import Foundation
import Testing
@testable import PaperDeckCore

/// Phase 1 fix F1: batch "Read with AI" (`Engine.requestReread(paperIDs:)`) never sends a paper
/// that waits for the user's own confirmation — held as possibly unpublished (`ai_note =
/// mail_unpublished`), under an open duplicate review that holds it, marked "Unpublished /
/// confidential" or "Never use AI". Those keep their held job and are reported in `held` with a
/// reason; the confirmation sheet lists them first (`rereadHolds(paperIDs:)`). Probes V1 / V2 of the
/// selection-assist verifier, inverted. Temp libraries, agent.mode mock.
@Suite struct P1FBatchRereadHoldTests {
    typealias Kit = OpsTestKit

    static func aiOn(_ env: Kit.Env) {
        var s = env.settings.value
        s.agentMode = .mock
        env.settings.value = s
    }

    /// A paper as the mail import leaves a person's PDF without DOI / arXiv id: held job + note.
    static func heldUnpublished(_ env: Kit.Env, title: String) async throws -> Paper {
        let p = try await Kit.addPaper(env, title: title)
        await env.engine.agents.enqueue(paperPK: p.pk, hold: true)
        _ = try await env.db.transaction { db in
            try db.modifyPaper(pk: p.pk) { $0.aiNote = ImportAnnotation.unpublishedHoldNote }
        }
        return try await Kit.paper(env, p.id)
    }

    @Test func aPossiblyUnpublishedPaperStaysHeld() async throws {
        try await Kit.run { env in
            let a = try await Self.heldUnpublished(env, title: "Unpublished manuscript")
            let b = try await Kit.addPaper(env, title: "Published paper", doi: "10.1000/xyz")
            #expect(a.aiState == .held && a.aiNote == ImportAnnotation.unpublishedHoldNote)
            Self.aiOn(env)
            let out = try await env.engine.requestReread(paperIDs: [a.id, b.id])
            #expect(out.applied == [b.id] && out.skipped.isEmpty)
            #expect(out.held == [RereadHeld(paperID: a.id, reason: .possiblyUnpublished)])
            #expect(out.heldCount(.possiblyUnpublished) == 1 && out.heldCount(.duplicateReview) == 0)
            let after = try await Kit.paper(env, a.id)
            #expect(after.aiState == .held && after.aiNote == ImportAnnotation.unpublishedHoldNote)
            #expect(try await env.db.activeJob(paperPK: a.pk)?.state == .held)
            #expect(try await env.db.activeJob(paperPK: b.pk)?.state == .queued)
        }
    }

    @Test func aPaperUnderAnOpenDuplicateReviewStaysHeld() async throws {
        try await Kit.run { env in
            let old = try await Kit.addPaper(env, title: "Old version")
            let new = try await Kit.addPaper(env, title: "New version", mode: .none)
            await env.engine.agents.enqueue(paperPK: new.pk, hold: true)
            let review = DupReview(newPaperID: new.id, existingPaperID: old.id, band: .likely, score: 0.9,
                                   createdAt: env.clock.value, newPaperPK: new.pk, existingPaperPK: old.pk,
                                   held: DupHeldIntent(scheduleHeld: true, placement: "normal", aiQueue: true))
            try await env.db.insertDupReview(review)
            Self.aiOn(env)
            let out = try await env.engine.requestReread(paperIDs: [old.id, new.id])
            #expect(out.applied == [old.id])
            #expect(out.held == [RereadHeld(paperID: new.id, reason: .duplicateReview)])
            #expect(try await env.db.activeJob(paperPK: new.pk)?.state == .held)    // no quota spent on a copy
            #expect(try await env.db.openDupReview(newPaperPK: new.pk) != nil)
        }
    }

    /// A review opened by Check for Duplicates (likely, but nothing held at intake) holds nothing —
    /// the ribbon says so — so the batch reads the paper (pf verification regression #2).
    @Test func aLibraryCheckReviewDoesNotHold() async throws {
        try await Kit.run { env in
            let old = try await Kit.addPaper(env, title: "Old version")
            let new = try await Kit.addPaper(env, title: "New version")
            let review = DupReview(newPaperID: new.id, existingPaperID: old.id, band: .likely, score: 0.9,
                                   createdAt: env.clock.value, newPaperPK: new.pk, existingPaperPK: old.pk)
            try await env.db.insertDupReview(review)
            #expect(review.holdsNewPaper && review.hold == .none)
            Self.aiOn(env)
            let out = try await env.engine.requestReread(paperIDs: [new.id])
            #expect(out.applied == [new.id])
            #expect(out.held.isEmpty)
        }
    }

    /// A "possible" match only asks — it holds nothing, so the batch reads the paper.
    @Test func aPossibleMatchDoesNotHold() async throws {
        try await Kit.run { env in
            let old = try await Kit.addPaper(env, title: "Old version")
            let new = try await Kit.addPaper(env, title: "Similar title")
            let review = DupReview(newPaperID: new.id, existingPaperID: old.id, band: .possible, score: 0.5,
                                   createdAt: env.clock.value, newPaperPK: new.pk, existingPaperPK: old.pk)
            try await env.db.insertDupReview(review)
            #expect(!review.holdsNewPaper)
            Self.aiOn(env)
            let out = try await env.engine.requestReread(paperIDs: [new.id])
            #expect(out.applied == [new.id] && out.held.isEmpty)
        }
    }

    @Test func neverAIAndConfidentialPapersAreLeftOutAndTheStrongestReasonWins() async throws {
        try await Kit.run { env in
            let never = try await Kit.addPaper(env, title: "Never")
            let secret = try await Kit.addPaper(env, title: "Confidential")
            let both = try await Self.heldUnpublished(env, title: "Unpublished and never")
            let plain = try await Kit.addPaper(env, title: "Plain")
            try await env.engine.setPaperPolicy(paperID: never.id, confidential: false, neverAI: true)
            try await env.engine.setPaperPolicy(paperID: secret.id, confidential: true, neverAI: false)
            try await env.engine.setPaperPolicy(paperID: both.id, confidential: true, neverAI: true)
            Self.aiOn(env)
            let ids = [never.id, secret.id, both.id, plain.id]
            // The sheet's preview: the same list, nothing changed.
            let preview = try await env.engine.rereadHolds(paperIDs: ids + ["missing"])
            #expect(preview == [RereadHeld(paperID: never.id, reason: .neverAI),
                                RereadHeld(paperID: secret.id, reason: .confidential),
                                RereadHeld(paperID: both.id, reason: .neverAI)])
            #expect(try await env.db.activeJob(paperPK: plain.pk) == nil)
            let out = try await env.engine.requestReread(paperIDs: ids)
            #expect(out.applied == [plain.id] && out.held == preview)
            for p in [never, secret] { #expect(try await env.db.activeJob(paperPK: p.pk) == nil) }
            #expect(try await env.db.activeJob(paperPK: both.pk)?.state == .held)
            #expect(try await env.db.activeJob(paperPK: plain.pk)?.state == .queued)
        }
    }

    /// The notice names only the papers that were queued; nothing is announced when all were held.
    @Test func theNoticeListsOnlyQueuedPapers() async throws {
        try await Kit.run { env in
            let a = try await Self.heldUnpublished(env, title: "Held")
            Self.aiOn(env)
            let events = BatchOperationTests.Sink(env.engine.events.subscribe())
            let out = try await env.engine.requestReread(paperIDs: [a.id])
            #expect(out.applied.isEmpty && out.held.count == 1)
            #expect(BatchOperationTests.notices(await events.settle()).isEmpty)
        }
    }
}
