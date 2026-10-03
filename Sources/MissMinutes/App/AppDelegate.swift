import AppKit
import Combine
import MinutesBrain
import MinutesCharacter
import MinutesCore
import MinutesStage
import MinutesVoice

/// The composition root: builds every module, wires their ports together and
/// owns their lifetimes. No behaviour lives here; that is the Director's job.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SettingsStore()
    private(set) var stage: Stage!
    private(set) var voice: SpeechEngine!
    private(set) var brain: ClaudeCodeBrain!
    private(set) var director: Director!
    private let bubble = BubbleController()
    private let bridge = BodyBridgeServer()
    private var menu: StatusMenuController!
    private var settingsWindow: SettingsWindowController?
    private var hotKey: HotKey?
    private var lastSettings = MinutesSettings()
    private var brainRestart: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        let settings = store.settings
        lastSettings = settings

        let stage = Stage(settings: settings.character)
        let voice = SpeechEngine(settings: settings.voice)
        let brain = ClaudeCodeBrain(resumeSessionID: settings.brain.rememberConversation ? store.lastSessionID : nil) { [unowned self] resume in
            try self.launchPlan(resume: resume)
        }
        let puppet = Puppet(animator: stage.animator) { [weak stage] in stage?.directionToCursor() ?? CGPoint(x: 1, y: 0) }
        let director = Director(character: puppet, stage: stage, bubble: bubble, voice: voice, brain: brain,
                                screenshots: ScreenCapturer(), scheduler: MainQueueScheduler(),
                                settings: { [unowned self] in self.store.settings })
        self.stage = stage
        self.voice = voice
        self.brain = brain
        self.director = director

        stage.mouthProvider = { [weak voice] in voice?.mouth() }
        stage.onFrameEnd = { [weak bubble] head in bubble?.follow(head) }
        brain.onSession = { [weak self] id in
            guard let self, self.store.settings.brain.rememberConversation else { return }
            self.store.lastSessionID = id
        }
        director.onOpenSettings = { [weak self] in self?.openSettings() }
        director.onAlert = { NSSound(named: "Glass")?.play() }
        bridge.handler = { [weak self] tool, args, reply in
            guard let self else { return }
            do {
                self.director.handle(body: try BodyCommand.decode(tool: tool, args: args), reply: reply)
            } catch {
                reply(.error(String(describing: error)))
            }
        }

        menu = StatusMenuController(app: self)
        hotKey = HotKey(keyCode: HotKey.keyM, modifiers: HotKey.controlOption) { [weak self] in self?.director.summon() }

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.localizedName }
            .sink { [weak self] app in self?.director.frontAppChanged(app) }
            .store(in: &cancellables)
        store.$settings
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] new in self?.settingsChanged(new) }
            .store(in: &cancellables)

        // Resolve the login-shell PATH off the main thread, then bring up the
        // body bridge and the brain so the first question is answered quickly.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = ExecutableLocator.loginPATH
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.bridge.start { _ in self.brain.start() }
                }
            }
        }
        director.start()
    }

    /// `missminutes://ask?q=…`, `…://summon`, `…://show`, `…://hide`, `…://settings`:
    /// lets Shortcuts, Raycast, Alfred or a script talk to her.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "missminutes" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "q" || $0.name == "text" }?.value
            switch url.host {
            case "ask": if let query, !query.isEmpty { director.ask(query) } else { director.summon() }
            case "summon": director.summon()
            case "show": stage.appear()
            case "hide": stage.vanish()
            case "settings": openSettings()
            default: break
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        brain?.stop()
        bridge.stop()
    }

    // MARK: Actions (menu, settings window)

    func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(app: self) }
        settingsWindow?.show()
    }

    func restartBrain(fresh: Bool) {
        if fresh { director.newConversation() } else { brain.restart(fresh: false) }
    }

    // MARK: Wiring

    private func settingsChanged(_ new: MinutesSettings) {
        let old = lastSettings
        lastSettings = new
        if new.character != old.character { stage.apply(new.character) }
        if new.voice != old.voice { voice.apply(new.voice) }
        if !new.voice.enabled { voice.stop() }
        if !new.brain.rememberConversation { store.lastSessionID = nil }
        if new.brain != old.brain {
            // Debounced: typing in the persona field shouldn't restart Claude Code per keystroke.
            brainRestart?.cancel()
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.brain.restart(fresh: false) } }
            brainRestart = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }
        director.settingsChanged()
    }

    private func launchPlan(resume: String?) throws -> ClaudeLaunchPlan {
        let s = store.settings.brain
        guard let claude = ExecutableLocator.claude(override: s.claudePath) else {
            throw BrainError.notFound(s.claudePath.isEmpty
                ? "I can't find Claude Code (`claude`) on this Mac. Install it, or set its path in Settings ▸ Brain."
                : "There's no executable at \(s.claudePath). Check Settings ▸ Brain.")
        }
        var body: BodyBridgeLaunch?
        if let port = bridge.port, let node = ExecutableLocator.node(override: s.nodePath), let script = Self.bridgeScript() {
            body = BodyBridgeLaunch(nodePath: node, scriptPath: script, port: port, token: bridge.token)
        }
        return ClaudeLaunchPlanner.make(
            settings: s, executable: claude, persona: s.persona.isEmpty ? Persona.builtIn : s.persona,
            bridge: body, resumeSessionID: resume, baseEnvironment: ProcessInfo.processInfo.environment,
            loginPATH: ExecutableLocator.loginPATH, home: NSHomeDirectory(),
            defaultWorkingDirectory: Self.workspace().path
        )
    }

    /// Her own working folder: ~/Library/Application Support/Claude Miss Minutes/Workspace.
    static func workspace() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Claude Miss Minutes/Workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The MCP bridge script: bundled in the .app, or straight from the source tree under `swift run`.
    static func bridgeScript() -> String? {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bridge/miss-minutes-mcp.mjs").path, fm.fileExists(atPath: bundled) {
            return bundled
        }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("bridge/miss-minutes-mcp.mjs").path
        return fm.fileExists(atPath: source) ? source : nil
    }

    var bodyBridgeStatus: String {
        let s = store.settings.brain
        guard bridge.port != nil else { return "Body bridge: starting…" }
        guard let node = ExecutableLocator.node(override: s.nodePath) else { return "Body bridge: Node.js not found, so she can talk but not move on request." }
        guard Self.bridgeScript() != nil else { return "Body bridge: script missing from the app bundle." }
        return "Body bridge: ready (\(node))"
    }
}
