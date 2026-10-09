import Foundation
import Testing
@testable import PaperDeckCore

/// Round 3, r3-2 (integrity-4, core half): the additive mail schema no longer raises
/// `PRAGMA user_version`. It stays 1 — what the pre-mail build's gate accepts — and the mail
/// tables are recorded in `schema_feature` ('mail', 1), written with them after the
/// pre-migration backup. A pre-release file at user_version 2 is converted without data loss.
@Suite struct R3SchemaTests {
    private static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-r3-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The pre-mail build's open gate (Migrations of the v1-only release): user_version ≤ 1 is
    /// accepted as-is; anything newer is refused. Returns the paper titles it would show.
    private static func openLikeThePreMailBuild(_ url: URL) throws -> [String]? {
        let raw = try SQLiteConnection(path: url.path)
        defer { raw.close() }
        let check = try raw.query("PRAGMA quick_check") { $0.string(0) }
        guard check == ["ok"] else { return nil }
        guard try raw.userVersion() <= 1 else { return nil }          // "newer than this PaperDeck supports"
        return try raw.query("SELECT title FROM paper WHERE deleted_at IS NULL ORDER BY pk") { $0.string(0) }
    }

    /// The old build's own objects (everything but the mail tables, the additive assist feature's
    /// tables and indexes, the marker and SQLite's internal autoindex / stat tables), as SQL.
    private static func coreSchema(_ raw: SQLiteConnection) throws -> [String] {
        let feature = (Migrations.assistTables + Migrations.assistIndexes).map { "'\($0)'" }.joined(separator: ", ")
        return try raw.query("""
            SELECT type || ' ' || name || ' ' || COALESCE(sql, '') FROM sqlite_master
            WHERE name NOT LIKE 'mail_%' AND name NOT LIKE 'ix_mail%' AND name NOT LIKE 'ux_mail%'
              AND name NOT LIKE 'paper_source%' AND name NOT GLOB 'sqlite_*'
              AND name <> 'schema_feature' AND name NOT IN (\(feature))
            ORDER BY type, name
            """) { $0.string(0) }
    }

    private static func makeV1Library(at url: URL) throws {
        let raw = try SQLiteConnection(path: url.path)
        defer { raw.close() }
        try Migrations.prepare(raw, backupsDir: nil, now: t0, targetVersion: 1)
        try raw.run("""
            INSERT INTO paper(id, sha256, file_size, doi, title, title_rank, folder, pdf_name, original_name,
                              queue_rank, added_at, updated_at)
            VALUES('11111111-2222-3333-4444-555555555555', ?2, 1, '10.1/old', 'Old paper', 4, 'Papers/old',
                   'old.pdf', 'old.pdf', 1, ?1, ?1)
            """, [.text(Database.timestamp(t0)), .text(String(repeating: "b", count: 64))])
        try raw.run("INSERT INTO kv(key, value) VALUES('plan.skipDays', '[]')")
    }

    @Test func thePreMailBuildStillOpensALibraryAfterTheMailMigration() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        let backups = dir.appendingPathComponent("Backups")
        try Self.makeV1Library(at: url)
        let before: [String]
        do {
            let raw = try SQLiteConnection(path: url.path)
            before = try Self.coreSchema(raw)
            raw.close()
        }

        // This build migrates it: backup first, then the mail tables and their marker.
        let db = try Database(url: url, backupsDir: backups)
        #expect(db.migration.fromVersion == 1 && db.migration.toVersion == 2)
        let backup = try #require(db.migration.backup)
        #expect(backup.lastPathComponent.hasPrefix("pre-migration-v1-"))
        #expect(try await db.schemaVersion() == 2)
        _ = try await db.insertMailMessage(MailMessage(accountID: "a", internetMessageID: "<r3@x>", fromAddress: "a@x.org",
                                                       senderKind: .alert, subject: "s", receivedAt: Self.t0), items: [])
        await db.close()

        let raw = try SQLiteConnection(path: url.path)
        #expect(try raw.userVersion() == 1)
        #expect(try Migrations.featureVersion(raw, Migrations.mailFeature) == 1)
        #expect(try raw.scalarInt("SELECT count(*) FROM mail_message") == 1)
        let after = try Self.coreSchema(raw)
        #expect(after == before, "\(Set(after).symmetricDifference(before))")   // the old build's tables untouched
        raw.close()

        // The pre-mail build opens it and reads its papers.
        #expect(try Self.openLikeThePreMailBuild(url) == ["Old paper"])

