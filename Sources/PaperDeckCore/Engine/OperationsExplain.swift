import Foundation

/// Why an Explain operation was refused.
package enum ExplainOperationError: Error, Equatable, Sendable {
    case explanationNotFound(String)
    /// The explanation belongs to no paper yet (pick one first).
    case notMatched(String)
}

// Explain's engine operations (READING_ASSIST_PLAN §4 `ExplainOps`). Owned by Slice A. History
// (save / list / pin / notes / prune) since A1; locating the paper, its context and the history's
// anchors / filing / delete since A3. All local: no AI, no network.
extension Engine {
    /// Which library paper `capture` shows: the reader's anchor names it exactly; otherwise the
    /// locator matches the window title and the captured text (`PaperLocator`). nil: none.
    package func locatePaper(_ capture: ExplainCapture) async -> PaperMatch? {
        if let anchor = capture.readerAnchor {
            guard let paper = try? await db.paper(id: anchor.paperID), paper.isLive else { return nil }
            return PaperMatch(paperID: paper.id, page: anchor.page, confidence: 1, via: .reader)
        }
        return await PaperLocator.locate(windowTitle: capture.windowTitle, ocrText: capture.text ?? capture.readerAnchor?.text,
                                         engine: self)
    }

    /// The structured context of an Explain turn about `match` (nil: unmatched) around the
    /// captured `text` (`PaperContextBuilder`), with the paper's privacy inputs.
    package func explainContext(for match: PaperMatch?, around text: String?) async -> ExplainContext {
        await PaperContextBuilder.context(for: match, around: text, engine: self)
    }

    /// The matched paper's vocabulary for OCR's custom words (empty: unmatched or gone).
    package func explainCustomWords(for match: PaperMatch?) async -> [String] {
        guard let match, let paper = try? await db.paper(id: match.paperID) else { return [] }
        return PaperContextBuilder.customWords(paper)
    }

    /// The located paper's context in its flat A1 form within `budget` characters (the meta line,
    /// then the section, abstract and nearby text); nil when the paper is gone.
    package func paperContext(_ match: PaperMatch, budget: Int) async -> PaperContext? {
        let c = await explainContext(for: match, around: nil)
        guard c.isMatched, budget > 0 else { return nil }
        let meta = PaperContextBuilder.clip(c.metaLine ?? "", min(budget, PaperContextBuilder.Caps.title + 200))
        let parts = [c.section.map { "Section: " + $0 }, c.abstract.map { "Abstract: " + $0 }, c.nearby].compactMap { $0 }
        let context = PaperContextBuilder.clip(parts.joined(separator: "\n\n"), max(budget - meta.count, 0))
        return PaperContext(paperID: match.paperID, meta: meta, context: context)
    }

    /// One explanation (nil: unknown).
    package func explanation(id: String) async throws -> ExplanationRecord? {
        try await db.explanation(id: id)
    }

    /// The turns of one panel, in order.
    package func explanations(threadID: String) async throws -> [ExplanationRecord] {
        try await db.explanations(threadID: threadID)
    }

    /// Removes an explanation from the history (a saved-to-notes copy stays in the notes).
    package func deleteExplanation(id: String) async throws {
        do {
            try await db.deleteExplanation(id: id)
        } catch DatabaseError.notFound {
            throw ExplainOperationError.explanationNotFound(id)
        }
    }

    /// Files an explanation under a live paper the user picked (`via: .user`), or unfiles it (nil).
    /// Every turn of its panel follows, so a follow-up's notes go to the same paper.
    package func assignExplanation(id: String, paperID: String?) async throws {
        guard let record = try await db.explanation(id: id) else { throw ExplainOperationError.explanationNotFound(id) }
        var pk: Int64?
        if let paperID { pk = try await PaperOpsSupport.livePK(db, paperID) }
        for turn in try await db.explanations(threadID: record.threadID) {
            try await db.setExplanationPaper(id: turn.id, paperPK: pk, via: pk == nil ? nil : .user, score: pk == nil ? nil : 1)
        }
    }

    /// Where the explanation points back to (the history's page chip), nil when it is unmatched
    /// or its paper is gone.
    package func explanationAnchor(id: String) async throws -> ExplanationAnchor? {
        guard let record = try await db.explanation(id: id) else { throw ExplainOperationError.explanationNotFound(id) }
        guard let paperID = record.paperID, let paper = try await db.paper(id: paperID), paper.isLive else { return nil }
        return ExplanationAnchor(paperID: paperID, page: record.page, highlight: Self.highlight(record.excerpt))
    }

