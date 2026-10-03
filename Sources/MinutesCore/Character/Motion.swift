import CoreGraphics
import Foundation

/// Postures and locomotion: the bottom layer of the animation stack, owned by
/// the stage. Everything above it (moods, activity loops, gestures, blinks, lip
/// sync) is layered on by the `Animator`.
public enum BaseMotion: String, CaseIterable {
    case stand, sit, float, walk, hop, fall, dangle
    /// On all fours along a ledge.
    case crawl
    /// Hanging by her hands from a window's bottom edge, and moving along it hand over hand.
    case hang, shimmy
    /// Holding on to a window's side, and climbing up or down it.
    case cling, climb
}

/// Inputs a base motion needs besides time, fed by the stage each frame.
public struct MotionContext: Equatable {
    /// Seconds since this motion started.
    public var time: Double = 0
    /// -1 facing left, 1 facing right. Clinging and climbing: the side her window is on.
    public var facing: CGFloat = 1
    /// Gait cycles completed (walk, crawl, climb, shimmy); the stage advances it
    /// from distance travelled so planted hands and feet never slide.
    public var walkPhase: Double = 0
    /// Hop progress 0…1.
    public var progress: CGFloat = 0
    /// Anchor velocity in points per second.
    public var velocity = CGPoint.zero
    /// The hop ends hanging from or clinging to an edge: arms up to catch it.
    public var grab = false
    /// Climbing: 1 going up a window's side, -1 going down.
    public var climb: CGFloat = 1

    public init() {}
}

private func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// Procedural motion clips, written in the 1930s rubber-hose idiom: everything
/// bounces on a beat, limbs swing on offset phases, nothing is ever fully still.
public enum Motions {
    /// Stride length of one step at scale 1. Walk speed / (2 × stride) = cycles per second.
    public static let stride: CGFloat = 30
    /// Height of her hands above the anchor while hanging from an edge.
    public static let hangGrip: CGFloat = 166
    /// Half the distance between her hands while hanging: wide, so her arms run up her sides.
    public static let hangSpread: CGFloat = 44
    /// How far out from the anchor her hands grip a window's side while clinging.
    public static let clingGrip: CGFloat = 56

    /// Distance one limb covers per half cycle, for each gait.
    public static func stride(for motion: BaseMotion) -> CGFloat {
        switch motion {
        case .crawl: return 20
        case .climb: return 24
        case .shimmy: return 22
        default: return stride
        }
    }

    public static func pose(_ motion: BaseMotion, _ c: MotionContext) -> Pose {
        switch motion {
        case .stand: return stand(c)
        case .sit: return sit(c)
        case .float: return float(c)
        case .walk: return walk(c)
        case .hop: return hop(c)
        case .fall: return fall(c)
        case .dangle: return dangle(c)
        case .crawl: return crawl(c)
        case .hang: return hang(c)
        case .shimmy: return shimmy(c)
        case .cling: return cling(c)
        case .climb: return climb(c)
        }
    }

    /// One limb's step cycle at `phase` (in cycles): planted for the first
    /// half, sliding back one stride relative to her as she passes over it,
    /// then swinging forward. Returns the offset along her way and the lift 0…1.
    static func step(_ phase: Double, stride: CGFloat) -> (along: CGFloat, lift: CGFloat) {
        var u = phase.truncatingRemainder(dividingBy: 1)
        if u < 0 { u += 1 }
        if u < 0.5 { return (stride / 2 - stride * CGFloat(u / 0.5), 0) }
        let s = CGFloat((u - 0.5) / 0.5)
        return (-stride / 2 + stride * smoothstep(s), bump(s))
    }

