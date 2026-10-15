import Foundation
import SQLite3

/// Why the library database could not be opened or a write could not proceed.
package enum DatabaseError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `user_version` is newer than this build understands — refuse rather than corrupt it.
    case newerSchema(found: Int, supported: Int)
    /// quick_check failed or the file is not a database; caller moves it aside and rebuilds.
    case corrupt(String)
    /// A write targeted a row that does not exist.
    case notFound(String)
    /// An insert collided with an existing row's natural key (e.g. a mail Message-ID).
    case duplicate(String)

    package var description: String {
        switch self {
        case .newerSchema(let found, let supported):
            return "Database schema v\(found) is newer than this PaperDeck supports (v\(supported))"
        case .corrupt(let detail): return "Database is corrupt: \(detail)"
        case .notFound(let what): return "Not found: \(what)"
        case .duplicate(let what): return "Already exists: \(what)"
        }
    }
}

/// Connection setup and forward-only schema migrations (§5).
///
/// Two marks on disk (review integrity-4): `PRAGMA user_version` is the library core and stays
/// at 1, so a PaperDeck from before mail (its gate accepts user_version ≤ 1) can still open a
/// library this build has used; the additive mail tables are recorded separately, as the row
/// ('mail', 1) of `schema_feature`, written in the transaction that creates them (after a
/// pre-migration backup, like any migration of an existing file). An older build ignores both
/// the table and the mail tables; nothing of its own schema is touched.
///
/// `latestVersion`, `targetVersion`, `Outcome` and `Database.schemaVersion()` count schema
/// *levels*: 1 = library, 2 = library + mail. user_version 2 is what pre-release mail builds
/// wrote; such a file (it has the mail tables) is converted at open to user_version 1 + the
/// marker — no data changes, no backup needed. A future core migration must therefore use
/// user_version 3 or later (refused here as newer, like any other unknown version).
///
/// Additive features after the levels (READING_ASSIST_PLAN §5): the reading-assist tables are the
/// row ('assist', 1) of `schema_feature`, created by a full `prepare` (not counted in the levels,
/// so `latestVersion` stays 2 and an older build's gate — user_version + the mail row — is
/// unchanged). An existing file gets the pre-migration backup first, as for any migration; a file
/// that already has every assist table but lost its marker is adopted without one. A marker newer
/// than this build understands is refused like a newer schema, before anything is written.
///
/// The capture-time confidentiality verdict is another additive feature, the row
/// ('mail_confidential', 1): the nullable column `mail_message.confidential`, backfilled for every
/// message whose body is still stored (`MailHeuristics.isConfidential` on its subject and body; a
/// purged one stays NULL and is judged as before). Same rules: backup first, one transaction,
/// adopted without a backup when the column is already there, refused when newer. An older build
/// names its columns, so it keeps reading and writing the file (its new rows get NULL).
package enum Migrations {
    package static let latestVersion = 2
    /// `PRAGMA user_version` of the library core this build writes.
    package static let coreUserVersion = 1
    /// The mail tables' row in `schema_feature`, and its version.
    package static let mailFeature = "mail"
    package static let mailFeatureVersion = 1
    /// user_version pre-release mail builds wrote (library + mail in one number).
    package static let prereleaseMailUserVersion = 2
    /// The reading-assist tables' row in `schema_feature` (`SchemaAssist.swift`), and its version.
    package static let assistFeature = "assist"
    package static let assistFeatureVersion = 1
    /// The capture-time confidentiality verdict's row (`mail_message.confidential`), and its version.
    package static let mailConfidentialFeature = "mail_confidential"
    package static let mailConfidentialFeatureVersion = 1

    /// What `prepare` did, for logging.
    package struct Outcome: Sendable, Equatable {
        package var fromVersion: Int
        package var toVersion: Int
        package var backup: URL?
    }

    /// What `inspect` found in a file it only read (`Database.openForInspection`, `--doctor`).
    package struct Inspection: Sendable, Equatable {
        /// `level` of the file: 0 (empty), 1 (library), 2 (library + mail).
        package var level: Int
        /// This build's `prepare` would change the file: a level migration, the assist tables, the
        /// mail marks, the pre-release columns or the mail confidentiality column (or its marker).
        /// The app does that (with its pre-migration backup) at its next launch; a diagnostic never does.
        package var needsUpgrade: Bool

        package init(level: Int, needsUpgrade: Bool) {
            self.level = level; self.needsUpgrade = needsUpgrade
        }

        /// "schema v1 (this build expects v2 — open the app to upgrade)"; nil when nothing is due.
        package var upgradeNote: String? {
            guard needsUpgrade else { return nil }
            return level < Migrations.latestVersion
                ? "schema v\(level) (this build expects v\(Migrations.latestVersion) — open the app to upgrade)"
                : "schema v\(level) needs this build's additions (open the app to upgrade)"
        }
    }

    /// quick_check, the version gate and the work a full `prepare` would do — reads only (no
    /// pragma that writes, no transaction), so it is safe on a read-only connection. Throws
    /// `.corrupt` / `.newerSchema` like `prepare`.
    package static func inspect(_ db: SQLiteConnection) throws -> Inspection {
        try db.exec("PRAGMA busy_timeout = 3000")
        try quickCheck(db)
        let level = try level(db)
        var needs = level < latestVersion
        if try featureVersion(db, assistFeature) < assistFeatureVersion { needs = true }
        if level >= 2 {
            if try db.userVersion() != coreUserVersion || featureVersion(db, mailFeature) < mailFeatureVersion { needs = true }
            if try !missingPrereleaseColumns(db).isEmpty { needs = true }
        }
        // `ensureMailConfidentialFeature`'s own condition: the column and its marker (or just the marker).
        if try featureVersion(db, mailConfidentialFeature) < mailConfidentialFeatureVersion, try tableExists(db, "mail_message") {
            needs = true
        }
        return Inspection(level: level, needsUpgrade: needs)
    }

    /// `PRAGMA quick_check`; throws `.corrupt` unless it says "ok".
    private static func quickCheck(_ db: SQLiteConnection) throws {
        let check: [String]
        do {
            check = try db.query("PRAGMA quick_check") { $0.string(0) }
        } catch let e as SQLiteError where e.isCorruption {
            throw DatabaseError.corrupt(e.message)
        }
        guard check == ["ok"] else { throw DatabaseError.corrupt(check.prefix(5).joined(separator: "; ")) }
    }

    /// Per-connection pragmas. WAL is persistent in the file; the others are not.
    package static func configure(_ db: SQLiteConnection) throws {
        try db.exec("PRAGMA busy_timeout = 3000")
        try db.exec("PRAGMA foreign_keys = ON")
        try db.exec("PRAGMA synchronous = NORMAL")
        // Zero freed b-tree space when it costs no extra I/O, so deleted/purged mail bodies
        // don't linger in the main file's pages (WAL and backups age out on their own).
        try db.exec("PRAGMA secure_delete = FAST")
        try db.exec("PRAGMA journal_mode = WAL")
    }

    /// quick_check → pragmas → version gate → pre-migration backup → migrations → features.
    /// `backupsDir == nil` skips the backup (in-memory and scratch DBs).
    /// `targetVersion` below `latestVersion` stops early — only tests use it, to build a
    /// file with an older schema (level 1: a library from before mail) that a later open
    /// then migrates. The additive features (the assist tables) are created only by a full
    /// prepare; `features: false` leaves them out (tests: a level-2 file as build 28 left it).
    @discardableResult
    package static func prepare(_ db: SQLiteConnection, backupsDir: URL?, now: Date = Date(),
                                targetVersion: Int = latestVersion, features: Bool = true) throws -> Outcome {
        precondition((1...latestVersion).contains(targetVersion), "unknown schema v\(targetVersion)")
        try db.exec("PRAGMA busy_timeout = 3000")
        try quickCheck(db)

        try configure(db)
        let from = try level(db)                    // throws `newerSchema` before anything is written
        var outcome = Outcome(fromVersion: from, toVersion: from, backup: nil)
        if from >= 2 { try normalizeMailMarks(db) }
        if from < targetVersion {
            let hasSchema = (try db.scalarInt("SELECT count(*) FROM sqlite_master") ?? 0) > 0
            if hasSchema, let backupsDir {
                outcome.backup = try backup(db, to: backupsDir, fromVersion: from, now: now)
            }
            for version in (from + 1)...targetVersion {
                try db.transaction(immediate: true) {
                    try apply(version, on: db, now: now)
                }
                outcome.toVersion = version
                Log.db.info("Migrated database to schema v\(version)")
            }
        }
        if features, targetVersion == latestVersion {
            try ensureAssistFeature(db, backupsDir: backupsDir, fromLevel: from, now: now, outcome: &outcome)
            try ensureMailConfidentialFeature(db, backupsDir: backupsDir, fromLevel: from, now: now, outcome: &outcome)
        }
        return outcome
    }

    /// `mail_message.confidential` and its marker, in one transaction, with the backfill: every
    /// message whose body is still stored gets the guard's verdict on its subject and body (a purged
    /// one keeps NULL — `MailHeuristics.isConfidential(_ m:)` then reads what is left, as before). A
    /// file that existed before this prepare is backed up first unless this prepare already did; a
    /// file whose column is there (its marker was lost) only gets the marker back.
    private static func ensureMailConfidentialFeature(_ db: SQLiteConnection, backupsDir: URL?, fromLevel: Int, now: Date,
                                                      outcome: inout Outcome) throws {
        guard try featureVersion(db, mailConfidentialFeature) < mailConfidentialFeatureVersion,
              try tableExists(db, "mail_message") else { return }
        if try columnExists(db, table: "mail_message", column: "confidential") {
            try db.transaction(immediate: true) { try markFeature(db, mailConfidentialFeature, mailConfidentialFeatureVersion) }
            Log.db.info("Mail confidentiality column recorded in schema_feature")
            return
        }
        if fromLevel >= 1, outcome.backup == nil, let backupsDir {
            outcome.backup = try backup(db, to: backupsDir, fromVersion: fromLevel, now: now, tag: mailConfidentialFeature)
        }
        let filled = try db.transaction(immediate: true) { () throws -> Int in
            try db.exec("ALTER TABLE mail_message ADD COLUMN confidential INTEGER")
            let n = try backfillMailConfidential(db)
            try markFeature(db, mailConfidentialFeature, mailConfidentialFeatureVersion)
            return n
        }
        Log.db.info("Added mail_message.confidential (schema_feature \(mailConfidentialFeature, privacy: .public) = \(mailConfidentialFeatureVersion, privacy: .public), \(filled, privacy: .public) messages judged)")
    }

    /// The verdict for every message with a stored body and no verdict yet (idempotent: only NULL
    /// rows are written; `updated_at` is left alone — nothing about the message changed). Returns how
    /// many rows were judged. Bodies never leave this function (nothing is logged).
    package static func backfillMailConfidential(_ db: SQLiteConnection) throws -> Int {
        var after: Int64 = 0, judged = 0
        while true {
            // In pages (bodies are up to 20 000 characters each): only one page is in memory.
            let rows = try db.query("""
                SELECT pk, subject, from_address, body_text FROM mail_message
                WHERE confidential IS NULL AND body_purged = 0 AND pk > ? ORDER BY pk LIMIT 200
                """, [.integer(after)]) { (pk: $0.int64(0), subject: $0.string(1), from: $0.string(2), body: $0.optionalString(3)) }
            guard let last = rows.last else { return judged }
            for r in rows {
                let verdict = MailHeuristics.isConfidential(subject: r.subject, fromAddress: r.from, body: r.body)
                try db.run("UPDATE mail_message SET confidential = ? WHERE pk = ? AND confidential IS NULL",
                           [.bool(verdict), .integer(r.pk)])
            }
            judged += rows.count
            after = last.pk
        }
    }

    private static func columnExists(_ db: SQLiteConnection, table: String, column: String) throws -> Bool {
        try db.query("SELECT name FROM pragma_table_info(?)", [.text(table)]) { $0.string(0) }.contains(column)
    }

    /// The reading-assist tables and their marker, in one transaction. A file that existed before
    /// this prepare (level ≥ 1) is backed up first unless the level migration just did; a file that
    /// already has every assist table (its marker was lost) only gets the marker back.
    private static func ensureAssistFeature(_ db: SQLiteConnection, backupsDir: URL?, fromLevel: Int, now: Date,
                                            outcome: inout Outcome) throws {
        guard try featureVersion(db, assistFeature) < assistFeatureVersion else { return }
        if try hasAssistTables(db) {
            try db.transaction(immediate: true) { try markFeature(db, assistFeature, assistFeatureVersion) }
            Log.db.info("Assist tables recorded in schema_feature")
            return
        }
        if fromLevel >= 1, outcome.backup == nil, let backupsDir {
            outcome.backup = try backup(db, to: backupsDir, fromVersion: fromLevel, now: now, tag: assistFeature)
        }
        try db.transaction(immediate: true) {
            try db.exec(schemaAssist)
            try markFeature(db, assistFeature, assistFeatureVersion)
        }
        Log.db.info("Added the assist tables (schema_feature assist = \(assistFeatureVersion, privacy: .public))")
    }

    private static func hasAssistTables(_ db: SQLiteConnection) throws -> Bool {
        for table in assistTables where try !tableExists(db, table) { return false }
        return true
    }

    /// The schema level of an open file: 0 (empty / unversioned), 1 (library), 2 (library +
    /// mail: the marker, the pre-release user_version 2 with the mail tables, or mail tables a
    /// marker-less file already has). Throws `newerSchema` for a file a newer build wrote.
    package static func level(_ db: SQLiteConnection) throws -> Int {
        let found = try db.userVersion()
        switch found {
        case ..<coreUserVersion:
            return found
        case coreUserVersion:
            let mail = try featureVersion(db, mailFeature)
            if mail > mailFeatureVersion {
                throw DatabaseError.newerSchema(found: coreUserVersion + mail, supported: latestVersion)
            }
            let assist = try featureVersion(db, assistFeature)
            if assist > assistFeatureVersion {
                throw DatabaseError.newerSchema(found: latestVersion + assist,
                                                supported: latestVersion + assistFeatureVersion)
            }
            let confidential = try featureVersion(db, mailConfidentialFeature)
            if confidential > mailConfidentialFeatureVersion {
                throw DatabaseError.newerSchema(found: latestVersion + confidential,
                                                supported: latestVersion + mailConfidentialFeatureVersion)
            }
            if mail >= 1 { return 2 }
            return try hasMailTables(db) ? 2 : 1
        case prereleaseMailUserVersion:
            guard try hasMailTables(db) else {
                throw DatabaseError.newerSchema(found: found, supported: coreUserVersion)
            }
            return 2
        default:
            throw DatabaseError.newerSchema(found: found, supported: latestVersion)
        }
    }

    /// Version of a `schema_feature` row; 0 when the table or the row is missing.
    package static func featureVersion(_ db: SQLiteConnection, _ name: String) throws -> Int {
        guard try tableExists(db, "schema_feature") else { return 0 }
        return Int(try db.scalarInt("SELECT version FROM schema_feature WHERE name = ?", [.text(name)]) ?? 0)
    }

    private static func tableExists(_ db: SQLiteConnection, _ name: String) throws -> Bool {
        (try db.scalarInt("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(name)]) ?? 0) > 0
    }

    private static func hasMailTables(_ db: SQLiteConnection) throws -> Bool {
        try tableExists(db, "mail_message") && tableExists(db, "mail_item") && tableExists(db, "paper_source")
    }

    /// A level-2 file as this build keeps it: user_version 1, the mail marker, the pre-release
    /// columns. Converts a pre-release file (user_version 2) or adopts mail tables without a
    /// marker in one transaction; otherwise only the idempotent column repair runs.
    private static func normalizeMailMarks(_ db: SQLiteConnection) throws {
        let found = try db.userVersion()
        let marked = try featureVersion(db, mailFeature) >= 1
        guard found != coreUserVersion || !marked else {
            try repairPrereleaseColumns(db)
            return
        }
        try db.transaction(immediate: true) {
            try markMailFeature(db)
            try repairPrereleaseColumns(db)
            try db.setUserVersion(coreUserVersion)
        }
        Log.db.info("Mail schema recorded in schema_feature (user_version \(found, privacy: .public) → \(coreUserVersion, privacy: .public))")
    }

    private static func markMailFeature(_ db: SQLiteConnection) throws {
        try markFeature(db, mailFeature, mailFeatureVersion)
    }

    private static func markFeature(_ db: SQLiteConnection, _ name: String, _ version: Int) throws {
        try db.exec("CREATE TABLE IF NOT EXISTS schema_feature(name TEXT PRIMARY KEY, version INTEGER NOT NULL) WITHOUT ROWID")
        try db.run("INSERT INTO schema_feature(name, version) VALUES(?, ?) ON CONFLICT(name) DO UPDATE SET version = excluded.version",
                   [.text(name), .int(version)])
    }

    /// Columns the mail schema gained after its tables were first created. A database that
    /// already has the mail tables gets the missing ones added at open (idempotent; nothing else
    /// is touched, so no backup). Only nullable or defaulted columns, so an older build — which
    /// names its columns explicitly — keeps reading and writing the file.
    /// - `triage_consented`, `triage_consent_provider`: before the mail schema first shipped.
    /// - `is_bulk` (mail policy round 5): mailing-list mail; NULL for messages captured before.
    /// - `mail_item.origin_ext`, `pdf_state_ext`, `document_*`, `share_host` (documents & share links):
    ///   the exact origin / PDF state of a document or share-link row — the frozen CHECK lists keep
    ///   `attachment` / `link` / `needs_pdf` in the old columns, which an older build reads — and the
    ///   stored original; `paper_source.document`: the original kept next to a converted paper's PDF.
    package static let prereleaseV2Columns: [(table: String, column: String, definition: String)] = [
        ("mail_message", "triage_consented", "INTEGER NOT NULL DEFAULT 0"),
        ("mail_message", "triage_consent_provider", "TEXT"),
        ("mail_message", "is_bulk", "INTEGER"),
        ("mail_item", "origin_ext", "TEXT"),
        ("mail_item", "pdf_state_ext", "TEXT"),
        ("mail_item", "document_name", "TEXT"),
        ("mail_item", "document_kind", "TEXT"),
        ("mail_item", "document_path", "TEXT"),
        ("mail_item", "document_sha256", "TEXT"),
        ("mail_item", "share_host", "TEXT"),
        ("paper_source", "document", "TEXT"),
    ]

    private static func repairPrereleaseColumns(_ db: SQLiteConnection) throws {
        for (table, column, definition) in try missingPrereleaseColumns(db) {
            try db.exec("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
            Log.db.info("Added the pre-release column \(column, privacy: .public) to \(table, privacy: .public)")
        }
    }

    /// The `prereleaseV2Columns` an existing mail table lacks (reads only).
    private static func missingPrereleaseColumns(_ db: SQLiteConnection) throws -> [(table: String, column: String, definition: String)] {
        try prereleaseV2Columns.filter { (table, column, _) in
            let existing = try db.query("SELECT name FROM pragma_table_info(?)", [.text(table)]) { $0.string(0) }
            return !existing.isEmpty && !existing.contains(column)
        }
    }

    /// `pre-migration-v<level>-<stamp>.sqlite`; a feature migration adds its name
    /// (`pre-migration-v2-assist-<stamp>.sqlite`).
    private static func backup(_ db: SQLiteConnection, to dir: URL, fromVersion: Int, now: Date,
                               tag: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = "pre-migration-v\(fromVersion)-" + (tag.map { $0 + "-" } ?? "") + fileStamp(now)
        var url = dir.appendingPathComponent(base + ".sqlite")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)_\(n).sqlite"); n += 1
        }
        try db.run("VACUUM INTO ?", [.text(url.path)])
        Log.db.info("Backed up database before migration to \(url.lastPathComponent, privacy: .public)")
        return url
    }

    /// `20260930-101500` in UTC — sortable and safe in file names.
    package static func fileStamp(_ date: Date) -> String {
        let c = LocalDate.gregorian(.gmt).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    private static func apply(_ version: Int, on db: SQLiteConnection, now: Date) throws {
        switch version {
        case 1:
            try db.exec(schemaV1)
            let seed = try db.prepare("""
                INSERT INTO category(name, description, hue, origin, acknowledged, created_at)
                VALUES(?, ?, ?, 'starter', 1, ?)
                """)
            let stamp = Database.timestamp(now)
            for (i, s) in PaperCategory.starters.enumerated() {
                try seed.run([.text(s.name), .text(s.description), .int(i), .text(stamp)])
            }
            try db.setUserVersion(coreUserVersion)
        case 2:
            // Additive: the mail tables plus their marker; user_version stays at the core's 1.
            try db.exec(schemaV2)
            try markMailFeature(db)
        default:
            throw DatabaseError.notFound("migration v\(version)")
        }
    }

    /// §5 migration 1, except the single `paper_fts` is split into a metadata
    /// table and a full-text table so metadata can be reindexed without the text.
    private static let schemaV1 = """
    CREATE TABLE category(pk INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE, description TEXT, hue INTEGER NOT NULL,
      origin TEXT NOT NULL CHECK(origin IN('starter','agent','user')), acknowledged INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL);
    CREATE TABLE paper(pk INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, sha256 TEXT NOT NULL UNIQUE, file_size INTEGER NOT NULL,
      doi TEXT COLLATE NOCASE, published_doi TEXT COLLATE NOCASE, arxiv_id TEXT, arxiv_version INTEGER, pii TEXT,
      title TEXT NOT NULL, title_rank INTEGER NOT NULL,
      authors_json TEXT NOT NULL DEFAULT '[]', year INTEGER, venue TEXT, abstract TEXT,
      meta_source TEXT NOT NULL DEFAULT 'none', meta_user_edited INTEGER NOT NULL DEFAULT 0,
      page_count INTEGER, char_count INTEGER, flags INTEGER NOT NULL DEFAULT 0,
      folder TEXT NOT NULL, pdf_name TEXT NOT NULL, original_name TEXT NOT NULL, name_final INTEGER NOT NULL DEFAULT 0,
      stage TEXT NOT NULL DEFAULT 'committed' CHECK(stage IN('committed','enriched','filed','ready')),
      status TEXT NOT NULL DEFAULT 'to_read' CHECK(status IN('to_read','reading','done')), priority INTEGER NOT NULL DEFAULT 0,
      deadline TEXT, schedule_mode TEXT NOT NULL DEFAULT 'auto' CHECK(schedule_mode IN('auto','pinned','none')),
      deadline_origin TEXT NOT NULL DEFAULT 'place' CHECK(deadline_origin IN('place','user')),
      queue_rank INTEGER NOT NULL, placement_floor TEXT, provisional INTEGER NOT NULL DEFAULT 1,
      est_minutes INTEGER, est_source TEXT NOT NULL DEFAULT 'heuristic',
      category_pk INTEGER REFERENCES category(pk) ON DELETE SET NULL, category_user_set INTEGER NOT NULL DEFAULT 0,
      needs_review INTEGER NOT NULL DEFAULT 0, tldr TEXT, card_json TEXT, card_version INTEGER, text_quality TEXT,
      ai_state TEXT NOT NULL DEFAULT 'none' CHECK(ai_state IN('none','held','queued','running','done','failed','skipped','limited','needs_login')),
      ai_note TEXT, ai_seen INTEGER NOT NULL DEFAULT 1, notes TEXT NOT NULL DEFAULT '',
      added_at TEXT NOT NULL, updated_at TEXT NOT NULL, opened_at TEXT, done_at TEXT, deleted_at TEXT);
    CREATE UNIQUE INDEX ux_doi   ON paper(doi)      WHERE doi IS NOT NULL AND deleted_at IS NULL;
    CREATE UNIQUE INDEX ux_arxiv ON paper(arxiv_id) WHERE arxiv_id IS NOT NULL AND deleted_at IS NULL;
    CREATE INDEX ix_live ON paper(status, deadline) WHERE deleted_at IS NULL;
    CREATE TABLE checklist_item(pk INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, paper_pk INTEGER NOT NULL REFERENCES paper(pk) ON DELETE CASCADE,
      ord REAL NOT NULL, text TEXT NOT NULL, section TEXT, page INTEGER, minutes INTEGER NOT NULL, kind TEXT NOT NULL,
      origin TEXT NOT NULL CHECK(origin IN('heuristic','agent','user')), user_edited INTEGER NOT NULL DEFAULT 0, done_at TEXT);
    CREATE INDEX ix_checklist_paper ON checklist_item(paper_pk, ord);
    CREATE TABLE tag(pk INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE);
    CREATE TABLE paper_tag(paper_pk INTEGER NOT NULL REFERENCES paper(pk) ON DELETE CASCADE, tag_pk INTEGER NOT NULL REFERENCES tag(pk) ON DELETE CASCADE,
      origin TEXT NOT NULL CHECK(origin IN('agent','user','suppressed')), PRIMARY KEY(paper_pk, tag_pk)) WITHOUT ROWID;
    CREATE INDEX ix_paper_tag_tag ON paper_tag(tag_pk);
    CREATE TABLE agent_job(pk INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, paper_pk INTEGER NOT NULL REFERENCES paper(pk) ON DELETE CASCADE,
      provider TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN('held','queued','running','succeeded','failed','cancelled')),
      priority INTEGER NOT NULL DEFAULT 0, attempt INTEGER NOT NULL DEFAULT 0, text_budget INTEGER, effort TEXT, not_before TEXT,
      error_kind TEXT, error_message TEXT, model TEXT, duration_ms INTEGER, cost_usd REAL, input_tokens INTEGER, output_tokens INTEGER,
      created_at TEXT NOT NULL, started_at TEXT, finished_at TEXT);
    CREATE UNIQUE INDEX ux_agent_active ON agent_job(paper_pk) WHERE state IN('held','queued','running');
    CREATE INDEX ix_agent_job_paper ON agent_job(paper_pk);
    CREATE TABLE meta_cache(key TEXT PRIMARY KEY, status INTEGER NOT NULL, body BLOB, fetched_at TEXT NOT NULL) WITHOUT ROWID;
    CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
    CREATE VIRTUAL TABLE paper_fts_meta USING fts5(title, authors, abstract, card, tags, notes,
      content='', contentless_delete=1, tokenize='unicode61 remove_diacritics 2', prefix='2 3');
    CREATE VIRTUAL TABLE paper_fts_text USING fts5(fulltext,
      content='', contentless_delete=1, tokenize='unicode61 remove_diacritics 2', prefix='2 3');
    """

    /// Level 2 — Mail (docs/MAIL_DESIGN.md Part A §1, adapted to MailModels.swift).
    /// Purely additive: three new tables (recorded in `schema_feature`, not in user_version),
    /// nothing existing is touched. Enum columns hold
    /// the Swift raw values (the CHECK lists are frozen here — a new case needs a
    /// migration); instants are `Database.timestamp` strings, days `YYYY-MM-DD`.
    /// `mail_item.paper_id` and `paper_source.mail_message_id` are soft references by
    /// stable uuid, so rebuilds and mail purges never break them.
    private static let schemaV2 = """
    CREATE TABLE mail_message(pk INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE,
      account_id TEXT NOT NULL DEFAULT '', source_ref TEXT, internet_message_id TEXT NOT NULL COLLATE NOCASE,
      from_address TEXT NOT NULL COLLATE NOCASE, from_name TEXT, rule_id TEXT,
      sender_kind TEXT NOT NULL DEFAULT 'person' CHECK(sender_kind IN('advisor','person','alert','manual')),
      auth_state TEXT NOT NULL DEFAULT 'unknown' CHECK(auth_state IN('pass','fail','unknown')),
      subject TEXT NOT NULL DEFAULT '', received_at TEXT NOT NULL, web_link TEXT,
      snippet TEXT, body_text TEXT, body_purged INTEGER NOT NULL DEFAULT 0,
      state TEXT NOT NULL DEFAULT 'pending' CHECK(state IN('pending','snoozed','merged','dismissed','no_request')),
      user_touched INTEGER NOT NULL DEFAULT 0, snoozed_until TEXT,
      triage_state TEXT NOT NULL DEFAULT 'none' CHECK(triage_state IN('none','awaiting_consent','held','queued',
        'running','done','failed','skipped','limited','needs_login')),
      triage_source TEXT CHECK(triage_source IN('ai','heuristic')), triage_json TEXT,
      triage_attempt INTEGER NOT NULL DEFAULT 0, triage_not_before TEXT, triage_error TEXT,
      triage_provider TEXT, triage_model TEXT, triage_ms INTEGER,
      triage_in_tokens INTEGER, triage_out_tokens INTEGER, triage_stdin_bytes INTEGER,
      seen INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, handled_at TEXT,
      triage_consented INTEGER NOT NULL DEFAULT 0, triage_consent_provider TEXT, is_bulk INTEGER);
    CREATE UNIQUE INDEX ux_mail_msgid ON mail_message(internet_message_id);
    CREATE INDEX ix_mail_state ON mail_message(state, received_at DESC);
    CREATE INDEX ix_mail_triage ON mail_message(triage_state, triage_not_before) WHERE triage_state IN('held','queued');
    CREATE TABLE mail_item(pk INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE,
      message_pk INTEGER NOT NULL REFERENCES mail_message(pk) ON DELETE CASCADE,
      ord INTEGER NOT NULL, cand TEXT NOT NULL,
      origin TEXT NOT NULL CHECK(origin IN('attachment','link','identifier','citation','alert_entry')),
      found_by TEXT NOT NULL DEFAULT 'local' CHECK(found_by IN('local','ai','user')),
      title TEXT, authors_json TEXT NOT NULL DEFAULT '[]', venue TEXT, year INTEGER,
      doi TEXT COLLATE NOCASE, published_doi TEXT COLLATE NOCASE, arxiv_id TEXT COLLATE NOCASE,
      arxiv_version INTEGER, pii TEXT, url TEXT, url_original TEXT, host TEXT,
      meta_source TEXT NOT NULL DEFAULT 'none',
      relevance TEXT CHECK(relevance IN('requested','highlighted','listed')), why TEXT, confidence REAL,
      pdf_state TEXT NOT NULL DEFAULT 'unknown'
        CHECK(pdf_state IN('unknown','has_pdf','downloadable','downloading','needs_pdf','in_library')),
      pdf_path TEXT, pdf_sha256 TEXT, pdf_bytes INTEGER, download_error TEXT, paper_id TEXT,
      status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN('pending','merged','linked','skipped')),
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      origin_ext TEXT, pdf_state_ext TEXT, document_name TEXT, document_kind TEXT, document_path TEXT,
      document_sha256 TEXT, share_host TEXT);
    CREATE INDEX ix_mail_item_msg ON mail_item(message_pk, ord);
    CREATE INDEX ix_mail_item_doi ON mail_item(doi) WHERE doi IS NOT NULL;
    CREATE INDEX ix_mail_item_arxiv ON mail_item(arxiv_id) WHERE arxiv_id IS NOT NULL;
    CREATE INDEX ix_mail_item_open ON mail_item(pdf_state) WHERE status = 'pending';
    CREATE TABLE paper_source(pk INTEGER PRIMARY KEY, paper_pk INTEGER NOT NULL REFERENCES paper(pk) ON DELETE CASCADE,
      kind TEXT NOT NULL DEFAULT 'email', mail_message_id TEXT, internet_message_id TEXT COLLATE NOCASE,
      from_address TEXT, from_name TEXT, subject TEXT, received_at TEXT, web_link TEXT,
      request_kind TEXT, summary TEXT, due_hint TEXT, added_at TEXT NOT NULL, document TEXT,
      UNIQUE(paper_pk, internet_message_id));
    """
}
