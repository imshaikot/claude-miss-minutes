import CoreGraphics
import Foundation
import Testing
@testable import MinutesCore

// MARK: Fakes

@MainActor private final class FakeCharacter: CharacterPort {
    var moods: [Mood] = [], gestures: [GestureName] = [], activities: [Activity?] = [], clocks: [ClockMode] = []
    func setMood(_ mood: Mood) { moods.append(mood) }
    func play(_ gesture: GestureName) { gestures.append(gesture) }
    func setActivity(_ activity: Activity?) { activities.append(activity) }
    func setClock(_ mode: ClockMode) { clocks.append(mode) }
}

@MainActor private final class FakeStage: StagePort {
    var onEvent: ((StageEvent) -> Void)?
    var isVisible = true
    var isTravelling = false
    var currentPerch: Perch?
    var moves: [MoveTarget] = []
    var snapshot = SceneSnapshot(screens: [], windows: [], frontApp: "Safari")
    func appear() { isVisible = true }
    func vanish() { isVisible = false }
    func move(to target: MoveTarget, style: TravelStyle, completion: @escaping (Bool) -> Void) { moves.append(target); completion(true) }
    func scene() -> SceneSnapshot { snapshot }
}

@MainActor private final class FakeBubble: BubblePort {
    var onEvent: ((BubbleEvent) -> Void)?
    var isOpen = false
    var log: [String] = []
    var reply = ""
    var permissionVoice = PermissionVoice()
    func showInput(placeholder: String) { isOpen = true; log.append("input") }
    func showThinking(_ status: String) { isOpen = true; log.append("thinking") }
    func setStatus(_ status: String?) { log.append("status:\(status ?? "-")") }
    func setReply(_ text: String) { isOpen = true; reply = text }
    func showHearing(_ transcript: String, placeholder: String) { isOpen = true; log.append("hearing:\(transcript)") }
    func showPermission(_ request: PermissionRequest, voice: PermissionVoice) {
        isOpen = true
        log.append("permission:\(request.tool)")
        permissionVoice = voice
    }
    func showNotice(_ text: String, actions: [String], autoHide: TimeInterval?) { isOpen = true; log.append("notice:\(text)") }
    func hide(after delay: TimeInterval) { log.append("hide") }
}

@MainActor private final class FakeVoice: VoicePort {
    var onFinished: (() -> Void)?
    var isSpeaking = false
    var spoken: [String] = []
    func speak(_ sentence: String) { spoken.append(sentence); isSpeaking = true }
    func stop() { isSpeaking = false }
    func finish() { isSpeaking = false; onFinished?() }
}

@MainActor private final class FakeEars: EarsPort {
    var onEvent: ((HearingEvent) -> Void)?
    var isAuthorized = true
    var log: [String] = []
    func start(_ hint: HearingHint) { log.append(hint == .dictation ? "start" : "start:yesOrNo") }
    func finish() { log.append("finish") }
    func cancel() { log.append("cancel") }
}

@MainActor private final class FakeBrain: BrainPort {
    var onEvent: ((BrainEvent) -> Void)?
    var status = BrainStatus.ready
    var sent: [String] = []
    var answers: [Bool] = []
    var interrupts = 0
    var restarts: [Bool] = []
    func send(_ text: String) { sent.append(text) }
    func answer(_ request: PermissionRequest, allow: Bool) { answers.append(allow) }
    func interrupt() { interrupts += 1 }
    func restart(fresh: Bool) { restarts.append(fresh) }
}

/// Runs scheduled work only when told to.
@MainActor private final class ManualScheduler: Scheduler {
    var queue: [(delay: TimeInterval, action: @MainActor () -> Void, cancelled: Bool)] = []
    func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledTask {
        queue.append((delay, action, false))
        let index = queue.count - 1
        return ScheduledTask { [weak self] in self?.queue[index].cancelled = true }
    }
    func runAll(maxDelay: TimeInterval = .infinity) {
        let pending = queue.enumerated().filter { !$0.element.cancelled && $0.element.delay <= maxDelay }
        for (index, _) in pending { queue[index].cancelled = true }
        for (_, item) in pending { item.action() }
    }
}

