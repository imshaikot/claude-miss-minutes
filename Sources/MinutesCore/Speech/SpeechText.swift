import Foundation

/// Cuts streamed reply text into speakable sentences as soon as each one is
/// complete, so she starts talking while the brain is still writing.
public struct SentenceStream {
    private var buffer = ""
    private var inCodeFence = false
    private var announcedCode = false

    public init() {}

    /// Appends a text delta and returns any sentences that are now complete.
    public mutating func push(_ delta: String) -> [String] {
        buffer += delta
        return drain(final: false)
    }

    /// Returns whatever is left at the end of a turn.
    public mutating func flush() -> [String] {
        let out = drain(final: true)
        buffer = ""
        inCodeFence = false
        announcedCode = false
        return out
    }

    private mutating func drain(final: Bool) -> [String] {
        var sentences: [String] = []
        while true {
            // Code fences are shown in the bubble, never read aloud.
            if inCodeFence {
                guard let close = buffer.range(of: "```") else {
                    if final { buffer = "" }
                    break
                }
                buffer = String(buffer[close.upperBound...])
                inCodeFence = false
                continue
            }
            let fence = buffer.range(of: "```")
            let boundary = sentenceBoundary(in: buffer, final: final)
            if let fence, boundary.map({ fence.lowerBound < $0 }) ?? true {
                let before = String(buffer[..<fence.lowerBound])
                sentences += speakableParts(before)
                if !announcedCode {
                    sentences.append("I've put the details in my bubble.")
                    announcedCode = true
                }
                buffer = String(buffer[fence.upperBound...])
                inCodeFence = true
                continue
            }
            guard let end = boundary else { break }
            let sentence = String(buffer[..<end])
            buffer = String(buffer[end...])
            sentences += speakableParts(sentence)
        }
        if final, !buffer.isEmpty {
            sentences += speakableParts(buffer)
            buffer = ""
        }
        return sentences
    }

    private func speakableParts(_ raw: String) -> [String] {
        let s = SpeechText.speakable(raw)
        return s.isEmpty ? [] : [s]
    }

    /// Index just past the first sentence end: terminal punctuation followed by
    /// whitespace, or a newline. Ignores decimals like "3.5".
    private func sentenceBoundary(in text: String, final: Bool) -> String.Index? {
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "\n" { return text.index(after: i) }
            if ".!?…".contains(ch) {
                var j = text.index(after: i)
                while j < text.endIndex, ".!?…\"')”’".contains(text[j]) { j = text.index(after: j) }
                if j == text.endIndex { return final ? j : nil }
                if text[j].isWhitespace { return j }
            }
            i = text.index(after: i)
        }
        return nil
    }
}

public enum SpeechText {
    /// Strips Markdown and other things a voice should not read.
    public static func speakable(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"https?://\S+"#, with: "a link", options: .regularExpression)
        s = s.replacingOccurrences(of: #"`([^`]*)`"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s{0,3}(#{1,6}|[-*+]|\d+\.|>)\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\*\*|__|\*|_|~~)"#, with: "", options: .regularExpression)
        s = String(s.unicodeScalars.filter { !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000)) })
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
