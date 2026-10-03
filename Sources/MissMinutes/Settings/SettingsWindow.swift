import AppKit
import MinutesBrain
import MinutesCore
import MinutesVoice
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(app: AppDelegate) {
        let root = SettingsView(store: app.store, brainInfo: BrainInfo(app: app), kokoro: app.kokoro,
                                preview: { [weak app] text in app?.voice.speak(text) })
        window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Miss Minutes Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Live brain facts for the Settings window.
@MainActor
final class BrainInfo: ObservableObject {
    private weak var app: AppDelegate?
    @Published var status = ""
    @Published var command = ""
    @Published var claudePath = ""
    @Published var nodePath = ""
    @Published var bridge = ""
    private var timer: Timer?

    init(app: AppDelegate) {
        self.app = app
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard let app, let brain = app.brain else { return }
        let s = app.store.settings.brain
        status = brain.status.label
        command = brain.lastPlan?.displayCommand ?? "Not started yet."
        claudePath = ExecutableLocator.claude(override: s.claudePath) ?? "not found"
        nodePath = ExecutableLocator.node(override: s.nodePath) ?? "not found"
        bridge = app.bodyBridgeStatus
    }

    func restart() { app?.restartBrain(fresh: false) }
    func newConversation() { app?.restartBrain(fresh: true) }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var brainInfo: BrainInfo
    var kokoro: KokoroVoice
    var preview: (String) -> Void

    var body: some View {
        TabView {
            BrainTab(store: store, info: brainInfo).tabItem { Label("Brain", systemImage: "brain") }
            CharacterTab(store: store).tabItem { Label("Character", systemImage: "figure.wave") }
            VoiceTab(store: store, kokoro: kokoro, preview: preview).tabItem { Label("Voice", systemImage: "waveform") }
            GeneralTab(store: store).tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 600, height: 620)
        .padding(.top, 8)
    }
}

// MARK: - Brain

private struct BrainTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var info: BrainInfo
    @State private var customModel = ""

    private var isPreset: Bool {
        ModelPresets.all.contains { $0.alias.caseInsensitiveCompare(store.settings.brain.model) == .orderedSame }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack {
                        Text(info.status).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart") { info.restart() }
                        Button("New Conversation") { info.newConversation() }
                    }
                }
                Picker("Model", selection: Binding(
                    get: { isPreset ? store.settings.brain.model.lowercased() : "__custom" },
                    set: { store.settings.brain.model = $0 == "__custom" ? (customModel.isEmpty ? "claude-sonnet-5-5" : customModel) : $0 }
                )) {
                    ForEach(ModelPresets.all, id: \.alias) { Text($0.title).tag($0.alias) }
                    Text("Custom model id…").tag("__custom")
                }
                if !isPreset {
                    TextField("Model id", text: $store.settings.brain.model)
                        .onAppear { customModel = store.settings.brain.model }
                }
                Picker("Effort", selection: $store.settings.brain.effort) {
                    ForEach(Effort.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Tools", selection: $store.settings.brain.tools) {
                    ForEach(ToolAccess.allCases) { access in
                        VStack(alignment: .leading) {
                            Text(access.title)
                            Text(access.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(access)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: { Text("Claude Code") }

            Section {
                PathField(title: "claude", placeholder: "Auto: \(info.claudePath)", text: $store.settings.brain.claudePath, directory: false)
                PathField(title: "Working folder", placeholder: "Her own folder in Application Support", text: $store.settings.brain.workingDirectory, directory: true)
                PathField(title: "node (body bridge)", placeholder: "Auto: \(info.nodePath)", text: $store.settings.brain.nodePath, directory: false)
                Text(info.bridge).font(.caption).foregroundStyle(.secondary)
                Toggle("Use only her own tools (ignore my Claude Code MCP servers)", isOn: $store.settings.brain.isolateMCP)
                Toggle("Remember the conversation across launches", isOn: $store.settings.brain.rememberConversation)
                Toggle("Let her take screenshots when asked about the screen", isOn: $store.settings.brain.letHerSeeScreen)
                TextField("Extra arguments", text: $store.settings.brain.extraArguments, prompt: Text("e.g. --add-dir ~/Documents"))
            } header: { Text("Process") }

            Section {
                TextEditor(text: Binding(
                    get: { store.settings.brain.persona.isEmpty ? Persona.builtIn : store.settings.brain.persona },
                    set: { store.settings.brain.persona = $0 == Persona.builtIn ? "" : $0 }
                ))
                .font(.system(size: 11.5))
                .frame(height: 130)
                HStack {
                    Spacer()
                    Button("Reset to Built-in") { store.settings.brain.persona = "" }.disabled(store.settings.brain.persona.isEmpty)
                }
            } header: { Text("Persona (appended to Claude Code's system prompt)") }

            Section {
                Text(info.command).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
            } header: { Text("Command line") }
        }
        .formStyle(.grouped)
    }
}

private struct PathField: View {
    var title: String
    var placeholder: String
    @Binding var text: String
    var directory: Bool

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField("", text: $text, prompt: Text(placeholder))
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = directory
                    panel.canChooseFiles = !directory
                    panel.allowsMultipleSelection = false
                    panel.showsHiddenFiles = true
                    if panel.runModal() == .OK, let url = panel.url { text = url.path }
                }
            }
        }
    }
}

