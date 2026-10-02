import AppKit
import MinutesCore
import QuartzCore

/// A transparent, display-linked view that draws the character and nothing
/// else: no background, no border. Only her silhouette accepts the mouse.
public final class CharacterView: NSView {
    public var pose = Pose() { didSet { needsDisplay = true } }
    public var scale: CGFloat = 1 { didSet { needsDisplay = true } }
    public let renderer = CharacterRenderer()

    /// Called once per display refresh with (timestamp, dt).
    public var onFrame: ((CFTimeInterval, CFTimeInterval) -> Void)?
    public var onMouseDown: ((NSEvent) -> Void)?
    public var onMouseDragged: ((NSEvent) -> Void)?
    public var onMouseUp: ((NSEvent) -> Void)?

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        layer?.isOpaque = false
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var isOpaque: Bool { false }
    public override var isFlipped: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Where the anchor sits inside this view.
    public var anchorInView: CGPoint {
        CGPoint(x: Rig.anchorInCanvas.x * scale, y: Rig.anchorInCanvas.y * scale)
    }

    public func startDisplayLink(preferredFPS: Int) {
        stopDisplayLink()
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        let fps = Float(max(24, preferredFPS))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, fps), maximum: fps, preferred: fps)
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTimestamp = 0
    }

    public func stopDisplayLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTimestamp == 0 ? 1.0 / 60 : min(0.1, now - lastTimestamp)
        lastTimestamp = now
        onFrame?(now, dt)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        renderer.draw(pose, in: ctx, anchor: anchorInView, scale: scale,
                      deviceScale: window?.backingScaleFactor ?? 2, time: CACurrentMediaTime())
    }

    /// True when `point` (in view coordinates) is on her.
    public func isOnCharacter(_ point: CGPoint) -> Bool {
        renderer.hitPath(for: pose, anchor: anchorInView, scale: scale).contains(point)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return isOnCharacter(local) ? self : nil
    }

    public override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    public override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
    public override func mouseUp(with event: NSEvent) { onMouseUp?(event) }
}

/// Offscreen rendering: the app icon and the model sheet used to review poses.
public enum CharacterSnapshot {
    public static func image(_ pose: Pose, size: CGSize, anchor: CGPoint, scale: CGFloat,
                             background: CGColor? = nil, time: Double = 0) -> CGImage? {
        let px = 2
        guard let ctx = CGContext(data: nil, width: Int(size.width) * px, height: Int(size.height) * px, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: CGFloat(px), y: CGFloat(px))
        if let background {
            ctx.setFillColor(background)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        CharacterRenderer().draw(pose, in: ctx, anchor: anchor, scale: scale, deviceScale: CGFloat(px), time: time)
        return ctx.makeImage()
    }

    /// A labelled grid of poses on a checkerboard (so transparency is visible).
    public static func sheet(_ poses: [(String, Pose)], columns: Int, cell: CGSize = CGSize(width: 260, height: 300), scale: CGFloat = 0.9) -> CGImage? {
        let rows = (poses.count + columns - 1) / columns
        let size = CGSize(width: cell.width * CGFloat(columns), height: cell.height * CGFloat(rows))
        let px = 2
        guard let ctx = CGContext(data: nil, width: Int(size.width) * px, height: Int(size.height) * px, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: CGFloat(px), y: CGFloat(px))
        for y in stride(from: 0, to: size.height, by: 16) {
            for x in stride(from: 0, to: size.width, by: 16) {
                let dark = (Int(x / 16) + Int(y / 16)) % 2 == 0
                ctx.setFillColor(CGColor(gray: dark ? 0.82 : 0.9, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 16, height: 16))
            }
        }
        let renderer = CharacterRenderer()
        for (i, entry) in poses.enumerated() {
            let col = i % columns, row = rows - 1 - i / columns
            let origin = CGPoint(x: CGFloat(col) * cell.width, y: CGFloat(row) * cell.height)
            renderer.draw(entry.1, in: ctx, anchor: CGPoint(x: origin.x + cell.width / 2, y: origin.y + 95), scale: scale, deviceScale: CGFloat(px))
            let label = NSAttributedString(string: entry.0, attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.black])
            let line = CTLineCreateWithAttributedString(label)
            ctx.textPosition = CGPoint(x: origin.x + 10, y: origin.y + cell.height - 22)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}
