import CoreGraphics
import Foundation
import Testing
@testable import MinutesCore

@Suite("Pose and gestures")
struct PoseTests {
    @Test func mixHitsBothEndsAndTheMiddle() {
        var a = Pose(), b = Pose()
        a.body = CGPoint(x: 0, y: 90); b.body = CGPoint(x: 10, y: 110)
        a.smile = 0; b.smile = 1
        a.rightHandShape = .open; b.rightHandShape = .point
        #expect(Pose.mix(a, b, 0) == a)
        #expect(Pose.mix(a, b, 1) == b)
        let mid = Pose.mix(a, b, 0.5)
        #expect(mid.body == CGPoint(x: 5, y: 100))
        #expect(mid.smile == 0.5)
        #expect(Pose.mix(a, b, 0.4).rightHandShape == .open)
        #expect(Pose.mix(a, b, 0.6).rightHandShape == .point)
    }

    @Test func keyframesEaseBetweenKeysAndHoldAtTheEnds() {
        let keys: [Key<CGFloat>] = [Key(0, 0), Key(1, 10, .linear), Key(2, 20, .linear)]
        #expect(sample(keys, at: -1, lerp) == 0)
        #expect(sample(keys, at: 0.5, lerp) == 5)
        #expect(sample(keys, at: 1.5, lerp) == 15)
        #expect(sample(keys, at: 9, lerp) == 20)
    }

    @Test func gestureWeightFadesInAndOut() {
        let g = Gestures.make(.wave)
        #expect(g.weight(at: 0) == 0)
        #expect(g.weight(at: g.duration / 2) == 1)
        #expect(g.weight(at: g.duration) == 0)
        #expect(g.isFinished(at: g.duration))
    }

    @Test func everyGestureMovesSomething() {
        for name in GestureName.allCases {
            let g = Gestures.make(name)
            var pose = Pose()
            g.apply(to: &pose, at: g.duration * 0.45, weight: 1)
            #expect(pose != Pose(), "\(name) changed nothing")
        }
    }

    @Test func pointAimsTheArmOnTheSideOfTheTarget() {
        var pose = Pose()
        let left = Gestures.make(.point, toward: CGPoint(x: -1, y: 0))
        left.apply(to: &pose, at: 1, weight: 1)
        #expect(pose.leftHandShape == .point)
        #expect(pose.leftHand.x < -90)
    }

    @Test func everyMoodHasADistinctFace() {
        let faces = Mood.allCases.map(Expression.of)
        for (i, a) in faces.enumerated() {
            for b in faces[(i + 1)...] { #expect(a != b) }
        }
    }
}

@Suite("Animator")
struct AnimatorTests {
    private func run(_ animator: Animator, from start: Double = 0, to end: Double, date: Date = Date()) -> Pose {
        var pose = Pose()
        var t = start
        while t <= end { pose = animator.update(now: t, dt: 1.0 / 60, date: date); t += 1.0 / 60 }
        return pose
    }

    @Test func blinksCloseTheEyesBriefly() {
        let animator = Animator(random: { 0.5 })
        let open = run(animator, to: 1.0)
        #expect(open.eyeOpen > 0.9)
        // The first blink is due at 1.2 s; 60 ms after it starts the lids are shut.
        _ = animator.update(now: 1.21, dt: 1.0 / 60)
        let shut = animator.update(now: 1.27, dt: 1.0 / 60)
        #expect(shut.eyeOpen < 0.15)
    }

    @Test func clockHandsShowTheRealTime() {
        let animator = Animator(random: { 0.5 })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 3, minute: 15))!
        let pose = animator.update(now: 0, dt: 1.0 / 60, date: date)
        #expect(abs(pose.minuteAngle - .pi / 2) < 0.001)
        #expect(abs(pose.hourAngle - (3.25 / 12) * 2 * .pi) < 0.001)
    }

    @Test func spinningHandsGlideBackToTheTime() {
        let animator = Animator(random: { 0.5 })
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        animator.clockMode = .spin
        let spinning = run(animator, to: 1, date: date)
        let still = Animator(random: { 0.5 }).update(now: 0, dt: 1.0 / 60, date: date)
        #expect(abs(spinning.minuteAngle - still.minuteAngle) > 1)
        animator.clockMode = .time
        let settled = run(animator, from: 1, to: 4, date: date)
        let turns = (settled.minuteAngle - still.minuteAngle) / (2 * .pi)
        #expect(abs(turns - turns.rounded()) < 0.01)
    }

    @Test func activityFadesOutAfterItIsCleared() {
        let animator = Animator(random: { 0.5 })
        animator.setActivity(.think, at: 0)
        let thinking = run(animator, to: 1)
        #expect(thinking.rightHandShape == .fist)
        animator.setActivity(nil, at: 1)
        let after = run(animator, from: 1, to: 2)
        #expect(after.rightHandShape == .open)
        #expect(animator.currentActivity == nil)
    }

    @Test func dematerializeFinishesHidden() {
        let animator = Animator(random: { 0.5 })
        animator.dematerialize(at: 0, duration: 0.4)
        let pose = run(animator, to: 0.5)
        #expect(animator.isDematerialized)
        #expect(pose.opacity < 0.05)
    }

    @Test func lipSyncOpensTheMouth() {
        let animator = Animator(random: { 0.5 })
        animator.mouth = MouthShape(open: 0.8, wide: -0.8)
        let pose = animator.update(now: 0, dt: 1.0 / 60)
        #expect(pose.mouthOpen >= 0.8)
        #expect(pose.mouthWide < -0.5)
    }

    @Test func walkingFeetStayPlantedWhileTheBodyMoves() {
        // During stance a foot moves backwards relative to the anchor by exactly
        // the distance walked, so it stays still on screen.
        var c = MotionContext()
        c.facing = 1
        c.walkPhase = 0.1
        let a = Motions.pose(.walk, c)
        c.walkPhase = 0.2
        let b = Motions.pose(.walk, c)
        let walked = 0.1 * 2 * Motions.stride
        #expect(abs((a.leftFoot.x - b.leftFoot.x) - walked) < 0.001)
        #expect(a.leftFoot.y == 0 && b.leftFoot.y == 0)
    }
}

@Suite("Mouth shapes and speech text")
struct SpeechTests {
    @Test func vowelsShapeTheLips() {
        #expect(Phonetics.shape(for: "o")!.wide < 0)
        #expect(Phonetics.shape(for: "e")!.wide > 0)
        #expect(Phonetics.shape(for: "m")!.open == 0)
        #expect(Phonetics.wideness(in: "moo", at: 1) < 0)
    }

    @Test func sentencesStreamOutAsTheyComplete() {
        var stream = SentenceStream()
        #expect(stream.push("Hey there, sug").isEmpty)
        #expect(stream.push("ar! It's 3.5 minutes past") == ["Hey there, sugar!"])
        #expect(stream.push(" three. And") == ["It's 3.5 minutes past three."])
        #expect(stream.flush() == ["And"])
    }

    @Test func codeBlocksAreAnnouncedNotRead() {
        var stream = SentenceStream()
        let out = stream.push("Here you go:\n```swift\nlet x = 1\n```\nEnjoy! ") + stream.flush()
        #expect(out == ["Here you go:", "I've put the details in my bubble.", "Enjoy!"])
    }

    @Test func markdownIsStrippedForTheVoice() {
        #expect(SpeechText.speakable("**Bold** and `code` with [a link](https://x.y) 🎉") == "Bold and code with a link")
        #expect(SpeechText.speakable("- one\n- two") == "one two")
        #expect(SpeechText.speakable("See https://example.com now") == "See a link now")
    }
}
