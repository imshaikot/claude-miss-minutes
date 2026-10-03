import AppKit
import MinutesCharacter
import MinutesCore

/// Command-line rendering modes, used by the build script (icon) and for
/// reviewing the character without launching the overlay (sheet).
enum RenderCommands {
    static func sheet(to path: String) -> Int32 {
        guard let image = CharacterSnapshot.sheet(ModelSheet.all, columns: 6) else { return 1 }
        return write(image, path)
    }

    /// The 1024 px app icon: her face over a TVA-green squircle with an amber glow.
    static func icon(to path: String) -> Int32 {
        let size = 1024
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        let s = CGFloat(size)
        let inset = s * 0.06
        let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let squircle = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.height * 0.225, transform: nil)
        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()
        let colors = [CGColor(srgbRed: 0.16, green: 0.30, blue: 0.26, alpha: 1), CGColor(srgbRed: 0.05, green: 0.11, blue: 0.10, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: .zero, options: [])
        // Faint scanlines, the hologram projector's signature.
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.035))
        for y in stride(from: CGFloat(0), to: s, by: 12) { ctx.fill(CGRect(x: 0, y: y, width: s, height: 4)) }
        let scale: CGFloat = 4.1
        let anchor = CGPoint(x: s * 0.5, y: s * 0.47 - 92 * scale)
        CharacterRenderer().draw(ModelSheet.iconPose, in: ctx, anchor: anchor, scale: scale, deviceScale: 1)
        ctx.restoreGState()
        guard let image = ctx.makeImage() else { return 1 }
        return write(image, path)
    }

    private static func write(_ image: CGImage, _ path: String) -> Int32 {
        do {
            try CharacterSnapshot.writePNG(image, to: URL(fileURLWithPath: path))
            print("wrote \(path)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            return 1
        }
    }
}
