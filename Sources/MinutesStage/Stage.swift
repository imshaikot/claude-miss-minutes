import AppKit
import MinutesCharacter
import MinutesCore
import QuartzCore

/// The window she lives in: borderless, fully transparent, no shadow, above
/// normal windows on every Space (including full-screen apps). It never takes
/// focus and ignores the mouse except over her silhouette.
final class CharacterWindow: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        isMovable = false
        ignoresMouseEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // She may stand partly off screen or right under the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The director's handle on her performance (moods, gestures, activity loops, clock).
@MainActor
public final class Puppet: CharacterPort {
    private let animator: Animator
    private let pointDirection: () -> CGPoint

    public init(animator: Animator, pointDirection: @escaping () -> CGPoint) {
        self.animator = animator
        self.pointDirection = pointDirection
    }

    public func setMood(_ mood: Mood) { animator.setMood(mood, at: CACurrentMediaTime()) }
    public func play(_ gesture: GestureName) {
        animator.play(Gestures.make(gesture, toward: pointDirection()), at: CACurrentMediaTime())
    }
    public func setActivity(_ activity: Activity?) { animator.setActivity(activity, at: CACurrentMediaTime()) }
    public func setClock(_ mode: ClockMode) { animator.clockMode = mode }
}

/// Puts her on screen and moves her about: perching, walking, hopping,
/// teleporting, gliding, falling, being dragged, and riding along on windows.
@MainActor
public final class Stage: StagePort {
    public var onEvent: ((StageEvent) -> Void)?
    /// End of every frame, with a rect around her head in screen coordinates (for the bubble).
    public var onFrameEnd: ((CGRect) -> Void)?
    /// Polled every frame for lip sync.
    public var mouthProvider: (() -> MouthShape?)?

    public let animator = Animator()
    private let window: CharacterWindow
    private let view: CharacterView
    private let sense = ScreenSense()
    private var settings: CharacterSettings
    private var planner = PerchPlanner()
    private var rng = SystemRandomNumberGenerator()

    public private(set) var currentPerch: Perch?
    private var anchor = CGPoint(x: 400, y: 200)
    private var trackTarget = CGPoint.zero
    private var follow = Spring2D(stiffness: 240, dampingRatio: 0.9)
    private var movement: Movement?
    private var travelDone: ((Bool) -> Void)?
    private var drag: Drag?
    private var lastAnchor = CGPoint.zero
    private var velocity = CGPoint.zero
    private var lastScene = SceneSnapshot.empty
    private var nextSceneAt: Double = 0
    private var nextTrackAt: Double = 0
    private var quietUntil: Double = 0
    private var visible = false
    private var vanishing = false
    private var now: Double = CACurrentMediaTime()
    private var observers: [NSObjectProtocol] = []

    private enum Movement {
        case walk(from: CGPoint, to: Perch, start: Double, duration: Double)
        case hop(from: CGPoint, to: Perch, start: Double, duration: Double, arc: CGFloat)
        case glide(from: CGPoint, to: Perch, start: Double, duration: Double)
        case teleport(to: Perch, start: Double, arrived: Bool)
        case fall(velocity: CGFloat, hangUntil: Double, target: Perch?)
    }

    private struct Drag {
        var grab: CGPoint
        var start: CGPoint
        var moved = false
    }

    private var scale: CGFloat { CGFloat(settings.scale) }

