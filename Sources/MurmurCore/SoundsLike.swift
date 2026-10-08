import Foundation

/// Fixes near-misses of the user's vocabulary ("acupinol" → "Acupanel",
/// "Casero" → "Kasaro"). Distil-Whisper ignores prompts, so steering the model
/// doesn't work; correcting afterwards does.
///
/// A word (or two words run together, for "acu panel") is replaced when it has
/// the same consonant skeleton as a term *and* is spelled similarly once
/// sounds are normalised. Needing both keeps "kisser" from becoming "Kasaro".
public enum SoundsLike {
    public static func correct(_ text: String, terms: [String]) -> String {
        let usable = terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !usable.isEmpty, !text.isEmpty else { return text }

        var tokens = tokenize(text)
        for term in usable.sorted(by: { $0.count > $1.count }) {
            let termLetters = letters(term)
            guard !termLetters.isEmpty else { continue }
            let termWords = term.split(separator: " ").count
            var i = 0
            while i < tokens.count {
                if tokens[i].isWord {
                    // The term's own word count, plus one more for words split apart.
                    for span in [termWords + 1, termWords] {
                        guard let range = wordSpan(tokens, from: i, words: span) else { continue }
                        let candidate = tokens[range].filter(\.isWord).map(\.text).joined()
                        if matches(letters(candidate), termLetters) {
                            tokens.replaceSubrange(range, with: [Token(text: term, isWord: true)])
                            break
                        }
                    }
                }
                i += 1
            }
        }
        return tokens.map(\.text).joined()
    }

    // MARK: Matching

    static func matches(_ candidate: String, _ term: String) -> Bool {
        if candidate == term { return true }                      // same word, maybe different case
        guard term.count >= 4, candidate.count >= 3 else { return false }
        let ratio = Double(candidate.count) / Double(term.count)
        guard ratio > 0.6, ratio < 1.5 else { return false }
        let a = normalise(candidate), b = normalise(term)
        guard skeleton(a) == skeleton(b), skeleton(b).count >= 2 else { return false }
        let distance = levenshtein(Array(a), Array(b))
        return 1 - Double(distance) / Double(max(a.count, b.count)) >= 0.7
    }

    /// Lowercase letters and digits only.
    static func letters(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Spelling with sounds unified: c/q→k (soft c→s), ph→f, z→s, x→ks, doubled letters collapsed.
    static func normalise(_ s: String) -> String {
        let chars = Array(s)
        var out: [Character] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            switch c {
            case "p" where next == "h": out.append("f"); i += 1
            case "c" where next == "k": out.append("k"); i += 1
            case "c": out.append(next.map { "eiy".contains($0) } == true ? "s" : "k")
            case "q": out.append("k")
            case "z": out.append("s")
            case "x": out.append(contentsOf: ["k", "s"])
            default: out.append(c)
            }
            i += 1
        }
        var collapsed: [Character] = []
        for c in out where collapsed.last != c { collapsed.append(c) }
        return String(collapsed)
    }

    /// Consonants only.
    static func skeleton(_ normalised: String) -> String {
        var out: [Character] = []
        for c in normalised where !"aeiouyhw".contains(c) {
            if out.last != c { out.append(c) }
        }
        return String(out)
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    // MARK: Tokens

    struct Token { var text: String; var isWord: Bool }

    /// Splits into alternating word / non-word runs, keeping everything.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inWord = false
        for ch in text {
            let isWordChar = ch.isLetter || ch.isNumber || ch == "'"
            if current.isEmpty { inWord = isWordChar }
            if isWordChar != inWord {
                tokens.append(Token(text: current, isWord: inWord))
                current = ""
                inWord = isWordChar
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(Token(text: current, isWord: inWord)) }
        return tokens
    }

    /// Token indices covering `words` words starting at word token `start`, only
    /// bridging single spaces or hyphens. Returns a closed range of indices.
    static func wordSpan(_ tokens: [Token], from start: Int, words: Int) -> ClosedRange<Int>? {
        var count = 0
        var j = start
        while j < tokens.count {
            if tokens[j].isWord {
                count += 1
                if count == words { return start...j }
            } else if tokens[j].text != " " && tokens[j].text != "-" {
                return nil
            }
            j += 1
        }
        return nil
    }
}
