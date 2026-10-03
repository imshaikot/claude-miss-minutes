import CoreGraphics

/// How she gets along a ledge, or from one ledge to another.
public enum Locomotion: String, CaseIterable, Equatable {
    case walk, crawl, climb, shimmy, hop

    /// Points per second at scale 1 (hops are timed by the stage).
    public var speed: CGFloat {
        switch self {
        case .walk: return 95
        case .crawl: return 50
        case .climb: return 60
        case .shimmy: return 65
        case .hop: return 900
        }
    }
}

/// One step of a route: travel this way until she is at `to`.
public struct Leg: Equatable {
    public var locomotion: Locomotion
    public var to: Perch

    public init(_ locomotion: Locomotion, to: Perch) {
        self.locomotion = locomotion
        self.to = to
    }
}

/// A stretch of surface she can be on: the top or bottom edge of a window, one
/// of its sides, or a display's floor. Her anchor (level with her feet) runs
/// along a line at `level`; `spans` are the parts of that line where she fits:
/// on screen, not hidden by a window in front, with room for her body.
public struct Ledge: Equatable {
    public enum Axis: Equatable { case horizontal, vertical }

    public var surface: Surface
    /// How she rests there.
    public var posture: Posture
    public var axis: Axis
    /// The anchor line: y for horizontal ledges, x for vertical ones.
    public var level: CGFloat
    /// Free stretches of the other coordinate, ascending.
    public var spans: [ClosedRange<CGFloat>]
    /// Front-to-back index of its window; the floor is behind every window.
    public var depth: Int
    public var window: WindowInfo?
    public var screen: Int

    public func point(at t: CGFloat) -> CGPoint {
        axis == .horizontal ? CGPoint(x: t, y: level) : CGPoint(x: level, y: t)
    }

    /// Where `point` falls along the ledge.
    public func coordinate(of point: CGPoint) -> CGFloat { axis == .horizontal ? point.x : point.y }

    /// How she moves along it (`walk` stands for walking or crawling).
    public var locomotion: Locomotion {
        switch surface {
        case .windowSide: return .climb
        case .windowBottom: return .shimmy
        case .windowTop, .floor, .air: return .walk
        }
    }

    public func perch(at t: CGFloat) -> Perch {
        let p = point(at: t)
        var offset: CGFloat = 0
        if let frame = window?.frame { offset = axis == .horizontal ? p.x - frame.minX : p.y - frame.minY }
        return Perch(surface: surface, point: p, posture: posture, offset: offset)
    }

    /// The span holding `t`, allowing `slack` points either side.
    public func span(containing t: CGFloat, slack: CGFloat = 0.5) -> ClosedRange<CGFloat>? {
        spans.first { t >= $0.lowerBound - slack && t <= $0.upperBound + slack }
    }

    /// Something to land on when falling: a window top or a floor.
    var catchesFalls: Bool { axis == .horizontal && (posture == .sit || posture == .stand) }
}

/// The map of where she can be on the current screen: every ledge (window
/// tops, sides and bottoms, display floors) with its safe stretches. It is
/// built from one `SceneSnapshot` by geometry alone, so the same scene always
/// gives the same map, the same safe spot and the same routes. The stage
/// rebuilds it whenever the layout changes and asks `check` what to do.
public struct ScreenMap {
    public let scene: SceneSnapshot
    public let rules: PerchRules
    public let ledges: [Ledge]

    public init(scene: SceneSnapshot, rules: PerchRules = PerchRules()) {
        self.scene = scene
        self.rules = rules
        ledges = Self.build(scene, rules)
    }

    public func ledge(for surface: Surface) -> Ledge? { ledges.first { $0.surface == surface } }

    // MARK: Building

    static func build(_ scene: SceneSnapshot, _ r: PerchRules) -> [Ledge] {
        var result: [Ledge] = []
        if r.useWindows || r.useEdges {
            for (depth, w) in scene.windows.enumerated() {
                guard w.frame.width >= r.minWindowSize.width, w.frame.height >= r.minWindowSize.height, !r.avoids(w.app) else { continue }
                let front = scene.windows[..<depth].map(\.frame)
                if r.useWindows, let top = top(of: w, depth: depth, front: front, scene, r) { result.append(top) }
                guard r.useEdges else { continue }
                for left in [false, true] {
                    if let side = side(of: w, left: left, depth: depth, front: front, scene, r) { result.append(side) }
                }
                if let bottom = bottom(of: w, depth: depth, front: front, scene, r) { result.append(bottom) }
            }
        }
        if r.useFloor || result.isEmpty {
            for (index, screen) in scene.screens.enumerated() {
                let v = screen.visible
                let spans = stretch(v.minX + r.halfWidth, v.maxX - r.halfWidth)
                guard !spans.isEmpty else { continue }
                result.append(Ledge(surface: .floor(screen: index), posture: .stand, axis: .horizontal, level: v.minY,
                                    spans: spans, depth: scene.windows.count, window: nil, screen: index))
            }
        }
        return result
    }

