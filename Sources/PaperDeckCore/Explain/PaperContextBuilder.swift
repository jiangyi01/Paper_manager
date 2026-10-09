import Foundation

/// The located paper's context for an Explain turn (LN §5 "Context sent when matched", dive-cli §7
/// caps) plus the paper's privacy inputs. Built locally from the library; nothing here is sent
/// until `ExplainPrompt` places it — neutralized — in the turn's blocks. Never holds a window title.
package struct ExplainContext: Sendable, Equatable {
    package var paperID: String?
    /// Physical, 1-based.
    package var page: Int?
    package var via: MatchSource?
    package var confidence: Double?
    package var title: String?
    /// The first `PaperContextBuilder.Caps.authors` authors.
    package var authors: [String]
    /// More authors than `authors` lists ("et al.").
    package var moreAuthors: Bool
    package var year: Int?
    package var venue: String?
    /// The nearest section heading before the capture ("3 Method").
    package var section: String?
    package var abstract: String?
    /// The paper's text around the capture (±`Caps.nearbyEachSide` characters, cleaned).
    package var nearby: String?
    /// The page's figure / table caption (the one the capture names, else the nearest).
    package var figureCaption: String?
    // Privacy inputs (`AssistPrivacy`), read with the paper.
    package var policy: PaperPolicy?
    package var aiNote: String?
    package var provenance: [PaperSourceSummary]
    /// The privacy inputs couldn't be read: ask before sending (never assume "ok").
    package var privacyUnchecked: Bool
    /// The paper's own vocabulary for OCR (`OCREngine.recognize(customWords:)`).
    package var customWords: [String]

    package init(paperID: String? = nil, page: Int? = nil, via: MatchSource? = nil, confidence: Double? = nil,
                 title: String? = nil, authors: [String] = [], moreAuthors: Bool = false, year: Int? = nil,
                 venue: String? = nil, section: String? = nil, abstract: String? = nil, nearby: String? = nil,
                 figureCaption: String? = nil, policy: PaperPolicy? = nil, aiNote: String? = nil,
                 provenance: [PaperSourceSummary] = [], privacyUnchecked: Bool = false, customWords: [String] = []) {
        self.paperID = paperID; self.page = page; self.via = via; self.confidence = confidence; self.title = title
        self.authors = authors; self.moreAuthors = moreAuthors; self.year = year; self.venue = venue
        self.section = section; self.abstract = abstract; self.nearby = nearby; self.figureCaption = figureCaption
        self.policy = policy; self.aiNote = aiNote; self.provenance = provenance
        self.privacyUnchecked = privacyUnchecked; self.customWords = customWords
    }

    /// No paper: only the capture itself is sent.
    package static let unmatched = ExplainContext()

    package var isMatched: Bool { paperID != nil }

    /// "Title — A, B, C et al. · Venue · 2024" (the A1 flat `PaperContext.meta`); nil unmatched.
    package var metaLine: String? {
        guard let title, !title.isEmpty else { return nil }
        var parts = [title]
        if !authors.isEmpty { parts.append(authors.joined(separator: ", ") + (moreAuthors ? " et al." : "")) }
        if let venue, !venue.isEmpty { parts.append(venue) }
        if let year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }
}

