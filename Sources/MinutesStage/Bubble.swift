import AppKit
import MinutesCore
import SwiftUI

/// State behind the speech bubble.
final class BubbleModel: ObservableObject {
    enum Mode: Equatable { case hidden, input, thinking, reply, permission, notice }
    enum Tail { case bottom, left, right }

    @Published var mode: Mode = .hidden
    @Published var placeholder = ""
    @Published var input = ""
    @Published var status: String?
    @Published var reply = ""
    @Published var notice = ""
    @Published var actions: [String] = []
    @Published var permission: PermissionRequest?
    @Published var tail: Tail = .bottom

    var onSubmit: (String) -> Void = { _ in }
    var onPermission: (Bool) -> Void = { _ in }
    var onAction: (String) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onEscape: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
}

private enum BubbleStyle {
    static let paper = Color(red: 1.0, green: 0.965, blue: 0.89)
    static let ink = Color(red: 0.23, green: 0.10, blue: 0.03)
    static let rim = Color(red: 0.48, green: 0.23, blue: 0.06)
    static let accent = Color(red: 0.91, green: 0.45, blue: 0.11)
    static let muted = Color(red: 0.48, green: 0.36, blue: 0.27)
    static let width: CGFloat = 320
    static let tail: CGFloat = 12
    static let margin: CGFloat = 14
}

struct BubbleView: View {
    @ObservedObject var model: BubbleModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(width: BubbleStyle.width, alignment: .leading)
            .background(BubbleShape(tail: model.tail, tailSize: BubbleStyle.tail).fill(BubbleStyle.paper))
            .overlay(BubbleShape(tail: model.tail, tailSize: BubbleStyle.tail).stroke(BubbleStyle.rim, lineWidth: 2))
            .padding(tailPadding)
            .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
            .padding(BubbleStyle.margin)
            .onHover { model.onHover($0) }
            .onExitCommand { model.onEscape() }
            .environment(\.colorScheme, .light)
    }

    private var tailPadding: EdgeInsets {
        switch model.tail {
        case .bottom: return EdgeInsets(top: 0, leading: 0, bottom: BubbleStyle.tail, trailing: 0)
        case .left: return EdgeInsets(top: 0, leading: BubbleStyle.tail, bottom: 0, trailing: 0)
        case .right: return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: BubbleStyle.tail)
        }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch model.mode {
            case .hidden:
                EmptyView()
            case .input:
                inputField
                Text("Return to send · Esc to close").font(.system(size: 10)).foregroundStyle(BubbleStyle.muted)
            case .thinking:
                HStack(spacing: 8) {
                    ThinkingDots()
                    Text(model.status ?? "Thinking…").font(.system(size: 12, design: .rounded)).foregroundStyle(BubbleStyle.muted)
                }
            case .reply:
                replyText
                if let status = model.status { statusLine(status) }
            case .permission:
                permissionBody
            case .notice:
                Text(model.notice).font(.system(size: 13, design: .rounded)).foregroundStyle(BubbleStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.actions.isEmpty {
                    HStack { Spacer(); ForEach(model.actions, id: \.self) { action in pill(action, primary: action == model.actions.last) { model.onAction(action) } } }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(BubbleStyle.accent)
            Text("MISS MINUTES").font(.system(size: 10, weight: .heavy, design: .rounded)).tracking(1.2).foregroundStyle(BubbleStyle.rim)
            Spacer()
            Button { model.onClose() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(BubbleStyle.muted)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
    }

    private var inputField: some View {
        TextField(model.placeholder, text: $model.input, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 14, design: .rounded))
            .foregroundStyle(BubbleStyle.ink)
            .lineLimit(1...5)
            .focused($inputFocused)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(BubbleStyle.rim.opacity(0.4), lineWidth: 1))
            .onSubmit {
                let text = model.input
                model.input = ""
                model.onSubmit(text)
            }
            .onAppear { DispatchQueue.main.async { inputFocused = true } }
    }

    private var replyText: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(markdown(model.reply))
                    .font(.system(size: 13.5, design: .rounded))
                    .foregroundStyle(BubbleStyle.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .id("end")
            }
            .frame(maxHeight: 260)
            .onChange(of: model.reply) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private var permissionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("May I use \(model.permission?.tool ?? "this tool")?")
                .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(BubbleStyle.ink)
            Text(model.permission?.summary ?? "")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(BubbleStyle.ink)
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                pill("Deny", primary: false) { model.onPermission(false) }
                pill("Allow", primary: true) { model.onPermission(true) }
            }
        }
    }

    private func statusLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            ThinkingDots().scaleEffect(0.7)
            Text(text).font(.system(size: 11, design: .rounded)).foregroundStyle(BubbleStyle.muted).lineLimit(1)
        }
    }

    private func pill(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .foregroundStyle(primary ? Color.white : BubbleStyle.rim)
                .background(Capsule().fill(primary ? BubbleStyle.accent : BubbleStyle.paper))
                .overlay(Capsule().stroke(BubbleStyle.rim, lineWidth: primary ? 0 : 1.2))
        }
        .buttonStyle(.plain)
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// Three bouncing dots.
struct ThinkingDots: View {
    @State private var phase = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle().fill(Color(red: 0.91, green: 0.45, blue: 0.11)).frame(width: 6, height: 6)
                    .offset(y: phase ? -3 : 3)
                    .animation(.easeInOut(duration: 0.45).repeatForever().delay(Double(i) * 0.15), value: phase)
            }
        }
        .onAppear { phase = true }
    }
}