    /// Sitting on the top edge, clear of the traffic lights, with headroom under the menu bar.
    private static func top(of w: WindowInfo, depth: Int, front: [CGRect], _ scene: SceneSnapshot, _ r: PerchRules) -> Ledge? {
        let f = w.frame, y = f.maxY
        guard let screen = scene.screens.firstIndex(where: { $0.frame.contains(CGPoint(x: f.midX, y: y - 1)) }) else { return nil }
        let v = scene.screens[screen].visible
        guard y + r.headroom <= v.maxY, y > v.minY + 60 else { return nil }
        var spans = stretch(max(f.minX + r.leftInset, v.minX + r.halfWidth), min(f.maxX - r.rightInset, v.maxX - r.halfWidth))
        spans = clear(spans, of: front, band: (y - 6)...(y + r.headroom), axis: .horizontal, before: r.halfWidth, after: r.halfWidth)
        guard !spans.isEmpty else { return nil }
        return Ledge(surface: .windowTop(windowID: w.id, app: w.app), posture: .sit, axis: .horizontal, level: y,
                     spans: spans, depth: depth, window: w, screen: screen)
    }

    /// Clinging to the outside of a side, with room beside it for her body and her hand on the edge.
    private static func side(of w: WindowInfo, left: Bool, depth: Int, front: [CGRect], _ scene: SceneSnapshot, _ r: PerchRules) -> Ledge? {
        let f = w.frame
        let x = left ? f.minX - r.clingReach : f.maxX + r.clingReach
        let far = left ? x - r.clingAway : x + r.clingAway
        guard let screen = scene.screens.firstIndex(where: { $0.frame.contains(CGPoint(x: x, y: f.midY)) }) else { return nil }
        let v = scene.screens[screen].visible
        guard far >= v.minX, far <= v.maxX else { return nil }
        var spans = stretch(max(f.minY + 4, v.minY), min(f.maxY - r.clingTop, v.maxY - r.height))
        let band = left ? far...(f.minX + 4) : (f.maxX - 4)...far
        spans = clear(spans, of: front, band: band, axis: .vertical, before: 6, after: r.height)
        guard !spans.isEmpty else { return nil }
        return Ledge(surface: .windowSide(windowID: w.id, app: w.app, left: left), posture: .cling, axis: .vertical, level: x,
                     spans: spans, depth: depth, window: w, screen: screen)
    }

    /// Hanging under the bottom edge, with room down to the Dock for her legs.
    private static func bottom(of w: WindowInfo, depth: Int, front: [CGRect], _ scene: SceneSnapshot, _ r: PerchRules) -> Ledge? {
        let f = w.frame, y = f.minY - r.hangReach
        guard let screen = scene.screens.firstIndex(where: { $0.frame.contains(CGPoint(x: f.midX, y: f.minY - 1)) }) else { return nil }
        let v = scene.screens[screen].visible
        guard y - r.hangDrop >= v.minY, f.minY <= v.maxY else { return nil }
        var spans = stretch(max(f.minX + r.hangInset, v.minX + r.hangHalfWidth), min(f.maxX - r.hangInset, v.maxX - r.hangHalfWidth))
        spans = clear(spans, of: front, band: (y - r.hangDrop)...(f.minY + 4), axis: .horizontal, before: r.hangHalfWidth, after: r.hangHalfWidth)
        guard !spans.isEmpty else { return nil }
        return Ledge(surface: .windowBottom(windowID: w.id, app: w.app), posture: .hang, axis: .horizontal, level: y,
                     spans: spans, depth: depth, window: w, screen: screen)
    }

    private static func stretch(_ lower: CGFloat, _ upper: CGFloat) -> [ClosedRange<CGFloat>] {
        upper >= lower ? [lower...upper] : []
    }

