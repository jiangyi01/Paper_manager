import Foundation
import Testing
@testable import PaperDeckCore

/// The `qa_*` tables (DQ §8): threads with their papers in order, messages in order, updates,
/// deletion and its cascades, the latency samples, and the sidecar codec. Temp libraries.
@Suite struct DatabaseQATests {
    private typealias Kit = OpsTestKit

    @Test func threadsKeepTheirPapersInOrderAndListNewestFirst() async throws {
        try await Kit.run { env in
            let a = try await Kit.addPaper(env, title: "A")
            let b = try await Kit.addPaper(env, title: "B")
            let t0 = env.clock.value
            let multi = try await env.db.insertQAThread(QAThread(paperIDs: [b.id, a.id], title: "m", mode: .excerpts, createdAt: t0,
                                                                 language: .zh))
            #expect(multi.paperIDs == [b.id, a.id] && multi.scope == .multi && multi.mode == .excerpts && multi.language == .zh)
            #expect(multi.persisted)
            let single = try await env.db.insertQAThread(QAThread(paperIDs: [a.id], title: "s", mode: .fullText,
                                                                  createdAt: t0.addingTimeInterval(60)))
            #expect(try await env.db.qaThreads(paperID: a.id).map(\.id) == [single.id, multi.id])
            #expect(try await env.db.qaThreads(paperID: a.id, scope: .paper).map(\.id) == [single.id])
            #expect(try await env.db.qaThreads(paperID: b.id).map(\.id) == [multi.id])
            try await env.db.updateQAThread(id: multi.id, title: "renamed", language: .en, mode: .cards,
                                            updatedAt: t0.addingTimeInterval(120))
            let updated = try #require(try await env.db.qaThread(id: multi.id))
            #expect(updated.title == "renamed" && updated.language == .en && updated.mode == .cards)
            #expect(try await env.db.qaThreads(paperID: a.id).map(\.id) == [multi.id, single.id])
            try await env.db.updateQAThread(id: multi.id, archived: true)
            #expect(try await env.db.qaThreads(paperID: a.id).map(\.id) == [single.id])
            #expect(try await env.db.qaThreads(paperID: a.id, includeArchived: true).count == 2)

            await #expect(throws: DatabaseError.duplicate("qa thread \(single.id)")) {
                try await env.db.insertQAThread(single)
            }
            await #expect(throws: DatabaseError.notFound("paper nope")) {
                try await env.db.insertQAThread(QAThread(paperIDs: ["nope"], title: "x", mode: .fullText, createdAt: t0))
            }
            await #expect(throws: DatabaseError.notFound("qa thread zz")) { try await env.db.updateQAThread(id: "zz", title: "x") }
        }
    }

    @Test func messagesAreOrderedUpdatedAndDeleted() async throws {
        try await Kit.run { env in
            let a = try await Kit.addPaper(env)
            let t0 = env.clock.value
            let t = try await env.db.insertQAThread(QAThread(paperIDs: [a.id], title: "t", mode: .fullText, createdAt: t0))
            let q = try await env.db.insertQAMessage(QAMessage(threadID: t.id, role: .user, text: "q?", createdAt: t0))
            var ans = try await env.db.insertQAMessage(QAMessage(threadID: t.id, role: .assistant, text: "", state: .streaming,
                                                                 meta: AssistMeta(provider: "claude", model: "haiku"),
                                                                 createdAt: t0, language: "en", depth: .quick))
            #expect(q.ord == 0 && ans.ord == 1)
            try await env.db.updateQAMessageText(id: ans.id, text: "partial")
            #expect(try await env.db.qaMessage(id: ans.id)?.text == "partial")
            ans.text = "Done [p. 2]."
            ans.state = .done
            ans.citations = [QACitation(page: 2, label: "1203", quote: "q", quoteFound: true)]
            ans.meta = AssistMeta(provider: "claude", model: "claude-haiku-4-5", totalMs: 7_250, inputTokens: 900,
                                  outputTokens: 40, costUSD: 0.01)
            ans.context = QAContextStats(mode: .fullText, chars: 3_600, estimatedTokens: 900, pages: [[1, 2]], fullText: true)
            try await env.db.updateQAMessage(ans)
            #expect(try await env.db.qaMessage(id: ans.id) == ans)
            // A finished answer's text is no longer touched by a late partial save.
            try await env.db.updateQAMessageText(id: ans.id, text: "late")
            #expect(try await env.db.qaMessage(id: ans.id)?.text == "Done [p. 2].")
            #expect(try await env.db.qaRecentDurations(provider: "claude", depth: .quick) == [7_250])
            #expect(try await env.db.qaRecentDurations(provider: "claude", depth: .thorough).isEmpty)
            #expect(try await env.db.qaMessages(threadID: t.id).map(\.id) == [q.id, ans.id])
            #expect(try await env.db.deleteQAMessage(id: q.id) == t.id)
            #expect(try await env.db.deleteQAMessage(id: q.id) == nil)
            let next = try await env.db.insertQAMessage(QAMessage(threadID: t.id, role: .user, text: "again", createdAt: t0))
            #expect(next.ord == 2)
            await #expect(throws: DatabaseError.notFound("qa thread zz")) {
                try await env.db.insertQAMessage(QAMessage(threadID: "zz", role: .user, text: "x", createdAt: t0))
            }
            #expect(try await env.db.deleteQAThread(id: t.id) == [a.id])
            #expect(try await env.db.qaMessage(id: ans.id) == nil)              // cascade
        }
    }

    @Test func deletingAPaperDropsItFromItsThreadsAndRecoveryRemovesEmptyOnes() async throws {
        try await Kit.run { env in
            let a = try await Kit.addPaper(env, title: "A")
            let b = try await Kit.addPaper(env, title: "B")
            let t0 = env.clock.value
            let multi = try await env.db.insertQAThread(QAThread(paperIDs: [a.id, b.id], title: "m", mode: .fullText, createdAt: t0))
            let single = try await env.db.insertQAThread(QAThread(paperIDs: [b.id], title: "s", mode: .fullText, createdAt: t0))
            try await env.db.hardDelete(pk: b.pk)
            #expect(try await env.db.qaThread(id: multi.id)?.paperIDs == [a.id])
            #expect(try await env.db.qaThread(id: single.id)?.paperIDs == [])
            let r = try await env.db.recoverQA()
            #expect(r.orphanThreads == 1 && r.cancelled == 0)
            #expect(try await env.db.qaThread(id: single.id) == nil)
            #expect(try await env.db.qaThread(id: multi.id) != nil)
        }
    }

    @Test func theSidecarRoundTripsAndRejectsOtherSchemas() throws {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var t = QAThread(id: "t1", paperIDs: ["p"], title: "Q?", mode: .fullText, createdAt: t0, language: .zh, persisted: true)
        t.updatedAt = t0.addingTimeInterval(30)
        let q = QAMessage(id: "m1", threadID: "t1", role: .user, text: "Q?", createdAt: t0)
        let a = QAMessage(id: "m2", threadID: "t1", role: .assistant, text: "A [p. 3].", meta: AssistMeta(provider: "codex", model: "gpt-5.6-luna", totalMs: 5_000),
                          createdAt: t0.addingTimeInterval(5), citations: [QACitation(page: 3, valid: true)], language: "zh",
                          depth: .thorough, ord: 1)
        let streaming = QAMessage(id: "m3", threadID: "t1", role: .assistant, text: "…", state: .streaming, createdAt: t0, ord: 2)
        let multi = QAThread(id: "t2", paperIDs: ["p", "q"], title: "m", mode: .cards, createdAt: t0)
        let file = QASidecar(paperID: "p", threads: [(t, [q, a, streaming]), (multi, [])])
        #expect(file.threads.map(\.id) == ["t1"])                                    // single-paper threads only
        try #require(file.threads.count > 0)          // no index past a failed expectation (QA-15)
        #expect(file.threads[0].messages.map(\.id) == ["m1", "m2"])                  // no streaming rows
        let data = try file.encoded()
        #expect(try file.encoded() == data)                                          // deterministic
        let back = try QASidecar.decode(data)
        #expect(back == file)
        let restored = back.restored()
        #expect(restored.count == 1 && restored[0].0.id == "t1" && restored[0].0.language == .zh && restored[0].0.updatedAt == t.updatedAt)
        #expect(restored[0].1.map(\.text) == ["Q?", "A [p. 3]."] && restored[0].1[1].citations == a.citations)
        #expect(restored[0].1[1].meta?.model == "gpt-5.6-luna" && restored[0].1[1].depth == .thorough)
        var other = file
        other.schema = "paperdeck.qa/9"
        #expect(throws: QAError.unsupportedSidecar("paperdeck.qa/9")) { try QASidecar.decode(try other.encoded()) }
    }
}
