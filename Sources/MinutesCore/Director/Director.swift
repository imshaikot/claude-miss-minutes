import CoreGraphics
import Foundation

/// Idle fidgets per posture, as data: (gesture, weight).
public enum IdleFidgets {
    public static func table(for posture: Posture) -> [(GestureName, Double)] {
        switch posture {
        case .stand: return [(.lookAround, 3), (.tapFoot, 1), (.stretch, 1), (.nod, 0.5)]
        case .sit: return [(.lookAround, 3), (.stretch, 1), (.nod, 0.6)]
        case .float: return [(.lookAround, 3), (.stretch, 0.8), (.blowKiss, 0.3)]
        }
    }

    public static func pick(for posture: Posture, roll: Double) -> GestureName {
        let table = table(for: posture)
        var r = roll * table.reduce(0) { $0 + $1.1 }
        for (gesture, weight) in table {
            r -= weight
            if r <= 0 { return gesture }
        }
        return table[0].0
    }
}

/// The behaviour layer: turns brain, voice, stage and bubble events into what
/// she does next. It owns the conversation phase and the idle life (wandering,
/// fidgets, reminders) and talks to everything else through ports only.
@MainActor
public final class Director {
    public enum Phase: Equatable {
        case idle, listening, thinking, speaking, asking
    }

