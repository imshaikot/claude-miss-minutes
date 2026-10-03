import Foundation

/// The modifier keys that matter to hold-to-talk.
public struct KeyModifiers: OptionSet, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let command = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)
    public static let function = KeyModifiers(rawValue: 1 << 4)
}

/// Recognises "hold ⌃ Control on its own to talk" from polled keyboard state.
///
/// Fed many times a second with the modifiers that are down and a running
/// count of other input (key presses, clicks, scrolls). Control alone, held
/// for `holdDelay`, opens her ears; letting go sends what she heard. Anything
/// else while Control is down (⌃C, ⌃-click, another modifier) means it was a
/// shortcut, not a request to talk, and nothing more happens until Control is
/// released.
public struct HoldToTalk {
    public enum Event: Equatable {
        case began, ended, cancelled
    }

    private enum State: Equatable {
        case idle
        case armed(since: TimeInterval, input: UInt64)
        case talking(input: UInt64)
        /// Control was part of a shortcut: wait until it is released.
        case blocked
    }

    public var holdDelay: TimeInterval
    private var state = State.idle

    public init(holdDelay: TimeInterval = 0.3) {
        self.holdDelay = holdDelay
    }

    public var isTalking: Bool {
        if case .talking = state { return true }
        return false
    }

    /// `input` is only read while Control is down, so polling stays cheap.
    public mutating func update(time: TimeInterval, modifiers: KeyModifiers, input: @autoclosure () -> UInt64) -> Event? {
        let controlOnly = modifiers == .control
        let controlDown = modifiers.contains(.control)
        switch state {
        case .idle:
            if controlOnly {
                state = .armed(since: time, input: input())
            } else if controlDown {
                state = .blocked
            }
            return nil

        case let .armed(since, count):
            if !controlDown {
                state = .idle
            } else if !controlOnly || input() != count {
                state = .blocked
            } else if time - since >= holdDelay {
                state = .talking(input: count)
                return .began
            }
            return nil

        case let .talking(count):
            if !controlDown {
                state = .idle
                return .ended
            }
            if !controlOnly || input() != count {
                state = .blocked
                return .cancelled
            }
            return nil

        case .blocked:
            if !controlDown { state = .idle }
            return nil
        }
    }

    /// Forget any hold in progress (the feature was switched off). Returns
    /// `.cancelled` if she was listening.
    public mutating func reset() -> Event? {
        defer { state = .idle }
        return isTalking ? .cancelled : nil
    }
}
