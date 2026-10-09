import Foundation

/// One prepared page of a paper: the text after `TextPreparer` (de-hyphenated, running headers and
/// reference lists removed), indexed by its `[[p. N]]` marker (the PDF's physical page).
package struct QAPage: Sendable, Equatable {
    package var number: Int
    package var text: String

    package init(number: Int, text: String) { self.number = number; self.text = text }
}

/// One paper as Q&A sees it: metadata, the card's text, the prepared pages.
package struct QAPaperInput: Sendable, Equatable {
    package var id: String
    package var title: String
    package var authors: [String]
    package var year: Int?
    package var venue: String?
    package var doi: String?
    package var arxiv: String?
    package var pageCount: Int?
    package var abstract: String?
    package var tldr: String?
    /// The card's summary lines (summary, contributions, results, limitations, key terms), one per line.
    package var cardLines: [String]
    /// Empty: no text layer (or the text could not be read): only metadata and card go out.
    package var pages: [QAPage]

    package init(id: String, title: String, authors: [String] = [], year: Int? = nil, venue: String? = nil,
                 doi: String? = nil, arxiv: String? = nil, pageCount: Int? = nil, abstract: String? = nil,
                 tldr: String? = nil, cardLines: [String] = [], pages: [QAPage] = []) {
        self.id = id; self.title = title; self.authors = authors; self.year = year; self.venue = venue
        self.doi = doi; self.arxiv = arxiv; self.pageCount = pageCount; self.abstract = abstract; self.tldr = tldr
        self.cardLines = cardLines; self.pages = pages
    }

    /// Characters of all pages.
    package var textChars: Int { pages.reduce(0) { $0 + $1.text.count } }
}

/// Everything one question's context depends on.
package struct QAContextRequest: Sendable, Equatable {
    package var papers: [QAPaperInput]
    package var question: String
    /// Earlier turns of the thread (question, answer, …), oldest first: done answers only.
    package var history: [AssistTurnText]
    package var mode: QAContextMode
    /// `assist.qa.textBudget`: the single-paper budget (characters of page text).
    package var textBudget: Int
    package var language: UILang
    package var depth: AssistSettings.Depth

    package init(papers: [QAPaperInput], question: String, history: [AssistTurnText] = [], mode: QAContextMode = .fullText,
                 textBudget: Int = 80_000, language: UILang = .en, depth: AssistSettings.Depth = .quick) {
        self.papers = papers; self.question = question; self.history = history; self.mode = mode
        self.textBudget = textBudget; self.language = language; self.depth = depth
    }
}

/// The built turn: the text sent on stdin, what it holds, and the page texts the answer's citations
/// are checked against.
package struct QAContext: Sendable, Equatable {
    package var turnText: String
    /// The stable part (metadata, cards, papers): byte-identical across follow-ups whenever the
    /// same pages go out (always, when every paper fits), so the provider can cache it.
    package var prefix: String
    package var stats: QAContextStats
    /// The pages sent, per paper (P1 first), by page number.
    package var sentPages: [[Int: String]]
}

