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
    func showPermission(_ request: PermissionRequest)
    func showNotice(_ text: String, actions: [String], autoHide: TimeInterval?)
    func hide(after delay: TimeInterval)
}

@MainActor
public protocol VoicePort: AnyObject {
    var onFinished: (() -> Void)? { get set }
    var isSpeaking: Bool { get }
    func speak(_ sentence: String)
    func stop()
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
