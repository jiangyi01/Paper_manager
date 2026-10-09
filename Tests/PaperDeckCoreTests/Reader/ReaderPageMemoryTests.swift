import Foundation
import Testing
@testable import PaperDeckCore

/// The reader's page memory (kv `reader.page.<id>`): per paper, quiet, pruned with purged papers.
@Suite("Reader: page memory in the library")
struct ReaderPageMemoryTests {
    @Test func thePageIsRememberedPerPaper() async throws {
        try await OpsTestKit.run { env in
            let a = try await OpsTestKit.addPaper(env, title: "First")
            let b = try await OpsTestKit.addPaper(env, title: "Second")
            #expect(await env.engine.readerPage(paperID: a.id) == nil)
            await env.engine.setReaderPage(paperID: a.id, page: 7)
            await env.engine.setReaderPage(paperID: b.id, page: 2)
            await env.engine.setReaderPage(paperID: a.id, page: 9)
            #expect(await env.engine.readerPage(paperID: a.id) == 9)
            #expect(await env.engine.readerPage(paperID: b.id) == 2)
            #expect(try await env.db.kv("reader.page.\(a.id)") == "9")
            // Nothing below page 1 is stored.
            await env.engine.setReaderPage(paperID: b.id, page: 0)
            #expect(await env.engine.readerPage(paperID: b.id) == 2)
            // A damaged row reads as "no memory".
            try await env.db.setKV("reader.page.\(b.id)", "x")
            #expect(await env.engine.readerPage(paperID: b.id) == nil)
        }
    }

    @Test func turningPagesDoesNotRefreshTheLibrary() async throws {
        try await OpsTestKit.run { env in
            let a = try await OpsTestKit.addPaper(env)
            try await Task.sleep(for: .milliseconds(100))
            let changes = env.engine.changes.subscribe()
            let seen = OpsTestKit.Box(0)
            let watcher = Task { for await change in changes where change == .settings { seen.value += 1 } }
            for p in 1...5 { await env.engine.setReaderPage(paperID: a.id, page: p) }
            try await Task.sleep(for: .milliseconds(200))
            #expect(seen.value == 0, "a page turn is not a settings / library change")
            // The control: an ordinary kv write does notify (the watcher is live).
            try await env.db.setKV("reader.control", "1")
            try await Task.sleep(for: .milliseconds(200))
            #expect(seen.value >= 1)
            watcher.cancel()
        }
    }

    @Test func purgedPapersLoseTheirMemoryAndDeletedOnesKeepIt() async throws {
        try await OpsTestKit.run { env in
            let kept = try await OpsTestKit.addPaper(env, title: "Kept")
            let trashed = try await OpsTestKit.addPaper(env, title: "Trashed")
            let purged = try await OpsTestKit.addPaper(env, title: "Purged")
            for (p, n) in [(kept, 3), (trashed, 4), (purged, 5)] { await env.engine.setReaderPage(paperID: p.id, page: n) }
            try await env.db.setKV("reader.page.not-a-paper", "2")
            try await env.db.setKV("reader.pages", "keep me")           // not under the prefix
            _ = try await env.engine.softDelete(paperID: trashed.id)
            _ = try await env.engine.softDelete(paperID: purged.id)
            // The delete's card.json write lands first: removing the folder while it is written failed
            // the purge once on a loaded machine (`trashFailed`; Phase 2 fix round, ENV-1).
            await env.engine.ctx.sidecars.flush()
            try await env.engine.deleteNow(paperID: purged.id, trash: { url in (try? FileManager.default.removeItem(at: url)) != nil })
            #expect(await env.engine.pruneReaderPages() == 2)
            #expect(await env.engine.readerPage(paperID: kept.id) == 3)
            #expect(await env.engine.readerPage(paperID: trashed.id) == 4, "Recently Deleted keeps its page for a restore")
            #expect(await env.engine.readerPage(paperID: purged.id) == nil)
            #expect(try await env.db.kv("reader.page.not-a-paper") == nil)
            #expect(try await env.db.kv("reader.pages") == "keep me")
            #expect(await env.engine.pruneReaderPages() == 0)
        }
    }
}
