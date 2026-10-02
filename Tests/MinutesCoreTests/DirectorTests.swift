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
    func showInput(placeholder: String) { isOpen = true; log.append("input") }
    func showThinking(_ status: String) { isOpen = true; log.append("thinking") }
    func setStatus(_ status: String?) { log.append("status:\(status ?? "-")") }
    func setReply(_ text: String) { isOpen = true; reply = text }
    func showPermission(_ request: PermissionRequest) { isOpen = true; log.append("permission:\(request.tool)") }
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
    let character = FakeCharacter(), stage = FakeStage(), bubble = FakeBubble(), voice = FakeVoice(), brain = FakeBrain()
    let scheduler = ManualScheduler()
    var settings = MinutesSettings()
    let director: Director

    init(voice enabled: Bool = true) {
        settings.voice.enabled = enabled
        let frozen = settings
        director = Director(character: character, stage: stage, bubble: bubble, voice: voice, brain: brain, screenshots: nil,
                            scheduler: scheduler, settings: { frozen }, now: { Date(timeIntervalSince1970: 1_790_000_000) },
                            random: { 0.5 })
    }
}

// MARK: Tests

@MainActor
@Suite("Director")
struct DirectorTests {
    @Test func clickingHerOpensTheInputBubble() {
        let rig = Rig()
        rig.stage.onEvent?(.clicked)
        #expect(rig.director.phase == .listening)
        #expect(rig.bubble.log.last == "input")
        #expect(rig.character.activities.last == .listen)
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
