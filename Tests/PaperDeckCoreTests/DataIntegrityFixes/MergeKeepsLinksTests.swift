import Foundation
import Testing
@testable import PaperDeckCore

/// Merging a duplicate (Keep the new one, Re-read with the new file, the email's Use this
/// version) hard-deletes the copy. Its Q&A thread links and its keep-apart decisions (`dup_pair`)
/// move to the kept paper inside the merge transaction, Undo moves them back onto the re-created
/// copy, both papers' qa.json follow, and launch recovery finds no thread without papers
/// (dedupe-batch-2). Mock backends only.
@Suite(.timeLimit(.minutes(2))) struct MergeKeepsLinksTests {
    private typealias Kit = QATestKit

    @Test func aMergeMovesTheCopysThreadsAndPairsAndUndoMovesThemBack() async throws {
        try await Kit.run { env in
            let e = try await Kit.addPaper(env, title: "Cortex atlas")              // kept (earlier)
            let n = try await Kit.addPaper(env, title: "Cortex atlas revised")      // merged away
            let x = try await Kit.addPaper(env, title: "Unrelated paper")
            let qa = await env.engine.qaService()
            let onCopy = await qa.newThread(paperIDs: [n.id], mode: .fullText)
            _ = try #require(Kit.completed(await Kit.ask(env, qa, onCopy.id, "What is shown?")))
            let withX = await qa.newThread(paperIDs: [n.id, x.id], mode: .fullText)
            _ = try #require(Kit.completed(await Kit.ask(env, qa, withX.id, "How do they compare?")))
            try await env.db.setDupPair(n.pk, x.pk, decision: "distinct", relation: nil, decidedBy: "user",
                                        at: env.clock.value)
            let review = DupReview(newPaperID: n.id, existingPaperID: e.id, band: .likely, score: 0.9,
                                   createdAt: env.clock.value, newPaperPK: n.pk, existingPaperPK: e.pk, origin: .scan)
            try await env.db.insertDupReview(review)

            let done = try await env.engine.resolveDuplicate(reviewID: review.id, .keepNew(reread: false))
            #expect(try await env.db.paper(id: n.id) == nil)
            #expect(Set(await qa.threads(paperID: e.id).map(\.id)) == [onCopy.id, withX.id])
            #expect(try await env.db.qaThread(id: withX.id)?.paperIDs == [e.id, x.id])
            #expect(try await env.db.dupPair(e.pk, x.pk)?.decision == "distinct")
            #expect(try await env.db.dupPairPartnerIDs(paperPK: x.pk) == [e.id])
            await qa.flushSidecars()
            let kept = try await OpsTestKit.paper(env, e.id)
            #expect(try QASidecar.decode(try Data(contentsOf: Kit.qaJSON(env, kept))).threads.map(\.id) == [onCopy.id])
            #expect(try await env.db.recoverQA().orphanThreads == 0)

            #expect(try await env.engine.undoDuplicateResolution(token: try #require(done.undoToken)))
            let copy = try await OpsTestKit.paper(env, n.id)
            #expect(Set(await qa.threads(paperID: n.id).map(\.id)) == [onCopy.id, withX.id])
            #expect(await qa.threads(paperID: e.id).isEmpty)
            #expect(try await env.db.qaThread(id: withX.id)?.paperIDs == [n.id, x.id])
            #expect(try await env.db.dupPair(copy.pk, x.pk)?.decision == "distinct")
            #expect(try await env.db.dupPair(e.pk, x.pk) == nil)
            #expect(try await env.db.recoverQA().orphanThreads == 0)
            await qa.flushSidecars()
            #expect(!FileManager.default.fileExists(atPath: Kit.qaJSON(env, try await OpsTestKit.paper(env, e.id)).path))
            #expect(try QASidecar.decode(try Data(contentsOf: Kit.qaJSON(env, copy))).threads.map(\.id) == [onCopy.id])
        }
    }

    /// A thread both papers were in keeps the kept paper's place (and comes back whole on undo); a
    /// decision the kept paper already had with a partner wins over the copy's.
    @Test func sharedThreadsAndExistingDecisionsAreKept() async throws {
        try await Kit.run { env in
            let e = try await Kit.addPaper(env, title: "Cortex atlas")
            let n = try await Kit.addPaper(env, title: "Cortex atlas revised")
            let x = try await Kit.addPaper(env, title: "Unrelated paper")
            let qa = await env.engine.qaService()
            let shared = await qa.newThread(paperIDs: [e.id, n.id], mode: .fullText)
            _ = try #require(Kit.completed(await Kit.ask(env, qa, shared.id, "Same paper?")))
            try await env.db.setDupPair(e.pk, x.pk, decision: "related", relation: "comment", decidedBy: "user",
                                        at: env.clock.value)
            try await env.db.setDupPair(n.pk, x.pk, decision: "distinct", relation: nil, decidedBy: "user",
                                        at: env.clock.value)
            let review = DupReview(newPaperID: n.id, existingPaperID: e.id, band: .likely, score: 0.9,
                                   createdAt: env.clock.value, newPaperPK: n.pk, existingPaperPK: e.pk, origin: .scan)
            try await env.db.insertDupReview(review)

            let done = try await env.engine.resolveDuplicate(reviewID: review.id, .keepNew(reread: false))
            #expect(try await env.db.qaThread(id: shared.id)?.paperIDs == [e.id])
            #expect(try await env.db.dupPair(e.pk, x.pk)?.decision == "related")

            #expect(try await env.engine.undoDuplicateResolution(token: try #require(done.undoToken)))
            let copy = try await OpsTestKit.paper(env, n.id)
            #expect(try await env.db.qaThread(id: shared.id)?.paperIDs == [e.id, n.id])
            #expect(try await env.db.dupPair(e.pk, x.pk)?.decision == "related")     // the kept paper's own stays
            #expect(try await env.db.dupPair(copy.pk, x.pk)?.decision == "distinct")
        }
    }
}
