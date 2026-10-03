import AVFoundation
import Combine
import Foundation
import os

private let log = Logger(subsystem: "com.imshaikot.claude-miss-minutes", category: "kokoro")

/// Kokoro-82M, an open-source neural voice (Apache-2.0), running on this Mac
/// in a Node sidecar (`voice/miss-minutes-voice.mjs`).
///
/// Nothing ships with the app: `install()` downloads the packages and the
/// model (about 330 MB) into `home` on request, and from then on it runs
/// offline. Sentences go in as JSON lines on stdin; 24 kHz float PCM comes
/// back on stdout, a chunk at a time.
@MainActor
public final class KokoroVoice: ObservableObject {
    public enum State: Equatable {
        case notInstalled
        /// `fraction` is nil while there is no progress to report.
        case installing(fraction: Double?, step: String)
        /// Installed, not running.
        case stopped
        case starting
        case ready
        case failed(String)
    }

    public enum Event {
        case audio(AVAudioPCMBuffer)
        case done
        case failed(String)
    }

    /// How to run the sidecar. Resolved each launch, since the node path is a setting.
    public struct Runtime {
        public var node: String
        public var script: String
        public var environment: [String: String]

        public init(node: String, script: String, environment: [String: String]) {
            self.node = node
            self.script = script
            self.environment = environment
        }
    }

    @Published public private(set) var state: State {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public var onStateChange: ((State) -> Void)?

    private let home: URL
    private let runtime: () -> Runtime?
    private var process: Process?
    private var mode = ""
    private var stdin: FileHandle?
    private var lineBuffer = Data()
    private var stderrTail = ""
    private var fatalMessage: String?
    private var generation = 0
    private var nextID = 0
    private var handlers: [Int: (Event) -> Void] = [:]
    private var crashes = 0

    public init(home: URL, runtime: @escaping () -> Runtime?) {
        self.home = home
        self.runtime = runtime
        state = FileManager.default.fileExists(atPath: home.appendingPathComponent("installed.json").path) ? .stopped : .notInstalled
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent("installed.json").path)
    }

    // MARK: Lifecycle

    /// Download everything (on request: it is a few hundred megabytes), then start.
    public func install() {
        terminate()
        launch("install")
        if process != nil { state = .installing(fraction: nil, step: "Downloading packages…") }
    }

    public func cancelInstall() {
        guard case .installing = state else { return }
        terminate()
        try? FileManager.default.removeItem(at: home)
        state = .notInstalled
    }

    public func uninstall() {
        terminate()
        try? FileManager.default.removeItem(at: home)
        state = .notInstalled
    }

    /// Start the voice server if it is installed and not already running.
    public func start() {
        guard process == nil, isInstalled else { return }
        launch("serve")
        if process != nil { state = .starting }
    }

    public func stop() {
        guard mode != "install" || process == nil else { return }
        terminate()
        state = isInstalled ? .stopped : .notInstalled
    }

    /// After a failure: start again, or reinstall if the install never finished.
    public func retry() {
        crashes = 0
        if isInstalled { terminate(); start() } else { install() }
    }

    // MARK: Speaking

    /// Renders one sentence: `handler` gets audio chunks and then `.done`, or `.failed`.
    public func speak(_ text: String, voice: String, speed: Double, handler: @escaping (Event) -> Void) {
        guard state == .ready, let stdin else {
            DispatchQueue.main.async { handler(.failed("The neural voice isn't running.")) }
            return
        }
        nextID += 1
        handlers[nextID] = handler
        send(["type": "speak", "id": nextID, "text": text, "voice": voice, "speed": speed], to: stdin)
    }

    /// Drop every sentence not yet spoken; their handlers are not called again.
    public func cancelAll() {
        handlers.removeAll()
        if state == .ready, let stdin { send(["type": "cancel"], to: stdin) }
    }

    // MARK: Process

    private func launch(_ mode: String) {
        guard let runtime = runtime() else {
            state = .failed("Node.js wasn't found. Install it (brew install node), or set its path in Settings ▸ Brain.")
            return
        }
        generation += 1
        let gen = generation
        self.mode = mode
        lineBuffer.removeAll()
        stderrTail = ""
        fatalMessage = nil
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: runtime.node)
        p.arguments = [runtime.script, mode, "--home", home.path]
        p.environment = runtime.environment
        p.currentDirectoryURL = home
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(data, generation: gen) } }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.appendStderr(data, generation: gen) } }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(code: code, generation: gen) } }
        }
        do {
            try p.run()
        } catch {
            state = .failed("Could not start the neural voice: \(error.localizedDescription)")
            return
        }
        process = p
        stdin = input.fileHandleForWriting
    }

    private func terminate() {
        generation += 1
        failAll("The neural voice stopped.")
        try? stdin?.close()
        stdin = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    private func send(_ message: [String: Any], to handle: FileHandle) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        do { try handle.write(contentsOf: data) } catch { log.error("Could not reach the neural voice: \(error.localizedDescription, privacy: .public)") }
    }

    private func consume(_ data: Data, generation gen: Int) {
        guard gen == generation else { return }
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[lineBuffer.startIndex..<newline]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        let id = message["id"] as? Int
        switch message["type"] as? String {
        case "progress":
            let model = message["stage"] as? String == "model"
            state = .installing(fraction: message["fraction"] as? Double, step: model ? "Downloading the voice model…" : "Downloading packages…")
        case "ready":
            state = .ready
        case "audio":
            guard let id, let pcm = message["pcm"] as? String, let buffer = Self.buffer(base64: pcm, rate: message["rate"] as? Double ?? 24000) else { return }
            handlers[id]?(.audio(buffer))
        case "done":
            if let id { handlers.removeValue(forKey: id)?(.done) }
        case "error":
            let text = message["message"] as? String ?? "Unknown error"
            if let id { handlers.removeValue(forKey: id)?(.failed(text)) } else { fatalMessage = text }
        default:
            break
        }
    }

    private func appendStderr(_ data: Data, generation gen: Int) {
        guard gen == generation else { return }
        stderrTail += String(decoding: data, as: UTF8.self)
        if stderrTail.count > 4000 { stderrTail = String(stderrTail.suffix(4000)) }
    }

    private func exited(code: Int32, generation gen: Int) {
        guard gen == generation else { return }
        process = nil
        stdin = nil
        let detail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").suffix(2).joined(separator: " ")
        let reason = fatalMessage ?? (detail.isEmpty ? "The neural voice exited (code \(code))." : detail)
        failAll(reason)
        if mode == "install" {
            if code == 0, isInstalled {
                state = .stopped
                start()
            } else {
                state = .failed(reason)
            }
            return
        }
        let wasReady = state == .ready
        state = .failed(reason)
        log.error("Neural voice stopped: \(reason, privacy: .public)")
        // It was working: bring it back, but don't loop on a crash.
        if wasReady, crashes < 3 {
            crashes += 1
            start()
        }
    }

    private func failAll(_ reason: String) {
        let pending = handlers
        handlers.removeAll()
        for handler in pending.values { handler(.failed(reason)) }
    }

    /// Little-endian float32 mono samples (the sidecar's wire format).
    static func buffer(base64: String, rate: Double) -> AVAudioPCMBuffer? {
        guard let data = Data(base64Encoded: base64), data.count >= 4,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { return nil }
        let frames = AVAudioFrameCount(data.count / 4)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let channel = buffer.floatChannelData?[0] else { return nil }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(channel, base, Int(frames) * MemoryLayout<Float>.size)
        }
        buffer.frameLength = frames
        return buffer
    }
}
