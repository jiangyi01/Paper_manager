import Foundation

/// The reader's find bar: which match is current among the matches of the query, in document order.
/// Pure; owned by Slice C (reader).
package struct ReaderFindCursor: Sendable, Equatable {
    /// Physical page of each match, in document order.
    package private(set) var matchPages: [Int]
    /// The current match (nil: no matches).
    package private(set) var index: Int?

    /// A new search starts at the first match on or after `page` (the page being read), wrapping to
    /// the first match.
    package init(matchPages: [Int], startingAt page: Int?) {
        self.matchPages = matchPages
        guard !matchPages.isEmpty else { index = nil; return }
        if let page, let i = matchPages.firstIndex(where: { $0 >= page }) { index = i } else { index = 0 }
    }

    package var count: Int { matchPages.count }

    /// An incremental search (RD-1) delivered more matches, in document order: the current match
    /// stays where it is; with none yet, it becomes the first match on or after `page` once one has
    /// arrived (without a page, the first match). Until then there is none — `finish()` wraps to
    /// the first match when the search ends without one after `page`.
    package mutating func append(_ pages: [Int], startingAt page: Int?) {
        let from = matchPages.count
        matchPages += pages
        guard index == nil, !pages.isEmpty else { return }
        if let page {
            if let i = matchPages[from...].firstIndex(where: { $0 >= page }) { index = i }
        } else {
            index = 0
        }
    }

    /// The search is over: no match on or after the page read → the first match (as `init`).
    package mutating func finish() {
        if index == nil, !matchPages.isEmpty { index = 0 }
    }

    /// ⌘G / Return (while a search is still running without a current match: the first one).
    package mutating func next() {
        guard count > 0 else { return }
        guard let i = index else { index = 0; return }
        index = (i + 1) % count
    }

    /// ⇧⌘G / ⇧Return.
    package mutating func previous() {
        guard count > 0 else { return }
        guard let i = index else { index = count - 1; return }
        index = (i - 1 + count) % count
    }

    /// 1-based "3 of 12" position.
    package var position: Int? { index.map { $0 + 1 } }
}

/// Finding a quoted passage on a page (a citation's quote, a saved explanation's excerpt): PDF text
/// breaks lines, hyphenates words, uses ligatures and curly quotes, and a model may trim or paraphrase
/// the ends of a quote — so the search is whitespace-, hyphenation- and case-tolerant and falls back to
/// shorter runs of the quote's words. Pure; owned by Slice C (reader).
package enum ReaderQuote {
    /// Minimum characters of a search string (shorter ones match too much).
    package static let minLength = 4

    /// Search strings, most specific first: the whole quote (quotes and ellipses stripped, whitespace
    /// collapsed); the longest part between ellipses; then the first 12, the first 6 and the last 6
    /// words. Empty when nothing is long enough.
    package static func candidates(_ quote: String) -> [String] {
        let whole = clean(quote)
        guard whole.count >= minLength else { return [] }
        var out = [whole]
        func add(_ s: String) {
            let c = clean(s)
            if c.count >= minLength, !out.contains(c) { out.append(c) }
        }
        // "We show … that X": the longest part between ellipses stands for the quote.
        let parts = whole.components(separatedBy: "…").flatMap { $0.components(separatedBy: "...") }
            .map(clean).filter { !$0.isEmpty }
        var core = whole
        if parts.count > 1, let longest = parts.max(by: { $0.count < $1.count }) {
            add(longest)
            core = longest
        }
        let words = core.split(separator: " ").map(String.init)
        if words.count > 12 { add(words.prefix(12).joined(separator: " ")) }
        if words.count > 6 {
            add(words.prefix(6).joined(separator: " "))
            add(words.suffix(6).joined(separator: " "))
        }
        return out
    }

    /// Which match to show: the first on `target` itself, else the nearest within `tolerance` pages
    /// (earlier page first on a tie: a citation more often points one page late than early), else
    /// nil. Without a target, the first match.
    package static func pick(matchPages: [Int], target: Int?, tolerance: Int = 1) -> Int? {
        guard let target else { return matchPages.isEmpty ? nil : 0 }
        var best: (index: Int, distance: Int, page: Int)?
        for (i, p) in matchPages.enumerated() {
            let d = abs(p - target)
            guard d <= tolerance else { continue }
            if let b = best, (b.distance, b.page) <= (d, p) { continue }
            best = (i, d, p)
        }
        return best?.index
    }

    /// Straight quotes, no surrounding quote marks, single spaces.
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let edge: Set<Character> = ["\"", "'", "«", "»", "「", "」", "“", "”", " "]
        while let f = t.first, edge.contains(f) { t.removeFirst() }
        while let l = t.last, edge.contains(l) { t.removeLast() }
        while t.hasPrefix("…") || t.hasPrefix("...") { t = String(t.dropFirst(t.hasPrefix("…") ? 1 : 3)).trimmingCharacters(in: .whitespaces) }
        while t.hasSuffix("…") || t.hasSuffix("...") { t = String(t.dropLast(t.hasSuffix("…") ? 1 : 3)).trimmingCharacters(in: .whitespaces) }
        return t
    }
}