    /// The excerpt's first sentence on one line, ≤ `ExplanationAnchor.highlightLimit` characters.
    static func highlight(_ excerpt: String?) -> String? {
        guard let flat = excerpt.map(PaperContextBuilder.oneLine), !flat.isEmpty else { return nil }
        var sentence = flat
        if let end = flat.range(of: #"[.!?](\s|$)|[。！？]"#, options: .regularExpression) {
            sentence = String(flat[..<end.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        let limit = ExplanationAnchor.highlightLimit
        guard sentence.count > limit else { return sentence }
        let head = String(sentence.prefix(limit))
        if let space = head.lastIndex(where: \.isWhitespace) { return String(head[..<space]) }
        return head
    }

    /// Stores an explanation (the excerpt is kept to `ExplanationRecord.maxExcerpt` characters).
    @discardableResult
    package func saveExplanation(_ record: ExplanationRecord) async throws -> ExplanationRecord {
        try await db.insertExplanation(record)
    }

    /// Newest first; nil `paperID`: across papers (and unmatched ones).
    package func explanations(paperID: String?, limit: Int) async throws -> [ExplanationRecord] {
        guard let paperID else { return try await db.explanations(paperPK: nil, limit: limit) }
        guard let paper = try await db.paper(id: paperID) else { throw PaperOperationError.paperNotFound(paperID) }
        return try await db.explanations(paperPK: paper.pk, limit: limit)
    }

    /// Appends the explanation to its paper's notes (`ExplainNotes.block`) through the same path
    /// as the notes editor, and marks it saved (kept by every prune). A second call changes nothing.
    package func appendExplanationToNotes(id: String) async throws {
        guard let record = try await db.explanation(id: id) else { throw ExplainOperationError.explanationNotFound(id) }
        guard record.savedToNotesAt == nil else { return }
        guard let paperID = record.paperID else { throw ExplainOperationError.notMatched(id) }
        let block = ExplainNotes.block(record, lang: ctx.loadSettings().lang, timeZone: ctx.calendar.timeZone)
        _ = try await PaperOpsSupport.modifyLive(self, paperID) { p, _ in
            p.notes = ExplainNotes.append(block, to: p.notes)
        }
        try await db.markExplanationSaved(id: id, at: ctx.now())
    }

    package func setExplanationPinned(id: String, _ pinned: Bool) async throws {
        do {
            try await db.setExplanationPinned(id: id, pinned)
        } catch DatabaseError.notFound {
            throw ExplainOperationError.explanationNotFound(id)
        }
    }

    /// Removes unpinned, unsaved explanations older than `date`; returns how many.
    @discardableResult
    package func pruneExplanations(olderThan date: Date) async throws -> Int {
        try await db.pruneExplanations(olderThan: date)
    }

    /// Maintenance's pass: `assist.explain.historyDays` (default 90) before now.
    @discardableResult
    package func pruneExplanationsByRetention() async throws -> Int {
        let days = max(1, ctx.loadSettings().assist.explainHistoryDays)     // never "prune everything"
        return try await pruneExplanations(olderThan: ctx.now().addingTimeInterval(-Double(days) * 86_400))
    }
}

/// The notes block of a saved explanation (LN §7.3):
/// ```
/// — Explain · p. 5 · 2026-10-01 14:32 · Claude haiku
/// > "We regularize the attention weights by …"
/// <answer>
/// ```
/// The label follows the UI language; the excerpt is one line of at most `excerptLimit` characters.
package enum ExplainNotes {
    package static let excerptLimit = 300

    package static func block(_ r: ExplanationRecord, lang: UILang, timeZone: TimeZone) -> String {
        var head = [lang == .zh ? "讲解" : "Explain"]
        if let page = r.page { head.append(lang == .zh ? "第 \(page) 页" : "p. \(page)") }
        head.append(stamp(r.createdAt, timeZone: timeZone))
        let who = providerName(r.meta.provider, lang: lang)
        head.append(r.meta.model.isEmpty || r.meta.provider == AssistMode.local.rawValue ? who : "\(who) \(r.meta.model)")
        var lines = ["— " + head.joined(separator: " · ")]
        if let q = oneLine(r.question) { lines.append("> " + (lang == .zh ? "问：" : "Q: ") + q) }
        if let e = oneLine(r.excerpt) { lines.append("> \"" + e + "\"") }
        lines.append(r.answer.trimmingCharacters(in: .whitespacesAndNewlines))
        return lines.joined(separator: "\n")
    }

    /// `block` after `notes`, one blank line between them.
    package static func append(_ block: String, to notes: String) -> String {
        let base = notes.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        return base.isEmpty ? block + "\n" : base + "\n\n" + block + "\n"
    }

    private static func providerName(_ provider: String, lang: UILang) -> String {
        if let kind = AIProviderKind(rawValue: provider) { return kind.shortName }
        switch AssistMode(rawValue: provider) {
        case .local?: return lang == .zh ? "本机模型" : "On-device model"
        case .mock?: return "Mock"
        default: return provider
        }
    }

    private static func oneLine(_ s: String?) -> String? {
        guard let s else { return nil }
        let flat = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return flat.count > excerptLimit ? String(flat.prefix(excerptLimit - 1)) + "…" : flat
    }

    private static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }
}
