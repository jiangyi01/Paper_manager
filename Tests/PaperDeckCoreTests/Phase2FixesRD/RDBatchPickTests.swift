import Foundation
import Testing
@testable import PaperDeckCore

/// Phase 2 fix B3-2: in the batch review (and the decision sheet), the user's explicit pick survives
/// an [Ask AI] answer. A pick that equalled the row's suggestion used to be stored as "no override",
/// so a confident answer that moved the suggestion silently changed what [Apply] did — "Set all to
/// Keep both" became Skip (the new copy removed) for that row. The AI only re-bands.
@Suite("Phase 2 fixes RD: explicit picks survive the judge")
struct RDBatchPickTests {
    static let review = DupReview(newPaperID: "n", existingPaperID: "e", band: .possible, score: 0.6,
                                  createdAt: Date(timeIntervalSince1970: 0), newPaperPK: 1, existingPaperPK: 2,
                                  relation: .sameWork, evidence: [], newerSide: nil, origin: .scan)

    static func detail(_ r: DupReview, _ def: DupChoiceKind, choices: [DupChoiceKind] = [.keepNew, .keepBoth, .skip]) -> DupReviewDetail {
        DupReviewDetail(review: r, new: DupSideSummary(title: "t"), existing: DupSideSummary(title: "t"),
                        explanation: DupExplanation(headline: ""), choices: choices, defaultChoice: def,
                        canRegenerateChecklist: false)
    }

    /// The verifier's probe: possible (suggests Keep both) → "Set all to Keep both" → a confident
    /// same-work answer moves the suggestion to Skip → the row still applies Keep both.
    @Test func aPresetEqualToTheSuggestionSurvivesAJudgeAnswer() {
        var rows = [DupBatchRow(detail: Self.detail(Self.review, .keepBoth))]
        rows = DupBatch.applying(.keepBoth, to: rows)
        #expect(rows[0].choice == .keepBoth && rows[0].override == .keepBoth && !rows[0].isOverridden)
        var judged = Self.review
        judged.band = .likely
        let row = rows[0].refreshed(with: Self.detail(judged, .skip))
        #expect(row.suggested == .skip)
        #expect(row.choice == .keepBoth, "the user's 'Set all to Keep both' was replaced by the AI-moved suggestion")
        #expect(row.isOverridden)                       // now it differs from the (new) suggestion: highlighted
        #expect(row.dupChoice == .keepBoth(linkAsRelated: false))
    }

    /// A row without a pick follows the new suggestion; a pick the fresh review no longer offers
    /// falls back to it; "Set all to Suggested" clears every pick.
    @Test func withoutAPickTheRowFollowsTheNewSuggestion() {
        var judged = Self.review
        judged.band = .likely
        let plain = DupBatchRow(detail: Self.detail(Self.review, .keepBoth)).refreshed(with: Self.detail(judged, .skip))
        #expect(plain.choice == .skip && plain.override == nil)
        let gone = DupBatchRow(detail: Self.detail(Self.review, .keepBoth), override: .keepNew)
            .refreshed(with: Self.detail(judged, .skip, choices: [.keepBoth, .skip]))
        #expect(gone.choice == .skip && gone.override == nil)
        let picked = DupBatch.applying(.skip, to: [DupBatchRow(detail: Self.detail(Self.review, .keepBoth))])
        #expect(picked[0].override == .skip)
        #expect(DupBatch.applying(.suggested, to: picked)[0].override == nil)
        // The sheet's carry rule is the same.
        #expect(DupBatch.carry(.keepBoth, into: Self.detail(judged, .skip)) == .keepBoth)
        #expect(DupBatch.carry(.keepNew, into: Self.detail(judged, .skip, choices: [.skip])) == nil)
        #expect(DupBatch.carry(nil, into: Self.detail(judged, .skip)) == nil)
        // "N changed" still counts only rows that differ from their suggestion.
        #expect(DupBatch.changes(.keepBoth, in: [DupBatchRow(detail: Self.detail(Self.review, .keepBoth))]) == 0)
    }

    /// The same flow with the real engine and a scripted mock judge.
    @Test func throughTheEngine() async throws {
        let mock = MockAssistBackend(behavior: DupJudgeEngineTests.answer("same_work", 0.95))
        try await DedupeKit.run(DupJudgeEngineTests.settings(), assist: mock) { env in
            let body = DedupeKit.body(seed: "mail judge")
            _ = await env.ingest([try env.pdf("journal.pdf", title: DupJudgeEngineTests.title, body: body)])
            let url = try env.pdf("attachment.pdf", title: DupJudgeEngineTests.title, body: body)
            _ = await env.ingest([url], origin: .mail, annotations: [url: ImportAnnotation(sameWorkPolicy: .link)])
            let review = try await env.onlyOpenReview()
            try await env.engine.setDuplicateJudgeEnabled(true)
            var rows = await env.engine.duplicateBatchRows(ids: [review.id])
            #expect(rows.first?.suggested == .keepBoth)
            rows = DupBatch.applying(.keepBoth, to: rows)
            _ = try await env.engine.askDuplicateJudge(reviewID: review.id, ticket: DupJudgeEngineTests.ticket(env))
            let fresh = try await env.engine.duplicateReviewDetail(id: review.id)
            #expect(fresh.review.band == .likely && fresh.defaultChoice != .keepBoth)
            let row = rows[0].refreshed(with: fresh)
            #expect(row.choice == .keepBoth, "the AI answer replaced the user's preset for this row")
            // [Apply] keeps both: nothing removed.
            let applied = await env.engine.resolveDuplicates([(row.id, row.dupChoice)])
            #expect(applied.failed.isEmpty && applied.resolved.first?.choice == .keepBoth)
            #expect(try await env.paper(try #require(review.newPaperID)).isLive)
        }
    }
}
