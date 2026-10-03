import Foundation

/// Reads a spoken answer to a permission question ("Mind if I run a command?").
///
/// The whole utterance has to be the answer: yes phrases ("yeah, go ahead"),
/// or no phrases ("no, don't"), with fillers and pleasantries around them.
/// Anything else is nil: a sentence that merely contains "yes", a mix of both
/// ("no, wait, yes"), a qualified "yes, but only…". A misheard yes lets Claude
/// Code run something, so when in doubt she asks again rather than guess.
public enum YesNo {
    static let yes = [
        "yes", "yeah", "yea", "yep", "yup", "ya", "yah", "aye", "uh huh", "mhm", "mm hmm", "mmhmm",
        "sure", "sure thing", "ok", "okay", "o k", "alright", "all right", "fine", "that's fine", "that's ok", "that's okay",
        "go", "go ahead", "go on", "go for it", "do it", "do that", "run it", "proceed", "continue", "carry on",
        "allow", "allow it", "allowed", "approve", "approved", "granted", "permission granted",
        "of course", "absolutely", "definitely", "certainly", "affirmative", "by all means", "please do",
        "sounds good", "no problem", "no worries", "why not", "you may", "you can",
    ]

    static let no = [
        "no", "nope", "nah", "nay", "no way", "no thanks", "negative", "never", "never mind", "nevermind",
        "don't", "do not", "don't do it", "don't do that", "do not do it", "do not do that", "don't run it", "do not run it",
        "deny", "denied", "decline", "refuse", "stop", "cancel", "abort", "skip it", "leave it", "forget it",
        "not now", "not yet", "not right now", "not today", "absolutely not", "definitely not", "certainly not", "of course not",
        "i don't think so", "i'd rather not", "rather not", "better not", "wait", "hold on", "hang on",
    ]

    static let filler = [
        "uh", "um", "er", "erm", "ah", "oh", "hm", "hmm", "well", "so", "and", "then", "just", "i said", "i mean",
        "please", "thanks", "thank you", "sugar", "hon", "honey", "miss minutes", "minutes", "ma'am",
    ]

    private enum Meaning { case yes, no, filler }

    private static let lexicon: [String: Meaning] = {
        var lexicon: [String: Meaning] = [:]
        for phrase in filler { lexicon[phrase] = .filler }
        for phrase in yes { lexicon[phrase] = .yes }
        for phrase in no { lexicon[phrase] = .no }
        return lexicon
    }()

    private static let longestPhrase = lexicon.keys.map { $0.split(separator: " ").count }.max() ?? 1

    /// True for yes, false for no, nil when it isn't a clear answer.
    public static func parse(_ transcript: String) -> Bool? {
        let words = words(transcript)
        var answer: Bool?
        var i = 0
        while i < words.count {
            // Longest phrase first, so "no problem" is a yes and "of course not" a no.
            let match = (1...min(longestPhrase, words.count - i)).reversed().lazy
                .compactMap { n in lexicon[words[i..<i + n].joined(separator: " ")].map { (n, $0) } }
                .first
            guard let (length, meaning) = match else { return nil }
            i += length
            guard meaning != .filler else { continue }
            let allow = meaning == .yes
            if let answer, answer != allow { return nil }
            answer = allow
        }
        return answer
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0 == "'") }
            .map(String.init)
    }
}
