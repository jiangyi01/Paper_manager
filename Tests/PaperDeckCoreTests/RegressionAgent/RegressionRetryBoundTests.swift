import Foundation
import Testing
@testable import PaperDeckCore

/// Finding 4: the per-class retry counters reset each other, so alternating overloaded / generic
/// failures respawned one paper forever. Now a job fails after 7 failures in total.
@Suite(.serialized) struct RegressionRetryBoundTests {
    private static let totalLimit = 7

    /// Advances the injected clock past every backoff until the paper failed or `calls` spawns happened.
    private static func drive(_ h: RAQueueHarness, _ fake: RAScriptedProvider, paperPK: Int64,
                              untilCalls calls: Int = .max, iterations: Int = 16) async throws {
        for _ in 0..<iterations {
            if try await h.paper(paperPK).aiState == .failed { return }
            if await fake.generateCalls >= calls { return }
            let before = await fake.generateCalls
            h.clock.update { $0 = $0.addingTimeInterval(11 * 60) }
            _ = await raEventually(.seconds(2)) {
                if await fake.generateCalls > before { return true }
                return try await h.paper(paperPK).aiState == .failed
            }
        }
    }

    /// Waits until the job is back in the queue (or failed) after the latest spawn.
    private static func settled(_ h: RAQueueHarness, _ paperPK: Int64) async -> Bool {
        await raEventually {
            let j = try await h.job(paperPK)
            return j.state == .queued || j.state == .failed
        }
    }

    /// Ported.
    @Test func alternatingOverloadedAndGenericNeverFails() async throws {
        let fake = RAScriptedProvider(fallback: .overloaded)
        for _ in 0..<20 { await fake.push(.overloaded, .generic("exit 1: API Error: 500")) }
        let h = try await RAQueueHarness.make(mode: .claude, claude: fake)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.queue.start()
        #expect(await raEventually { await fake.generateCalls >= 1 })
        try await Self.drive(h, fake, paperPK: p.pk)
        let calls = await fake.generateCalls
        #expect(calls <= 8, "one paper was spawned \(calls) times; the per-class limits never trigger")
        #expect(calls == Self.totalLimit)
        #expect(await raEventually { try await h.paper(p.pk).aiState == .failed })
        #expect(try await h.job(p.pk).state == .failed)
        await h.finish()
    }

    /// The total survives a relaunch (it is persisted, not kept in memory).
    @Test func totalFailureCountSurvivesARelaunch() async throws {
        let root = try RAQueueHarness.newRoot()
        let clock = RABox(raStart)
        let first = RAScriptedProvider(script: [.overloaded, .generic("boom"), .overloaded, .generic("boom")],
                                       fallback: .overloaded)
        let a = try await RAQueueHarness.make(mode: .claude, claude: first, root: root, clock: clock)
        let p = try await a.insertPaper()
        await a.queue.enqueue(paperPK: p.pk, hold: false)
        await a.queue.start()
        #expect(await raEventually { await first.generateCalls >= 1 })
        try await Self.drive(a, first, paperPK: p.pk, untilCalls: 4)
        #expect(await first.generateCalls == 4)
        #expect(await Self.settled(a, p.pk))
        await a.stop()

        let second = RAScriptedProvider(fallback: .overloaded)
        let b = try await RAQueueHarness.make(mode: .claude, claude: second, root: root, clock: clock)
        await b.queue.start()
        try await Self.drive(b, second, paperPK: p.pk)
        #expect(await raEventually { try await b.paper(p.pk).aiState == .failed })
        // 4 failures before the relaunch; overloaded n = 1, 2, 3 is the 7th failure in total (an
        // in-memory count would have allowed six more).
        #expect(await second.generateCalls == Self.totalLimit - 4)
        await b.finish()
    }

    /// Pure classes keep their §6.2 limits (generic fails on the 3rd failure).
    @Test func pureGenericStillFailsOnTheThirdFailure() async throws {
        let fake = RAScriptedProvider(fallback: .generic("exit 1: boom"))
        let h = try await RAQueueHarness.make(mode: .claude, claude: fake)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.queue.start()
        #expect(await raEventually { await fake.generateCalls >= 1 })
        try await Self.drive(h, fake, paperPK: p.pk)
        #expect(await raEventually { try await h.paper(p.pk).aiState == .failed })
        #expect(await fake.generateCalls == 3)
        #expect(try await h.job(p.pk).attempt == 3)
        await h.finish()
    }

    /// Re-arming a backing-off job (retry / enqueue) starts a fresh total: afterwards only the
    /// overloaded limit (6th consecutive failure) applies, not the 3 failures left before.
    @Test func reArmingResetsTheTotal() async throws {
        let fake = RAScriptedProvider(script: [.overloaded, .generic("boom"), .overloaded, .generic("boom")],
                                      fallback: .overloaded)
        let h = try await RAQueueHarness.make(mode: .claude, claude: fake)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.queue.start()
        #expect(await raEventually { await fake.generateCalls >= 1 })
        try await Self.drive(h, fake, paperPK: p.pk, untilCalls: 4)
        #expect(await Self.settled(h, p.pk))
        #expect(try await h.job(p.pk).state == .queued)
        let jobBefore = try await h.job(p.pk)
        await h.queue.retry(paperPK: p.pk)                          // same row, attempt 0
        #expect(try await h.job(p.pk).pk == jobBefore.pk)
        try await Self.drive(h, fake, paperPK: p.pk)
        #expect(await raEventually { try await h.paper(p.pk).aiState == .failed })
        #expect(await fake.generateCalls == 4 + AgentQueue.maxOverloadedRetries + 1)
        #expect(try await h.job(p.pk).attempt == AgentQueue.maxOverloadedRetries + 1)
        await h.finish()
    }
}
