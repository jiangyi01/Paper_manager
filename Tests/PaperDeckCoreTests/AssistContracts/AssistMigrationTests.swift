import Foundation
import Testing
@testable import PaperDeckCore

/// Slice 0 contract (READING_ASSIST_PLAN §5, §9.1): the additive assist feature. On a level-2
/// library (build 28: library + mail) a full open backs the file up, creates the assist tables and
/// writes `schema_feature('assist', 1)` — `user_version` stays 1 and the mail row is untouched — and
/// an older build (its gate reads user_version and the mail row only) still opens the file.
@Suite struct AssistMigrationTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-assist-mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A library as build 28 left it: level 2 (mail), no assist tables, one paper with a mail
    /// provenance row and a kv row.
    private static func makeLevel2File(at url: URL) throws {
        let raw = try SQLiteConnection(path: url.path)
        defer { raw.close() }
        let outcome = try Migrations.prepare(raw, backupsDir: nil, now: t0, features: false)
        #expect(outcome == Migrations.Outcome(fromVersion: 0, toVersion: 2, backup: nil))
        try raw.run("""
            INSERT INTO paper(id, sha256, file_size, doi, title, title_rank, folder, pdf_name, original_name,
                              queue_rank, added_at, updated_at)
            VALUES('11111111-2222-3333-4444-555555555555', ?2, 1, '10.1/old', 'Old paper', 4, 'Papers/old',
                   'old.pdf', 'old.pdf', 1, ?1, ?1)
            """, [.text(Database.timestamp(t0)), .text(String(repeating: "b", count: 64))])
        try raw.run("INSERT INTO paper_source(paper_pk, internet_message_id, added_at) VALUES(1, '<m@x>', ?)",
                    [.text(Database.timestamp(t0))])
        try raw.run("INSERT INTO kv(key, value) VALUES('plan.skipDays', '[]')")
    }

    /// Build 28's gate (Migrations.level of that build): user_version and the mail row only; nil = refused.
    private static func openLikeBuild28(_ url: URL) throws -> (level: Int, titles: [String])? {
        let raw = try SQLiteConnection(path: url.path)
        defer { raw.close() }
        let check = try raw.query("PRAGMA quick_check") { $0.string(0) }
        guard check == ["ok"] else { return nil }
        let uv = try raw.userVersion()
        guard uv <= 1 else { return nil }
        let hasFeature = (try raw.scalarInt("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='schema_feature'") ?? 0) > 0
        let mail = hasFeature ? Int(try raw.scalarInt("SELECT version FROM schema_feature WHERE name = 'mail'") ?? 0) : 0
        guard mail <= 1 else { return nil }
        let titles = try raw.query("SELECT title FROM paper WHERE deleted_at IS NULL ORDER BY pk") { $0.string(0) }
        return (uv == 1 && mail >= 1 ? 2 : uv, titles)
    }

    private static func objects(_ raw: SQLiteConnection) throws -> Set<String> {
        Set(try raw.query("SELECT name FROM sqlite_master WHERE name NOT GLOB 'sqlite_*'") { $0.string(0) })
    }

    @Test func aLevel2LibraryGetsTheAssistTablesAfterABackup() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite"), backups = dir.appendingPathComponent("Backups")
        try Self.makeLevel2File(at: url)
        let before: (objects: Set<String>, mailRow: Int64?)
        do {
            let raw = try SQLiteConnection(path: url.path)
            before = (try Self.objects(raw), try raw.scalarInt("SELECT version FROM schema_feature WHERE name='mail'"))
            raw.close()
        }
        #expect(before.objects.isDisjoint(with: Migrations.assistTables))

        let db = try Database(url: url, backupsDir: backups)
        #expect(db.migration.fromVersion == 2 && db.migration.toVersion == 2)       // levels unchanged
        let backup = try #require(db.migration.backup)
        #expect(backup.lastPathComponent.hasPrefix("pre-migration-v2-assist-") && backup.pathExtension == "sqlite")
        #expect(try await db.schemaVersion() == 2)
        #expect(try await db.livePapers().map(\.title) == ["Old paper"])
        #expect(try await db.kv("plan.skipDays") == "[]")
        await db.close()

        // The backup is the untouched level-2 file.
        let copy = try SQLiteConnection(path: backup.path)
        #expect(try Self.objects(copy) == before.objects)
        copy.close()

        let raw = try SQLiteConnection(path: url.path)
        #expect(try raw.userVersion() == 1)
        #expect(try raw.scalarInt("SELECT version FROM schema_feature WHERE name='mail'") == before.mailRow)
        #expect(try Migrations.featureVersion(raw, Migrations.assistFeature) == 1)
        let after = try Self.objects(raw)
        #expect(after == before.objects.union(Migrations.assistTables).union(Migrations.assistIndexes),
                "\(after.symmetricDifference(before.objects.union(Migrations.assistTables).union(Migrations.assistIndexes)))")
        raw.close()

        // Build 28 still opens it (level 2, its papers), ignoring the new tables.
        let old = try #require(try Self.openLikeBuild28(url))
        #expect(old.level == 2 && old.titles == ["Old paper"])

        // Reopening is a no-op: no second backup.
        let again = try await Database.open(url: url, backupsDir: backups)
        #expect(again.migration == Migrations.Outcome(fromVersion: 2, toVersion: 2, backup: nil))
        await again.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).count == 1)
    }

    @Test func aLevel1LibraryIsMigratedWithOneBackup() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite"), backups = dir.appendingPathComponent("Backups")
        do {
            let raw = try SQLiteConnection(path: url.path)
            try Migrations.prepare(raw, backupsDir: nil, now: Self.t0, targetVersion: 1)
            raw.close()
        }
        let db = try Database(url: url, backupsDir: backups)
        #expect(db.migration.fromVersion == 1 && db.migration.toVersion == 2)
        #expect(db.migration.backup?.lastPathComponent.hasPrefix("pre-migration-v1-") == true)
        await db.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).count == 1)
        let raw = try SQLiteConnection(path: url.path)
        defer { raw.close() }
        #expect(try raw.userVersion() == 1)
        #expect(try Migrations.featureVersion(raw, Migrations.mailFeature) == 1)
        #expect(try Migrations.featureVersion(raw, Migrations.assistFeature) == 1)
    }

    @Test func aFreshLibraryHasEverythingAndNoBackup() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backups = dir.appendingPathComponent("Backups")
        let db = try Database(url: dir.appendingPathComponent("library.sqlite"), backupsDir: backups)
        #expect(db.migration == Migrations.Outcome(fromVersion: 0, toVersion: 2, backup: nil))
        let marks = try await db.transaction { db in
            (try db.db.userVersion(), try Migrations.featureVersion(db.db, Migrations.mailFeature),
             try Migrations.featureVersion(db.db, Migrations.assistFeature))
        }
        #expect(marks.0 == 1 && marks.1 == 1 && marks.2 == 1)
        await db.close()
        #expect(!FileManager.default.fileExists(atPath: backups.path))
        let mem = try Database.inMemory()
        let tables = try await mem.transaction { db in
            Set(try db.db.query("SELECT name FROM sqlite_master WHERE type = 'table'") { $0.string(0) })
        }
        #expect(tables.isSuperset(of: Migrations.assistTables))
    }

    @Test func tablesWithoutTheirMarkerAreAdoptedWithoutABackup() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite"), backups = dir.appendingPathComponent("Backups")
        do {
            let raw = try SQLiteConnection(path: url.path)
            try Migrations.prepare(raw, backupsDir: nil, now: Self.t0)
            try raw.exec("DELETE FROM schema_feature WHERE name = 'assist'")
            raw.close()
        }
        let db = try Database(url: url, backupsDir: backups)
        #expect(db.migration == Migrations.Outcome(fromVersion: 2, toVersion: 2, backup: nil))
        await db.close()
        #expect(!FileManager.default.fileExists(atPath: backups.path))
        let raw = try SQLiteConnection(path: url.path)
        defer { raw.close() }
        #expect(try Migrations.featureVersion(raw, Migrations.assistFeature) == 1)
    }

    @Test func aNewerAssistMarkerIsRefusedUntouched() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        do {
            let raw = try SQLiteConnection(path: url.path)
            try Migrations.prepare(raw, backupsDir: nil, now: Self.t0)
            try raw.exec("UPDATE schema_feature SET version = 2 WHERE name = 'assist'")
            raw.close()
        }
        #expect(throws: DatabaseError.newerSchema(found: Migrations.latestVersion + 2,
                                                  supported: Migrations.latestVersion + Migrations.assistFeatureVersion)) {
            _ = try Database(url: url, backupsDir: dir)
        }
        let raw = try SQLiteConnection(path: url.path)
        defer { raw.close() }
        #expect(try Migrations.featureVersion(raw, Migrations.assistFeature) == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasPrefix("pre-migration") })
        // Build 28 still opens it: it never reads the assist row.
        #expect(try Self.openLikeBuild28(url)?.level == 2)
    }

    /// An older build hard-deletes a paper with foreign keys on (its configure does): every assist
    /// row of the paper goes with it; explanations keep their text with the paper unset.
    @Test func anOlderBuildsHardDeleteCascades() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        let raw = try SQLiteConnection(path: url.path)
        defer { raw.close() }
        try Migrations.prepare(raw, backupsDir: nil, now: Self.t0)
        let ts = Database.timestamp(Self.t0)
        try raw.run("""
            INSERT INTO paper(id, sha256, file_size, title, title_rank, folder, pdf_name, original_name, queue_rank, added_at, updated_at)
            VALUES('p1', ?2, 1, 'A', 4, 'Papers/a', 'a.pdf', 'a.pdf', 1, ?1, ?1), ('p2', ?3, 1, 'B', 4, 'Papers/b', 'b.pdf', 'b.pdf', 2, ?1, ?1)
            """, [.text(ts), .text(String(repeating: "a", count: 64)), .text(String(repeating: "c", count: 64))])
        try raw.run("INSERT INTO paper_policy(paper_pk, confidential, never_ai, set_by, set_at) VALUES(1, 1, 0, 'user', ?)", [.text(ts)])
        try raw.run("INSERT INTO paper_key(paper_pk, kind, value, source) VALUES(1, 'doi', '10.1/a', 'local')")
        try raw.run("INSERT INTO reading_cycle(paper_pk, n, started_at) VALUES(1, 1, ?)", [.text(ts)])
        try raw.run("INSERT INTO dup_pair(a_pk, b_pk, decision, decided_by, decided_at) VALUES(1, 2, 'distinct', 'user', ?)", [.text(ts)])
        try raw.run("INSERT INTO qa_thread(id, scope, title, created_at, updated_at) VALUES('t1', 'paper', 'T', ?1, ?1)", [.text(ts)])
        try raw.run("INSERT INTO qa_thread_paper(thread_pk, paper_pk, ord) VALUES(1, 1, 0)")
        try raw.run("""
            INSERT INTO explanation(id, paper_pk, thread_id, source, action, lang, answer, provider, created_at)
            VALUES('e1', 1, 'th', 'clipboard', 'explain', 'zh', 'answer', 'mock', ?)
            """, [.text(ts)])
        // The old build: foreign_keys = ON (Migrations.configure), DELETE FROM paper.
        try raw.exec("PRAGMA foreign_keys = ON")
        try raw.run("DELETE FROM paper WHERE pk = 1")
        for table in ["paper_policy", "paper_key", "reading_cycle", "dup_pair", "qa_thread_paper"] {
            #expect(try raw.scalarInt("SELECT count(*) FROM \(table)") == 0, "\(table)")
        }
        #expect(try raw.scalarInt("SELECT count(*) FROM qa_thread") == 1)        // threads are kept (C prunes)
        #expect(try raw.scalarInt("SELECT count(*) FROM explanation WHERE paper_pk IS NULL") == 1)
        #expect(try raw.query("PRAGMA foreign_key_check") { $0.string(0) }.isEmpty)
    }

    /// The CHECK lists are frozen: every `ExplainSource` is storable, nothing else is.
    @Test func theExplanationSourceListMatchesTheModel() throws {
        let raw = try SQLiteConnection(path: ":memory:")
        defer { raw.close() }
        try Migrations.prepare(raw, backupsDir: nil, now: Self.t0)
        let ts = Database.timestamp(Self.t0)
        for (i, source) in ExplainSource.allCases.enumerated() {
            try raw.run("""
                INSERT INTO explanation(id, thread_id, source, action, lang, answer, provider, created_at)
                VALUES(?, 'th', ?, 'explain', 'en', 'a', 'mock', ?)
                """, [.text("e\(i)"), .text(source.rawValue), .text(ts)])
        }
        #expect(throws: (any Error).self) {
            try raw.run("""
                INSERT INTO explanation(id, thread_id, source, action, lang, answer, provider, created_at)
                VALUES('bad', 'th', 'followup', 'explain', 'en', 'a', 'mock', ?)
                """, [.text(ts)])
        }
    }
}
