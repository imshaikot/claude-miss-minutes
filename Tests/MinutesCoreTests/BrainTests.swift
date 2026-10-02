import Foundation
import Testing
@testable import MinutesCore

@Suite("stream-json protocol")
struct StreamJSONTests {
    @Test func parsesATurnWithStreamingTextAndATool() {
        var parser = StreamJSONParser()
        let lines = [
            #"{"type":"system","subtype":"init","session_id":"s-1","model":"claude-sonnet-5-5"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text","text":""}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi "}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"sugar."}}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hi sugar."}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/tmp/a.txt"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"x","is_error":false}]}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"text","text":""}}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"Hi sugar.","session_id":"s-1","total_cost_usd":0.012}"#,
        ]
        let events = lines.flatMap { parser.parse(line: $0) }
        #expect(events == [
            .started(sessionID: "s-1", model: "claude-sonnet-5-5"),
            .textDelta("Hi "),
            .textDelta("sugar."),
            .toolStarted(name: "Read", summary: "Read /tmp/a.txt"),
            .toolFinished(name: "Read", isError: false),
            .textDelta("\n\n"),
            .turnFinished(TurnResult(text: "Hi sugar.", isError: false, sessionID: "s-1", costUSD: 0.012)),
        ])
    }

    @Test func withoutPartialMessagesTextComesFromAssistantMessages() {
        var parser = StreamJSONParser()
        let events = parser.parse(line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]}}"#)
        #expect(events == [.textDelta("Hello")])
    }

    @Test func permissionRequestsCarryTheToolInput() throws {
        var parser = StreamJSONParser()
        let line = #"{"type":"control_request","request_id":"r9","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"ls ~/Downloads"}}}"#
        let events = parser.parse(line: line)
        guard case let .permissionRequested(request)? = events.first else {
            Issue.record("expected a permission request, got \(events)")
            return
        }
        #expect(request.id == "r9")
        #expect(request.summary == "Run: ls ~/Downloads")
        let input = try JSONSerialization.jsonObject(with: request.inputJSON) as? [String: String]
        #expect(input == ["command": "ls ~/Downloads"])
    }

    @Test func errorsAndJunkAreHandled() {
        var parser = StreamJSONParser()
        #expect(parser.parse(line: "not json").isEmpty)
        #expect(parser.parse(line: #"{"type":"rate_limit_event"}"#).isEmpty)
        let failed = parser.parse(line: #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["boom"]}"#)
        #expect(failed == [.turnFinished(TurnResult(text: "boom", isError: true))])
    }

    @Test func outgoingMessagesAreSingleJSONLines() throws {
        let user = StreamJSON.userMessage("hi \"there\"")
        #expect(user.last == 0x0A)
        let object = try JSONSerialization.jsonObject(with: user.dropLast()) as? [String: Any]
        #expect(object?["type"] as? String == "user")

        let allow = StreamJSON.permissionResponse(requestID: "r1", allow: true, inputJSON: Data(#"{"command":"ls"}"#.utf8))
        let response = try JSONSerialization.jsonObject(with: allow.dropLast()) as? [String: Any]
        let inner = (response?["response"] as? [String: Any])?["response"] as? [String: Any]
        #expect(inner?["behavior"] as? String == "allow")
        #expect((inner?["updatedInput"] as? [String: String]) == ["command": "ls"])

        let deny = StreamJSON.permissionResponse(requestID: "r1", allow: false, inputJSON: Data())
        #expect(String(decoding: deny, as: UTF8.self).contains(#""behavior":"deny""#))
    }
}

@Suite("Launch plan")
struct LaunchPlanTests {
    private func plan(_ configure: (inout BrainSettings) -> Void = { _ in }, bridge: BodyBridgeLaunch? = nil, resume: String? = nil,
                      env: [String: String] = ["PATH": "/usr/bin", "CLAUDECODE": "1", "HOME": "/Users/me"]) -> ClaudeLaunchPlan {
        var settings = BrainSettings()
        configure(&settings)
        return ClaudeLaunchPlanner.make(settings: settings, executable: "/x/claude", persona: "You are Miss Minutes.", bridge: bridge,
                                        resumeSessionID: resume, baseEnvironment: env, loginPATH: "/opt/homebrew/bin:/usr/bin",
                                        home: "/Users/me", defaultWorkingDirectory: "/Users/me/Library/Application Support/MM")
    }

    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    @Test func defaultsAreAStreamingLookOnlySession() {
        let p = plan()
        #expect(Array(p.arguments.prefix(1)) == ["-p"])
        #expect(value(after: "--input-format", in: p.arguments) == "stream-json")
        #expect(value(after: "--output-format", in: p.arguments) == "stream-json")
        #expect(p.arguments.contains("--include-partial-messages"))
        #expect(value(after: "--permission-prompt-tool", in: p.arguments) == "stdio")
        #expect(value(after: "--model", in: p.arguments) == "sonnet")
        #expect(value(after: "--effort", in: p.arguments) == "low")
        #expect(value(after: "--tools", in: p.arguments) == "Read,Glob,Grep,WebSearch,WebFetch")
        #expect(value(after: "--append-system-prompt", in: p.arguments) == "You are Miss Minutes.")
        #expect(p.arguments.contains("--strict-mcp-config"))
        #expect(p.workingDirectory == "/Users/me/Library/Application Support/MM")
    }

    @Test func toolAccessLevelsMapToFlags() {
        #expect(value(after: "--tools", in: plan { $0.tools = .conversation }.arguments) == "")
        #expect(!plan { $0.tools = .askFirst }.arguments.contains("--tools"))
    }

    @Test func defaultModelAndAutoEffortAddNoFlags() {
        let p = plan { $0.model = ""; $0.effort = .auto; $0.isolateMCP = false }
        #expect(!p.arguments.contains("--model"))
        #expect(!p.arguments.contains("--effort"))
        #expect(!p.arguments.contains("--strict-mcp-config"))
    }

    @Test func theBodyBridgeIsAllowedWithoutPrompts() throws {
        let bridge = BodyBridgeLaunch(nodePath: "/opt/homebrew/bin/node", scriptPath: "/app/bridge.mjs", port: 5555, token: "tok")
        let p = plan(bridge: bridge)
        #expect(value(after: "--allowedTools", in: p.arguments) == "mcp__minutes")
        let config = try JSONSerialization.jsonObject(with: Data(value(after: "--mcp-config", in: p.arguments)!.utf8)) as? [String: Any]
        let server = (config?["mcpServers"] as? [String: Any])?["minutes"] as? [String: Any]
        #expect(server?["command"] as? String == "/opt/homebrew/bin/node")
        #expect(server?["args"] as? [String] == ["/app/bridge.mjs"])
        #expect((server?["env"] as? [String: String]) == ["MINUTES_PORT": "5555", "MINUTES_TOKEN": "tok"])
    }

    @Test func resumeExtraArgumentsAndEnvironment() {
        let p = plan({ $0.extraArguments = #"--add-dir "~/My Docs" --verbose"#; $0.workingDirectory = "~/Projects" }, resume: "abc")
        #expect(value(after: "--resume", in: p.arguments) == "abc")
        #expect(Array(p.arguments.suffix(3)) == ["--add-dir", "~/My Docs", "--verbose"])
        #expect(p.environment["CLAUDECODE"] == nil)
        #expect(p.environment["PATH"]!.hasPrefix("/opt/homebrew/bin:/usr/bin:"))
        #expect(p.workingDirectory == "/Users/me/Projects")
    }

    @Test func shellWordsHonourQuotesAndEscapes() {
        #expect(ShellWords.split(#"a "b c" 'd e' f\ g"#) == ["a", "b c", "d e", "f g"])
        #expect(ShellWords.split("   ") == [])
        #expect(ShellWords.split(#"--x """#) == ["--x", ""])
    }
}

@Suite("Settings and body commands")
struct SettingsTests {
    @Test func oldOrPartialSettingsStillLoad() throws {
        let json = #"{"brain":{"model":"opus"},"voice":{"enabled":false}}"#
        let settings = try JSONDecoder().decode(MinutesSettings.self, from: Data(json.utf8))
        #expect(settings.brain.model == "opus")
        #expect(settings.brain.tools == .lookOnly)
        #expect(settings.voice.enabled == false)
        #expect(settings.character == CharacterSettings())
    }

    @Test func settingsRoundTrip() throws {
        var settings = MinutesSettings()
        settings.character.shyApps = ["zoom.us"]
        settings.brain.effort = .high
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(MinutesSettings.self, from: data) == settings)
    }

    @Test func restlessnessShortensWanderIntervals() {
        var calm = CharacterSettings(), busy = CharacterSettings()
        calm.restlessness = 0
        busy.restlessness = 1
        #expect(busy.wanderInterval.upperBound < calm.wanderInterval.lowerBound)
    }

    @Test func bodyCommandsDecode() throws {
        #expect(try BodyCommand.decode(tool: "emote", args: ["mood": "Happy", "gesture": "wave"]) == .emote(mood: .happy, gesture: .wave))
        #expect(try BodyCommand.decode(tool: "move_to", args: ["target": "app", "app": "Safari"]) == .moveTo(.app("Safari"), style: .auto))
        #expect(try BodyCommand.decode(tool: "move_to", args: ["target": "pointer", "style": "teleport"]) == .moveTo(.cursor, style: .teleport))
        #expect(try BodyCommand.decode(tool: "set_reminder", args: ["minutes": 1.5, "message": "Stretch!"]) == .setReminder(seconds: 90, message: "Stretch!"))
        #expect(try BodyCommand.decode(tool: "look_at_screen", args: [:]) == .lookAtScreen(screenshot: true))
    }

    @Test func badBodyCommandsExplainThemselves() {
        #expect(throws: BodyCommand.DecodeError.self) { try BodyCommand.decode(tool: "emote", args: [:]) }
        #expect(throws: BodyCommand.DecodeError.self) { try BodyCommand.decode(tool: "emote", args: ["gesture": "moonwalk"]) }
        #expect(throws: BodyCommand.DecodeError.self) { try BodyCommand.decode(tool: "move_to", args: ["target": "app"]) }
        #expect(throws: BodyCommand.DecodeError.self) { try BodyCommand.decode(tool: "set_reminder", args: ["message": "x"]) }
        #expect(throws: BodyCommand.DecodeError.self) { try BodyCommand.decode(tool: "fly", args: [:]) }
    }

    /// The MCP schemas live in the Node bridge; keep its enums in step with the Swift ones.
    @Test func bridgeSchemasMatchTheSwiftEnums() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("bridge/miss-minutes-mcp.mjs"), encoding: .utf8)
        func list(_ name: String) -> [String] {
            guard let line = script.split(separator: "\n").first(where: { $0.hasPrefix("export const \(name) = [") }) else { return [] }
            return line.split(separator: "'").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        }
        #expect(list("MOODS") == Mood.allCases.map(\.rawValue))
        #expect(list("GESTURES") == GestureName.allCases.map(\.rawValue))
    }
}
