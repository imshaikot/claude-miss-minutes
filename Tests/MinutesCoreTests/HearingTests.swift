import Foundation
import Testing
@testable import MinutesCore

/// Drives `HoldToTalk` through a script of polls, 30 per second like the app.
private struct Keyboard {
    var gesture = HoldToTalk(holdDelay: 0.3)
    var time: TimeInterval = 0
    var input: UInt64 = 0
    var events: [HoldToTalk.Event] = []

    mutating func hold(_ modifiers: KeyModifiers, for seconds: TimeInterval) {
        let end = time + seconds
        while time < end - 1e-9 {
            time += 1.0 / 30
            if let event = gesture.update(time: time, modifiers: modifiers, input: input) { events.append(event) }
        }
    }

    mutating func press() { input += 1 }
}

@Suite("Hold to talk")
struct HoldToTalkTests {
    @Test func holdingControlAloneTalksAndReleasingSends() {
        var k = Keyboard()
        k.hold([], for: 0.2)
        k.hold(.control, for: 1.5)
        #expect(k.events == [.began])
        k.hold([], for: 0.1)
        #expect(k.events == [.began, .ended])
    }

    @Test func aQuickTapDoesNothing() {
        var k = Keyboard()
        k.hold(.control, for: 0.2)
        k.hold([], for: 0.5)
        #expect(k.events.isEmpty)
    }

    @Test func controlShortcutsNeverStartListening() {
        var k = Keyboard()
        k.hold(.control, for: 0.1)
        k.press() // ⌃C
        k.hold(.control, for: 1.0)
        #expect(k.events.isEmpty)
        k.hold([], for: 0.1)
        // A later, clean hold still works.
        k.hold(.control, for: 0.5)
        #expect(k.events == [.began])
    }

    @Test func otherModifiersMeanAShortcut() {
        var k = Keyboard()
        k.hold([.control, .shift], for: 1.0)
        #expect(k.events.isEmpty)
        // Shift let go while Control stays down: still the same shortcut.
        k.hold(.control, for: 1.0)
        #expect(k.events.isEmpty)
    }

    @Test func aKeyPressWhileTalkingCancels() {
        var k = Keyboard()
        k.hold(.control, for: 0.6)
        k.press() // ⌃-click or ⌃A after all
        k.hold(.control, for: 0.3)
        k.hold([], for: 0.1)
        #expect(k.events == [.began, .cancelled])
    }

    @Test func addingAModifierWhileTalkingCancels() {
        var k = Keyboard()
        k.hold(.control, for: 0.6)
        k.hold([.control, .option], for: 0.2)
        #expect(k.events == [.began, .cancelled])
    }

    @Test func resetCancelsOnlyWhileTalking() {
        var idle = HoldToTalk()
        #expect(idle.reset() == nil)
        var k = Keyboard()
        k.hold(.control, for: 0.6)
        #expect(k.gesture.isTalking)
        #expect(k.gesture.reset() == .cancelled)
        #expect(!k.gesture.isTalking)
    }
}

@Suite("Yes or no")
struct YesNoTests {
    @Test(arguments: ["Yes.", "yeah", "Yep!", "Sure, go ahead.", "OK", "Okay, do it", "Allow", "Uh-huh", "Mm-hmm",
                      "Yes please", "No problem", "Go for it, sugar", "Absolutely", "Um, yeah, just run it", "yes yes yes"])
    func clearYeses(_ heard: String) {
        #expect(YesNo.parse(heard) == true)
    }

    @Test(arguments: ["No.", "Nope", "No thanks", "Don't.", "Don\u{2019}t do that", "Deny", "Stop", "Absolutely not",
                      "Of course not", "Not now, hon", "Nah, I'd rather not", "Wait"])
    func clearNos(_ heard: String) {
        #expect(YesNo.parse(heard) == false)
    }

    @Test(arguments: ["", "um", "Yes no", "No, wait, yes", "Yes, but only the first one", "I said no to him yesterday",
                      "What's the weather", "Mind if I run a command?", "Was that a yes or a no, sugar?"])
    func anythingElseIsNoAnswer(_ heard: String) {
        #expect(YesNo.parse(heard) == nil)
    }
}
