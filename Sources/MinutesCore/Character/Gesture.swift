import CoreGraphics

// MARK: - Keyframes

/// A keyframe; `ease` shapes the approach *to* this key from the previous one.
public struct Key<Value> {
    public var time: Double
    public var value: Value
    public var ease: Ease

    public init(_ time: Double, _ value: Value, _ ease: Ease = .inOut) {
        self.time = time
        self.value = value
        self.ease = ease
    }
}

func sample<Value>(_ keys: [Key<Value>], at t: Double, _ mix: (Value, Value, CGFloat) -> Value) -> Value {
    precondition(!keys.isEmpty, "a track needs at least one key")
    if t <= keys[0].time { return keys[0].value }
    for i in 1..<keys.count where t <= keys[i].time {
        let a = keys[i - 1], b = keys[i]
        let u = CGFloat((t - a.time) / max(b.time - a.time, 0.0001))
        return mix(a.value, b.value, b.ease(u))
    }
    return keys[keys.count - 1].value
}

/// One animated channel inside a gesture. Tracks are type-erased closures so a
/// gesture can be declared as a plain list.
public struct Track {
    public enum Mode { case override, additive }

    let apply: (inout Pose, Double, CGFloat) -> Void

    public static func scalar(_ channel: WritableKeyPath<Pose, CGFloat>, _ keys: [Key<CGFloat>], _ mode: Mode = .override) -> Track {
        Track { pose, t, w in
            let v = sample(keys, at: t, lerp)
            switch mode {
            case .override: pose[keyPath: channel] = lerp(pose[keyPath: channel], v, w)
            case .additive: pose[keyPath: channel] += v * w
            }
        }
    }

    public static func point(_ channel: WritableKeyPath<Pose, CGPoint>, _ keys: [Key<CGPoint>], _ mode: Mode = .override) -> Track {
        Track { pose, t, w in
            let v = sample(keys, at: t, lerp)
            switch mode {
            case .override: pose[keyPath: channel] = lerp(pose[keyPath: channel], v, w)
            case .additive: pose[keyPath: channel] += v * w
            }
        }
    }

    public static func shape(_ channel: WritableKeyPath<Pose, HandShape>, _ value: HandShape) -> Track {
        Track { pose, _, w in if w > 0.5 { pose[keyPath: channel] = value } }
    }

    /// An additive sine oscillation, for shakes and rings.
    public static func oscillate(_ channel: WritableKeyPath<Pose, CGFloat>, amplitude: CGFloat, hertz: Double) -> Track {
        Track { pose, t, w in pose[keyPath: channel] += amplitude * CGFloat(sin(t * hertz * 2 * .pi)) * w }
    }
}

// MARK: - Gestures

public enum GestureName: String, CaseIterable, Codable {
    case wave, point, shrug, clap, jump, bow, nod
    case shakeHead = "shake_head"
    case ring
    case tapFoot = "tap_foot"
    case explain
    case lookAround = "look_around"
    case stretch
    case blowKiss = "blow_kiss"
}

/// Looping arm/face layers that hold while the assistant is in a phase.
public enum Activity: String, CaseIterable, Codable {
    case listen, think, talk, ask
}

/// A keyframed overlay on top of the base motion. Override tracks pull channels
/// toward their keys by the gesture's weight; additive tracks add on top.
public struct Gesture {
    public var name: String
    public var duration: Double
    public var fadeIn: Double
    public var fadeOut: Double
    public var loops: Bool
    public var mood: Mood?
    public var tracks: [Track]

    public init(_ name: String, duration: Double, fadeIn: Double = 0.18, fadeOut: Double = 0.28,
                loops: Bool = false, mood: Mood? = nil, tracks: [Track]) {
        self.name = name
        self.duration = duration
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.loops = loops
        self.mood = mood
        self.tracks = tracks
    }

