import CoreGraphics

/// The model sheet: proportions and colours of the character, at scale 1.
/// The renderer reads only from here, so restyling her is a one-file change.
public enum Rig {
    /// Body ellipse radii.
    public static let body = CGSize(width: 54, height: 50)
    public static let bezel: CGFloat = 7
    public static let outline: CGFloat = 2.6
    public static let limb: CGFloat = 4.8
    /// Rubber-hose characters wear oversized gloves and shoes.
    public static let gloveScale: CGFloat = 1.22
    public static let shoeScale: CGFloat = 1.12
    public static let shoulder = CGPoint(x: 47, y: -6)
    public static let hip = CGPoint(x: 17, y: -44)
    public static let eye = CGPoint(x: 17, y: 12)
    public static let eyeSize = CGSize(width: 16, height: 22.5)
    public static let brow = CGPoint(x: 18, y: 33)
    public static let clockPivot = CGPoint(x: 0, y: -5)
    public static let mouth = CGPoint(x: 0, y: -25)
    public static let cheek = CGPoint(x: 31, y: -13)

    /// The drawing canvas at scale 1 and the anchor's position inside it.
    /// Wide and tall enough for raised arms, hops and dangling legs.
    public static let canvas = CGSize(width: 300, height: 330)
    public static let anchorInCanvas = CGPoint(x: 150, y: 86)

    /// Anchor-space height of the top of her head when standing (for bubble placement).
    public static let headTop: CGFloat = 92 + 50 + 18
}

enum Palette {
    static let outline = rgb(0x47, 0x1F, 0x07)
    static let bezel = rgb(0xD6, 0x5A, 0x10)
    static let faceLight = rgb(0xFF, 0xC4, 0x5E)
    static let faceDark = rgb(0xF0, 0x86, 0x1E)
    static let lid = rgb(0xF6, 0x9A, 0x30)
    static let tick = rgb(0x8A, 0x40, 0x0E)
    static let clockHand = rgb(0x47, 0x1F, 0x07)
    static let pivot = rgb(0xFF, 0xE2, 0x9C)
    static let eyeWhite = rgb(0xFF, 0xFC, 0xF4)
    static let pupil = rgb(0x1C, 0x0E, 0x06)
    static let lips = rgb(0xD0, 0x1E, 0x36)
    static let mouthInside = rgb(0x6A, 0x0E, 0x12)
    static let tongue = rgb(0xEE, 0x5C, 0x6C)
    static let blush = rgb(0xFF, 0x62, 0x74)
    static let heart = rgb(0xE8, 0x1E, 0x46)
    static let limb = rgb(0x1C, 0x10, 0x0A)
    static let glove = rgb(0xFF, 0xFF, 0xFF)
    static let gloveDetail = rgb(0xC9, 0xBF, 0xB4)
    static let shoe = rgb(0x5C, 0x26, 0x0C)
    static let knob = rgb(0xE2, 0x6C, 0x18)
    static let glow = rgb(0xFF, 0x96, 0x28)
    static let scan = rgb(0xFF, 0xF2, 0xD0)
    static let ghostA = rgb(0x20, 0xE0, 0xFF)
    static let ghostB = rgb(0xFF, 0x30, 0x60)

    static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }
}
