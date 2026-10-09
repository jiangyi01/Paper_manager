import Foundation
import Testing
@testable import PaperDeckCore

/// Finding 9: a rebuild restored transient ai_state (held/queued/…) from card.json without any
/// agent_job row, so the paper was stuck forever (releaseHeld / the queue never saw it).
@Suite(.serialized) struct RegressionRebuildJobsTests {
    private typealias Kit = OpsTestKit

    /// Ported (assertion adapted to the fix: the held paper gets its held job back).
    @Test func rebuildLeavesHeldPapersWithoutJobs() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, title: "Held paper")
            await env.engine.agents.enqueue(paperPK: p.pk, hold: true)
            #expect(try await Kit.paper(env, p.id).aiState == .held)
            await env.engine.ctx.sidecars.flush()
            _ = try await env.engine.rebuildFromSidecars(replacingExisting: true)
            let rebuilt = try await Kit.paper(env, p.id)
            let held = try await env.db.jobs(states: [.held, .queued])
            #expect(rebuilt.aiState == .held)
            #expect(held.map(\.paperPK) == [rebuilt.pk], "paper shows ai_state=held but has no active job")
            await env.engine.agents.releaseHeld(paperPKs: nil)
            let afterRelease = try await Kit.paper(env, p.id)
            #expect(afterRelease.aiState == .queued, "releaseHeld could not queue the rebuilt paper")
            #expect(try await env.db.activeJob(paperPK: rebuilt.pk)?.state == .queued)
        }
    }

    /// Every transient state comes back with a matching active job; mode_off holds keep their note,
    /// a crashed `running` becomes queued, and terminal states get no job.
    @Test func rebuildRecreatesJobsForEveryWaitingState() async throws {
        try await Kit.run { env in
            let states: [(AIState, String?)] = [(.held, AgentQueue.modeOffNote), (.held, nil), (.queued, nil),
                                                (.running, nil), (.limited, nil), (.needsLogin, "需登录 Claude"),
                                                (.failed, "超时"), (.none, nil)]
            var ids: [String: (AIState, String?)] = [:]
            for (i, (state, note)) in states.enumerated() {
                let p = try await Kit.addPaper(env, title: "State \(i)")
                _ = try await env.db.modifyPaper(pk: p.pk, now: env.clock.value) { $0.aiState = state; $0.aiNote = note }
                await env.engine.ctx.syncSidecar(pk: p.pk)
                ids[p.id] = (state, note)
            }
            await env.engine.ctx.sidecars.flush()
            _ = try await env.engine.rebuildFromSidecars(replacingExisting: true)
            for (id, (state, note)) in ids {
                let row = try await Kit.paper(env, id)
                let job = try await env.db.activeJob(paperPK: row.pk)
                switch state {
                case .held:
                    #expect(row.aiState == .held && row.aiNote == note)
                    #expect(job?.state == .held)
                    #expect(job?.errorKind == (note == AgentQueue.modeOffNote ? AgentQueue.modeOffNote : nil))
                case .queued, .limited, .needsLogin:
                    #expect(row.aiState == state && row.aiNote == note)
                    #expect(job?.state == .queued)
                case .running:
                    #expect(row.aiState == .queued && row.aiNote == nil)
                    #expect(job?.state == .queued)
                default:
                    #expect(row.aiState == state)
                    #expect(job == nil)
                }
            }
        }
    }

    /// Safety net at queue start: a paper whose ai_state says "waiting" but has no active job
    /// (older rebuilds, adopted folders) gets its job back.
    @Test func queueStartReconcilesWaitingPapersWithoutJobs() async throws {
        let h = try await RAQueueHarness.make(mode: .off, claude: RAScriptedProvider())
        let held = try await h.insertPaper(title: "held.pdf")
        let queued = try await h.insertPaper(title: "queued.pdf")
        let done = try await h.insertPaper(title: "done.pdf")
        _ = try await h.db.modifyPaper(pk: held.pk, now: h.clock.value) { $0.aiState = .held; $0.aiNote = nil }
        _ = try await h.db.modifyPaper(pk: queued.pk, now: h.clock.value) { $0.aiState = .needsLogin; $0.aiNote = "x" }
        _ = try await h.db.modifyPaper(pk: done.pk, now: h.clock.value) { $0.aiState = .done }
        await h.queue.start()
        #expect(try await h.db.activeJob(paperPK: held.pk)?.state == .held)
        // mode off: the reconciled queued job is held (mode_off) by the first pass, never spawned.
        #expect(await raEventually { try await h.db.activeJob(paperPK: queued.pk)?.state == .held })
        #expect(try await h.paper(queued.pk).aiNote == AgentQueue.modeOffNote)
        #expect(try await h.db.activeJob(paperPK: done.pk) == nil)
        await h.finish()
    }
}
