import CoreGraphics
import Foundation

public enum ClockMode: Equatable {
    /// Hands show the real time.
    case time
    /// Hands whirl (thinking, teleporting) and glide back to the time afterwards.
    case spin
}

/// Layers every animation source into one `Pose` per frame:
///
/// 1. base motion (posture/locomotion, cross-faded on change)
/// 2. mood expression (blended), then activity-loop and gesture moods
/// 3. activity loop (listen/think/talk/ask) and one-shot gestures
/// 4. secondary motion: inertia, look-at springs, autonomous glances
/// 5. blinks, lip sync, clock hands, hologram presence
///
/// Pure value math with no AppKit, so it is deterministic under test given a
/// seeded `random` source.
public final class Animator {
    public private(set) var base: BaseMotion = .stand
    /// Stage-owned inputs for the base motion (facing, walk phase, hop progress, velocity).
    public var context = MotionContext()
    private var baseStart: Double = 0
    private var blendFrom: Pose?
    private var blendStart: Double = 0
    private var blendDuration: Double = 0.25

    private var activity: (kind: Activity, gesture: Gesture, start: Double)?
    private var fadingActivity: (gesture: Gesture, start: Double, fadeStart: Double, weight: CGFloat)?
    private var gestures: [(gesture: Gesture, start: Double)] = []

    public private(set) var mood: Mood = .happy
    private var moodFrom = Expression.of(.happy)
    private var moodStart: Double = -10
    /// A physical reaction (falling, being dragged) that overrides every other mood.
    public var reflexMood: Mood? {
        didSet { if let reflexMood { lastReflex = reflexMood } }
    }
    private var lastReflex: Mood = .surprised
    private var reflexWeight: CGFloat = 0

    /// Where to look, as a direction in face space (-1…1). `nil` lets her glance around.
    public var lookTarget: CGPoint?
    private var pupils = Spring2D(stiffness: 260, dampingRatio: 0.72)
    private var faceTurn = Spring2D(stiffness: 70, dampingRatio: 0.85)
    private var glance = CGPoint.zero
    private var nextGlance: Double = 2

    private var nextBlink: Double = 1.2
    private var blinkStart: Double = -10
    private var pendingDoubleBlink = false

    /// Set every frame by the voice; nil when silent.
    public var mouth: MouthShape?

    public var clockMode: ClockMode = .time
    private var minuteSpin: CGFloat = 0
    private var hourSpin: CGFloat = 0

    /// Anchor acceleration (pt/s²) from the stage; drives an under-damped sway.
    public var acceleration = CGPoint.zero
    private var inertia = Spring(stiffness: 80, dampingRatio: 0.32)
    private var bounce = Spring(stiffness: 260, dampingRatio: 0.28)

    public var hologram = true
    private var presence: (appearing: Bool, start: Double, duration: Double)?
    private var nextFlicker: Double = 9
    private var flickerStart: Double = -10

    private let random: () -> Double
    public private(set) var lastPose = Pose()
    public private(set) var now: Double = 0

    public init(random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.random = random
    }

    // MARK: Commands

    public func setBase(_ motion: BaseMotion, at now: Double, blend: Double = 0.25) {
        guard motion != base else { return }
        blendFrom = lastPose
        blendStart = now
        blendDuration = blend
        base = motion
        baseStart = now
    }

    /// Restarts the current base motion's clock (e.g. a fresh hop).
    public func restartBase(at now: Double) { baseStart = now }

    public func setActivity(_ kind: Activity?, at now: Double) {
        if kind == activity?.kind { return }
        if let current = activity {
            let w = current.gesture.weight(at: now - current.start)
            fadingActivity = (current.gesture, current.start, now, w)
        }
        activity = kind.map { ($0, Gestures.loop(for: $0), now) }
    }

    public var currentActivity: Activity? { activity?.kind }

    public func play(_ gesture: Gesture, at now: Double) {
        gestures.removeAll { $0.gesture.name == gesture.name }
        gestures.append((gesture, now))
    }

    public var isGesturing: Bool { !gestures.isEmpty }