/// Builds a question's context (DQ §6.2, READING_ASSIST_PLAN §4 "Turn parameters"). Pure.
///
/// Layout, stable parts first:
/// ```
/// <metadata> one line per paper </metadata>
/// <card id="P1"> TL;DR, summary, … </card>
/// <paper id="P1"> [[p. 1]] … [… pages 12–18 omitted …] … </paper>
/// <conversation> [user] … [assistant] … </conversation>
/// <task> language, length, citation form </task>
/// <question> … </question>
/// ```
/// Budgets: one paper → `textBudget` (80,000 by default); several → full text only for ≤ 3 papers
/// (40,000 each), excerpts 100,000 / N each, cards ~1,500 characters each and no page text. A paper
/// that fits goes in full; one that doesn't keeps its first page (title, abstract) and then the pages
/// that match the question best (`EphemeralPageIndex`, bm25), then the earliest remaining pages
/// while the budget lasts — always in page order, with a marker where pages were left out.
///
/// The question is cut to `questionLimit` characters and the conversation to `historyLimit` (each
/// earlier question to `historyQuestionChars`, each answer to `historyAnswerChars`): trimmed, never
/// refused (dive-cli §7; Phase 2 fix QA-10). Page markers come only from the builder: a `[[p. N]]`
/// written inside a page's own text is defused before the pages are numbered (QA-8).
package enum QAContextBuilder {
    package static let multiFullTextBudget = 40_000
    package static let multiExcerptTotal = 100_000
    package static let cardChars = 1_500
    /// The card in a full-text or excerpt context (the page text carries the substance).
    package static let shortCardChars = 800
    package static let historyTurns = 6
    package static let historyAnswerChars = 1_500
    /// The question sent (dive-cli §7: question ≤ 1 000 characters, trimmed rather than refused).
    package static let questionLimit = 1_000
    /// An earlier question in `<conversation>`.
    package static let historyQuestionChars = 1_000
    /// The whole `<conversation>` (dive-cli §7: history ≤ 6 000); the oldest turns go first.
    package static let historyLimit = 6_000

    /// The question as it is sent and stored: trimmed, at most `questionLimit` characters ("…" marks a cut).
    package static func capQuestion(_ question: String) -> String {
        cut(question.trimmingCharacters(in: .whitespacesAndNewlines), to: questionLimit)
    }

    /// The composer's text is longer than what a question sends (the Ask views show a note).
    package static func questionIsCut(_ draft: String) -> Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).count > questionLimit
    }

    private static func cut(_ s: String, to limit: Int) -> String {
        s.count > limit ? String(s.prefix(limit - 1)) + "…" : s
    }

    package static func build(_ r: QAContextRequest) -> QAContext {
        var r = r
        r.question = capQuestion(r.question)
        let multi = r.papers.count > 1
        let mode: QAContextMode = r.papers.count > QAContextMode.fullTextMaxPapers && r.mode == .fullText ? .excerpts : r.mode
        let budget = perPaperBudget(mode: mode, count: r.papers.count, textBudget: r.textBudget)
        var blocks: [String] = []

        // <metadata>
        if !r.papers.isEmpty {
            let lines = r.papers.enumerated().map { i, p in metadataLine(p, label: multi ? "P\(i + 1)" : nil) }
            blocks.append("<metadata>\n" + lines.joined(separator: "\n") + "\n</metadata>")
        }
        // <card>
        for (i, p) in r.papers.enumerated() {
            let text = cardText(p, limit: mode == .cards ? cardChars : shortCardChars)
            guard !text.isEmpty else { continue }
            blocks.append("<card\(multi ? " id=\"P\(i + 1)\"" : "")>\n" + text + "\n</card>")
        }
        // <paper>
        var pagesSent: [[Int]] = []
        var sentPages: [[Int: String]] = []
        var omitted = 0
        var fullText = !r.papers.isEmpty && mode != .cards
        if mode != .cards {
            for (i, p) in r.papers.enumerated() {
                let picked = select(pages: p.pages, question: r.question, budget: budget)
                pagesSent.append(picked.kept.map(\.number))
                sentPages.append(Dictionary(picked.kept.map { ($0.number, $0.text) }, uniquingKeysWith: { a, _ in a }))
                omitted += picked.omitted.count
                if !picked.omitted.isEmpty || p.pages.isEmpty { fullText = false }
                guard !p.pages.isEmpty else { continue }
                blocks.append("<paper\(multi ? " id=\"P\(i + 1)\"" : "")>\n" + render(picked.kept, all: p.pages) + "</paper>")
            }
        } else {
            pagesSent = r.papers.map { _ in [] }
            sentPages = r.papers.map { _ in [:] }
            omitted = r.papers.reduce(0) { $0 + $1.pages.count }
        }
        let prefix = blocks.isEmpty ? "" : blocks.joined(separator: "\n") + "\n"

        var tail: [String] = []
        let history = conversation(r.history)
        if !history.isEmpty { tail.append("<conversation>\n" + history + "\n</conversation>") }
        tail.append("<task>\n" + QAPrompts.task(language: r.language, depth: r.depth, multi: multi, cardsOnly: mode == .cards)
                    + "\n</task>")
        tail.append("<question>\n" + BlockTags.neutralize(r.question) + "\n</question>")
        let turnText = prefix + tail.joined(separator: "\n") + "\n"
        let stats = QAContextStats(mode: mode, chars: turnText.count, estimatedTokens: QAEstimator.tokens(turnText),
                                   pages: pagesSent, omittedPages: omitted, fullText: fullText)
        return QAContext(turnText: turnText, prefix: prefix, stats: stats, sentPages: sentPages)
    }

    /// Characters of page text one paper may send.
    package static func perPaperBudget(mode: QAContextMode, count: Int, textBudget: Int) -> Int {
        let n = max(1, count)
        switch mode {
        case .cards: return 0
        case .fullText: return n == 1 ? textBudget : min(textBudget, multiFullTextBudget)
        case .excerpts: return n == 1 ? textBudget : min(textBudget, multiExcerptTotal / n)
        }
    }

    /// The pages that fit `budget`: everything when it all fits; otherwise the first page, then the
    /// question's best pages, then the earliest remaining ones — returned in page order.
    package static func select(pages: [QAPage], question: String, budget: Int) -> (kept: [QAPage], omitted: [Int]) {
        guard !pages.isEmpty else { return ([], []) }
        let total = pages.reduce(0) { $0 + $1.text.count }
        if total <= budget { return (pages, []) }
        var keep = Set<Int>()
        var used = 0
        func add(_ p: QAPage) {
            guard !keep.contains(p.number), used + p.text.count <= budget else { return }
            keep.insert(p.number)
            used += p.text.count
        }
        let byNumber = Dictionary(pages.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        add(pages[0])
        for hit in EphemeralPageIndex.rank(pages: pages, question: question) {
            if let p = byNumber[hit.page] { add(p) }
        }
        for p in pages { add(p) }
        let kept = pages.filter { keep.contains($0.number) }
        let omitted = pages.filter { !keep.contains($0.number) }.map(\.number)
        return (kept, omitted)
    }

    /// `[[p. N]]` + text per kept page; a marker for each run of left-out pages.
    static func render(_ kept: [QAPage], all: [QAPage]) -> String {
        let keep = Set(kept.map(\.number))
        var out = ""
        var gap: [Int] = []
        func flushGap() {
            guard let first = gap.first, let last = gap.last else { return }
            out += first == last ? "[… page \(first) omitted …]\n" : "[… pages \(first)–\(last) omitted …]\n"
            gap = []
        }
        for p in all {
            if keep.contains(p.number) {
                flushGap()
                out += "[[p. \(p.number)]]\n" + BlockTags.neutralize(defusePageMarkers(p.text))
                if !out.hasSuffix("\n") { out += "\n" }
            } else {
                gap.append(p.number)
            }
        }
        flushGap()
        return out
    }

    static func metadataLine(_ p: QAPaperInput, label: String?) -> String {
        var parts: [String] = []
        if let label { parts.append(label) }
        parts.append(clean(p.title.isEmpty ? "Untitled" : p.title))
        if !p.authors.isEmpty {
            let names = p.authors.prefix(6).map(clean)
            parts.append(names.joined(separator: ", ") + (p.authors.count > 6 ? " et al." : ""))
        }
        if let year = p.year { parts.append(String(year)) }
        if let venue = p.venue.map(clean), !venue.isEmpty { parts.append(venue) }
        if let doi = p.doi { parts.append("doi:" + clean(doi)) } else if let arxiv = p.arxiv { parts.append("arXiv:" + clean(arxiv)) }
        if let n = p.pageCount ?? (p.pages.isEmpty ? nil : p.pages.map(\.number).max()) { parts.append("\(n) pages") }
        if p.pages.isEmpty { parts.append("no page text") }
        return parts.joined(separator: " · ")
    }

    /// TL;DR, then the card lines (or the abstract when there is no card), within `limit`.
    static func cardText(_ p: QAPaperInput, limit: Int) -> String {
        var lines: [String] = []
        if let tldr = p.tldr.map(clean), !tldr.isEmpty { lines.append("TL;DR: " + tldr) }
        lines += p.cardLines.map(clean).filter { !$0.isEmpty }
        if lines.isEmpty, let abstract = p.abstract.map(clean), !abstract.isEmpty { lines.append("Abstract: " + abstract) }
        var out = ""
        for line in lines {
            let piece = (out.isEmpty ? "" : "\n") + line
            if out.count + piece.count > limit {
                let room = limit - out.count - 1
                if room > 40 { out += String(piece.prefix(room)) + "…" }
                break
            }
            out += piece
        }
        return out
    }

    /// The last `historyTurns` turns (oldest first), questions cut to `historyQuestionChars`, answers
    /// to `historyAnswerChars`; then the oldest dropped until the whole fits `historyLimit`.
    static func conversation(_ turns: [AssistTurnText]) -> String {
        var lines = turns.suffix(historyTurns).map { t in
            let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let limit = t.role == .assistant ? historyAnswerChars : historyQuestionChars
            return "[\(t.role.rawValue)] " + BlockTags.neutralize(cut(text, to: limit))
        }
        while lines.count > 1, lines.reduce(0, { $0 + $1.count + 1 }) - 1 > historyLimit { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    /// One line, block tags neutralized.
    private static func clean(_ s: String) -> String { BlockTags.neutralize(QAPrompts.oneLine(s)) }

    // MARK: - Page text

    /// `[[` before a page marker's `p.` / `pp.` (any case, spaces or invisible marks between) becomes
    /// `[ [`: a page's own text can't pose as a page boundary, neither to the page split nor to the
    /// model. Idempotent.
    package static func defusePageMarkers(_ s: String) -> String {
        guard s.contains("[") else { return s }
        let ns = s as NSString
        return markerLike.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "[ [")
    }

    private static let markerLike = try! NSRegularExpression(
        pattern: #"\[[\s\p{Cf}]*\[(?=[\s\p{Cf}]*p{1,2}[\s\p{Cf}]*\.)"#, options: [.caseInsensitive])

    /// The cached full text (pages separated by form feeds) prepared like the card's `<paper>`
    /// payload, without trimming, split back into pages at its `[[p. N]]` markers. Marker-like text
    /// inside a page is defused first, so only `TextPreparer`'s own markers number the pages.
    package static func preparePages(rawText: String) -> [QAPage] {
        let raw = rawText.split(separator: "\u{0C}", omittingEmptySubsequences: false).map { defusePageMarkers(String($0)) }
        guard raw.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return [] }
        let structure = Sections.analyze(pageTexts: raw, outline: nil)
        let prepared = TextPreparer.prepare(pageTexts: raw, structure: structure, budget: 0)     // 0: nothing trimmed
        return pages(fromMarked: prepared.text)
    }

    /// Splits `[[p. N]]`-marked text into pages (text before the first marker is dropped). The
    /// markers `TextPreparer` writes only ever increase: one that doesn't is page text, so a page
    /// number is never used twice.
    package static func pages(fromMarked text: String) -> [QAPage] {
        var out: [QAPage] = []
        var current: Int?
        var buffer = ""
        func flush() {
            if let n = current {
                let body = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { out.append(QAPage(number: n, text: body)) }
            }
            buffer = ""
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("[[p. "), line.hasSuffix("]]"), let n = Int(line.dropFirst(5).dropLast(2)), n > (current ?? 0) {
                flush()
                current = n
            } else {
                buffer += line
                buffer += "\n"
            }
        }
        flush()
        return out
    }
}