    public private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onPhaseChange?(phase) } }
    }
    public var onPhaseChange: ((Phase) -> Void)?
    public var onOpenSettings: (() -> Void)?
    /// Plays an attention sound (reminders).
    public var onAlert: (() -> Void)?

    private let character: CharacterPort
    private let stage: StagePort
    private let bubble: BubblePort
    private let voice: VoicePort
    private let brain: BrainPort
    private let screenshots: ScreenshotPort?
    private let scheduler: Scheduler
    private let settings: () -> MinutesSettings
    private let now: () -> Date
    private let random: () -> Double

    private var reply = ""
    private var sentences = SentenceStream()
    private var turnDone = true
    private var pendingPermission: PermissionRequest?
    private var wanderTask: ScheduledTask?
    private var fidgetTask: ScheduledTask?
    private var moodTask: ScheduledTask?
    private var reminders: [UUID: ScheduledTask] = [:]
    private var hiddenForShyApp = false

    public init(character: CharacterPort, stage: StagePort, bubble: BubblePort, voice: VoicePort, brain: BrainPort,
                screenshots: ScreenshotPort?, scheduler: Scheduler, settings: @escaping () -> MinutesSettings,
                now: @escaping () -> Date = Date.init, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.character = character
        self.stage = stage
        self.bubble = bubble
        self.voice = voice
        self.brain = brain
        self.screenshots = screenshots
        self.scheduler = scheduler
        self.settings = settings
        self.now = now
        self.random = random

        stage.onEvent = { [weak self] in self?.handle(stage: $0) }
        bubble.onEvent = { [weak self] in self?.handle(bubble: $0) }
        brain.onEvent = { [weak self] in self?.handle(brain: $0) }
        voice.onFinished = { [weak self] in self?.voiceFinished() }
    }

    // MARK: Lifecycle

    public func start() {
        stage.appear()
        scheduler.after(1.0) { [weak self] in
            guard let self else { return }
            self.character.setMood(.happy)
            self.character.play(.wave)
            let greeting = Lines.pick(Lines.greetings)
            self.bubble.showNotice(greeting, actions: [], autoHide: 4.5)
            self.say(greeting)
        }
        scheduleWander()
        scheduleFidget()
    }

    /// Hotkey, menu item or a click on her: open the input bubble.
    public func summon() {
        if !stage.isVisible { stage.appear() }
        switch phase {
        case .asking:
            if let pendingPermission { bubble.showPermission(pendingPermission) }
        case .thinking:
            bubble.showThinking(Lines.pick(Lines.thinking))
        case .speaking:
            stopTalking()
            listen()
        case .idle, .listening:
            listen()
        }
    }

    public func stopTalking() {
        brain.interrupt()
        voice.stop()
        sentences = SentenceStream()
        turnDone = true
        pendingPermission = nil
        if phase != .idle && phase != .listening { finishTurn(hideAfter: 4) }
    }

    public func newConversation() {
        stopTalking()
        brain.restart(fresh: true)
        reply = ""
        character.play(.nod)
        bubble.showNotice("Fresh page! What's next, sugar?", actions: [], autoHide: 3)
    }

    public func toggleVisibility() {
        if stage.isVisible { stage.vanish() } else { stage.appear() }
    }

    public func frontAppChanged(_ app: String?) {
        let shy = settings().character.shyApps
        let isShy = app.map { name in shy.contains { $0.caseInsensitiveCompare(name) == .orderedSame } } ?? false
        if isShy, stage.isVisible, phase == .idle {
            hiddenForShyApp = true
            stage.vanish()
        } else if !isShy, hiddenForShyApp {
            hiddenForShyApp = false
            stage.appear()
        } else if !isShy, let app, phase == .idle, settings().character.wander, random() < 0.2 {
            // Sometimes she follows you to the app you just switched to.
            scheduler.after(1.5) { [weak self] in
                guard let self, self.phase == .idle, !self.stage.isTravelling else { return }
                self.stage.move(to: .app(app), style: .auto) { _ in }
            }
        }
    }

    public func settingsChanged() {
        scheduleWander()
    }

    // MARK: Conversation

    private func listen() {
        phase = .listening
        character.setActivity(.listen)
        character.setMood(.happy)
        bubble.showInput(placeholder: Lines.pick(Lines.listening))
    }

    /// Ask her something directly (URL scheme, Shortcuts, tests).
    public func ask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        wanderTask?.cancel()
        reply = ""
        sentences = SentenceStream()
        turnDone = false
        phase = .thinking
        character.setActivity(.think)
        character.setClock(.spin)
        bubble.showThinking(Lines.pick(Lines.thinking))
        let context = Persona.contextLine(date: now(), frontApp: stage.scene().frontApp)
        brain.send(context + "\n" + trimmed)
    }

    private func say(_ sentence: String) {
        guard settings().voice.enabled, !sentence.isEmpty else { return }
        voice.speak(sentence)
    }

    private func finishTurn(hideAfter: TimeInterval = 12) {
        phase = .idle
        character.setActivity(nil)
        character.setClock(.time)
        bubble.setStatus(nil)
        bubble.hide(after: hideAfter)
        scheduleWander()
    }

    private func voiceFinished() {
        if turnDone && phase == .speaking { finishTurn() }
    }

    // MARK: Event handlers

    func handle(bubble event: BubbleEvent) {
        switch event {
        case let .submitted(text):
            ask(text)
        case let .permissionAnswered(allow):
            guard let request = pendingPermission else { return }
            pendingPermission = nil
            brain.answer(request, allow: allow)
            phase = .thinking
            character.setActivity(.think)
            character.setClock(.spin)
            character.play(allow ? .nod : .shakeHead)
            bubble.showThinking(allow ? "On it…" : "Alright, I won't.")
        case let .action(name):
            switch name {
            case "Open Settings": onOpenSettings?()
            case "Thanks!": character.play(.blowKiss); bubble.hide(after: 0.6)
            default: bubble.hide(after: 0)
            }
        case .dismissed:
            if phase == .listening {
                phase = .idle
                character.setActivity(nil)
            }
        case .interrupt:
            stopTalking()
        }
    }

    func handle(brain event: BrainEvent) {
        switch event {
        case .started:
            break
        case let .textDelta(delta):
            guard phase != .idle, phase != .listening else { return }
            if phase != .speaking {
                phase = .speaking
                character.setActivity(.talk)
                character.setClock(.time)
                bubble.setStatus(nil)
            } else if pendingToolSpin {
                pendingToolSpin = false
                character.setActivity(.talk)
                character.setClock(.time)
                bubble.setStatus(nil)
            }
            reply += delta
            bubble.setReply(reply)
            for sentence in sentences.push(delta) { say(sentence) }
        case let .toolStarted(name, summary):
            guard !ToolSummary.isBodyTool(name) else { return }
            pendingToolSpin = true
            character.setActivity(.think)
            character.setClock(.spin)
            bubble.setStatus(summary)
        case .toolFinished:
            break
        case let .permissionRequested(request):
            pendingPermission = request
            phase = .asking
            character.setActivity(.ask)
            character.setClock(.time)
            bubble.showPermission(request)
            say("Mind if I \(request.tool == "Bash" ? "run a command" : "use \(request.tool)")?")
        case let .turnFinished(result):
            guard !turnDone else { return }
            turnDone = true
            pendingToolSpin = false
            for sentence in sentences.flush() { say(sentence) }
            if result.isError {
                character.setMood(.sad)
                let message = result.text.isEmpty ? "Something went sideways on my end." : result.text
                bubble.showNotice("Oh no: \(message)", actions: ["Open Settings"], autoHide: 10)
                finishTurn(hideAfter: 10)
                return
            }
            if reply.isEmpty, !result.text.isEmpty {
                reply = result.text
                bubble.setReply(reply)
                var stream = SentenceStream()
                for sentence in stream.push(result.text) + stream.flush() { say(sentence) }
                phase = .speaking
                character.setActivity(.talk)
            }
            if !voice.isSpeaking { finishTurn() }
        case let .failed(message):
            turnDone = true
            character.setMood(.sad)
            bubble.showNotice("My brain went quiet: \(message)", actions: ["Open Settings"], autoHide: nil)
            if phase != .idle { finishTurn(hideAfter: 30) }
        case let .exited(code, message):
            guard !turnDone || phase == .thinking || phase == .asking else { return }
            turnDone = true
            character.setMood(.sad)
            bubble.showNotice("Claude Code stopped (exit \(code)). \(message ?? "")", actions: ["Open Settings"], autoHide: nil)
            finishTurn(hideAfter: 30)
        }
    }

    private var pendingToolSpin = false

    func handle(stage event: StageEvent) {
        switch event {
        case .clicked:
            if phase == .listening, bubble.isOpen {
                bubble.hide(after: 0)
                handle(bubble: .dismissed)
            } else {
                summon()
            }
        case .dragStarted:
            wanderTask?.cancel()
        case .dropped:
            scheduleWander()
        case .fell:
            break
        case .landed:
            guard phase == .idle else { return }
            character.setMood(.annoyed)
            character.play(.shakeHead)
            if settings().character.quips { bubble.showNotice(Lines.pick(Lines.fell), actions: [], autoHide: 2.5) }
            moodTask?.cancel()
            moodTask = scheduler.after(2.5) { [weak self] in self?.character.setMood(.happy) }
        }
    }

    // MARK: Body tools

    public func handle(body command: BodyCommand, reply: @escaping (BodyReply) -> Void) {
        switch command {
        case let .emote(mood, gesture):
            if let mood { character.setMood(mood) }
            if let gesture { character.play(gesture) }
            reply(BodyReply(text: "Done."))

        case let .moveTo(target, style):
            if !stage.isVisible { stage.appear() }
            stage.move(to: target, style: style) { arrived in
                reply(arrived ? BodyReply(text: "Arrived.") : .error("There's no sensible spot for that right now (no such window, or no room)."))
            }

        case let .lookAtScreen(wantScreenshot):
            let summary = stage.scene().summary()
            guard wantScreenshot else { reply(BodyReply(text: summary)); return }
            guard settings().brain.letHerSeeScreen, let screenshots else {
                reply(BodyReply(text: summary + "\n(Screenshots are turned off in Miss Minutes' settings.)"))
                return
            }
            character.play(.lookAround)
            screenshots.capture(maxWidth: 1400) { image in
                if let image {
                    reply(BodyReply(text: summary, imageBase64: image, imageMIME: "image/jpeg"))
                } else {
                    reply(BodyReply(text: summary + "\n(No screenshot: macOS has not granted Screen Recording permission to Miss Minutes.)"))
                }
            }

        case let .setReminder(seconds, message):
            let id = UUID()
            reminders[id] = scheduler.after(seconds) { [weak self] in
                self?.reminders[id] = nil
                self?.reminderFired(message)
            }
            let due = now().addingTimeInterval(seconds)
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            reply(BodyReply(text: "Reminder set for \(formatter.string(from: due))."))
        }
    }

    public var pendingReminderCount: Int { reminders.count }

    private func reminderFired(_ message: String) {
        if !stage.isVisible { stage.appear() }
        onAlert?()
        stage.move(to: .cursor, style: .teleport) { [weak self] _ in
            guard let self else { return }
            self.character.setMood(.excited)
            self.character.play(.ring)
            self.bubble.showNotice(message, actions: ["Thanks!"], autoHide: nil)
            self.say(message)
        }
    }

    // MARK: Idle life

    private func scheduleWander() {
        wanderTask?.cancel()
        let config = settings().character
        guard config.wander else { return }
        let range = config.wanderInterval
        let delay = range.lowerBound + random() * (range.upperBound - range.lowerBound)
        wanderTask = scheduler.after(delay) { [weak self] in
            guard let self else { return }
            if self.phase == .idle, self.stage.isVisible, !self.stage.isTravelling, !self.bubble.isOpen {
                self.stage.move(to: .random, style: .auto) { _ in }
            }
            self.scheduleWander()
        }
    }

    private func scheduleFidget() {
        fidgetTask?.cancel()
        fidgetTask = scheduler.after(12 + random() * 20) { [weak self] in
            guard let self else { return }
            if self.phase == .idle, self.stage.isVisible, !self.stage.isTravelling {
                let posture = self.stage.currentPerch?.posture ?? .stand
                self.character.play(IdleFidgets.pick(for: posture, roll: self.random()))
            }
            self.scheduleFidget()
        }
    }
}
