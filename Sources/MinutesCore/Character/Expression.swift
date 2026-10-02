import CoreGraphics

/// Named moods. The body tool `emote` and the director speak in moods; the
/// `Expression` table turns each into face channel values.
public enum Mood: String, CaseIterable, Codable {
    case neutral, happy, excited, thinking, surprised, sly, sad, annoyed, love, worried, sleepy
}

public struct Expression: Equatable {
    public var smile: CGFloat = 0.45
    public var mouthOpen: CGFloat = 0
    public var mouthWide: CGFloat = 0
    public var browRaise: CGFloat = 0
    public var browTilt: CGFloat = 0
    public var squint: CGFloat = 0
    public var eyeWide: CGFloat = 0
    public var eyeOpen: CGFloat = 1
    public var blush: CGFloat = 0.3
    public var pupil: PupilStyle = .round
    public var lookBias = CGPoint.zero

    public init() {}

    init(_ configure: (inout Expression) -> Void) {
        var e = Expression()
        configure(&e)
        self = e
    }

    /// The model sheet for faces.
    public static func of(_ mood: Mood) -> Expression {
        switch mood {
        case .neutral:
            return Expression { $0.smile = 0.2; $0.blush = 0.2 }
        case .happy:
            return Expression { $0.smile = 0.75; $0.squint = 0.12; $0.browRaise = 0.2; $0.blush = 0.4 }
        case .excited:
            return Expression {
                $0.smile = 1; $0.mouthOpen = 0.45; $0.mouthWide = 0.4; $0.browRaise = 0.7
                $0.eyeWide = 0.35; $0.blush = 0.6
            }
        case .thinking:
            return Expression {
                $0.smile = 0.05; $0.browRaise = 0.25; $0.browTilt = -0.35; $0.squint = 0.2
                $0.lookBias = CGPoint(x: 0.6, y: 0.75)
            }
        case .surprised:
            return Expression {
                $0.smile = 0; $0.mouthOpen = 0.7; $0.mouthWide = -0.8; $0.browRaise = 1
                $0.eyeWide = 0.7; $0.blush = 0.2
            }
        case .sly:
            return Expression {
                $0.smile = 0.6; $0.squint = 0.45; $0.browRaise = 0.35; $0.browTilt = 0.25
                $0.lookBias = CGPoint(x: -0.55, y: 0); $0.blush = 0.35
            }
        case .sad:
            return Expression {
                $0.smile = -0.55; $0.browRaise = 0.3; $0.browTilt = -0.8; $0.eyeOpen = 0.8
                $0.lookBias = CGPoint(x: 0, y: -0.5); $0.blush = 0.15
            }
        case .annoyed:
            return Expression {
                $0.smile = -0.25; $0.browRaise = -0.4; $0.browTilt = 0.8; $0.squint = 0.4; $0.blush = 0.15
            }
        case .love:
            return Expression {
                $0.smile = 0.85; $0.browRaise = 0.4; $0.blush = 1; $0.pupil = .heart; $0.eyeWide = 0.15
            }
        case .worried:
            return Expression {
                $0.smile = -0.2; $0.mouthOpen = 0.12; $0.mouthWide = -0.3; $0.browRaise = 0.6
                $0.browTilt = -0.7; $0.eyeWide = 0.25
            }
        case .sleepy:
            return Expression { $0.smile = 0.25; $0.eyeOpen = 0.35; $0.browRaise = -0.2; $0.blush = 0.25 }
        }
    }

    public static func mix(_ a: Expression, _ b: Expression, _ t: CGFloat) -> Expression {
        if t <= 0 { return a }
        if t >= 1 { return b }
        var e = Expression()
        e.smile = lerp(a.smile, b.smile, t)
        e.mouthOpen = lerp(a.mouthOpen, b.mouthOpen, t)
        e.mouthWide = lerp(a.mouthWide, b.mouthWide, t)
        e.browRaise = lerp(a.browRaise, b.browRaise, t)
        e.browTilt = lerp(a.browTilt, b.browTilt, t)
        e.squint = lerp(a.squint, b.squint, t)
        e.eyeWide = lerp(a.eyeWide, b.eyeWide, t)
        e.eyeOpen = lerp(a.eyeOpen, b.eyeOpen, t)
        e.blush = lerp(a.blush, b.blush, t)
        e.pupil = t < 0.5 ? a.pupil : b.pupil
        e.lookBias = lerp(a.lookBias, b.lookBias, t)
        return e
    }

    public func apply(to pose: inout Pose) {
        pose.smile = smile
        pose.mouthOpen = mouthOpen
        pose.mouthWide = mouthWide
        pose.browRaise = browRaise
        pose.browTilt = browTilt
        pose.squint = squint
        pose.eyeWide = eyeWide
        pose.eyeOpen = eyeOpen
        pose.blush = blush
        pose.pupilStyle = pupil
    }
}
