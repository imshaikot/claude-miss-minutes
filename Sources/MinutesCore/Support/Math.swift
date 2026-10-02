import CoreGraphics
import Foundation

// MARK: - Vector helpers

public extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
    static func += (a: inout CGPoint, b: CGPoint) { a = a + b }

    var length: CGFloat { (x * x + y * y).squareRoot() }

    var normalized: CGPoint {
        let l = length
        return l > 0.0001 ? CGPoint(x: x / l, y: y / l) : .zero
    }

    func rotated(by angle: CGFloat) -> CGPoint {
        let c = cos(angle), s = sin(angle)
        return CGPoint(x: x * c - y * s, y: x * s + y * c)
    }

    func distance(to other: CGPoint) -> CGFloat { (self - other).length }

    func clamped(to radius: CGFloat) -> CGPoint {
        let l = length
        return l > radius ? self * (radius / l) : self
    }
}

public func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
public func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
}

public func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
    min(max(value, lower), upper)
}

/// Maps `value` from `[a, b]` to `[0, 1]`, clamped.
public func progress(_ value: Double, from a: Double, to b: Double) -> CGFloat {
    guard b > a else { return value >= b ? 1 : 0 }
    return CGFloat(clamp((value - a) / (b - a), 0, 1))
}

// MARK: - Easing

/// Easing curves used by keyframes and procedural motion. All map 0…1 to 0…1
/// (the overshooting ones briefly leave that range).
public enum Ease: Equatable {
    case linear, `in`, out, inOut, backOut, elasticOut, hold

    public func callAsFunction(_ t: CGFloat) -> CGFloat {
        let t = clamp(t, 0, 1)
        switch self {
        case .linear: return t
        case .in: return t * t * t
        case .out: let u = 1 - t; return 1 - u * u * u
        case .inOut: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .backOut:
            let c1: CGFloat = 1.70158, c3 = c1 + 1
            return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
        case .elasticOut:
            if t == 0 || t == 1 { return t }
            return pow(2, -10 * t) * sin((t * 10 - 0.75) * (2 * .pi / 3)) + 1
        case .hold: return t < 1 ? 0 : 1
        }
    }
}

/// Hermite smoothstep.
public func smoothstep(_ t: CGFloat) -> CGFloat {
    let t = clamp(t, 0, 1)
    return t * t * (3 - 2 * t)
}

/// A 0→1→0 bump over `t ∈ [0, 1]`.
public func bump(_ t: CGFloat) -> CGFloat {
    guard t > 0, t < 1 else { return 0 }
    return sin(.pi * t)
}

// MARK: - Springs

/// A damped spring integrated with semi-implicit Euler in fixed sub-steps, which
/// keeps it stable at any frame rate. Used for secondary motion (pupils, inertia,
/// following a moving window).
public struct Spring: Equatable {
    public var value: CGFloat
    public var velocity: CGFloat = 0
    public var stiffness: CGFloat
    public var damping: CGFloat

    public init(value: CGFloat = 0, stiffness: CGFloat = 170, dampingRatio: CGFloat = 0.8) {
        self.value = value
        self.stiffness = stiffness
        self.damping = 2 * dampingRatio * stiffness.squareRoot()
    }

    public mutating func step(toward target: CGFloat, dt: Double) {
        var remaining = CGFloat(min(dt, 0.1))
        let h: CGFloat = 1.0 / 240.0
        while remaining > 0 {
            let s = min(h, remaining)
            let force = -stiffness * (value - target) - damping * velocity
            velocity += force * s
            value += velocity * s
            remaining -= s
        }
    }
}

public struct Spring2D: Equatable {
    public var x: Spring
    public var y: Spring

    public init(value: CGPoint = .zero, stiffness: CGFloat = 170, dampingRatio: CGFloat = 0.8) {
        x = Spring(value: value.x, stiffness: stiffness, dampingRatio: dampingRatio)
        y = Spring(value: value.y, stiffness: stiffness, dampingRatio: dampingRatio)
    }

    public var value: CGPoint {
        get { CGPoint(x: x.value, y: y.value) }
        set { x.value = newValue.x; y.value = newValue.y }
    }

    public var velocity: CGPoint { CGPoint(x: x.velocity, y: y.velocity) }

    public mutating func step(toward target: CGPoint, dt: Double) {
        x.step(toward: target.x, dt: dt)
        y.step(toward: target.y, dt: dt)
    }
}

// MARK: - Randomness and noise

/// Deterministic generator (SplitMix64) so behaviour can be replayed in tests.
public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Smooth 1D value noise in -1…1. Cheap organic wobble for idle motion.
public func noise(_ x: Double, seed: Int = 0) -> CGFloat {
    func hash(_ i: Int) -> Double {
        var h = UInt64(bitPattern: Int64(i &* 374_761_393 &+ seed &* 668_265_263))
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Double(h % 10_000) / 5_000.0 - 1.0
    }
    let i = Int(floor(x))
    let f = x - floor(x)
    let u = f * f * (3 - 2 * f)
    return CGFloat(hash(i) * (1 - u) + hash(i + 1) * u)
}