package enum PaperContextBuilder {
    /// Per-part caps (dive-cli §7, LN §5), characters.
    package enum Caps {
        package static let title = 300
        package static let authors = 3
        package static let venue = 120
        package static let section = 160
        package static let abstract = 600
        package static let nearbyEachSide = 1_200
        package static let caption = 600
        package static let customWords = 60
    }

    /// The context for `match` (nil → unmatched), the text `around` being what was captured (OCR
    /// or exact text): it is found again on the matched page — or, failing that, anywhere in the
    /// paper — so the nearby text and the section are the ones around it; without it the page's
    /// start stands in. Always returns (an unmatched context when the paper is gone).
    package static func context(for match: PaperMatch?, around: String?, engine: Engine) async -> ExplainContext {
        guard let match, let paper = try? await engine.db.paper(id: match.paperID) else { return .unmatched }
        var c = ExplainContext(paperID: paper.id, page: match.page, via: match.via, confidence: match.confidence)
        c.title = clip(oneLine(paper.title), Caps.title)
        c.authors = paper.authors.prefix(Caps.authors).map { clip(oneLine($0), 80) }
        c.moreAuthors = paper.authors.count > Caps.authors
        c.year = paper.year
        c.venue = paper.venue.map { clip(oneLine($0), Caps.venue) }
        c.abstract = paper.abstract.map { clip(oneLine($0), Caps.abstract) }.flatMap { $0.isEmpty ? nil : $0 }
        c.customWords = customWords(paper)
        do {
            let inputs = try await engine.privacyInputs(paperID: paper.id)
            c.policy = inputs.policy; c.aiNote = inputs.aiNote; c.provenance = inputs.provenance
        } catch {
            c.privacyUnchecked = true
        }
        let pages = await ExplainTextCache.shared.pages(of: paper, texts: engine.ctx.texts, now: engine.ctx.now())
        guard !pages.isEmpty else { return c }
        var pageIndex = match.page.map { $0 - 1 }.flatMap { pages.indices.contains($0) ? $0 : nil }
        var range: Range<Int>?
        if let around, TextMatch.normalizedCount(around) >= 20 {
            if let p = pageIndex, let hit = TextMatch.find(around, in: [pages[p]]), hit.score >= 0.3 {
                range = hit.range
            } else if let hit = TextMatch.find(around, in: pages), hit.score >= PaperLocator.tuning.textAccept {
                pageIndex = hit.page - 1
                range = hit.range
            }
        }
        guard let p = pageIndex else { return c }
        c.page = p + 1
        let chars = Array(pages[p].text)
        c.nearby = nearby(chars, range: range).flatMap { $0.isEmpty ? nil : $0 }
        c.section = section(pages, page: p, offset: range?.lowerBound ?? 0)
        c.figureCaption = caption(chars, near: range?.lowerBound ?? 0, hint: around)
        return c
    }

    /// The paper's vocabulary for OCR: title words, card key terms, the first author's surname.
    package static func customWords(_ paper: Paper) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ w: String) {
            let t = w.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
            guard t.count >= 4, t.count <= 40, t.contains(where: \.isLetter), seen.insert(t.lowercased()).inserted else { return }
            out.append(t)
        }
        paper.title.split(whereSeparator: { $0.isWhitespace || $0 == "/" }).forEach { add(String($0)) }
        paper.card?.keyTerms.forEach { add($0.term) }
        if let first = paper.authors.first { add(FileNamer.lastName(from: first)) }
        return Array(out.prefix(Caps.customWords))
    }

    // MARK: - Pieces

    /// `Caps.nearbyEachSide` characters each side of `range` (the page's start without one), cut at
    /// whitespace, cleaned like copied text (de-hyphenated, lines unwrapped), "…" where cut.
    static func nearby(_ chars: [Character], range: Range<Int>?) -> String? {
        guard !chars.isEmpty else { return nil }
        let r = range.map { $0.clamped(to: 0..<chars.count) } ?? 0..<0
        var lo = max(0, r.lowerBound - Caps.nearbyEachSide)
        var hi = min(chars.count, max(r.upperBound, r.lowerBound) + Caps.nearbyEachSide + (range == nil ? Caps.nearbyEachSide : 0))
        if lo > 0 { while lo < hi, !chars[lo - 1].isWhitespace { lo += 1 } }
        if hi < chars.count { while hi > lo, !chars[hi].isWhitespace { hi -= 1 } }
        guard lo < hi else { return nil }
        let body = OCRPostProcess.normalizeCopied(String(chars[lo..<hi]))
        guard !body.isEmpty else { return nil }
        return (lo > 0 ? "… " : "") + body + (hi < chars.count ? " …" : "")
    }

    /// The nearest section heading at or before `offset` on `page`, else on up to three earlier pages.
    static func section(_ pages: [ExplainTextCache.Page], page: Int, offset: Int) -> String? {
        for p in stride(from: page, through: max(0, page - 3), by: -1) {
            let text = p == page ? String(Array(pages[p].text).prefix(max(offset, 0) + 200)) : pages[p].text
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            for line in lines.reversed() where !line.isEmpty {
                guard let h = Sections.classifyLine(line, page: p + 1), case .section(let kind) = h,
                      ![.references, .acknowledgements, .other].contains(kind) else { continue }
                return clip(line, Caps.section)
            }
        }
        return nil
    }

    private static let captionStart = try! NSRegularExpression(
        pattern: #"(?m)^\s*((?:Extended Data |Supplementary )?(?:Fig\.?|Figure|FIG\.?|Table|TABLE)\s*(S?\d+))"#)

    /// The page's caption ("Figure 3 …" / "Table 2 …", ≤ `Caps.caption`): the one `hint` names
    /// ("Fig. 3"), else the one nearest `offset`.
    static func caption(_ chars: [Character], near offset: Int, hint: String?) -> String? {
        let text = String(chars)
        let ns = text as NSString
        let matches = captionStart.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        let wanted: String? = hint.flatMap { h in
            h.range(of: #"(?i)\b(?:fig\.?|figure|table)\s*(S?\d+)"#, options: .regularExpression).map {
                String(h[$0]).replacingOccurrences(of: #"(?i)^(?:fig\.?|figure|table)\s*"#, with: "", options: .regularExpression)
            }
        }
        let utf16Offset = String(chars.prefix(max(0, min(offset, chars.count)))).utf16.count
        let pick = matches.first { m in wanted.map { ns.substring(with: m.range(at: 2)).caseInsensitiveCompare($0) == .orderedSame } ?? false }
            ?? matches.min { abs($0.range.location - utf16Offset) < abs($1.range.location - utf16Offset) }
        guard let pick else { return nil }
        let start = pick.range(at: 1).location
        let rest = ns.substring(from: start)
        let body = OCRPostProcess.normalizeCopied(String(rest.prefix(Caps.caption * 2)))
        return body.isEmpty ? nil : clip(body, Caps.caption)
    }

    // MARK: - Text helpers

    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// At most `limit` characters (graphemes, never a split character), cut at a word boundary
    /// near the end when there is one, "…" appended when cut.
    package static func clip(_ s: String, _ limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard s.count > limit else { return s }
        let head = String(s.prefix(max(limit - 1, 0)))
        let window = max(limit / 5, min(15, limit / 2))
        if let space = head.lastIndex(where: \.isWhitespace), head.distance(from: space, to: head.endIndex) <= window {
            return String(head[..<space]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return head + "…"
    }
}
