import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct LaunchMaintenanceTests {
    private typealias Kit = OpsTestKit
    private typealias PDTag = PaperDeckCore.Tag
    private static var fm: FileManager { FileManager.default }

    private static func trashInto(_ dir: URL) throws -> @Sendable (URL) -> Bool {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return { url in (try? FileManager.default.moveItem(at: url, to: dir.appendingPathComponent(UUID().uuidString))) != nil }
    }

    private static func age(_ url: URL, by seconds: TimeInterval) throws {
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
    }

    @Test func missingFileIsFlaggedAndCleared() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env)
            let pdf = env.engine.ctx.pdfURL(p)
            let bytes = try Data(contentsOf: pdf)
            try Self.fm.removeItem(at: pdf)
            let first = try await env.engine.maintenance.reconcile()
            #expect(first.markedMissing == [p.id])
            #expect(try await Kit.paper(env, p.id).flags.contains(.missing))
            #expect(try await env.engine.maintenance.reconcile().markedMissing.isEmpty)     // idempotent

            try bytes.write(to: pdf)
            let second = try await env.engine.maintenance.reconcile()
            #expect(second.clearedMissing == [p.id])
            #expect(!(try await Kit.paper(env, p.id).flags.contains(.missing)))
        }
    }

    @Test func movedFolderIsFoundByCardID() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, folder: "2024_Wang_Original")
            let q = try await Kit.addPaper(env, folder: "2024_Chen_Other")
            await env.engine.ctx.sidecars.flush()
            try Self.fm.moveItem(at: env.paths.papers.appendingPathComponent("2024_Wang_Original"),
                                 to: env.paths.papers.appendingPathComponent("Renamed in Finder"))
            try Self.fm.moveItem(at: env.paths.papers.appendingPathComponent("2024_Chen_Other"),
                                 to: env.paths.inbox.appendingPathComponent("moved-to-inbox"))
            let report = try await env.engine.maintenance.reconcile()
            #expect(Set(report.relocated) == [p.id, q.id])
            #expect(report.markedMissing.isEmpty && report.adopted.isEmpty)
            let moved = try await Kit.paper(env, p.id)
            #expect(moved.folder == "Papers/Renamed in Finder" && moved.pdfName == "2024_Wang_Original.pdf")
            #expect(!moved.flags.contains(.missing))
            #expect(try await Kit.paper(env, q.id).folder == "Papers/_Inbox/moved-to-inbox")
            #expect(Self.fm.fileExists(atPath: env.engine.ctx.pdfURL(moved).path))
        }
    }

    @Test func renamedPDFInsideItsFolderIsFixed() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, folder: "2024_Wang_Pdf")
            let folder = env.engine.ctx.folderURL(p)
            try Self.fm.moveItem(at: folder.appendingPathComponent(p.pdfName), to: folder.appendingPathComponent("my copy.pdf"))
            #expect(try await env.engine.maintenance.reconcile().relocated == [p.id])
            #expect(try await Kit.paper(env, p.id).pdfName == "my copy.pdf")
        }
    }

    @Test func orphanFolderWithCardAndPDFIsAdopted() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, folder: "2024_Wang_Adopt")
            let cat = try await env.engine.createCategory(name: "Adopted Things")
            _ = try await env.engine.setCategory(paperID: p.id, categoryPK: cat.pk)
            _ = try await env.engine.addTag(paperID: p.id, "keep-me")
            let items = try await Kit.checklist(env, p.id)
            _ = try await env.engine.toggleChecklistItem(paperID: p.id, itemID: items[1].id)
            await env.engine.ctx.sidecars.flush()
            try await env.db.hardDelete(pk: p.pk)                       // the row is gone, the folder stays
            // Folders that can't be adopted: card without PDF, PDF without card.
            let noPDF = env.paths.papers.appendingPathComponent("2024_No_PDF")
            try Self.fm.createDirectory(at: noPDF, withIntermediateDirectories: false)
            var card = try CardSidecar.decoded(from: Data(contentsOf: env.engine.ctx.folderURL(p).appendingPathComponent("card.json")))
            card.id = UUID().uuidString.lowercased()
            card.sha256 = String(repeating: "b", count: 64)
            try card.encoded().write(to: noPDF.appendingPathComponent("card.json"))
            let noCard = env.paths.papers.appendingPathComponent("Loose PDF")
            try Self.fm.createDirectory(at: noCard, withIntermediateDirectories: false)
            try Kit.pdfBytes("loose").write(to: noCard.appendingPathComponent("loose.pdf"))

            let report = try await env.engine.maintenance.reconcile()
            #expect(report.adopted == [p.id])
            #expect(report.skipped.contains { $0.hasPrefix("Papers/2024_No_PDF") })
            let adopted = try await Kit.paper(env, p.id)
            #expect(adopted.folder == "Papers/2024_Wang_Adopt" && adopted.sha256 == p.sha256)
            #expect(adopted.categoryPK == cat.pk && adopted.status == .reading)
            #expect(try await Kit.checklist(env, p.id).map(\.id) == items.map(\.id))
            #expect(try await env.db.tags(paperPK: adopted.pk) == [PDTag(name: "keep-me", origin: .user)])
            #expect(try await env.engine.maintenance.reconcile().adopted.isEmpty)
        }
    }

    @Test func launchCleansTemporaryFilesAndPurges() async throws {
        try await Kit.run { env in
            let partials = [env.paths.partial.appendingPathComponent("a.pdf"), env.paths.partial.appendingPathComponent("b.pdf")]
            for url in partials { try Kit.pdfBytes(url.lastPathComponent).write(to: url) }
            let oldIncoming = env.paths.incoming.appendingPathComponent(UUID().uuidString)
            let newIncoming = env.paths.incoming.appendingPathComponent(UUID().uuidString)
            let oldJob = env.paths.jobs.appendingPathComponent(UUID().uuidString)
            let newJob = env.paths.jobs.appendingPathComponent(UUID().uuidString)
            for dir in [oldIncoming, newIncoming, oldJob, newJob] {
                try Self.fm.createDirectory(at: dir, withIntermediateDirectories: false)
                try Data("x".utf8).write(to: dir.appendingPathComponent("stderr.txt"))
            }
            try Self.age(oldIncoming, by: 25 * 3600)
            try Self.age(newIncoming, by: 23 * 3600)
            try Self.age(oldJob, by: 8 * 86_400)
            try Self.age(newJob, by: 6 * 86_400)

            let p = try await Kit.addPaper(env)
            _ = try await env.engine.softDelete(paperID: p.id)
            env.advance(31 * 86_400)
            let trash = try Self.trashInto(env.root.appendingPathComponent("Trash"))
            let report = await Maintenance(engine: env.engine, trash: trash).onLaunch()

            #expect(report.errors.isEmpty)
            #expect(report.rebuilt == nil)
            #expect(report.removedPartials == 2 && report.removedIncoming == 1 && report.removedJobDirs == 1)
            #expect(partials.allSatisfy { !Self.fm.fileExists(atPath: $0.path) })
            #expect(!Self.fm.fileExists(atPath: oldIncoming.path) && Self.fm.fileExists(atPath: newIncoming.path))
            #expect(!Self.fm.fileExists(atPath: oldJob.path) && Self.fm.fileExists(atPath: newJob.path))
            #expect(report.purged == [p.id])
            #expect(try await env.db.paper(id: p.id) == nil)
        }
    }

    @Test func dailyBackupKeepsTheNewestSeven() async throws {
        try await Kit.run { env in
            _ = try await Kit.addPaper(env)
            for day in 20...27 {
                try Data("old".utf8).write(to: env.paths.backups.appendingPathComponent("library-2026-09-\(day).sqlite"))
            }
            let migration = env.paths.backups.appendingPathComponent("pre-migration-v1-20260901T000000.sqlite")
            try Data("keep".utf8).write(to: migration)

            let maintenance = Maintenance(engine: env.engine, trash: { _ in false })
            let first = await maintenance.onLaunch()
            // The engine clock (Chicago) says 2026-09-29.
            #expect(first.backup?.lastPathComponent == "library-2026-09-29.sqlite")
            #expect(first.prunedBackups == ["library-2026-09-21.sqlite", "library-2026-09-20.sqlite"])
            let names = try Self.fm.contentsOfDirectory(atPath: env.paths.backups.path).filter { $0.hasPrefix("library-") }
            #expect(names.count == 7)
            #expect(Self.fm.fileExists(atPath: migration.path))
            let size = try #require(FileOps.fileSize(env.paths.backups.appendingPathComponent("library-2026-09-29.sqlite")))
            #expect(size > 4096)

            let second = await maintenance.onLaunch()
            #expect(second.backup == nil && second.prunedBackups.isEmpty)

            let manual = try await maintenance.backupNow()
            #expect(manual.lastPathComponent == "library-2026-09-29-100000.sqlite")
            #expect(try Self.fm.contentsOfDirectory(atPath: env.paths.backups.path).filter { $0.hasPrefix("library-") }.count == 7)
        }
    }
}
