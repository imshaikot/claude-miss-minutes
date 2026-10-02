import Foundation

/// A tool-permission question from the brain, answered from her speech bubble.
public struct PermissionRequest: Equatable {
    public var id: String
    public var tool: String
    /// A one-line human summary ("Run: ls ~/Downloads").
    public var summary: String
    /// The raw tool input, echoed back on approval.
    public var inputJSON: Data

    public init(id: String, tool: String, summary: String, inputJSON: Data) {
        self.id = id
        self.tool = tool
        self.summary = summary
        self.inputJSON = inputJSON
    }
}

public struct TurnResult: Equatable {
    public var text: String
    public var isError: Bool
    public var sessionID: String?
    public var costUSD: Double?

    public init(text: String, isError: Bool, sessionID: String? = nil, costUSD: Double? = nil) {
        self.text = text
        self.isError = isError
        self.sessionID = sessionID
        self.costUSD = costUSD
    }
}

/// Everything a brain can tell the director. Provider-neutral: the Claude Code
/// adapter produces these from stream-json, and any future brain (a Node or Rust
/// sidecar, the API directly) only has to produce the same events.
public enum BrainEvent: Equatable {
    case started(sessionID: String?, model: String?)
    case textDelta(String)
    case toolStarted(name: String, summary: String)
    case toolFinished(name: String, isError: Bool)
    case permissionRequested(PermissionRequest)
    case turnFinished(TurnResult)
    case failed(String)
    case exited(code: Int32, message: String?)
}

public enum BrainStatus: Equatable {
    case stopped
    case starting
    case ready
    case busy
    case failed(String)

    public var label: String {
        switch self {
        case .stopped: return "Asleep"
        case .starting: return "Waking up…"
        case .ready: return "Ready"
        case .busy: return "Thinking…"
        case let .failed(message): return "Error: \(message)"
        }
    }
}
