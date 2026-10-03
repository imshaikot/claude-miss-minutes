import CoreGraphics
import Foundation
import MinutesCore
import QuartzCore

/// Watches for ⌃ Control held on its own, anywhere, and reports
/// `HoldToTalk` events.
///
/// Carbon can't register a modifier-only hotkey, and an event tap needs Input
/// Monitoring permission. Instead this polls what the window server tells
/// every app without asking: which modifiers are down, and how many key
/// presses, clicks and scrolls there have been (so ⌃C or ⌃-click is seen as a
/// shortcut, not a request to talk).
@MainActor
final class HoldKey {
    private var gesture = HoldToTalk()
    private var timer: Timer?
    private let onEvent: (HoldToTalk.Event) -> Void

    private static let otherInput: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]

    init(onEvent: @escaping (HoldToTalk.Event) -> Void) {
        self.onEvent = onEvent
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common) // keep watching while a menu is open
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let event = gesture.reset() { onEvent(event) }
    }

    private func poll() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        var modifiers: KeyModifiers = []
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        if let event = gesture.update(time: CACurrentMediaTime(), modifiers: modifiers, input: Self.inputCount()) {
            onEvent(event)
        }
    }

    private static func inputCount() -> UInt64 {
        otherInput.reduce(0) { $0 + UInt64(CGEventSource.counterForEventType(.combinedSessionState, eventType: $1)) }
    }
}
