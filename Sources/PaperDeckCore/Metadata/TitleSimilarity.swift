import Foundation

/// Fuzzy title comparison used to accept a Crossref bibliographic-search hit
/// for a paper without identifiers. Titles are compared after normalization
/// (compatibility forms, case, diacritics, Greek letters spelled out, markup and
/// punctuation dropped), then scored as an even blend of token Jaccard (catches
/// a different word even in a long title) and Levenshtein over the space-free
/// string (tolerates split/glued words). Jaccard counts a long word one or two
/// edits away as matching, so a dropped ligature ("classication") or a typo
/// doesn't sink an otherwise identical title.
package enum TitleSimilarity {
    /// A search hit is accepted at or above this score (DESIGN §6.1).
    package static let acceptThreshold = 0.92

    /// Longer inputs are truncated; real titles are ≤ 300 characters.
    private static let maxScalars = 400

    package static func score(_ a: String, _ b: String) -> Double {
        let na = normalize(a), nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return 0 }
        if na == nb { return 1 }
        let wa = na.split(separator: " ").map(String.init), wb = nb.split(separator: " ").map(String.init)
        let ta = Set(rejoinSplits(wa, against: Set(wb))), tb = Set(rejoinSplits(wb, against: Set(wa)))
        let jaccard = softJaccard(ta, tb)
        let ca = Array(na.unicodeScalars.filter { $0 != " " }.prefix(maxScalars))
        let cb = Array(nb.unicodeScalars.filter { $0 != " " }.prefix(maxScalars))
        let longest = max(ca.count, cb.count)
        let edit = longest == 0 ? 1 : 1 - Double(levenshtein(ca, cb)) / Double(longest)
        return 0.5 * jaccard + 0.5 * edit
    }

    package static func matches(_ a: String, _ b: String, threshold: Double = acceptThreshold) -> Bool {
        score(a, b) >= threshold
    }

    /// Lowercase ASCII-ish words separated by single spaces ("β-Catenin <i>in vivo</i>" → "beta catenin in vivo").
    package static func normalize(_ s: String) -> String {
        let text = String(MetadataClients.stripMarkup(s).precomposedStringWithCompatibilityMapping
            .unicodeScalars.prefix(maxScalars * 2).map(Character.init))
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        var spelled = ""
        spelled.reserveCapacity(folded.count)
        for ch in folded {
            if let name = greek[ch] { spelled += " \(name) " } else { spelled.append(ch) }
        }
        var out = ""
        out.reserveCapacity(spelled.count)
        var pendingSpace = false
        for scalar in spelled.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    /// Exact token matches, plus one-to-one near matches between long words (≥ 5 letters,
    /// ≥ 0.8 edit similarity). "mouse"/"human" or "twelve"/"fifteen" stay different.
    private static func softJaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let exact = a.intersection(b)
        var leftoverB = Array(b.subtracting(exact).filter { $0.count >= 5 })
        var matched = exact.count
        for word in a.subtracting(exact) where word.count >= 5 && !leftoverB.isEmpty {
            let w = Array(word.unicodeScalars)
            if let i = leftoverB.firstIndex(where: { other in
                let o = Array(other.unicodeScalars)
                return 1 - Double(levenshtein(w, o)) / Double(max(w.count, o.count)) >= 0.8
            }) {
                leftoverB.remove(at: i)
                matched += 1
            }
        }
        return Double(matched) / Double(a.count + b.count - matched)
    }

    /// PDF text often splits or glues words ("repre sentation"); merge adjacent tokens whose
    /// concatenation is a word of the other title so one extraction artifact doesn't cost two tokens.
    private static func rejoinSplits(_ words: [String], against other: Set<String>) -> [String] {
        var out: [String] = []
        out.reserveCapacity(words.count)
        var i = 0
        while i < words.count {
            var token = words[i]
            var j = i + 1
            while !other.contains(token), j < words.count, j - i < 4 {
                let joined = token + words[j]
                guard other.contains(joined) || other.contains(where: { $0.hasPrefix(joined) }) else { break }
                token = joined
                j += 1
            }
            if other.contains(token) {
                out.append(token)
                i = j
            } else {
                out.append(words[i])
                i += 1
            }
        }
        return out
    }

    private static let greek: [Character: String] = {
        let names = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa",
                     "lambda", "mu", "nu", "xi", "omicron", "pi", "rho", "sigma", "tau", "upsilon", "phi",
                     "chi", "psi", "omega"]
        let lower = Array("αβγδεζηθικλμνξοπρστυφχψω")
        let upper = Array("ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ")
        var map: [Character: String] = ["ς": "sigma", "µ": "mu", "ϑ": "theta", "ϕ": "phi", "ϵ": "epsilon"]
        for (i, name) in names.enumerated() {
            map[lower[i]] = name
            map[upper[i]] = name
        }
        return map
    }()

    private static func levenshtein(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
