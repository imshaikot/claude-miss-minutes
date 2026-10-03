import CoreGraphics
import Foundation
import MinutesCore

/// Draws a `Pose` with Core Graphics in anchor space (y up). Stateless: the same
/// pose always draws the same picture, so it renders identically on screen, in
/// the app icon and in the offscreen model sheet.
public struct CharacterRenderer {
    public init() {}

    /// - Parameters:
    ///   - anchor: where the anchor point sits in the context, in context units.
    ///   - scale: character scale (1 = model sheet size).
    ///   - deviceScale: backing scale factor; shadows are specified in device space.
    public func draw(_ pose: Pose, in ctx: CGContext, anchor: CGPoint, scale: CGFloat, deviceScale: CGFloat = 2, time: Double = 0) {
        let drawn = pose.opacity > 0.002 && pose.size > 0.01
        guard drawn || pose.sparkle > 0.01 else { return }
        ctx.saveGState()
        ctx.translateBy(x: anchor.x, y: anchor.y)
        ctx.scaleBy(x: scale, y: scale)
        let shadowScale = scale * deviceScale

        if drawn {
            ctx.saveGState()
            ctx.concatenate(sizeTransform(pose))
            if pose.whirl > 0.01 { drawWhirl(pose, ctx, shadowScale: shadowScale, front: false) }
            ctx.saveGState()
            ctx.concatenate(turnTransform(pose))
            if pose.glitch > 0.02 {
                drawGlitched(pose, ctx, shadowScale: shadowScale, time: time)
            } else {
                ctx.setAlpha(pose.opacity)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                drawRevealed(pose, ctx, shadowScale: shadowScale, time: time)
                ctx.endTransparencyLayer()
            }
            ctx.restoreGState()
            if pose.whirl > 0.01 { drawWhirl(pose, ctx, shadowScale: shadowScale, front: true) }
            ctx.restoreGState()
        }
        if pose.sparkle > 0.01 { drawSparkle(pose, ctx, shadowScale: shadowScale) }
        ctx.restoreGState()
    }