    /// Cuts out every stretch where she would overlap a window in front. `band`
    /// is the strip she occupies across the ledge; along it her body reaches
    /// `before` behind her anchor and `after` ahead of it.
    private static func clear(_ spans: [ClosedRange<CGFloat>], of front: [CGRect], band: ClosedRange<CGFloat>,
                              axis: Ledge.Axis, before: CGFloat, after: CGFloat) -> [ClosedRange<CGFloat>] {
        var spans = spans
        for rect in front {
            let (acrossLow, acrossHigh) = axis == .horizontal ? (rect.minY, rect.maxY) : (rect.minX, rect.maxX)
            guard acrossLow < band.upperBound, acrossHigh > band.lowerBound else { continue }
            let (alongLow, alongHigh) = axis == .horizontal ? (rect.minX, rect.maxX) : (rect.minY, rect.maxY)
            spans = subtract(spans, (alongLow - after)...(alongHigh + before))
        }
        return spans
    }

    /// Where her anchor goes on `surface` of a window whose frame is `frame`, `offset` along it.
    public static func anchor(on surface: Surface, frame: CGRect, offset: CGFloat, rules r: PerchRules) -> CGPoint? {
        switch surface {
        case .windowTop: return CGPoint(x: frame.minX + offset, y: frame.maxY)
        case .windowBottom: return CGPoint(x: frame.minX + offset, y: frame.minY - r.hangReach)
        case let .windowSide(_, _, left): return CGPoint(x: left ? frame.minX - r.clingReach : frame.maxX + r.clingReach, y: frame.minY + offset)
        case .floor, .air: return nil
        }
    }

    // MARK: Keeping her safe

    /// What the mapping step decides for where she is now.
    public enum Verdict: Equatable {
        /// Her spot is still fine (moved along with its window if that moved).
        case stay(Perch)
        /// What she was on has gone: she falls to whatever is below.
        case fall
        /// Her spot is no longer safe (covered, squeezed, off screen): go here instead.
        case move(Perch)
    }

    public func check(_ perch: Perch, anchor: CGPoint) -> Verdict {
        if let moved = relocate(perch) { return .stay(moved) }
        if let id = perch.windowID, scene.window(id: id) == nil { return .fall }
        guard let spot = safeSpot(near: anchor, current: perch) else { return .stay(perch) }
        return .move(spot)
    }

    /// Where `perch` is in this scene (its window may have moved), or nil if
    /// that spot is gone, covered, squeezed or off screen.
    public func relocate(_ perch: Perch) -> Perch? {
        switch perch.surface {
        case .air:
            return scene.screens.contains { $0.frame.insetBy(dx: -1, dy: -1).contains(perch.point) } ? perch : nil
        case .floor:
            guard let ledge = ledge(for: perch.surface), ledge.span(containing: perch.point.x, slack: 2) != nil else { return nil }
            var moved = perch
            moved.point.y = ledge.level
            return moved
        case .windowTop, .windowBottom, .windowSide:
            guard let ledge = ledge(for: perch.surface), let frame = ledge.window?.frame,
                  let point = Self.anchor(on: perch.surface, frame: frame, offset: perch.offset, rules: rules),
                  ledge.span(containing: ledge.coordinate(of: point)) != nil else { return nil }
            var moved = perch
            moved.point = point
            return moved
        }
    }

    /// The closest safe place to `anchor`: the nearest point of every free
    /// stretch, ranked by distance with small preferences (her own window, the
    /// frontmost app, sitting over hanging over standing, away from the
    /// pointer). Ties go to the ledge listed first, so the answer never varies.
    public func safeSpot(near anchor: CGPoint, current: Perch? = nil) -> Perch? {
        var best: (perch: Perch, cost: CGFloat)?
        for ledge in ledges {
            for span in ledge.spans {
                let perch = ledge.perch(at: clamp(ledge.coordinate(of: anchor), span.lowerBound, span.upperBound))
                let cost = safeCost(perch, ledge: ledge, from: anchor, current: current)
                if cost < (best?.cost ?? .infinity) { best = (perch, cost) }
            }
        }
        return best?.perch
    }

    func safeCost(_ perch: Perch, ledge: Ledge, from anchor: CGPoint, current: Perch?) -> CGFloat {
        let unit = rules.halfWidth
        var cost = perch.point.distance(to: anchor)
        switch ledge.posture {
        case .sit: break
        case .hang: cost += unit * 0.5
        case .cling: cost += unit * 0.8
        case .stand, .float: cost += unit * 1.5
        }
        if perch.point.distance(to: scene.cursor) < rules.cursorComfort { cost += unit * 4 }
        if let id = current?.windowID, ledge.window?.id == id { cost -= unit * 2 }
        if let front = scene.frontPID, ledge.window?.pid == front { cost -= unit }
        return cost
    }