    /// Envelope weight at local time `t` (loops only fade in; the animator fades them out).
    public func weight(at t: Double) -> CGFloat {
        let fin = smoothstep(CGFloat(t / max(fadeIn, 0.001)))
        if loops { return fin }
        let fout = smoothstep(CGFloat((duration - t) / max(fadeOut, 0.001)))
        return min(fin, fout)
    }

    public func isFinished(at t: Double) -> Bool { !loops && t >= duration }

    public func apply(to pose: inout Pose, at t: Double, weight: CGFloat) {
        guard weight > 0.001 else { return }
        let local = loops ? t.truncatingRemainder(dividingBy: duration) : min(t, duration)
        for track in tracks { track.apply(&pose, local, weight) }
    }
}

private func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

/// The gesture library. Coordinates are body space at scale 1: shoulders sit at
/// (±47, -6), relaxed hands at (±56, -38), the chin at about (0, -44).
public enum Gestures {
    public static let shoulderRight = P(47, -6)
    public static let shoulderLeft = P(-47, -6)

    public static func make(_ name: GestureName, toward direction: CGPoint = CGPoint(x: 1, y: 0.2)) -> Gesture {
        switch name {
        case .wave: return wave
        case .point: return point(toward: direction)
        case .shrug: return shrug
        case .clap: return clap
        case .jump: return jump
        case .bow: return bow
        case .nod: return nod
        case .shakeHead: return shakeHead
        case .ring: return ring
        case .tapFoot: return tapFoot
        case .explain: return explain
        case .lookAround: return lookAround
        case .stretch: return stretch
        case .blowKiss: return blowKiss
        }
    }

    public static func loop(for activity: Activity) -> Gesture {
        switch activity {
        case .listen: return listen
        case .think: return think
        case .talk: return talk
        case .ask: return ask
        }
    }

    static let wave = Gesture("wave", duration: 1.9, mood: .happy, tracks: [
        .point(\.rightHand, [Key(0, P(56, -38)), Key(0.28, P(64, 48), .backOut), Key(1.9, P(64, 48))]),
        .scalar(\.rightArmBend, [Key(0, 8), Key(0.28, -14)]),
        .scalar(\.rightHandAngle, [
            Key(0.28, 0), Key(0.45, 0.5), Key(0.62, -0.35), Key(0.79, 0.5), Key(0.96, -0.35),
            Key(1.13, 0.5), Key(1.30, -0.35), Key(1.47, 0.35), Key(1.62, 0),
        ]),
        .shape(\.rightHandShape, .open),
        .scalar(\.tilt, [Key(0, 0), Key(0.3, -0.06), Key(1.6, -0.06), Key(1.9, 0)], .additive),
        .point(\.body, [Key(0, .zero), Key(0.35, P(0, 3)), Key(0.7, .zero), Key(1.05, P(0, 3)), Key(1.4, .zero)], .additive),
    ])

    static func point(toward direction: CGPoint) -> Gesture {
        let d = direction.normalized == .zero ? P(1, 0) : direction.normalized
        let right = d.x >= 0
        let shoulder = right ? shoulderRight : shoulderLeft
        let target = shoulder + d * 66
        let hand: WritableKeyPath<Pose, CGPoint> = right ? \.rightHand : \.leftHand
        let bend: WritableKeyPath<Pose, CGFloat> = right ? \.rightArmBend : \.leftArmBend
        let shape: WritableKeyPath<Pose, HandShape> = right ? \.rightHandShape : \.leftHandShape
        let angle: WritableKeyPath<Pose, CGFloat> = right ? \.rightHandAngle : \.leftHandAngle
        return Gesture("point", duration: 1.8, mood: .sly, tracks: [
            .point(hand, [Key(0, right ? P(56, -38) : P(-56, -38)), Key(0.3, target, .backOut), Key(1.8, target)]),
            .scalar(bend, [Key(0, 8), Key(0.3, 0)]),
            .scalar(angle, [Key(0, 0)]),
            .shape(shape, .point),
            .scalar(\.tilt, [Key(0, 0), Key(0.3, right ? -0.05 : 0.05)], .additive),
            .point(\.faceShift, [Key(0, .zero), Key(0.3, P(d.x * 0.5, d.y * 0.3))], .additive),
        ])
    }

