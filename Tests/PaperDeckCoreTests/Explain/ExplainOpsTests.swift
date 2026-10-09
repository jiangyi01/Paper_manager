import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// Explain's engine operations added in A3 (OperationsExplain, Database+Explain): the reader's
/// exact match, history delete / filing / anchors, the flat A1 context, the locator's DB queries.
@Suite struct ExplainOpsTests {
    static func record(_ paperID: String?, thread: String = "panel-1", turn: Int = 0, excerpt: String? = nil, page: Int? = 4) -> ExplanationRecord {
        ExplanationRecord(paperID: paperID, threadID: thread, turn: turn, source: .region, action: ExplainKind.explain.code, lang: .zh,
                          page: page, excerpt: excerpt, answer: "**要点。**", meta: AssistMeta(provider: "mock", model: "mock"),
                          createdAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(turn)))
    }

    @Test func theReaderAnchorIsAnExactMatch() async throws {
        let (engine, root) = try await ExplainKit.engine()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = try await ExplainKit.paper(engine, title: "Read in PaperDeck", pages: ["one", "two", "three"])
        let anchor = ReaderAnchor(paperID: p.id, kind: .selection, page: 3, rect: CGRect(x: 10, y: 10, width: 100, height: 20),
                                  pageBounds: CGRect(x: 0, y: 0, width: 612, height: 792), text: "three")
        let m = try #require(await engine.locatePaper(ExplainCapture(source: .reader, text: "three", readerAnchor: anchor)))
        #expect(m == PaperMatch(paperID: p.id, page: 3, confidence: 1, via: .reader))
        try await engine.db.softDelete(pk: p.pk)
        #expect(await engine.locatePaper(ExplainCapture(source: .reader, text: "three", readerAnchor: anchor)) == nil)
        await engine.shutdown()
    }

    @Test func historyDeleteFileAndAnchor() async throws {
        let (engine, root) = try await ExplainKit.engine()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = try await ExplainKit.paper(engine, title: "Picked later")
        let first = try await engine.saveExplanation(Self.record(nil, excerpt: "We regularize the weights. Then we test them."))
        let second = try await engine.saveExplanation(Self.record(nil, turn: 1))
        let other = try await engine.saveExplanation(Self.record(nil, thread: "panel-2"))
        // Unmatched: no anchor, notes refused until a paper is picked.
        #expect(try await engine.explanationAnchor(id: first.id) == nil)
        await #expect(throws: ExplainOperationError.notMatched(first.id)) { try await engine.appendExplanationToNotes(id: first.id) }
        // Filing one turn files its whole panel (as picked by the user), not other panels.
        try await engine.assignExplanation(id: second.id, paperID: p.id)
        let thread = try await engine.explanations(threadID: "panel-1")
        #expect(thread.map(\.paperID) == [p.id, p.id] && thread.allSatisfy { $0.matchVia == .user && $0.matchScore == 1 })
        #expect(try await engine.explanation(id: other.id)?.paperID == nil)
        #expect(try await engine.explanations(paperID: p.id, limit: 10).count == 2)
        try await engine.appendExplanationToNotes(id: first.id)
        #expect(try await engine.db.paper(id: p.id)?.notes.contains("**要点。**") == true)
        let anchor = try #require(try await engine.explanationAnchor(id: first.id))
        #expect(anchor == ExplanationAnchor(paperID: p.id, page: 4, highlight: "We regularize the weights."))
        // Unfiling, deleting, unknown ids.
        try await engine.assignExplanation(id: first.id, paperID: nil)
        #expect(try await engine.explanations(threadID: "panel-1").allSatisfy { $0.paperID == nil && $0.matchVia == nil })
        try await engine.deleteExplanation(id: other.id)
        #expect(try await engine.explanation(id: other.id) == nil)
        await #expect(throws: ExplainOperationError.explanationNotFound("nope")) { try await engine.deleteExplanation(id: "nope") }
        await #expect(throws: ExplainOperationError.explanationNotFound("nope")) { try await engine.assignExplanation(id: "nope", paperID: nil) }
        await #expect(throws: ExplainOperationError.explanationNotFound("nope")) { _ = try await engine.explanationAnchor(id: "nope") }
        await #expect(throws: PaperOperationError.self) { try await engine.assignExplanation(id: first.id, paperID: "missing") }
        await engine.shutdown()
    }

    @Test func highlightsAreTheFirstSentenceWithinTheLimit() {
        #expect(Engine.highlight("First one. Second one.") == "First one.")
        #expect(Engine.highlight("第一句。第二句。") == "第一句。")
        #expect(Engine.highlight("  ") == nil && Engine.highlight(nil) == nil)
        let long = String(repeating: "word ", count: 100)
        let h = try! #require(Engine.highlight(long))
        #expect(h.count <= ExplanationAnchor.highlightLimit && !h.hasSuffix(" "))
    }

    @Test func theFlatContextFitsItsBudget() async throws {
        let (engine, root) = try await ExplainKit.engine()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = try await ExplainKit.paper(engine, title: "Flat", pages: [String(repeating: "Body text of the page. ", count: 300)],
                                           abstract: "An abstract.")
        let c = try #require(await engine.paperContext(PaperMatch(paperID: p.id, page: 1, confidence: 0.9, via: .text), budget: 800))
        #expect(c.paperID == p.id && c.meta.hasPrefix("Flat") && c.meta.count + c.context.count <= 800)
        #expect(c.context.hasPrefix("Abstract: An abstract."))
        #expect(await engine.paperContext(PaperMatch(paperID: "gone", confidence: 1, via: .user), budget: 800) == nil)
        await engine.shutdown()
    }

    @Test func theLocatorsQueriesSkipDeletedPapersAndSurviveBadInput() async throws {
        let (engine, root) = try await ExplainKit.engine()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await ExplainKit.paper(engine, title: "Oligodendrocyte precursor survey", pages: ["Oligodendrocyte precursors divide."],
                                           pdfName: "2026_Lovelace_Survey.pdf", originalName: "Download (3).PDF")
        let b = try await ExplainKit.paper(engine, title: "Unrelated title", pages: ["Glaciers retreat."])
        let db = engine.db
        func any(_ words: [String]) throws -> String { try #require(FTSQuery.anyOf(words)) }
        let both = try any(["oligodendrocyte", "glaciers"]), glaciers = try any(["glaciers"])
        let titled = try any(["oligodendrocyte", "survey"]), oligo = try any(["oligodendrocyte"]), survey = try any(["survey"])
        #expect(try await db.fullTextCandidates(both, limit: 5).sorted() == [a.pk, b.pk].sorted())
        #expect(try await db.fullTextCandidates(glaciers) == [b.pk])
        #expect(try await db.titleCandidates(titled) == [a.pk])
        #expect(try await db.livePaperPKs(fileNames: ["2026_lovelace_survey.PDF"]) == [a.pk])
        #expect(try await db.livePaperPKs(fileNames: ["download (3).pdf", "  "]) == [a.pk])
        #expect(try await db.livePaperPKs(fileNames: []) == [])
        // A malformed expression (never built by anyOf) finds nothing instead of throwing.
        #expect(try await db.fullTextCandidates("\"unterminated", limit: 5) == [])
        #expect(try await db.titleCandidates("AND OR", limit: 5) == [])
        try await db.softDelete(pk: a.pk)
        #expect(try await db.fullTextCandidates(oligo) == [])
        #expect(try await db.titleCandidates(survey) == [])
        #expect(try await db.livePaperPKs(fileNames: ["2026_Lovelace_Survey.pdf"]) == [])
        await engine.shutdown()
    }
}
