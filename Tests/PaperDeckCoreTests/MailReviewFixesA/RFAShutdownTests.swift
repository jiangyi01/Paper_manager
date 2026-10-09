import Foundation
import Testing
@testable import PaperDeckCore

/// Review fix runtime-5 (AgentQueue half, contract K3): from `beginShutdown()` on nothing new is
/// spawned on either lane while the run in flight finishes; `Engine.shutdown` calls it first.
///
/// Each mock run takes `runTime`: long enough that "exactly one run has started" can be observed on a
/// loaded machine. With 300 ms the 20 ms poll sometimes missed that window while CPU-bound suites ran
/// beside it, saw two or three runs, and every later expectation failed (Phase 2 fix round, ENV-1).
@Suite(.serialized) struct RFAShutdownTests {
    typealias K = MailSyncKit
    typealias R = RFAKit

    static let runTime: Duration = .seconds(3)

    @Test func beginShutdownStopsNewSpawnsButLetsTheRunningOneFinish() async throws {
        let mock = MockAgentProvider(delay: Self.runTime)
        try await R.run(mode: .mock, mock: mock) { env in
            for n in 1...3 { await env.source().add("a\(n).eml", try R.alert(n)) }
            await env.sync()
            #expect(await K.eventually { await mock.calls == 1 })
            await env.engine.agents.beginShutdown()
            #expect(await K.eventually {
                var done = 0
                for n in 1...3 where await R.triageState(env, R.alertID(n)) == .done { done += 1 }
                return done == 1
            })
            try await Task.sleep(for: .milliseconds(600))
            #expect(await mock.calls == 1)                               // the one in flight only
            #expect(await env.engine.agents.queuedTriageMessagePKs().count == 2)   // kept for the next launch
            #expect(await env.engine.agents.testConnection() == .cancelled)
            #expect(await mock.calls == 1)
        }
    }

    @Test func beginShutdownKeepsCardJobsQueued() async throws {
        let mock = MockAgentProvider(delay: Self.runTime)
        let env = try await R.make(mode: .mock, mock: mock)
        do {
            var papers: [Paper] = []
            for n in 1...2 { papers.append(try await K.addPaper(env, title: "Paper \(n)")) }
            for p in papers {
                try env.engine.ctx.texts.save(String(repeating: "Cortex development text. ", count: 200), id: p.id)
            }
            for p in papers { await env.engine.agents.enqueue(paperPK: p.pk, hold: false) }
            #expect(await K.eventually { await mock.calls == 1 })
            await env.engine.agents.beginShutdown()
            // Past the run in flight (a second run would have started by then without the shutdown).
            try await Task.sleep(for: Self.runTime + .milliseconds(800))
            #expect(await mock.calls == 1)
            var queued = 0
            for p in papers where try await env.db.activeJob(paperPK: p.pk)?.state == .queued { queued += 1 }
            #expect(queued >= 1)
        } catch {
            await env.cleanup()
            throw error
        }
        await env.cleanup()
    }
}
