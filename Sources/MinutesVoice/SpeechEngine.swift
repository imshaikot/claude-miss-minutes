import AVFoundation
import CoreGraphics
import MinutesCore
import MinutesObjC
import os
import QuartzCore

private let log = Logger(subsystem: "com.imshaikot.claude-miss-minutes", category: "voice")

/// Text-to-speech with real lip sync.
///
/// Sentences are synthesized to PCM buffers (`AVSpeechSynthesizer.write`) and
/// played through an `AVAudioEngine`. While scheduling each buffer we record its
/// loudness in 256-frame blocks; every animation frame `mouth()` looks up the
/// block that is playing right now, so the jaw follows the actual audio. Lip
/// rounding comes from the letters at the current position in the sentence.
@MainActor
public final class SpeechEngine: NSObject, VoicePort {
    public var onFinished: (() -> Void)?
    public private(set) var isSpeaking = false

    private var settings: VoiceSettings
    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connectedFormat: AVAudioFormat?
    private var queue: [String] = []
    private var synthesizing = false
    private var receivedAudio = false
    private var writeStartedAt: CFTimeInterval = 0
    private var scheduledFrames: AVAudioFramePosition = 0
    private var envelope: [Float] = []
    private let block: AVAudioFrameCount = 256
    private var segments: [(start: AVAudioFramePosition, end: AVAudioFramePosition?, text: String)] = []
    private var jaw: CGFloat = 0
    private var generation = 0
    private var fallbackSpeaking = false
    private var watchdog: Timer?

