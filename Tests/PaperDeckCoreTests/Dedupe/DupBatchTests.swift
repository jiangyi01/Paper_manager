import Foundation
import Testing
@testable import PaperDeckCore

/// The batch review (B3; DQ §7 `DupBatchTests`): rows start on their suggestion, presets never
/// pick a choice a row doesn't offer, [Apply] resolves each row (a row answered elsewhere is
/// reported, the others still go) and one undo token reverts them all.
@Suite struct DupBatchPureTests {
    static func detail(_ id: String, choices: [DupChoiceKind], default d: DupChoiceKind, band: DupBand = .likely,
                       relation: DupRelation = .sameWork, held: Bool = false) -> DupReviewDetail {
        let review = DupReview(id: id, newPaperID: "n" + id, existingPaperID: "e" + id, band: band, score: 0.9,
                               createdAt: Date(timeIntervalSince1970: 0), newPaperPK: 2, existingPaperPK: 1,
                               relation: relation, held: held ? DupHeldIntent(scheduleHeld: true) : nil)
        return DupReviewDetail(review: review, new: DupSideSummary(title: "N"), existing: DupSideSummary(title: "E"),
                               explanation: DupExplanation(headline: "h"), choices: choices, defaultChoice: d,
                               canRegenerateChecklist: false)
    }

    @Test func presetsTakeOnlyOfferedChoices() {
        let rows = [DupBatchRow(detail: Self.detail("a", choices: [.keepNew, .keepBoth, .skip], default: .keepNew)),
                    DupBatchRow(detail: Self.detail("b", choices: [.skip, .keepBoth], default: .skip, relation: .supplement)),
                    DupBatchRow(detail: Self.detail("c", choices: [.addAgain, .skip], default: .addAgain))]
        #expect(rows.map(\.choice) == [.keepNew, .skip, .addAgain] && rows.allSatisfy { !$0.isOverridden })
        let both = DupBatch.applying(.keepBoth, to: rows)
        #expect(both.map(\.choice) == [.keepBoth, .keepBoth, .addAgain])
        #expect(both.map(\.isOverridden) == [true, true, false])
        #expect(DupBatch.changes(.keepBoth, in: rows) == 2 && DupBatch.changes(.keepNew, in: rows) == 0)
        let skip = DupBatch.applying(.skip, to: both)
        #expect(skip.map(\.choice) == [.skip, .skip, .skip])
        #expect(DupBatch.applying(.suggested, to: skip) == rows)
        // An override the row doesn't offer never applies.
        var r = rows[2]
        r.override = .keepNew
        #expect(r.choice == .addAgain && !r.isOverridden)
        // The engine choices with the batch's default options (related rows stay linked).
        #expect(both[1].dupChoice == .keepBoth(linkAsRelated: true) && both[0].dupChoice == .keepBoth(linkAsRelated: false))
        #expect(DupBatch.choice(.rereadEarlier, for: rows[0].detail.review)
                == .rereadEarlier(checklist: .keepProgress, deadline: .auto, useNewFile: false))
        #expect(DupBatch.choice(.keepNew, for: rows[0].detail.review) == .keepNew(reread: false))
    }

    @Test func heldRowsComeFirstThenTheStrongerBand() {
        let a = Self.detail("a", choices: [.skip], default: .skip, band: .possible)
        let b = Self.detail("b", choices: [.skip], default: .skip, band: .likely)
        let c = Self.detail("c", choices: [.skip], default: .skip, band: .possible, held: true)
        let d = Self.detail("d", choices: [.skip], default: .skip, band: .certain)
        #expect(DupBatch.ordered([a, b, c, d]).map(\.id) == ["c", "d", "b", "a"])
        #expect(DupBatchResolution.message(applied: 3, failed: 1, lang: .en) == "Applied 3 duplicate decisions — 1 couldn't be applied")
        #expect(DupBatchResolution.message(applied: 1, failed: 0, lang: .zh) == "已处理 1 个重复提醒")
    }
}

@Suite(.serialized) struct DupBatchEngineTests {
    static let titles = ["Lineage tracing of organoid progenitors at scale",
                         "Chromatin accessibility in the aging mouse hippocampus",
                         "Microglia shape synaptic plasticity in cortical circuits"]

