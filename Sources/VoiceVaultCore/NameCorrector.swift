import Foundation

/// Fixes commonly mistranscribed names using the user's People dictionary.
///
/// Philosophy: a missed correction is cheap (the user sees the transcript in
/// review), but a wrong correction corrupts a verbatim record. So fuzzy
/// matching is deliberately conservative, and every fix is reported so the
/// UI and frontmatter can show exactly what changed.
///
/// Three kinds of match, strictest first:
///  1. Alias, exact (case-insensitive): the user has explicitly said
///     "Soren means Suren" — always corrected.
///  2. Phonetic: same Metaphone key AND small edit distance.
///  3. Near-phonetic: Metaphone keys within edit distance 1, same initial,
///     and a slightly looser surface edit distance (catches
///     Sasnowski → Sosnovsky, where w/v shifts the key).
/// Fuzzy matches (2 and 3) never fire on common English words, so
/// "is a" can never become "Isa".
public struct NameCorrector: Sendable {
    public let people: [PersonName]

    public init(people: [PersonName]) {
        self.people = people
    }

    public struct Result: Sendable {
        public let text: String
        public let corrections: [NameCorrection]
    }

    public func correct(_ text: String) -> Result {
        guard !people.isEmpty, !text.isEmpty else {
            return Result(text: text, corrections: [])
        }

        let tokens = Self.wordTokens(in: text)
        guard !tokens.isEmpty else { return Result(text: text, corrections: []) }

        struct Replacement {
            let range: Range<String.Index>
            let original: String
            let canonical: String
        }
        var replacements: [Replacement] = []
        var claimed: [Range<String.Index>] = []

        func overlapsClaimed(_ range: Range<String.Index>) -> Bool {
            claimed.contains { $0.overlaps(range) }
        }

        for person in people {
            let canonical = person.name.trimmingCharacters(in: .whitespaces)
            guard !canonical.isEmpty else { continue }
            let canonicalTokens = canonical.split(separator: " ").map(String.init)
            let aliasSet = Set(person.aliases.map { $0.lowercased() })

            // Slide a window of the canonical name's word count over the text.
            let k = canonicalTokens.count
            guard k >= 1, tokens.count >= 1 else { continue }

            // Single-token aliases can also stand in for multi-token names
            // ("Isa" for "Isabel Matos"), so check 1-grams for aliases too.
            var windowSizes = Set([k, 1])
            for alias in person.aliases {
                windowSizes.insert(alias.split(separator: " ").count)
            }

            for size in windowSizes.sorted(by: >) {
                guard tokens.count >= size else { continue }
                for start in 0...(tokens.count - size) {
                    let window = Array(tokens[start..<(start + size)])
                    let surface = window.map(\.text).joined(separator: " ")
                    let range = window.first!.range.lowerBound..<window.last!.range.upperBound
                    if overlapsClaimed(range) { continue }
                    let lower = surface.lowercased()

                    var matched = false
                    if aliasSet.contains(lower), surface != canonical {
                        // Explicit aliases always win, even over the
                        // case-only skip below — the user asked for this.
                        matched = true
                    } else if lower == canonical.lowercased() {
                        // Already spelled canonically (or differs only in
                        // case, which verbatim transcripts keep).
                        continue
                    } else if size == k {
                        matched = zip(window.map(\.text), canonicalTokens).allSatisfy { token, target in
                            Self.fuzzyTokenMatch(token, target)
                        }
                        // Require at least one token to actually differ in
                        // more than case; pure case differences stay verbatim.
                        if matched {
                            matched = zip(window.map(\.text), canonicalTokens)
                                .contains { $0.lowercased() != $1.lowercased() }
                        }
                    }

                    if matched {
                        replacements.append(Replacement(range: range, original: surface, canonical: canonical))
                        claimed.append(range)
                    }
                }
            }
        }

        guard !replacements.isEmpty else { return Result(text: text, corrections: []) }

        var corrected = text
        var tally: [String: NameCorrection] = [:]
        for rep in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            corrected.replaceSubrange(rep.range, with: rep.canonical)
            let key = "\(rep.original)→\(rep.canonical)"
            if var existing = tally[key] {
                existing.count += 1
                tally[key] = existing
            } else {
                tally[key] = NameCorrection(from: rep.original, to: rep.canonical)
            }
        }
        let corrections = tally.values.sorted { $0.from < $1.from }
        return Result(text: corrected, corrections: corrections)
    }

    // MARK: - Matching

    /// True when `token` plausibly *is* `target` misheard.
    static func fuzzyTokenMatch(_ token: String, _ target: String) -> Bool {
        let t = token.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let p = target.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        if t == p { return true }
        if t.count < 2 || CommonWords.contains(t) { return false }
        // Contractions ("I'm", "that's") are never mishearings of a name.
        // Only fuzzy-match an apostrophe if the name itself has one (O'Brien).
        if t.contains("'") != p.contains("'") { return false }
        guard t.first == p.first else { return false }

        let surfaceDistance = damerauLevenshtein(t, p)
        let mt = metaphone(t)
        let mp = metaphone(p)

        if mt == mp, surfaceDistance <= max(1, p.count / 3) { return true }
        // Near-phonetic: keys within one edit. This looser rule exists for
        // consonant shifts inside long names (Sasnowski/Sosnovsky,
        // SSNSK/SSNFSK) and is too dangerous for short ones — one key edit
        // in a 3-letter name is a different word ("Ida" is not "Isa").
        // A token key that merely *extends* the target's ("sirens" SRNS vs
        // Suren SRN) is likewise a different word or plural, not a mishearing.
        if p.count >= 6,
           damerauLevenshtein(mt, mp) <= 1,
           !(mt.hasPrefix(mp) && mt.count > mp.count),
           surfaceDistance <= max(2, p.count / 3) { return true }
        return false
    }

    // MARK: - Tokenization

    struct Token {
        let text: String
        let range: Range<String.Index>
    }

    /// Word tokens (letters and apostrophes) with their ranges in the original.
    static func wordTokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch.isLetter {
                var end = text.index(after: index)
                while end < text.endIndex, text[end].isLetter || text[end] == "'" || text[end] == "\u{2019}" {
                    end = text.index(after: end)
                }
                // Trim trailing apostrophes so "Soren's" tokenizes as "Soren" + "'s"? No —
                // keep possessives out of the token: split at apostrophe-s endings.
                var token = String(text[index..<end])
                var realEnd = end
                for suffix in ["'s", "\u{2019}s"] where token.lowercased().hasSuffix(suffix) {
                    token = String(token.dropLast(2))
                    realEnd = text.index(end, offsetBy: -2)
                }
                if !token.isEmpty {
                    tokens.append(Token(text: token, range: index..<realEnd))
                }
                index = end
            } else {
                index = text.index(after: index)
            }
        }
        return tokens
    }

    // MARK: - Phonetics

    /// Simplified Metaphone: collapses a word to a consonant skeleton so
    /// spellings that sound alike compare equal (Soren/Suren → SRN).
    static func metaphone(_ word: String) -> String {
        let letters = word.lowercased().unicodeScalars.filter { CharacterSet.lowercaseLetters.contains($0) }
        var chars = letters.map { Character($0) }
        guard !chars.isEmpty else { return "" }

        // Initial-letter exceptions.
        if chars.count >= 2 {
            let two = String(chars[0...1])
            if ["kn", "gn", "pn", "wr", "ae"].contains(two) { chars.removeFirst() }
            else if two == "wh" { chars[1] = chars[0]; chars.removeFirst() }
            else if chars[0] == "x" { chars[0] = "s" }
        }

        var out = ""
        let vowels: Set<Character> = ["a", "e", "i", "o", "u"]
        var i = 0
        var previousEmitted: Character? = nil

        func emit(_ c: Character) {
            if previousEmitted != c { out.append(c); previousEmitted = c }
        }

        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            switch c {
            case "a", "e", "i", "o", "u":
                if i == 0 { emit("A") }
            case "b":
                emit("B")
            case "c":
                if let n = next, ["i", "e", "y"].contains(n) { emit("S") }
                else if next == "h" { emit("X"); i += 1 }
                else { emit("K") }
            case "d":
                emit("T")
            case "f":
                emit("F")
            case "g":
                if next == "h" { emit("K"); i += 1 }
                else if let n = next, ["i", "e", "y"].contains(n) { emit("J") }
                else { emit("K") }
            case "h":
                break
            case "j":
                emit("J")
            case "k":
                if previousEmitted == "K", chars.indices.contains(i - 1), chars[i - 1] == "c" { break }
                emit("K")
            case "l":
                emit("L")
            case "m":
                emit("M")
            case "n":
                emit("N")
            case "p":
                if next == "h" { emit("F"); i += 1 } else { emit("P")}
            case "q":
                emit("K")
            case "r":
                emit("R")
            case "s":
                if next == "h" { emit("X"); i += 1 } else { emit("S") }
            case "t":
                if next == "h" { emit("0"); i += 1 } else { emit("T") }
            case "v":
                emit("F")
            case "w":
                if let n = next, vowels.contains(n) { emit("W") }
            case "x":
                emit("K"); previousEmitted = nil; emit("S")
            case "y":
                if let n = next, vowels.contains(n) { emit("Y") }
            case "z":
                emit("S")
            default:
                break
            }
            i += 1
        }
        return out
    }

    // MARK: - Edit distance

    /// Damerau–Levenshtein (with transpositions).
    static func damerauLevenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var d = Array(repeating: Array(repeating: 0, count: t.count + 1), count: s.count + 1)
        for i in 0...s.count { d[i][0] = i }
        for j in 0...t.count { d[0][j] = j }
        for i in 1...s.count {
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                d[i][j] = Swift.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, s[i - 1] == t[j - 2], s[i - 2] == t[j - 1] {
                    d[i][j] = Swift.min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[s.count][t.count]
    }
}