    /// The first surface under `point` she can stand or sit on: what she lands on when dropped or when her ledge vanishes.
    public func landing(below point: CGPoint) -> Perch? {
        var best: (ledge: Ledge, x: CGFloat)?
        for ledge in ledges where ledge.catchesFalls && ledge.level <= point.y + 1 {
            guard let span = ledge.spans.first(where: { $0.contains(point.x) }) else { continue }
            if best == nil || ledge.level > best!.ledge.level { best = (ledge, clamp(point.x, span.lowerBound, span.upperBound)) }
        }
        if let best { return best.ledge.perch(at: best.x) }
        guard let screen = scene.screen(containing: point), let index = scene.screens.firstIndex(of: screen) else { return nil }
        let v = screen.visible
        let x = clamp(point.x, v.minX + rules.halfWidth, max(v.minX + rules.halfWidth, v.maxX - rules.halfWidth))
        return Perch(surface: .floor(screen: index), point: CGPoint(x: x, y: v.minY), posture: .stand)
    }

    /// A hovering spot at `point`, kept fully on its display.
    public func hover(at point: CGPoint) -> Perch? {
        guard let screen = scene.screen(containing: point) else { return nil }
        let v = screen.visible
        let x = clamp(point.x, v.minX + rules.halfWidth, max(v.minX + rules.halfWidth, v.maxX - rules.halfWidth))
        let y = clamp(point.y, v.minY + 20, max(v.minY + 20, v.maxY - rules.headroom * 1.6))
        return Perch(surface: .air, point: CGPoint(x: x, y: y), posture: .float)
    }

    // MARK: Routes

    private struct Node {
        var ledge: Int
        var span: Int?
        var t: CGFloat
        var point: CGPoint
    }

    /// The quickest way from `start` to `goal` over the ledges: along them
    /// (walking, climbing a side, shimmying under a bottom edge) and hopping
    /// between them where they come close, or dropping onto one below. So she
    /// goes around a window's frame rather than through it. Nil when either end
    /// is off the map, there is no way through, or it takes over `maxSeconds`.
    public func route(from start: Perch, to goal: Perch, maxSeconds: Double = .infinity) -> [Leg]? {
        guard let a = locate(start), let b = locate(goal), b.span != nil else { return nil }
        var nodes = [Node(ledge: a.ledge, span: a.span, t: a.t, point: start.point),
                     Node(ledge: b.ledge, span: b.span, t: b.t, point: goal.point)]
        for (li, ledge) in ledges.enumerated() {
            for (si, span) in ledge.spans.enumerated() {
                nodes.append(Node(ledge: li, span: si, t: span.lowerBound, point: ledge.point(at: span.lowerBound)))
                if span.upperBound - span.lowerBound > 0.5 {
                    nodes.append(Node(ledge: li, span: si, t: span.upperBound, point: ledge.point(at: span.upperBound)))
                }
            }
        }

        // Hops: from every start, goal and span end to the nearest point of every other span within reach.
        var hops: [(from: Int, to: Int, cost: Double)] = []
        let base = nodes.count
        for i in 0..<base {
            let n = nodes[i]
            for (li, ledge) in ledges.enumerated() {
                for (si, span) in ledge.spans.enumerated() where !(li == n.ledge && si == n.span) {
                    let t = clamp(ledge.coordinate(of: n.point), span.lowerBound, span.upperBound)
                    let p = ledge.point(at: t)
                    let there = canHop(n.point, p, from: ledges[n.ledge], to: ledge)
                    let back = canHop(p, n.point, from: ledge, to: ledges[n.ledge])
                    guard there || back else { continue }
                    let j = nodes.count
                    nodes.append(Node(ledge: li, span: si, t: t, point: p))
                    let cost = hopCost(n.point, p) + ((p - n.point).length > rules.jump ? 1 : 0)
                    if there { hops.append((i, j, cost)) }
                    if back { hops.append((j, i, cost)) }
                }
            }
        }

        var edges = Array(repeating: [(to: Int, cost: Double, hop: Bool)](), count: nodes.count)
        for hop in hops { edges[hop.from].append((hop.to, hop.cost, true)) }
        // Along a span: link neighbouring nodes, sorted so the graph is the same every time.
        let onSpans = nodes.indices.filter { nodes[$0].span != nil }.sorted {
            (nodes[$0].ledge, nodes[$0].span!, nodes[$0].t, $0) < (nodes[$1].ledge, nodes[$1].span!, nodes[$1].t, $1)
        }
        for (i, j) in zip(onSpans, onSpans.dropFirst()) where nodes[i].ledge == nodes[j].ledge && nodes[i].span == nodes[j].span {
            let speed = ledges[nodes[i].ledge].locomotion.speed * rules.scale
            let cost = Double(abs(nodes[j].t - nodes[i].t) / speed)
            edges[i].append((j, cost, false))
            edges[j].append((i, cost, false))
        }

        // Dijkstra from node 0 (start) to node 1 (goal).
        var best = Array(repeating: Double.infinity, count: nodes.count)
        var previous = Array(repeating: (node: -1, hop: false), count: nodes.count)
        var heap = RouteHeap()
        best[0] = 0
        heap.push(0, 0)
        while let (cost, i) = heap.pop() {
            if i == 1 { break }
            if cost > best[i] { continue }
            for edge in edges[i] where cost + edge.cost < best[edge.to] {
                best[edge.to] = cost + edge.cost
                previous[edge.to] = (i, edge.hop)
                heap.push(cost + edge.cost, edge.to)
            }
        }
        guard best[1].isFinite, best[1] <= maxSeconds else { return nil }

        var steps: [(node: Int, hop: Bool)] = []
        var k = 1
        while k != 0 {
            steps.append((k, previous[k].hop))
            k = previous[k].node
        }
        var legs: [Leg] = []
        var here = start.point
        for step in steps.reversed() {
            let node = nodes[step.node]
            let ledge = ledges[node.ledge]
            let perch = step.node == 1 ? goal : ledge.perch(at: node.t)
            defer { here = perch.point }
            if !step.hop, perch.point.distance(to: here) < 0.5 { continue }
            if !step.hop, let last = legs.last, last.locomotion != .hop, last.to.surface == perch.surface {
                legs[legs.count - 1].to = perch
            } else {
                legs.append(Leg(step.hop ? .hop : ledge.locomotion, to: perch))
            }
        }
        return legs
    }