    static let shrug = Gesture("shrug", duration: 1.5, tracks: [
        .point(\.leftHand, [Key(0, P(-56, -38)), Key(0.3, P(-64, 6), .backOut), Key(1.5, P(-64, 6))]),
        .point(\.rightHand, [Key(0, P(56, -38)), Key(0.3, P(64, 6), .backOut), Key(1.5, P(64, 6))]),
        .scalar(\.leftArmBend, [Key(0, 8), Key(0.3, 14)]),
        .scalar(\.rightArmBend, [Key(0, 8), Key(0.3, 14)]),
        .scalar(\.leftHandAngle, [Key(0, 0), Key(0.3, 1.1)]),
        .scalar(\.rightHandAngle, [Key(0, 0), Key(0.3, 1.1)]),
        .shape(\.leftHandShape, .open), .shape(\.rightHandShape, .open),
        .point(\.body, [Key(0, .zero), Key(0.3, P(0, 5), .backOut), Key(1.1, P(0, 5)), Key(1.5, .zero)], .additive),
        .scalar(\.browRaise, [Key(0, 0), Key(0.3, 0.7)], .additive),
        .scalar(\.smile, [Key(0, 0), Key(0.3, -0.25)], .additive),
    ])

    static let clap: Gesture = {
        var left: [Key<CGPoint>] = [Key(0, P(-56, -38))]
        var right: [Key<CGPoint>] = [Key(0, P(56, -38))]
        var t = 0.2
        for _ in 0..<5 {
            left.append(Key(t, P(-32, -34), .out)); right.append(Key(t, P(32, -34), .out))
            left.append(Key(t + 0.12, P(-8, -42), .in)); right.append(Key(t + 0.12, P(8, -42), .in))
            t += 0.26
        }
        return Gesture("clap", duration: t + 0.1, mood: .excited, tracks: [
            .point(\.leftHand, left), .point(\.rightHand, right),
            .scalar(\.leftArmBend, [Key(0, 8), Key(0.2, 10)]),
            .scalar(\.rightArmBend, [Key(0, 8), Key(0.2, 10)]),
            .scalar(\.leftHandAngle, [Key(0, 0), Key(0.2, -0.9)]),
            .scalar(\.rightHandAngle, [Key(0, 0), Key(0.2, -0.9)]),
            .shape(\.leftHandShape, .open), .shape(\.rightHandShape, .open),
            .point(\.body, [Key(0, .zero), Key(0.3, P(0, 3)), Key(0.56, .zero), Key(0.82, P(0, 3)), Key(1.08, .zero), Key(1.34, P(0, 3)), Key(1.6, .zero)], .additive),
        ])
    }()

    static let jump = Gesture("jump", duration: 1.05, fadeIn: 0.05, fadeOut: 0.15, mood: .excited, tracks: [
        .point(\.body, [Key(0, .zero), Key(0.15, P(0, -9), .out), Key(0.42, P(0, 40), .out), Key(0.68, .zero, .in), Key(0.78, P(0, -7), .out), Key(1.05, .zero)], .additive),
        .scalar(\.squash, [Key(0, 0), Key(0.15, -0.12), Key(0.25, 0.14), Key(0.42, 0), Key(0.66, 0.08), Key(0.78, -0.16), Key(1.05, 0)], .additive),
        .point(\.leftFoot, [Key(0, .zero), Key(0.2, .zero), Key(0.42, P(4, 30), .out), Key(0.68, .zero, .in)], .additive),
        .point(\.rightFoot, [Key(0, .zero), Key(0.2, .zero), Key(0.42, P(-4, 30), .out), Key(0.68, .zero, .in)], .additive),
        .point(\.leftHand, [Key(0, P(-56, -38)), Key(0.25, P(-54, 34), .backOut), Key(0.7, P(-54, 30)), Key(1.0, P(-56, -38))]),
        .point(\.rightHand, [Key(0, P(56, -38)), Key(0.25, P(54, 34), .backOut), Key(0.7, P(54, 30)), Key(1.0, P(56, -38))]),
        .scalar(\.leftArmBend, [Key(0, 8), Key(0.25, -10), Key(1.0, 8)]),
        .scalar(\.rightArmBend, [Key(0, 8), Key(0.25, -10), Key(1.0, 8)]),
    ])

