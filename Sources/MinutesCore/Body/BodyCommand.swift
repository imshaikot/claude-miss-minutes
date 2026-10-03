import Foundation

public enum TravelStyle: String, Codable, CaseIterable {
    case auto, walk, crawl, hop, teleport
}

/// What the brain can ask her body to do. Decoded from the body bridge (the
/// Node MCP server forwards tool calls here); the tool schemas live in
/// `bridge/miss-minutes-mcp.mjs`.
public enum BodyCommand: Equatable {
    case emote(mood: Mood?, gesture: GestureName?)
    case moveTo(MoveTarget, style: TravelStyle)
    case lookAtScreen(screenshot: Bool)
    case setReminder(seconds: Double, message: String)

    public struct DecodeError: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    public static func decode(tool: String, args: [String: Any]) throws -> BodyCommand {
        func string(_ key: String) -> String? {
            (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        func number(_ key: String) -> Double? {
            if let d = args[key] as? Double { return d }
            if let i = args[key] as? Int { return Double(i) }
            if let s = args[key] as? String { return Double(s) }
            return nil
        }

        switch tool {
        case "emote":
            let mood = try string("mood").map { raw -> Mood in
                guard let m = Mood(rawValue: raw.lowercased()) else { throw DecodeError(description: "Unknown mood \"\(raw)\". Use one of: \(Mood.allCases.map(\.rawValue).joined(separator: ", "))") }
                return m
            }
            let gesture = try string("gesture").map { raw -> GestureName in
                guard let g = GestureName(rawValue: raw.lowercased()) else { throw DecodeError(description: "Unknown gesture \"\(raw)\". Use one of: \(GestureName.allCases.map(\.rawValue).joined(separator: ", "))") }
                return g
            }
            guard mood != nil || gesture != nil else { throw DecodeError(description: "Give a mood, a gesture, or both.") }
            return .emote(mood: mood, gesture: gesture)

        case "move_to":
            let style = TravelStyle(rawValue: string("style")?.lowercased() ?? "auto") ?? .auto
            switch string("target")?.lowercased() ?? "random" {
            case "app", "window":
                guard let app = string("app") else { throw DecodeError(description: "target \"app\" needs an \"app\" name.") }
                return .moveTo(.app(app), style: style)
            case "hang", "edge", "cling": return .moveTo(.hang(app: string("app")), style: style)
            case "floor", "dock", "bottom": return .moveTo(.floor, style: style)
            case "pointer", "cursor", "mouse": return .moveTo(.cursor, style: style)
            case "left": return .moveTo(.screenSide(left: true), style: style)
            case "right": return .moveTo(.screenSide(left: false), style: style)
            case "random", "anywhere": return .moveTo(.random, style: style)
            case let other: throw DecodeError(description: "Unknown target \"\(other)\". Use app, hang, floor, pointer, left, right or random.")
            }

        case "look_at_screen":
            return .lookAtScreen(screenshot: args["screenshot"] as? Bool ?? true)

        case "set_reminder":
            let seconds = (number("minutes").map { $0 * 60 } ?? 0) + (number("seconds") ?? 0)
            guard seconds >= 1, seconds <= 7 * 24 * 3600 else { throw DecodeError(description: "Give minutes and/or seconds between 1 second and 7 days.") }
            return .setReminder(seconds: seconds, message: string("message") ?? Lines.reminder)

        default:
            throw DecodeError(description: "Unknown body tool \"\(tool)\".")
        }
    }
}

public struct BodyReply: Equatable {
    public var text: String
    public var imageBase64: String?
    public var imageMIME: String?
    public var isError: Bool

    public init(text: String, imageBase64: String? = nil, imageMIME: String? = nil, isError: Bool = false) {
        self.text = text
        self.imageBase64 = imageBase64
        self.imageMIME = imageMIME
        self.isError = isError
    }

    public static func error(_ text: String) -> BodyReply { BodyReply(text: text, isError: true) }

    public func jsonLine() -> Data {
        var object: [String: Any] = ["ok": !isError, "text": text]
        if let imageBase64 { object["image"] = ["data": imageBase64, "mimeType": imageMIME ?? "image/jpeg"] }
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
