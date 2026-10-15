import Foundation
import Testing
@testable import PaperDeckCore

/// `Database.openForInspection` (portability-cli-1): `--doctor` and `--doctor --mail-only` read the
/// real library's database, so the open must never migrate, back up or create anything — a file
/// from an older build stays byte-for-byte what it was, and the schema gap is reported instead.
/// Temp folders only.
@Suite("Database inspection open (read-only)")
struct DatabaseInspectionTests {
    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-db-inspect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A level-1 library (from before mail), closed so its WAL is folded in.
    static func level1File(_ url: URL) throws {
        let raw = try SQLiteConnection(path: url.path)
        try Migrations.prepare(raw, backupsDir: nil, targetVersion: 1)
        try raw.run("INSERT INTO kv(key, value) VALUES('probe', 'kept')")
        raw.close()
    }

    @Test func anOlderFileIsReportedNotMigrated() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        try Self.level1File(url)
        let before = try Data(contentsOf: url)

        let db = try await Database.openForInspection(url: url)
        #expect(db.inspection == Migrations.Inspection(level: 1, needsUpgrade: true))
        #expect(db.migration == Migrations.Outcome(fromVersion: 1, toVersion: 1, backup: nil))
        #expect(db.inspection?.upgradeNote == "schema v1 (this build expects v\(Migrations.latestVersion) — open the app to upgrade)")
        // Reads of the tables the file has work; a read of a table it lacks throws; writes throw.
        #expect(try await db.kv("probe") == "kept")
        #expect(try await db.livePapers().isEmpty)
        await #expect(throws: (any Error).self) { try await db.mailCounts() }
        await #expect(throws: (any Error).self) { try await db.setKV("probe", "changed") }
        await db.close()

        #expect(try Data(contentsOf: url) == before, "the inspection open changed the database file")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(Set(names).isSubset(of: ["library.sqlite", "library.sqlite-wal", "library.sqlite-shm"]), "\(names)")
        let raw = try SQLiteConnection(path: url.path, readOnly: true)
        defer { raw.close() }
        #expect(try Migrations.level(raw) == 1)
        #expect(try Migrations.featureVersion(raw, Migrations.assistFeature) == 0)
    }

    /// A cleanly closed file without its -wal / -shm (another tool closed it, or they were
    /// removed): a read-only connection can't create them, so the inspection reads a private copy.
    @Test func aFileWithoutItsWALFilesIsInspectedToo() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        try Self.level1File(url)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        let before = try Data(contentsOf: url)
        func copies() -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
                .filter { $0.hasPrefix("paperdeck-inspect-") })
        }
        let earlier = copies()
        let db = try await Database.openForInspection(url: url)
        #expect(db.inspection == Migrations.Inspection(level: 1, needsUpgrade: true))
        #expect(try await db.kv("probe") == "kept")
        await #expect(throws: (any Error).self) { try await db.setKV("probe", "changed") }
        #expect(copies().subtracting(earlier).count == 1)
        await db.close()
        #expect(copies().subtracting(earlier).isEmpty, "close removes the private copy")
        #expect(try Data(contentsOf: url) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["library.sqlite"], "nothing created next to it")
    }

    /// The contrast: the normal open (what --doctor used) upgrades the same file in place, with
    /// no backup when `backupsDir` is nil.
    @Test func theNormalOpenWouldHaveMigrated() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        try Self.level1File(url)
        let db = try await Database.open(url: url, backupsDir: nil)
        #expect(db.migration.fromVersion == 1 && db.migration.toVersion == Migrations.latestVersion && db.migration.backup == nil)
        #expect(db.inspection == nil)
        await db.close()
    }

    @Test func aCurrentFileNeedsNothing() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        let fresh = try Database(url: url, backupsDir: nil)
        await fresh.close()
        let before = try Data(contentsOf: url)
        let db = try await Database.openForInspection(url: url)
        #expect(db.inspection == Migrations.Inspection(level: Migrations.latestVersion, needsUpgrade: false))
        #expect(db.inspection?.upgradeNote == nil)
        let counts = try await db.mailCounts()
        #expect(counts.pending == 0 && counts.requests == 0)
        await db.close()
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func aLevel2FileWithoutTheAssistTablesNeedsAnUpgrade() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        do {
            let raw = try SQLiteConnection(path: url.path)
            try Migrations.prepare(raw, backupsDir: nil, features: false)
            raw.close()
        }
        let before = try Data(contentsOf: url)
        let db = try await Database.openForInspection(url: url)
        #expect(db.inspection == Migrations.Inspection(level: 2, needsUpgrade: true))
        #expect(db.inspection?.upgradeNote?.contains("open the app to upgrade") == true)
        _ = try await db.mailCounts()                     // the mail tables are there
        await db.close()
        #expect(try Data(contentsOf: url) == before)
    }

    /// A library the shipped build left (every table and mark of this build but the mail
    /// confidentiality column and its 'mail_confidential' row — or only that row lost): the app's
    /// next launch adds them (with a backup), so the inspection says an upgrade is due, changes
    /// nothing, and after that launch says nothing is due.
    @Test(arguments: [true, false])
    func aFileWithoutTheMailConfidentialityFeatureNeedsAnUpgrade(columnMissing: Bool) async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        do {
            let raw = try SQLiteConnection(path: url.path)
            try Migrations.prepare(raw, backupsDir: nil)
            if columnMissing { try raw.exec("ALTER TABLE mail_message DROP COLUMN confidential") }
            try raw.run("DELETE FROM schema_feature WHERE name = ?", [.text(Migrations.mailConfidentialFeature)])
            raw.close()
        }
        let before = try Data(contentsOf: url)
        let db = try await Database.openForInspection(url: url)
        #expect(db.inspection == Migrations.Inspection(level: Migrations.latestVersion, needsUpgrade: true))
        #expect(db.inspection?.upgradeNote == "schema v\(Migrations.latestVersion) needs this build's additions (open the app to upgrade)")
        _ = try await db.mailCounts()                     // the mail tables are there
        await db.close()
        #expect(try Data(contentsOf: url) == before, "the inspection open changed the database file")

        let opened = try await Database.open(url: url, backupsDir: nil)     // the app's launch
        await opened.close()
        let again = try await Database.openForInspection(url: url)
        #expect(again.inspection == Migrations.Inspection(level: Migrations.latestVersion, needsUpgrade: false))
        await again.close()
    }

    @Test func aNewerFileIsRefusedUntouched() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        do {
            let raw = try SQLiteConnection(path: url.path)
            try raw.exec("CREATE TABLE future(x); PRAGMA user_version = 99")
            raw.close()
        }
        let before = try Data(contentsOf: url)
        await #expect(throws: DatabaseError.newerSchema(found: 99, supported: Migrations.latestVersion)) {
            _ = try await Database.openForInspection(url: url)
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func aMissingFileIsNeverCreated() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Support/library.sqlite")
        await #expect(throws: (any Error).self) { _ = try await Database.openForInspection(url: url) }
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    @Test func aReadOnlyConnectionRefusesWrites() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        try Self.level1File(url)
        let raw = try SQLiteConnection(path: url.path, readOnly: true)
        defer { raw.close() }
        #expect(raw.isReadOnly)
        #expect(throws: SQLiteError.self) { try raw.run("INSERT INTO kv(key, value) VALUES('x', 'y')") }
        #expect(throws: SQLiteError.self) { try raw.setUserVersion(5) }
        #expect(try raw.userVersion() == 1)
    }
}