    static let bow = Gesture("bow", duration: 1.8, tracks: [
        .point(\.body, [Key(0, .zero), Key(0.4, P(0, -14)), Key(1.15, P(0, -14)), Key(1.6, .zero)], .additive),
        .scalar(\.squash, [Key(0, 0), Key(0.4, -0.06), Key(1.15, -0.06), Key(1.6, 0)], .additive),
        .point(\.rightHand, [Key(0, P(56, -38)), Key(0.4, P(-4, -30)), Key(1.8, P(-4, -30))]),
        .point(\.leftHand, [Key(0, P(-56, -38)), Key(0.4, P(-68, 12), .backOut), Key(1.8, P(-68, 12))]),
        .scalar(\.leftHandAngle, [Key(0, 0), Key(0.4, 0.8)]),
        .scalar(\.rightArmBend, [Key(0, 8), Key(0.4, 18)]),
        .point(\.faceShift, [Key(0, .zero), Key(0.4, P(0, -0.7)), Key(1.15, P(0, -0.7)), Key(1.6, .zero)], .additive),
        .scalar(\.eyeOpen, [Key(0, 1), Key(0.35, 0.08), Key(1.15, 0.08), Key(1.5, 1)]),
        .scalar(\.smile, [Key(0, 0), Key(0.4, 0.3)], .additive),
    ])

    static let nod = Gesture("nod", duration: 0.9, fadeIn: 0.08, fadeOut: 0.12, tracks: [
        .point(\.faceShift, [Key(0, .zero), Key(0.15, P(0, -0.7)), Key(0.35, P(0, 0.25)), Key(0.55, P(0, -0.6)), Key(0.75, P(0, 0.15)), Key(0.9, .zero)], .additive),
        .point(\.body, [Key(0, .zero), Key(0.15, P(0, -2)), Key(0.35, .zero), Key(0.55, P(0, -2)), Key(0.9, .zero)], .additive),
    ])

    static let shakeHead = Gesture("shake_head", duration: 1.0, fadeIn: 0.08, fadeOut: 0.12, tracks: [
        .point(\.faceShift, [Key(0, .zero), Key(0.15, P(-0.7, 0)), Key(0.35, P(0.7, 0)), Key(0.55, P(-0.6, 0)), Key(0.75, P(0.5, 0)), Key(1.0, .zero)], .additive),
        .scalar(\.tilt, [Key(0, 0), Key(0.15, 0.04), Key(0.35, -0.04), Key(0.55, 0.03), Key(0.75, -0.03), Key(1.0, 0)], .additive),
    ])

    static let ring = Gesture("ring", duration: 1.8, fadeIn: 0.06, fadeOut: 0.2, mood: .excited, tracks: [
        .oscillate(\.tilt, amplitude: 0.13, hertz: 15),
        .oscillate(\.squash, amplitude: 0.03, hertz: 30),
        .point(\.body, [Key(0, .zero), Key(0.1, P(0, 6)), Key(1.8, P(0, 6))], .additive),
        .point(\.leftHand, [Key(0, P(-56, -38)), Key(0.15, P(-58, 30), .backOut)]),
        .point(\.rightHand, [Key(0, P(56, -38)), Key(0.15, P(58, 30), .backOut)]),
        .scalar(\.leftArmBend, [Key(0, 8), Key(0.15, -8)]),
        .scalar(\.rightArmBend, [Key(0, 8), Key(0.15, -8)]),
        .oscillate(\.leftHandAngle, amplitude: 0.4, hertz: 7),
        .oscillate(\.rightHandAngle, amplitude: 0.4, hertz: 7),
    ])