    /// Which ledge and span `perch` is on, and where along it.
    private func locate(_ perch: Perch) -> (ledge: Int, span: Int?, t: CGFloat)? {
        guard let index = ledges.firstIndex(where: { $0.surface == perch.surface }) else { return nil }
        let ledge = ledges[index]
        let across = ledge.axis == .horizontal ? perch.point.y : perch.point.x
        guard abs(across - ledge.level) <= 2 else { return nil }
        let t = ledge.coordinate(of: perch.point)
        return (index, ledge.spans.firstIndex { t >= $0.lowerBound - 1 && t <= $0.upperBound + 1 }, t)
    }

    /// Close enough to hop, or a drop onto a top or floor below that doesn't
    /// pass through the window she's leaving (from its top she climbs down a side first).
    func canHop(_ a: CGPoint, _ b: CGPoint, from: Ledge, to: Ledge) -> Bool {
        let d = b - a
        let length = d.length
        guard length >= 1 else { return false }
        if length <= rules.jump { return true }
        guard to.catchesFalls, d.y < 0, abs(d.x) <= rules.dropReach, -d.y <= rules.drop else { return false }
        let path = CGRect(x: min(a.x, b.x), y: b.y, width: abs(d.x), height: -d.y)
        return from.window.map { !$0.frame.insetBy(dx: 4, dy: 4).intersects(path) } ?? true
    }

    /// Hops cost more than their airtime, so she keeps her feet on a ledge
    /// where she can; long drops cost a second more again.
    private func hopCost(_ a: CGPoint, _ b: CGPoint) -> Double {
        1.6 + Double((b - a).length / (Locomotion.hop.speed * rules.scale))
    }
}

/// A binary min-heap of (cost, node) for the route search, ordered by cost
/// and then by node so equal costs always resolve the same way.
struct RouteHeap {
    private var items: [(cost: Double, node: Int)] = []

    private static func less(_ a: (cost: Double, node: Int), _ b: (cost: Double, node: Int)) -> Bool {
        a.cost < b.cost || (a.cost == b.cost && a.node < b.node)
    }

    mutating func push(_ cost: Double, _ node: Int) {
        items.append((cost, node))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard Self.less(items[i], items[parent]) else { break }
            items.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> (cost: Double, node: Int)? {
        guard let first = items.first else { return nil }
        let last = items.removeLast()
        guard !items.isEmpty else { return first }
        items[0] = last
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var smallest = i
            if l < items.count, Self.less(items[l], items[smallest]) { smallest = l }
            if r < items.count, Self.less(items[r], items[smallest]) { smallest = r }
            guard smallest != i else { break }
            items.swapAt(i, smallest)
            i = smallest
        }
        return first
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
