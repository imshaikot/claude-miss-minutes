import CoreGraphics
import Foundation

/// Postures and locomotion: the bottom layer of the animation stack, owned by
/// the stage. Everything above it (moods, activity loops, gestures, blinks, lip
/// sync) is layered on by the `Animator`.
public enum BaseMotion: String, CaseIterable {
    case stand, sit, float, walk, hop, fall, dangle
}

/// Inputs a base motion needs besides time, fed by the stage each frame.
public struct MotionContext: Equatable {
    /// Seconds since this motion started.
    public var time: Double = 0
    /// -1 facing left, 1 facing right.
    public var facing: CGFloat = 1
    /// Walk cycles completed; the stage advances it from distance travelled so feet never slide.
    public var walkPhase: Double = 0
    /// Hop progress 0…1.
    public var progress: CGFloat = 0
    /// Anchor velocity in points per second.
    public var velocity = CGPoint.zero

    public init() {}
}

private func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// Procedural motion clips, written in the 1930s rubber-hose idiom: everything
/// bounces on a beat, limbs swing on offset phases, nothing is ever fully still.
public enum Motions {
    /// Stride length of one step at scale 1. Walk speed / (2 × stride) = cycles per second.
    public static let stride: CGFloat = 30

    public static func pose(_ motion: BaseMotion, _ c: MotionContext) -> Pose {
        switch motion {
        case .stand: return stand(c)
        case .sit: return sit(c)
        case .float: return float(c)
        case .walk: return walk(c)
        case .hop: return hop(c)
        case .fall: return fall(c)
        case .dangle: return dangle(c)
        }
    }

    static func stand(_ c: MotionContext) -> Pose {
        var p = Pose()
        let beat = c.time * 2 * .pi / 1.7
        let b = CGFloat(sin(beat)), h = CGFloat(sin(beat * 0.5))
        p.body = P(0, 92 + 1.8 * b)
        p.squash = 1 + 0.018 * CGFloat(sin(beat + .pi / 2))
        p.tilt = 0.035 * h
        // Signature stance: one hand on the hip, the other loose and swaying.
        p.leftHand = P(-50, -30 + b)
        p.leftArmBend = 26
        p.leftHandShape = .fist
        p.rightHand = P(57 + 2 * CGFloat(sin(beat * 0.5 + 1)), -40 + 1.5 * b)
        p.rightArmBend = 8
        p.rightHandAngle = 0.15 * h
        p.leftLegBend = 3 + 2 * b
        p.rightLegBend = 3 - 2 * b
        p.shadow = 1
        return p
    }

    static func sit(_ c: MotionContext) -> Pose {
        var p = Pose()
        let beat = c.time * 2 * .pi / 2.4
        p.body = P(0, 50 + 0.8 * CGFloat(sin(beat)))
        p.squash = 1 + 0.015 * CGFloat(sin(beat + .pi / 2))
        p.tilt = 0.03 * CGFloat(sin(beat * 0.5))
        // Palms on the ledge either side of her.
        p.leftHand = P(-63, -46)
        p.rightHand = P(63, -46)
        p.leftArmBend = 7
        p.rightArmBend = 7
        p.leftHandAngle = 0.5
        p.rightHandAngle = 0.5
        // Legs dangle over the edge and swing out of phase.
        let swing = c.time * 2 * .pi / 1.5
        p.leftFoot = P(-13 + 5 * CGFloat(sin(swing)), -46 + 4 * CGFloat(cos(swing)))
        p.rightFoot = P(13 + 5 * CGFloat(sin(swing + .pi)), -46 + 4 * CGFloat(cos(swing + .pi)))
        p.leftFootAngle = 0.25 * CGFloat(sin(swing + 0.6))
        p.rightFootAngle = 0.25 * CGFloat(sin(swing + .pi + 0.6))
        p.leftLegBend = 6
        p.rightLegBend = 6
        p.shadow = 0
        return p
    }

    /// Hovering in mid-air like a hologram projection: slow bob, legs dangling.
    static func float(_ c: MotionContext) -> Pose {
        var p = Pose()
        let t = c.time
        let bob = CGFloat(sin(t * 2 * .pi / 2.6))
        p.body = P(0, 92 + 5 * bob)
        p.squash = 1 + 0.02 * CGFloat(sin(t * 2 * .pi / 2.6 + .pi / 2))
        p.tilt = 0.05 * CGFloat(sin(t * 2 * .pi / 5.2))
        p.leftHand = P(-58, -30 + 3 * CGFloat(sin(t * 2.1 + 1)))
        p.rightHand = P(58, -30 + 3 * CGFloat(sin(t * 2.1)))
        p.leftArmBend = 10; p.rightArmBend = 10
        p.leftHandAngle = 0.3; p.rightHandAngle = 0.3
        let swing = t * 2 * .pi / 1.9
        p.leftFoot = P(-12 + 3 * CGFloat(sin(swing)), 6 + 5 * bob + 3 * CGFloat(cos(swing)))
        p.rightFoot = P(12 + 3 * CGFloat(sin(swing + .pi)), 6 + 5 * bob + 3 * CGFloat(cos(swing + .pi)))
        p.leftFootAngle = -0.35 + 0.15 * CGFloat(sin(swing))
        p.rightFootAngle = 0.35 + 0.15 * CGFloat(sin(swing + .pi))
        p.leftLegBend = 5; p.rightLegBend = 5
        p.shadow = 0
        return p
    }

