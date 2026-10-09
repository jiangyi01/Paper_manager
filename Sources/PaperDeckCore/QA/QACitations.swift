import Foundation

/// Citations in Q&A answers (DQ §6.3, dive-ui §2.4). Pure.
///
/// The model is asked for `[p. N]`, `[pp. N–M]`, `[P2 p. N]` and, from cards only, `[P2]`. The parser
/// is tolerant of what models actually write: `[[p. 7]]` (the input's own markers), `[p.7]`,
/// `[page 7]`, `[pp. 3, 7]`, `[p. 3; p. 9]`, `[P2 · p. 5]`, `[P2, p. 5]`, `[P1 p. 3; P2 p. 5]`,
/// `[第 7 页]`. Anything else in brackets (`[1]`, `[x]`, `[see Fig. 2]`) is not a citation.
///
/// Validity: the paper must be one of the thread's P1…Pn and the page within its page count — an
/// invalid chip is drawn dimmed, its `problem` says why. A citation without a paper label names P1
/// only when the thread has one paper; with several it is `.ambiguous` (Phase 2 fix QA-7). A page
/// that wasn't sent with the question is `.notSent` (`markUnsent`, QA-5): the model never saw it.
/// The supporting sentence is chosen locally (no tokens, no quotes asked of the model): the
/// sentence of the cited page sharing the most content words with the claim; when none shares
/// enough, `quoteFound = false` and the chip is drawn outlined.
package enum QACitations {
    /// One marker in a text and what it cites (one marker may cite several pages or papers).
    package struct Token: Sendable, Equatable {
        package var range: Range<String.Index>
        package var citations: [QACitation]
    }

    /// The custom URL scheme of a citation link in rendered answers (handled in-process only).
    package static let linkScheme = "paperdeck-cite"

    private static let bracket = try! NSRegularExpression(pattern: #"\[\[?([^\[\]\n]{1,80})\]\]?"#)
    private static let itemSplit = try! NSRegularExpression(pattern: #"\s*[;；]\s*|\s*,\s*(?=P\s*\d)"#)
    private static let paperPrefix = try! NSRegularExpression(pattern: #"^P\s*(\d{1,2})(?![\d.])"#)
    private static let pageSpec = try! NSRegularExpression(
        pattern: #"^(?:pp?\.?|pages?|第)\s*(\d{1,4}(?:\s*[-–—~]\s*\d{1,4})?(?:\s*(?:,|and|&|、)\s*\d{1,4}(?:\s*[-–—~]\s*\d{1,4})?)*)\s*页?$"#,
        options: [.caseInsensitive])
    private static let rangeNumbers = try! NSRegularExpression(pattern: #"(\d{1,4})(?:\s*[-–—~]\s*(\d{1,4}))?"#)

    /// Every citation marker in `text`, in order.
    package static func tokens(in text: String) -> [Token] {
        guard text.contains("[") else { return [] }
        let ns = text as NSString
        var out: [Token] = []
        for m in bracket.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: m.range(at: 1))
            guard let cites = parseInner(inner), let range = Range(m.range, in: text) else { continue }
            // `[[p. 3]` / `[p. 3]]`: keep only balanced double brackets as one token.
            let whole = ns.substring(with: m.range)
            let opens = whole.hasPrefix("[["), closes = whole.hasSuffix("]]")
            var r = range
            if opens != closes {
                if opens { r = text.index(after: r.lowerBound)..<r.upperBound } else { r = r.lowerBound..<text.index(before: r.upperBound) }
            }
            out.append(Token(range: r, citations: cites))
        }
        return out
    }

    /// The citations of `text` in order (a marker's several citations in their written order),
    /// validated against the thread's papers. `pageCounts[i]` is P(i+1)'s page count (nil: unknown).
    package static func parse(_ text: String, pageCounts: [Int?]) -> [QACitation] {
        tokens(in: text).flatMap { $0.citations.map { validate($0, pageCounts: pageCounts) } }
    }

    /// `c` with `valid` and `problem` set: a known paper, a page within its count (any positive page
    /// when the count is unknown), a range that doesn't end past it. An unlabelled citation (paper 0)
    /// is P1's when the thread has one paper (`pageCounts.count <= 1`) and `.ambiguous` otherwise.
    /// (`.notSent` is decided afterwards, by `markUnsent`.)
    package static func validate(_ c: QACitation, pageCounts: [Int?]) -> QACitation {
        var c = c
        c.valid = true
        c.problem = nil
        if c.paper == 0 {
            guard pageCounts.count <= 1 else { return invalid(c, .ambiguous) }
            c.paper = 1
        }
        guard c.paper >= 1, c.paper <= max(1, pageCounts.count) else { return invalid(c, .unknownPaper) }
        let count = pageCounts.indices.contains(c.paper - 1) ? pageCounts[c.paper - 1] : nil
        if let page = c.page {
            var ok = page >= 1
            if let count { ok = ok && page <= count }
            if let end = c.endPage, let count { ok = ok && end <= count }
            if !ok { return invalid(c, .pageMissing) }
        }
        return c
    }

    private static func invalid(_ c: QACitation, _ problem: QACitation.Problem) -> QACitation {
        var c = c
        c.valid = false
        c.problem = problem
        return c
    }

    /// `cites` with every valid page citation none of whose pages went out (`sent[paper - 1]` holds
    /// the pages sent per paper) marked invalid, `.notSent`, unchecked.
    package static func markUnsent(_ cites: [QACitation], sent: [[Int: String]]) -> [QACitation] {
        cites.map { c in
            guard c.valid, let first = c.page else { return c }
            let pages = sent.indices.contains(c.paper - 1) ? sent[c.paper - 1] : [:]
            let last = max(first, c.endPage ?? first)
            guard !(first...last).contains(where: { pages[$0] != nil }) else { return c }
            var out = invalid(c, .notSent)
            out.quote = nil
            out.quoteFound = nil
            return out
        }
    }

    /// Why `c` is invalid (nil: valid). Answers stored before `problem` existed get it derived from
    /// the thread's paper count.
    package static func problem(of c: QACitation, paperCount: Int) -> QACitation.Problem? {
        guard !c.valid else { return nil }
        if let p = c.problem { return p }
        if c.paper < 1 { return .ambiguous }
        return c.paper > max(1, paperCount) || c.page == nil ? .unknownPaper : .pageMissing
    }

    /// The stored citation an inline marker's citation stands for (validated first: a marker
    /// without a paper label is P1's in a single-paper thread), or the validated marker itself.
    package static func resolve(_ marker: QACitation, stored: [QACitation], pageCounts: [Int?]) -> QACitation {
        let v = validate(marker, pageCounts: pageCounts)
        return stored.first { $0.paper == v.paper && $0.page == v.page && $0.endPage == v.endPage } ?? v
    }

    /// The chip's text: `p. 7`, `pp. 7–9`, `P2 · p. 5`, `P2`. A citation without a paper label
    /// shows none (`p. 5`), also among several papers.
    package static func display(_ c: QACitation, multi: Bool) -> String {
        var page = ""
        if let p = c.page {
            page = c.endPage.map { "pp. \(p)–\($0)" } ?? "p. \(p)"
        }
        guard multi, c.paper >= 1 else { return page.isEmpty ? "P\(c.paper)" : page }
        return page.isEmpty ? "P\(c.paper)" : "P\(c.paper) · " + page
    }

    /// `text` with every marker written as `(p. 7)` / `(P2 · p. 5)` (notes, copy).
    package static func plain(_ text: String, multi: Bool) -> String {
        replacingTokens(in: text) { t in "(" + t.citations.map { display($0, multi: multi) }.joined(separator: "; ") + ")" }
    }

    /// `text` with every marker replaced by `transform(token)` (in order).
    package static func replacingTokens(in text: String, _ transform: (Token) -> String) -> String {
        let found = tokens(in: text)
        guard !found.isEmpty else { return text }
        var out = ""
        var cursor = text.startIndex
        for t in found {
            out += text[cursor..<t.range.lowerBound]
            out += transform(t)
            cursor = t.range.upperBound
        }
        out += text[cursor...]
        return out
    }

    /// `text` as Markdown in which each marker is a link `[p. 7](paperdeck-cite://<k>)` — `k` the
    /// marker's index in `tokens(in:)` — so the app can render chips inline and route clicks.
    package static func linkedMarkdown(_ text: String, multi: Bool) -> String {
        var k = -1
        return replacingTokens(in: text) { t in
            k += 1
            let label = t.citations.map { display($0, multi: multi) }.joined(separator: "; ")
            return "[\(label)](\(linkScheme)://\(k))"
        }
    }

    // MARK: Supporting sentences

    /// The answer's citations (as `parse`) with their supporting sentence: `pageText(paper, page)`
    /// gives the text sent for that page (nil: none). Pages of a range are searched up to 3.
    package static func attachQuotes(_ text: String, pageCounts: [Int?],
                                     pageText: (_ paper: Int, _ page: Int) -> String?) -> [QACitation] {
        let found = tokens(in: text)
        // The answer with every marker blanked out, so a marker's own "p. 7" is never a sentence end.
        var masked = Array(text)
        var starts: [Int] = []
        for t in found {
            let lo = text.distance(from: text.startIndex, to: t.range.lowerBound)
            let hi = text.distance(from: text.startIndex, to: t.range.upperBound)
            for i in lo..<hi { masked[i] = " " }
            starts.append(lo)
        }
        var out: [QACitation] = []
        for (t, start) in zip(found, starts) {
            let claim = claimWords(masked, before: start)
            for raw in t.citations {
                var c = validate(raw, pageCounts: pageCounts)
                if c.valid, let first = c.page {
                    let last = min(c.endPage ?? first, first + 2)
                    let pages = (first...max(first, last)).compactMap { pageText(c.paper, $0) }
                    if !pages.isEmpty, claim.count >= 2 {
                        let best = bestSentence(claim: claim, in: pages)
                        c.quote = best
                        c.quoteFound = best != nil
                    }
                }
                out.append(c)
            }
        }
        return out
    }

    /// Content words of the sentence of `chars` that ends at offset `end`; with fewer than two, the
    /// sentence before it too ("… is Y. [p. 7]").
    static func claimWords(_ chars: [Character], before end: Int) -> Set<String> {
        let (words, start) = sentenceWords(chars, before: end)
        guard words.count < 2, start > 0 else { return words }
        // Step back over the boundary (spaces, the full stop) to the end of the sentence before.
        var boundary = start
        while boundary > 0, chars[boundary - 1].isWhitespace || ".!?。！？".contains(chars[boundary - 1]) { boundary -= 1 }
        guard boundary > 0 else { return words }
        return words.union(sentenceWords(chars, before: boundary).words)
    }

    /// The words between the last sentence end before `end` and `end`, and where that sentence starts.
    private static func sentenceWords(_ chars: [Character], before end: Int) -> (words: Set<String>, start: Int) {
        var start = 0
        var i = end
        while i > 0 {
            let ch = chars[i - 1]
            if ch == "\n" || "。！？".contains(ch) { start = i; break }
            if ".!?".contains(ch), i < end, chars[i].isWhitespace, !(i >= 2 && chars[i - 2].isNumber && chars[i].isNumber) {
                start = i; break
            }
            i -= 1
        }
        return (words(String(chars[start..<end])), start)
    }

    /// The sentence of `pages` sharing the most claim words, if it shares at least
    /// max(2, ⌈claim / 4⌉) of them; at most 240 characters.
    static func bestSentence(claim: Set<String>, in pages: [String]) -> String? {
        let need = max(2, (claim.count + 3) / 4)
        var best: (score: Int, text: String)?
        for page in pages {
            for s in sentences(page) {
                let score = words(s).intersection(claim).count
                if score >= need, score > (best?.score ?? 0) { best = (score, s) }
            }
        }
        guard let text = best?.text else { return nil }
        return text.count > 240 ? String(text.prefix(239)) + "…" : text
    }

    /// A page's sentences: lines joined, split after . ! ? (not inside numbers) and 。！？.
    static func sentences(_ page: String) -> [String] {
        let flat = page.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        var out: [String] = []
        var current = ""
        let chars = Array(flat)
        for (i, ch) in chars.enumerated() {
            current.append(ch)
            let end: Bool
            if "。！？".contains(ch) { end = true } else if ".!?".contains(ch) {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                end = next.isWhitespace && !(i > 0 && chars[i - 1].isNumber && next.isNumber)
            } else {
                end = false
            }
            if end {
                let s = current.trimmingCharacters(in: .whitespaces)
                if s.count >= 12 { out.append(s) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if rest.count >= 12 { out.append(rest) }
        return out
    }

    /// Lowercased words of ≥ 4 letters (not stop words) and numbers of ≥ 2 characters ("92.3").
    static func words(_ s: String) -> Set<String> {
        var out = Set<String>()
        var current = ""
        func flush() {
            defer { current = "" }
            let t = current.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            guard !t.isEmpty, !FTSQuery.containsCJK(t) else { return }
            let numeric = t.allSatisfy { $0.isNumber || $0 == "." }
            if numeric ? t.count >= 2 : (t.count >= 4 && !EphemeralPageIndex.stopWords.contains(t)) { out.insert(t) }
        }
        for ch in s {
            if ch.isLetter || ch.isNumber || (ch == "." && current.last?.isNumber == true) { current.append(ch) } else { flush() }
        }
        flush()
        return out
    }

    // MARK: Parsing

    /// The citations one bracket holds, or nil when it isn't (entirely) a citation.
    static func parseInner(_ raw: String) -> [QACitation]? {
        let inner = raw.trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return nil }
        let ns = inner as NSString
        var items: [String] = []
        var cursor = 0
        for m in itemSplit.matches(in: inner, range: NSRange(location: 0, length: ns.length)) {
            items.append(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            cursor = m.range.location + m.range.length
        }
        items.append(ns.substring(from: cursor))
        var out: [QACitation] = []
        for item in items {
            guard let cites = parseItem(item.trimmingCharacters(in: .whitespaces)) else { return nil }
            out += cites
        }
        return out.isEmpty ? nil : out
    }

    /// One item of a bracket; an item without a paper label gets paper 0 (`validate` decides).
    private static func parseItem(_ item: String) -> [QACitation]? {
        guard !item.isEmpty else { return nil }
        var rest = item
        var paper = 0
        var hasPaper = false
        let ns = item as NSString
        if let m = paperPrefix.firstMatch(in: item, range: NSRange(location: 0, length: ns.length)) {
            paper = Int(ns.substring(with: m.range(at: 1))) ?? 0
            hasPaper = true
            rest = ns.substring(from: m.range.location + m.range.length)
            rest = String(rest.drop { " ·•,:-–—|/".contains($0) })
        }
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return hasPaper ? [QACitation(paper: paper, page: nil)] : nil }
        let tn = trimmed as NSString
        guard let m = pageSpec.firstMatch(in: trimmed, range: NSRange(location: 0, length: tn.length)) else { return nil }
        let list = tn.substring(with: m.range(at: 1))
        let ln = list as NSString
        var out: [QACitation] = []
        for r in rangeNumbers.matches(in: list, range: NSRange(location: 0, length: ln.length)) {
            guard let first = Int(ln.substring(with: r.range(at: 1))) else { continue }
            var end: Int?
            if r.range(at: 2).location != NSNotFound, let e = Int(ln.substring(with: r.range(at: 2))), e > first { end = e }
            out.append(QACitation(paper: paper, page: first, endPage: end))
        }
        return out.isEmpty ? nil : out
    }
}
