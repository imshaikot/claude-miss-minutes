import Foundation

/// The Claude Code `--input-format/--output-format stream-json` protocol:
/// newline-delimited JSON both ways. `StreamJSON` encodes what we write to the
/// CLI's stdin; `StreamJSONParser` turns its stdout into `BrainEvent`s.
public enum StreamJSON {
    public static func userMessage(_ text: String) -> Data {
        line([
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
        ])
    }

    public static func permissionResponse(requestID: String, allow: Bool, inputJSON: Data, message: String? = nil) -> Data {
        var decision: [String: Any]
        if allow {
            let input = (try? JSONSerialization.jsonObject(with: inputJSON)) ?? [String: Any]()
            decision = ["behavior": "allow", "updatedInput": input]
        } else {
            decision = ["behavior": "deny", "message": message ?? "The user declined this from Miss Minutes' speech bubble."]
        }
        return line([
            "type": "control_response",
            "response": ["subtype": "success", "request_id": requestID, "response": decision],
        ])
    }

    public static func interrupt(requestID: String = UUID().uuidString) -> Data {
        line(["type": "control_request", "request_id": requestID, "request": ["subtype": "interrupt"]])
    }

    static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }
}

/// Stateful decoder for the CLI's stdout. Feed it one line at a time.
public struct StreamJSONParser {
    private var toolNames: [String: String] = [:]
    private var sawPartialMessages = false
    private var turnHasText = false

    public init() {}

    public mutating func parse(line: String) -> [BrainEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return [] }

        switch type {
        case "system":
            guard object["subtype"] as? String == "init" else { return [] }
            return [.started(sessionID: object["session_id"] as? String, model: object["model"] as? String)]

        case "stream_event":
            sawPartialMessages = true
            guard let event = object["event"] as? [String: Any] else { return [] }
            if event["type"] as? String == "content_block_start",
               let block = event["content_block"] as? [String: Any], block["type"] as? String == "text", turnHasText {
                return [.textDelta("\n\n")]
            }
            guard event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else { return [] }
            turnHasText = true
            return [.textDelta(text)]

        case "assistant":
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            var events: [BrainEvent] = []
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    if let id = block["id"] as? String { toolNames[id] = name }
                    events.append(.toolStarted(name: name, summary: ToolSummary.describe(tool: name, input: block["input"] as? [String: Any] ?? [:])))
                case "text" where !sawPartialMessages:
                    if let text = block["text"] as? String, !text.isEmpty {
                        if turnHasText { events.append(.textDelta("\n\n")) }
                        turnHasText = true
                        events.append(.textDelta(text))
                    }
                default:
                    break
                }
            }
            return events

        case "user":
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }
            return content.compactMap { block in
                guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String else { return nil }
                return .toolFinished(name: toolNames.removeValue(forKey: id) ?? "tool", isError: block["is_error"] as? Bool ?? false)
            }

        case "control_request":
            guard let id = object["request_id"] as? String,
                  let request = object["request"] as? [String: Any],
                  request["subtype"] as? String == "can_use_tool" else { return [] }
            let tool = request["display_name"] as? String ?? request["tool_name"] as? String ?? "a tool"
            let input = request["input"] as? [String: Any] ?? [:]
            let inputJSON = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
            let summary = ToolSummary.describe(tool: request["tool_name"] as? String ?? tool, input: input)
            return [.permissionRequested(PermissionRequest(id: id, tool: tool, summary: summary, inputJSON: inputJSON))]

        case "result":
            turnHasText = false
            let subtype = object["subtype"] as? String ?? ""
            let isError = (object["is_error"] as? Bool ?? false) || subtype != "success"
            var text = object["result"] as? String ?? ""
            if isError, text.isEmpty, let errors = object["errors"] as? [String] { text = errors.joined(separator: "\n") }
            return [.turnFinished(TurnResult(text: text, isError: isError,
                                             sessionID: object["session_id"] as? String,
                                             costUSD: object["total_cost_usd"] as? Double))]
        default:
            return []
        }
    }
}

/// One-line, human-readable descriptions of tool calls for the speech bubble.
public enum ToolSummary {
    public static let bodyToolPrefix = "mcp__minutes__"

    public static func isBodyTool(_ name: String) -> Bool { name.hasPrefix(bodyToolPrefix) }

    public static func describe(tool: String, input: [String: Any]) -> String {
        func s(_ key: String) -> String? { (input[key] as? String).map { $0.count > 120 ? String($0.prefix(117)) + "…" : $0 } }
        switch tool {
        case "Bash": return "Run: \(s("command") ?? "a shell command")"
        case "Read": return "Read \(s("file_path") ?? "a file")"
        case "Write": return "Write \(s("file_path") ?? "a file")"
        case "Edit", "MultiEdit": return "Edit \(s("file_path") ?? "a file")"
        case "Glob": return "Look for files matching \(s("pattern") ?? "a pattern")"
        case "Grep": return "Search files for \(s("pattern") ?? "text")"
        case "WebFetch": return "Open \(s("url") ?? "a web page")"
        case "WebSearch": return "Search the web for \(s("query") ?? "something")"
        default:
            if isBodyTool(tool) { return String(tool.dropFirst(bodyToolPrefix.count)).replacingOccurrences(of: "_", with: " ") }
            if let description = s("description") { return "\(tool): \(description)" }
            return "Use \(tool)"
        }
    }
}
