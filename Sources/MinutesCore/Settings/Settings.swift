import Combine
import Foundation

/// What the brain may do on its own. Each level is a declarative bundle of CLI
/// flags (see `ClaudeLaunchPlanner`).
public enum ToolAccess: String, Codable, CaseIterable, Identifiable {
    /// No built-in tools: she can only talk and use her body.
    case conversation
    /// Read files, search, browse the web; nothing that changes anything.
    case lookOnly
    /// Every Claude Code tool; anything not already allowed is asked in her bubble.
    case askFirst

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .conversation: return "Conversation only"
        case .lookOnly: return "Look & search"
        case .askFirst: return "Full tools, ask first"
        }
    }

    public var detail: String {
        switch self {
        case .conversation: return "No file, shell or web tools. Just chat and her body."
        case .lookOnly: return "Read files, search and browse the web. Nothing that changes anything."
        case .askFirst: return "Every Claude Code tool. Anything not already allowed asks you in her bubble first."
        }
    }
}

public enum Effort: String, Codable, CaseIterable, Identifiable {
    case auto, low, medium, high
    public var id: String { rawValue }
}

public struct BrainSettings: Codable, Equatable {
    /// Empty means auto-detect.
    public var claudePath = ""
    public var nodePath = ""
    /// An alias (`sonnet`, `opus`, `haiku`, `fable`), a full model id, or empty for the CLI default.
    public var model = "sonnet"
    public var effort = Effort.low
    public var tools = ToolAccess.lookOnly
    /// Empty means her own folder in Application Support (keeps Claude Code out of your home folder).
    public var workingDirectory = ""
    /// Load only her own MCP server, not the user's Claude Code MCP servers.
    public var isolateMCP = true
    public var rememberConversation = true
    public var letHerSeeScreen = true
    public var extraArguments = ""
    /// Empty means the built-in persona.
    public var persona = ""

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        claudePath = c.value(.claudePath, d.claudePath)
        nodePath = c.value(.nodePath, d.nodePath)
        model = c.value(.model, d.model)
        effort = c.value(.effort, d.effort)
        tools = c.value(.tools, d.tools)
        workingDirectory = c.value(.workingDirectory, d.workingDirectory)
        isolateMCP = c.value(.isolateMCP, d.isolateMCP)
        rememberConversation = c.value(.rememberConversation, d.rememberConversation)
        letHerSeeScreen = c.value(.letHerSeeScreen, d.letHerSeeScreen)
        extraArguments = c.value(.extraArguments, d.extraArguments)
        persona = c.value(.persona, d.persona)
    }
}

public struct CharacterSettings: Codable, Equatable {
    public var scale = 1.0
    public var hologram = true
    public var frameRate = 60
    public var wander = true
    /// 0 = stays put for minutes, 1 = moves about every half minute.
    public var restlessness = 0.5
    public var perchOnWindows = true
    public var perchOnFloor = true
    /// Off: she hovers wherever she is dropped or sent, like a hologram, instead of falling to a ledge.
    public var gravity = true
    public var followCursor = true
    /// Short reactions in the bubble (after a fall, when poked).
    public var quips = true
    /// She hides while one of these apps is frontmost (screen sharing, presenting).
    public var shyApps: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        scale = c.value(.scale, d.scale)
        hologram = c.value(.hologram, d.hologram)
        frameRate = c.value(.frameRate, d.frameRate)
        wander = c.value(.wander, d.wander)
        restlessness = c.value(.restlessness, d.restlessness)
        perchOnWindows = c.value(.perchOnWindows, d.perchOnWindows)
        perchOnFloor = c.value(.perchOnFloor, d.perchOnFloor)
        gravity = c.value(.gravity, d.gravity)
        followCursor = c.value(.followCursor, d.followCursor)
        quips = c.value(.quips, d.quips)
        shyApps = c.value(.shyApps, d.shyApps)
    }

    /// Seconds between wanders for the current restlessness.
    public var wanderInterval: ClosedRange<Double> {
        let base = 180 - 150 * clamp(restlessness, 0, 1)
        return base * 0.7...base * 1.3
    }
}

public struct VoiceSettings: Codable, Equatable {
    public var enabled = true
    /// Empty means the best installed English voice.
    public var voiceIdentifier = ""
    public var rate = 0.53
    public var pitch = 1.18
    public var volume = 0.9

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        enabled = c.value(.enabled, d.enabled)
        voiceIdentifier = c.value(.voiceIdentifier, d.voiceIdentifier)
        rate = c.value(.rate, d.rate)
        pitch = c.value(.pitch, d.pitch)
        volume = c.value(.volume, d.volume)
    }
}

public struct MinutesSettings: Codable, Equatable {
    public var brain = BrainSettings()
    public var character = CharacterSettings()
    public var voice = VoiceSettings()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        brain = c.value(.brain, BrainSettings())
        character = c.value(.character, CharacterSettings())
        voice = c.value(.voice, VoiceSettings())
    }
}

extension KeyedDecodingContainer {
    /// Decodes a key, falling back to a default when it is missing or malformed,
    /// so settings saved by older versions always load.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

/// Persists settings as one JSON blob in user defaults and publishes changes.
public final class SettingsStore: ObservableObject {
    @Published public var settings: MinutesSettings {
        didSet { if settings != oldValue { save() } }
    }

    private let defaults: UserDefaults
    private let key = "settings.v1"
    private let sessionKey = "brain.lastSessionID"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode(MinutesSettings.self, from: data) {
            settings = decoded
        } else {
            settings = MinutesSettings()
        }
    }

    public var lastSessionID: String? {
        get { defaults.string(forKey: sessionKey) }
        set { defaults.set(newValue, forKey: sessionKey) }
    }

    public func reset() { settings = MinutesSettings() }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
    }
}
