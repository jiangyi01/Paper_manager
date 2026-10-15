import Foundation
import Testing
@testable import PaperDeckCore

/// The duplicate review toast's quick answers go through the review, so they can be undone
/// (dedupe-batch-3); Check for Duplicates finds live pairs even when a Recently Deleted copy
/// matches better (dedupe-batch-4).
@Suite(.serialized) struct DedupeQuickAnswerTests {
    private typealias R = DupResolutionTests

    /// The review toast the App posts for the import's classic same-work toast, and its quick answer.
    static func quickAnswer(_ env: DedupeKit.Env, review: DupReview) async throws -> (reviewID: String, choice: DupChoice) {
        let classic = try #require(env.events.toasts.first { DupExplainer.classicSameWorkPendingID($0) != nil })
        let worded = try #require(await env.engine.duplicateToast(replacing: classic))
        guard case .resolveDuplicate(let id, let choice) = try #require(worded.buttons.last).action else {
            Issue.record("no quick answer: \(worded.buttons)")
            throw CancellationError()
        }
        #expect(id == review.id)
        // The classic Replace / Ignore (which could not be undone) is not offered any more.
        #expect(!worded.buttons.contains { if case .replaceKeepingChecklist = $0.action { true } else { false } })
        #expect(!worded.buttons.contains { if case .ignorePending = $0.action { true } else { false } })
        return (id, choice)
    }

    @Test func keepNewFromTheToastCanBeUndone() async throws {
        try await DedupeKit.run(R.lookupOn(), fetcher: R.fetcher) { env in
            env.events.clear()
            let (e, review) = try await R.parked(env)
            let (id, choice) = try await Self.quickAnswer(env, review: review)
            #expect(choice == .keepNew(reread: false))
            let result = try await env.engine.resolveDuplicate(reviewID: id, choice)
            await env.settle()
            #expect(try await env.paper(e.id).ids.doi == R.journalDOI)
            let token = try #require(result.undoToken)
            #expect(try await env.engine.undo(token: token))                  // the toast's Undo
            let back = try await env.paper(e.id)
            #expect(back.sha256 == e.sha256 && back.ids.doi == R.preprintDOI)
            #expect(await env.engine.intake.pendingIDs().count == 1)
            #expect(try await env.db.dupReview(id: review.id)?.state == .open)
        }
    }

    @Test func skipFromTheToastKeepsTheFileForUndo() async throws {
        try await DedupeKit.run(R.lookupOn(), fetcher: R.fetcher) { env in
            _ = await env.ingest([try env.pdf("preprint.pdf", title: R.title, doi: R.preprintDOI)])
            env.events.clear()
            _ = await env.ingest([try env.pdf("preprint copy.pdf", title: R.title, doi: R.preprintDOI)])
            let review = try await env.onlyOpenReview()
            #expect(review.isParked && review.relation != .newerVersion)
            let (id, choice) = try await Self.quickAnswer(env, review: review)
            #expect(choice == .skip)
            let result = try await env.engine.resolveDuplicate(reviewID: id, choice)
            #expect(await env.engine.intake.pendingIDs().isEmpty)
            let token = try #require(result.undoToken)
            #expect(try await env.engine.undo(token: token))
            #expect(await env.engine.intake.pendingIDs().count == 1)          // the staged file is back
            #expect(try await env.db.dupReview(id: review.id)?.state == .open)
            #expect(try await env.db.livePapers().count == 1)
        }
    }

    // MARK: dedupe-batch-4

    /// R: an older copy of preprint P in Recently Deleted (lowest pk); P: the live preprint (same
    /// arXiv id); Q: the live journal version (linked to the arXiv id). R matches P and Q better
    /// (or first), yet the live pair P / Q is the one to ask about.
    @Test func aRecentlyDeletedCopyDoesNotHideALivePair() async throws {
        try await OpsTestKit.run { env in
            let title = "Lineage tracing of organoid progenitors at scale"
            let r = try await OpsTestKit.addPaper(env, title: title, arxiv: "2401.00001")
            try await env.engine.softDelete(paperID: r.id)
            env.advance(60)
            let p = try await OpsTestKit.addPaper(env, title: title, arxiv: "2401.00001")
            env.advance(60)
            let q = try await OpsTestKit.addPaper(env, title: title, doi: "10.1038/s41586-024-00001-1")
            try await env.db.addDupKeys(paperPK: q.pk, [DupKey(kind: .preprintDOI, value: "arxiv:2401.00001", source: .crossref)])

            let report = try await env.engine.dedupeReport()
            #expect(report.count == 1)
            let summary = try await env.engine.checkDuplicates()
            #expect(summary.checked == 2 && summary.opened.count == 1)
            let review = try #require(try await env.db.dupReviews(state: .open).first)
            #expect(Set([review.newPaperPK, review.existingPaperPK]) == Set([p.pk, q.pk]))
            #expect(review.newPaperID == q.id)                               // the later-added one is "new"
        }
    }

    @Test func intakeLookupsStillSeeRecentlyDeleted() async throws {
        try await OpsTestKit.run { env in
            let r = try await OpsTestKit.addPaper(env, title: "Lineage tracing of organoid progenitors at scale", arxiv: "2401.00001")
            try await env.engine.softDelete(paperID: r.id)
            let subject = await DedupeIndex.subject(for: r, ctx: env.engine.ctx)
            let settings = await env.engine.ctx.settings().dedupe
            let any = await DedupeIndex.match(subject, ids: r.ids, excluding: nil, settings: settings, ctx: env.engine.ctx)
            #expect(any?.existing?.pk == r.pk)
            let live = await DedupeIndex.match(subject, ids: r.ids, excluding: nil, settings: settings, ctx: env.engine.ctx,
                                               liveOnly: true)
            #expect(live?.existing == nil)
        }
    }
}