@MainActor
private struct Rig {
    let character = FakeCharacter(), stage = FakeStage(), bubble = FakeBubble(), voice = FakeVoice(), brain = FakeBrain(), ears = FakeEars()
    let scheduler = ManualScheduler()
    var settings = MinutesSettings()
    let director: Director

    init(voice enabled: Bool = true) {
        settings.voice.enabled = enabled
        let frozen = settings
        director = Director(character: character, stage: stage, bubble: bubble, voice: voice, brain: brain, ears: ears, screenshots: nil,
                            scheduler: scheduler, settings: { frozen }, now: { Date(timeIntervalSince1970: 1_790_000_000) },
                            random: { 0.5 })
    }

    /// She asks "Mind if I run a command?" (and is still saying it).
    func askPermission() {
        bubble.onEvent?(.submitted("list my downloads"))
        brain.onEvent?(.permissionRequested(PermissionRequest(id: "r1", tool: "Bash", summary: "Run: ls", inputJSON: Data("{}".utf8))))
    }
}

// MARK: Tests

@MainActor
@Suite("Director")
struct DirectorTests {
    @Test func clickingHerOpensTheInputBubble() {
        let rig = Rig()
        rig.stage.onEvent?(.clicked)
        #expect(rig.bubble.log.isEmpty) // a second click may be on its way
        rig.scheduler.runAll(maxDelay: Director.doubleClickWait)
        #expect(rig.director.phase == .listening)
        #expect(rig.bubble.log.last == "input")
        #expect(rig.character.activities.last == .listen)
    }

    @Test func doubleClickingSendsHerAwayWithoutFlashingTheBubble() {
        let rig = Rig()
        rig.stage.onEvent?(.clicked)
        rig.stage.onEvent?(.doubleClicked)
        rig.scheduler.runAll()
        #expect(rig.stage.isVisible == false)
        #expect(!rig.bubble.log.contains("input"))
        #expect(rig.director.phase == .idle)
    }

    @Test func hidingCutsHerOffMidSentence() {
        let rig = Rig()
        rig.bubble.onEvent?(.submitted("tell me a long story"))
        rig.brain.onEvent?(.textDelta("Once upon a time. "))
        rig.stage.onEvent?(.doubleClicked)
        #expect(rig.brain.interrupts == 1)
        #expect(rig.voice.isSpeaking == false)
        #expect(rig.director.phase == .idle)
        #expect(rig.bubble.log.last == "hide")
        #expect(rig.stage.isVisible == false)
    }

    @Test func holdingControlBringsHerBackToListen() {
        let rig = Rig()
        rig.stage.onEvent?(.doubleClicked)
        #expect(rig.stage.isVisible == false)
        rig.director.holdToTalk(.began)
        #expect(rig.stage.isVisible)
        #expect(rig.director.phase == .hearing)
        #expect(rig.ears.log == ["start"])
    }

    @Test func aQuestionGoesToTheBrainWithContext() {
        let rig = Rig()
        rig.bubble.onEvent?(.submitted("  what's up?  "))
        #expect(rig.director.phase == .thinking)
        #expect(rig.brain.sent.count == 1)
        #expect(rig.brain.sent[0].hasPrefix("[Local time: "))
        #expect(rig.brain.sent[0].contains("frontmost app: Safari"))
        #expect(rig.brain.sent[0].hasSuffix("\nwhat's up?"))
        #expect(rig.character.clocks.last == .spin)
    }

    @Test func streamedTextIsShownAndSpokenSentenceBySentence() {
        let rig = Rig()
        rig.bubble.onEvent?(.submitted("hi"))
        rig.brain.onEvent?(.textDelta("Well hey! I'm "))
        #expect(rig.director.phase == .speaking)
        #expect(rig.character.activities.last == .talk)
        #expect(rig.voice.spoken == ["Well hey!"])
        rig.brain.onEvent?(.textDelta("all yours."))
        #expect(rig.bubble.reply == "Well hey! I'm all yours.")
        rig.brain.onEvent?(.turnFinished(TurnResult(text: "Well hey! I'm all yours.", isError: false)))
        #expect(rig.voice.spoken == ["Well hey!", "I'm all yours."])
        // Still talking: the turn ends when the voice does.
        #expect(rig.director.phase == .speaking)
        rig.voice.finish()
        #expect(rig.director.phase == .idle)
        #expect(rig.bubble.log.last == "hide")
    }

