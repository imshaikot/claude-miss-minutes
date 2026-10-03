import AppKit
import MinutesCharacter
import MinutesCore
import MinutesVoice

@main
enum MissMinutesMain {
    static func main() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--render-sheet"), index + 1 < args.count {
            exit(RenderCommands.sheet(to: args[index + 1]))
        }
        if let index = args.firstIndex(of: "--render-icon"), index + 1 < args.count {
            exit(RenderCommands.icon(to: args[index + 1]))
        }
        if let index = args.firstIndex(of: "--say"), index + 1 < args.count {
            MainActor.assumeIsolated { say(args[index + 1]) }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Developer mode: speak through the real voice engine and print the jaw
    /// curve, e.g. `MissMinutes --say "Hey there, sugar. Tick tock."`.
    @MainActor
    static func say(_ text: String) -> Never {
        let voice = SpeechEngine(settings: SettingsStore().settings.voice)
        var stream = SentenceStream()
        for sentence in stream.push(text) + stream.flush() { voice.speak(sentence) }
        var finished = false
        voice.onFinished = { finished = true }
        var samples: [String] = []
        let deadline = Date().addingTimeInterval(30)
        while !finished && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            if let m = voice.mouth() { samples.append(String(format: "%.2f", m.open)) }
        }
        print("jaw:", samples.joined(separator: " "))
        exit(finished ? 0 : 1)
    }
}
