import AVFoundation
import MinutesCore
import MinutesObjC
import os
import Speech

private let log = Logger(subsystem: "com.imshaikot.claude-miss-minutes", category: "ears")

/// Speech to text for hold-to-talk and spoken permission answers, with Apple's
/// own recognizer (the engine behind Dictation). Recognition stays on this Mac
/// whenever the language's on-device model is installed, and goes to Apple's
/// servers otherwise.
///
/// macOS needs the microphone and speech-recognition usage strings in the
/// app's Info.plist, so this only works from the .app bundle, not `swift run`.
@MainActor
public final class SpeechListener: EarsPort {
    public var onEvent: ((HearingEvent) -> Void)?

    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    /// The recognizer stopped on its own (silence, error) before `finish()`.
    private var recognitionEnded = false
    private var finishing = false
    private var session = 0
    private var finishTimeout: DispatchWorkItem?

    public init() {}

    // MARK: EarsPort

    public var isAuthorized: Bool {
        Self.isBundledApp && SFSpeechRecognizer.authorizationStatus() == .authorized
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public func start(_ hint: HearingHint) {
        cancel()
        transcript = ""
        recognitionEnded = false
        finishing = false
        guard Self.isBundledApp else {
            return unavailable("Hold-to-talk needs the installed app (macOS only lets an app bundle use the microphone). Try `make install`.")
        }
        switch (SFSpeechRecognizer.authorizationStatus(), AVCaptureDevice.authorizationStatus(for: .audio)) {
        case (.denied, _), (.restricted, _):
            return unavailable("I'm not allowed to understand speech. Turn on Miss Minutes in System Settings ▸ Privacy & Security ▸ Speech Recognition.")
        case (_, .denied), (_, .restricted):
            return unavailable("I can't hear you, sugar. Turn on Miss Minutes in System Settings ▸ Privacy & Security ▸ Microphone.")
        case (.notDetermined, _), (_, .notDetermined):
            Self.requestAccess()
            return unavailable("macOS will ask if I may listen. Say yes, then hold ⌃ again and talk to me.")
        default:
            break
        }
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            return unavailable("Speech recognition isn't available right now. Is Dictation's language downloaded, or are we offline?")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        switch hint {
        case .dictation:
            request.taskHint = .dictation
            request.addsPunctuation = true
        case .yesOrNo:
            request.taskHint = .confirmation
        }
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        // A fresh engine each time picks up the current input device.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            return unavailable("I can't find a microphone.")
        }
        var startError: Error?
        let failure = MMCatchException {
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            engine.prepare()
            do { try engine.start() } catch { startError = error }
        }
        if let problem = failure ?? startError?.localizedDescription {
            log.error("Microphone failed to start (\(problem, privacy: .public))")
            _ = MMCatchException { input.removeTap(onBus: 0) }
            return unavailable("My ears won't start: \(problem)")
        }
        self.engine = engine
        self.recognizer = recognizer
        self.request = request
        session += 1
        let id = session
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.recognized(text, isFinal: isFinal, failed: failed, session: id) }
            }
        }
    }

    public func finish() {
        guard engine != nil || recognitionEnded else { return deliver() }
        finishing = true
        stopMicrophone()
        request?.endAudio()
        if recognitionEnded { return deliver() }
        // The final result normally lands well under a second after endAudio.
        let id = session
        let timeout = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { if self?.session == id { self?.deliver() } }
        }
        finishTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: timeout)
    }

    public func cancel() {
        session += 1
        finishTimeout?.cancel()
        finishTimeout = nil
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        stopMicrophone()
        finishing = false
    }

    // MARK: Recognition

    private func recognized(_ text: String?, isFinal: Bool, failed: Bool, session id: Int) {
        guard id == session else { return }
        if let text, !text.isEmpty { transcript = text }
        if isFinal || failed {
            // Ended by itself (silence, a server limit, "no speech detected").
            // Whatever was heard stands; it goes out when ⌃ is let go.
            recognitionEnded = true
            if finishing { deliver() }
            return
        }
        if !finishing { onEvent?(.partial(transcript)) }
    }

    private func deliver() {
        let heard = transcript
        cancel()
        onEvent?(.final(heard))
    }

    private func unavailable(_ reason: String) {
        cancel()
        onEvent?(.unavailable(reason))
    }

    private func stopMicrophone() {
        guard let engine else { return }
        self.engine = nil
        _ = MMCatchException {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    // MARK: Permissions

    private static var isBundledApp: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return info["NSMicrophoneUsageDescription"] != nil && info["NSSpeechRecognitionUsageDescription"] != nil
    }

    /// Both prompts, one after the other.
    private static func requestAccess() {
        SFSpeechRecognizer.requestAuthorization { _ in
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }
}