    @Test func silentModeFinishesWhenTheBrainDoes() {
        let rig = Rig(voice: false)
        rig.bubble.onEvent?(.submitted("hi"))
        rig.brain.onEvent?(.textDelta("Done."))
        rig.brain.onEvent?(.turnFinished(TurnResult(text: "Done.", isError: false)))
        #expect(rig.voice.spoken.isEmpty)
        #expect(rig.director.phase == .idle)
    }

    @Test func permissionQuestionsRoundTripThroughTheBubble() {
        let rig = Rig()
        rig.bubble.onEvent?(.submitted("list my downloads"))
        let request = PermissionRequest(id: "r1", tool: "Bash", summary: "Run: ls", inputJSON: Data("{}".utf8))
        rig.brain.onEvent?(.permissionRequested(request))
        #expect(rig.director.phase == .asking)
        #expect(rig.bubble.log.last == "permission:Bash")
        #expect(rig.character.activities.last == .ask)
        rig.bubble.onEvent?(.permissionAnswered(allow: true))
        #expect(rig.brain.answers == [true])
        #expect(rig.director.phase == .thinking)
        #expect(rig.character.gestures.last == .nod)
    }

    @Test func herOwnBodyToolsDoNotShowAsStatus() {
        let rig = Rig()
        rig.bubble.onEvent?(.submitted("wave"))
        rig.brain.onEvent?(.toolStarted(name: "mcp__minutes__emote", summary: "emote"))
        #expect(!rig.bubble.log.contains { $0.hasPrefix("status:emote") })
        rig.brain.onEvent?(.toolStarted(name: "WebSearch", summary: "Search the web for weather"))
        #expect(rig.bubble.log.last == "status:Search the web for weather")
    }

    @Test func escapeInterruptsTheBrainAndTheVoice() {
        let rig = Rig()
        rig.bubble.onEvent?(.submitted("tell me a long story"))
        rig.brain.onEvent?(.textDelta("Once upon a time. "))
        rig.bubble.onEvent?(.interrupt)
        #expect(rig.brain.interrupts == 1)
        #expect(rig.voice.isSpeaking == false)
        #expect(rig.director.phase == .idle)
    }

    @Test func brainFailuresAreToldKindly() {
        let rig = Rig()
        rig.bubble.onEvent?(.submitted("hi"))
        rig.brain.onEvent?(.failed("I can't find Claude Code"))
        #expect(rig.director.phase == .idle)
        #expect(rig.character.moods.last == .sad)
        #expect(rig.bubble.log.contains("notice:My brain went quiet: I can't find Claude Code"))
    }

    @Test func bodyCommandsDriveTheCharacterAndReply() {
        let rig = Rig()
        var replies: [BodyReply] = []
        rig.director.handle(body: .emote(mood: .excited, gesture: .jump)) { replies.append($0) }
        rig.director.handle(body: .moveTo(.app("Safari"), style: .auto)) { replies.append($0) }
        rig.director.handle(body: .lookAtScreen(screenshot: false)) { replies.append($0) }
        #expect(rig.character.moods.last == .excited)
        #expect(rig.character.gestures.last == .jump)
        #expect(rig.stage.moves == [.app("Safari")])
        #expect(replies.map(\.text).prefix(2) == ["Done.", "Arrived."])
        #expect(replies[2].text.contains("Frontmost app: Safari"))
    }

    @Test func remindersRingWhenTheyFire() {
        let rig = Rig()
        var reply: BodyReply?
        rig.director.handle(body: .setReminder(seconds: 600, message: "Stretch, sugar!")) { reply = $0 }
        #expect(reply?.text.hasPrefix("Reminder set for") == true)
        #expect(rig.director.pendingReminderCount == 1)
        rig.scheduler.runAll(maxDelay: 600)
        #expect(rig.stage.moves.last == .cursor)
        #expect(rig.character.gestures.last == .ring)
        #expect(rig.voice.spoken.last == "Stretch, sugar!")
        #expect(rig.director.pendingReminderCount == 0)
    }

