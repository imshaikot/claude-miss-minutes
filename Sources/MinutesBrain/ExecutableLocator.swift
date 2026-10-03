import Foundation
import MinutesCore

/// Finds command-line tools for a GUI app, which does not inherit the shell's PATH.
public enum ExecutableLocator {
    /// The user's login-shell PATH, resolved once (with a timeout so a slow shell config can't hang us).
    public static let loginPATH: String? = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // Login (not interactive) shell: picks up Homebrew & co. from .zprofile without running .zshrc.
        process.arguments = ["-lc", "printf '__MM_PATH__%s__MM_END__' \"$PATH\""]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        if done.wait(timeout: .now() + 4) == .timedOut {
            process.terminate()
            return nil
        }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let start = text.range(of: "__MM_PATH__"), let end = text.range(of: "__MM_END__", range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }()

    public static func find(_ name: String, override: String, candidates: [String]) -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        if !override.isEmpty {
            let path = ClaudeLaunchPlanner.expandTilde(override, home: home)
            return fm.isExecutableFile(atPath: path) ? path : nil
        }
        let pathDirs = ((loginPATH ?? "") + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""))
            .split(separator: ":").map(String.init)
        for dir in pathDirs where !dir.isEmpty {
            let path = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: path) { return path }
        }
        for candidate in candidates {
            let path = ClaudeLaunchPlanner.expandTilde(candidate, home: home)
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    public static func claude(override: String) -> String? {
        find("claude", override: override, candidates: [
            "~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ])
    }

    public static func node(override: String) -> String? {
        var candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "~/.volta/bin/node", "~/.local/bin/node"]
        let nvm = NSHomeDirectory() + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            candidates += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin/node" }
        }
        return find("node", override: override, candidates: candidates)
    }
}