/// A page's text prepared for tolerant search, with a map back to the original (UTF-16 offsets, what
/// `PDFPage.selection(for: NSRange)` takes): whitespace runs become one space, ligatures and other
/// compatibility characters are expanded ("ﬁ" → "fi"), curly quotes straightened, and — with
/// `joinHyphens` — a word broken at a line end ("regu-\nlarize") is joined. Pure; owned by Slice C.
package struct ReaderTextIndex: Sendable {
    package let normalized: String
    /// For each UTF-16 unit of `normalized`: the original UTF-16 range it came from.
    private let starts: [Int]
    private let ends: [Int]

    package init(_ original: String, joinHyphens: Bool) {
        var out = ""
        var starts: [Int] = [], ends: [Int] = []
        var offset = 0
        let chars = Array(original)
        var i = 0
        var pendingSpace: (start: Int, end: Int)?
        func emit(_ s: String, _ from: Int, _ to: Int) {
            for unit in s.utf16 { _ = unit; starts.append(from); ends.append(to) }
            out += s
        }
        while i < chars.count {
            let c = chars[i]
            let width = c.utf16.count
            if c.isWhitespace {
                if pendingSpace == nil { pendingSpace = (offset, offset + width) } else { pendingSpace!.end = offset + width }
                offset += width; i += 1
                continue
            }
            if joinHyphens, c == "-" || c == "\u{00AD}", let next = Self.wordAfterLineBreak(chars, after: i) {
                // "regu-\n larize": drop the hyphen and the break; the space before it (if any) stays.
                var skipped = width
                for k in (i + 1)..<next { skipped += chars[k].utf16.count }
                offset += skipped; i = next
                continue
            }
            if let space = pendingSpace {
                if !out.isEmpty { emit(" ", space.start, space.end) }
                pendingSpace = nil
            }
            emit(Self.fold(c), offset, offset + width)
            offset += width; i += 1
        }
        self.normalized = out
        self.starts = starts
        self.ends = ends
    }

    /// The original UTF-16 range of the first match of `query` (normalized the same way), searched
    /// case- and diacritic-insensitively; nil when absent.
    package func find(_ query: String) -> NSRange? { findAll(query, limit: 1).first }

    /// Every match (up to `limit`), as original UTF-16 ranges.
    package func findAll(_ query: String, limit: Int = .max) -> [NSRange] {
        let q = ReaderTextIndex(query, joinHyphens: false).normalized
        guard !q.isEmpty, !normalized.isEmpty else { return [] }
        let hay = normalized as NSString
        var out: [NSRange] = []
        var from = 0
        while from < hay.length, out.count < limit {
            let r = hay.range(of: q, options: [.caseInsensitive, .diacriticInsensitive],
                              range: NSRange(location: from, length: hay.length - from))
            guard r.location != NSNotFound, r.length > 0 else { break }
            let start = starts[r.location], end = ends[r.location + r.length - 1]
            out.append(NSRange(location: start, length: end - start))
            from = r.location + r.length
        }
        return out
    }

    /// The index of the word character after a hyphen that ends a line ("-" then a newline, maybe
    /// spaces) when that character is a lowercase letter; nil otherwise ("state-of-the-art" on one
    /// line, "Fig. 3-\nB").
    private static func wordAfterLineBreak(_ chars: [Character], after i: Int) -> Int? {
        guard i > 0, chars[i - 1].isLetter else { return nil }
        var k = i + 1
        var sawNewline = false
        while k < chars.count, chars[k].isWhitespace {
            if chars[k].isNewline { sawNewline = true }
            k += 1
        }
        guard sawNewline, k < chars.count, chars[k].isLowercase else { return nil }
        return k
    }

    /// Compatibility forms ("ﬁ" → "fi", full-width → ASCII) and straight quotes.
    private static func fold(_ c: Character) -> String {
        switch c {
        case "\u{201C}", "\u{201D}", "\u{201E}": return "\""
        case "\u{2018}", "\u{2019}", "\u{201A}": return "'"
        case "\u{2010}", "\u{2011}": return "-"
        default:
            let s = String(c)
            return s.unicodeScalars.allSatisfy(\.isASCII) ? s : s.precomposedStringWithCompatibilityMapping
        }
    }
}