// MARK: - Character

private struct CharacterTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                LabeledContent("Size") {
                    Slider(value: $store.settings.character.scale, in: 0.6...1.6, step: 0.05) { EmptyView() }
                }
                Toggle("Hologram glow and flicker", isOn: $store.settings.character.hologram)
                Picker("Frame rate", selection: $store.settings.character.frameRate) {
                    Text("30 fps").tag(30); Text("60 fps").tag(60); Text("120 fps").tag(120)
                }
                .pickerStyle(.segmented)
                Toggle("Eyes follow the pointer", isOn: $store.settings.character.followCursor)
                Toggle("Little quips in her bubble", isOn: $store.settings.character.quips)
            } header: { Text("Look") }

            Section {
                Toggle("Wander, stroll and climb around on her own", isOn: $store.settings.character.wander)
                LabeledContent("Restlessness") {
                    Slider(value: $store.settings.character.restlessness, in: 0...1) { EmptyView() } minimumValueLabel: { Text("Calm") } maximumValueLabel: { Text("Busy") }
                }
                Toggle("Sit on top of windows", isOn: $store.settings.character.perchOnWindows)
                Toggle("Hang from and climb the edges of windows", isOn: $store.settings.character.hangOnEdges)
                Toggle("Stand on the Dock / bottom of the screen", isOn: $store.settings.character.perchOnFloor)
                Toggle("Gravity (off: she hovers wherever you drop her)", isOn: $store.settings.character.gravity)
                TextField("Hide while these apps are frontmost", text: Binding(
                    get: { store.settings.character.shyApps.joined(separator: ", ") },
                    set: { store.settings.character.shyApps = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                ), prompt: Text("e.g. zoom.us, Keynote"))
            } header: { Text("Behaviour") }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Voice

private struct VoiceTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var kokoro: KokoroVoice
    var preview: (String) -> Void
    private let voices = SpeechEngine.availableVoices()
    private let hasNaturalVoice = SpeechEngine.hasNaturalVoice

    var body: some View {
        Form {
            Section {
                Toggle("Speak replies aloud", isOn: $store.settings.voice.enabled)
                Picker("Voice engine", selection: $store.settings.voice.engine) {
                    Text("Kokoro: neural, runs on this Mac").tag(VoiceEngine.kokoro)
                    Text("macOS voices").tag(VoiceEngine.system)
                }
                LabeledContent("Volume") { Slider(value: $store.settings.voice.volume, in: 0...1) { EmptyView() } }
                HStack {
                    Spacer()
                    Button("Preview") { preview("Well hey there, sugar! This is how I sound. Right on time, as always.") }
                }
            } header: { Text("Voice") }

            if store.settings.voice.engine == .kokoro {
                Section {
                    KokoroStatus(kokoro: kokoro)
                    Picker("Voice", selection: $store.settings.voice.kokoroVoice) {
                        ForEach(KokoroVoices.all, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    LabeledContent("Speed") { Slider(value: $store.settings.voice.kokoroSpeed, in: 0.8...1.3) { EmptyView() } }
                } header: { Text("Kokoro") } footer: {
                    Text("Kokoro-82M is an open-source (Apache-2.0) text-to-speech model. The download comes from npm and Hugging Face; after that it runs offline and nothing you hear leaves this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Voice", selection: $store.settings.voice.voiceIdentifier) {
                    Text("Automatic (best installed)").tag("")
                    ForEach(voices) { v in Text("\(v.name) — \(v.language) · \(v.quality)").tag(v.id) }
                }
                LabeledContent("Speed") { Slider(value: $store.settings.voice.rate, in: 0.35...0.65) { EmptyView() } }
                LabeledContent("Pitch") { Slider(value: $store.settings.voice.pitch, in: 0.8...1.6) { EmptyView() } }
                if !hasNaturalVoice {
                    HStack(alignment: .top) {
                        Text("Only compact voices are installed, and they sound robotic. Download an Enhanced or Premium one (Ava or Zoe suit her) under Spoken Content ▸ System Voice ▸ Manage Voices.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension")!)
                        }
                    }
                }
            } header: {
                Text(store.settings.voice.engine == .kokoro ? "macOS voice (used until Kokoro is ready)" : "macOS voice")
            }
        }
        .formStyle(.grouped)
    }
}

/// Download, progress, and what to do when something went wrong.
private struct KokoroStatus: View {
    @ObservedObject var kokoro: KokoroVoice

    var body: some View {
        switch kokoro.state {
        case .notInstalled:
            row("Not downloaded yet: about 330 MB, once.", button: "Download") { kokoro.install() }
        case let .installing(fraction, step):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(step).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { kokoro.cancelInstall() }
                }
                if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
            }
        case .stopped:
            row("Downloaded. Starts when she next speaks.", button: "Remove") { kokoro.uninstall() }
        case .starting:
            HStack {
                ProgressView().controlSize(.small)
                Text("Warming up…").foregroundStyle(.secondary)
            }
        case .ready:
            row("Ready, running on this Mac.", button: "Remove") { kokoro.uninstall() }
        case let .failed(reason):
            VStack(alignment: .leading, spacing: 6) {
                Text(reason).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                HStack {
                    Spacer()
                    if kokoro.isInstalled { Button("Remove") { kokoro.uninstall() } }
                    Button("Try Again") { kokoro.retry() }
                }
            }
        }
    }

    private func row(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        LabeledContent("Status") {
            HStack {
                Text(text).foregroundStyle(.secondary)
                Spacer()
                Button(button, action: action)
            }
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var store: SettingsStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Talk to her", value: "Hold ⌃ and speak, let go to send")
                LabeledContent("Type to her", value: "⌃⌥M (anywhere)")
                Toggle("Hold ⌃ Control to talk", isOn: $store.settings.listening.holdToTalk)
                Toggle("Listen for yes or no after she asks permission", isOn: $store.settings.listening.handsFreeAnswers)
                LabeledContent("Click her", value: "Opens her speech bubble")
                LabeledContent("Drag her", value: "Pick her up and drop her anywhere")
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            } header: { Text("General") }
            Section {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
                LabeledContent("Version", value: version)
                Text("A desktop assistant in the style of a 1950s cartoon clock, with Claude Code as her brain. An unofficial fan homage, not affiliated with Marvel or Disney.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Reset All Settings") { store.reset() }
                }
            } header: { Text("About") }
        }
        .formStyle(.grouped)
    }
}
