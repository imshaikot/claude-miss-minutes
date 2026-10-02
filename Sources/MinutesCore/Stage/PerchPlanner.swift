import CoreGraphics

/// Tunables for where she may sit. Distances are points at scale 1; use `scaled`.
public struct PerchRules: Equatable {
    /// Half her width including resting hands: the anchor keeps this far from obstacles.
    public var halfWidth: CGFloat = 78
    /// Room needed above a ledge for her body when sitting on it.
    public var headroom: CGFloat = 125
    /// Keep clear of the traffic-light buttons at a window's top-left.
    public var leftInset: CGFloat = 110
    public var rightInset: CGFloat = 80
    public var minWindowSize = CGSize(width: 320, height: 180)
    public var useWindows = true
    public var useFloor = true
    public var avoidApps: Set<String> = []
    /// Spots closer than this to the pointer are avoided (she stays out of the way).
    public var cursorComfort: CGFloat = 170

    public init() {}

    public func scaled(_ s: CGFloat) -> PerchRules {
        var r = self
        r.halfWidth *= s
        r.headroom *= s
        r.leftInset = max(leftInset, halfWidth * s)
        r.rightInset = max(rightInset, halfWidth * s)
        r.cursorComfort *= max(1, s)
        return r
    }
}

public struct ScoredPerch: Equatable {
    public var perch: Perch
    public var score: CGFloat
}

/// Turns a `SceneSnapshot` into places that make sense to sit: visible top
/// edges of windows (not hidden behind other windows, with room under the menu
/// bar) and the floor of each display. Pure geometry, fully unit-tested.
public struct PerchPlanner {
    public var rules: PerchRules

    public init(rules: PerchRules = PerchRules()) {
        self.rules = rules
    }

    struct Ledge {
        var surface: Surface
        var y: CGFloat
        var spans: [ClosedRange<CGFloat>]
        var posture: Posture
        var depth: Int
        var window: WindowInfo?
        var screen: Int
    }

    func ledges(in scene: SceneSnapshot) -> [Ledge] {
        var result: [Ledge] = []
        if rules.useWindows {
            for (depth, w) in scene.windows.enumerated() {
                guard w.frame.width >= rules.minWindowSize.width, w.frame.height >= rules.minWindowSize.height,
                      !rules.avoidApps.contains(where: { $0.caseInsensitiveCompare(w.app) == .orderedSame }) else { continue }
                let y = w.frame.maxY
                guard let screenIndex = scene.screens.firstIndex(where: { $0.frame.contains(CGPoint(x: w.frame.midX, y: y - 1)) }) else { continue }
                let visible = scene.screens[screenIndex].visible
                guard y + rules.headroom <= visible.maxY, y > visible.minY + 60 else { continue }
                let lower = max(w.frame.minX + rules.leftInset, visible.minX + rules.halfWidth)
                let upper = min(w.frame.maxX - rules.rightInset, visible.maxX - rules.halfWidth)
                guard upper >= lower else { continue }
                var spans = [lower...upper]
                let band = (y - 6)...(y + rules.headroom)
                for front in scene.windows[..<depth] where front.frame.minY < band.upperBound && front.frame.maxY > band.lowerBound {
                    spans = subtract(spans, (front.frame.minX - rules.halfWidth)...(front.frame.maxX + rules.halfWidth))
                }
                guard !spans.isEmpty else { continue }
                result.append(Ledge(surface: .windowTop(windowID: w.id, app: w.app), y: y, spans: spans,
                                    posture: .sit, depth: depth, window: w, screen: screenIndex))
            }
        }
        if rules.useFloor || result.isEmpty {
            for (index, screen) in scene.screens.enumerated() {
                let v = screen.visible
                let lower = v.minX + rules.halfWidth, upper = v.maxX - rules.halfWidth
                guard upper > lower else { continue }
                result.append(Ledge(surface: .floor(screen: index), y: v.minY, spans: [lower...upper],
                                    posture: .stand, depth: scene.windows.count, window: nil, screen: index))
            }
        }
        return result
    }

