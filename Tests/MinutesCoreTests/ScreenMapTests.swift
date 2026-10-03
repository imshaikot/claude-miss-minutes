import CoreGraphics
import Testing
@testable import MinutesCore

/// A 1440×900 display with a 25 pt menu bar and a 70 pt Dock.
private let screen = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                visible: CGRect(x: 0, y: 70, width: 1440, height: 805))

private func window(_ id: Int, _ app: String, _ rect: CGRect, pid: Int32 = 1) -> WindowInfo {
    WindowInfo(id: id, app: app, pid: pid, frame: rect)
}

/// A window floating mid-screen, with room on every side.
private let safari = window(1, "Safari", CGRect(x: 400, y: 350, width: 600, height: 400), pid: 10)

private func map(_ windows: [WindowInfo], cursor: CGPoint = .zero) -> ScreenMap {
    ScreenMap(scene: SceneSnapshot(screens: [screen], windows: windows, cursor: cursor))
}

@Suite("Screen map")
struct ScreenMapTests {
    @Test func aWindowWithRoomAroundItOffersEveryEdge() {
        let ledges = map([safari]).ledges
        let rules = PerchRules()
        #expect(ledges.map(\.posture) == [.sit, .cling, .cling, .hang, .stand])
        let top = ledges[0], right = ledges[1], left = ledges[2], bottom = ledges[3]
        #expect(top.level == 750 && top.spans == [510...920])
        // Clinging: her anchor sits out beside the edge, low enough that her hand is on the side.
        #expect(right.surface == .windowSide(windowID: 1, app: "Safari", left: false))
        #expect(right.level == 1000 + rules.clingReach)
        #expect(left.level == 400 - rules.clingReach)
        #expect(left.spans == [354...(750 - rules.clingTop)])
        // Hanging: the edge is hangReach above her anchor.
        #expect(bottom.level == 350 - rules.hangReach)
        #expect(bottom.spans == [(400 + rules.hangInset)...(1000 - rules.hangInset)])
    }

    @Test func hangingNeedsRoomAboveTheDock() {
        let low = window(1, "Notes", CGRect(x: 400, y: 150, width: 600, height: 500))
        #expect(!map([low]).ledges.contains { $0.posture == .hang })
    }

    @Test func noClingingWhereTheScreenEnds() {
        let wide = window(1, "Notes", CGRect(x: 20, y: 300, width: 1400, height: 400))
        #expect(!map([wide]).ledges.contains { $0.posture == .cling })
    }

    @Test func edgesCanBeTurnedOff() {
        var rules = PerchRules()
        rules.useEdges = false
        let ledges = ScreenMap(scene: SceneSnapshot(screens: [screen], windows: [safari]), rules: rules).ledges
        #expect(ledges.map(\.posture) == [.sit, .stand])
    }

    @Test func aWindowInFrontCutsTheEdgesBehindIt() {
        let notes = window(2, "Notes", CGRect(x: 600, y: 600, width: 500, height: 250))
        let ledges = map([notes, safari]).ledges.filter { $0.window?.id == 1 }
        let top = ledges.first { $0.posture == .sit }!
        #expect(top.spans == [510...(600 - PerchRules().halfWidth)])
        // Notes covers the upper part of Safari's right side.
        let right = ledges.first { $0.surface == .windowSide(windowID: 1, app: "Safari", left: false) }!
        #expect(right.spans.allSatisfy { $0.upperBound <= 600 - PerchRules().height })
    }

    @Test func theSameSceneAlwaysMapsTheSameWay() {
        let notes = window(2, "Notes", CGRect(x: 600, y: 600, width: 500, height: 250))
        let a = map([notes, safari]), b = map([notes, safari])
        #expect(a.ledges == b.ledges)
        let anchor = CGPoint(x: 800, y: 750)
        #expect(a.safeSpot(near: anchor) == b.safeSpot(near: anchor))
        let start = a.ledges[0].perch(at: a.ledges[0].spans[0].lowerBound)
        let goal = a.ledges.last { $0.posture == .hang }!.perch(at: 700)
        #expect(a.route(from: start, to: goal) == b.route(from: start, to: goal))
    }

    @Test func layoutChangesIgnoreThePointer() {
        let a = SceneSnapshot(screens: [screen], windows: [safari], frontApp: "Safari", cursor: .zero)
        var b = a
        b.cursor = CGPoint(x: 300, y: 300)
        b.frontApp = "Notes"
        #expect(a.sameLayout(as: b))
        b.windows[0].frame.origin.x += 1
        #expect(!a.sameLayout(as: b))
    }
}

@Suite("Mapping step")
struct MappingStepTests {
    private let seat = Perch(surface: .windowTop(windowID: 1, app: "Safari"), point: CGPoint(x: 800, y: 750), posture: .sit, offset: 400)

    @Test func aSeatRidesAlongWithItsWindow() {
        var moved = safari
        moved.frame.origin = CGPoint(x: 450, y: 320)
        #expect(map([moved]).check(seat, anchor: seat.point) == .stay(Perch(surface: seat.surface, point: CGPoint(x: 850, y: 720), posture: .sit, offset: 400)))
    }

    @Test func aClingRidesAlongWithItsWindow() {
        let side = map([safari]).ledges[2].perch(at: 450)
        var moved = safari
        moved.frame.origin = CGPoint(x: 350, y: 380)
        guard case let .stay(perch) = map([moved]).check(side, anchor: side.point) else { Issue.record("expected to stay"); return }
        #expect(perch.point == CGPoint(x: 350 - PerchRules().clingReach, y: 480))
    }