    public func setMood(_ newMood: Mood, at now: Double) {
        guard newMood != mood else { return }
        moodFrom = currentMoodExpression(at: now)
        mood = newMood
        moodStart = now
    }

    /// A landing impact: an under-damped squash that settles over half a second.
    public func impact(_ strength: CGFloat = 1) {
        bounce.velocity -= 3.2 * strength
    }

    public func materialize(at now: Double, duration: Double = 0.75) {
        presence = (true, now, duration)
    }

    public func dematerialize(at now: Double, duration: Double = 0.45) {
        presence = (false, now, duration)
    }

    /// True once a dematerialize has fully finished.
    public var isDematerialized: Bool {
        guard let presence, !presence.appearing else { return false }
        return now - presence.start >= presence.duration
    }

    // MARK: Frame

    public func update(now: Double, dt: Double, date: Date = Date()) -> Pose {
        self.now = now
        context.time = now - baseStart
        var pose = Motions.pose(base, context)
        if let from = blendFrom {
            let w = Ease.inOut(CGFloat((now - blendStart) / max(blendDuration, 0.001)))
            pose.takeBody(from: Pose.mix(from, pose, w))
            if w >= 1 { blendFrom = nil }
        }

        applyExpression(to: &pose, now: now, dt: dt)
        applyLayers(to: &pose, now: now)
        applyInertia(to: &pose, dt: dt)
        applyLook(to: &pose, now: now, dt: dt)
        applyBlink(to: &pose, now: now)
        applyMouth(to: &pose)
        applyClock(to: &pose, dt: dt, date: date)
        applyPresence(to: &pose, now: now)

        lastPose = pose
        return pose
    }

    private func currentMoodExpression(at now: Double) -> Expression {
        Expression.mix(moodFrom, Expression.of(mood), smoothstep(CGFloat((now - moodStart) / 0.35)))
    }

    private func applyExpression(to pose: inout Pose, now: Double, dt: Double) {
        var expression = currentMoodExpression(at: now)
        if let activity, let mood = activity.gesture.mood {
            expression = Expression.mix(expression, .of(mood), activity.gesture.weight(at: now - activity.start))
        }
        if let latest = gestures.last(where: { $0.gesture.mood != nil }), let mood = latest.gesture.mood {
            expression = Expression.mix(expression, .of(mood), latest.gesture.weight(at: now - latest.start))
        }
        reflexWeight += ((reflexMood == nil ? 0 : 1) - reflexWeight) * CGFloat(min(1, dt * 8))
        expression = Expression.mix(expression, .of(lastReflex), reflexWeight)
        expression.apply(to: &pose)
        pose.look = expression.lookBias
    }

    private func applyLayers(to pose: inout Pose, now: Double) {
        if let fading = fadingActivity {
            let w = fading.weight * (1 - smoothstep(CGFloat((now - fading.fadeStart) / 0.3)))
            if w <= 0.001 { fadingActivity = nil } else {
                fading.gesture.apply(to: &pose, at: now - fading.start, weight: w)
            }
        }
        if let activity {
            let t = now - activity.start
            activity.gesture.apply(to: &pose, at: t, weight: activity.gesture.weight(at: t))
        }
        gestures.removeAll { $0.gesture.isFinished(at: now - $0.start) }
        for entry in gestures {
            let t = now - entry.start
            entry.gesture.apply(to: &pose, at: t, weight: entry.gesture.weight(at: t))
        }
    }

    private func applyInertia(to pose: inout Pose, dt: Double) {
        let target = clamp(-acceleration.x * 0.00022, -0.35, 0.35)
        inertia.step(toward: target, dt: dt)
        pose.tilt += inertia.value
        pose.body.x -= inertia.value * 10
        bounce.step(toward: 0, dt: dt)
        pose.squash += bounce.value
        pose.body.y += bounce.value * 40
    }