    /// Three originals, then one import of their copies plus an unrelated file: three held reviews.
    static func importBatch(_ env: DedupeKit.Env) async throws -> (summary: ImportBatchSummary, originals: [String]) {
        var originals: [String] = []
        for (i, t) in titles.enumerated() {
            let s = await env.ingest([try env.pdf("orig\(i).pdf", title: t, body: DedupeKit.body(seed: "text \(i)"))])
            originals.append(try #require(s.added.first))
        }
        var files: [URL] = []
        for (i, t) in titles.enumerated() {
            files.append(try env.pdf("copy\(i).pdf", title: t, body: DedupeKit.body(seed: "text \(i)")))
        }
        files.append(try env.pdf("other.pdf", title: "Deep learning predicts protein structure variants", body: DedupeKit.body(seed: "other")))
        return (await env.ingest(files), originals)
    }

    @Test func applyEveryRowThenUndoThemAllAtOnce() async throws {
        try await DedupeKit.run { env in
            let (summary, originals) = try await Self.importBatch(env)
            // One review toast for the import, opening its first review.
            #expect(env.events.toasts.contains { $0.id == "dup-batch-" + summary.batchID })
            let ids = await env.engine.duplicateBatchReviewIDs(batchID: summary.batchID)
            #expect(ids.count == 3)
            let rows = await env.engine.duplicateBatchRows(ids: ids)
            #expect(rows.count == 3 && rows.allSatisfy { $0.detail.review.hold == .scheduleAndAI && $0.suggested == .skip })
            // Row 2 overridden: keep both. The others: their suggestion (remove the new copy).
            let keep = rows[1]
            let items = DupBatch.applying(.suggested, to: rows).map { row -> (reviewID: String, choice: DupChoice) in
                row.id == keep.id ? (row.id, .keepBoth(linkAsRelated: false)) : (row.id, row.dupChoice)
            }
            let result = await env.engine.resolveDuplicates(items)
            #expect(result.resolved.count == 3 && result.failed.isEmpty)
            #expect(result.resolved.allSatisfy { $0.undoToken == nil })
            let token = try #require(result.undoToken)
            #expect(result.message == "Applied 3 duplicate decisions")
            #expect(try await env.db.dupReviews(state: .open).isEmpty)
            let kept = try await env.paper(try #require(keep.detail.review.newPaperID))
            #expect(kept.isLive && kept.scheduleMode != .none)
            #expect(try await env.db.dupPair(kept.pk, try #require(keep.detail.review.existingPaperPK))?.decision == "distinct")
            for row in rows where row.id != keep.id {
                #expect(try await env.paper(try #require(row.detail.review.newPaperID)).isDeleted)
            }
            // One Undo (through the engine's chained undo) reverts every row.
            #expect(try await env.engine.undo(token: token))
            let open = try await env.db.dupReviews(state: .open)
            #expect(Set(open.map(\.id)) == Set(ids))
            for row in rows {
                #expect(try await env.paper(try #require(row.detail.review.newPaperID)).isLive)
            }
            #expect(try await env.db.dupPair(kept.pk, try #require(keep.detail.review.existingPaperPK)) == nil)
            for id in originals { #expect(try await env.paper(id).isLive) }
            #expect(try await env.engine.undo(token: token) == false)
        }
    }

    @Test func aRowAnsweredElsewhereIsReportedAndTheOthersStillGo() async throws {
        try await DedupeKit.run { env in
            let (summary, _) = try await Self.importBatch(env)
            let rows = await env.engine.duplicateBatchRows(ids: await env.engine.duplicateBatchReviewIDs(batchID: summary.batchID))
            // Answered in its own sheet meanwhile.
            _ = try await env.engine.resolveDuplicate(reviewID: rows[0].id, .keepBoth(linkAsRelated: false))
            let result = await env.engine.resolveDuplicates(rows.map { ($0.id, $0.dupChoice) })
            #expect(result.resolved.map(\.reviewID) == rows.dropFirst().map(\.id))
            #expect(result.failed == [rows[0].id: .reviewClosed(rows[0].id)])
            #expect(result.message == "Applied 2 duplicate decisions — 1 couldn't be applied")
            #expect(result.undoToken != nil)
            // Closed rows aren't listed again.
            #expect(await env.engine.duplicateBatchRows(ids: rows.map(\.id)).isEmpty)
        }
    }

    @Test func aLibraryChecksQuestionsMakeOneBatch() async throws {
        try await DedupeKit.run(DedupeKit.settings(dedupe: DedupeSettings(enabled: false))) { env in
            // Copies imported while the check was off: no reviews yet.
            for (i, t) in Self.titles.prefix(2).enumerated() {
                _ = await env.ingest([try env.pdf("orig\(i).pdf", title: t, body: DedupeKit.body(seed: "scan \(i)"))])
                _ = await env.ingest([try env.pdf("copy\(i).pdf", title: t, body: DedupeKit.body(seed: "scan \(i)"))])
            }
            #expect(await env.engine.duplicateBatchReviewIDs(batchID: nil).isEmpty)
            env.settings.value = DedupeKit.settings()
            let check = try await env.engine.checkDuplicates()
            #expect(check.opened.count == 2)
            let ids = await env.engine.duplicateBatchReviewIDs(batchID: nil)
            #expect(Set(ids) == Set(check.opened))
            let rows = await env.engine.duplicateBatchRows(ids: ids)
            // A check's question holds nothing; its suggestion never throws a paper away silently.
            #expect(rows.count == 2 && rows.allSatisfy { $0.detail.review.origin == .scan && $0.detail.review.hold == .none })
            let result = await env.engine.resolveDuplicates(DupBatch.applying(.keepBoth, to: rows).map { ($0.id, $0.dupChoice) })
            #expect(result.resolved.count == 2 && result.resolved.allSatisfy { $0.choice == .keepBoth })
            #expect(await env.engine.duplicateBatchReviewIDs(batchID: nil).isEmpty)
        }
    }
}
