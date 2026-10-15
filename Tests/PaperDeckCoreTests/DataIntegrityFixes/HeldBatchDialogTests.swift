import Foundation
import Testing
@testable import PaperDeckCore

/// Lane 1 review: the last batch path that released held readings unfiltered (dedupe-batch-extra-2's
/// remaining call site). The batch dialog's [Read All] — after a large import, or after a click on
/// one paper's "awaiting confirmation" badge, which lists every held paper — called
/// `AgentQueue.releaseHeld(paperPKs:)` for all of them, so a possibly unpublished manuscript or a
/// paper under duplicate review was read without its own confirmation. It now goes through
/// `Engine.releaseHeldReadings(paperIDs:confirmed:)`: those papers keep their held job and note and
/// are reported, and only the paper whose badge was clicked counts as confirmed. Also: a removal
/// the undo window waits for, scheduled again, runs on the newer timer only (`UndoCleanups`).
@Suite struct HeldBatchDialogTests {
    private typealias Kit = OpsTestKit
    private typealias Holds = P1FBatchRereadHoldTests

    @Test func readAllLeavesConfirmationHoldsHeldAndConfirmsOnlyTheClickedPaper() async throws {
        try await Kit.run { env in
            let manuscript = try await Holds.heldUnpublished(env, title: "Manuscript")
            let other = try await Holds.heldUnpublished(env, title: "Another manuscript")
            let old = try await Kit.addPaper(env, title: "Old version")
            let copy = try await Kit.addPaper(env, title: "New version", mode: .none)
            await env.engine.agents.enqueue(paperPK: copy.pk, hold: true)
            try await env.db.insertDupReview(DupReview(newPaperID: copy.id, existingPaperID: old.id, band: .likely, score: 0.9,
                                                       createdAt: env.clock.value, newPaperPK: copy.pk, existingPaperPK: old.pk,
                                                       held: DupHeldIntent(scheduleHeld: true, placement: "normal", aiQueue: true)))
            let batchHeld = try await Kit.addPaper(env, title: "Held in an import batch")
            await env.engine.agents.enqueue(paperPK: batchHeld.pk, hold: true)
            let idle = try await Kit.addPaper(env, title: "No reading")
            Holds.aiOn(env)

            // An import's dialog: no paper was confirmed by a click.
            let imported = await env.engine.releaseHeldReadings(paperIDs: [manuscript.id, copy.id, batchHeld.id, idle.id])
            #expect(imported.released == 1)
            #expect(Set(imported.held.map(\.paperID)) == [manuscript.id, copy.id])
            #expect(imported.held.first { $0.paperID == manuscript.id }?.reason == .possiblyUnpublished)
            #expect(imported.held.first { $0.paperID == copy.id }?.reason == .duplicateReview)
            #expect(try await env.db.activeJob(paperPK: batchHeld.pk)?.state == .queued)
            #expect(try await env.db.activeJob(paperPK: manuscript.pk)?.state == .held)
            #expect(try await Kit.paper(env, manuscript.id).aiNote == ImportAnnotation.unpublishedHoldNote)
            #expect(try await env.db.activeJob(paperPK: copy.pk)?.state == .held)
            #expect(try await env.db.activeJob(paperPK: idle.pk) == nil)               // nothing created

            // The badge of `manuscript` clicked: the dialog lists every held paper; [Read All]
            // confirms that one only.
            let clicked = await env.engine.releaseHeldReadings(paperIDs: [manuscript.id, other.id, copy.id],
                                                               confirmed: manuscript.id.uppercased())
            #expect(clicked.released == 1)
            #expect(Set(clicked.held.map(\.paperID)) == [other.id, copy.id])
            #expect(try await env.db.activeJob(paperPK: manuscript.pk)?.state == .queued)
            #expect(try await Kit.paper(env, manuscript.id).aiNote == nil)
            #expect(try await env.db.activeJob(paperPK: other.pk)?.state == .held)
            #expect(try await Kit.paper(env, other.id).aiNote == ImportAnnotation.unpublishedHoldNote)
            #expect(try await env.db.activeJob(paperPK: copy.pk)?.state == .held)
        }
    }

    @Test func aNeverAIPaperStaysHeldEvenWhenItsBadgeWasClicked() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, title: "Never AI")
            await env.engine.agents.enqueue(paperPK: p.pk, hold: true)
            try await env.engine.setPaperPolicy(paperID: p.id, confidential: false, neverAI: true)
            Holds.aiOn(env)
            let out = await env.engine.releaseHeldReadings(paperIDs: [p.id], confirmed: p.id)
            #expect(out.released == 0 && out.held == [RereadHeld(paperID: p.id, reason: .neverAI)])
            #expect(try await env.db.activeJob(paperPK: p.pk)?.state == .held)
        }
    }

    /// The App releases held readings unfiltered only for one paper at a time (the detail bar's
    /// Start Now, the AI queue row's Read Now): every batch surface goes through the engine's
    /// filtered `releaseHeldReadings` / `queueExistingPapers`.
    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func noAppSurfaceReleasesABatchUnfiltered() throws {
        let hits = try LintRepo.grep(#"releaseHeld\(paperPKs:"#, under: "Sources/PaperDeck")
        #expect(!hits.isEmpty)
        for hit in hits { #expect(hit.text.contains("releaseHeld(paperPKs: [pk])"), "\(hit)") }
        let dialog = try String(contentsOf: LintRepo.url("Sources/PaperDeck/Views/Library/BatchDialog.swift"), encoding: .utf8)
        #expect(dialog.contains("engine.releaseHeldReadings(paperIDs: ids, confirmed: confirmed)"))
        let menu = try String(contentsOf: LintRepo.url("Sources/PaperDeck/Views/Library/PaperContextMenu.swift"), encoding: .utf8)
        #expect(menu.contains("heldForAI: ids, confirmedPaperID: paper.id)"))
    }

    /// A key scheduled again (a copy merged, undone and merged again; a parked file skipped,
    /// restored and skipped again) runs its removal on the newer timer only: the older one must
    /// not take away what the newer undo needs.
    @Test func aRescheduledRemovalRunsOnTheNewerTimerOnly() async throws {
        let cleanups = UndoCleanups()
        let early = Kit.Box(false), late = Kit.Box(false)
        await cleanups.schedule("merged.x", after: 0.01) { early.value = true }
        await cleanups.schedule("merged.x", after: 3600) { late.value = true }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!early.value, "the superseded timer removed the material")
        #expect(!late.value)
        #expect(await cleanups.state("merged.x").pending)
        // A key scheduled once still runs.
        let once = Kit.Box(false)
        await cleanups.schedule("parked.p", after: 0.01) { once.value = true }
        for _ in 0..<200 where !once.value { try await Task.sleep(for: .milliseconds(25)) }
        #expect(once.value)
        #expect(!(await cleanups.state("parked.p").pending))
    }
}
