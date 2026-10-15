import Foundation
import Testing
@testable import PaperDeckCore

/// Move to Recently Deleted cancels a paper's reading job. Restore — and the batch toast's Undo —
/// bring a ready paper's held / queued / running reading back (core-data-4); cancelling a job (the
/// batch delete, the AI queue's ✕) keeps the "possibly unpublished — confirm before AI reading"
/// mark (dedupe-batch-1); "Read All Now" and "Queue Existing Papers" never start a reading that
/// waits for the user's own confirmation (dedupe-batch-extra-2). Temp libraries; no CLI.
@Suite struct TrashKeepsReadingTests {
    private typealias Kit = OpsTestKit
    private typealias Holds = P1FBatchRereadHoldTests

    // MARK: core-data-4

    @Test func restoreBringsBackTheReadingItsDeleteCancelled() async throws {
        try await Kit.run { env in
            let held = try await Kit.addPaper(env, title: "Held")
            await env.engine.agents.enqueue(paperPK: held.pk, hold: true, priority: 2)
            let queued = try await Kit.addPaper(env, title: "Queued")
            await env.engine.agents.enqueue(paperPK: queued.pk, hold: false, priority: 1)
            let running = try await Kit.addPaper(env, title: "Running")
            await env.engine.agents.enqueue(paperPK: running.pk, hold: false)
            _ = try await env.db.transaction { db in               // as a claim leaves it
                guard var j = try db.activeJob(paperPK: running.pk) else { return }
                j.state = .running
                try db.updateJob(j)
                try db.modifyPaper(pk: running.pk) { $0.aiState = .running }
            }
            let idle = try await Kit.addPaper(env, title: "Never queued")

            for p in [held, queued, running, idle] {
                try await env.engine.softDelete(paperID: p.id)
                #expect(try await env.db.activeJob(paperPK: p.pk) == nil)
            }
            for p in [held, queued, running, idle] { try await env.engine.restore(paperID: p.id) }

            let h = try #require(try await env.db.activeJob(paperPK: held.pk))
            #expect(h.state == .held && h.priority == 2)
            #expect(try await Kit.paper(env, held.id).aiState == .held)
            let q = try #require(try await env.db.activeJob(paperPK: queued.pk))
            #expect(q.state == .queued && q.priority == 1)
            #expect(try await Kit.paper(env, queued.id).aiState == .queued)
            #expect(try await env.db.activeJob(paperPK: running.pk)?.state == .queued)     // starts over
            #expect(try await env.db.activeJob(paperPK: idle.pk) == nil)
            #expect(try await Kit.paper(env, idle.id).aiState == .none)
            for p in [held, queued, running, idle] { #expect(try await env.db.trashedJob(paperID: p.id) == nil) }
        }
    }

    @Test func aModeOffHoldComesBackAsAModeOffHold() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, title: "Waiting for AI to be on")
            await env.engine.agents.enqueue(paperPK: p.pk, hold: true)
            _ = try await env.db.transaction { db in
                guard var j = try db.activeJob(paperPK: p.pk) else { return }
                j.errorKind = AgentQueue.modeOffNote
                try db.updateJob(j)
                try db.modifyPaper(pk: p.pk) { $0.aiNote = AgentQueue.modeOffNote }
            }
            try await env.engine.softDelete(paperID: p.id)
            try await env.engine.restore(paperID: p.id)
            let job = try #require(try await env.db.activeJob(paperPK: p.pk))
            #expect(job.state == .held && job.errorKind == AgentQueue.modeOffNote)
            #expect(try await Kit.paper(env, p.id).aiNote == AgentQueue.modeOffNote)
        }
    }

    @Test func aPurgeForgetsTheRecordedReading() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, title: "Gone for good")
            await env.engine.agents.enqueue(paperPK: p.pk, hold: true)
            try await env.engine.softDelete(paperID: p.id)
            #expect(try await env.db.trashedJob(paperID: p.id)?.state == .held)
            env.advance(Engine.recentlyDeletedRetention + 60)
            let trash = DedupeKit.Trash()
            #expect(try await env.engine.purgeExpired(trash: trash.function) == [p.id])
            #expect(try await env.db.trashedJob(paperID: p.id) == nil)
        }
    }

    // MARK: core-data-4 + dedupe-batch-1 (the batch path)

    @Test func batchTrashThenUndoKeepsReadingsAndTheUnpublishedMark() async throws {
        try await Kit.run { env in
            let manuscript = try await Holds.heldUnpublished(env, title: "Manuscript")
            let queued = try await Kit.addPaper(env, title: "Queued")
            await env.engine.agents.enqueue(paperPK: queued.pk, hold: false, priority: 3)

            let out = try await env.engine.applyBatch(.moveToTrash, paperIDs: [manuscript.id, queued.id])
            #expect(out.applied.count == 2)
            #expect(try await Kit.paper(env, manuscript.id).aiNote == ImportAnnotation.unpublishedHoldNote)
            #expect(try await env.engine.undoBatch(token: try #require(out.undoToken)))

            let back = try await Kit.paper(env, manuscript.id)
            #expect(back.isLive && back.aiState == .held && back.aiNote == ImportAnnotation.unpublishedHoldNote)
            #expect(try await env.db.activeJob(paperPK: manuscript.pk)?.state == .held)
            #expect(try await env.engine.rereadHolds(paperIDs: [manuscript.id])
                    == [RereadHeld(paperID: manuscript.id, reason: .possiblyUnpublished)])
            let q = try #require(try await env.db.activeJob(paperPK: queued.pk))
            #expect(q.state == .queued && q.priority == 3)
            Holds.aiOn(env)
            let reread = try await env.engine.requestReread(paperIDs: [manuscript.id])
            #expect(reread.applied.isEmpty && reread.held.map(\.reason) == [.possiblyUnpublished])
            #expect(try await env.db.activeJob(paperPK: manuscript.pk)?.state == .held)
        }
    }

    /// Restoring later from Recently Deleted (after the undo window) does the same.
    @Test func batchTrashThenRestoreLaterKeepsTheHeldReading() async throws {
        try await Kit.run { env in
            let manuscript = try await Holds.heldUnpublished(env, title: "Manuscript")
            _ = try await env.engine.applyBatch(.moveToTrash, paperIDs: [manuscript.id])
            env.advance(3600)
            _ = try await env.engine.applyBatch(.restore, paperIDs: [manuscript.id])
            let back = try await Kit.paper(env, manuscript.id)
            #expect(back.aiState == .held && back.aiNote == ImportAnnotation.unpublishedHoldNote)
            #expect(try await env.db.activeJob(paperPK: manuscript.pk)?.state == .held)
        }
    }

    /// The AI queue popover's ✕ cancels the job, not the fact that the file may be unpublished.
    @Test func cancellingAHeldReadingKeepsTheUnpublishedMark() async throws {
        try await Kit.run { env in
            let manuscript = try await Holds.heldUnpublished(env, title: "Manuscript")
            let plain = try await Kit.addPaper(env, title: "Plain")
            await env.engine.agents.enqueue(paperPK: plain.pk, hold: true)
            _ = try await env.db.transaction { db in try db.modifyPaper(pk: plain.pk) { $0.aiNote = "x" } }
            await env.engine.agents.cancel(paperPK: manuscript.pk)
            await env.engine.agents.cancel(paperPK: plain.pk)
            let m = try await Kit.paper(env, manuscript.id)
            #expect(m.aiState == .none && m.aiNote == ImportAnnotation.unpublishedHoldNote)
            #expect(try await Kit.paper(env, plain.id).aiNote == nil)                 // a job-state note goes
            #expect(try await env.engine.rereadHolds(paperIDs: [manuscript.id]).map(\.reason) == [.possiblyUnpublished])
        }
    }

    // MARK: dedupe-batch-extra-2

    @Test func readAllNowAndQueueExistingLeaveConfirmationHoldsHeld() async throws {
        try await Kit.run { env in
            let manuscript = try await Holds.heldUnpublished(env, title: "Manuscript")
            let old = try await Kit.addPaper(env, title: "Old version")
            let copy = try await Kit.addPaper(env, title: "New version", mode: .none)
            await env.engine.agents.enqueue(paperPK: copy.pk, hold: true)
            try await env.db.insertDupReview(DupReview(newPaperID: copy.id, existingPaperID: old.id, band: .likely, score: 0.9,
                                                       createdAt: env.clock.value, newPaperPK: copy.pk, existingPaperPK: old.pk,
                                                       held: DupHeldIntent(scheduleHeld: true, placement: "normal", aiQueue: true)))
            let batchHeld = try await Kit.addPaper(env, title: "Held in an import batch")
            await env.engine.agents.enqueue(paperPK: batchHeld.pk, hold: true)
            let never = try await Kit.addPaper(env, title: "Never AI")
            try await env.engine.setPaperPolicy(paperID: never.id, confidential: false, neverAI: true)
            let fresh = try await Kit.addPaper(env, title: "Never read")
            Holds.aiOn(env)

            let readAll = await env.engine.releaseHeldReadings()
            #expect(readAll.released == 1)
            #expect(Set(readAll.held.map(\.paperID)) == [manuscript.id, copy.id])
            #expect(readAll.held.first { $0.paperID == manuscript.id }?.reason == .possiblyUnpublished)
            #expect(readAll.held.first { $0.paperID == copy.id }?.reason == .duplicateReview)
            #expect(try await env.db.activeJob(paperPK: batchHeld.pk)?.state == .queued)
            #expect(try await env.db.activeJob(paperPK: manuscript.pk)?.state == .held)
            #expect(try await Kit.paper(env, manuscript.id).aiNote == ImportAnnotation.unpublishedHoldNote)
            #expect(try await env.db.activeJob(paperPK: copy.pk)?.state == .held)

            let existing = await env.engine.queueExistingPapers([never.pk, fresh.pk])
            #expect(existing.released == 1)
            #expect(Set(existing.held.map(\.paperID)) == [manuscript.id, copy.id, never.id])
            #expect(existing.held.first { $0.paperID == never.id }?.reason == .neverAI)
            #expect(try await env.db.activeJob(paperPK: fresh.pk)?.state == .queued)
            #expect(try await env.db.activeJob(paperPK: never.pk) == nil)
            #expect(try await env.db.activeJob(paperPK: manuscript.pk)?.state == .held)
        }
    }
}