    public func candidates(in scene: SceneSnapshot, current: Perch? = nil) -> [ScoredPerch] {
        var out: [ScoredPerch] = []
        for ledge in ledges(in: scene) {
            for span in ledge.spans {
                let width = span.upperBound - span.lowerBound
                let fractions: [CGFloat] = width < 40 ? [0.5] : [0.15, 0.5, 0.85]
                for f in fractions {
                    let x = span.lowerBound + width * f
                    let point = CGPoint(x: x, y: ledge.y)
                    let perch = Perch(surface: ledge.surface, point: point, posture: ledge.posture,
                                      offset: ledge.window.map { x - $0.frame.minX } ?? 0)
                    out.append(ScoredPerch(perch: perch, score: score(perch, ledge: ledge, scene: scene, current: current)))
                }
            }
        }
        return out
    }

    func score(_ perch: Perch, ledge: Ledge, scene: SceneSnapshot, current: Perch?) -> CGFloat {
        var s: CGFloat
        if let w = ledge.window {
            s = 1 / (1 + 0.6 * CGFloat(ledge.depth))
            if let front = scene.frontPID, w.pid == front { s += 1.2 }
            // The right-hand part of a window is usually less busy than the left.
            let rel = (perch.point.x - w.frame.minX) / max(w.frame.width, 1)
            s *= 0.8 + 0.4 * rel
        } else {
            s = 0.55
        }
        if perch.point.distance(to: scene.cursor) < rules.cursorComfort { s *= 0.25 }
        if let current, perch.point.distance(to: current.point) < 120 { s *= 0.15 }
        return s
    }

    /// A weighted-random pick among sensible spots.
    public func choose<R: RandomNumberGenerator>(in scene: SceneSnapshot, current: Perch?, using rng: inout R) -> Perch? {
        let all = candidates(in: scene, current: current)
        let total = all.reduce(0) { $0 + $1.score * $1.score }
        guard total > 0 else { return all.first?.perch }
        var roll = CGFloat(Double.random(in: 0..<1, using: &rng)) * total
        for c in all {
            roll -= c.score * c.score
            if roll <= 0 { return c.perch }
        }
        return all.last?.perch
    }

    public func perch<R: RandomNumberGenerator>(for target: MoveTarget, in scene: SceneSnapshot, current: Perch?, using rng: inout R) -> Perch? {
        switch target {
        case .random:
            return choose(in: scene, current: current, using: &rng)
        case let .app(name):
            let matches = candidates(in: scene, current: current).filter {
                if case let .windowTop(_, app) = $0.perch.surface { return app.localizedCaseInsensitiveContains(name) }
                return false
            }
            if let best = matches.max(by: { $0.score < $1.score }) { return best.perch }
            // No free top edge (a maximized window, say): stand on the floor beneath the app's window.
            guard let window = scene.windows.first(where: { $0.app.localizedCaseInsensitiveContains(name) }),
                  let index = scene.screens.firstIndex(where: { $0.frame.intersects(window.frame) }) else { return nil }
            let v = scene.screens[index].visible
            let lower = max(v.minX, window.frame.minX) + rules.halfWidth
            let upper = min(v.maxX, window.frame.maxX) - rules.halfWidth
            let x = upper > lower ? upper - (upper - lower) * 0.15 : (lower + upper) / 2
            return Perch(surface: .floor(screen: index), point: CGPoint(x: x, y: v.minY), posture: .stand)
        case .floor:
            let reference = current?.point ?? scene.cursor
            let floors = candidates(in: scene).filter { if case .floor = $0.perch.surface { return true }; return false }
            let screen = scene.screen(containing: reference)
            return floors.filter { scene.screen(containing: $0.perch.point) == screen }
                .min { abs($0.perch.point.x - reference.x) < abs($1.perch.point.x - reference.x) }?.perch
                ?? floors.first?.perch
        case .cursor:
            let all = candidates(in: scene)
            return all.min { $0.perch.point.distance(to: scene.cursor) < $1.perch.point.distance(to: scene.cursor) }?.perch
        case let .screenSide(left):
            guard let screen = scene.screen(containing: scene.cursor), let index = scene.screens.firstIndex(of: screen) else { return nil }
            let v = screen.visible
            let x = left ? v.minX + rules.halfWidth + 20 : v.maxX - rules.halfWidth - 20
            return Perch(surface: .floor(screen: index), point: CGPoint(x: x, y: v.minY), posture: .stand)
        case let .point(p):
            return landing(below: p, in: scene)
        }
    }