    static let tapFoot: Gesture = {
        var taps: [Key<CGFloat>] = [Key(0, 0)]
        var t = 0.25
        for _ in 0..<5 { taps.append(Key(t, 0.45, .out)); taps.append(Key(t + 0.16, 0, .in)); t += 0.34 }
        return Gesture("tap_foot", duration: t + 0.2, mood: .annoyed, tracks: [
            .scalar(\.rightFootAngle, taps),
            .point(\.rightFoot, [Key(0, .zero)], .additive),
            .point(\.leftHand, [Key(0, P(-56, -38)), Key(0.25, P(-50, -30))]),
            .point(\.rightHand, [Key(0, P(56, -38)), Key(0.25, P(50, -30))]),
            .scalar(\.leftArmBend, [Key(0, 8), Key(0.25, 24)]),
            .scalar(\.rightArmBend, [Key(0, 8), Key(0.25, 24)]),
            .shape(\.leftHandShape, .fist), .shape(\.rightHandShape, .fist),
        ])
    }()

    static let explain = Gesture("explain", duration: 1.6, tracks: [
        .point(\.rightHand, [Key(0, P(56, -38)), Key(0.35, P(62, -8), .backOut), Key(1.0, P(56, -14)), Key(1.6, P(56, -38))]),
        .scalar(\.rightHandAngle, [Key(0, 0), Key(0.35, 1.0)]),
        .scalar(\.rightArmBend, [Key(0, 8), Key(0.35, 16)]),
        .shape(\.rightHandShape, .open),
    ])

    static let lookAround = Gesture("look_around", duration: 2.6, tracks: [
        .point(\.look, [Key(0, .zero), Key(0.4, P(-0.9, 0.1)), Key(1.1, P(-0.9, 0.1)), Key(1.5, P(0.9, 0.25)), Key(2.2, P(0.9, 0.25)), Key(2.6, .zero)], .additive),
        .point(\.faceShift, [Key(0, .zero), Key(0.4, P(-0.5, 0)), Key(1.1, P(-0.5, 0)), Key(1.5, P(0.5, 0.1)), Key(2.2, P(0.5, 0.1)), Key(2.6, .zero)], .additive),
    ])

    static let stretch = Gesture("stretch", duration: 2.4, mood: .sleepy, tracks: [
        .point(\.leftHand, [Key(0, P(-56, -38)), Key(0.5, P(-34, 72), .out), Key(1.9, P(-36, 70))]),
        .point(\.rightHand, [Key(0, P(56, -38)), Key(0.5, P(34, 72), .out), Key(1.9, P(36, 70))]),
        .scalar(\.leftArmBend, [Key(0, 8), Key(0.5, -6)]),
        .scalar(\.rightArmBend, [Key(0, 8), Key(0.5, -6)]),
        .scalar(\.squash, [Key(0, 0), Key(0.5, 0.08), Key(1.9, 0.08), Key(2.4, 0)], .additive),
        .scalar(\.mouthOpen, [Key(0, 0), Key(0.6, 0.85), Key(1.6, 0.85), Key(2.0, 0)]),
        .scalar(\.mouthWide, [Key(0, 0), Key(0.6, -0.5)]),
        .scalar(\.eyeOpen, [Key(0, 1), Key(0.5, 0.1), Key(1.7, 0.1), Key(2.1, 1)]),
    ])

    static let blowKiss = Gesture("blow_kiss", duration: 1.7, mood: .love, tracks: [
        .point(\.rightHand, [Key(0, P(56, -38)), Key(0.35, P(10, -26)), Key(0.6, P(10, -26)), Key(0.9, P(66, 14), .backOut), Key(1.7, P(66, 14))]),
        .scalar(\.rightArmBend, [Key(0, 8), Key(0.35, 22), Key(0.9, 0)]),
        .scalar(\.rightHandAngle, [Key(0, 0), Key(0.35, 1.2), Key(0.9, 0.6)]),
        .shape(\.rightHandShape, .open),
        .scalar(\.mouthWide, [Key(0, 0), Key(0.3, -1), Key(0.7, -1), Key(0.9, 0)]),
        .scalar(\.mouthOpen, [Key(0, 0), Key(0.3, 0.12), Key(0.7, 0.12), Key(0.9, 0)]),
        .scalar(\.smile, [Key(0, 0), Key(0.3, -0.3), Key(0.7, -0.3), Key(0.9, 0.2)], .additive),
    ])

