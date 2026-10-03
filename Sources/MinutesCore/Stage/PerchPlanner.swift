import CoreGraphics

/// Tunables for where she may be. Distances are points at scale 1; use `scaled`.
public struct PerchRules: Equatable {
    /// Half her width including resting hands: the anchor keeps this far from obstacles.
    public var halfWidth: CGFloat = 78
    /// Room needed above a ledge for her body when sitting on it.
    public var headroom: CGFloat = 125
    /// Keep clear of the traffic-light buttons at a window's top-left.
    public var leftInset: CGFloat = 110
    public var rightInset: CGFloat = 80
    /// Hanging under a bottom edge: the edge is this far above her anchor (her hands grip just below it).
    public var hangReach: CGFloat = Motions.hangGrip + 10
    /// Half her width while hanging.
    public var hangHalfWidth: CGFloat = 62
    /// Her hands stay this far inside a window's bottom corners.
    public var hangInset: CGFloat = 44
    /// Room needed below a hanging anchor for her dangling shoes.
    public var hangDrop: CGFloat = 14
    /// Clinging to a side: her anchor is this far out from the edge...
    public var clingReach: CGFloat = Motions.clingGrip + 8
    /// ...and her far side this much further out.
    public var clingAway: CGFloat = 60
    /// A clinging anchor stays this far below the window's top, so her hand is on the side.
    public var clingTop: CGFloat = 150
    /// Her height above the anchor, standing or clinging.
    public var height: CGFloat = 165
    /// The longest hop between ledges, and the longest drop onto one straight below.
    public var jump: CGFloat = 300
    public var drop: CGFloat = 420
    public var dropReach: CGFloat = 220
    public var minWindowSize = CGSize(width: 320, height: 180)
    public var useWindows = true
    /// Hang from window bottoms and cling to window sides.
    public var useEdges = true
    public var useFloor = true
    public var avoidApps: Set<String> = []
    /// Spots closer than this to the pointer are avoided (she stays out of the way).
    public var cursorComfort: CGFloat = 170
    /// The character scale these distances were scaled by.
    public private(set) var scale: CGFloat = 1

    public init() {}

    public func scaled(_ s: CGFloat) -> PerchRules {
        var r = self
        let lengths: [WritableKeyPath<PerchRules, CGFloat>] = [
            \.halfWidth, \.headroom, \.hangReach, \.hangHalfWidth, \.hangInset, \.hangDrop,
            \.clingReach, \.clingAway, \.clingTop, \.height, \.jump, \.drop, \.dropReach,
        ]
        for key in lengths { r[keyPath: key] *= s }
        r.leftInset = max(leftInset, halfWidth * s)
        r.rightInset = max(rightInset, halfWidth * s)
        r.cursorComfort *= max(1, s)
        r.scale = scale * s
        return r
    }

    public func avoids(_ app: String) -> Bool {
        avoidApps.contains { $0.caseInsensitiveCompare(app) == .orderedSame }
    }
}

public struct ScoredPerch: Equatable {
    public var perch: Perch
    public var score: CGFloat
}

/// Chooses where she goes. The geometry (which spots exist and are safe, how
/// to get between them) is the `ScreenMap`'s; the planner adds taste: sampled
/// candidates, scores, and the weighted-random picks that keep her lively.
public struct PerchPlanner {
    public var rules: PerchRules

    public init(rules: PerchRules = PerchRules()) {
        self.rules = rules
    }

    /// The deterministic map of `scene`.
    public func map(_ scene: SceneSnapshot) -> ScreenMap { ScreenMap(scene: scene, rules: rules) }

