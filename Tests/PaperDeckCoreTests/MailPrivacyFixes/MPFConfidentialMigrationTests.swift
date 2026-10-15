import Foundation
import Testing
@testable import PaperDeckCore

/// Mail privacy fixes, mail-ai-privacy-3 / extra 1: the stored capture-time verdict is the additive
/// feature ('mail_confidential', 1) — the nullable column `mail_message.confidential`, added to a
/// library in the currently shipped schema (user_version 1, 'mail' 1, 'assist' 1) after a
/// pre-migration backup, in one transaction with its marker and a backfill of every message whose
/// body is still stored. user_version and the shipped markers stay as they were, so the shipped
/// build's gate still opens the file and its explicit-column writes keep working.
@Suite struct MPFConfidentialMigrationTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-mailconf-mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `mail_message`'s columns as the shipped build (main before this fix) creates them.
    static let shippedMailColumns = [
        "pk", "id", "account_id", "source_ref", "internet_message_id", "from_address", "from_name", "rule_id",
        "sender_kind", "auth_state", "subject", "received_at", "web_link", "snippet", "body_text", "body_purged",
        "state", "user_touched", "snoozed_until", "triage_state", "triage_source", "triage_json",
        "triage_attempt", "triage_not_before", "triage_error", "triage_provider", "triage_model", "triage_ms",
        "triage_in_tokens", "triage_out_tokens", "triage_stdin_bytes", "seen", "created_at", "updated_at",
        "handled_at", "triage_consented", "triage_consent_provider", "is_bulk",
    ]

    private static func columns(_ raw: SQLiteConnection) throws -> [String] {
        try raw.query("SELECT name FROM pragma_table_info('mail_message') ORDER BY cid") { $0.string(0) }
    }

    /// The shipped build's own insert: it names its columns (no `confidential`).
    private static func insertLikeTheShippedBuild(_ raw: SQLiteConnection, id: String, subject: String, from: String,
                                                  kind: String = "alert", body: String?, purged: Bool) throws {
        let ts = Database.timestamp(t0)
        try raw.run("""
            INSERT INTO mail_message(id, account_id, internet_message_id, from_address, sender_kind, subject, received_at,
                                     body_text, body_purged, state, created_at, updated_at)
            VALUES(?1, 'acct', ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'dismissed', ?6, ?6)
            """, [.text(id), .text("<\(id)@example.org>"), .text(from), .text(kind), .text(subject), .text(ts),
                  .string(body), .bool(purged)])
    }

    /// A library as the shipped build leaves it — this build's full schema minus this feature — with
    /// four messages: a confidential one (by its body), a digest, and two whose bodies were purged.
    private static func makeShippedFile(at url: URL) throws {
        let raw = try SQLiteConnection(path: url.path)
        defer { raw.close() }
        try Migrations.prepare(raw, backupsDir: nil, now: t0)
        try raw.exec("ALTER TABLE mail_message DROP COLUMN confidential")
        try raw.exec("DELETE FROM schema_feature WHERE name = 'mail_confidential'")
        #expect(try columns(raw) == shippedMailColumns)
        #expect(try raw.userVersion() == 1)
        #expect(try Migrations.featureVersion(raw, Migrations.mailFeature) == 1)
        #expect(try Migrations.featureVersion(raw, Migrations.assistFeature) == 1)
        try insertLikeTheShippedBuild(raw, id: "m-invite", subject: "Request from Nature Neuroscience",
                                      from: "editor@neuroscience.nature.com",
                                      body: "Dear Dr. Example,\nI would like to invite you to review the attached manuscript.",
                                      purged: false)
        try insertLikeTheShippedBuild(raw, id: "m-digest", subject: "Nature Neuroscience: new issue",
                                      from: "alerts@neuroscience.nature.com",
                                      body: "New this month: cortical folding, radial glia and more.", purged: false)
        try insertLikeTheShippedBuild(raw, id: "m-purged-invite", subject: "Invitation to review manuscript NN-A12345",
                                      from: "editor@neuroscience.nature.com", body: nil, purged: true)
        try insertLikeTheShippedBuild(raw, id: "m-purged", subject: "Seminar on Thursday", from: "pi@lab.example.edu",
                                      kind: "advisor", body: nil, purged: true)
    }

    /// The shipped build's gate (its `Migrations.level`): user_version, the 'mail' and 'assist' rows.
    private static func shippedBuildOpens(_ url: URL) throws -> Bool {
        let raw = try SQLiteConnection(path: url.path)
        defer { raw.close() }
        let check = try raw.query("PRAGMA quick_check") { $0.string(0) }
        guard check == ["ok"], try raw.userVersion() <= 1 else { return false }
        return try Migrations.featureVersion(raw, Migrations.mailFeature) <= 1
            && Migrations.featureVersion(raw, Migrations.assistFeature) <= 1
    }

    @Test func theShippedSchemaGetsTheColumnAfterABackupAndIsBackfilled() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite"), backups = dir.appendingPathComponent("Backups")
        try Self.makeShippedFile(at: url)

        let db = try Database(url: url, backupsDir: backups)
        #expect(db.migration.fromVersion == 2 && db.migration.toVersion == 2)          // levels unchanged
        let backup = try #require(db.migration.backup)
        #expect(backup.lastPathComponent.hasPrefix("pre-migration-v2-mail_confidential-") && backup.pathExtension == "sqlite")
        func verdict(_ id: String) async throws -> Bool? { try #require(try await db.mailMessage(id: id)).confidential }
        #expect(try await verdict("m-invite") == true)
        #expect(try await verdict("m-digest") == false)
        #expect(try await verdict("m-purged-invite") == nil)                         // purged: not judged…
        #expect(try await verdict("m-purged") == nil)
        // …and read as before from what is left (the subject).
        #expect(MailHeuristics.isConfidential(try #require(try await db.mailMessage(id: "m-purged-invite"))))
        #expect(!MailHeuristics.isConfidential(try #require(try await db.mailMessage(id: "m-purged"))))
        await db.close()

        // The backup is the untouched shipped file.
        let copy = try SQLiteConnection(path: backup.path)
        #expect(try Self.columns(copy) == Self.shippedMailColumns)
        #expect(try Migrations.featureVersion(copy, Migrations.mailConfidentialFeature) == 0)
        copy.close()

        let raw = try SQLiteConnection(path: url.path)
        #expect(try Self.columns(raw) == Self.shippedMailColumns + ["confidential"])
        #expect(try raw.userVersion() == 1)
        #expect(try Migrations.featureVersion(raw, Migrations.mailFeature) == 1)
        #expect(try Migrations.featureVersion(raw, Migrations.assistFeature) == 1)
        #expect(try Migrations.featureVersion(raw, Migrations.mailConfidentialFeature) == 1)
        // The shipped build still opens it and writes with its own column list (the verdict stays NULL).
        raw.close()
        #expect(try Self.shippedBuildOpens(url))
        do {
            let old = try SQLiteConnection(path: url.path)
            try Self.insertLikeTheShippedBuild(old, id: "m-old-build", subject: "Lab meeting", from: "pi@lab.example.edu",
                                               kind: "advisor", body: "See you at noon.", purged: false)
            old.close()
        }

        // Reopening is a no-op: no second backup; the shipped build's row reads with no verdict.
        let again = try await Database.open(url: url, backupsDir: backups)
        #expect(again.migration == Migrations.Outcome(fromVersion: 2, toVersion: 2, backup: nil))
        #expect(try await again.mailMessage(id: "m-old-build")?.confidential == nil)
        #expect(try await again.mailMessage(id: "m-invite")?.confidential == true)
        await again.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).count == 1)
    }

    @Test func theBackfillOnlyJudgesRowsWithoutAVerdict() throws {
        let raw = try SQLiteConnection(path: ":memory:")
        defer { raw.close() }
        try Migrations.prepare(raw, backupsDir: nil, now: Self.t0)
        try Self.insertLikeTheShippedBuild(raw, id: "a", subject: "Invitation to review manuscript X-1", from: "e@x.example",
                                           body: "Dear Dr. Example", purged: false)
        try Self.insertLikeTheShippedBuild(raw, id: "b", subject: "Digest", from: "e@x.example", body: "Papers", purged: false)
        try raw.run("UPDATE mail_message SET confidential = 1 WHERE id = 'b'")          // already judged: kept
        #expect(try Migrations.backfillMailConfidential(raw) == 1)
        #expect(try Migrations.backfillMailConfidential(raw) == 0)                    // idempotent
        let verdicts = try raw.query("SELECT id, confidential FROM mail_message ORDER BY id") { ($0.string(0), $0.optionalInt(1)) }
        #expect(verdicts.map(\.0) == ["a", "b"] && verdicts.map(\.1) == [1, 1])
    }

    @Test func aColumnWithoutItsMarkerIsAdoptedWithoutABackup() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite"), backups = dir.appendingPathComponent("Backups")
        do {
            let raw = try SQLiteConnection(path: url.path)
            try Migrations.prepare(raw, backupsDir: nil, now: Self.t0)
            try raw.exec("DELETE FROM schema_feature WHERE name = 'mail_confidential'")
            raw.close()
        }
        let db = try Database(url: url, backupsDir: backups)
        #expect(db.migration == Migrations.Outcome(fromVersion: 2, toVersion: 2, backup: nil))
        await db.close()
        #expect(!FileManager.default.fileExists(atPath: backups.path))
        let raw = try SQLiteConnection(path: url.path)
        defer { raw.close() }
        #expect(try Migrations.featureVersion(raw, Migrations.mailConfidentialFeature) == 1)
    }

    @Test func aNewerMarkerIsRefusedUntouched() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        do {
            let raw = try SQLiteConnection(path: url.path)
            try Migrations.prepare(raw, backupsDir: nil, now: Self.t0)
            try raw.exec("UPDATE schema_feature SET version = 2 WHERE name = 'mail_confidential'")
            raw.close()
        }
        #expect(throws: DatabaseError.newerSchema(found: Migrations.latestVersion + 2,
                                                  supported: Migrations.latestVersion + Migrations.mailConfidentialFeatureVersion)) {
            _ = try Database(url: url, backupsDir: dir)
        }
        let raw = try SQLiteConnection(path: url.path)
        defer { raw.close() }
        #expect(try Migrations.featureVersion(raw, Migrations.mailConfidentialFeature) == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasPrefix("pre-migration") })
    }

    @Test func aFreshLibraryHasTheColumnAndNoBackup() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backups = dir.appendingPathComponent("Backups")
        let db = try Database(url: dir.appendingPathComponent("library.sqlite"), backupsDir: backups)
        #expect(db.migration == Migrations.Outcome(fromVersion: 0, toVersion: 2, backup: nil))
        let marks = try await db.transaction { db in
            (try db.db.userVersion(), try Migrations.featureVersion(db.db, Migrations.mailConfidentialFeature))
        }
        #expect(marks.0 == 1 && marks.1 == 1)
        let (saved, _) = try await db.insertMailMessage(
            MailMessage(accountID: "a", internetMessageID: "<fresh@example.org>", fromAddress: "a@example.org",
                        senderKind: .alert, subject: "s", receivedAt: Self.t0, confidential: true), items: [])
        #expect(try await db.mailMessage(pk: saved.pk)?.confidential == true)
        await db.close()
        #expect(!FileManager.default.fileExists(atPath: backups.path))
    }
}