    /// A hovering spot at `point`, kept fully on its display.
    public func hover(at point: CGPoint, in scene: SceneSnapshot) -> Perch? {
        guard let screen = scene.screen(containing: point) else { return nil }
        let v = screen.visible
        let x = clamp(point.x, v.minX + rules.halfWidth, max(v.minX + rules.halfWidth, v.maxX - rules.halfWidth))
        let y = clamp(point.y, v.minY + 20, max(v.minY + 20, v.maxY - rules.headroom * 1.6))
        return Perch(surface: .air, point: CGPoint(x: x, y: y), posture: .float)
    }

    /// The first surface under `point`: what she lands on when dropped or when her ledge vanishes.
    public func landing(below point: CGPoint, in scene: SceneSnapshot) -> Perch? {
        var best: (Ledge, CGFloat)?
        for ledge in ledges(in: scene) where ledge.y <= point.y + 1 {
            guard let span = ledge.spans.first(where: { $0.contains(point.x) }) else { continue }
            if best == nil || ledge.y > best!.0.y { best = (ledge, clamp(point.x, span.lowerBound, span.upperBound)) }
        }
        if let (ledge, x) = best {
            return Perch(surface: ledge.surface, point: CGPoint(x: x, y: ledge.y), posture: ledge.posture,
                         offset: ledge.window.map { x - $0.frame.minX } ?? 0)
        }
        guard let screen = scene.screen(containing: point), let index = scene.screens.firstIndex(of: screen) else { return nil }
        let v = screen.visible
        let x = clamp(point.x, v.minX + rules.halfWidth, max(v.minX + rules.halfWidth, v.maxX - rules.halfWidth))
        return Perch(surface: .floor(screen: index), point: CGPoint(x: x, y: v.minY), posture: .stand)
    }

    /// Where a window perch is now (the window may have moved), or nil if it is
    /// gone, too small, hidden behind another window, or out of headroom.
    public func relocate(_ perch: Perch, in scene: SceneSnapshot) -> Perch? {
        switch perch.surface {
        case let .windowTop(id, _):
            guard let ledge = ledges(in: scene).first(where: { $0.surface == perch.surface }),
                  let window = scene.window(id: id) else { return nil }
            let x = window.frame.minX + perch.offset
            guard ledge.spans.contains(where: { $0.contains(x) }) else { return nil }
            var moved = perch
            moved.point = CGPoint(x: x, y: ledge.y)
            return moved
        case let .floor(index):
            guard index < scene.screens.count else { return nil }
            var moved = perch
            moved.point.y = scene.screens[index].visible.minY
            return moved
        case .air:
            return scene.screen(containing: perch.point) == nil ? nil : perch
        }
    }
}

/// Removes `cut` from a set of disjoint ranges.
func subtract(_ spans: [ClosedRange<CGFloat>], _ cut: ClosedRange<CGFloat>) -> [ClosedRange<CGFloat>] {
    var out: [ClosedRange<CGFloat>] = []
    for s in spans {
        if cut.upperBound < s.lowerBound || cut.lowerBound > s.upperBound { out.append(s); continue }
        if cut.lowerBound > s.lowerBound { out.append(s.lowerBound...cut.lowerBound) }
        if cut.upperBound < s.upperBound { out.append(cut.upperBound...s.upperBound) }
    }
    return out.filter { $0.upperBound - $0.lowerBound > 0.5 }
}