    /// The clickable silhouette in the same space `draw` uses.
    public func hitPath(for pose: Pose, anchor: CGPoint, scale: CGFloat) -> CGPath {
        let place = turnTransform(pose).concatenating(sizeTransform(pose))
            .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y).scaledBy(x: scale, y: scale))
        let path = CGMutablePath()
        let bodyT = bodyTransform(pose)
        path.addEllipse(in: CGRect(x: -Rig.body.width - 6, y: -Rig.body.height - 6, width: (Rig.body.width + 6) * 2, height: (Rig.body.height + 14) * 2), transform: bodyT.concatenating(place))
        let limbT = limbTransform(pose)
        for hand in [pose.leftHand, pose.rightHand] {
            let p = hand.applying(limbT)
            path.addEllipse(in: CGRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32), transform: place)
        }
        for foot in [pose.leftFoot, pose.rightFoot] {
            path.addEllipse(in: CGRect(x: foot.x - 16, y: foot.y - 6, width: 32, height: 22), transform: place)
        }
        return path
    }

    // MARK: - Presence effects

    /// Shrinking into a point, about the body centre.
    func sizeTransform(_ pose: Pose) -> CGAffineTransform {
        guard pose.size != 1 else { return .identity }
        return CGAffineTransform(translationX: pose.body.x, y: pose.body.y)
            .scaledBy(x: pose.size, y: pose.size)
            .translatedBy(x: -pose.body.x, y: -pose.body.y)
    }

    /// Turning about her vertical axis: squeezed by the cosine, and mirrored
    /// past a quarter turn, when it is her back we see.
    func turnTransform(_ pose: Pose) -> CGAffineTransform {
        guard pose.twirl != 0 else { return .identity }
        let c = cos(pose.twirl)
        let squeeze = c < 0 ? min(c, -0.05) : max(c, 0.05)
        return CGAffineTransform(translationX: pose.body.x, y: 0).scaledBy(x: squeeze, y: 1).translatedBy(x: -pose.body.x, y: 0)
    }

    /// Rings of light whirling round her as she spins, drawn in two passes:
    /// the far half behind her, the near half in front.
    private func drawWhirl(_ pose: Pose, _ ctx: CGContext, shadowScale: CGFloat, front: Bool) {
        let rings: [(dy: CGFloat, rx: CGFloat)] = [(34, 66), (-6, 76), (-48, 54)]
        let path = CGMutablePath()
        for (i, ring) in rings.enumerated() {
            let center = CGPoint(x: pose.body.x, y: pose.body.y + ring.dy)
            let start = pose.twirl * 0.6 + CGFloat(i) * 2.1
            var drawing = false
            for k in 0...24 {
                let a = start + 2.4 * CGFloat(k) / 24
                let point = CGPoint(x: center.x + ring.rx * cos(a), y: center.y + 12 * sin(a))
                // The lower half of each ring is the side nearer to us.
                guard (sin(a) < 0) == front else { drawing = false; continue }
                if drawing { path.addLine(to: point) } else { path.move(to: point) }
                drawing = true
            }
        }
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 6 * shadowScale, color: Palette.glow)
        ctx.setStrokeColor(Palette.scan.copy(alpha: pose.whirl * (front ? 0.85 : 0.4)) ?? Palette.scan)
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The glint she shrinks into when she goes, and grows out of when she comes back.
    private func drawSparkle(_ pose: Pose, _ ctx: CGContext, shadowScale: CGFloat) {
        let s = pose.sparkle
        let r = 38 * s
        let star = CGMutablePath()
        for k in 0..<16 {
            let a = CGFloat(k) * .pi / 8
            let reach = k % 4 == 0 ? r : k % 2 == 0 ? r * 0.4 : r * 0.1
            let point = CGPoint(x: sin(a) * reach, y: cos(a) * reach)
            if k == 0 { star.move(to: point) } else { star.addLine(to: point) }
        }
        star.closeSubpath()
        ctx.saveGState()
        ctx.translateBy(x: pose.body.x, y: pose.body.y)
        ctx.rotate(by: s * .pi / 4)
        ctx.setShadow(offset: .zero, blur: 14 * shadowScale, color: Palette.glow)
        ctx.setFillColor(Palette.scan.copy(alpha: min(1, s * 1.5)) ?? Palette.scan)
        ctx.addPath(star)
        ctx.fillPath()
        ctx.fillEllipse(in: CGRect(x: -r * 0.2, y: -r * 0.2, width: r * 0.4, height: r * 0.4))
        ctx.restoreGState()
    }

    private func drawRevealed(_ pose: Pose, _ ctx: CGContext, shadowScale: CGFloat, time: Double) {
        guard pose.reveal < 0.999 else {
            drawCharacter(pose, ctx, shadowScale: shadowScale, time: time)
            return
        }
        let bottom: CGFloat = min(pose.leftFoot.y, pose.rightFoot.y) - 14
        let top: CGFloat = pose.body.y + Rig.body.height + 30
        let edge = bottom + (top - bottom) * pose.reveal
        ctx.saveGState()
        ctx.clip(to: CGRect(x: -200, y: bottom - 40, width: 400, height: edge - bottom + 40))
        drawCharacter(pose, ctx, shadowScale: shadowScale, time: time)
        ctx.restoreGState()
        // The projector's scan line.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 8 * shadowScale, color: Palette.glow)
        ctx.setFillColor(Palette.scan)
        ctx.fill(CGRect(x: pose.body.x - 80, y: edge - 1, width: 160, height: 2))
        ctx.restoreGState()
    }

    /// Hologram interference: tinted ghosts plus horizontally torn slices.
    private func drawGlitched(_ pose: Pose, _ ctx: CGContext, shadowScale: CGFloat, time: Double) {
        let g = pose.glitch
        let seed = Int(time * 24)
        for (tint, dx) in [(Palette.ghostA, -5 * g), (Palette.ghostB, 5 * g)] {
            ctx.saveGState()
            ctx.translateBy(x: dx, y: 0)
            ctx.setAlpha(pose.opacity * 0.45 * g)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            drawRevealed(pose, ctx, shadowScale: shadowScale, time: time)
            ctx.setBlendMode(.sourceAtop)
            ctx.setFillColor(tint)
            ctx.fill(CGRect(x: -300, y: -200, width: 600, height: 600))
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        let bands = 7
        let bottom: CGFloat = -80, height: CGFloat = 300
        for i in 0..<bands {
            let y0 = bottom + height * CGFloat(i) / CGFloat(bands)
            let shift = noise(Double(seed) * 1.7 + Double(i) * 3.1, seed: 11) * 16 * g
            ctx.saveGState()
            ctx.clip(to: CGRect(x: -300, y: y0, width: 600, height: height / CGFloat(bands) + 0.5))
            ctx.translateBy(x: shift, y: 0)
            ctx.setAlpha(pose.opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            drawRevealed(pose, ctx, shadowScale: shadowScale, time: time)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }

    // MARK: - Character

    func bodyTransform(_ pose: Pose) -> CGAffineTransform {
        let sy = pose.squash
        let sx = 1 / max(sy, 0.3).squareRoot()
        return CGAffineTransform(translationX: pose.body.x, y: pose.body.y).rotated(by: pose.tilt).scaledBy(x: sx, y: sy)
    }

    /// Body transform without squash: hands ride the body's position and tilt only.
    func limbTransform(_ pose: Pose) -> CGAffineTransform {
        CGAffineTransform(translationX: pose.body.x, y: pose.body.y).rotated(by: pose.tilt)
    }

    private func drawCharacter(_ pose: Pose, _ ctx: CGContext, shadowScale: CGFloat, time: Double) {
        let bodyT = bodyTransform(pose)
        let limbT = limbTransform(pose)

        if pose.shadow > 0.01 { drawGroundShadow(pose, ctx) }

        // Legs, behind the body.
        for side: CGFloat in [-1, 1] {
            let hip = CGPoint(x: side * Rig.hip.x, y: Rig.hip.y).applying(bodyT)
            let foot = side < 0 ? pose.leftFoot : pose.rightFoot
            let ankle = foot + CGPoint(x: 0, y: 6)
            let bend = side < 0 ? pose.leftLegBend : pose.rightLegBend
            strokeHose(from: hip, to: ankle, bend: bend, side: side, ctx)
            let dir: CGFloat = abs(pose.facing) > 0.3 ? (pose.facing > 0 ? 1 : -1) : side
            drawShoe(at: foot, direction: dir, angle: side < 0 ? pose.leftFootAngle : pose.rightFootAngle, ctx)
        }

        // Arms and gloves: in front of the body, unless one is reaching round behind her.
        let behind = { (side: CGFloat) in side < 0 ? pose.leftArmBehind : pose.rightArmBehind }
        for side: CGFloat in [-1, 1] where behind(side) { drawArm(pose, side: side, bodyT, limbT, ctx) }
        drawBody(pose, bodyT, ctx, shadowScale: shadowScale, time: time)
        for side: CGFloat in [-1, 1] where !behind(side) { drawArm(pose, side: side, bodyT, limbT, ctx) }
    }

    private func drawArm(_ pose: Pose, side: CGFloat, _ bodyT: CGAffineTransform, _ limbT: CGAffineTransform, _ ctx: CGContext) {
        let shoulder = CGPoint(x: side * Rig.shoulder.x, y: Rig.shoulder.y).applying(bodyT)
        let hand = (side < 0 ? pose.leftHand : pose.rightHand).applying(limbT)
        let bend = side < 0 ? pose.leftArmBend : pose.rightArmBend
        let control = strokeHose(from: shoulder, to: hand, bend: bend, side: side, ctx)
        let tangent = hand - control
        let angle = atan2(tangent.y, tangent.x) - side * (side < 0 ? pose.leftHandAngle : pose.rightHandAngle)
        drawGlove(at: hand, angle: angle, mirrored: side < 0, shape: side < 0 ? pose.leftHandShape : pose.rightHandShape, ctx)
    }

    private func drawGroundShadow(_ pose: Pose, _ ctx: CGContext) {
        let lift = max(0, pose.body.y - 92)
        let w = 74 * max(0.4, 1 - lift / 160)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.16 * pose.shadow))
        ctx.fillEllipse(in: CGRect(x: pose.body.x - w / 2, y: -5, width: w, height: 10))
    }

    /// A rubber-hose limb: one quadratic curve, bowed outward by `bend` points.
    /// Returns the control point (for the glove's orientation).
    @discardableResult
    private func strokeHose(from a: CGPoint, to b: CGPoint, bend: CGFloat, side: CGFloat, _ ctx: CGContext) -> CGPoint {
        let dir = (b - a).normalized
        let perp = CGPoint(x: -dir.y, y: dir.x) * (side > 0 ? 1 : -1)
        let control = lerp(a, b, 0.5) + perp * (bend * 2)
        let path = CGMutablePath()
        path.move(to: a)
        path.addQuadCurve(to: b, control: control)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(Palette.limb)
        ctx.setLineWidth(Rig.limb)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()
        return control
    }

    // MARK: Body and face

    private func drawBody(_ pose: Pose, _ bodyT: CGAffineTransform, _ ctx: CGContext, shadowScale: CGFloat, time: Double) {
        let rx = Rig.body.width, ry = Rig.body.height
        let outer = CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2)
        let inner = outer.insetBy(dx: Rig.bezel, dy: Rig.bezel)

        ctx.saveGState()
        ctx.concatenate(bodyT)

        // Winding knob on top, behind the body.
        ctx.setLineWidth(Rig.outline)
        ctx.setStrokeColor(Palette.outline)
        ctx.setFillColor(Palette.knob)
        let stem = CGPath(roundedRect: CGRect(x: -5, y: ry - 4, width: 10, height: 12), cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.addPath(stem); ctx.drawPath(using: .fillStroke)
        let cap = CGRect(x: -10, y: ry + 6, width: 20, height: 11)
        ctx.addPath(CGPath(roundedRect: cap, cornerWidth: 5, cornerHeight: 5, transform: nil)); ctx.drawPath(using: .fillStroke)
        ctx.setStrokeColor(Palette.outline.copy(alpha: 0.5) ?? Palette.outline)
        ctx.setLineWidth(1)
        for x in stride(from: CGFloat(-6), through: 6, by: 4) {
            ctx.move(to: CGPoint(x: x, y: ry + 8)); ctx.addLine(to: CGPoint(x: x, y: ry + 15))
        }
        ctx.strokePath()

        // Bezel with the hologram glow.
        ctx.saveGState()
        if pose.glow > 0.01 {
            ctx.setShadow(offset: .zero, blur: 18 * shadowScale, color: Palette.glow.copy(alpha: 0.75 * pose.glow))
        }
        ctx.setFillColor(Palette.bezel)
        ctx.fillEllipse(in: outer)
        ctx.restoreGState()

        // Dial, or the back of the case once she has turned round.
        ctx.saveGState()
        ctx.addEllipse(in: inner)
        ctx.clip()
        if cos(pose.twirl) < 0 {
            drawCaseBack(ctx, inner: inner)
        } else {
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [Palette.faceLight, Palette.faceDark] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: -14, y: 20), startRadius: 2,
                                   endCenter: CGPoint(x: 0, y: 0), endRadius: rx * 1.05, options: [.drawsAfterEndLocation])
            drawTicks(ctx, inner: inner)
            drawFace(pose, ctx)
        }
        if pose.glow > 0.01 { drawScanlines(ctx, inner: inner, strength: pose.glow, time: time) }
        ctx.restoreGState()

        // Inner bezel line, gloss, outline.
        ctx.setLineWidth(1.2)
        ctx.setStrokeColor(Palette.outline.copy(alpha: 0.45) ?? Palette.outline)
        ctx.strokeEllipse(in: inner)
        ctx.saveGState()
        let gloss = CGMutablePath()
        gloss.addArc(center: .zero, radius: 1, startAngle: .pi * 0.58, endAngle: .pi * 0.9, clockwise: false,
                     transform: CGAffineTransform(scaleX: rx - 3.5, y: ry - 3.5))
        ctx.addPath(gloss)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.45))
        ctx.setLineWidth(2.6)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setLineWidth(Rig.outline)
        ctx.setStrokeColor(Palette.outline)
        ctx.strokeEllipse(in: outer)

        ctx.restoreGState()
    }

    /// The back of the case, glimpsed mid-twirl: a cover plate with a coin slot, screwed on.
    private func drawCaseBack(_ ctx: CGContext, inner: CGRect) {
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [Palette.faceDark, Palette.bezel] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: 12, y: 18), startRadius: 2,
                               endCenter: .zero, endRadius: inner.width * 0.55, options: [.drawsAfterEndLocation])
        let plate = CGRect(x: -20, y: -20, width: 40, height: 40)
        ctx.setFillColor(Palette.knob)
        ctx.fillEllipse(in: plate)
        ctx.setStrokeColor(Palette.outline.copy(alpha: 0.55) ?? Palette.outline)
        ctx.setLineWidth(1.6)
        ctx.strokeEllipse(in: plate)
        ctx.setLineWidth(2.2)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: -8, y: -4.6))
        ctx.addLine(to: CGPoint(x: 8, y: 4.6))
        ctx.strokePath()
        ctx.setFillColor(Palette.outline.copy(alpha: 0.5) ?? Palette.outline)
        for k in 0..<4 {
            let a = CGFloat(k) * .pi / 2 + .pi / 4
            ctx.fillEllipse(in: CGRect(x: cos(a) * 31 - 2, y: sin(a) * 29 - 2, width: 4, height: 4))
        }
    }

    private func drawTicks(_ ctx: CGContext, inner: CGRect) {
        let rx = inner.width / 2 - 3, ry = inner.height / 2 - 3
        ctx.setStrokeColor(Palette.tick)
        ctx.setLineCap(.round)
        for k in 0..<12 {
            let a = CGFloat(k) * .pi / 6
            let quarter = k % 3 == 0
            let len: CGFloat = quarter ? 6 : 3.5
            let outerP = CGPoint(x: sin(a) * rx, y: cos(a) * ry)
            let innerP = CGPoint(x: sin(a) * (rx - len), y: cos(a) * (ry - len))
            ctx.setLineWidth(quarter ? 2.4 : 1.6)
            ctx.move(to: outerP)
            ctx.addLine(to: innerP)
            ctx.strokePath()
        }
    }

    private func drawScanlines(_ ctx: CGContext, inner: CGRect, strength: CGFloat, time: Double) {
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.05 * strength))
        var y = inner.minY
        while y < inner.maxY {
            ctx.fill(CGRect(x: inner.minX, y: y, width: inner.width, height: 1))
            y += 3
        }
        let span = inner.height + 20
        let bandY = inner.maxY + 10 - CGFloat((time * 22).truncatingRemainder(dividingBy: Double(span)))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.07 * strength))
        ctx.fill(CGRect(x: inner.minX, y: bandY - 6, width: inner.width, height: 12))
    }

    private func drawFace(_ pose: Pose, _ ctx: CGContext) {
        let fs = pose.faceShift
        let shift = CGPoint(x: fs.x * 8, y: fs.y * 4.5)

        // Cheeks.
        for side: CGFloat in [-1, 1] {
            let c = CGPoint(x: side * Rig.cheek.x + shift.x * 0.9, y: Rig.cheek.y + shift.y)
            ctx.setFillColor(Palette.blush.copy(alpha: 0.18 + 0.42 * pose.blush) ?? Palette.blush)
            ctx.fillEllipse(in: CGRect(x: c.x - 7, y: c.y - 4.2, width: 14, height: 8.4))
        }

        drawClockHands(pose, ctx, shift: shift)

        for side: CGFloat in [-1, 1] { drawEye(pose, side: side, shift: shift, ctx) }

        // Brows.
        ctx.setStrokeColor(Palette.outline)
        ctx.setLineWidth(2.6)
        ctx.setLineCap(.round)
        for side: CGFloat in [-1, 1] {
            let c = CGPoint(x: side * Rig.brow.x + shift.x * 1.1, y: Rig.brow.y + pose.browRaise * 5 + shift.y + pose.eyeWide * 2)
            let inner = CGPoint(x: c.x - side * 7.5, y: c.y - pose.browTilt * 3)
            let outer = CGPoint(x: c.x + side * 7.5, y: c.y + pose.browTilt * 1.5 - 1)
            ctx.move(to: inner)
            ctx.addQuadCurve(to: outer, control: CGPoint(x: c.x, y: c.y + 3.5))
            ctx.strokePath()
        }

        drawMouth(pose, ctx, shift: shift)
    }

    private func drawClockHands(_ pose: Pose, _ ctx: CGContext, shift: CGPoint) {
        let pivot = Rig.clockPivot + shift * 0.6
        func hand(angle: CGFloat, length: CGFloat, width: CGFloat) {
            let dir = CGPoint(x: sin(angle), y: cos(angle))
            let perp = CGPoint(x: -dir.y, y: dir.x)
            let path = CGMutablePath()
            path.move(to: pivot - dir * 3 + perp * (width / 2))
            path.addLine(to: pivot + dir * (length * 0.72) + perp * (width / 2))
            path.addLine(to: pivot + dir * length)
            path.addLine(to: pivot + dir * (length * 0.72) - perp * (width / 2))
            path.addLine(to: pivot - dir * 3 - perp * (width / 2))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(Palette.clockHand)
            ctx.fillPath()
        }
        hand(angle: pose.hourAngle, length: 12, width: 3.6)
        hand(angle: pose.minuteAngle, length: 18, width: 2.6)
        let cap = CGRect(x: pivot.x - 3, y: pivot.y - 3, width: 6, height: 6)
        ctx.setFillColor(Palette.pivot)
        ctx.fillEllipse(in: cap)
        ctx.setStrokeColor(Palette.clockHand)
        ctx.setLineWidth(1.2)
        ctx.strokeEllipse(in: cap)
    }

    private func drawEye(_ pose: Pose, side: CGFloat, shift: CGPoint, _ ctx: CGContext) {
        let far = max(0, -side * pose.faceShift.x)
        let w = Rig.eyeSize.width * (1 - 0.22 * far) * (1 + 0.12 * pose.eyeWide)
        let h = Rig.eyeSize.height * (1 + 0.14 * pose.eyeWide)
        let c = CGPoint(x: side * Rig.eye.x + shift.x * (1 + 0.15 * side * pose.faceShift.x), y: Rig.eye.y + shift.y)
        let rect = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)

        ctx.setFillColor(Palette.eyeWhite)
        ctx.fillEllipse(in: rect)

        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()
        let pc = CGPoint(x: c.x + pose.look.x * w * 0.24, y: c.y + pose.look.y * h * 0.2 - 1)
        switch pose.pupilStyle {
        case .heart:
            ctx.addPath(heartPath(center: pc, size: 11))
            ctx.setFillColor(Palette.heart)
            ctx.fillPath()
        case .round:
            let pw = 10 * (w / Rig.eyeSize.width), ph = 14 * (h / Rig.eyeSize.height)
            ctx.setFillColor(Palette.pupil)
            ctx.fillEllipse(in: CGRect(x: pc.x - pw / 2, y: pc.y - ph / 2, width: pw, height: ph))
            // The pie-cut highlight of 1930s cartoon eyes.
            let wedge = CGMutablePath()
            wedge.move(to: pc + CGPoint(x: 0.6, y: 0.8))
            wedge.addArc(center: pc + CGPoint(x: 0.6, y: 0.8), radius: ph * 0.62, startAngle: 0.55, endAngle: 1.2, clockwise: false)
            wedge.closeSubpath()
            ctx.addPath(wedge)
            ctx.setFillColor(Palette.eyeWhite)
            ctx.fillPath()
        }
        // Upper lid (blinks) and lower lid (squints).
        let lidY = rect.maxY - rect.height * (1 - pose.eyeOpen) * 1.02
        let lowY = rect.minY + rect.height * clamp(pose.squint, 0, 1) * 0.4
        ctx.setFillColor(Palette.lid)
        ctx.fill(CGRect(x: rect.minX - 1, y: lidY, width: rect.width + 2, height: rect.maxY - lidY + 1))
        ctx.fill(CGRect(x: rect.minX - 1, y: rect.minY - 1, width: rect.width + 2, height: lowY - rect.minY + 1))
        ctx.setStrokeColor(Palette.outline)
        ctx.setLineWidth(1.8)
        if pose.eyeOpen < 0.97 {
            ctx.move(to: CGPoint(x: rect.minX, y: lidY))
            ctx.addQuadCurve(to: CGPoint(x: rect.maxX, y: lidY), control: CGPoint(x: c.x, y: lidY - 2.5))
            ctx.strokePath()
        }
        if pose.squint > 0.03 {
            ctx.move(to: CGPoint(x: rect.minX, y: lowY))
            ctx.addQuadCurve(to: CGPoint(x: rect.maxX, y: lowY), control: CGPoint(x: c.x, y: lowY + 2.5))
            ctx.strokePath()
        }
        ctx.restoreGState()

        ctx.setStrokeColor(Palette.outline)
        ctx.setLineWidth(2.2)
        ctx.strokeEllipse(in: rect)

        // Lashes on the outer upper rim, riding the lid down when she blinks.
        ctx.setLineWidth(1.9)
        ctx.setLineCap(.round)
        for (i, deg) in [28.0, 50.0, 72.0].enumerated() {
            let a = CGFloat(deg) * .pi / 180
            var base = CGPoint(x: c.x + side * cos(a) * w / 2, y: c.y + sin(a) * h / 2)
            base.y = min(base.y, lidY + 0.5)
            let len: CGFloat = i == 1 ? 7 : 5.8
            let out = CGPoint(x: side * cos(a), y: sin(a)) * len
            let tip = base + out + CGPoint(x: side * 1.2, y: 1.5)
            ctx.move(to: base)
            ctx.addQuadCurve(to: tip, control: base + out * 0.6 + CGPoint(x: 0, y: -0.8))
            ctx.strokePath()
        }
    }

    private func heartPath(center c: CGPoint, size s: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x, y: c.y - s * 0.55))
        p.addCurve(to: CGPoint(x: c.x - s * 0.55, y: c.y + s * 0.2), control1: CGPoint(x: c.x - s * 0.2, y: c.y - s * 0.3), control2: CGPoint(x: c.x - s * 0.55, y: c.y - s * 0.1))
        p.addArc(center: CGPoint(x: c.x - s * 0.27, y: c.y + s * 0.22), radius: s * 0.28, startAngle: .pi, endAngle: 0, clockwise: true)
        p.addArc(center: CGPoint(x: c.x + s * 0.27, y: c.y + s * 0.22), radius: s * 0.28, startAngle: .pi, endAngle: 0, clockwise: true)
        p.addCurve(to: CGPoint(x: c.x, y: c.y - s * 0.55), control1: CGPoint(x: c.x + s * 0.55, y: c.y - s * 0.1), control2: CGPoint(x: c.x + s * 0.2, y: c.y - s * 0.3))
        p.closeSubpath()
        return p
    }

    private func drawMouth(_ pose: Pose, _ ctx: CGContext, shift: CGPoint) {
        let m = Rig.mouth + CGPoint(x: shift.x, y: shift.y * 0.9)
        let open = clamp(pose.mouthOpen, 0, 1)
        let wide = clamp(pose.mouthWide, -1, 1)
        let smile = clamp(pose.smile, -1, 1)
        let hw = max(4, 11 * (1 + 0.35 * wide) * (1 - 0.3 * open * max(0, -wide)))
        let cornerY = smile * 5 + open * 2
        let left = CGPoint(x: m.x - hw, y: m.y + cornerY)
        let right = CGPoint(x: m.x + hw, y: m.y + cornerY)

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if open < 0.05 {
            ctx.move(to: left)
            ctx.addQuadCurve(to: right, control: CGPoint(x: m.x, y: m.y - smile * 8))
            ctx.setStrokeColor(Palette.lips)
            ctx.setLineWidth(3.4)
            ctx.strokePath()
            // Little corner tucks.
            ctx.setStrokeColor(Palette.outline.copy(alpha: 0.6) ?? Palette.outline)
            ctx.setLineWidth(1.2)
            for (corner, s) in [(left, CGFloat(-1)), (right, CGFloat(1))] {
                ctx.move(to: corner + CGPoint(x: -s * 1.5, y: 1.5 + smile))
                ctx.addLine(to: corner + CGPoint(x: s * 1.5, y: -0.5))
            }
            ctx.strokePath()
            return
        }
        let depth = 4 + open * 16 + max(0, smile) * 2
        let path = CGMutablePath()
        path.move(to: left)
        path.addQuadCurve(to: right, control: CGPoint(x: m.x, y: m.y + cornerY * 0.35 + 1 - smile * 2))
        path.addQuadCurve(to: left, control: CGPoint(x: m.x, y: m.y - depth - smile * 3))
        path.closeSubpath()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(Palette.mouthInside)
        ctx.fill(CGRect(x: m.x - 30, y: m.y - 40, width: 60, height: 60))
        ctx.setFillColor(Palette.tongue)
        ctx.fillEllipse(in: CGRect(x: m.x - hw * 0.65, y: m.y - depth * 0.95, width: hw * 1.3, height: depth * 0.6))
        if open > 0.3 {
            ctx.setFillColor(Palette.eyeWhite)
            ctx.fill(CGRect(x: m.x - hw, y: m.y + cornerY * 0.3 - 2.2, width: hw * 2, height: 3))
        }
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(Palette.lips)
        ctx.setLineWidth(2.8)
        ctx.strokePath()
    }

    // MARK: Gloves and shoes

    private func drawGlove(at point: CGPoint, angle: CGFloat, mirrored: Bool, shape: HandShape, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y)
        ctx.rotate(by: angle)
        ctx.scaleBy(x: Rig.gloveScale, y: mirrored ? -Rig.gloveScale : Rig.gloveScale)

        var parts: [CGPath] = []
        func capsule(_ a: CGPoint, _ b: CGPoint, _ width: CGFloat) -> CGPath {
            let p = CGMutablePath()
            p.move(to: a); p.addLine(to: b)
            return p.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
        }
        parts.append(CGPath(roundedRect: CGRect(x: -4, y: -7, width: 8, height: 14), cornerWidth: 3, cornerHeight: 3, transform: nil))
        switch shape {
        case .open:
            for (i, y) in [-5.6, -1.9, 1.9, 5.6].enumerated() {
                let y = CGFloat(y)
                let len: CGFloat = i == 0 || i == 3 ? 8 : 10
                parts.append(capsule(CGPoint(x: 11, y: y * 0.8), CGPoint(x: 11 + len, y: y * 1.25), 5.4))
            }
            parts.append(capsule(CGPoint(x: 7, y: 5), CGPoint(x: 11, y: 12.5), 5.4))
            parts.append(CGPath(ellipseIn: CGRect(x: 1, y: -8, width: 17, height: 16), transform: nil))
        case .fist:
            parts.append(CGPath(ellipseIn: CGRect(x: 1, y: -9, width: 19, height: 18), transform: nil))
            for y in [-5.6, -1.9, 1.9, 5.6] { parts.append(CGPath(ellipseIn: CGRect(x: 15, y: CGFloat(y) - 2.6, width: 6, height: 5.2), transform: nil)) }
        case .point:
            parts.append(CGPath(ellipseIn: CGRect(x: 1, y: -9, width: 18, height: 17), transform: nil))
            for y in [-5.4, -1.8] { parts.append(CGPath(ellipseIn: CGRect(x: 14, y: CGFloat(y) - 2.6, width: 6, height: 5.2), transform: nil)) }
            parts.append(capsule(CGPoint(x: 13, y: 4), CGPoint(x: 27, y: 4.5), 5.2))
        }
        // Outline pass then fill pass: overlapping parts merge into one silhouette.
        ctx.setStrokeColor(Palette.outline)
        ctx.setLineWidth(4.2)
        ctx.setLineJoin(.round)
        for p in parts { ctx.addPath(p); ctx.strokePath() }
        ctx.setFillColor(Palette.glove)
        for p in parts { ctx.addPath(p); ctx.fillPath() }
        // Cuff seam and the three stitches on the back of the glove.
        ctx.setStrokeColor(Palette.gloveDetail)
        ctx.setLineWidth(1)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 3.5, y: -6)); ctx.addLine(to: CGPoint(x: 3.5, y: 6))
        if shape != .point {
            for y in [-3.0, 0.0, 3.0] {
                ctx.move(to: CGPoint(x: 7, y: CGFloat(y) * 0.9)); ctx.addLine(to: CGPoint(x: 12.5, y: CGFloat(y)))
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawShoe(at foot: CGPoint, direction: CGFloat, angle: CGFloat, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: foot.x, y: foot.y)
        ctx.scaleBy(x: direction * Rig.shoeScale, y: Rig.shoeScale)
        ctx.rotate(by: angle)
        let shoe = CGMutablePath()
        shoe.move(to: CGPoint(x: -7, y: 1))
        shoe.addLine(to: CGPoint(x: 12, y: 0))
        shoe.addCurve(to: CGPoint(x: 13, y: 12), control1: CGPoint(x: 22, y: 0), control2: CGPoint(x: 22, y: 12))
        shoe.addCurve(to: CGPoint(x: -7, y: 9), control1: CGPoint(x: 6, y: 12.5), control2: CGPoint(x: -1, y: 11))
        shoe.addCurve(to: CGPoint(x: -7, y: 1), control1: CGPoint(x: -10, y: 7), control2: CGPoint(x: -10, y: 2))
        shoe.closeSubpath()
        ctx.addPath(shoe)
        ctx.setFillColor(Palette.shoe)
        ctx.setStrokeColor(Palette.outline)
        ctx.setLineWidth(2.2)
        ctx.drawPath(using: .fillStroke)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.55))
        ctx.setLineWidth(1.6)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 11, y: 9.5))
        ctx.addQuadCurve(to: CGPoint(x: 17, y: 6), control: CGPoint(x: 16, y: 9.5))
        ctx.strokePath()
        ctx.restoreGState()
    }
}
