import CoreGraphics
import Foundation

/// Idle fidgets per posture, as data: (gesture, weight). Hanging and clinging
/// she keeps at least one hand on the edge.
public enum IdleFidgets {
    public static func table(for posture: Posture) -> [(GestureName, Double)] {
        switch posture {
        case .stand: return [(.lookAround, 3), (.tapFoot, 1), (.stretch, 1), (.dance, 0.8), (.nod, 0.5)]
        case .sit: return [(.lookAround, 3), (.stretch, 1), (.nod, 0.6), (.wave, 0.4)]
        case .float: return [(.lookAround, 3), (.stretch, 0.8), (.dance, 0.5), (.blowKiss, 0.3)]
        case .hang: return [(.lookAround, 3), (.nod, 0.6), (.blowKiss, 0.4)]
        case .cling: return [(.lookAround, 3), (.nod, 0.8)]
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

/// What she does with herself between conversations, as data.
public enum IdleLife {
    public enum Beat: Equatable {
        case fidget(GestureName)
        /// A short way along whatever she is on: steps, a crawl, a climb, a shimmy.
        case stroll
    }

    /// A small beat: about a third are strolls when she may roam.
    public static func beat(posture: Posture, roaming: Bool, roll: Double) -> Beat {
        let strolls = 0.35
        guard roaming else { return .fidget(IdleFidgets.pick(for: posture, roll: roll)) }
        if roll < strolls { return .stroll }
        return .fidget(IdleFidgets.pick(for: posture, roll: (roll - strolls) / (1 - strolls)))
    }

    /// A bigger move: usually somewhere else on the app you are working in
    /// (its top, its sides, under it), otherwise anywhere.
    public static func wander(frontApp: String?, roll: Double) -> MoveTarget {
        frontApp != nil && roll < 0.6 ? .explore(app: frontApp) : .random
    }
}

/// The behaviour layer: turns brain, voice, stage and bubble events into what
/// she does next. It owns the conversation phase and the idle life (wandering,
/// fidgets, reminders) and talks to everything else through ports only.
@MainActor
public final class Director {
    public enum Phase: Equatable {
        /// `listening`: her input bubble is open for typing. `hearing`: ⌃ is held and she is taking dictation.
        case idle, listening, hearing, thinking, speaking, asking
    }

    /// Her ears while a permission question stands.
    private enum AnswerEars: Equatable {
        case closed
        /// Hands-free: they open once she has finished asking.
        case afterVoice
        /// `held`: while ⌃ is down; otherwise hands-free, for `answerWindow`.
        case open(held: Bool)

        var isOpen: Bool {
            if case .open = self { return true }
            return false
        }
    }

    /// Hands-free, how long her ears stay open after she asks, and how long a
    /// clear yes or no must stand before she acts on it ("no… problem!").
    static let answerWindow: TimeInterval = 8
    static let answerSettle: TimeInterval = 0.8
    /// How long a click on her waits for a second one before it opens her
    /// bubble, so a double-click doesn't flash it open first.
    static let doubleClickWait: TimeInterval = 0.25

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
    private let ears: EarsPort?
    private let screenshots: ScreenshotPort?
    private let scheduler: Scheduler
    private let settings: () -> MinutesSettings
    private let now: () -> Date
    private let random: () -> Double

    private var reply = ""
    private var sentences = SentenceStream()
    private var turnDone = true
    private var pendingPermission: PermissionRequest?
    private var answerEars = AnswerEars.closed
    private var answerHeard = ""
    private var answerSettle: ScheduledTask?
    private var answerWindow: ScheduledTask?
    private var wanderTask: ScheduledTask?
    private var idleTask: ScheduledTask?
    private var moodTask: ScheduledTask?
    private var clickTask: ScheduledTask?
    private var reminders: [UUID: ScheduledTask] = [:]
    private var hiddenForShyApp = false
    private var hearingPrompt = ""

    public init(character: CharacterPort, stage: StagePort, bubble: BubblePort, voice: VoicePort, brain: BrainPort,
                ears: EarsPort? = nil, screenshots: ScreenshotPort?, scheduler: Scheduler, settings: @escaping () -> MinutesSettings,
                now: @escaping () -> Date = Date.init, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.character = character
        self.stage = stage
        self.bubble = bubble
        self.voice = voice
        self.brain = brain
        self.ears = ears
        self.screenshots = screenshots
        self.scheduler = scheduler
        self.settings = settings
        self.now = now
        self.random = random

        stage.onEvent = { [weak self] in self?.handle(stage: $0) }
        bubble.onEvent = { [weak self] in self?.handle(bubble: $0) }
        brain.onEvent = { [weak self] in self?.handle(brain: $0) }
        voice.onFinished = { [weak self] in self?.voiceFinished() }
        ears?.onEvent = { [weak self] in self?.handle(ears: $0) }
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
        scheduleIdle()
    }

    /// Hotkey, menu item or a click on her: open the input bubble.
    public func summon() {
        if !stage.isVisible { stage.appear() }
        switch phase {
        case .asking:
            showPermission()
        case .thinking:
            bubble.showThinking(Lines.pick(Lines.thinking))
        case .speaking:
            stopTalking()
            listen()
        case .idle, .listening:
            listen()
        case .hearing:
            break
        }
    }

    public func stopTalking() {
        if phase == .hearing {
            ears?.cancel()
            phase = .idle
            character.setActivity(nil)
            bubble.hide(after: 0)
        }
        brain.interrupt()
        voice.stop()
        sentences = SentenceStream()
        turnDone = true
        closeAnswerEars()
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
        if stage.isVisible { hide() } else { stage.appear() }
    }

    /// Double-click or the menu: she drops whatever she was doing and twirls
    /// out of sight until she is called back (hold ⌃, ⌃⌥M, the menu).
    public func hide() {
        clickTask?.cancel()
        stopTalking()
        if phase == .listening { handle(bubble: .dismissed) }
        bubble.hide(after: 0)
        hiddenForShyApp = false
        stage.vanish()
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
        } else if !isShy, let app, phase == .idle, settings().character.wander, random() < 0.45 {
            // Often she follows you to the app you just switched to, onto whichever of its edges is free.
            scheduler.after(1.5) { [weak self] in
                guard let self, self.phase == .idle, !self.stage.isTravelling else { return }
                self.stage.move(to: .explore(app: app), style: .auto) { _ in }
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
        ask(text, status: Lines.pick(Lines.thinking))
    }

    /// `status` shows in the thinking bubble: a stock line, or what she heard you say.
    private func ask(_ text: String, status: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        wanderTask?.cancel()
        reply = ""
        sentences = SentenceStream()
        turnDone = false
        phase = .thinking
        character.setActivity(.think)
        character.setClock(.spin)
        bubble.showThinking(status)
        let context = Persona.contextLine(date: now(), frontApp: stage.scene().frontApp)
        brain.send(context + "\n" + trimmed)
    }

    private func say(_ sentence: String) {
        guard settings().voice.enabled, !sentence.isEmpty else { return }
        voice.speak(sentence)
    }

    private func finishTurn(hideAfter: TimeInterval = 12) {
        // A turn that ended under a question took the question with it.
        closeAnswerEars()
        pendingPermission = nil
        phase = .idle
        character.setActivity(nil)
        character.setClock(.time)
        bubble.setStatus(nil)
        bubble.hide(after: hideAfter)
        scheduleWander()
    }

    private func voiceFinished() {
        if turnDone && phase == .speaking { finishTurn() }
        if phase == .asking, answerEars == .afterVoice { openAnswerEars(held: false) }
    }

    // MARK: Hold to talk

    /// ⌃ held on its own (see `HoldToTalk`): she listens while it is down (out
    /// of hiding first, if she was hidden) and takes what she heard as your
    /// question when it is let go. Holding it while she talks or thinks cuts
    /// her off, like Esc. Holding it while she asks permission takes a yes or
    /// a no instead.
    public func holdToTalk(_ event: HoldToTalk.Event) {
        let answering = answerEars == .open(held: true)
        switch event {
        case .began:
            startHearing()
        case .ended:
            guard phase == .hearing || answering else { return }
            ears?.finish()
        case .cancelled:
            if answering {
                closeAnswerEars()
                character.setActivity(.ask)
                showPermission()
                return
            }
            guard phase == .hearing else { return }
            ears?.cancel()
            stopHearing()
            bubble.hide(after: 0)
        }
    }

    private func startHearing() {
        guard settings().listening.holdToTalk, let ears, phase != .hearing else { return }
        if phase == .asking {
            if pendingPermission != nil { openAnswerEars(held: true) }
            return
        }
        if !stage.isVisible { stage.appear() }
        if phase == .speaking || phase == .thinking {
            stopTalking()
        } else if voice.isSpeaking {
            voice.stop() // she must not hear herself
        }
        wanderTask?.cancel()
        phase = .hearing
        character.setActivity(.listen)
        character.setMood(.happy)
        hearingPrompt = Lines.pick(Lines.hearing)
        bubble.showHearing("", placeholder: hearingPrompt)
        ears.start(.dictation)
    }

    private func stopHearing() {
        phase = .idle
        character.setActivity(nil)
        scheduleWander()
    }

    func handle(ears event: HearingEvent) {
        if case let .open(held) = answerEars { return heardAnswer(event, held: held) }
        guard phase == .hearing else { return }
        switch event {
        case let .partial(text):
            bubble.showHearing(text, placeholder: hearingPrompt)
        case let .final(text):
            let heard = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if heard.isEmpty {
                stopHearing()
                character.play(.shrug)
                bubble.showNotice(Lines.pick(Lines.didntCatch), actions: [], autoHide: 2.5)
            } else {
                ask(heard, status: "“\(heard)”")
            }
        case let .unavailable(reason):
            stopHearing()
            bubble.showNotice(reason, actions: [], autoHide: 12)
        }
    }

    // MARK: Answering by voice

    // A permission question takes a spoken yes or no as well as a click: hold
    // ⌃ and say it, or just say it in the few seconds after she has asked.
    // Only a clear answer counts (`YesNo`); anything else leaves the buttons.

    /// Hands-free: once she has finished asking, her ears open for a while.
    /// Never the first time: macOS's own prompt shouldn't pop up mid-question.
    private func awaitSpokenAnswer() {
        guard settings().listening.handsFreeAnswers, ears?.isAuthorized == true else { return }
        answerEars = .afterVoice
        if !voice.isSpeaking { openAnswerEars(held: false) }
    }

    private func openAnswerEars(held: Bool) {
        guard let ears else { return }
        closeAnswerEars()
        if voice.isSpeaking { voice.stop() } // she must not hear herself
        answerEars = .open(held: held)
        answerHeard = ""
        if held { character.setActivity(.listen) }
        showPermission()
        if !held {
            answerWindow = scheduler.after(Self.answerWindow) { [weak self] in
                guard let self, self.answerEars == .open(held: false) else { return }
                self.ears?.finish()
            }
        }
        ears.start(.yesOrNo)
    }

    /// Shut her ears without taking an answer.
    private func closeAnswerEars() {
        if answerEars.isOpen { ears?.cancel() }
        answerEars = .closed
        answerSettle?.cancel()
        answerSettle = nil
        answerWindow?.cancel()
        answerWindow = nil
    }

    private func heardAnswer(_ event: HearingEvent, held: Bool) {
        switch event {
        case let .partial(text):
            answerHeard = text
            showPermission()
            // Held, the answer is whatever was said when ⌃ is let go.
            guard !held else { return }
            answerSettle?.cancel()
            answerSettle = nil
            if let allow = YesNo.parse(text) {
                answerSettle = scheduler.after(Self.answerSettle) { [weak self] in self?.answerPermission(allow) }
            }
        case let .final(text):
            answerEars = .closed // they have stopped by themselves
            closeAnswerEars()
            if let allow = YesNo.parse(text) { return answerPermission(allow) }
            character.setActivity(.ask)
            // Hands-free, the window just closes; held, she asks again.
            guard held else { return showPermission() }
            let line = Lines.pick(Lines.yesOrNo)
            character.play(.shrug)
            showPermission(note: line)
            say(line)
            awaitSpokenAnswer()
        case let .unavailable(reason):
            answerEars = .closed
            closeAnswerEars()
            character.setActivity(.ask)
            // Hands-free stays quiet about it: the question is what matters.
            showPermission(note: held ? reason : nil)
        }
    }

    private func answerPermission(_ allow: Bool) {
        guard let request = pendingPermission else { return }
        closeAnswerEars()
        pendingPermission = nil
        brain.answer(request, allow: allow)
        phase = .thinking
        character.setActivity(.think)
        character.setClock(.spin)
        character.play(allow ? .nod : .shakeHead)
        bubble.showThinking(allow ? "On it…" : "Alright, I won't.")
    }

    /// The permission bubble, with what she has heard of your answer and how to
    /// answer out loud (or `note`, when there is something else to say).
    private func showPermission(note: String? = nil) {
        guard let pendingPermission else { return }
        var voice = PermissionVoice()
        switch answerEars {
        case let .open(held):
            voice.heard = answerHeard
            if held { voice.note = "Let go of ⌃ to answer" }
        case .closed, .afterVoice:
            if settings().listening.holdToTalk, ears != nil { voice.note = "Or hold ⌃ and say yes or no" }
        }
        if let note { voice.note = note }
        bubble.showPermission(pendingPermission, voice: voice)
    }

    // MARK: Event handlers

    func handle(bubble event: BubbleEvent) {
        switch event {
        case let .submitted(text):
            ask(text)
        case let .permissionAnswered(allow):
            answerPermission(allow)
        case let .action(name):
            switch name {
            case "Open Settings": onOpenSettings?()
            case "Thanks!": character.play(.blowKiss); bubble.hide(after: 0.6)
            default:
                // Closed: no listening for an answer behind a hidden bubble.
                closeAnswerEars()
                bubble.hide(after: 0)
            }
        case .dismissed:
            if phase == .hearing { ears?.cancel() }
            if phase == .listening || phase == .hearing {
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
            guard phase != .idle, phase != .listening, phase != .hearing else { return }
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
            // Asked by a turn you just talked over: that turn is gone.
            guard phase != .hearing else { brain.answer(request, allow: false); return }
            closeAnswerEars()
            pendingPermission = request
            phase = .asking
            character.setActivity(.ask)
            character.setClock(.time)
            showPermission()
            say("Mind if I \(request.tool == "Bash" ? "run a command" : "use \(request.tool)")?")
            awaitSpokenAnswer()
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
            clickTask?.cancel()
            clickTask = scheduler.after(Self.doubleClickWait) { [weak self] in
                guard let self else { return }
                if self.phase == .listening, self.bubble.isOpen {
                    self.bubble.hide(after: 0)
                    self.handle(bubble: .dismissed)
                } else {
                    self.summon()
                }
            }
        case .doubleClicked:
            hide()
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
        // Not while she is listening to you: she would hear herself.
        guard phase != .hearing, !answerEars.isOpen else {
            scheduler.after(5) { [weak self] in self?.reminderFired(message) }
            return
        }
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
                let target = IdleLife.wander(frontApp: self.stage.scene().frontApp, roll: self.random())
                self.stage.move(to: target, style: .auto) { _ in }
            }
            self.scheduleWander()
        }
    }

    /// Small beats between the big moves, so she is never still for long.
    private func scheduleIdle() {
        idleTask?.cancel()
        let range = settings().character.idleInterval
        idleTask = scheduler.after(range.lowerBound + random() * (range.upperBound - range.lowerBound)) { [weak self] in
            guard let self else { return }
            if self.phase == .idle, self.stage.isVisible, !self.stage.isTravelling {
                let posture = self.stage.currentPerch?.posture ?? .stand
                let roaming = self.settings().character.wander && !self.bubble.isOpen
                switch IdleLife.beat(posture: posture, roaming: roaming, roll: self.random()) {
                case let .fidget(gesture): self.character.play(gesture)
                case .stroll: self.stage.move(to: .stroll, style: .auto) { _ in }
                }
            }
            self.scheduleIdle()
        }
    }
}