    @Test func aWindowThatClosesDropsHer() {
        #expect(map([]).check(seat, anchor: seat.point) == .fall)
    }

    @Test func aCoveredSeatMovesToTheNearestSafeSpotOnTheSameWindow() {
        // Notes is raised over the middle of Safari's top edge, right where she sits.
        let notes = window(2, "Notes", CGRect(x: 600, y: 600, width: 500, height: 250))
        let covered = map([notes, safari])
        guard case let .move(spot) = covered.check(seat, anchor: seat.point) else { Issue.record("expected a move"); return }
        #expect(spot.surface == seat.surface)
        #expect(spot.point == CGPoint(x: 600 - PerchRules().halfWidth, y: 750))
        #expect(covered.relocate(spot) == spot)
    }

    @Test func theSafeSpotKeepsClearOfThePointer() {
        let notes = window(2, "Notes", CGRect(x: 600, y: 600, width: 500, height: 250))
        let pointer = CGPoint(x: 522, y: 760)
        guard case let .move(spot) = map([notes, safari], cursor: pointer).check(seat, anchor: seat.point) else { Issue.record("expected a move"); return }
        #expect(spot.point.distance(to: pointer) >= PerchRules().cursorComfort)
    }

    @Test func aFloorSpotOffAShrunkenDisplayMoves() {
        let floor = Perch(surface: .floor(screen: 0), point: CGPoint(x: 2000, y: 70), posture: .stand)
        guard case let .move(spot) = map([]).check(floor, anchor: floor.point) else { Issue.record("expected a move"); return }
        #expect(spot.point == CGPoint(x: 1440 - PerchRules().halfWidth, y: 70))
    }
}

@Suite("Routes")
struct RouteTests {
    @Test func alongOneLedgeIsASingleWalk() {
        let m = map([safari])
        let top = m.ledges[0]
        let legs = m.route(from: top.perch(at: 600), to: top.perch(at: 850))
        #expect(legs == [Leg(.walk, to: top.perch(at: 850))])
    }

    @Test func fromTheTopToUnderneathSheGoesRoundTheFrame() {
        let m = map([safari])
        let goal = m.ledges[3].perch(at: 700)
        let legs = m.route(from: m.ledges[0].perch(at: 700), to: goal)!
        // Along the top to the near corner, over onto the left side, down it, under the bottom edge, across.
        #expect(legs.map(\.locomotion) == [.walk, .hop, .climb, .hop, .shimmy])
        #expect(legs[2].to.point == CGPoint(x: 400 - PerchRules().clingReach, y: 354))
        #expect(legs.last?.to == goal)
    }

    @Test func aGapBetweenWindowsIsHopped() {
        let a = window(1, "Safari", CGRect(x: 100, y: 350, width: 500, height: 400))
        let c = window(2, "Notes", CGRect(x: 700, y: 350, width: 500, height: 400))
        let m = map([a, c])
        let from = m.ledge(for: .windowTop(windowID: 1, app: "Safari"))!.perch(at: 300)
        let to = m.ledge(for: .windowTop(windowID: 2, app: "Notes"))!.perch(at: 1000)
        #expect(m.route(from: from, to: to)?.map(\.locomotion) == [.walk, .hop, .walk])
    }

    @Test func noRouteWhenItWouldTakeTooLong() {
        let m = map([safari])
        #expect(m.route(from: m.ledges[0].perch(at: 700), to: m.ledges[3].perch(at: 700), maxSeconds: 5) == nil)
    }
}

@Suite("Where she goes")
struct PlannerTargetTests {
    private let scene = SceneSnapshot(screens: [screen], windows: [safari, window(2, "Notes", CGRect(x: 40, y: 120, width: 330, height: 200))],
                                      frontApp: "Safari", frontPID: 10, cursor: CGPoint(x: 1400, y: 880))

    @Test func aStrollStaysOnItsLedge() {
        let planner = PerchPlanner()
        let seat = planner.map(scene).ledges[0].perch(at: 700)
        var rng = SeededRandom(seed: 3)
        for _ in 0..<20 {
            let spot = planner.stroll(from: seat, in: scene, using: &rng)!
            let distance = abs(spot.point.x - seat.point.x)
            #expect(spot.surface == seat.surface && spot.point.y == seat.point.y)
            #expect(distance >= PerchRules().halfWidth * 0.8 - 0.001 && distance <= PerchRules().halfWidth * 4 + 0.001)
        }
    }

    @Test func hangingPicksAnEdgeOfTheApp() {
        var rng = SeededRandom(seed: 1)
        let spot = PerchPlanner().perch(for: .hang(app: "safari"), in: scene, current: nil, using: &rng)
        #expect(spot?.app == "Safari")
        #expect(spot?.posture == .hang || spot?.posture == .cling)
        #expect(PerchPlanner().perch(for: .hang(app: "Xcode"), in: scene, current: nil, using: &rng) == nil)
    }

    @Test func exploringStaysOnTheFrontApp() {
        let planner = PerchPlanner()
        let seat = planner.map(scene).ledges[0].perch(at: 700)
        var rng = SeededRandom(seed: 9)
        for _ in 0..<20 {
            let spot = planner.perch(for: .explore(app: nil), in: scene, current: seat, using: &rng)!
            #expect(spot.app == "Safari")
            #expect(spot.point.distance(to: seat.point) > PerchRules().halfWidth * 1.5)
        }
    }

    @Test func movingToAnAppPrefersItsTopEdge() {
        var rng = SeededRandom(seed: 1)
        #expect(PerchPlanner().perch(for: .app("Safari"), in: scene, current: nil, using: &rng)?.posture == .sit)
    }
}