    /// A point in anchor space, in the body space of `p` (where hands live).
    static func inBody(_ point: CGPoint, _ p: Pose) -> CGPoint {
        (point - p.body).rotated(by: -p.tilt)
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
        } else if c.grab {
            // Reaching for an edge to hang from: arms stay up and close round it, no landing crouch.
            let u = clamp((pr - 0.18) / 0.82, 0, 1)
            p.body = P(0, 96 - 6 * u)
            p.squash = lerp(1.15, 1.04, u)
            p.tilt = -0.12 * f * (1 - u)
            p.leftHand = P(-hangSpread, 68 + 8 * u); p.rightHand = P(hangSpread, 68 + 8 * u)
            p.leftArmBend = 9; p.rightArmBend = 9
            p.leftHandShape = u > 0.75 ? .fist : .open
            p.rightHandShape = u > 0.75 ? .fist : .open
            p.leftFoot = P(-12, 14 - 8 * u); p.rightFoot = P(12, 10 - 6 * u)
            p.leftLegBend = 8; p.rightLegBend = 8
            p.shadow = 0
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

    /// On all fours, low and leaning into the way she's going. Each hand moves
    /// with the opposite knee, and whatever is planted stays put on screen.
    static func crawl(_ c: MotionContext) -> Pose {
        var p = Pose()
        let f: CGFloat = c.facing >= 0 ? 1 : -1
        let s = stride(for: .crawl)
        let a = c.walkPhase * 2 * .pi
        p.facing = f
        p.faceShift = P(0.6 * f, -0.2)
        p.body = P(-6 * f, 56 + 3 * abs(CGFloat(sin(a))))
        p.squash = 0.94 + 0.02 * CGFloat(cos(2 * a))
        p.tilt = -0.42 * f + 0.03 * CGFloat(sin(a))
        let lead = step(c.walkPhase, stride: s), trail = step(c.walkPhase + 0.5, stride: s)
        // The hand on her facing side reaches ahead in front of her; the other paws from behind her.
        let leadHand = inBody(P(f * (46 + lead.along), 3 + 9 * lead.lift), p)
        let trailHand = inBody(P(f * (26 + trail.along), 3 + 9 * trail.lift), p)
        // Knees down behind her: shoes upturned, soles to the sky.
        let leadFoot = P(f * (-34 + trail.along), 9 + 8 * trail.lift)
        let trailFoot = P(f * (-50 + lead.along), 9 + 8 * lead.lift)
        if f > 0 {
            p.rightHand = leadHand; p.leftHand = trailHand; p.leftArmBehind = true
            p.rightFoot = leadFoot; p.leftFoot = trailFoot
        } else {
            p.leftHand = leadHand; p.rightHand = trailHand; p.rightArmBehind = true
            p.leftFoot = leadFoot; p.rightFoot = trailFoot
        }
        p.leftHandAngle = -0.9; p.rightHandAngle = -0.9
        p.leftArmBend = 3; p.rightArmBend = 3
        p.leftLegBend = 12; p.rightLegBend = 12
        p.leftFootAngle = 2.8 - 0.3 * (f > 0 ? lead.lift : trail.lift)
        p.rightFootAngle = 2.8 - 0.3 * (f > 0 ? trail.lift : lead.lift)
        p.shadow = 1
        return p
    }

    /// The pendulum she makes hanging from her hands: body under the grip, swung by `swing` radians.
    private static func hanging(swing: CGFloat) -> Pose {
        var p = Pose()
        let length = hangGrip - 90
        p.body = P(length * sin(swing), hangGrip - length * cos(swing))
        p.tilt = swing
        p.leftHandShape = .fist; p.rightHandShape = .fist
        p.leftArmBend = 9; p.rightArmBend = 9
        p.shadow = 0
        return p
    }

    /// Hanging from an edge by both hands: a slow sway, legs dangling and now and then kicking.
    static func hang(_ c: MotionContext) -> Pose {
        let t = c.time
        var p = hanging(swing: 0.06 * CGFloat(sin(t * 2 * .pi / 2.8)) + 0.03 * noise(t * 0.6, seed: 3))
        p.squash = 1.05 + 0.01 * CGFloat(sin(t * 2 * .pi / 1.4))
        p.leftHand = inBody(P(-hangSpread, hangGrip), p)
        p.rightHand = inBody(P(hangSpread, hangGrip), p)
        let kick = clamp(noise(t * 0.45, seed: 9) * 1.8, 0, 1)
        let pedal = t * 2 * .pi * 1.3
        let drift = p.body.x * 1.3
        for side: CGFloat in [-1, 1] {
            let phase = pedal + (side < 0 ? 0 : .pi)
            let foot = P(drift + side * 11 + 3 * CGFloat(sin(phase)) * (0.4 + kick), 4 + 12 * kick * max(0, CGFloat(sin(phase))))
            if side < 0 { p.leftFoot = foot; p.leftFootAngle = -0.5 + 0.3 * kick } else { p.rightFoot = foot; p.rightFootAngle = -0.5 + 0.3 * kick }
        }
        p.leftLegBend = 4 + 6 * kick; p.rightLegBend = 4 + 6 * kick
        return p
    }

    /// Hand over hand along the edge she hangs from, legs trailing.
    static func shimmy(_ c: MotionContext) -> Pose {
        let f: CGFloat = c.facing >= 0 ? 1 : -1
        let s = stride(for: .shimmy)
        let a = c.walkPhase * 2 * .pi
        var p = hanging(swing: 0.05 * CGFloat(sin(a)) - 0.04 * f)
        p.facing = 0.4 * f
        p.faceShift = P(0.4 * f, 0.1)
        p.squash = 1.04
        let right = step(c.walkPhase + (f > 0 ? 0 : 0.5), stride: s)
        let left = step(c.walkPhase + (f > 0 ? 0.5 : 0), stride: s)
        p.rightHand = inBody(P(hangSpread + f * right.along, hangGrip - 7 * right.lift), p)
        p.leftHand = inBody(P(-hangSpread + f * left.along, hangGrip - 7 * left.lift), p)
        let drift = p.body.x * 1.3 - 6 * f
        p.leftFoot = P(drift - 11 + 3 * CGFloat(sin(a)), 5 + 3 * CGFloat(cos(a)))
        p.rightFoot = P(drift + 11 + 3 * CGFloat(sin(a + .pi)), 5 + 3 * CGFloat(cos(a + .pi)))
        p.leftFootAngle = -0.4; p.rightFootAngle = -0.4
        p.leftLegBend = 5; p.rightLegBend = 5
        return p
    }

    /// Holding on to a window's side (which is toward `facing`): the near hand
    /// high on the edge, the far one lower and reaching round behind her,
    /// shoes braced on the frame, leaning out to look at you.
    static func cling(_ c: MotionContext) -> Pose {
        var p = Pose()
        let f: CGFloat = c.facing >= 0 ? 1 : -1
        let t = c.time
        let sway = CGFloat(sin(t * 2 * .pi / 3.2))
        p.facing = 0.5 * f
        p.body = P(-6 * f + 1.5 * sway, 94 + 1.2 * CGFloat(sin(t * 2 * .pi / 1.6)))
        p.tilt = 0.07 * f + 0.02 * sway
        p.faceShift = P(-0.3 * f, 0.05)
        let near = inBody(P(f * clingGrip, 148), p)
        let far = inBody(P(f * clingGrip, 84), p)
        let nearFoot = P(f * 58, 30 + sway)
        let farFoot = P(f * 56, 4)
        brace(&p, facing: f, hands: (near, far), feet: (nearFoot, farFoot))
        return p
    }

    /// Hands and shoes on a window's side toward `facing`: the far arm reaches
    /// round behind her, soles flat on the frame, the far leg tucked under.
    private static func brace(_ p: inout Pose, facing f: CGFloat, hands: (near: CGPoint, far: CGPoint), feet: (near: CGPoint, far: CGPoint)) {
        if f > 0 {
            p.rightHand = hands.near; p.leftHand = hands.far; p.leftArmBehind = true
            p.rightFoot = feet.near; p.leftFoot = feet.far
            p.rightLegBend = 6; p.leftLegBend = -6
        } else {
            p.leftHand = hands.near; p.rightHand = hands.far; p.rightArmBehind = true
            p.leftFoot = feet.near; p.rightFoot = feet.far
            p.leftLegBend = 6; p.rightLegBend = -6
        }
        p.leftHandShape = .fist; p.rightHandShape = .fist
        p.leftHandAngle = 1.1; p.rightHandAngle = 1.1
        p.leftArmBend = 6; p.rightArmBend = 6
        p.leftFootAngle = 1.2; p.rightFootAngle = 1.2
        p.shadow = 0
    }

    /// Hand over hand up or down a window's side, shoes walking the frame.
    static func climb(_ c: MotionContext) -> Pose {
        var p = Pose()
        let f: CGFloat = c.facing >= 0 ? 1 : -1
        let v: CGFloat = c.climb >= 0 ? 1 : -1
        let s = stride(for: .climb)
        let a = c.walkPhase * 2 * .pi
        p.facing = 0.5 * f
        p.body = P(-4 * f, 94 + 2.5 * CGFloat(sin(2 * a)))
        p.tilt = 0.05 * f + 0.04 * CGFloat(sin(a))
        p.faceShift = P(0.35 * f, 0.35 * v)
        let nearStep = step(c.walkPhase, stride: s), farStep = step(c.walkPhase + 0.5, stride: s)
        let near = inBody(P(f * (clingGrip - 5 * nearStep.lift), 146 + v * nearStep.along), p)
        let far = inBody(P(f * (clingGrip - 5 * farStep.lift), 90 + v * farStep.along), p)
        // Each foot pushes off the frame with the opposite hand.
        let nearFoot = P(f * (58 - 6 * farStep.lift), 30 + v * farStep.along)
        let farFoot = P(f * (56 - 6 * nearStep.lift), 6 + v * nearStep.along)
        brace(&p, facing: f, hands: (near, far), feet: (nearFoot, farFoot))
        return p
    }
}