    @Test func aFallEarnsAQuip() {
        let rig = Rig()
        rig.stage.onEvent?(.landed)
        #expect(rig.character.gestures.last == .shakeHead)
        #expect(rig.bubble.log.last?.hasPrefix("notice:") == true)
    }

    @Test func holdingControlDictatesAQuestion() {
        let rig = Rig()
        rig.director.holdToTalk(.began)
        #expect(rig.director.phase == .hearing)
        #expect(rig.ears.log == ["start"])
        #expect(rig.character.activities.last == .listen)
        rig.ears.onEvent?(.partial("what's the"))
        #expect(rig.bubble.log.last == "hearing:what's the")
        rig.director.holdToTalk(.ended)
        #expect(rig.ears.log == ["start", "finish"])
        #expect(rig.brain.sent.isEmpty)
        rig.ears.onEvent?(.final(" what's the time in Rome "))
        #expect(rig.director.phase == .thinking)
        #expect(rig.brain.sent.count == 1)
        #expect(rig.brain.sent[0].hasSuffix("\nwhat's the time in Rome"))
    }

    @Test func holdingControlCutsHerOff() {
        let rig = Rig()
        rig.bubble.onEvent?(.submitted("tell me a long story"))
        rig.brain.onEvent?(.textDelta("Once upon a time. "))
        #expect(rig.voice.isSpeaking)
        rig.director.holdToTalk(.began)
        #expect(rig.brain.interrupts == 1)
        #expect(rig.voice.isSpeaking == false)
        #expect(rig.director.phase == .hearing)
        // The interrupted turn's tail is not spoken over you.
        rig.brain.onEvent?(.textDelta("There was a clock. "))
        #expect(rig.voice.spoken == ["Once upon a time."])
    }

    @Test func nothingHeardSendsNothing() {
        let rig = Rig()
        rig.director.holdToTalk(.began)
        rig.director.holdToTalk(.ended)
        rig.ears.onEvent?(.final("  "))
        #expect(rig.brain.sent.isEmpty)
        #expect(rig.director.phase == .idle)
        #expect(rig.bubble.log.last?.hasPrefix("notice:") == true)
    }

    @Test func aShortcutAfterAllCancelsQuietly() {
        let rig = Rig()
        rig.director.holdToTalk(.began)
        rig.director.holdToTalk(.cancelled)
        #expect(rig.ears.log == ["start", "cancel"])
        #expect(rig.director.phase == .idle)
        #expect(rig.bubble.log.last == "hide")
        // A late result from the cancelled recognition is ignored.
        rig.ears.onEvent?(.final("ctrl c"))
        #expect(rig.brain.sent.isEmpty)
    }

    @Test func holdingControlAnswersAPermissionQuestion() {
        let rig = Rig()
        rig.askPermission()
        #expect(rig.bubble.permissionVoice.note == "Or hold ⌃ and say yes or no")
        rig.director.holdToTalk(.began)
        #expect(rig.director.phase == .asking)
        #expect(rig.ears.log == ["start:yesOrNo"])
        #expect(rig.voice.isSpeaking == false) // she must not hear herself
        #expect(rig.bubble.permissionVoice.heard == "")
        rig.ears.onEvent?(.partial("Yeah, go"))
        rig.scheduler.runAll(maxDelay: 1)
        // Held, the answer is what was said when ⌃ is let go.
        #expect(rig.brain.answers.isEmpty)
        #expect(rig.bubble.permissionVoice.heard == "Yeah, go")
        rig.director.holdToTalk(.ended)
        #expect(rig.ears.log.last == "finish")
        rig.ears.onEvent?(.final("Yeah, go ahead."))
        #expect(rig.brain.answers == [true])
        #expect(rig.director.phase == .thinking)
        #expect(rig.character.gestures.last == .nod)
    }

