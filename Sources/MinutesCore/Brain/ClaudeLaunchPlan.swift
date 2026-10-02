import Foundation

/// Everything needed to spawn the brain process. Built by a pure function so
/// the exact command line is unit-tested and shown verbatim in Settings.
public struct ClaudeLaunchPlan: Equatable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String
    public var environment: [String: String]

    /// The command line for display, with long values elided.
    public var displayCommand: String {
        ([executable] + arguments.map { arg in
            let short = arg.count > 60 ? String(arg.prefix(57)) + "…" : arg
            return short.contains(" ") || short.isEmpty ? "'\(short)'" : short
        }).joined(separator: " ")
    }
}

/// How the body bridge (her MCP server) is launched by Claude Code.
public struct BodyBridgeLaunch: Equatable {
    public var nodePath: String
    public var scriptPath: String
    public var port: UInt16
    public var token: String

    public init(nodePath: String, scriptPath: String, port: UInt16, token: String) {
        self.nodePath = nodePath
        self.scriptPath = scriptPath
        self.port = port
        self.token = token
    }

    public static let serverName = "minutes"

    public var mcpConfigJSON: String {
        let config: [String: Any] = [
            "mcpServers": [
                Self.serverName: [
                    "type": "stdio",
                    "command": nodePath,
                    "args": [scriptPath],
                    "env": ["MINUTES_PORT": String(port), "MINUTES_TOKEN": token],
                ],
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

public enum ClaudeLaunchPlanner {
    /// Built-in tools per access level (`nil` = Claude Code's full default set).
    public static func builtInTools(for access: ToolAccess) -> String? {
        switch access {
        case .conversation: return ""
        case .lookOnly: return "Read,Glob,Grep,WebSearch,WebFetch"
        case .askFirst: return nil
        }
    }

    public static func make(
        settings: BrainSettings,
        executable: String,
        persona: String,
        bridge: BodyBridgeLaunch?,
        resumeSessionID: String?,
        baseEnvironment: [String: String],
        loginPATH: String?,
        home: String,
        defaultWorkingDirectory: String
    ) -> ClaudeLaunchPlan {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-prompt-tool", "stdio",
        ]
        let model = settings.model.trimmingCharacters(in: .whitespaces)
        if !model.isEmpty, model.lowercased() != "default" { args += ["--model", model] }
        if settings.effort != .auto { args += ["--effort", settings.effort.rawValue] }
        if let tools = builtInTools(for: settings.tools) { args += ["--tools", tools] }
        args += ["--append-system-prompt", persona]
        if let bridge {
            args += ["--mcp-config", bridge.mcpConfigJSON]
            args += ["--allowedTools", "mcp__\(BodyBridgeLaunch.serverName)"]
        }
        if settings.isolateMCP { args.append("--strict-mcp-config") }
        if let resumeSessionID, !resumeSessionID.isEmpty { args += ["--resume", resumeSessionID] }
        args += ShellWords.split(settings.extraArguments)

        var env = baseEnvironment
        // A nested session must not think it runs inside another Claude Code.
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] { env.removeValue(forKey: key) }
        env["PATH"] = mergedPATH(loginPATH, env["PATH"], home: home)
        env["MISS_MINUTES"] = "1"

        return ClaudeLaunchPlan(
            executable: executable,
            arguments: args,
            workingDirectory: settings.workingDirectory.isEmpty ? defaultWorkingDirectory : expandTilde(settings.workingDirectory, home: home),
            environment: env
        )
    }

    static func mergedPATH(_ login: String?, _ current: String?, home: String) -> String {
        let fallback = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        var parts: [String] = []
        for part in (login ?? "").split(separator: ":").map(String.init) + (current ?? "").split(separator: ":").map(String.init) + fallback
        where !part.isEmpty && seen.insert(part).inserted {
            parts.append(part)
        }
        return parts.joined(separator: ":")
    }

    public static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }
}

/// Minimal POSIX-shell-style word splitting for the "extra arguments" field.
public enum ShellWords {
    public static func split(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escape = false
        for ch in text {
            if escape { current.append(ch); escape = false; inWord = true; continue }
            if ch == "\\" && quote != "'" { escape = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; inWord = true; continue }
            if ch.isWhitespace {
                if inWord { words.append(current); current = ""; inWord = false }
                continue
            }
            current.append(ch)
            inWord = true
        }
        if inWord { words.append(current) }
        return words
    }
}
