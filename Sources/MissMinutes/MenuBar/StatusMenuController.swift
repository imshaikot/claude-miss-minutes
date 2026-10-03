import AppKit
import MinutesCore

/// Model aliases offered in the menu bar and Settings (empty = Claude Code's own default).
enum ModelPresets {
    static let all: [(title: String, alias: String)] = [
        ("Claude Code default", ""),
        ("Fable", "fable"),
        ("Opus", "opus"),
        ("Sonnet", "sonnet"),
        ("Haiku", "haiku"),
    ]

    static func title(for alias: String) -> String {
        all.first { $0.alias.caseInsensitiveCompare(alias) == .orderedSame }?.title ?? alias
    }
}

/// The menu bar item: a tiny clock showing the real time, and a menu that is
/// rebuilt each time it opens so it always reflects the current state.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private unowned let app: AppDelegate
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var clockTimer: Timer?

    init(app: AppDelegate) {
        self.app = app
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.toolTip = "Miss Minutes"
        refreshIcon()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIcon() }
        }
    }

    private func refreshIcon() {
        item.button?.image = Self.clockIcon(date: Date())
    }

    /// A template clock face with hands at the current time.
    static func clockIcon(date: Date) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY - 0.5)
            NSColor.black.setStroke()
            let face = NSBezierPath(ovalIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14))
            face.lineWidth = 1.6
            face.stroke()
            let knob = NSBezierPath(roundedRect: CGRect(x: c.x - 1.6, y: c.y + 7.2, width: 3.2, height: 2), xRadius: 0.8, yRadius: 0.8)
            NSColor.black.setFill()
            knob.fill()
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            let minute = CGFloat(parts.minute ?? 0) / 60 * 2 * .pi
            let hour = (CGFloat((parts.hour ?? 0) % 12) + CGFloat(parts.minute ?? 0) / 60) / 12 * 2 * .pi
            for (angle, length, width) in [(hour, CGFloat(3.6), CGFloat(1.6)), (minute, CGFloat(5.2), CGFloat(1.2))] {
                let hand = NSBezierPath()
                hand.move(to: c)
                hand.line(to: CGPoint(x: c.x + sin(angle) * length, y: c.y + cos(angle) * length))
                hand.lineWidth = width
                hand.lineCapStyle = .round
                hand.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshIcon()
        menu.removeAllItems()
        let settings = app.store.settings
        let brain = app.brain!
        let director = app.director!

        let header = NSMenuItem(title: "Miss Minutes", action: nil, keyEquivalent: "")
        header.isEnabled = false
        let model = brain.model ?? (settings.brain.model.isEmpty ? "default model" : settings.brain.model)
        var subtitle = "Claude Code · \(model) · \(brain.status.label)"
        if brain.sessionCostUSD > 0 { subtitle += String(format: " · $%.2f this session", brain.sessionCostUSD) }
        header.attributedTitle = Self.header("Miss Minutes", subtitle: subtitle)
        menu.addItem(header)
        menu.addItem(.separator())

        let talk = add("Talk to Miss Minutes", #selector(talk), key: "m")
        talk.keyEquivalentModifierMask = [.control, .option]
        add("Stop Talking", #selector(stopTalking)).isEnabled = director.phase != .idle
        add("New Conversation", #selector(newConversation))
        menu.addItem(.separator())

        let brainMenu = NSMenu()
        for preset in ModelPresets.all {
            let entry = NSMenuItem(title: preset.title, action: #selector(chooseModel(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = preset.alias
            entry.state = settings.brain.model.caseInsensitiveCompare(preset.alias) == .orderedSame ? .on : .off
            brainMenu.addItem(entry)
        }
        if !ModelPresets.all.contains(where: { $0.alias.caseInsensitiveCompare(settings.brain.model) == .orderedSame }) {
            let custom = NSMenuItem(title: "Custom: \(settings.brain.model)", action: nil, keyEquivalent: "")
            custom.state = .on
            brainMenu.addItem(custom)
        }
        brainMenu.addItem(.separator())
        for access in ToolAccess.allCases {
            let entry = NSMenuItem(title: "Tools: \(access.title)", action: #selector(chooseTools(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = access.rawValue
            entry.state = settings.brain.tools == access ? .on : .off
            entry.toolTip = access.detail
            brainMenu.addItem(entry)
        }
        brainMenu.addItem(.separator())
        for effort in Effort.allCases {
            let entry = NSMenuItem(title: "Effort: \(effort.rawValue.capitalized)", action: #selector(chooseEffort(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = effort.rawValue
            entry.state = settings.brain.effort == effort ? .on : .off
            brainMenu.addItem(entry)
        }
        brainMenu.addItem(.separator())
        let restart = NSMenuItem(title: "Restart Brain", action: #selector(restartBrain), keyEquivalent: "")
        restart.target = self
        brainMenu.addItem(restart)
        let brainItem = NSMenuItem(title: "Brain: \(ModelPresets.title(for: settings.brain.model))", action: nil, keyEquivalent: "")
        brainItem.submenu = brainMenu
        menu.addItem(brainItem)
        menu.addItem(.separator())

        add(app.stage.isVisible ? "Hide Miss Minutes" : "Show Miss Minutes", #selector(toggleVisible))
        add("Come to Pointer", #selector(summonToPointer))
        toggle("Wander Around", settings.character.wander, #selector(toggleWander))
        toggle("Gravity", settings.character.gravity, #selector(toggleGravity))
        toggle("Voice", settings.voice.enabled, #selector(toggleVoice))
        toggle("Hold ⌃ to Talk", settings.listening.holdToTalk, #selector(toggleHoldToTalk))
        toggle("Hologram Effect", settings.character.hologram, #selector(toggleHologram))
        menu.addItem(.separator())
        add("Settings…", #selector(openSettings), key: ",")
        add("Quit Miss Minutes", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) {
        add(title, action).state = on ? .on : .off
    }

    private static func header(_ title: String, subtitle: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        text.append(NSAttributedString(string: subtitle, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        return text
    }

    // MARK: Actions

    @objc private func talk() { app.director.summon() }
    @objc private func stopTalking() { app.director.stopTalking() }
    @objc private func newConversation() { app.director.newConversation() }
    @objc private func restartBrain() { app.restartBrain(fresh: false) }
    @objc private func toggleVisible() { app.director.toggleVisibility() }
    @objc private func summonToPointer() { app.stage.move(to: .cursor, style: .auto) { _ in } }
    @objc private func openSettings() { app.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func chooseModel(_ sender: NSMenuItem) {
        app.store.settings.brain.model = sender.representedObject as? String ?? ""
    }

    @objc private func chooseTools(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let access = ToolAccess(rawValue: raw) { app.store.settings.brain.tools = access }
    }

    @objc private func chooseEffort(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let effort = Effort(rawValue: raw) { app.store.settings.brain.effort = effort }
    }

    @objc private func toggleWander() { app.store.settings.character.wander.toggle() }
    @objc private func toggleGravity() { app.store.settings.character.gravity.toggle() }
    @objc private func toggleVoice() { app.store.settings.voice.enabled.toggle() }
    @objc private func toggleHoldToTalk() { app.store.settings.listening.holdToTalk.toggle() }
    @objc private func toggleHologram() { app.store.settings.character.hologram.toggle() }
}
