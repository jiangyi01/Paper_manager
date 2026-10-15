import Foundation
import Testing
@testable import PaperDeckCore

/// Settings ▸ Library ▸ Rebuild index (`rebuildFromSidecars(replacingExisting: true)`) hard-deletes
/// every paper row and inserts it again from card.json. What hangs off the rows but isn't in
/// card.json — Q&A thread links (cascade), Explain history (set null), duplicate reviews (cascade) —
/// is linked back by paper id in the same transaction, and qa.json links back a thread that lost
/// its papers instead of skipping it (core-data-1). The rebuild refuses while the agent queue reads
/// a paper (core-data-extra-1). Mock backends only; no CLI.
@Suite(.timeLimit(.minutes(2))) struct RebuildKeepsAssistLinksTests {
    private typealias Kit = QATestKit

    @Test func rebuildKeepsQAThreadsExplainHistoryAndOpenReviews() async throws {
        try await Kit.run { env in
            let a = try await Kit.addPaper(env, title: "Zebrafish fins")
            let b = try await Kit.addPaper(env, title: "Axolotl limbs")
            let qa = await env.engine.qaService()                     // bound, as the app binds it at launch
            let single = await qa.newThread(paperIDs: [a.id], mode: .fullText)
            _ = try #require(Kit.completed(await Kit.ask(env, qa, single.id, "What is shown?")))
            let multi = await qa.newThread(paperIDs: [a.id, b.id], mode: .fullText)
            _ = try #require(Kit.completed(await Kit.ask(env, qa, multi.id, "How do they compare?")))
            await qa.flushSidecars()
            let explained = try await env.engine.saveExplanation(ExplanationRecord(
                paperID: a.id, threadID: "explain-a", source: .reader, action: "explain", lang: .en, excerpt: "x",
                answer: "Explained.", meta: AssistMeta(provider: "mock", model: "mock"), createdAt: env.clock.value))
            let review = DupReview(newPaperID: b.id, existingPaperID: a.id, band: .likely, score: 0.9,
                                   createdAt: env.clock.value, newPaperPK: b.pk, existingPaperPK: a.pk,
                                   held: DupHeldIntent(scheduleHeld: true, placement: "normal", aiQueue: true))
            try await env.db.insertDupReview(review)
            let alias = DupKey(kind: .preprintDOI, value: "10.1101/2024.01.01.000001", source: .merge)
            try await env.db.addDupKeys(paperPK: a.pk, [alias])
            await env.engine.ctx.sidecars.flush()

            let report = try await env.engine.rebuildFromSidecars(replacingExisting: true)
            #expect(report.papers == 2 && report.skipped.isEmpty)

            #expect(Set(await qa.threads(paperID: a.id).map(\.id)) == [single.id, multi.id])
            #expect(await qa.threads(paperID: b.id).map(\.id) == [multi.id])
            #expect(try await env.db.qaThread(id: multi.id)?.paperIDs == [a.id, b.id])     // order kept
            #expect(await qa.messages(threadID: single.id).map(\.role) == [.user, .assistant])
            #expect(try await env.engine.explanations(paperID: a.id, limit: 10).map(\.id) == [explained.id])
            let b2 = try await OpsTestKit.paper(env, b.id), a2 = try await OpsTestKit.paper(env, a.id)
            let reopened = try #require(try await env.db.openDupReview(newPaperPK: b2.pk))
            #expect(reopened.id == review.id && reopened.existingPaperPK == a2.pk && reopened.hold == .scheduleAndAI)
            #expect(try await env.db.dupKeys(paperPK: a2.pk).contains(alias))           // a merged copy's alias
            // The next launch's recovery finds no thread without papers; qa.json still has the thread.
            #expect(try await env.db.recoverQA().orphanThreads == 0)
            let file = try QASidecar.decode(try Data(contentsOf: Kit.qaJSON(env, a2)))
            #expect(file.threads.map(\.id) == [single.id])
        }
    }

    /// A thread whose papers were hard-deleted (an older rebuild) is linked back by its paper's
    /// qa.json instead of being skipped (and later dropped by launch recovery).
    @Test func qaJsonLinksBackAThreadThatLostItsPapers() async throws {
        try await Kit.run { env in
            let a = try await Kit.addPaper(env)
            let qa = await env.engine.qaService()
            let thread = await qa.newThread(paperIDs: [a.id], mode: .fullText)
            _ = try #require(Kit.completed(await Kit.ask(env, qa, thread.id, "What is shown?")))
            await qa.flushSidecars()
            try await env.db.transaction { db in try db.db.run("DELETE FROM qa_thread_paper") }
            #expect(await qa.threads(paperID: a.id).isEmpty)

            #expect(await env.engine.restoreQASidecars(paperIDs: [a.id]) == 1)
            #expect(await qa.threads(paperID: a.id).map(\.id) == [thread.id])
            #expect(await qa.messages(threadID: thread.id).count == 2)
            #expect(await env.engine.restoreQASidecars(paperIDs: [a.id]) == 0)       // nothing twice
            #expect(try await env.db.recoverQA().orphanThreads == 0)
        }
    }

    /// Rebuilding while a card job runs would cascade its job row away: the run's result would be
    /// dropped and the paper read again. The engine refuses (typed, worded in both languages).
    @Test func rebuildRefusesWhileAPaperIsBeingRead() async throws {
        let mock = MockAgentProvider(behavior: .hang)
        let (engine, root) = try await AgentQueueAssistHookTests.engine(agentMode: .mock, mock: mock)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = try await AgentQueueAssistHookTests.insertReadyPaper(engine)
        await engine.ctx.syncSidecar(pk: p.pk)
        await engine.agents.enqueue(paperPK: p.pk, hold: false)
        await engine.agents.start()
        #expect(await AgentQueueAssistHookTests.eventually { await engine.agents.runningPaperPK() == p.pk })

        await #expect(throws: PaperOperationError.aiReadingInProgress) {
            try await engine.rebuildFromSidecars(replacingExisting: true)
        }
        #expect(try await engine.db.paper(pk: p.pk)?.id == p.id)                 // nothing was dropped
        #expect(try await engine.db.activeJob(paperPK: p.pk)?.state == .running)
        #expect(PaperOperationError.aiReadingInProgress.message(.en).contains("nothing was rebuilt"))
        #expect(PaperOperationError.aiReadingInProgress.message(.zh).contains("未执行重建"))

        await engine.shutdown()                       // the run goes back to queued; the queue stops
        await engine.ctx.sidecars.flush()
        let report = try await engine.rebuildFromSidecars(replacingExisting: true)
        #expect(report.papers == 1)
        #expect(try await engine.db.paper(id: p.id) != nil)
        await engine.db.close()
    }
}
