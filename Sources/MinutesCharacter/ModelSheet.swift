import CoreGraphics
import Foundation
import MinutesCore

/// Named poses for reviewing the character offscreen (`MissMinutes --render-sheet out.png`)
/// and for the app icon. Each is produced by the real animator, so the sheet
/// shows exactly what plays on screen.
public enum ModelSheet {
    /// What she is touching in a sheet cell, drawn faintly so contact can be checked.
    public enum Prop {
        case none
        /// The floor, level with her feet.
        case ground
        /// The top of a window, under her seat.
        case windowTop
        /// The bottom of a window this far above her anchor (she hangs from it).
        case windowBottom(CGFloat)
        /// The side of a window this far to the right (or left, when negative) of her anchor.
        case windowSide(CGFloat)
    }

    public struct Entry {
        public var name: String
        public var pose: Pose
        public var prop: Prop
    }

    public struct Setup {
        public var base: BaseMotion = .stand
        public var mood: Mood = .happy
        public var activity: Activity?
        public var gesture: GestureName?
        /// Starts leaving this way at time 0.
        public var leaving: PresenceStyle?
        public var at: Double = 0.6
        public var mouth: MouthShape?
        public var look: CGPoint? = .zero
        public var prop: Prop = .ground
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
        if let leaving = s.leaving { animator.dematerialize(at: 0, style: leaving) }
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

    public static var all: [Entry] {
        func S(_ build: (inout Setup) -> Void) -> Setup { var s = Setup(); build(&s); return s }
        let rules = PerchRules()
        let entries: [(String, Setup)] = [
            ("stand", S { _ in }),
            ("sit", S { $0.base = .sit; $0.prop = .windowTop }),
            ("float", S { $0.base = .float; $0.prop = .none }),
            ("walk A", S { $0.base = .walk; $0.context = { $0.walkPhase = 0.1; $0.facing = 1 } }),
            ("walk B", S { $0.base = .walk; $0.context = { $0.walkPhase = 0.6; $0.facing = 1 } }),
            ("hop", S { $0.base = .hop; $0.prop = .none; $0.context = { $0.progress = 0.4; $0.facing = -1 } }),
            ("crawl A", S { $0.base = .crawl; $0.context = { $0.walkPhase = 0.15; $0.facing = 1 } }),
            ("crawl B", S { $0.base = .crawl; $0.context = { $0.walkPhase = 0.65; $0.facing = -1 } }),
            ("hang", S { $0.base = .hang; $0.at = 1.0; $0.prop = .windowBottom(rules.hangReach) }),
            ("shimmy", S { $0.base = .shimmy; $0.prop = .windowBottom(rules.hangReach); $0.context = { $0.walkPhase = 0.3; $0.facing = 1 } }),
            ("cling", S { $0.base = .cling; $0.prop = .windowSide(rules.clingReach); $0.context = { $0.facing = 1 } }),
            ("climb", S { $0.base = .climb; $0.prop = .windowSide(-rules.clingReach); $0.context = { $0.walkPhase = 0.3; $0.facing = -1; $0.climb = 1 } }),
            ("grab", S { $0.base = .hop; $0.prop = .windowBottom(rules.hangReach); $0.context = { $0.progress = 0.9; $0.grab = true; $0.facing = 1 } }),
            ("fall", S { $0.base = .fall; $0.mood = .surprised; $0.prop = .none }),
            ("dangle", S { $0.base = .dangle; $0.mood = .worried; $0.prop = .none; $0.context = { $0.velocity = CGPoint(x: 400, y: 0) } }),
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
            ("dance A", S { $0.gesture = .dance; $0.at = 0.45 }),
            ("dance B", S { $0.gesture = .dance; $0.at = 0.75 }),
            ("love", S { $0.mood = .love; $0.base = .sit; $0.prop = .windowTop }),
            ("surprised", S { $0.mood = .surprised }),
            ("sly", S { $0.mood = .sly; $0.look = nil }),
            ("sad", S { $0.mood = .sad; $0.look = nil }),
            ("annoyed", S { $0.mood = .annoyed }),
            ("excited", S { $0.mood = .excited }),
            ("blink", S { $0.configure = { $0.eyeOpen = 0.1 } }),
            ("ring", S { $0.gesture = .ring; $0.at = 0.5 }),
            ("look left", S { $0.look = CGPoint(x: -1, y: 0.2) ; $0.at = 1.5 }),
            ("twirl", S { $0.leaving = .twirl; $0.at = 0.3 }),
            ("twirl, back", S { $0.leaving = .twirl; $0.at = 0.444 }),
            ("twirl, glint", S { $0.leaving = .twirl; $0.at = 0.9 }),
        ]
        return entries.map { Entry(name: $0.0, pose: pose($0.1), prop: $0.1.prop) }
    }

    /// The icon pose: a happy wave, seen close up.
    public static var iconPose: Pose {
        var p = pose(Setup(mood: .happy, gesture: .wave, at: 0.62, look: CGPoint(x: 0.1, y: 0.1)))
        p.shadow = 0
        return p
    }
}
