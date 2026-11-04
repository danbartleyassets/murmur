import Foundation

/// Removes non-speech annotations Whisper emits for music or noise,
/// e.g. "(upbeat music)", "[BLANK_AUDIO]", "♪ la la ♪".
public enum NonSpeech {
    public static func strip(_ text: String) -> String {
        var t = text
        let patterns = [
            "\\([^)]*(music|applause|laughter|laughs|noise|silence|inaudible|sigh|cough)[^)]*\\)",
            "\\[[^\\]]*(music|applause|laughter|laughs|noise|silence|blank_audio|inaudible|sigh|cough)[^\\]]*\\]",
            "♪[^♪]*♪", "♪+"
        ]
        for p in patterns {
            t = t.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        t = t.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Whisper's habit of inventing a sign-off when it hears near-silence.
public enum Hallucination {
    private static let phrases: Set<String> = [
        "thank you", "thank you very much", "thanks for watching", "thank you for watching",
        "thanks for listening", "thank you for listening", "bye", "you", "so", "okay",
        "please subscribe", "subtitles by the amara.org community"
    ]

    /// True when `text` is one of the stock phrases and there was barely any voice.
    public static func isLikely(_ text: String, voicedSeconds: Double) -> Bool {
        guard voicedSeconds < 0.4 else { return false }
        let normalized = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
        return normalized.isEmpty || phrases.contains(normalized)
    }
}

/// Spoken commands that control dictation instead of being typed.
public enum Commands {
    private static let abortPhrases: Set<String> = [
        "scratch that", "cancel that", "never mind", "nevermind", "delete that", "cancel"
    ]

    /// The whole utterance was "scratch that" or similar.
    public static func isAbort(_ text: String) -> Bool {
        let normalized = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,"))
        return abortPhrases.contains(normalized)
    }

    /// "new line" and "new paragraph" become line breaks.
    public static func applyInline(_ text: String) -> String {
        var out = text
        let map: [(String, String)] = [
            ("\\s*\\bnew paragraph\\b[,.]?", "\n\n"),
            ("\\s*\\bnew line\\b[,.]?", "\n")
        ]
        for (pattern, replacement) in map {
            out = out.replacingOccurrences(of: pattern, with: replacement,
                                           options: [.regularExpression, .caseInsensitive])
        }
        out = out.replacingOccurrences(of: " *\n *", with: "\n", options: .regularExpression)
        // Capitalise the first letter after a break ("new line thanks" -> "\nThanks").
        var result = ""
        var capitaliseNext = false
        for ch in out {
            if ch == "\n" { capitaliseNext = true; result.append(ch); continue }
            if capitaliseNext, ch.isLetter {
                result.append(contentsOf: ch.uppercased())
                capitaliseNext = false
            } else {
                result.append(ch)
                if !ch.isWhitespace { capitaliseNext = false }
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

/// User-defined "misheard → correct" rules, matched whole-word and case-insensitive.
public enum Replacements {
    public static func apply(_ rules: [String: String], to text: String) -> String {
        var out = text
        // Longest first so "acu panel" wins over "acu".
        for (wrong, right) in rules.sorted(by: { $0.key.count > $1.key.count }) where !wrong.isEmpty {
            let pattern = "(?<![\\w])" + NSRegularExpression.escapedPattern(for: wrong) + "(?![\\w])"
            out = out.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: right),
                                           options: [.regularExpression, .caseInsensitive])
        }
        return out
    }
}

/// Decides whether a dictation needs a leading space, given the character just
/// before the cursor. `previous == nil` means unknown, so nothing is added.
public enum Spacing {
    public static func join(previous: Character?, text: String) -> String {
        guard let previous, let first = text.first else { return text }
        if previous.isWhitespace || previous.isNewline { return text }
        if "([{\"'“‘/-".contains(previous) { return text }
        if ".,;:!?)]}…".contains(first) { return text }
        return " " + text
    }
}

/// Message mode's first pass: the spoken tics that are never meant, removed by rule
/// before the language model tidies the rest. Also the fallback when Apple
/// Intelligence is off.
public enum Fillers {
    private static let rules: [(String, String)] = [
        ("(?i),?[ \\t]*\\b(um+|uh+|erm+|er|ah|hmm+|mm+)\\b[,.]?", ""),                      // vocal fillers
        ("(?i)\\b(\\w+(?:[ \\t]+\\w+){0,2})[ \\t]+\\1\\b", "$1"),                         // "the the", "can you can you"
        ("(?i)(^|[.!?]\\s+)(yeah|okay|ok|right|so|well),?[ \\t]+(so[ \\t]+|basically[ \\t]+)?", "$1"), // opening throat-clearing
        ("(?i),?[ \\t]*\\byou know\\b,?(?=[ \\t]*(?:[.!?,]|and\\b|but\\b|so\\b|or\\b|$))", ""),
        ("(?i)\\bbasically\\b,?[ \\t]*", ""),
        ("(?i),?[ \\t]*\\bI mean\\b,?", "")
    ]

    public static func strip(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for (pattern, template) in rules {
            t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        t = t.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[ \\t]+([,.!?])", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^[ \\t,]+", with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // Removing an opening "So" leaves the next sentence lower-case.
        let starts = try! NSRegularExpression(pattern: "(^|[.!?]\\s+)([a-z])")
        for match in starts.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
            if let r = Range(match.range(at: 2), in: t) { t.replaceSubrange(r, with: t[r].uppercased()) }
        }
        return t
    }
}