    // MARK: Activity loops (first key == last key so they cycle seamlessly)

    static let listen = Gesture("listen", duration: 3.2, fadeIn: 0.3, loops: true, mood: .happy, tracks: [
        .point(\.leftHand, [Key(0, P(-12, -44)), Key(1.6, P(-12, -42)), Key(3.2, P(-12, -44))]),
        .point(\.rightHand, [Key(0, P(12, -44)), Key(1.6, P(12, -42)), Key(3.2, P(12, -44))]),
        .scalar(\.leftArmBend, [Key(0, 18)]), .scalar(\.rightArmBend, [Key(0, 18)]),
        .scalar(\.leftHandAngle, [Key(0, -1.0)]), .scalar(\.rightHandAngle, [Key(0, -1.0)]),
        .shape(\.leftHandShape, .open), .shape(\.rightHandShape, .open),
        .scalar(\.tilt, [Key(0, 0.0), Key(1.6, 0.05), Key(3.2, 0.0)], .additive),
    ])

    static let think = Gesture("think", duration: 2.4, fadeIn: 0.3, loops: true, mood: .thinking, tracks: [
        .point(\.rightHand, [Key(0, P(20, -54)), Key(1.2, P(21, -52)), Key(2.4, P(20, -54))]),
        .scalar(\.rightArmBend, [Key(0, 26)]),
        .scalar(\.rightHandAngle, [Key(0, 1.4)]),
        .shape(\.rightHandShape, .fist),
        .point(\.leftHand, [Key(0, P(-50, -30))]),
        .scalar(\.leftArmBend, [Key(0, 26)]),
        .shape(\.leftHandShape, .fist),
        .scalar(\.tilt, [Key(0, 0.04), Key(1.2, 0.08), Key(2.4, 0.04)], .additive),
    ])

    static let talk = Gesture("talk", duration: 2.8, fadeIn: 0.35, loops: true, mood: .happy, tracks: [
        .point(\.rightHand, [Key(0, P(58, -26)), Key(0.7, P(63, -8)), Key(1.4, P(57, -20)), Key(2.1, P(64, -4)), Key(2.8, P(58, -26))]),
        .scalar(\.rightHandAngle, [Key(0, 0.7), Key(0.7, 1.0), Key(1.4, 0.6), Key(2.1, 1.0), Key(2.8, 0.7)]),
        .scalar(\.rightArmBend, [Key(0, 16)]),
        .shape(\.rightHandShape, .open),
        .point(\.leftHand, [Key(0, P(-50, -30))]),
        .scalar(\.leftArmBend, [Key(0, 26)]),
        .shape(\.leftHandShape, .fist),
    ])

    static let ask = Gesture("ask", duration: 2.0, fadeIn: 0.3, loops: true, mood: .worried, tracks: [
        .point(\.leftHand, [Key(0, P(-10, -34)), Key(1.0, P(-10, -31)), Key(2.0, P(-10, -34))]),
        .point(\.rightHand, [Key(0, P(10, -34)), Key(1.0, P(10, -31)), Key(2.0, P(10, -34))]),
        .scalar(\.leftArmBend, [Key(0, 22)]), .scalar(\.rightArmBend, [Key(0, 22)]),
        .scalar(\.leftHandAngle, [Key(0, -1.3)]), .scalar(\.rightHandAngle, [Key(0, -1.3)]),
        .shape(\.leftHandShape, .open), .shape(\.rightHandShape, .open),
        .scalar(\.tilt, [Key(0, -0.03), Key(1.0, 0.03), Key(2.0, -0.03)], .additive),
    ])
}
