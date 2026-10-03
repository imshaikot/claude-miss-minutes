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

    /// A labelled grid of poses on a checkerboard (so transparency is visible),
    /// each over a faint drawing of what she is touching.
    public static func sheet(_ poses: [ModelSheet.Entry], columns: Int, cell: CGSize = CGSize(width: 260, height: 300), scale: CGFloat = 0.9) -> CGImage? {
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
            let anchor = CGPoint(x: origin.x + cell.width / 2, y: origin.y + 95)
            ctx.saveGState()
            ctx.clip(to: CGRect(origin: origin, size: cell))
            drawProp(entry.prop, anchor: anchor, scale: scale, in: ctx)
            ctx.restoreGState()
            renderer.draw(entry.pose, in: ctx, anchor: anchor, scale: scale, deviceScale: CGFloat(px))
            let label = NSAttributedString(string: entry.name, attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.black])
            let line = CTLineCreateWithAttributedString(label)
            ctx.textPosition = CGPoint(x: origin.x + 10, y: origin.y + cell.height - 22)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()
    }

    /// A slab of window with its edge outlined, on the side of the edge the prop names.
    private static func drawProp(_ prop: ModelSheet.Prop, anchor a: CGPoint, scale s: CGFloat, in ctx: CGContext) {
        let slab: CGRect
        let edge: (CGPoint, CGPoint)
        switch prop {
        case .none:
            return
        case .ground:
            ctx.setStrokeColor(CGColor(gray: 0.45, alpha: 0.6))
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: a.x - 110, y: a.y)); ctx.addLine(to: CGPoint(x: a.x + 110, y: a.y))
            ctx.strokePath()
            return
        case .windowTop:
            slab = CGRect(x: a.x - 120, y: a.y - 200, width: 240, height: 200)
            edge = (CGPoint(x: slab.minX, y: a.y), CGPoint(x: slab.maxX, y: a.y))
        case let .windowBottom(height):
            let y = a.y + height * s
            slab = CGRect(x: a.x - 120, y: y, width: 240, height: 200)
            edge = (CGPoint(x: slab.minX, y: y), CGPoint(x: slab.maxX, y: y))
        case let .windowSide(offset):
            let x = a.x + offset * s
            slab = offset > 0 ? CGRect(x: x, y: a.y - 40, width: 200, height: 300) : CGRect(x: x - 200, y: a.y - 40, width: 200, height: 300)
            edge = (CGPoint(x: x, y: slab.minY), CGPoint(x: x, y: slab.maxY))
        }
        ctx.setFillColor(CGColor(srgbRed: 0.55, green: 0.62, blue: 0.75, alpha: 0.35))
        ctx.fill(slab)
        ctx.setStrokeColor(CGColor(srgbRed: 0.2, green: 0.25, blue: 0.35, alpha: 0.8))
        ctx.setLineWidth(2)
        ctx.move(to: edge.0); ctx.addLine(to: edge.1)
        ctx.strokePath()
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}