/// A rounded rectangle with a tail pointing at her.
struct BubbleShape: Shape {
    var tail: BubbleModel.Tail
    var tailSize: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: 16)
        var t = Path()
        switch tail {
        case .bottom:
            let x = rect.midX
            t.move(to: CGPoint(x: x - tailSize, y: rect.maxY - 1))
            t.addQuadCurve(to: CGPoint(x: x + 2, y: rect.maxY + tailSize), control: CGPoint(x: x - 2, y: rect.maxY + 4))
            t.addQuadCurve(to: CGPoint(x: x + tailSize, y: rect.maxY - 1), control: CGPoint(x: x + 4, y: rect.maxY + 2))
        case .left:
            let y = rect.midY
            t.move(to: CGPoint(x: rect.minX + 1, y: y - tailSize))
            t.addLine(to: CGPoint(x: rect.minX - tailSize, y: y))
            t.addLine(to: CGPoint(x: rect.minX + 1, y: y + tailSize))
        case .right:
            let y = rect.midY
            t.move(to: CGPoint(x: rect.maxX - 1, y: y - tailSize))
            t.addLine(to: CGPoint(x: rect.maxX + tailSize, y: y))
            t.addLine(to: CGPoint(x: rect.maxX - 1, y: y + tailSize))
        }
        path.addPath(t)
        return path
    }
}

/// A borderless panel that can take keyboard focus without activating the app,
/// so typing to her never steals focus from what you were doing.
final class BubblePanel: NSPanel {
    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 360, height: 120), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
public final class BubbleController: BubblePort {
    public var onEvent: ((BubbleEvent) -> Void)?

    private let model = BubbleModel()
    private let panel = BubblePanel()
    private let hosting: NSHostingView<BubbleView>
    private var headRect = CGRect.zero
    private var hideWork: DispatchWorkItem?
    private var hovering = false
    private var pendingHideDelay: TimeInterval?

    public init() {
        hosting = NSHostingView(rootView: BubbleView(model: model))
        panel.contentView = hosting
        model.onSubmit = { [weak self] text in self?.onEvent?(.submitted(text)) }
        model.onPermission = { [weak self] allow in self?.onEvent?(.permissionAnswered(allow: allow)) }
        model.onAction = { [weak self] action in self?.onEvent?(.action(action)) }
        model.onClose = { [weak self] in
            guard let self else { return }
            let wasInput = self.model.mode == .input
            self.hide(after: 0)
            self.onEvent?(wasInput ? .dismissed : .action("Close"))
        }
        model.onEscape = { [weak self] in
            guard let self else { return }
            if self.model.mode == .input || self.model.mode == .notice {
                self.hide(after: 0)
                self.onEvent?(.dismissed)
            } else {
                self.onEvent?(.interrupt)
            }
        }
        model.onHover = { [weak self] inside in
            guard let self else { return }
            self.hovering = inside
            if !inside, let delay = self.pendingHideDelay { self.hide(after: delay) }
        }
    }

    public var isOpen: Bool { model.mode != .hidden }

    public func showInput(placeholder: String) {
        model.placeholder = placeholder
        model.input = ""
        show(.input)
        panel.makeKeyAndOrderFront(nil)
    }

    public func showThinking(_ status: String) {
        model.status = status
        show(.thinking)
    }

    public func setStatus(_ status: String?) {
        model.status = status
        relayout()
    }

    public func setReply(_ text: String) {
        model.reply = text
        if model.mode != .reply { model.status = nil }
        show(.reply)
    }

    public func showPermission(_ request: PermissionRequest) {
        model.permission = request
        show(.permission)
    }

    public func showNotice(_ text: String, actions: [String], autoHide: TimeInterval?) {
        model.notice = text
        model.actions = actions
        show(.notice)
        if let autoHide { hide(after: autoHide) }
    }

    public func hide(after delay: TimeInterval) {
        hideWork?.cancel()
        pendingHideDelay = delay
        guard delay > 0 else {
            pendingHideDelay = nil
            model.mode = .hidden
            if panel.isKeyWindow { panel.resignKey() }
            panel.orderOut(nil)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.hovering else { return }
                self.hide(after: 0)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Called every frame by the stage with her head rect.
    public func follow(_ head: CGRect) {
        guard head.distance(to: headRect) > 0.5 else { return }
        headRect = head
        if isOpen { place() }
    }

    private func show(_ mode: BubbleModel.Mode) {
        hideWork?.cancel()
        pendingHideDelay = nil
        model.mode = mode
        relayout()
        panel.orderFrontRegardless()
    }

    private func relayout() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        if panel.frame.size != size { panel.setContentSize(size) }
        place()
    }

    /// Above her head when there is room, otherwise beside her.
    private func place() {
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: headRect.midX, y: headRect.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let m = BubbleStyle.margin
        var origin: CGPoint
        var tail: BubbleModel.Tail = .bottom
        if headRect.maxY + size.height - m <= visible.maxY {
            origin = CGPoint(x: headRect.midX - size.width / 2, y: headRect.maxY - m + 2)
        } else if headRect.minX - size.width + m >= visible.minX {
            tail = .right
            origin = CGPoint(x: headRect.minX - size.width + m - 2, y: headRect.midY - size.height / 2)
        } else {
            tail = .left
            origin = CGPoint(x: headRect.maxX - m + 2, y: headRect.midY - size.height / 2)
        }
        origin.x = clamp(origin.x, visible.minX - m, visible.maxX - size.width + m)
        origin.y = clamp(origin.y, visible.minY - m, visible.maxY - size.height + m)
        if model.tail != tail { model.tail = tail }
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
}

private extension CGRect {
    func distance(to other: CGRect) -> CGFloat {
        abs(minX - other.minX) + abs(minY - other.minY) + abs(width - other.width) + abs(height - other.height)
    }
}
