import Foundation
import Testing
@testable import PaperDeckCore

/// Library fixes: deleting the last open checklist item marks the paper read (core-data-6); the
/// daily housekeeping backs up and purges (core-data-5); "Recently opened" ranks by the last open
/// after a relaunch (dedupe-batch-9); "Si"/"si" in a file name is no supplement (core-data-7,
/// core-data-extra-3). Temp libraries; no CLI, no real Trash.
@Suite struct LibraryFixesTests {
    private typealias Kit = OpsTestKit

    // MARK: core-data-6

    @Test func deletingTheLastOpenItemMarksThePaperRead() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, deadline: Kit.day(2026, 9, 29))
            let items = try await Kit.checklist(env, p.id)
            for item in items.dropLast() { _ = try await env.engine.toggleChecklistItem(paperID: p.id, itemID: item.id) }
            #expect(try await Kit.paper(env, p.id).status == .reading)
            env.advance(60)
            let result = try await env.engine.deleteChecklistItem(paperID: p.id, itemID: items.last!.id)
            #expect(result.markedDone)
            let done = try await Kit.paper(env, p.id)
            #expect(done.status == .done && done.doneAt == env.clock.value && done.openedAt != nil)
            #expect(result.paper.status == .done)
            #expect(try await Kit.checklist(env, p.id).count == items.count - 1)
        }
    }

    @Test func deletingAnItemOtherwiseLeavesTheStatus() async throws {
        try await Kit.run { env in
            // Open items remain: still reading.
            let p = try await Kit.addPaper(env, title: "Open items")
            let items = try await Kit.checklist(env, p.id)
            _ = try await env.engine.toggleChecklistItem(paperID: p.id, itemID: items[0].id)
            let r1 = try await env.engine.deleteChecklistItem(paperID: p.id, itemID: items[1].id)
            #expect(!r1.markedDone)
            #expect(try await Kit.paper(env, p.id).status == .reading)
            // The last item deleted: nothing left to tick, nothing is decided.
            let single = try await Kit.addPaper(env, title: "Single", checklist: Kit.heuristicChecklist([10]))
            let only = try await Kit.checklist(env, single.id)
            let r2 = try await env.engine.deleteChecklistItem(paperID: single.id, itemID: only[0].id)
            #expect(!r2.markedDone)
            #expect(try await Kit.paper(env, single.id).status == .toRead)
        }
        // Auto-mark-done off: the paper stays reading at 100 %.
        try await Kit.run(Kit.settings(autoDone: false)) { env in
            let p = try await Kit.addPaper(env)
            let items = try await Kit.checklist(env, p.id)
            for item in items.dropLast() { _ = try await env.engine.toggleChecklistItem(paperID: p.id, itemID: item.id) }
            let r = try await env.engine.deleteChecklistItem(paperID: p.id, itemID: items.last!.id)
            #expect(!r.markedDone)
            #expect(try await Kit.paper(env, p.id).status == .reading)
        }
    }

    /// Integration X2: Mark as Unread (⌘D, now also in the Paper menu) on a fully ticked paper
    /// sends it back to reading; deleting an already-ticked item afterwards completes nothing and
    /// must not re-mark it read.
    @Test func deletingATickedItemDoesNotUndoMarkAsUnread() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, deadline: Kit.day(2026, 9, 29))
            let items = try await Kit.checklist(env, p.id)
            #expect(items.count >= 2)
            for item in items { _ = try await env.engine.toggleChecklistItem(paperID: p.id, itemID: item.id) }
            #expect(try await Kit.paper(env, p.id).status == .done)
            let unread = try await env.engine.toggleDone(paperID: p.id)
            #expect(unread.status == .reading && unread.doneAt == nil)
            env.advance(60)
            let result = try await env.engine.deleteChecklistItem(paperID: p.id, itemID: items.last!.id)
            #expect(!result.markedDone)
            #expect(result.paper.status == .reading)
            let after = try await Kit.paper(env, p.id)
            #expect(after.status == .reading && after.doneAt == nil)
            #expect(try await Kit.checklist(env, p.id).count == items.count - 1)
        }
    }

    // MARK: core-data-5

    @Test func theDailyHousekeepingBacksUpAndPurges() async throws {
        try await Kit.run { env in
            let gone = try await Kit.addPaper(env, title: "Deleted long ago")
            let kept = try await Kit.addPaper(env, title: "Still here")
            try await env.engine.softDelete(paperID: gone.id)
            let trash = DedupeKit.Trash()
            let maintenance = Maintenance(engine: env.engine, trash: trash.function)
            try await maintenance.dailyHousekeeping()
            let backups = { try FileManager.default.contentsOfDirectory(atPath: env.paths.backups.path).filter { $0.hasPrefix("library-") }.sorted() }
            #expect(try backups() == ["library-2026-09-29.sqlite"])
            #expect(try await env.db.paper(id: gone.id) != nil)                    // not 30 days yet

            // Weeks later, the app still running: the day's pass backs up and purges.
            env.advance(Engine.recentlyDeletedRetention + 86_400)
            try await maintenance.dailyHousekeeping()
            #expect(try backups() == ["library-2026-09-29.sqlite", "library-2026-10-30.sqlite"])
            #expect(try await env.db.paper(id: gone.id) == nil)
            #expect(try await env.db.paper(id: kept.id) != nil)
            // Idempotent the same day.
            try await maintenance.dailyHousekeeping()
            #expect(try backups().count == 2)
        }
    }

    // MARK: dedupe-batch-9

    @Test func recentlyOpenedRanksByTheLastOpenAfterARelaunch() async throws {
        let env = try await Kit.make()
        let root = env.root
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try await Kit.addPaper(env, title: "A")
        let b = try await Kit.addPaper(env, title: "B")
        let c = try await Kit.addPaper(env, title: "Never opened")
        _ = try await env.engine.markOpened(paperID: a.id)          // A first opened long ago
        env.advance(30 * 86_400)
        _ = try await env.engine.markOpened(paperID: b.id)          // B first opened last month
        env.advance(29 * 86_400)
        _ = try await env.engine.markOpened(paperID: a.id)          // A read again yesterday
        let later = env.clock.value.addingTimeInterval(86_400)
        await env.engine.shutdown()
        await env.engine.db.close()

        let reopened = try await Kit.make(root: root, now: later)
        let papers = try await reopened.db.livePapers()
        #expect(reopened.engine.recentOpens.recent().isEmpty)        // the session list is gone
        let ranked = SelectN.pick(.recentlyOpened, n: nil, from: papers, lastOpened: reopened.engine.lastOpened.snapshot())
        #expect(ranked == [a.id, b.id])
        #expect(!ranked.contains(c.id))
        // Delete Permanently forgets the paper's open.
        try await reopened.engine.deleteNow(paperID: a.id, trash: DedupeKit.Trash().function)
        #expect(reopened.engine.lastOpened.snapshot()[a.id] == nil)
        #expect(try await reopened.db.lastOpenedRecords().map(\.id) == [b.id])
        await reopened.engine.shutdown()
        await reopened.engine.db.close()
    }

    @Test func theLastOpenListIsBounded() async throws {
        try await Kit.run { env in
            for i in 0..<(LastOpenedRecord.capacity + 3) {
                try await env.db.recordOpened(paperID: "p\(i)", at: env.clock.value.addingTimeInterval(Double(i)))
            }
            let list = try await env.db.lastOpenedRecords()
            #expect(list.count == LastOpenedRecord.capacity)
            #expect(list.first?.id == "p\(LastOpenedRecord.capacity + 2)")
        }
    }

    // MARK: core-data-7, core-data-extra-3

    @Test func siInAFileNameIsNoSupplementUnlessItIsCapitals() {
        for name in ["Si_2023_CellReports.pdf", "Li-Si-2020-Nature.pdf", "Strain engineering in Si nanowires.pdf",
                     "Wang.si.pdf", "si.pdf", "Simons_2020.pdf"] {
            #expect(!IntakeActor.isSupplementName(name), "\(name)")
            #expect(!DedupeText.isSupplementFileName(name), "\(name)")
        }
        for name in ["paper_SI.pdf", "main_SI.pdf", "SI_appendix.pdf", "Wang 2024 SI.pdf", "paper_supp.pdf", "Paper-Suppl.pdf",
                     "SUPPLEMENTARY_data.pdf", "Extended Data.pdf", "extended_data.pdf"] {
            #expect(IntakeActor.isSupplementName(name), "\(name)")
            #expect(DedupeText.isSupplementFileName(name), "\(name)")
        }
        let title = "Strain engineering in silicon nanowires for flexible electronics"
        #expect(DedupeText.kind(title: title, fileName: "Si_2023_CellReports.pdf") == .article)
        #expect(DedupeText.kind(title: title, fileName: "Wang_2024_SI.pdf") == .supplement)
    }

    @Test func aFolderImportKeepsPapersBySi() async throws {
        try await DedupeKit.run(DedupeKit.settings(dedupe: DedupeSettings(enabled: false))) { env in
            let dir = env.downloads.appendingPathComponent("Reading list", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let files = ["Si_2023_CellReports.pdf": "Spatial atlas of the developing mouse cortex",
                         "Li-Si-2020-Nature.pdf": "Chromatin dynamics in human organoids",
                         "main.pdf": "Lineage tracing of organoid progenitors at scale",
                         "main_SI.pdf": "Supplementary information"]
            for (name, title) in files {
                try DedupeKit.pdfData(title: title, doi: nil, body: DedupeKit.body(seed: name), pages: 2, tag: name)
                    .write(to: dir.appendingPathComponent(name))
            }
            let summary = await env.engine.intake.ingest([.file(dir)], options: ImportOptions(origin: .drop))
            await env.settle()
            #expect(summary.added.count == 3)
            let names = Set(try await env.db.livePapers().map(\.originalName))
            #expect(names == ["Si_2023_CellReports.pdf", "Li-Si-2020-Nature.pdf", "main.pdf"])
        }
    }
}