    @Test func aMuddledAnswerIsAskedAgain() {
        let rig = Rig()
        rig.askPermission()
        rig.director.holdToTalk(.began)
        rig.director.holdToTalk(.ended)
        rig.ears.onEvent?(.final("Hmm, maybe later"))
        #expect(rig.brain.answers.isEmpty)
        #expect(rig.director.phase == .asking)
        #expect(rig.character.gestures.last == .shrug)
        #expect(Lines.yesOrNo.contains(rig.voice.spoken.last ?? ""))
        #expect(rig.bubble.permissionVoice.note == rig.voice.spoken.last)
        // Once she has asked again, she listens again.
        rig.voice.finish()
        #expect(rig.ears.log == ["start:yesOrNo", "finish", "start:yesOrNo"])
    }

    @Test func afterAskingSheListensForAYesOrNo() {
        let rig = Rig()
        rig.askPermission()
        #expect(rig.ears.log.isEmpty) // not while she is still asking
        rig.voice.finish()
        #expect(rig.ears.log == ["start:yesOrNo"])
        #expect(rig.bubble.permissionVoice.heard == "")
        // "No…" then "…problem": she waits for the whole answer.
        rig.ears.onEvent?(.partial("No"))
        rig.ears.onEvent?(.partial("No problem"))
        rig.scheduler.runAll(maxDelay: 1)
        #expect(rig.brain.answers == [true])
        #expect(rig.ears.log == ["start:yesOrNo", "cancel"])
    }

    @Test func handsFreeEarsCloseQuietlyWithoutAClearAnswer() {
        let rig = Rig()
        rig.askPermission()
        rig.voice.finish()
        let spoken = rig.voice.spoken
        rig.ears.onEvent?(.partial("and then the"))
        rig.scheduler.runAll(maxDelay: Director.answerWindow)
        #expect(rig.ears.log == ["start:yesOrNo", "finish"])
        rig.ears.onEvent?(.final("and then the weather"))
        #expect(rig.brain.answers.isEmpty)
        #expect(rig.director.phase == .asking)
        #expect(rig.voice.spoken == spoken)
        #expect(rig.bubble.permissionVoice.heard == nil)
        rig.bubble.onEvent?(.permissionAnswered(allow: false))
        #expect(rig.brain.answers == [false])
    }

    @Test func clickingWhileSheListensClosesHerEars() {
        let rig = Rig()
        rig.askPermission()
        rig.voice.finish()
        rig.bubble.onEvent?(.permissionAnswered(allow: false))
        #expect(rig.brain.answers == [false])
        #expect(rig.ears.log == ["start:yesOrNo", "cancel"])
        #expect(rig.character.gestures.last == .shakeHead)
        // A late word from the closed ears changes nothing.
        rig.ears.onEvent?(.final("yes"))
        #expect(rig.brain.answers == [false])
    }

    @Test func handsFreeNeverRaisesTheMicrophonePrompt() {
        let rig = Rig()
        rig.ears.isAuthorized = false
        rig.askPermission()
        rig.voice.finish()
        #expect(rig.ears.log.isEmpty)
        // Holding ⌃ is asking to be heard, so that may prompt.
        rig.director.holdToTalk(.began)
        #expect(rig.ears.log == ["start:yesOrNo"])
    }

    @Test func aShortcutWhileAnsweringLeavesTheQuestion() {
        let rig = Rig()
        rig.askPermission()
        rig.director.holdToTalk(.began)
        rig.director.holdToTalk(.cancelled)
        #expect(rig.ears.log == ["start:yesOrNo", "cancel"])
        #expect(rig.director.phase == .asking)
        #expect(rig.bubble.log.last == "permission:Bash")
        #expect(rig.bubble.permissionVoice.heard == nil)
        #expect(rig.brain.answers.isEmpty)
    }

    @Test func earsThatCannotListenSayWhy() {
        let rig = Rig()
        rig.director.holdToTalk(.began)
        rig.ears.onEvent?(.unavailable("No microphone."))
        #expect(rig.director.phase == .idle)
        #expect(rig.bubble.log.last == "notice:No microphone.")
    }