        // The old build adds a paper of its own; this build opens the file again unchanged.
        do {
            let old = try SQLiteConnection(path: url.path)
            try old.run("""
                INSERT INTO paper(id, sha256, file_size, title, title_rank, folder, pdf_name, original_name,
                                  queue_rank, added_at, updated_at)
                VALUES('22222222-2222-3333-4444-555555555555', ?2, 1, 'Added by the old build', 4, 'Papers/new',
                       'new.pdf', 'new.pdf', 2, ?1, ?1)
                """, [.text(Database.timestamp(Self.t0)), .text(String(repeating: "c", count: 64))])
            old.close()
        }
        let again = try await Database.open(url: url, backupsDir: backups)
        #expect(again.migration == Migrations.Outcome(fromVersion: 2, toVersion: 2, backup: nil))
        #expect(Set(try await again.livePapers().map(\.title)) == ["Old paper", "Added by the old build"])
        #expect(try await again.mailMessage(internetMessageID: "<r3@x>") != nil)
        await again.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).count == 1)   // no second backup
    }

    @Test func aFreshLibraryKeepsUserVersionOne() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        let db = try Database(url: url, backupsDir: dir.appendingPathComponent("Backups"))
        #expect(db.migration == Migrations.Outcome(fromVersion: 0, toVersion: 2, backup: nil))
        await db.close()
        let raw = try SQLiteConnection(path: url.path)
        defer { raw.close() }
        #expect(try raw.userVersion() == 1)
        #expect(try Migrations.featureVersion(raw, Migrations.mailFeature) == 1)
        #expect(try Self.openLikeThePreMailBuild(url) == [])
    }

    /// A development build wrote user_version 2 with the mail tables: converted to 1 + the
    /// marker at open, every row kept, no backup, and the pre-mail build can open it afterwards.
    @Test func aPrereleaseUserVersionTwoFileIsConvertedWithoutDataLoss() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        let backups = dir.appendingPathComponent("Backups")
        try Self.makeV1Library(at: url)
        do {
            // The pre-release layout: mail tables (without the late consent columns), no marker, v2.
            let raw = try SQLiteConnection(path: url.path)
            try Migrations.prepare(raw, backupsDir: nil, now: Self.t0)
            try raw.exec("DROP TABLE schema_feature")
            try raw.exec("ALTER TABLE mail_message DROP COLUMN triage_consent_provider")
            try raw.exec("ALTER TABLE mail_message DROP COLUMN triage_consented")
            try raw.run("""
                INSERT INTO mail_message(id, internet_message_id, from_address, received_at, created_at, updated_at, body_text)
                VALUES('m1', '<pre@x>', 'a@x', '2026-09-30T10:00:00.000Z', '2026-09-30T10:00:00.000Z',
                       '2026-09-30T10:00:00.000Z', 'kept body')
                """)
            try raw.exec("PRAGMA user_version = 2")
            raw.close()
        }
        #expect(try Self.openLikeThePreMailBuild(url) == nil)               // the bug: the old build refused it

        let db = try await Database.open(url: url, backupsDir: backups)
        #expect(db.migration == Migrations.Outcome(fromVersion: 2, toVersion: 2, backup: nil))
        #expect(try await db.schemaVersion() == 2)
        let m = try #require(try await db.mailMessage(id: "m1"))
        #expect(m.bodyText == "kept body" && !m.triageConsented)
        #expect(try await db.livePapers().map(\.title) == ["Old paper"])
        #expect(try await db.kv("plan.skipDays") == "[]")
        await db.close()

        let raw = try SQLiteConnection(path: url.path)
        #expect(try raw.userVersion() == 1)
        #expect(try Migrations.featureVersion(raw, Migrations.mailFeature) == 1)
        raw.close()
        #expect(try Self.openLikeThePreMailBuild(url) == ["Old paper"])
        #expect(!FileManager.default.fileExists(atPath: backups.path))
    }

    /// user_version 2 without the mail tables is not the pre-release layout: refused, untouched.
    /// A mail marker newer than this build is refused too; a core version above 2 as before.
    @Test func genuinelyNewerFilesAreStillRefused() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.sqlite")
        do {
            let raw = try SQLiteConnection(path: a.path)
            try raw.exec("CREATE TABLE future(x); PRAGMA user_version = 2")
            raw.close()
        }
        #expect(throws: DatabaseError.newerSchema(found: 2, supported: 1)) { _ = try Database(url: a, backupsDir: dir) }

        let b = dir.appendingPathComponent("b.sqlite")
        do {
            let raw = try SQLiteConnection(path: b.path)
            try Migrations.prepare(raw, backupsDir: nil)
            try raw.exec("UPDATE schema_feature SET version = 2 WHERE name = 'mail'")
            raw.close()
        }
        #expect(throws: DatabaseError.newerSchema(found: 3, supported: Migrations.latestVersion)) {
            _ = try Database(url: b, backupsDir: dir)
        }
        let raw = try SQLiteConnection(path: b.path)
        defer { raw.close() }
        #expect(try Migrations.featureVersion(raw, Migrations.mailFeature) == 2)    // untouched
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasPrefix("pre-migration") })
    }
}