    private func applyLook(to pose: inout Pose, now: Double, dt: Double) {
        if now >= nextGlance {
            nextGlance = now + 1.4 + random() * 2.8
            glance = random() < 0.35 ? .zero : CGPoint(x: CGFloat(random() * 1.2 - 0.6), y: CGFloat(random() * 0.8 - 0.4))
        }
        let target = (lookTarget ?? glance).clamped(to: 1)
        pupils.step(toward: target, dt: dt)
        faceTurn.step(toward: CGPoint(x: target.x * 0.35, y: target.y * 0.25), dt: dt)
        pose.look = (pose.look + pupils.value).clamped(to: 1.15)
        pose.faceShift += faceTurn.value
    }

    private func applyBlink(to pose: inout Pose, now: Double) {
        if now >= nextBlink {
            blinkStart = now
            if pendingDoubleBlink {
                pendingDoubleBlink = false
                nextBlink = now + 2 + random() * 3.5
            } else if random() < 0.15 {
                pendingDoubleBlink = true
                nextBlink = now + 0.22
            } else {
                nextBlink = now + 2 + random() * 3.5
            }
        }
        let t = now - blinkStart
        var closed: CGFloat = 0
        if t >= 0 && t < 0.06 { closed = CGFloat(t / 0.06) } else if t >= 0.06 && t < 0.17 { closed = 1 - CGFloat((t - 0.06) / 0.11) }
        pose.eyeOpen *= 1 - closed
    }

    private func applyMouth(to pose: inout Pose) {
        guard let mouth else { return }
        pose.mouthOpen = max(pose.mouthOpen * 0.3, mouth.open)
        pose.mouthWide = lerp(pose.mouthWide, mouth.wide, clamp(mouth.open * 4, 0, 0.85))
        pose.body.y += mouth.open * 1.6
        pose.browRaise += mouth.open * 0.18
    }

    private func applyClock(to pose: inout Pose, dt: Double, date: Date) {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let seconds = Double(parts.second ?? 0) + Double(parts.nanosecond ?? 0) / 1e9
        let minutes = Double(parts.minute ?? 0) + seconds / 60
        let hours = Double((parts.hour ?? 0) % 12) + minutes / 60
        let turn = 2 * CGFloat.pi
        switch clockMode {
        case .spin:
            minuteSpin += CGFloat(dt) * 9
            hourSpin += CGFloat(dt) * 2.2
        case .time:
            // Glide forward to the next whole turn so the hands land on the real time.
            let k = CGFloat(min(1, dt * 3.5))
            minuteSpin += (ceil(minuteSpin / turn - 0.001) * turn - minuteSpin) * k
            hourSpin += (ceil(hourSpin / turn - 0.001) * turn - hourSpin) * k
        }
        pose.minuteAngle = CGFloat(minutes / 60) * turn + minuteSpin
        pose.hourAngle = CGFloat(hours / 12) * turn + hourSpin
    }

    private func applyPresence(to pose: inout Pose, now: Double) {
        pose.glow = hologram ? 1 : 0
        if let presence {
            let u = CGFloat((now - presence.start) / max(presence.duration, 0.001))
            let jitter = CGFloat(noise(now * 40, seed: 7)) * 0.5 + 0.5
            if presence.appearing {
                if u >= 1 { self.presence = nil } else {
                    pose.reveal = Ease.out(u)
                    pose.glitch = (1 - u) * 0.9
                    pose.opacity = min(1, u * 1.8) * (u < 0.7 ? (0.55 + 0.45 * jitter) : 1)
                }
            } else {
                let v = min(u, 1)
                pose.reveal = 1 - Ease.in(v)
                pose.glitch = min(1, v * 1.4)
                pose.opacity = (1 - v) * (0.6 + 0.4 * jitter)
            }
        }
        guard hologram else { return }
        if now >= nextFlicker {
            flickerStart = now
            nextFlicker = now + 7 + random() * 14
        }
        let f = now - flickerStart
        if f >= 0 && f < 0.2 {
            let b = bump(CGFloat(f / 0.2))
            pose.glitch = max(pose.glitch, 0.3 * b)
            pose.opacity *= 1 - 0.15 * b
        }
    }
}
