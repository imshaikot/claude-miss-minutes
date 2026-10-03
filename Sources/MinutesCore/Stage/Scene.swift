import CoreGraphics

/// One on-screen window, in AppKit global coordinates (origin bottom-left of the
/// main display, y up).
public struct WindowInfo: Equatable, Codable {
    public var id: Int
    public var app: String
    public var pid: Int32
    public var frame: CGRect
    public var title: String?

    public init(id: Int, app: String, pid: Int32, frame: CGRect, title: String? = nil) {
        self.id = id
        self.app = app
        self.pid = pid
        self.frame = frame
        self.title = title
    }
}

public struct ScreenInfo: Equatable, Codable {
    public var frame: CGRect
    /// Excludes the menu bar and the Dock.
    public var visible: CGRect

    public init(frame: CGRect, visible: CGRect) {
        self.frame = frame
        self.visible = visible
    }
}

/// What the stage can see at one moment. Windows are ordered front to back.
public struct SceneSnapshot: Equatable, Codable {
    public var screens: [ScreenInfo]
    public var windows: [WindowInfo]
    public var frontApp: String?
    public var frontPID: Int32?
    public var cursor: CGPoint

    public init(screens: [ScreenInfo], windows: [WindowInfo], frontApp: String? = nil, frontPID: Int32? = nil, cursor: CGPoint = .zero) {
        self.screens = screens
        self.windows = windows
        self.frontApp = frontApp
        self.frontPID = frontPID
        self.cursor = cursor
    }

    public static let empty = SceneSnapshot(screens: [], windows: [])

    public func screen(containing point: CGPoint) -> ScreenInfo? {
        screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
            ?? screens.min { distance($0.frame, point) < distance($1.frame, point) }
    }

    public func window(id: Int) -> WindowInfo? { windows.first { $0.id == id } }

    /// Same displays and same windows in the same places, ignoring the pointer
    /// and which app is frontmost: nothing she stands on has changed.
    public func sameLayout(as other: SceneSnapshot) -> Bool {
        screens == other.screens && windows.count == other.windows.count
            && zip(windows, other.windows).allSatisfy { $0.id == $1.id && $0.frame == $1.frame }
    }

    private func distance(_ rect: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
        let dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// A short plain-text description for the brain.
    public func summary(limit: Int = 12) -> String {
        var lines: [String] = []
        if let frontApp { lines.append("Frontmost app: \(frontApp)") }
        for (i, screen) in screens.enumerated() {
            lines.append("Display \(i + 1): \(Int(screen.frame.width))×\(Int(screen.frame.height)) pt")
        }
        lines.append("Windows, front to back:")
        for w in windows.prefix(limit) {
            let title = (w.title?.isEmpty == false) ? " — \"\(w.title!)\"" : ""
            lines.append("• \(w.app)\(title) at x \(Int(w.frame.minX)), y \(Int(w.frame.minY)), \(Int(w.frame.width))×\(Int(w.frame.height))")
        }
        if windows.count > limit { lines.append("…and \(windows.count - limit) more") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Perches

public enum Posture: String, Codable {
    case sit, stand
    /// Hovering in mid-air (hologram style); used when gravity is off.
    case float
    /// Hanging by her hands from a window's bottom edge.
    case hang
    /// Clinging to the outside of a window's side.
    case cling
}

public enum Surface: Equatable, Codable {
    /// The top edge of a window: she sits with her legs over the title bar.
    case windowTop(windowID: Int, app: String)
    /// The bottom edge of a window: she hangs below it by her hands.
    case windowBottom(windowID: Int, app: String)
    /// The outside of a window's left or right side: she clings to it.
    case windowSide(windowID: Int, app: String, left: Bool)
    /// The floor of a display (top of the Dock, or the bottom of the screen).
    case floor(screen: Int)
    /// Anywhere on screen, hovering.
    case air
}

/// A place she can be: the surface, the anchor point on it and how she rests there.
/// The anchor is always level with her feet, whatever her posture, so every
/// way of travelling lines up with every way of resting.
public struct Perch: Equatable, Codable {
    public var surface: Surface
    public var point: CGPoint
    public var posture: Posture
    /// For window perches: distance from the window's left edge (top and
    /// bottom) or bottom edge (sides), so she rides along when the window moves.
    public var offset: CGFloat

    public init(surface: Surface, point: CGPoint, posture: Posture, offset: CGFloat = 0) {
        self.surface = surface
        self.point = point
        self.posture = posture
        self.offset = offset
    }

    public var windowID: Int? {
        switch surface {
        case let .windowTop(id, _), let .windowBottom(id, _), let .windowSide(id, _, _): return id
        case .floor, .air: return nil
        }
    }

    /// The app whose window she is on.
    public var app: String? {
        switch surface {
        case let .windowTop(_, app), let .windowBottom(_, app), let .windowSide(_, app, _): return app
        case .floor, .air: return nil
        }
    }
}

/// Where a move should go, as the director or a body tool names it.
public enum MoveTarget: Equatable {
    case random
    case app(String)
    case floor
    case cursor
    case screenSide(left: Bool)
    case point(CGPoint)
    /// A short way along whatever she is on: a few steps, a climb, a shimmy.
    case stroll
    /// Somewhere else on an app's windows (the frontmost app when nil), any
    /// way she can be there: sitting, hanging or clinging.
    case explore(app: String?)
    /// Hanging from or clinging to an edge of an app's window (the frontmost app when nil).
    case hang(app: String?)
}
