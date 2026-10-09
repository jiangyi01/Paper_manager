import Foundation
import Testing
@testable import PaperDeckCore

/// Phase 2 integration (Lead): the change requests the lanes left for Lead-owned files — `qa.json`
/// follows a paper's privacy flags (R-QA-1) and comes back with an index rebuild (R-QA-2), the daily
/// housekeeping drops the reader's page memory of purged papers (R-RD-5), and the notes editor keeps
/// a Save-to-Notes block that lands under unsaved typing (R-QA-9, `NotesMerge`). Mock assist backend only.
@Suite(.serialized) struct P2IntegrationTests {
    private typealias Kit = QATestKit

    // MARK: R-QA-1 — qa.json follows the privacy flags without a separate sync

    @Test func markingAPaperPrivateRemovesItsQaJsonAndUnmarkingBringsItBack() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env)
            let qa = await env.engine.qaService()
            let thread = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            #expect(Kit.completed(await Kit.ask(env, qa, thread.id, "What is shown?")) != nil)
            await qa.flushSidecars()
            let url = Kit.qaJSON(env, p)
            #expect(FileManager.default.fileExists(atPath: url.path))

            // Only `setPaperPolicy` — no explicit `syncQASidecar` — and the file is gone.
            try await env.engine.setPaperPolicy(paperID: p.id, confidential: true, neverAI: false)
            #expect(!FileManager.default.fileExists(atPath: url.path), "a confidential paper keeps no qa.json")
            try await env.engine.setPaperPolicy(paperID: p.id, confidential: false, neverAI: false)
            #expect(FileManager.default.fileExists(atPath: url.path), "unmarked: the threads are written again")
            try await env.engine.setPaperPolicy(paperID: p.id, confidential: false, neverAI: true)
            #expect(!FileManager.default.fileExists(atPath: url.path), "a never-AI paper keeps no qa.json")
            // The database keeps the thread either way.
            #expect(await qa.messages(threadID: thread.id).count == 2)
        }
    }

    // MARK: R-QA-2 — an index rebuild restores single-paper threads from qa.json

    @Test func anIndexRebuildRestoresTheThreadsFromQaJson() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env)
            await env.engine.ctx.syncSidecar(pk: p.pk)
            await env.engine.ctx.sidecars.flush()
            let qa = await env.engine.qaService()
            let thread = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            let answer = try #require(Kit.completed(await Kit.ask(env, qa, thread.id, "What is shown?")))
            await qa.flushSidecars()
            // The database forgets the thread (as a fresh index would); the rebuild reads it back.
            try await env.db.deleteQAThread(id: thread.id)
            #expect(await qa.thread(id: thread.id) == nil)
            _ = try await env.engine.rebuildFromSidecars(replacingExisting: true)
            let restored = await qa.messages(threadID: thread.id)
            #expect(restored.map(\.role) == [.user, .assistant])
            #expect(restored.last?.id == answer.id && restored.last?.text == answer.text && restored.last?.state == .done)
            #expect(await qa.thread(id: thread.id)?.paperIDs == [p.id])
        }
    }

    // MARK: R-RD-5 — the daily housekeeping prunes the reader's page memory

    @Test func theDailyHousekeepingDropsTheReaderPagesOfPurgedPapers() async throws {
        try await OpsTestKit.run { env in
            let kept = try await OpsTestKit.addPaper(env, title: "Kept")
            let purged = try await OpsTestKit.addPaper(env, title: "Purged")
            await env.engine.setReaderPage(paperID: kept.id, page: 3)
            await env.engine.setReaderPage(paperID: purged.id, page: 5)
            _ = try await env.engine.softDelete(paperID: purged.id)
            try await env.engine.deleteNow(paperID: purged.id, trash: { url in (try? FileManager.default.removeItem(at: url)) != nil })
            let report = try await env.engine.maintenance.assistRetention()
            #expect(report.prunedReaderPages == 1)
            #expect(await env.engine.readerPage(paperID: kept.id) == 3)
            #expect(await env.engine.readerPage(paperID: purged.id) == nil)
            #expect(try await env.engine.maintenance.assistRetention().prunedReaderPages == 0)
        }
    }

    /// Page-memory keys hold the lowercased id; a paper whose stored id isn't lowercase (an older
    /// library) keeps its page.
    @Test func pruningComparesIDsCaseInsensitively() async throws {
        try await OpsTestKit.run { env in
            let p = try await OpsTestKit.addPaper(env, title: "Upper")
            try await env.db.transaction { db in try db.db.exec("UPDATE paper SET id = upper(id) WHERE pk = \(p.pk)") }
            let upper = p.id.uppercased()
            #expect(try await env.db.transaction { db in try db.db.scalarString("SELECT id FROM paper WHERE pk = \(p.pk)") } == upper)
            await env.engine.setReaderPage(paperID: upper, page: 4)
            #expect(await env.engine.pruneReaderPages() == 0)
            #expect(await env.engine.readerPage(paperID: upper) == 4)
        }
    }

    // MARK: R-QA-9 — NotesMerge

    static let block = "— Ask · 2026-10-01 21:40 · Claude haiku\n> Q: What is shown?\nThe main result [p. 3]."

    @Test func aBlockAppendedUnderUnsavedTypingIsKept() {
        let base = "My notes"
        let stored = ExplainNotes.append(Self.block, to: base)
        let local = "My notes, and more I typed"
        let merged = NotesMerge.appendedBlocks(base: base, stored: stored, local: local)
        #expect(merged == "My notes, and more I typed\n\n" + Self.block + "\n")
        // Already there (the editor's text holds it): unchanged.
        #expect(NotesMerge.appendedBlocks(base: base, stored: stored, local: merged ?? "") == merged)
        // Two blocks at once.
        let second = "— Explain · p. 4 · 2026-10-01 21:41 · Claude haiku\nA term."
        let both = ExplainNotes.append(second, to: stored)
        #expect(NotesMerge.appendedBlocks(base: base, stored: both, local: local)
                == "My notes, and more I typed\n\n" + Self.block + "\n\n" + second + "\n")
    }

    @Test func emptyOrTrailingWhitespaceBasesMergeToo() {
        #expect(NotesMerge.appendedBlocks(base: "", stored: ExplainNotes.append(Self.block, to: ""), local: "typing")
                == "typing\n\n" + Self.block + "\n")
        #expect(NotesMerge.appendedBlocks(base: "Notes\n\n", stored: ExplainNotes.append(Self.block, to: "Notes\n\n"),
                                          local: "Notes\n\nmore") == "Notes\n\nmore\n\n" + Self.block + "\n")
        // The user's text was empty again (they deleted everything): the block alone.
        #expect(NotesMerge.appendedBlocks(base: "x", stored: ExplainNotes.append(Self.block, to: "x"), local: "")
                == Self.block + "\n")
    }

    @Test func anyOtherChangeLeavesThePendingSaveAlone() {
        // The editor's own save landing (typed text, no block marker).
        #expect(NotesMerge.appendedBlocks(base: "abc", stored: "abc xyz", local: "abc xy") == nil)
        #expect(NotesMerge.appendedBlocks(base: "abc", stored: "abc\n\nmore text", local: "abcd") == nil)
        // Unchanged, shortened or rewritten elsewhere.
        #expect(NotesMerge.appendedBlocks(base: "abc", stored: "abc", local: "abcd") == nil)
        #expect(NotesMerge.appendedBlocks(base: "abc def", stored: "abc", local: "abc defg") == nil)
        #expect(NotesMerge.appendedBlocks(base: "abc", stored: "xyz\n\n" + Self.block, local: "abcd") == nil)
        // A marker in the middle of the same line is not a block.
        #expect(NotesMerge.appendedBlocks(base: "abc", stored: "abc— x", local: "abcd") == nil)
        #expect(NotesMerge.appendedBlocks(base: "abc", stored: "abc — x", local: "abcd") == nil)
    }
}
