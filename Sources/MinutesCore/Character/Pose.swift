import CoreGraphics

public enum HandShape: String, CaseIterable, Codable {
    case open, fist, point
}

public enum PupilStyle: String, CaseIterable, Codable {
    case round, heart
}

/// Every animatable channel of the character in one value type.
///
/// Coordinate spaces (points at scale 1, y up):
/// - **anchor space**: origin where she touches the surface (feet when standing,
///   seat when sitting). `body`, feet and the ground shadow live here.
/// - **body space**: origin at the body centre, rotated by `tilt`. Hands live here
///   so they ride along with the body.
///
/// Motions write the body/limb channels, expressions write the face channels and
/// the animator layers them; the renderer only ever sees a `Pose`.
public struct Pose: Equatable {
    // Body
    public var body = CGPoint(x: 0, y: 92)
    public var tilt: CGFloat = 0
    public var squash: CGFloat = 1
    public var facing: CGFloat = 0

    // Arms (hands in body space; bend > 0 bows the elbow outward)
    public var leftHand = CGPoint(x: -56, y: -38)
    public var rightHand = CGPoint(x: 56, y: -38)
    public var leftArmBend: CGFloat = 8
    public var rightArmBend: CGFloat = 8
    public var leftHandAngle: CGFloat = 0
    public var rightHandAngle: CGFloat = 0
    public var leftHandShape: HandShape = .open
    public var rightHandShape: HandShape = .open
    /// Drawn behind the body (the far arm when she is side-on: crawling, climbing).
    public var leftArmBehind = false
    public var rightArmBehind = false

    // Legs (feet in anchor space; bend > 0 bows the knee outward)
    public var leftFoot = CGPoint(x: -15, y: 0)
    public var rightFoot = CGPoint(x: 15, y: 0)
    public var leftLegBend: CGFloat = 2
    public var rightLegBend: CGFloat = 2
    public var leftFootAngle: CGFloat = 0
    public var rightFootAngle: CGFloat = 0

    // Face
    public var faceShift = CGPoint.zero
    public var look = CGPoint.zero
    public var eyeOpen: CGFloat = 1
    public var eyeWide: CGFloat = 0
    public var squint: CGFloat = 0
    public var browRaise: CGFloat = 0
    public var browTilt: CGFloat = 0
    public var smile: CGFloat = 0.45
    public var mouthOpen: CGFloat = 0
    public var mouthWide: CGFloat = 0
    public var blush: CGFloat = 0.3
    public var pupilStyle: PupilStyle = .round

    // Clock hands, radians clockwise from twelve. Not blended: the animator owns them.
    public var hourAngle: CGFloat = 0
    public var minuteAngle: CGFloat = 0

    // Presence (hologram)
    public var opacity: CGFloat = 1
    public var glitch: CGFloat = 0
    public var reveal: CGFloat = 1
    public var glow: CGFloat = 1
    public var shadow: CGFloat = 0
    /// Twirling away or back: turned this far (radians) about her vertical
    /// axis, the back of the clock showing past a quarter turn.
    public var twirl: CGFloat = 0
    /// Her whole figure scaled about the body centre (shrinking into a point).
    public var size: CGFloat = 1
    /// The rings whirling round her as she spins, 0…1.
    public var whirl: CGFloat = 0
    /// The glint she pops out of (or into), 0…1, drawn at the body centre.
    public var sparkle: CGFloat = 0

    public init() {}

    public static let rest = Pose()

    static let scalarChannels: [WritableKeyPath<Pose, CGFloat>] = [
        \.tilt, \.squash, \.facing,
        \.leftArmBend, \.rightArmBend, \.leftHandAngle, \.rightHandAngle,
        \.leftLegBend, \.rightLegBend, \.leftFootAngle, \.rightFootAngle,
        \.eyeOpen, \.eyeWide, \.squint, \.browRaise, \.browTilt, \.smile,
        \.mouthOpen, \.mouthWide, \.blush,
        \.opacity, \.glitch, \.reveal, \.glow, \.shadow,
        \.twirl, \.size, \.whirl, \.sparkle,
    ]

    static let pointChannels: [WritableKeyPath<Pose, CGPoint>] = [
        \.body, \.leftHand, \.rightHand, \.leftFoot, \.rightFoot, \.faceShift, \.look,
    ]

    static let shapeChannels: [WritableKeyPath<Pose, HandShape>] = [
        \.leftHandShape, \.rightHandShape,
    ]

    /// Channel-wise blend. Discrete channels switch at the halfway point.
    public static func mix(_ a: Pose, _ b: Pose, _ t: CGFloat) -> Pose {
        if t <= 0 { return a }
        if t >= 1 { return b }
        var out = a
        for key in scalarChannels { out[keyPath: key] = lerp(a[keyPath: key], b[keyPath: key], t) }
        for key in pointChannels { out[keyPath: key] = lerp(a[keyPath: key], b[keyPath: key], t) }
        for key in shapeChannels { out[keyPath: key] = t < 0.5 ? a[keyPath: key] : b[keyPath: key] }
        out.pupilStyle = t < 0.5 ? a.pupilStyle : b.pupilStyle
        out.leftArmBehind = t < 0.5 ? a.leftArmBehind : b.leftArmBehind
        out.rightArmBehind = t < 0.5 ? a.rightArmBehind : b.rightArmBehind
        return out
    }

    /// Copies only the body and limb channels from `source` (used to mix a
    /// motion into a pose without disturbing the face).
    public mutating func takeBody(from source: Pose) {
        body = source.body; tilt = source.tilt; squash = source.squash; facing = source.facing
        leftHand = source.leftHand; rightHand = source.rightHand
        leftArmBend = source.leftArmBend; rightArmBend = source.rightArmBend
        leftHandAngle = source.leftHandAngle; rightHandAngle = source.rightHandAngle
        leftHandShape = source.leftHandShape; rightHandShape = source.rightHandShape
        leftArmBehind = source.leftArmBehind; rightArmBehind = source.rightArmBehind
        leftFoot = source.leftFoot; rightFoot = source.rightFoot
        leftLegBend = source.leftLegBend; rightLegBend = source.rightLegBend
        leftFootAngle = source.leftFootAngle; rightFootAngle = source.rightFootAngle
        shadow = source.shadow
    }
}