    public func candidates(in scene: SceneSnapshot, current: Perch? = nil) -> [ScoredPerch] {
        let map = map(scene)
        var out: [ScoredPerch] = []
        for ledge in map.ledges {
            for span in ledge.spans {
                let width = span.upperBound - span.lowerBound
                let fractions: [CGFloat] = width < 40 ? [0.5] : [0.15, 0.5, 0.85]
                for f in fractions {
                    let perch = ledge.perch(at: span.lowerBound + width * f)
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
            if ledge.axis == .horizontal {
                // The right-hand part of a window is usually less busy than the left.
                let rel = (perch.point.x - w.frame.minX) / max(w.frame.width, 1)
                s *= 0.8 + 0.4 * rel
            }
            switch ledge.posture {
            case .hang: s *= 0.8
            case .cling: s *= 0.7
            case .sit, .stand, .float: break
            }
        } else {
            s = 0.55
        }
        if perch.point.distance(to: scene.cursor) < rules.cursorComfort { s *= 0.25 }
        if let current, perch.point.distance(to: current.point) < 120 { s *= 0.15 }
        return s
    }

    /// A weighted-random pick among sensible spots.
    public func choose<R: RandomNumberGenerator>(in scene: SceneSnapshot, current: Perch?, using rng: inout R) -> Perch? {
        pick(from: candidates(in: scene, current: current), using: &rng)
    }

    /// Weighted by score squared, so good spots win most of the time but not every time.
    func pick<R: RandomNumberGenerator>(from pool: [ScoredPerch], using rng: inout R) -> Perch? {
        let total = pool.reduce(0) { $0 + $1.score * $1.score }
        guard total > 0 else { return pool.first?.perch }
        var roll = CGFloat(Double.random(in: 0..<1, using: &rng)) * total
        for c in pool {
            roll -= c.score * c.score
            if roll <= 0 { return c.perch }
        }
        return pool.last?.perch
    }

    public func perch<R: RandomNumberGenerator>(for target: MoveTarget, in scene: SceneSnapshot, current: Perch?, using rng: inout R) -> Perch? {
        switch target {
        case .random:
            return choose(in: scene, current: current, using: &rng)
        case let .app(name):
            let mine = candidates(in: scene, current: current).filter { $0.perch.app?.localizedCaseInsensitiveContains(name) == true }
            let seats = mine.filter { $0.perch.posture == .sit }
            if let best = (seats.isEmpty ? mine : seats).max(by: { $0.score < $1.score }) { return best.perch }
            // No free edge (a maximized window, say): stand on the floor beneath the app's window.
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
        case .stroll:
            return stroll(from: current, in: scene, using: &rng)
        case let .explore(app):
            return explore(app: app ?? scene.frontApp, in: scene, current: current, using: &rng)
        case let .hang(app):
            let edges = candidates(in: scene, current: current).filter { $0.perch.posture == .hang || $0.perch.posture == .cling }
            let name = app ?? scene.frontApp
            let mine = edges.filter { c in name.map { c.perch.app?.localizedCaseInsensitiveContains($0) == true } ?? true }
            // A named app with no free edge has no answer; for "wherever I'm working" any window will do.
            return (mine.isEmpty && app == nil ? edges : mine).max { $0.score < $1.score }?.perch
        }
    }

    /// Somewhere else on `app`'s windows, favouring a different way of being
    /// there (hanging after sitting, say). Anywhere sensible when the app has no room.
    func explore<R: RandomNumberGenerator>(app: String?, in scene: SceneSnapshot, current: Perch?, using rng: inout R) -> Perch? {
        var pool = candidates(in: scene, current: current).filter { c in
            guard let app else { return c.perch.windowID != nil }
            return c.perch.app?.localizedCaseInsensitiveContains(app) == true
        }
        if let current {
            pool = pool.filter { $0.perch.point.distance(to: current.point) > rules.halfWidth * 1.5 }.map {
                var c = $0
                if c.perch.posture != current.posture { c.score *= 1.5 }
                return c
            }
        }
        return pick(from: pool, using: &rng) ?? choose(in: scene, current: current, using: &rng)
    }

    /// A short way along whatever she is on: a few steps along a ledge, a
    /// climb up or down a side, a shimmy under a bottom edge, a drift in the air.
    public func stroll<R: RandomNumberGenerator>(from perch: Perch?, in scene: SceneSnapshot, using rng: inout R) -> Perch? {
        guard let perch else { return nil }
        let map = map(scene)
        if perch.surface == .air {
            let drift = CGPoint(x: CGFloat.random(in: -3...3, using: &rng), y: CGFloat.random(in: -1...1, using: &rng)) * rules.halfWidth
            return map.hover(at: perch.point + drift)
        }
        guard let ledge = map.ledge(for: perch.surface) else { return nil }
        let t = ledge.coordinate(of: perch.point)
        guard let span = ledge.span(containing: t, slack: 2) else { return nil }
        let shortest = rules.halfWidth * 0.8, longest = rules.halfWidth * 4
        let ways = [(CGFloat(-1), t - span.lowerBound), (CGFloat(1), span.upperBound - t)].filter { $0.1 >= shortest }
        guard !ways.isEmpty else { return nil }
        let way = ways[ways.count == 1 ? 0 : Int.random(in: 0...1, using: &rng)]
        let distance = CGFloat.random(in: shortest...min(longest, way.1), using: &rng)
        return ledge.perch(at: clamp(t + way.0 * distance, span.lowerBound, span.upperBound))
    }

    /// A hovering spot at `point`, kept fully on its display.
    public func hover(at point: CGPoint, in scene: SceneSnapshot) -> Perch? { map(scene).hover(at: point) }

    /// The first surface under `point`: what she lands on when dropped or when her ledge vanishes.
    public func landing(below point: CGPoint, in scene: SceneSnapshot) -> Perch? { map(scene).landing(below: point) }

    /// Where a window perch is now (the window may have moved), or nil if it is
    /// gone, too small, hidden behind another window, or out of room.
    public func relocate(_ perch: Perch, in scene: SceneSnapshot) -> Perch? { map(scene).relocate(perch) }
}
