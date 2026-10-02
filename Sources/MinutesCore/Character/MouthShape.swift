import CoreGraphics

/// What the voice tells the face each frame: how open the jaw is and whether the
/// lips are rounded (`wide < 0`, "oo") or stretched (`wide > 0`, "ee").
public struct MouthShape: Equatable {
    public var open: CGFloat
    public var wide: CGFloat

    public init(open: CGFloat, wide: CGFloat) {
        self.open = open
        self.wide = wide
    }

    public static let closed = MouthShape(open: 0, wide: 0)
}

/// Letter-level mouth shapes. Coarse on purpose: cartoon lip sync reads well with
/// a handful of shapes, and the jaw itself is driven by real audio amplitude.
public enum Phonetics {
    public static func shape(for character: Character) -> MouthShape? {
        switch character.lowercased().first ?? " " {
        case "a": return MouthShape(open: 0.9, wide: 0.15)
        case "e": return MouthShape(open: 0.55, wide: 0.7)
        case "i", "y": return MouthShape(open: 0.45, wide: 0.85)
        case "o": return MouthShape(open: 0.75, wide: -0.75)
        case "u", "w", "q": return MouthShape(open: 0.4, wide: -0.95)
        case "m", "b", "p": return MouthShape(open: 0, wide: 0)
        case "f", "v": return MouthShape(open: 0.15, wide: 0.4)
        case "s", "z", "t", "d", "n", "c", "k", "g", "j", "h", "r", "l", "x": return MouthShape(open: 0.25, wide: 0.35)
        default: return nil
        }
    }

    /// The lip rounding around a fractional position in `text` (0…1), taken from
    /// the nearest letter that has a shape.
    public static func wideness(in text: String, at fraction: Double) -> CGFloat {
        let chars = Array(text)
        guard !chars.isEmpty else { return 0 }
        let center = clamp(Int(Double(chars.count - 1) * fraction), 0, chars.count - 1)
        for radius in 0..<6 {
            for index in [center + radius, center - radius] where index >= 0 && index < chars.count {
                if let shape = shape(for: chars[index]) { return shape.wide }
            }
        }
        return 0
    }

    /// A synthetic jaw curve for when no audio amplitude is available: one bump
    /// per vowel group across the word's duration.
    public static func syntheticOpen(word: String, at fraction: Double) -> CGFloat {
        let vowels = word.lowercased().filter { "aeiouy".contains($0) }
        let syllables = max(1, vowels.count)
        let local = (fraction * Double(syllables)).truncatingRemainder(dividingBy: 1)
        let peak = vowels.isEmpty ? 0.35 : (shape(for: vowels[vowels.index(vowels.startIndex, offsetBy: min(syllables - 1, Int(fraction * Double(syllables))))])?.open ?? 0.5)
        return bump(CGFloat(local)) * peak
    }
}