    public init(settings: CharacterSettings) {
        self.settings = settings
        let size = CGSize(width: Rig.canvas.width * CGFloat(settings.scale), height: Rig.canvas.height * CGFloat(settings.scale))
        window = CharacterWindow(size: size)
        view = CharacterView(frame: CGRect(origin: .zero, size: size))
        window.contentView = view
        apply(settings)

        view.onFrame = { [weak self] now, dt in MainActor.assumeIsolated { self?.tick(now: now, dt: dt) } }
        view.onMouseDown = { [weak self] _ in MainActor.assumeIsolated { self?.mouseDown() } }
        view.onMouseDragged = { [weak self] _ in MainActor.assumeIsolated { self?.mouseDragged() } }
        view.onMouseUp = { [weak self] _ in MainActor.assumeIsolated { self?.mouseUp() } }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.nextSceneAt = 0 }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged() }
        })
    }

    public func apply(_ settings: CharacterSettings) {
        let rescaled = settings.scale != self.settings.scale
        self.settings = settings
        var rules = PerchRules()
        rules.useWindows = settings.perchOnWindows
        rules.useFloor = settings.perchOnFloor
        rules.avoidApps = Set(settings.shyApps)
        planner = PerchPlanner(rules: rules.scaled(scale))
        animator.hologram = settings.hologram
        view.scale = scale
        if rescaled {
            window.setContentSize(CGSize(width: Rig.canvas.width * scale, height: Rig.canvas.height * scale))
            positionWindow()
        }
        if visible { view.startDisplayLink(preferredFPS: settings.frameRate) }
    }

    // MARK: StagePort

    public var isVisible: Bool { visible && !vanishing }
    public var isTravelling: Bool { movement != nil || drag?.moved == true }

    public func scene() -> SceneSnapshot {
        lastScene = sense.snapshot()
        return lastScene
    }

    public func appear() {
        guard !visible || vanishing else { return }
        now = CACurrentMediaTime()
        vanishing = false
        visible = true
        lastScene = sense.snapshot()
        if let perch = currentPerch, let moved = planner.relocate(perch, in: lastScene) {
            currentPerch = moved
        } else {
            currentPerch = planner.choose(in: lastScene, current: nil, using: &rng)
                ?? planner.landing(below: CGPoint(x: lastScene.cursor.x, y: 10_000), in: lastScene)
        }
        if let perch = currentPerch { anchor = perch.point }
        settle()
        animator.setBase(baseMotion(for: currentPerch?.posture ?? .stand), at: now, blend: 0)
        animator.materialize(at: now)
        positionWindow()
        window.orderFrontRegardless()
        view.startDisplayLink(preferredFPS: settings.frameRate)
    }

    public func vanish() {
        guard visible, !vanishing else { return }
        finishTravel(false)
        vanishing = true
        animator.dematerialize(at: CACurrentMediaTime())
    }

    public func move(to target: MoveTarget, style: TravelStyle, completion: @escaping (Bool) -> Void) {
        let fresh = scene()
        var destination: Perch?
        if !settings.gravity {
            switch target {
            case .cursor: destination = planner.hover(at: fresh.cursor + CGPoint(x: 0, y: 30 * scale), in: fresh)
            case let .point(p): destination = planner.hover(at: p, in: fresh)
            case .random where Double.random(in: 0..<1, using: &rng) < 0.35:
                if let screen = fresh.screen(containing: anchor) {
                    let v = screen.visible
                    destination = planner.hover(at: CGPoint(x: .random(in: v.minX...v.maxX, using: &rng),
                                                            y: .random(in: v.minY...v.maxY, using: &rng)), in: fresh)
                }
            default: break
            }
        }
        if destination == nil {
            destination = planner.perch(for: target, in: fresh, current: currentPerch, using: &rng)
        }
        guard let destination else { completion(false); return }
        if !isVisible {
            currentPerch = destination
            appear()
            completion(true)
            return
        }
        travel(to: destination, style: style, completion: completion)
    }

    /// Unit vector from her toward the pointer (for the point gesture).
    public func directionToCursor() -> CGPoint {
        let head = anchor + CGPoint(x: 0, y: animator.lastPose.body.y * scale)
        let d = NSEvent.mouseLocation - head
        return d.length < 1 ? CGPoint(x: 1, y: 0.2) : d.normalized
    }

    // MARK: Travel

    private func baseMotion(for posture: Posture) -> BaseMotion {
        switch posture {
        case .sit: return .sit
        case .stand: return .stand
        case .float: return .float
        }
    }

    private func travel(to perch: Perch, style: TravelStyle, completion: @escaping (Bool) -> Void) {
        finishTravel(false)
        travelDone = completion
        let from = anchor
        let delta = perch.point - from
        let distance = delta.length
        let fromPosture = currentPerch?.posture ?? .stand
        let sameLevel = abs(delta.y) < 2 && currentPerch.map { $0.surface == perch.surface } == true
        let airborne = perch.posture == .float || fromPosture == .float

        var chosen = style
        if chosen == .auto {
            if airborne { chosen = distance < 900 * scale ? .hop : .teleport }
            else if sameLevel && abs(delta.x) < 650 * scale { chosen = .walk }
            else if distance < 750 * scale { chosen = .hop }
            else { chosen = .teleport }
        }
        if chosen == .walk && !sameLevel { chosen = .hop }

        animator.context.facing = delta.x >= 0 ? 1 : -1
        currentPerch = nil
        switch chosen {
        case .walk:
            movement = .walk(from: from, to: perch, start: now, duration: max(0.3, abs(delta.x) / (95 * scale)))
            animator.setBase(.walk, at: now, blend: 0.2)
        case .hop where airborne:
            movement = .glide(from: from, to: perch, start: now, duration: clamp(0.6 + Double(distance / (500 * scale)), 0.6, 2.2))
            animator.setBase(.float, at: now, blend: 0.3)
        case .hop:
            let arc = max(50 * scale, 70 * scale + max(0, delta.y) * 0.45)
            movement = .hop(from: from, to: perch, start: now, duration: clamp(0.6 + Double(distance / (1600 * scale)), 0.6, 1.1), arc: arc)
            animator.setBase(.hop, at: now, blend: 0.1)
            animator.restartBase(at: now)
        case .teleport, .auto:
            movement = .teleport(to: perch, start: now, arrived: false)
            animator.dematerialize(at: now)
            animator.clockMode = .spin
        }
    }

    private func finishTravel(_ arrived: Bool) {
        let done = travelDone
        travelDone = nil
        done?(arrived)
    }

    private func arrive(at perch: Perch, impact: CGFloat = 0) {
        movement = nil
        currentPerch = perch
        anchor = perch.point
        settle()
        animator.setBase(baseMotion(for: perch.posture), at: now, blend: impact > 0 ? 0.12 : 0.3)
        animator.reflexMood = nil
        if impact > 0 { animator.impact(impact) }
        finishTravel(true)
    }

    /// Resets the ride-along spring to where she is now.
    private func settle() {
        trackTarget = anchor
        follow = Spring2D(value: anchor, stiffness: 240, dampingRatio: 0.9)
    }

    private func startFall(surprised: Bool) {
        finishTravel(false)
        currentPerch = nil
        lastScene = sense.snapshot()
        let landing = planner.landing(below: anchor, in: lastScene)
        movement = .fall(velocity: 0, hangUntil: now + (surprised ? 0.35 : 0), target: landing)
        animator.setBase(.fall, at: now, blend: 0.12)
        animator.reflexMood = .surprised
        if surprised { onEvent?(.fell) }
    }

    private func updateMovement(dt: Double) {
        guard let movement else { return }
        switch movement {
        case let .walk(from, to, start, duration):
            let u = progress(now, from: start, to: start + duration)
            let previous = anchor.x
            anchor = lerp(from, to.point, u)
            animator.context.walkPhase += Double(abs(anchor.x - previous) / (2 * Motions.stride * scale))
            if u >= 1 { arrive(at: to) }

        case let .hop(from, to, start, duration, arc):
            let p = progress(now, from: start, to: start + duration)
            animator.context.progress = p
            let u = clamp((p - 0.18) / 0.64, 0, 1)
            anchor = lerp(from, to.point, Ease.inOut(u)) + CGPoint(x: 0, y: arc * 4 * u * (1 - u))
            if p >= 1 { arrive(at: to, impact: 0.35) }

        case let .glide(from, to, start, duration):
            let u = Ease.inOut(progress(now, from: start, to: start + duration))
            anchor = lerp(from, to.point, u) + CGPoint(x: 0, y: sin(.pi * u) * 30 * scale)
            if u >= 1 { arrive(at: to) }

        case let .teleport(to, start, arrived):
            if !arrived, now - start >= 0.45 {
                anchor = to.point
                settle()
                animator.setBase(baseMotion(for: to.posture), at: now, blend: 0)
                animator.materialize(at: now, duration: 0.7)
                self.movement = .teleport(to: to, start: now, arrived: true)
            } else if arrived, now - start >= 0.7 {
                animator.clockMode = .time
                arrive(at: to)
            }

        case let .fall(velocity, hangUntil, target):
            guard now >= hangUntil else { return }
            let v = velocity - 2600 * scale * CGFloat(dt)
            anchor.y += v * CGFloat(dt)
            if let target, anchor.y <= target.point.y {
                anchor.y = target.point.y
                anchor.x = target.point.x
                arrive(at: target, impact: min(1.4, abs(v) / (1100 * scale)))
                onEvent?(.landed)
            } else if anchor.y < -4000 {
                self.movement = nil
                currentPerch = nil
                visible = false
                appear()
            } else {
                self.movement = .fall(velocity: v, hangUntil: hangUntil, target: target)
            }
        }
    }

    // MARK: Perch upkeep

    private func spaceChanged() {
        guard isVisible, movement == nil, drag == nil, currentPerch?.windowID != nil else { return }
        quietUntil = now + 1
        move(to: .random, style: .teleport) { _ in }
    }

    private func upkeep(dt: Double) {
        guard movement == nil, drag == nil, let perch = currentPerch else { return }

        if case let .windowTop(id, _) = perch.surface, now >= nextTrackAt {
            nextTrackAt = now + 1.0 / 20
            if let frame = sense.frame(ofWindow: id) {
                trackTarget = CGPoint(x: frame.minX + perch.offset, y: frame.maxY)
            } else if now > quietUntil {
                startFall(surprised: true)
                return
            }
        }
        if perch.windowID != nil {
            follow.step(toward: trackTarget, dt: dt)
            anchor = follow.value
        }

        guard now >= nextSceneAt else { return }
        nextSceneAt = now + 1.2
        lastScene = sense.snapshot()
        if let moved = planner.relocate(perch, in: lastScene) {
            currentPerch = moved
            if moved.windowID == nil { anchor = moved.point }
        } else if case let .windowTop(id, _) = perch.surface, now > quietUntil {
            if lastScene.window(id: id) == nil {
                startFall(surprised: true)
            } else {
                // Covered by another window or squeezed under the menu bar: find a better seat.
                move(to: .random, style: .auto) { _ in }
            }
        }
    }

    // MARK: Pointer

    private func mouseDown() {
        let m = NSEvent.mouseLocation
        drag = Drag(grab: m - anchor, start: m)
    }

    private func mouseDragged() {
        guard var d = drag else { return }
        let m = NSEvent.mouseLocation
        if !d.moved, m.distance(to: d.start) > 4 {
            d.moved = true
            finishTravel(false)
            movement = nil
            currentPerch = nil
            animator.clockMode = .time
            animator.setBase(.dangle, at: now, blend: 0.15)
            onEvent?(.dragStarted)
        }
        if d.moved { anchor = m - d.grab }
        drag = d
    }

    private func mouseUp() {
        guard let d = drag else { return }
        drag = nil
        guard d.moved else { onEvent?(.clicked); return }
        onEvent?(.dropped)
        lastScene = sense.snapshot()
        if settings.gravity {
            startFall(surprised: false)
        } else if let spot = planner.hover(at: anchor, in: lastScene) {
            arrive(at: spot, impact: 0.3)
        }
    }

    // MARK: Frame

    private func tick(now: Double, dt: Double) {
        self.now = now
        updateMovement(dt: dt)
        upkeep(dt: dt)

        let raw = (anchor - lastAnchor) * CGFloat(1 / max(dt, 0.001))
        let previous = velocity
        velocity = lerp(velocity, raw, 0.35)
        lastAnchor = anchor
        animator.context.velocity = velocity
        let ridingOrDragged = movement == nil
        animator.acceleration = ridingOrDragged ? (velocity - previous) * CGFloat(1 / max(dt, 0.001)) : .zero

        animator.mouth = mouthProvider?()
        updateLook()
        view.pose = animator.update(now: now, dt: dt)
        positionWindow()
        updateMousePassthrough()

        let body = view.pose.body
        let head = CGRect(x: anchor.x + (body.x - 60) * scale, y: anchor.y + (body.y - 50) * scale,
                          width: 120 * scale, height: 118 * scale)
        onFrameEnd?(head)

        if vanishing, animator.isDematerialized {
            vanishing = false
            visible = false
            window.orderOut(nil)
            view.stopDisplayLink()
        }
    }

    private func updateLook() {
        guard settings.followCursor else { animator.lookTarget = nil; return }
        let head = anchor + CGPoint(x: 0, y: (animator.lastPose.body.y + 10) * scale)
        let d = NSEvent.mouseLocation - head
        animator.lookTarget = d.length < 900 * scale ? CGPoint(x: d.x / (320 * scale), y: d.y / (320 * scale)).clamped(to: 1) : nil
    }

    private func positionWindow() {
        let origin = CGPoint(x: anchor.x - view.anchorInView.x, y: anchor.y - view.anchorInView.y)
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
    }

    private func updateMousePassthrough() {
        let m = NSEvent.mouseLocation
        let local = CGPoint(x: m.x - window.frame.minX, y: m.y - window.frame.minY)
        let over = drag != nil || (isVisible && view.isOnCharacter(local))
        if window.ignoresMouseEvents == over { window.ignoresMouseEvents = !over }
    }
}