    @Test func holdToTalkCanBeSwitchedOff() {
        var rig = Rig()
        rig.settings.listening.holdToTalk = false
        let settings = rig.settings
        let director = Director(character: rig.character, stage: rig.stage, bubble: rig.bubble, voice: rig.voice, brain: rig.brain,
                                ears: rig.ears, screenshots: nil, scheduler: rig.scheduler, settings: { settings })
        director.holdToTalk(.began)
        #expect(director.phase == .idle)
        #expect(rig.ears.log.isEmpty)
    }

    @Test func betweenConversationsSheStrollsAbout() {
        let rig = Rig()
        let settings = rig.settings
        let director = Director(character: rig.character, stage: rig.stage, bubble: rig.bubble, voice: rig.voice, brain: rig.brain,
                                screenshots: nil, scheduler: rig.scheduler, settings: { settings }, random: { 0.1 })
        director.start()
        rig.scheduler.runAll(maxDelay: 1)
        rig.bubble.isOpen = false // the greeting has faded
        // The first idle beat comes within seconds, not minutes.
        rig.scheduler.runAll(maxDelay: settings.character.idleInterval.upperBound)
        #expect(rig.stage.moves == [.stroll])
    }

    @Test func switchingAppsOftenTakesHerAlong() {
        let rig = Rig()
        let settings = rig.settings
        let director = Director(character: rig.character, stage: rig.stage, bubble: rig.bubble, voice: rig.voice, brain: rig.brain,
                                screenshots: nil, scheduler: rig.scheduler, settings: { settings }, random: { 0.3 })
        director.frontAppChanged("Notes")
        rig.scheduler.runAll(maxDelay: 2)
        #expect(rig.stage.moves == [.explore(app: "Notes")])
    }

    @Test func shyAppsHideHerAndBringHerBack() {
        var rig = Rig()
        rig.settings.character.shyApps = ["zoom.us"]
        let settings = rig.settings
        let director = Director(character: rig.character, stage: rig.stage, bubble: rig.bubble, voice: rig.voice, brain: rig.brain,
                                screenshots: nil, scheduler: rig.scheduler, settings: { settings }, random: { 0.9 })
        director.frontAppChanged("zoom.us")
        #expect(rig.stage.isVisible == false)
        director.frontAppChanged("Safari")
        #expect(rig.stage.isVisible == true)
    }
}

@Suite("Idle life")
struct IdleLifeTests {
    @Test func aThirdOfTheBeatsAreStrollsWhenSheMayRoam() {
        #expect(IdleLife.beat(posture: .sit, roaming: true, roll: 0.2) == .stroll)
        #expect(IdleLife.beat(posture: .sit, roaming: true, roll: 0.6) != .stroll)
        #expect(IdleLife.beat(posture: .sit, roaming: false, roll: 0.2) != .stroll)
    }

    @Test func wanderingFavoursTheAppYouAreIn() {
        #expect(IdleLife.wander(frontApp: "Safari", roll: 0.3) == .explore(app: "Safari"))
        #expect(IdleLife.wander(frontApp: "Safari", roll: 0.9) == .random)
        #expect(IdleLife.wander(frontApp: nil, roll: 0.3) == .random)
    }

    @Test func hangingOnSheKeepsAHandFree() {
        // Nothing that needs both hands while she is holding on to an edge.
        let twoHanded: Set<GestureName> = [.clap, .shrug, .stretch, .jump, .ring, .dance, .bow, .tapFoot]
        for posture in [Posture.hang, .cling] {
            #expect(IdleFidgets.table(for: posture).allSatisfy { !twoHanded.contains($0.0) })
        }
    }

    @Test func restlessnessSpeedsUpTheBeats() {
        var calm = CharacterSettings(), busy = CharacterSettings()
        calm.restlessness = 0
        busy.restlessness = 1
        #expect(busy.idleInterval.upperBound < calm.idleInterval.lowerBound)
        #expect(busy.wanderInterval.upperBound < calm.wanderInterval.lowerBound)
    }
}
