import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct DatabaseMigrationTests {
    /// A fresh temp folder per test; removed by the caller's `defer`.
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-db-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func samplePaper() -> Paper {
        Paper(sha256: String(repeating: "a", count: 64), fileSize: 1, ids: PaperIDs(doi: "10.1/x"),
              title: "Persisted", folder: "Papers/x", pdfName: "x.pdf", originalName: "x.pdf")
    }

    @Test func freshDatabaseSeedsStartersOnce() async throws {
        let db = try Database.inMemory()
        #expect(try await db.schemaVersion() == Migrations.latestVersion)
        let cats = try await db.categories()
        #expect(cats.map(\.name) == PaperCategory.starters.map(\.name))
        #expect(cats.map(\.description) == PaperCategory.starters.map { Optional($0.description) })
        #expect(cats.map(\.hue) == Array(0..<7))
        #expect(cats.allSatisfy { $0.origin == .starter && $0.acknowledged })
        #expect(db.migration.fromVersion == 0 && db.migration.toVersion == Migrations.latestVersion
                && db.migration.backup == nil)
    }

    @Test func reopeningIsIdempotent() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Support/library.sqlite")
        let backups = dir.appendingPathComponent("Support/Backups")

        let first = try Database(url: url, backupsDir: backups)       // creates the parent folder
        #expect(first.migration.backup == nil)                          // nothing to back up yet
        try await first.insertPaper(samplePaper())
        try await first.deleteCategory(pk: 1)                          // a deleted starter must not come back
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))   // WAL mode
        await first.close()

        let second = try await Database.open(url: url, backupsDir: backups)
        #expect(second.migration == Migrations.Outcome(fromVersion: Migrations.latestVersion,
                                                       toVersion: Migrations.latestVersion, backup: nil))
        #expect(try await second.categories().count == 6)
        #expect(try await second.livePapers().map(\.title) == ["Persisted"])
        #expect(try await second.schemaVersion() == Migrations.latestVersion)
        #expect(!FileManager.default.fileExists(atPath: backups.path))
        await second.close()
    }

    @Test func refusesNewerSchema() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        do {
            let raw = try SQLiteConnection(path: url.path)
            try raw.exec("CREATE TABLE future(x); PRAGMA user_version = 99")
            raw.close()
        }
        #expect(throws: DatabaseError.newerSchema(found: 99, supported: Migrations.latestVersion)) {
            _ = try Database(url: url, backupsDir: dir)
        }
        let raw = try SQLiteConnection(path: url.path)
        #expect(try raw.userVersion() == 99)                          // untouched
        #expect(try raw.scalarInt("SELECT count(*) FROM sqlite_master WHERE name = 'paper'") == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasPrefix("pre-migration") })
    }

    @Test func backsUpExistingDatabaseBeforeMigrating() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        let backups = dir.appendingPathComponent("Backups")
        do {
            let raw = try SQLiteConnection(path: url.path)
            try raw.exec("CREATE TABLE legacy(v TEXT); INSERT INTO legacy VALUES('keep me')")
            raw.close()
        }
        let db = try Database(url: url, backupsDir: backups)
        let backup = try #require(db.migration.backup)
        #expect(backup.deletingLastPathComponent().standardizedFileURL.path == backups.standardizedFileURL.path)
        #expect(backup.lastPathComponent.hasPrefix("pre-migration-v0-"))
        #expect(backup.pathExtension == "sqlite")
        let copy = try SQLiteConnection(path: backup.path)
        #expect(try copy.scalarString("SELECT v FROM legacy") == "keep me")
        #expect(try copy.userVersion() == 0)
        #expect(try await db.schemaVersion() == Migrations.latestVersion)
        await db.close()
    }

    @Test func corruptFileIsReportedAndCanBeMovedAside() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        try Data(repeating: 0x42, count: 8192).write(to: url)
        let error = #expect(throws: DatabaseError.self) { _ = try Database(url: url, backupsDir: dir) }
        guard case .corrupt = error else { Issue.record("expected .corrupt, got \(String(describing: error))"); return }
        let moved = try Database.moveAsideCorrupt(url: url, backupsDir: dir.appendingPathComponent("Backups"))
        #expect(moved.lastPathComponent.hasPrefix("corrupt-"))
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("library.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        _ = try Database(url: url, backupsDir: dir)                    // a fresh DB opens in its place
    }

    @Test func foreignKeysAreEnforced() async throws {
        let db = try Database.inMemory()
        await #expect(throws: SQLiteError.self) {
            try await db.replaceChecklist(paperPK: 999, items: [ChecklistItem(ord: 1, text: "x", minutes: 5, origin: .user)])
        }
        await #expect(throws: SQLiteError.self) {
            try await db.insertJob(AgentJob(paperPK: 999, provider: "mock", state: .queued))
        }
    }

    @Test func fileStampIsUTC() {
        #expect(Migrations.fileStamp(Date(timeIntervalSince1970: 1_790_000_000)) == "20260921-141320")
    }
}
