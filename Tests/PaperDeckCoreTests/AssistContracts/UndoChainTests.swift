import Foundation
import Testing
@testable import PaperDeckCore

/// The toast's [Undo] (`Toast.Action.undo(token:)` → `Engine.undo(token:)`) reaches every ledger:
/// skip-today, a multi-select batch (Slice C, R-C1-1) and a duplicate decision (Slice B, R-B-1).
/// Each token is single-use and unknown tokens are refused.
@Suite(.serialized) struct UndoChainTests {
    private typealias Kit = OpsTestKit

    @Test func theToastUndoReachesABatch() async throws {
        try await Kit.run { env in
            let a = try await Kit.addPaper(env, title: "A")
            let b = try await Kit.addPaper(env, title: "B")
            let before = try await Kit.paper(env, a.id).priority
            let out = try await env.engine.applyBatch(.setPriority(.high), paperIDs: [a.id, b.id])
            let token = try #require(out.undoToken)
            #expect(try await Kit.paper(env, a.id).priority == .high)
            #expect(try await env.engine.undo(token: token))
            #expect(try await Kit.paper(env, a.id).priority == before)
            #expect(try await Kit.paper(env, b.id).priority == before)
            #expect(try await !env.engine.undo(token: token))                    // single use
            #expect(try await !env.engine.undo(token: "no-such-token"))
        }
    }

    @Test func theToastUndoReachesADuplicateDecision() async throws {
        try await DedupeKit.run { env in
            let (_, n, review) = try await DupResolutionTests.held(env)
            let r = try await env.engine.resolveDuplicate(reviewID: review.id, .skip)
            let token = try #require(r.undoToken)
            #expect(try await env.paper(n.id).isDeleted)                         // skipped: the copy is in Recently Deleted
            #expect(try await env.engine.undo(token: token))
            #expect(try await env.paper(n.id).isLive)                            // live again
            #expect(try await env.db.dupReview(id: review.id)?.state == .open)
            #expect(try await !env.engine.undo(token: token))
        }
    }

    /// R-A1-1: the engine wires its lane — a turn's status reaches the event hub (`.assistStatus`).
    @Test func theEnginesLanePublishesItsStatus() async throws {
        var s = OpsTestKit.settings()
        s.assist.mode = .mock
        try await Kit.run(s) { env in
            let events = BatchOperationTests.Sink(env.engine.events.subscribe())
            let request = AssistRequest(surface: .explain, systemPrompt: "system", turnText: "<selection>x</selection>",
                                        model: "haiku", session: .oneShot,
                                        limits: AssistLimits.defaults(for: .explain, provider: .claude))
            var turn: [AssistEvent] = []
            for await e in await env.engine.assist.submit(request, ticket: .mint(.box, surface: .explain, now: env.clock.value)) { turn.append(e) }
            guard case .done? = turn.last else { Issue.record("no done: \(turn)"); return }
            let statuses = await events.settle().compactMap { if case .assistStatus(let st) = $0 { return st }; return nil }
            #expect(!statuses.isEmpty)
            #expect(await env.engine.assist.registeredModes.contains(.mock))
        }
    }
}
