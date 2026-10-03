import CoreGraphics
import Foundation

// The director talks to the rest of the app only through these ports. Each
// module implements one; tests implement them with fakes. Adding a capability
// means adding a port, not reaching into another module.

@MainActor
public protocol CharacterPort: AnyObject {
    func setMood(_ mood: Mood)
    func play(_ gesture: GestureName)
    func setActivity(_ activity: Activity?)
    func setClock(_ mode: ClockMode)
}

public enum StageEvent: Equatable {
    case clicked
    /// The second press of a double-click (its first click was reported already).
    case doubleClicked
    case dragStarted
    case dropped
    /// Her ledge vanished from under her.
    case fell
    /// Touched down after a fall or a drop.
    case landed
}

@MainActor
public protocol StagePort: AnyObject {
    var onEvent: ((StageEvent) -> Void)? { get set }
    var isVisible: Bool { get }
    var isTravelling: Bool { get }
    var currentPerch: Perch? { get }
    func appear()
    func vanish()
    func move(to target: MoveTarget, style: TravelStyle, completion: @escaping (Bool) -> Void)
    func scene() -> SceneSnapshot
}

public enum BubbleEvent: Equatable {
    case submitted(String)
    case permissionAnswered(allow: Bool)
    case action(String)
    case dismissed
    case interrupt
}

@MainActor
public protocol BubblePort: AnyObject {
    var onEvent: ((BubbleEvent) -> Void)? { get set }
    var isOpen: Bool { get }
    func showInput(placeholder: String)
    func showThinking(_ status: String)
    func setStatus(_ status: String?)
    func setReply(_ text: String)
    /// Hold-to-talk: what she has heard so far, or `placeholder` before the first word.
    func showHearing(_ transcript: String, placeholder: String)
    func showPermission(_ request: PermissionRequest, voice: PermissionVoice)
    func showNotice(_ text: String, actions: [String], autoHide: TimeInterval?)
    func hide(after delay: TimeInterval)
}

/// The spoken side of a permission bubble.
public struct PermissionVoice: Equatable {
    /// What she has heard of your answer so far ("" before the first word); nil while her ears are shut.
    public var heard: String?
    /// A line under the buttons: how to answer out loud, or why that didn't work.
    public var note: String?

    public init(heard: String? = nil, note: String? = nil) {
        self.heard = heard
        self.note = note
    }
}

@MainActor
public protocol VoicePort: AnyObject {
    var onFinished: (() -> Void)? { get set }
    var isSpeaking: Bool { get }
    func speak(_ sentence: String)
    func stop()
}

public enum HearingEvent: Equatable {
    /// The words so far, while you are still talking.
    case partial(String)
    /// Everything that was said, after `finish()` ("" when nothing was caught).
    case final(String)
    /// She can't listen (no permission, no microphone…). Shown in her bubble.
    case unavailable(String)
}

/// What she is listening for, so the recognizer can be tuned to it.
public enum HearingHint: Equatable {
    case dictation
    /// A short answer to a permission question.
    case yesOrNo
}

/// Speech to text for hold-to-talk and spoken permission answers.
@MainActor
public protocol EarsPort: AnyObject {
    var onEvent: ((HearingEvent) -> Void)? { get set }
    /// macOS already lets her listen, so `start` won't put up a permission prompt.
    var isAuthorized: Bool { get }
    func start(_ hint: HearingHint)
    /// Stop listening and report what was heard with `.final`.
    func finish()
    /// Stop listening and drop what was heard.
    func cancel()
}

@MainActor
public protocol BrainPort: AnyObject {
    var onEvent: ((BrainEvent) -> Void)? { get set }
    var status: BrainStatus { get }
    func send(_ text: String)
    func answer(_ request: PermissionRequest, allow: Bool)
    func interrupt()
    /// Restart the process (after a settings change); `fresh` drops the conversation.
    func restart(fresh: Bool)
}

@MainActor
public protocol ScreenshotPort: AnyObject {
    /// A downscaled JPEG of the main display, base64-encoded, or nil (no permission).
    func capture(maxWidth: Int, completion: @escaping (String?) -> Void)
}

public final class ScheduledTask {
    private let onCancel: () -> Void
    public init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() { onCancel() }
}

@MainActor
public protocol Scheduler: AnyObject {
    @discardableResult
    func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledTask
}

/// Main-queue scheduler used by the app.
@MainActor
public final class MainQueueScheduler: Scheduler {
    public init() {}

    @discardableResult
    public func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledTask {
        let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return ScheduledTask { item.cancel() }
    }
}
