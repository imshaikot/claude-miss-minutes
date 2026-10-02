import CoreGraphics
import Foundation
import MinutesCore

/// Named poses for reviewing the character offscreen (`MissMinutes --render-sheet out.png`)
/// and for the app icon. Each is produced by the real animator, so the sheet
/// shows exactly what plays on screen.
public enum ModelSheet {
    public struct Setup {
        public var base: BaseMotion = .stand
        public var mood: Mood = .happy
        public var activity: Activity?
        public var gesture: GestureName?
        public var at: Double = 0.6
        public var mouth: MouthShape?
        public var look: CGPoint? = .zero
        public var configure: ((inout Pose) -> Void)?
        public var context: ((inout MotionContext) -> Void)?
    }

    public static func pose(_ s: Setup) -> Pose {
        let animator = Animator(random: { 0.999 })
        animator.hologram = true
        s.context?(&animator.context)
        animator.setBase(s.base, at: -10, blend: 0)
        animator.setMood(s.mood, at: -10)
        if let activity = s.activity { animator.setActivity(activity, at: -10) }
        if let gesture = s.gesture { animator.play(Gestures.make(gesture), at: 0) }
        animator.lookTarget = s.look
        animator.mouth = s.mouth
        var pose = Pose()
        var t = -10.0
        while t < s.at { pose = animator.update(now: t, dt: 1.0 / 60, date: Date(timeIntervalSince1970: 1_790_000_000)); t += 1.0 / 60 }
        pose = animator.update(now: s.at, dt: 1.0 / 60, date: Date(timeIntervalSince1970: 1_790_000_000))
        pose.glitch = 0
        pose.opacity = 1
        s.configure?(&pose)
        return pose
    }

    public static var all: [(String, Pose)] {
        func S(_ build: (inout Setup) -> Void) -> Setup { var s = Setup(); build(&s); return s }
        let entries: [(String, Setup)] = [
            ("stand", S { _ in }),
            ("sit", S { $0.base = .sit }),
            ("float", S { $0.base = .float }),
            ("walk A", S { $0.base = .walk; $0.context = { $0.walkPhase = 0.1; $0.facing = 1 } }),
            ("walk B", S { $0.base = .walk; $0.context = { $0.walkPhase = 0.6; $0.facing = 1 } }),
            ("hop", S { $0.base = .hop; $0.context = { $0.progress = 0.4; $0.facing = -1 } }),
            ("fall", S { $0.base = .fall; $0.mood = .surprised }),
            ("dangle", S { $0.base = .dangle; $0.mood = .worried; $0.context = { $0.velocity = CGPoint(x: 400, y: 0) } }),
            ("listen", S { $0.activity = .listen; $0.at = 1.2 }),
            ("think", S { $0.activity = .think; $0.at = 1.2 }),
            ("talk", S { $0.activity = .talk; $0.at = 1.0; $0.mouth = MouthShape(open: 0.7, wide: 0.1) }),
            ("ask", S { $0.activity = .ask; $0.at = 1.2 }),
            ("wave", S { $0.gesture = .wave; $0.at = 0.62 }),
            ("point", S { $0.gesture = .point; $0.at = 0.9 }),
            ("shrug", S { $0.gesture = .shrug; $0.at = 0.8 }),
            ("clap", S { $0.gesture = .clap; $0.at = 0.32 }),
            ("jump", S { $0.gesture = .jump; $0.at = 0.42 }),
            ("bow", S { $0.gesture = .bow; $0.at = 0.8 }),
            ("tap foot", S { $0.gesture = .tapFoot; $0.at = 0.6 }),
            ("stretch", S { $0.gesture = .stretch; $0.at = 1.0 }),
            ("blow kiss", S { $0.gesture = .blowKiss; $0.at = 0.45 }),
            ("love", S { $0.mood = .love; $0.base = .sit }),
            ("surprised", S { $0.mood = .surprised }),
            ("sly", S { $0.mood = .sly; $0.look = nil }),
            ("sad", S { $0.mood = .sad; $0.look = nil }),
            ("annoyed", S { $0.mood = .annoyed }),
            ("excited", S { $0.mood = .excited }),
            ("blink", S { $0.configure = { $0.eyeOpen = 0.1 } }),
            ("ring", S { $0.gesture = .ring; $0.at = 0.5 }),
            ("look left", S { $0.look = CGPoint(x: -1, y: 0.2) ; $0.at = 1.5 }),
        ]
        return entries.map { ($0.0, pose($0.1)) }
    }

    /// The icon pose: a happy wave, seen close up.
    public static var iconPose: Pose {
        var p = pose(Setup(mood: .happy, gesture: .wave, at: 0.62, look: CGPoint(x: 0.1, y: 0.1)))
        p.shadow = 0
        return p
    }
}
