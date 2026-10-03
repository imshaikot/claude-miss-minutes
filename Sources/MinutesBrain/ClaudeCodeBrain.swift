import Foundation
import MinutesCore

public enum BrainError: LocalizedError {
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(what): return what
        }
    }
}

/// The brain: one long-lived `claude -p` process speaking stream-json over
/// stdin/stdout. Messages queue up while it starts; permission questions are
/// answered through stdin; a restart resumes the same session unless asked
/// for a fresh one.
@MainActor
public final class ClaudeCodeBrain: BrainPort {
    public var onEvent: ((BrainEvent) -> Void)?
    public var onStatus: ((BrainStatus) -> Void)?
    /// The conversation's session id changed (persist it to resume across launches).
    public var onSession: ((String?) -> Void)?

    public private(set) var status: BrainStatus = .stopped { didSet { if status != oldValue { onStatus?(status) } } }
    public private(set) var sessionID: String?
    public private(set) var model: String?
    public private(set) var sessionCostUSD: Double = 0
    public private(set) var lastPlan: ClaudeLaunchPlan?

    private let planProvider: (_ resume: String?) throws -> ClaudeLaunchPlan
    private var process: Process?
    private var stdin: FileHandle?
    private var parser = StreamJSONParser()
    private var lineBuffer = Data()
    private var stderrTail = ""
    private var pending: [Data] = []
    private var busy = false
    private var generation = 0
    private var resumeID: String?
    private var resumedThisLaunch = false

    public init(resumeSessionID: String?, planProvider: @escaping (_ resume: String?) throws -> ClaudeLaunchPlan) {
        self.resumeID = resumeSessionID
        self.sessionID = resumeSessionID
        self.planProvider = planProvider
    }

    // MARK: BrainPort

    public func start() {
        guard process == nil else { return }
        launch()
    }

    public func send(_ text: String) {
        busy = true
        write(StreamJSON.userMessage(text))
        if status != .starting { status = .busy }
    }

    public func answer(_ request: PermissionRequest, allow: Bool) {
        write(StreamJSON.permissionResponse(requestID: request.id, allow: allow, inputJSON: request.inputJSON))
    }

    public func interrupt() {
        guard busy, process != nil else { return }
        write(StreamJSON.interrupt())
    }

    public func restart(fresh: Bool) {
        terminate()
        if fresh {
            resumeID = nil
            sessionID = nil
            sessionCostUSD = 0
            onSession?(nil)
        } else {
            resumeID = sessionID
        }
        launch()
    }

    public func stop() {
        terminate()
        status = .stopped
    }

    // MARK: Process

    private func launch() {
        let plan: ClaudeLaunchPlan
        do {
            plan = try planProvider(resumeID)
        } catch {
            status = .failed(error.localizedDescription)
            if busy { busy = false; onEvent?(.failed(error.localizedDescription)) }
            pending.removeAll()
            return
        }
        lastPlan = plan
        generation += 1
        let gen = generation
        parser = StreamJSONParser()
        lineBuffer.removeAll()
        stderrTail = ""
        resumedThisLaunch = resumeID != nil

        let p = Process()
        p.executableURL = URL(fileURLWithPath: plan.executable)
        p.arguments = plan.arguments
        p.environment = plan.environment
        p.currentDirectoryURL = URL(fileURLWithPath: plan.workingDirectory)
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

        status = .starting
        do {
            try p.run()
        } catch {
            status = .failed("Could not start Claude Code: \(error.localizedDescription)")
            if busy { busy = false; onEvent?(.failed("Could not start Claude Code at \(plan.executable).")) }
            return
        }
        process = p
        stdin = input.fileHandleForWriting
        status = busy ? .busy : .ready
        let queued = pending
        pending.removeAll()
        for data in queued { write(data) }
    }

    private func terminate() {
        generation += 1
        busy = false
        pending.removeAll()
        try? stdin?.close()
        stdin = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    private func write(_ data: Data) {
        guard let stdin else {
            pending.append(data)
            if process == nil { launch() }
            return
        }
        do {
            try stdin.write(contentsOf: data)
        } catch {
            pending.append(data)
        }
    }

    private func consume(_ data: Data, generation gen: Int) {
        guard gen == generation else { return }
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[lineBuffer.startIndex..<newline]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            for event in parser.parse(line: line) { route(event) }
        }
    }

    private func route(_ event: BrainEvent) {
        switch event {
        case let .started(session, model):
            if let model { self.model = model }
            if let session, session != sessionID {
                sessionID = session
                onSession?(session)
            }
        case let .turnFinished(result):
            busy = false
            status = .ready
            if let cost = result.costUSD { sessionCostUSD = cost }
            if let session = result.sessionID, session != sessionID {
                sessionID = session
                onSession?(session)
            }
        default:
            break
        }
        onEvent?(event)
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
        let message = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").suffix(3).joined(separator: " ")
        if resumedThisLaunch, code != 0 {
            // The saved session could not be resumed (deleted, other directory): start fresh next time.
            resumeID = nil
            sessionID = nil
            onSession?(nil)
        }
        status = code == 0 ? .stopped : .failed(message.isEmpty ? "Claude Code exited with code \(code)" : message)
        if busy {
            busy = false
            onEvent?(.exited(code: code, message: message.isEmpty ? nil : message))
        }
    }
}