    public init(settings: VoiceSettings) {
        self.settings = settings
        super.init()
        engine.attach(player)
        synth.delegate = self
        // macOS stops the engine on its own thread when the output device changes
        // (headphones, display audio); reconnect instead of playing into a stopped engine.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineConfigurationChanged() }
        }
    }

    public func apply(_ settings: VoiceSettings) {
        self.settings = settings
        player.volume = Float(settings.volume)
    }

    // MARK: VoicePort

    public func speak(_ sentence: String) {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        queue.append(text)
        if !isSpeaking {
            isSpeaking = true
            startWatchdog()
        }
        pump()
    }

    public func stop() {
        generation += 1
        queue.removeAll()
        synth.stopSpeaking(at: .immediate)
        synthesizing = false
        fallbackSpeaking = false
        if isSpeaking { reset() }
    }

    /// The mouth shape for this instant, or nil when silent. Call once per frame.
    public func mouth() -> MouthShape? {
        guard isSpeaking else { return nil }
        if fallbackSpeaking {
            let t = CACurrentMediaTime()
            return MouthShape(open: 0.25 + 0.35 * CGFloat(abs(sin(t * 11))), wide: 0.2 * CGFloat(sin(t * 3)))
        }
        guard let sample = playedFrames() else { return MouthShape(open: 0, wide: 0) }
        let index = Int(sample / AVAudioFramePosition(block))
        let rms = index >= 0 && index < envelope.count ? CGFloat(envelope[index]) : 0
        let target = clamp((rms - 0.012) * 3.2, 0, 1).squareRoot()
        jaw += (target - jaw) * (target > jaw ? 0.65 : 0.3)
        var wide: CGFloat = 0
        if let segment = segments.last(where: { $0.start <= sample }) {
            let end = segment.end ?? scheduledFrames
            let fraction = Double(sample - segment.start) / Double(max(1, end - segment.start))
            wide = Phonetics.wideness(in: segment.text, at: clamp(fraction, 0, 1))
        }
        return MouthShape(open: jaw, wide: wide)
    }

    // MARK: Voices

    public struct VoiceOption: Identifiable, Hashable {
        public var id: String
        public var name: String
        public var language: String
        public var quality: String
    }

    public static func availableVoices() -> [VoiceOption] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
            .map { VoiceOption(id: $0.identifier, name: $0.name, language: $0.language, quality: label($0.quality)) }
    }

    private static func label(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }

    /// Best installed English voice that suits her: a higher-quality female US voice if present.
    static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let ranked = voices.sorted { a, b in
            func score(_ v: AVSpeechSynthesisVoice) -> Int {
                var s = v.quality.rawValue * 10
                if v.language == "en-US" { s += 5 }
                if v.gender == .female { s += 3 }
                if v.name == "Samantha" { s += 2 }
                if v.identifier.contains("eloquence") || v.identifier.contains("speech.synthesis.voice") { s -= 20 }
                return s
            }
            return score(a) > score(b)
        }
        return ranked.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    // MARK: Pipeline

    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = settings.voiceIdentifier.isEmpty ? Self.preferredVoice() : (AVSpeechSynthesisVoice(identifier: settings.voiceIdentifier) ?? Self.preferredVoice())
        u.rate = Float(clamp(settings.rate, 0.3, 0.7))
        u.pitchMultiplier = Float(clamp(settings.pitch, 0.5, 2))
        u.postUtteranceDelay = 0.04
        return u
    }

    private func pump() {
        guard !synthesizing, !fallbackSpeaking, !queue.isEmpty else { return }
        let text = queue.removeFirst()
        synthesizing = true
        receivedAudio = false
        writeStartedAt = CACurrentMediaTime()
        segments.append((scheduledFrames, nil, text))
        let gen = generation
        let utterance = makeUtterance(text)
        synth.write(utterance) { [weak self] buffer in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(buffer, generation: gen, utterance: utterance) }
            }
        }
    }

    private func receive(_ buffer: AVAudioBuffer, generation gen: Int, utterance: AVSpeechUtterance) {
        guard gen == generation, let pcm = buffer as? AVAudioPCMBuffer else { return }
        guard pcm.frameLength > 0 else {
            if let last = segments.indices.last { segments[last].end = scheduledFrames }
            synthesizing = false
            pump()
            return
        }
        receivedAudio = true
        guard prepareEngine(for: pcm.format) else { return }
        if let data = pcm.floatChannelData?[0] {
            var offset: AVAudioFrameCount = 0
            while offset < pcm.frameLength {
                let count = min(block, pcm.frameLength - offset)
                var sum: Float = 0
                for i in 0..<Int(count) { let s = data[Int(offset) + i]; sum += s * s }
                envelope.append((sum / Float(count)).squareRoot())
                offset += count
            }
        }
        let failure = MMCatchException {
            self.player.scheduleBuffer(pcm, completionHandler: nil)
            if !self.player.isPlaying { self.player.play() }
        }
        if let failure {
            log.error("Audio playback failed (\(failure, privacy: .public)); reconnecting")
            engineConfigurationChanged()
            return
        }
        scheduledFrames += AVAudioFramePosition(pcm.frameLength)
    }

    /// The engine stopped underneath us: drop what was queued for playback,
    /// reconnect on the next buffer and carry on with the remaining sentences.
    private func engineConfigurationChanged() {
        connectedFormat = nil
        _ = MMCatchException { self.player.stop() }
        scheduledFrames = 0
        envelope.removeAll()
        if let last = segments.last, last.end == nil { segments = [(0, nil, last.text)] } else { segments.removeAll() }
    }

    private func prepareEngine(for format: AVAudioFormat) -> Bool {
        if connectedFormat == nil || connectedFormat!.sampleRate != format.sampleRate || connectedFormat!.channelCount != format.channelCount {
            if scheduledFrames > 0, connectedFormat != nil { return true }
            let failure = MMCatchException {
                self.player.stop()
                self.engine.connect(self.player, to: self.engine.mainMixerNode, format: format)
            }
            if let failure {
                log.error("Could not connect the voice (\(failure, privacy: .public))")
                return false
            }
            connectedFormat = format
            player.volume = Float(settings.volume)
        }
        if !engine.isRunning {
            do { try engine.start() } catch {
                log.error("Could not start audio (\(error.localizedDescription, privacy: .public))")
                return false
            }
        }
        return true
    }

    private func playedFrames() -> AVAudioFramePosition? {
        guard player.isPlaying, let nodeTime = player.lastRenderTime, let time = player.playerTime(forNodeTime: nodeTime) else { return nil }
        return time.sampleTime
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkProgress() }
        }
    }

    /// Detects the end of playback, and falls back to plain `speak()` for voices
    /// that cannot render to buffers.
    private func checkProgress() {
        guard isSpeaking else { return }
        if synthesizing, !receivedAudio, CACurrentMediaTime() - writeStartedAt > 2.0 {
            generation += 1
            synth.stopSpeaking(at: .immediate)
            synthesizing = false
            if let segment = segments.popLast() {
                fallbackSpeaking = true
                synth.speak(makeUtterance(segment.text))
            }
            return
        }
        guard !synthesizing, !fallbackSpeaking, queue.isEmpty else { return }
        let played = playedFrames() ?? scheduledFrames
        if played >= scheduledFrames {
            reset()
            onFinished?()
        }
    }

    private func reset() {
        isSpeaking = false
        watchdog?.invalidate()
        watchdog = nil
        _ = MMCatchException {
            self.player.stop()
            self.engine.stop()
        }
        scheduledFrames = 0
        envelope.removeAll()
        segments.removeAll()
        jaw = 0
    }
}

extension SpeechEngine: AVSpeechSynthesizerDelegate {
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.fallbackSpeaking else { return }
                self.fallbackSpeaking = false
                self.pump()
            }
        }
    }
}
