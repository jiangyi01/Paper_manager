import Foundation

/// The import's scan of removed papers' titles (D6) compares a new title with up to 500 tombstone
/// titles. `TitleSimilarity.score` costs a whole-title edit distance; this is a cheap upper bound
/// of that score, so only the few titles that could reach the threshold get the real score.
///
/// The score is ½·J + ½·E (`TitleSimilarity`): J the soft word Jaccard (exact words after the
/// split/glue repair, plus one-to-one near matches between long words ≥ 0.8 alike), E the edit
/// similarity of the space-free strings. Both halves are bounded from above:
/// - E: an edit script keeps at most the shared characters (as multisets), so
///   lev ≥ max(|a|, |b|) − |chars(a) ∩ chars(b)|. Characters are counted in 64 buckets (a–z,
///   0–9 exact, everything else folded), which only enlarges the intersection: the bound stays valid.
/// - J: the exact words are counted the way the score counts them (the same split/glue repair),
///   and the near matches are bounded by the words on each side that have *any* partner whose
///   length and letters allow ≥ 0.8 similarity (a matching never exceeds the smaller of the two).
///
/// Never below the real score (the property tests compare both on the fixture pairs, on split /
/// glued / typo variants and on random titles), so the scan finds exactly what a full scan finds.
package enum TitleBound {
    /// An upper bound of `TitleSimilarity.score(a.norm, b.norm)`.
    package static func upperBound(_ a: TitleProfile, _ b: TitleProfile) -> Double {
        guard !a.norm.isEmpty, !b.norm.isEmpty else { return 0 }
        if a.norm == b.norm { return 1 }
        let words = WordCounts(a, b)
        return 0.5 * words.jaccard(near: words.nearBound(a, b)) + 0.5 * editBound(a, b)
    }

    /// Whether the score of `a` and `b` could reach `threshold` — the cheapest test first: the
    /// characters alone, then the words with every leftover long word counted as a near match,
    /// then the near matches their letters actually allow.
    package static func mayReach(_ a: TitleProfile, _ b: TitleProfile, _ threshold: Double) -> Bool {
        guard !a.norm.isEmpty, !b.norm.isEmpty else { return false }
        if a.norm == b.norm { return true }
        let th = threshold - 1e-9
        let edit = editBound(a, b)
        if 0.5 + 0.5 * edit < th { return false }
        let words = WordCounts(a, b)
        if 0.5 * words.jaccard(near: min(words.leftA.count, words.leftB.count)) + 0.5 * edit < th { return false }
        return 0.5 * words.jaccard(near: words.nearBound(a, b)) + 0.5 * edit >= th
    }

    /// E's upper bound from the scalar buckets of the space-free strings.
    static func editBound(_ a: TitleProfile, _ b: TitleProfile) -> Double {
        let longest = max(a.compactCount, b.compactCount)
        guard longest > 0 else { return 1 }
        let lower = longest - TitleProfile.intersection(a.bag, b.bag)
        return 1 - Double(max(0, lower)) / Double(longest)
    }

    /// The word sets as the score builds them (after the split/glue repair), their exact matches
    /// and the leftover long words (`String.count` ≥ 5, as the score filters them).
    struct WordCounts {
        let total: Int
        let exact: Int
        let leftA: Set<String>
        let leftB: Set<String>

        init(_ a: TitleProfile, _ b: TitleProfile) {
            let ta = Set(TitleBound.rejoinSplits(a.words, against: b.wordSet))
            let tb = Set(TitleBound.rejoinSplits(b.words, against: a.wordSet))
            let common = ta.intersection(tb)
            total = ta.count + tb.count
            exact = common.count
            leftA = ta.subtracting(common).filter { $0.count >= 5 }
            leftB = tb.subtracting(common).filter { $0.count >= 5 }
        }

        func jaccard(near: Int) -> Double {
            let matched = Double(exact + near)
            let denominator = Double(total) - matched
            return denominator <= 0 ? 1 : min(1, matched / denominator)
        }

        /// A matching never exceeds the smaller number of words that have any possible partner.
        func nearBound(_ a: TitleProfile, _ b: TitleProfile) -> Int {
            guard !leftA.isEmpty, !leftB.isEmpty else { return 0 }
            var partneredB = Set<String>()
            var partneredA = 0
            for x in leftA {
                let bx = a.wordBag(x)
                var found = false
                for y in leftB where TitleBound.mayBeNear(x, bx, y, b.wordBag(y)) {
                    found = true
                    partneredB.insert(y)
                }
                if found { partneredA += 1 }
            }
            return min(partneredA, partneredB.count)
        }
    }

    /// Two long words could be ≥ 0.8 alike (`TitleSimilarity`'s near match): their scalars allow it.
    static func mayBeNear(_ x: String, _ bx: [UInt16], _ y: String, _ by: [UInt16]) -> Bool {
        let lx = x.unicodeScalars.count, ly = y.unicodeScalars.count
        let longest = max(lx, ly)
        guard longest > 0 else { return true }
        // The length difference alone (an edit script needs at least that many steps).
        if 1 - Double(abs(lx - ly)) / Double(longest) < 0.8 { return false }
        let lower = longest - TitleProfile.intersection(bx, by)
        return 1 - Double(max(0, lower)) / Double(longest) >= 0.8
    }

    /// `TitleSimilarity`'s split/glue repair, the same rule: adjacent words whose concatenation is
    /// (or starts) a word of the other title are merged when the result is one of its words.
    static func rejoinSplits(_ words: [String], against other: Set<String>) -> [String] {
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
}

/// What the bound needs of one normalized title, computed once (`TitleProfileCache` keeps the
/// tombstones' between imports).
package struct TitleProfile: Sendable {
    package let norm: String
    package let words: [String]
    package let wordSet: Set<String>
    /// Scalars of the space-free title, at most 400 (as the score truncates it).
    package let compactCount: Int
    package let bag: [UInt16]
    /// Per distinct word: its scalar buckets.
    private let wordBags: [String: [UInt16]]

    static let buckets = 64
    static let maxScalars = 400

    /// `norm` is a normalized title (`DedupeText.titleNorm`), re-normalized here like the score does
    /// (skipped when it is plainly in normal form already: the stored tombstone titles are).
    package init(_ norm: String) {
        let n = Self.isPlainNormal(norm) ? norm : TitleSimilarity.normalize(norm)
        self.norm = n
        words = n.split(separator: " ").map(String.init)
        wordSet = Set(words)
        var bag = [UInt16](repeating: 0, count: Self.buckets)
        var count = 0
        for u in n.unicodeScalars where u != " " {
            if count == Self.maxScalars { break }
            bag[Self.bucket(u)] &+= 1
            count += 1
        }
        compactCount = count
        self.bag = bag
        var bags: [String: [UInt16]] = [:]
        for w in wordSet where w.count >= 5 { bags[w] = Self.bag(of: w) }
        wordBags = bags
    }

    /// Lowercase ASCII letters and digits in words separated by single spaces — what
    /// `TitleSimilarity.normalize` returns for such a string unchanged (nothing to fold, spell out,
    /// strip or compose), so re-normalizing it can be skipped.
    static func isPlainNormal(_ s: String) -> Bool {
        var previousSpace = true
        for u in s.utf8 {
            if u == 32 {
                if previousSpace { return false }
                previousSpace = true
            } else if (u >= 97 && u <= 122) || (u >= 48 && u <= 57) {
                previousSpace = false
            } else {
                return false
            }
        }
        return !previousSpace
    }

    /// A word's buckets (computed for a word the profile doesn't hold: a glued one).
    func wordBag(_ w: String) -> [UInt16] { wordBags[w] ?? Self.bag(of: w) }

    static func bag(of w: String) -> [UInt16] {
        var bag = [UInt16](repeating: 0, count: buckets)
        for u in w.unicodeScalars { bag[bucket(u)] &+= 1 }
        return bag
    }

    /// a–z → 0…25, 0–9 → 26…35, anything else folded into 36…63.
    static func bucket(_ u: Unicode.Scalar) -> Int {
        let v = u.value
        if v >= 97 && v <= 122 { return Int(v - 97) }
        if v >= 48 && v <= 57 { return 26 + Int(v - 48) }
        if v >= 65 && v <= 90 { return Int(v - 65) + 36 }        // never after normalization; kept apart anyway
        return 36 + Int(v % 28)
    }

    static func intersection(_ a: [UInt16], _ b: [UInt16]) -> Int {
        var s = 0
        for i in 0..<min(a.count, b.count) { s += Int(min(a[i], b[i])) }
        return s
    }
}

/// Tombstone title profiles across imports (a folder import compares every file with the same
/// tombstones). Keyed by the normalized title itself, so it can never be stale; bounded.
package final class TitleProfileCache: @unchecked Sendable {
    package static let shared = TitleProfileCache()
    static let limit = 4_096

    private let lock = NSLock()
    private var profiles: [String: TitleProfile] = [:]

    package func profile(_ norm: String) -> TitleProfile {
        if let hit = lock.withLock({ profiles[norm] }) { return hit }
        let p = TitleProfile(norm)
        lock.withLock {
            if profiles.count >= Self.limit { profiles.removeAll(keepingCapacity: true) }
            profiles[norm] = p
        }
        return p
    }
}