    static func walk(_ c: MotionContext) -> Pose {
        var p = Pose()
        let f: CGFloat = c.facing >= 0 ? 1 : -1
        let a = c.walkPhase * 2 * .pi
        p.facing = f
        p.faceShift = P(0.55 * f, 0)
        p.body = P(0, 89 + 6 * abs(CGFloat(sin(a))))
        p.squash = 1 + 0.035 * CGFloat(cos(2 * a))
        p.tilt = -0.08 * f + 0.025 * CGFloat(sin(a))
        for (index, offset) in [(0, -5.0), (1, 5.0)] {
            var phase = (c.walkPhase + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
            if phase < 0 { phase += 1 }
            var foot = CGPoint.zero
            var angle: CGFloat = 0
            if phase < 0.5 {
                let s = CGFloat(phase / 0.5)
                foot = P(f * (stride / 2 - stride * s), 0)
            } else {
                let s = CGFloat((phase - 0.5) / 0.5)
                foot = P(f * (-stride / 2 + stride * smoothstep(s)), 11 * bump(s))
                angle = f * 0.35 * bump(s)
            }
            foot.x += CGFloat(offset)
            if index == 0 { p.leftFoot = foot; p.leftFootAngle = angle } else { p.rightFoot = foot; p.rightFootAngle = angle }
        }
        let swing = CGFloat(sin(a))
        p.leftHand = P(-50 + f * 13 * swing, -34 + 2 * CGFloat(cos(2 * a)))
        p.rightHand = P(50 - f * 13 * swing, -34 + 2 * CGFloat(cos(2 * a)))
        p.leftHandAngle = 0.25 * swing
        p.rightHandAngle = -0.25 * swing
        p.leftLegBend = 4
        p.rightLegBend = 4
        p.shadow = 1
        return p
    }

    /// Anticipation 0–0.18, airborne 0.18–0.82, landing 0.82–1 (the stage moves the anchor in the air phase).
    static func hop(_ c: MotionContext) -> Pose {
        var p = stand(c)
        let f: CGFloat = c.facing >= 0 ? 1 : -1
        let pr = c.progress
        p.facing = f * 0.6
        p.faceShift = P(0.4 * f, 0)
        if pr < 0.18 {
            let crouch = Ease.out(pr / 0.18)
            p.body = P(0, 92 - 13 * crouch)
            p.squash = 1 - 0.15 * crouch
            p.leftHand = P(-54, -46); p.rightHand = P(54, -46)
            p.leftLegBend = 10 * crouch; p.rightLegBend = 10 * crouch
            p.shadow = 1
        } else if pr < 0.82 {
            let u = (pr - 0.18) / 0.64
            p.body = P(0, 96)
            p.squash = u < 0.5 ? lerp(1.15, 1.0, u * 2) : lerp(1.0, 1.07, (u - 0.5) * 2)
            p.tilt = -0.16 * f * (1 - 2 * u)
            p.leftHand = P(-52, 30); p.rightHand = P(52, 30)
            p.leftArmBend = -8; p.rightArmBend = -8
            p.leftHandShape = .open
            p.leftFoot = P(-12, 18); p.rightFoot = P(12, 14)
            p.leftLegBend = 12; p.rightLegBend = 12
            p.shadow = 0
        } else {
            let u = (pr - 0.82) / 0.18
            let impact = (1 - u) * (1 - u)
            p.body = P(0, 92 - 14 * impact)
            p.squash = 1 - 0.2 * impact
            p.leftHand = lerp(P(-58, 0), P(-50, -30), u)
            p.rightHand = lerp(P(58, 0), P(57, -40), u)
            p.leftLegBend = 12 * impact; p.rightLegBend = 12 * impact
            p.shadow = 1
        }
        return p
    }

    static func fall(_ c: MotionContext) -> Pose {
        var p = Pose()
        let t = c.time
        p.body = P(0, 100)
        p.squash = 1.08
        p.tilt = 0.05 * CGFloat(sin(t * 9))
        p.leftHand = P(-50 + 6 * CGFloat(sin(t * 17)), 38 + 8 * CGFloat(cos(t * 13)))
        p.rightHand = P(50 + 6 * CGFloat(sin(t * 15 + 1)), 38 + 8 * CGFloat(cos(t * 14)))
        p.leftArmBend = -10; p.rightArmBend = -10
        p.leftFoot = P(-14 + 6 * CGFloat(sin(t * 16)), 14 + 8 * CGFloat(cos(t * 12)))
        p.rightFoot = P(14 + 6 * CGFloat(sin(t * 14 + 2)), 14 + 8 * CGFloat(cos(t * 11 + 1)))
        p.leftLegBend = 8; p.rightLegBend = 8
        p.shadow = 0
        return p
    }

    /// Held by the pointer: limbs hang and trail behind the drag.
    static func dangle(_ c: MotionContext) -> Pose {
        var p = Pose()
        let trail = clamp(-c.velocity.x * 0.03, -26, 26)
        let lift = clamp(abs(c.velocity.y) * 0.01, 0, 8)
        let t = c.time
        p.body = P(0, 92)
        p.leftHand = P(-48 + trail * 0.4, -52 + lift)
        p.rightHand = P(48 + trail * 0.4, -52 + lift)
        p.leftArmBend = 4; p.rightArmBend = 4
        p.leftFoot = P(-12 + trail + 2 * CGFloat(sin(t * 5)), -6 + abs(trail) * 0.25)
        p.rightFoot = P(12 + trail + 2 * CGFloat(sin(t * 5 + 1.4)), -6 + abs(trail) * 0.25)
        p.leftFootAngle = -trail * 0.01; p.rightFootAngle = -trail * 0.01
        p.leftLegBend = 3; p.rightLegBend = 3
        p.shadow = 0
        return p
    }
}
