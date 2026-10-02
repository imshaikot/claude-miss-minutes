import CoreGraphics
import Testing
@testable import MinutesCore

/// A 1440×900 display with a 25 pt menu bar and a 70 pt Dock.
private let screen = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                visible: CGRect(x: 0, y: 70, width: 1440, height: 805))

private func window(_ id: Int, _ app: String, _ rect: CGRect, pid: Int32 = 1) -> WindowInfo {
    WindowInfo(id: id, app: app, pid: pid, frame: rect)
}

@Suite("Perch planner")
struct PerchPlannerTests {
    @Test func aWindowTopIsASeatWhenThereIsHeadroom() {
        let scene = SceneSnapshot(screens: [screen], windows: [window(1, "Safari", CGRect(x: 200, y: 150, width: 800, height: 500))],
                                  cursor: CGPoint(x: 1400, y: 100))
        let seats = PerchPlanner().candidates(in: scene).filter { $0.perch.posture == .sit }
        #expect(!seats.isEmpty)
        for seat in seats {
            #expect(seat.perch.point.y == 650)
            #expect(seat.perch.point.x >= 200 + 110 && seat.perch.point.x <= 1000 - 80)
        }
    }

    @Test func maximizedWindowsOfferNoSeat() {
        let scene = SceneSnapshot(screens: [screen], windows: [window(1, "Xcode", screen.visible)])
        let seats = PerchPlanner().candidates(in: scene).filter { $0.perch.posture == .sit }
        #expect(seats.isEmpty)
    }

    @Test func windowsInFrontHideTheEdgeBehindThem() {
        let back = window(2, "Notes", CGRect(x: 100, y: 150, width: 1000, height: 400))
        // In front, covering the right half of Notes' top edge.
        let front = window(1, "Mail", CGRect(x: 600, y: 300, width: 500, height: 400))
        let scene = SceneSnapshot(screens: [screen], windows: [front, back])
        let notesSeats = PerchPlanner().candidates(in: scene).filter { $0.perch.windowID == 2 }
        #expect(!notesSeats.isEmpty)
        for seat in notesSeats { #expect(seat.perch.point.x <= 600 - PerchRules().halfWidth) }
    }

    @Test func theFrontAppIsPreferredAndThePointerAvoided() {
        let a = window(1, "Safari", CGRect(x: 100, y: 150, width: 500, height: 400), pid: 10)
        let b = window(2, "Notes", CGRect(x: 800, y: 150, width: 500, height: 400), pid: 20)
        var scene = SceneSnapshot(screens: [screen], windows: [a, b], frontPID: 20, cursor: CGPoint(x: 0, y: 900))
        let planner = PerchPlanner()
        let best = planner.candidates(in: scene).max { $0.score < $1.score }!
        #expect(best.perch.windowID == 2)
        scene.cursor = best.perch.point
        let nearPointer = planner.candidates(in: scene).first { $0.perch.point == best.perch.point }!
        #expect(nearPointer.score < best.score)
    }

    @Test func choiceIsReproducibleWithASeed() {
        let scene = SceneSnapshot(screens: [screen], windows: [window(1, "Safari", CGRect(x: 200, y: 150, width: 800, height: 500))])
        var a = SeededRandom(seed: 42), b = SeededRandom(seed: 42)
        let planner = PerchPlanner()
        #expect(planner.choose(in: scene, current: nil, using: &a) == planner.choose(in: scene, current: nil, using: &b))
    }

    @Test func fallingLandsOnTheFirstLedgeBelow() {
        let low = window(2, "Notes", CGRect(x: 100, y: 120, width: 900, height: 200))
        let high = window(1, "Safari", CGRect(x: 100, y: 120, width: 900, height: 450))
        let scene = SceneSnapshot(screens: [screen], windows: [high, low])
        let planner = PerchPlanner()
        let landing = planner.landing(below: CGPoint(x: 500, y: 800), in: scene)
        #expect(landing?.point.y == 570)
        #expect(landing?.windowID == 1)
        // Off to the side of every window: down to the floor (top of the Dock).
        let floor = planner.landing(below: CGPoint(x: 1300, y: 800), in: scene)
        #expect(floor?.point.y == 70)
        #expect(floor?.posture == .stand)
    }

    @Test func aPerchRidesAlongWhenItsWindowMoves() {
        var w = window(1, "Safari", CGRect(x: 200, y: 150, width: 800, height: 500))
        let planner = PerchPlanner()
        let perch = planner.candidates(in: SceneSnapshot(screens: [screen], windows: [w])).first { $0.perch.windowID == 1 }!.perch
        w.frame.origin = CGPoint(x: 260, y: 100)
        let moved = planner.relocate(perch, in: SceneSnapshot(screens: [screen], windows: [w]))
        #expect(moved?.point == CGPoint(x: perch.point.x + 60, y: 600))
        #expect(planner.relocate(perch, in: SceneSnapshot(screens: [screen], windows: [])) == nil)
    }

    @Test func movingToAnAppWithoutRoomStandsBeneathIt() {
        let scene = SceneSnapshot(screens: [screen], windows: [window(1, "iTerm2", screen.visible)])
        var rng = SeededRandom(seed: 1)
        let perch = PerchPlanner().perch(for: .app("iterm"), in: scene, current: nil, using: &rng)
        #expect(perch?.posture == .stand)
        #expect(perch?.point.y == 70)
    }

    @Test func hoveringStaysOnScreen() {
        let scene = SceneSnapshot(screens: [screen], windows: [])
        let spot = PerchPlanner().hover(at: CGPoint(x: 5, y: 899), in: scene)
        #expect(spot?.posture == .float)
        #expect(spot!.point.x >= PerchRules().halfWidth)
        #expect(spot!.point.y < 875)
    }

    @Test func subtractCutsHoles() {
        #expect(subtract([0...100], 40...60) == [0...40, 60...100])
        #expect(subtract([0...100], -10...10) == [10...100])
        #expect(subtract([0...100], -10...200).isEmpty)
    }

    @Test func avoidedAppsAreNeverSeats() {
        var rules = PerchRules()
        rules.avoidApps = ["zoom.us"]
        let scene = SceneSnapshot(screens: [screen], windows: [window(1, "zoom.us", CGRect(x: 200, y: 150, width: 800, height: 500))])
        #expect(PerchPlanner(rules: rules).candidates(in: scene).allSatisfy { $0.perch.windowID == nil })
    }
}
