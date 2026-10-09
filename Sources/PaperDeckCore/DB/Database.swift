import Foundation
import SQLite3

/// The only reader/writer of library.sqlite (§3.4, §5).
///
/// Runs on its own serial dispatch queue, so SQLite I/O (fsync on COMMIT,
/// VACUUM INTO, large FTS inserts) never occupies a cooperative-pool thread.
/// All methods are synchronous inside the actor, so there is no reentrancy.
/// Every committed write is announced on `changes` (after COMMIT, never before).
package actor Database {
    private nonisolated let queue = DispatchSerialQueue(label: "\(Log.subsystem).database", qos: .userInitiated)
    // Internal (not private) so the per-feature extensions (Database+Mail.swift) share
    // the connection, coders and the write/note machinery below.
    let db: SQLiteConnection
    let encoder: JSONEncoder
    let decoder = JSONDecoder()
    private var txDepth = 0
    private var pendingChanges: [LibraryChange] = []

    /// Broadcasts a `LibraryChange` after each committed write.
    package nonisolated let changes = ChangeHub()
    /// nil for in-memory databases.
    package nonisolated let url: URL?
    /// What opening did (versions, pre-migration backup).
    package nonisolated let migration: Migrations.Outcome

    package nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Opens (creating the parent directory and file if needed) and migrates.
    /// Throws `DatabaseError.newerSchema` / `.corrupt` without modifying the file.
    package init(url: URL, backupsDir: URL?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(connection: SQLiteConnection(path: url.path), url: url, backupsDir: backupsDir)
    }

    private init(connection: SQLiteConnection, url: URL?, backupsDir: URL?) throws {
        self.migration = try Migrations.prepare(connection, backupsDir: backupsDir)
        self.db = connection
        self.url = url
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = enc
    }

    /// A private, fully migrated in-memory database (tests, previews).
    package static func inMemory() throws -> Database {
        try Database(connection: SQLiteConnection(path: ":memory:"), url: nil, backupsDir: nil)
    }

    /// `init(url:backupsDir:)` off the cooperative pool (open + migrate + backup can take a while).
    package static func open(url: URL, backupsDir: URL?) async throws -> Database {
        try await BlockingIO.run { try Database(url: url, backupsDir: backupsDir) }
    }

    /// Moves a corrupt DB and its -wal/-shm into `Backups/corrupt-<ts>/` so a
    /// fresh one can be created and rebuilt from the sidecars. Returns the folder.
    @discardableResult
    package static func moveAsideCorrupt(url: URL, backupsDir: URL, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        var dest = backupsDir.appendingPathComponent("corrupt-\(Migrations.fileStamp(now))", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = backupsDir.appendingPathComponent("corrupt-\(Migrations.fileStamp(now))_\(n)", isDirectory: true); n += 1
        }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: url.path + suffix)
            if fm.fileExists(atPath: src.path) {
                try fm.moveItem(at: src, to: dest.appendingPathComponent(src.lastPathComponent))
            }
        }
        return dest
    }

    // MARK: - Transactions and change fan-out

    /// Runs `body` as one transaction. Helpers it calls join it (savepoints) and
    /// their change notifications go out once, after the outer COMMIT.
    /// `try await db.transaction { db in try db.updatePaper(p); try db.replaceChecklist(…) }`
    package func transaction<T: Sendable>(_ body: @Sendable (isolated Database) throws -> T) throws -> T {
        try write { try body(self) }
    }

    func write<T>(_ body: () throws -> T) throws -> T {
        let outermost = txDepth == 0
        txDepth += 1
        defer { txDepth -= 1 }
        do {
            let result = try db.transaction(immediate: true, body)
            if outermost { flushChanges() }
            return result
        } catch {
            if outermost { pendingChanges.removeAll() }
            throw error
        }
    }

    func note(_ change: LibraryChange) { pendingChanges.append(change) }

    /// Dedupes; a burst of per-paper changes (rebuild, bulk import) collapses into `.papersBulk`,
    /// and a burst of per-message mail changes into `.mailBulk`.
    private func flushChanges() {
        var pks: [Int64] = [], mailPKs: [Int64] = []
        var seen = Set<Int64>(), seenMail = Set<Int64>()
        var others: [LibraryChange] = []
        for change in pendingChanges {
            if case .paper(let pk) = change {
                if seen.insert(pk).inserted { pks.append(pk) }
            } else if case .mail(let pk) = change {
                if seenMail.insert(pk).inserted { mailPKs.append(pk) }
            } else if !others.contains(change) {
                others.append(change)
            }
        }
        pendingChanges.removeAll()
        if pks.count > 32 {
            if !others.contains(.papersBulk) { others.insert(.papersBulk, at: 0) }
        } else if !others.contains(.papersBulk) {
            for pk in pks { changes.send(.paper(pk: pk)) }
        }
        if mailPKs.count > 32 {
            if !others.contains(.mailBulk) { others.append(.mailBulk) }
        } else if !others.contains(.mailBulk) {
            for pk in mailPKs { changes.send(.mail(pk: pk)) }
        }
        for change in others { changes.send(change) }
    }

    // MARK: - Papers

    private static let paperColumns = [
        "id", "sha256", "file_size", "doi", "published_doi", "arxiv_id", "arxiv_version", "pii",
        "title", "title_rank", "authors_json", "year", "venue", "abstract", "meta_source", "meta_user_edited",
        "page_count", "char_count", "flags", "folder", "pdf_name", "original_name", "name_final",
        "stage", "status", "priority", "deadline", "schedule_mode", "deadline_origin", "queue_rank",
        "placement_floor", "provisional", "est_minutes", "est_source", "category_pk", "category_user_set",
        "needs_review", "tldr", "card_json", "card_version", "text_quality", "ai_state", "ai_note", "ai_seen",
        "notes", "added_at", "updated_at", "opened_at", "done_at", "deleted_at",
    ]
    private static let paperSelect = "SELECT pk, " + paperColumns.joined(separator: ", ") + " FROM paper"
    private static let paperInsert = "INSERT INTO paper(" + paperColumns.joined(separator: ", ") + ") VALUES("
        + Array(repeating: "?", count: paperColumns.count).joined(separator: ", ") + ")"
    private static let paperUpdate = "UPDATE paper SET "
        + paperColumns.enumerated().map { "\($1) = ?\($0 + 1)" }.joined(separator: ", ")
        + " WHERE pk = ?\(paperColumns.count + 1)"

    /// Inserts `p` (its `pk` is ignored) plus its checklist in one transaction and
    /// indexes the FTS metadata. `queueRank <= 0` means "assign max+1".
    /// Returns the stored row (timestamps normalized to millisecond precision).
    @discardableResult
    package func insertPaper(_ p: Paper, checklist: [ChecklistItem] = []) throws -> Paper {
        let pk = try write { () throws -> Int64 in
            var row = p
            if row.queueRank <= 0 { row.queueRank = try nextQueueRank() }
            try db.run(Database.paperInsert, paperValues(row))
            let pk = db.lastInsertRowID
            for item in checklist { try insertItem(item, paperPK: pk) }
            try indexMeta(pk: pk)
            note(.paper(pk: pk))
            return pk
        }
        return try requirePaper(pk)
    }

    /// Rewrites the whole row by `pk`, sets `updated_at = now`, reindexes FTS metadata.
    @discardableResult
    package func updatePaper(_ p: Paper, now: Date = Date()) throws -> Paper {
        try write {
            var row = p
            row.updatedAt = now
            try db.run(Database.paperUpdate, paperValues(row) + [.integer(p.pk)])
            guard db.changes == 1 else { throw DatabaseError.notFound("paper \(p.pk)") }
            try indexMeta(pk: p.pk)
            note(.paper(pk: p.pk))
        }
        return try requirePaper(p.pk)
    }

    /// Atomic read-modify-write on the current row. Prefer this over `updatePaper`
    /// with a copy read before an `await` (network, agent run), which would
    /// silently overwrite edits made in the meantime.
    @discardableResult
    package func modifyPaper(pk: Int64, now: Date = Date(), _ body: @Sendable (inout Paper) throws -> Void) throws -> Paper {
        try write {
            var p = try requirePaper(pk)
            try body(&p)
            p.pk = pk
            return try updatePaper(p, now: now)
        }
    }

    /// These three include soft-deleted papers.
    package func paper(pk: Int64) throws -> Paper? {
        try db.queryOne(Database.paperSelect + " WHERE pk = ?", [.integer(pk)]) { try readPaper($0) }
    }

    package func paper(id: String) throws -> Paper? {
        try db.queryOne(Database.paperSelect + " WHERE id = ?", [.text(id.lowercased())]) { try readPaper($0) }
    }

    package func paper(sha256: String) throws -> Paper? {
        try db.queryOne(Database.paperSelect + " WHERE sha256 = ?", [.text(sha256.lowercased())]) { try readPaper($0) }
    }

    /// Live paper that is the same work (§5 查重 2): DOI (case-insensitive) or
    /// arXiv base id, also crossing preprint ↔ journal via `published_doi`. A bioRxiv DOI
    /// matches under both prefixes (`sameWorkDOIs`). `excluding` skips one paper (the one
    /// being checked), so its own row can't hide another holder.
    package func paperMatchingWork(doi: String?, arxivID: String?, publishedDOI: String?,
                                   excluding pk: Int64? = nil) throws -> Paper? {
        var dois = Database.sameWorkDOIs(doi)
        for d in Database.sameWorkDOIs(publishedDOI) where !dois.contains(d) { dois.append(d) }
        let arxiv = Database.clean(arxivID)
        guard !dois.isEmpty || arxiv != nil else { return nil }
        return try db.queryOne(Database.paperSelect + """
             WHERE deleted_at IS NULL AND (?3 IS NULL OR pk <> ?3) AND (
               doi IN (SELECT value FROM json_each(?1)) OR published_doi IN (SELECT value FROM json_each(?1))
               OR (?2 IS NOT NULL AND arxiv_id = ?2 COLLATE NOCASE))
             ORDER BY pk LIMIT 1
            """, [.text(try jsonStrings(dois)), .string(arxiv), .int64(pk)]) { try readPaper($0) }
    }

    /// Live paper whose own DOI (not its `published_doi`) names the same work as `doi` —
    /// what edit and restore refuse, with both bioRxiv prefixes counting as one.
    package func livePaper(holdingDOI doi: String, excluding pk: Int64? = nil) throws -> Paper? {
        let dois = Database.sameWorkDOIs(doi)
        guard !dois.isEmpty else { return nil }
        return try db.queryOne(Database.paperSelect + """
             WHERE deleted_at IS NULL AND (?2 IS NULL OR pk <> ?2) AND doi IN (SELECT value FROM json_each(?1))
             ORDER BY pk LIMIT 1
            """, [.text(try jsonStrings(dois)), .int64(pk)]) { try readPaper($0) }
    }

    /// Any paper (live or deleted) whose `folder` is `relative` (case-insensitive).
    package func paper(folder relative: String) throws -> Paper? {
        try db.queryOne(Database.paperSelect + " WHERE folder = ? COLLATE NOCASE ORDER BY pk LIMIT 1",
                        [.text(relative)]) { try readPaper($0) }
    }

    /// The DOIs that name the same work as `doi`, lowercased: the DOI itself and, for a
    /// date-stamped bioRxiv/medRxiv id, the version-less id under both prefixes. bioRxiv moved
    /// its preprints from 10.1101 to 10.64898 — file names and older records still carry the
    /// old prefix while the API (and so an enriched paper) has the new one. Empty for nil/blank.
    package static func sameWorkDOIs(_ doi: String?) -> [String] {
        guard let d = clean(doi)?.lowercased() else { return [] }
        var out = [d]
        if var base = MetadataClients.biorxivDOI(d) {
            if let v = base.range(of: #"(?<=\d)v\d+$"#, options: .regularExpression) { base.removeSubrange(v) }
            if !out.contains(base) { out.append(base) }
            if let alt = MetadataClients.alternateBiorxivDOI(base), !out.contains(alt) { out.append(alt) }
        }
        return out
    }

    /// Live papers in queue order.
    package func livePapers() throws -> [Paper] {
        try db.query(Database.paperSelect + " WHERE deleted_at IS NULL ORDER BY queue_rank, pk") { try readPaper($0) }
    }

    /// Soft-deleted papers, most recently deleted first.
    package func deletedPapers() throws -> [Paper] {
        try db.query(Database.paperSelect + " WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC, pk DESC") {
            try readPaper($0)
        }
    }

    /// Every row, live and deleted (rebuild/canonical dump).
    package func allPapers() throws -> [Paper] {
        try db.query(Database.paperSelect + " ORDER BY pk") { try readPaper($0) }
    }

    /// Live papers whose pipeline stage is not `stage` (EnrichActor resume).
    package func papers(notInStage stage: PaperStage) throws -> [Paper] {
        try db.query(Database.paperSelect + " WHERE deleted_at IS NULL AND stage <> ? ORDER BY pk",
                     [.text(stage.rawValue)]) { try readPaper($0) }
    }

    /// Papers for `pks`, in the given order (missing pks are skipped) — e.g. search hits.
    package func papers(pks: [Int64]) throws -> [Paper] {
        guard !pks.isEmpty else { return [] }
        let rows = try db.query(Database.paperSelect + " WHERE pk IN (SELECT value FROM json_each(?))",
                                [.text(Database.jsonArray(pks))]) { try readPaper($0) }
        let byPK = Dictionary(rows.map { ($0.pk, $0) }, uniquingKeysWith: { a, _ in a })
        return pks.compactMap { byPK[$0] }
    }

    package func nextQueueRank() throws -> Int {
        Int(try db.scalarInt("SELECT COALESCE(MAX(queue_rank), 0) + 1 FROM paper") ?? 1)
    }

    package func softDelete(pk: Int64, at date: Date = Date()) throws {
        try write {
            let ts = Database.timestamp(date)
            try db.run("UPDATE paper SET deleted_at = ?1, updated_at = ?1 WHERE pk = ?2", [.text(ts), .integer(pk)])
            guard db.changes == 1 else { throw DatabaseError.notFound("paper \(pk)") }
            note(.paper(pk: pk))
        }
    }

    /// Throws a unique violation if a live paper with the same DOI/arXiv id arrived meanwhile.
    package func restore(pk: Int64, now: Date = Date()) throws {
        try write {
            try db.run("UPDATE paper SET deleted_at = NULL, updated_at = ?1 WHERE pk = ?2",
                       [.text(Database.timestamp(now)), .integer(pk)])
            guard db.changes == 1 else { throw DatabaseError.notFound("paper \(pk)") }
            note(.paper(pk: pk))
        }
    }

    /// Deletes the row and both FTS rows; checklist, tags and jobs cascade.
    /// Idempotent. Afterwards the sha256 no longer blocks a re-import.
    package func hardDelete(pk: Int64) throws {
        try write {
            try db.run("DELETE FROM paper_fts_meta WHERE rowid = ?", [.integer(pk)])
            try db.run("DELETE FROM paper_fts_text WHERE rowid = ?", [.integer(pk)])
            try db.run("DELETE FROM paper WHERE pk = ?", [.integer(pk)])
            let deleted = db.changes > 0
            try db.run("DELETE FROM tag WHERE pk NOT IN (SELECT tag_pk FROM paper_tag)")
            if deleted { note(.paper(pk: pk)) }
        }
    }

    private func requirePaper(_ pk: Int64) throws -> Paper {
        guard let p = try paper(pk: pk) else { throw DatabaseError.notFound("paper \(pk)") }
        return p
    }

    private func touch(_ paperPK: Int64) throws {
        try db.run("UPDATE paper SET updated_at = ? WHERE pk = ?", [.text(Database.timestamp(Date())), .integer(paperPK)])
    }

    private func paperValues(_ p: Paper) throws -> [SQLiteValue] {
        let authors = String(decoding: try encoder.encode(p.authors), as: UTF8.self)
        let card = try p.card.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        let values: [SQLiteValue] = [
            .text(p.id.lowercased()), .text(p.sha256.lowercased()), .integer(p.fileSize),
            .string(Database.clean(p.ids.doi)), .string(Database.clean(p.ids.publishedDOI)),
            .string(Database.clean(p.ids.arxivID)), .int(p.ids.arxivVersion), .string(Database.clean(p.ids.pii)),
            .text(p.title), .int(p.titleRank.rawValue), .text(authors), .int(p.year), .string(p.venue),
            .string(p.abstract), .text(p.metaSource.rawValue), .bool(p.metaUserEdited),
            .int(p.pageCount), .int(p.charCount), .int(p.flags.rawValue), .text(p.folder), .text(p.pdfName),
            .text(p.originalName), .bool(p.nameFinal),
            .text(p.stage.rawValue), .text(p.status.rawValue), .int(p.priority.rawValue), .string(p.deadline?.iso),
            .text(p.scheduleMode.rawValue), .text(p.deadlineOrigin.rawValue), .int(p.queueRank),
            .string(p.placementFloor?.iso), .bool(p.provisional), .int(p.estMinutes), .text(p.estSource.rawValue),
            .int64(p.categoryPK), .bool(p.categoryUserSet),
            .bool(p.needsReview), .string(p.tldr), .string(card), .int(p.cardVersion), .string(p.textQuality?.rawValue),
            .text(p.aiState.rawValue), .string(p.aiNote), .bool(p.aiSeen),
            .text(p.notes), .text(Database.timestamp(p.addedAt)), .text(Database.timestamp(p.updatedAt)),
            .string(p.openedAt.map(Database.timestamp)), .string(p.doneAt.map(Database.timestamp)),
            .string(p.deletedAt.map(Database.timestamp)),
        ]
        assert(values.count == Database.paperColumns.count)
        return values
    }

    /// Column order = `paperSelect`. Unknown enum strings fall back to defaults rather than failing the row.
    private func readPaper(_ s: SQLiteStatement) throws -> Paper {
        var c = Columns(s)
        let pk = c.int64()
        let id = c.string(), sha = c.string(), size = c.int64()
        let doi = c.optString(), publishedDOI = c.optString()
        let arxivID = c.optString(), arxivVersion = c.optInt(), pii = c.optString()
        let title = c.string(), titleRank = c.rawInt(TitleRank.filename)
        let authorsJSON = c.string()
        let authors = (try? decoder.decode([String].self, from: Data(authorsJSON.utf8))) ?? []
        let year = c.optInt(), venue = c.optString(), abstract = c.optString()
        let metaSource = c.raw(MetaSource.none), metaUserEdited = c.bool()
        let pageCount = c.optInt(), charCount = c.optInt(), flags = PaperFlags(rawValue: c.int())
        let folder = c.string(), pdfName = c.string(), originalName = c.string(), nameFinal = c.bool()
        let stage = c.raw(PaperStage.committed), status = c.raw(PaperStatus.toRead)
        let priority = c.rawInt(Priority.normal), deadline = c.localDate()
        let scheduleMode = c.raw(ScheduleMode.auto), deadlineOrigin = c.raw(DeadlineOrigin.place)
        let queueRank = c.int(), placementFloor = c.localDate(), provisional = c.bool()
        let estMinutes = c.optInt(), estSource = c.raw(EstSource.heuristic)
        let categoryPK = c.optInt64(), categoryUserSet = c.bool(), needsReview = c.bool()
        let tldr = c.optString(), cardJSON = c.optString(), cardVersion = c.optInt()
        let textQuality = c.optString().flatMap(TextQuality.init(rawValue:))
        let aiState = c.raw(AIState.none), aiNote = c.optString(), aiSeen = c.bool()
        let notes = c.string(), addedAt = c.date(), updatedAt = c.date()
        let openedAt = c.optDate(), doneAt = c.optDate(), deletedAt = c.optDate()

        var card: ReadingCard?
        if let cardJSON {
            card = try? decoder.decode(ReadingCard.self, from: Data(cardJSON.utf8))
            if card == nil { Log.db.error("Undecodable card_json for paper \(pk)") }
        }
        let ids = PaperIDs(doi: doi, arxivID: arxivID, arxivVersion: arxivVersion, pii: pii, publishedDOI: publishedDOI)
        return Paper(
            pk: pk, id: id, sha256: sha, fileSize: size, ids: ids, title: title, titleRank: titleRank,
            authors: authors, year: year, venue: venue, abstract: abstract, metaSource: metaSource,
            metaUserEdited: metaUserEdited, pageCount: pageCount, charCount: charCount, flags: flags,
            folder: folder, pdfName: pdfName, originalName: originalName, nameFinal: nameFinal,
            stage: stage, status: status, priority: priority, deadline: deadline, scheduleMode: scheduleMode,
            deadlineOrigin: deadlineOrigin, queueRank: queueRank, placementFloor: placementFloor,
            provisional: provisional, estMinutes: estMinutes, estSource: estSource, categoryPK: categoryPK,
            categoryUserSet: categoryUserSet, needsReview: needsReview, tldr: tldr, card: card,
            cardVersion: cardVersion, textQuality: textQuality, aiState: aiState, aiNote: aiNote,
            aiSeen: aiSeen, notes: notes, addedAt: addedAt, updatedAt: updatedAt, openedAt: openedAt,
            doneAt: doneAt, deletedAt: deletedAt)
    }

    // MARK: - Checklist

    private static let itemColumns = "id, ord, text, section, page, minutes, kind, origin, user_edited, done_at"

    /// Items of one paper in display order.
    package func checklist(paperPK: Int64) throws -> [ChecklistItem] {
        try db.query("SELECT \(Database.itemColumns) FROM checklist_item WHERE paper_pk = ? ORDER BY ord, pk",
                     [.integer(paperPK)]) { readItem($0, from: 0) }
    }

    /// Every requested pk is a key (possibly with an empty list).
    package func checklists(paperPKs: [Int64]) throws -> [Int64: [ChecklistItem]] {
        var out = Dictionary(paperPKs.map { ($0, [ChecklistItem]()) }, uniquingKeysWith: { a, _ in a })
        guard !paperPKs.isEmpty else { return out }
        let rows = try db.query("""
            SELECT paper_pk, \(Database.itemColumns) FROM checklist_item
            WHERE paper_pk IN (SELECT value FROM json_each(?)) ORDER BY paper_pk, ord, pk
            """, [.text(Database.jsonArray(paperPKs))]) { ($0.int64(0), readItem($0, from: 1)) }
        for (pk, item) in rows { out[pk, default: []].append(item) }
        return out
    }

    package func replaceChecklist(paperPK: Int64, items: [ChecklistItem]) throws {
        try write {
            try db.run("DELETE FROM checklist_item WHERE paper_pk = ?", [.integer(paperPK)])
            for item in items { try insertItem(item, paperPK: paperPK) }
            try touch(paperPK)
            note(.paper(pk: paperPK))
        }
    }

    /// Insert or update by item id (moving it to `paperPK` if needed).
    package func upsertChecklistItem(paperPK: Int64, item: ChecklistItem) throws {
        try write {
            if let previous = try db.scalarInt("SELECT paper_pk FROM checklist_item WHERE id = ?", [.text(item.id)]),
               previous != paperPK {
                try touch(previous)
                note(.paper(pk: previous))
            }
            try db.run("""
                INSERT INTO checklist_item(paper_pk, \(Database.itemColumns)) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET paper_pk = excluded.paper_pk, ord = excluded.ord, text = excluded.text,
                  section = excluded.section, page = excluded.page, minutes = excluded.minutes, kind = excluded.kind,
                  origin = excluded.origin, user_edited = excluded.user_edited, done_at = excluded.done_at
                """, [.integer(paperPK)] + itemValues(item))
            try touch(paperPK)
            note(.paper(pk: paperPK))
        }
    }

    package func deleteChecklistItem(id: String) throws {
        try write {
            guard let paperPK = try db.scalarInt("SELECT paper_pk FROM checklist_item WHERE id = ?", [.text(id)]) else {
                return
            }
            try db.run("DELETE FROM checklist_item WHERE id = ?", [.text(id)])
            try touch(paperPK)
            note(.paper(pk: paperPK))
        }
    }

    private func insertItem(_ item: ChecklistItem, paperPK: Int64) throws {
        try db.run("INSERT INTO checklist_item(paper_pk, \(Database.itemColumns)) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                   [.integer(paperPK)] + itemValues(item))
    }

    private func itemValues(_ i: ChecklistItem) -> [SQLiteValue] {
        [.text(i.id), .real(i.ord), .text(i.text), .string(i.section), .int(i.page), .int(i.minutes),
         .text(i.kind.rawValue), .text(i.origin.rawValue), .bool(i.userEdited), .string(i.doneAt.map(Database.timestamp))]
    }

    private func readItem(_ s: SQLiteStatement, from start: Int32) -> ChecklistItem {
        var c = Columns(s, start: start)
        return ChecklistItem(id: c.string(), ord: c.double(), text: c.string(), section: c.optString(),
                             page: c.optInt(), minutes: c.int(), kind: c.raw(ChecklistKind.other),
                             origin: c.raw(ItemOrigin.heuristic), userEdited: c.bool(), doneAt: c.optDate())
    }

    // MARK: - Categories

    private static let categorySelect = "SELECT pk, name, description, hue, origin, acknowledged, created_at FROM category"

    package func categories() throws -> [PaperCategory] {
        try db.query(Database.categorySelect + " ORDER BY pk") { readCategory($0) }
    }

    package func category(pk: Int64) throws -> PaperCategory? {
        try db.queryOne(Database.categorySelect + " WHERE pk = ?", [.integer(pk)]) { readCategory($0) }
    }

    /// Case-insensitive name lookup.
    package func category(named name: String) throws -> PaperCategory? {
        try db.queryOne(Database.categorySelect + " WHERE name = ?",
                        [.text(name.trimmingCharacters(in: .whitespaces))]) { readCategory($0) }
    }

    /// Throws a unique violation for a name that exists (case-insensitively).
    @discardableResult
    package func insertCategory(_ c: PaperCategory) throws -> PaperCategory {
        let pk = try write { () throws -> Int64 in
            try db.run("""
                INSERT INTO category(name, description, hue, origin, acknowledged, created_at) VALUES(?, ?, ?, ?, ?, ?)
                """, [.text(c.name), .string(c.description), .int(c.hue), .text(c.origin.rawValue),
                      .bool(c.acknowledged), .text(Database.timestamp(c.createdAt))])
            note(.categories)
            return db.lastInsertRowID
        }
        guard let saved = try category(pk: pk) else { throw DatabaseError.notFound("category \(pk)") }
        return saved
    }

    package func updateCategory(_ c: PaperCategory) throws {
        try write {
            try db.run("""
                UPDATE category SET name = ?, description = ?, hue = ?, origin = ?, acknowledged = ?, created_at = ?
                WHERE pk = ?
                """, [.text(c.name), .string(c.description), .int(c.hue), .text(c.origin.rawValue),
                      .bool(c.acknowledged), .text(Database.timestamp(c.createdAt)), .integer(c.pk)])
            guard db.changes == 1 else { throw DatabaseError.notFound("category \(c.pk)") }
            note(.categories)
        }
    }

    /// Papers in it become uncategorized (FK ON DELETE SET NULL).
    package func deleteCategory(pk: Int64) throws {
        try write {
            try db.run("DELETE FROM category WHERE pk = ?", [.integer(pk)])
            guard db.changes == 1 else { return }
            note(.categories)
            note(.papersBulk)
        }
    }

    /// Live-paper count per category; every category is a key.
    package func categoryCounts() throws -> [Int64: Int] {
        let rows = try db.query("""
            SELECT c.pk, COUNT(p.pk) FROM category c
            LEFT JOIN paper p ON p.category_pk = c.pk AND p.deleted_at IS NULL GROUP BY c.pk
            """) { ($0.int64(0), $0.int(1)) }
        return Dictionary(rows, uniquingKeysWith: { a, _ in a })
    }

    private func readCategory(_ s: SQLiteStatement) -> PaperCategory {
        var c = Columns(s)
        return PaperCategory(pk: c.int64(), name: c.string(), description: c.optString(), hue: c.int(),
                        origin: c.raw(CategoryOrigin.user), acknowledged: c.bool(), createdAt: c.date())
    }

    // MARK: - Tags

    /// All tag rows of a paper including `suppressed` ones (filter those for display).
    package func tags(paperPK: Int64) throws -> [Tag] {
        try db.query("""
            SELECT t.name, pt.origin FROM paper_tag pt JOIN tag t ON t.pk = pt.tag_pk
            WHERE pt.paper_pk = ? ORDER BY t.pk
            """, [.integer(paperPK)]) { Tag(name: $0.string(0), origin: TagOrigin(rawValue: $0.string(1)) ?? .agent) }
    }

    /// Batch form of `tags(paperPK:)`; every requested pk is a key.
    package func tags(paperPKs: [Int64]) throws -> [Int64: [Tag]] {
        var out = Dictionary(paperPKs.map { ($0, [Tag]()) }, uniquingKeysWith: { a, _ in a })
        guard !paperPKs.isEmpty else { return out }
        let rows = try db.query("""
            SELECT pt.paper_pk, t.name, pt.origin FROM paper_tag pt JOIN tag t ON t.pk = pt.tag_pk
            WHERE pt.paper_pk IN (SELECT value FROM json_each(?)) ORDER BY pt.paper_pk, t.pk
            """, [.text(Database.jsonArray(paperPKs))]) {
            ($0.int64(0), Tag(name: $0.string(1), origin: TagOrigin(rawValue: $0.string(2)) ?? .agent))
        }
        for (pk, tag) in rows { out[pk, default: []].append(tag) }
        return out
    }

    /// Replaces the paper's tag set, creating `tag` rows as needed (names match
    /// case-insensitively; a later duplicate wins) and pruning unused ones.
    package func setTags(paperPK: Int64, _ tags: [Tag]) throws {
        try write {
            try db.run("DELETE FROM paper_tag WHERE paper_pk = ?", [.integer(paperPK)])
            for tag in tags {
                let name = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                try db.run("INSERT OR IGNORE INTO tag(name) VALUES(?)", [.text(name)])
                guard let tagPK = try db.scalarInt("SELECT pk FROM tag WHERE name = ?", [.text(name)]) else { continue }
                try db.run("""
                    INSERT INTO paper_tag(paper_pk, tag_pk, origin) VALUES(?, ?, ?)
                    ON CONFLICT(paper_pk, tag_pk) DO UPDATE SET origin = excluded.origin
                    """, [.integer(paperPK), .integer(tagPK), .text(tag.origin.rawValue)])
            }
            try db.run("DELETE FROM tag WHERE pk NOT IN (SELECT tag_pk FROM paper_tag)")
            try touch(paperPK)
            try indexMeta(pk: paperPK)
            note(.paper(pk: paperPK))
        }
    }

    /// Most used agent/user tags on live papers (sent to Claude as `frequent_tags`).
    package func frequentTags(limit: Int) throws -> [(name: String, count: Int)] {
        try db.query("""
            SELECT t.name, COUNT(*) AS n FROM paper_tag pt
            JOIN tag t ON t.pk = pt.tag_pk JOIN paper p ON p.pk = pt.paper_pk
            WHERE pt.origin IN ('agent', 'user') AND p.deleted_at IS NULL
            GROUP BY t.pk ORDER BY n DESC, t.name COLLATE NOCASE LIMIT ?
            """, [.int(limit)]) { (name: $0.string(0), count: $0.int(1)) }
    }

    /// Agent/user tag names of live papers per category (for taxonomy overlap).
    package func tagSetsByCategory() throws -> [Int64: Set<String>] {
        let rows = try db.query("""
            SELECT DISTINCT p.category_pk, t.name FROM paper p
            JOIN paper_tag pt ON pt.paper_pk = p.pk JOIN tag t ON t.pk = pt.tag_pk
            WHERE p.deleted_at IS NULL AND p.category_pk IS NOT NULL AND pt.origin IN ('agent', 'user')
            """) { ($0.int64(0), $0.string(1)) }
        var out: [Int64: Set<String>] = [:]
        for (pk, name) in rows { out[pk, default: []].insert(name) }
        return out
    }

    // MARK: - Agent jobs

    private static let jobColumns = [
        "id", "paper_pk", "provider", "state", "priority", "attempt", "text_budget", "effort", "not_before",
        "error_kind", "error_message", "model", "duration_ms", "cost_usd", "input_tokens", "output_tokens",
        "created_at", "started_at", "finished_at",
    ]
    private static let jobSelect = "SELECT j.pk, " + jobColumns.map { "j." + $0 }.joined(separator: ", ") + " FROM agent_job j"

    /// Throws a unique violation when the paper already has a held/queued/running job.
    @discardableResult
    package func insertJob(_ j: AgentJob) throws -> AgentJob {
        let pk = try write { () throws -> Int64 in
            try db.run("INSERT INTO agent_job(" + Database.jobColumns.joined(separator: ", ") + ") VALUES("
                       + Array(repeating: "?", count: Database.jobColumns.count).joined(separator: ", ") + ")",
                       jobValues(j))
            note(.jobs)
            return db.lastInsertRowID
        }
        guard let saved = try job(pk: pk) else { throw DatabaseError.notFound("job \(pk)") }
        return saved
    }

    package func updateJob(_ j: AgentJob) throws {
        try write {
            try db.run("UPDATE agent_job SET "
                       + Database.jobColumns.enumerated().map { "\($1) = ?\($0 + 1)" }.joined(separator: ", ")
                       + " WHERE pk = ?\(Database.jobColumns.count + 1)", jobValues(j) + [.integer(j.pk)])
            guard db.changes == 1 else { throw DatabaseError.notFound("job \(j.pk)") }
            note(.jobs)
        }
    }

    package func job(pk: Int64) throws -> AgentJob? {
        try db.queryOne(Database.jobSelect + " WHERE j.pk = ?", [.integer(pk)]) { readJob($0) }
    }

    package func job(id: String) throws -> AgentJob? {
        try db.queryOne(Database.jobSelect + " WHERE j.id = ?", [.text(id)]) { readJob($0) }
    }

    /// The paper's held/queued/running job (at most one, enforced by ux_agent_active).
    package func activeJob(paperPK: Int64) throws -> AgentJob? {
        try db.queryOne(Database.jobSelect + " WHERE j.paper_pk = ? AND j.state IN ('held', 'queued', 'running')",
                        [.integer(paperPK)]) { readJob($0) }
    }

    /// Queued, past its backoff, paper still live; highest priority, then oldest.
    package func nextRunnableJob(now: Date = Date()) throws -> AgentJob? {
        try db.queryOne(Database.jobSelect + """
             JOIN paper p ON p.pk = j.paper_pk
             WHERE j.state = 'queued' AND (j.not_before IS NULL OR j.not_before <= ?) AND p.deleted_at IS NULL
             ORDER BY j.priority DESC, j.created_at, j.pk LIMIT 1
            """, [.text(Database.timestamp(now))]) { readJob($0) }
    }

    /// Jobs in any of `states`, in run order.
    package func jobs(states: Set<AgentJobState>) throws -> [AgentJob] {
        guard !states.isEmpty else { return [] }
        let json = String(decoding: try encoder.encode(states.map(\.rawValue).sorted()), as: UTF8.self)
        return try db.query(Database.jobSelect + """
             WHERE j.state IN (SELECT value FROM json_each(?)) ORDER BY j.priority DESC, j.created_at, j.pk
            """, [.text(json)]) { readJob($0) }
    }

    /// Most recently active first.
    package func recentJobs(limit: Int) throws -> [AgentJob] {
        try db.query(Database.jobSelect + """
             ORDER BY COALESCE(j.finished_at, j.started_at, j.created_at) DESC, j.pk DESC LIMIT ?
            """, [.int(limit)]) { readJob($0) }
    }

    /// Startup recovery: running → queued (start time cleared). Papers whose
    /// `ai_state` is still `running` are set back to `queued` to match.
    @discardableResult
    package func resetRunningJobsToQueued() throws -> Int {
        try write {
            try db.run("""
                UPDATE paper SET ai_state = 'queued', updated_at = ?
                WHERE ai_state = 'running' AND pk IN (SELECT paper_pk FROM agent_job WHERE state = 'running')
                """, [.text(Database.timestamp(Date()))])
            if db.changes > 0 { note(.papersBulk) }
            try db.run("UPDATE agent_job SET state = 'queued', started_at = NULL WHERE state = 'running'")
            let n = db.changes
            if n > 0 { note(.jobs) }
            return n
        }
    }

    /// Earliest backoff among queued jobs of live papers (the queue sleeps until then).
    package func earliestNotBefore() throws -> Date? {
        try db.scalarString("""
            SELECT MIN(j.not_before) FROM agent_job j JOIN paper p ON p.pk = j.paper_pk
            WHERE j.state = 'queued' AND j.not_before IS NOT NULL AND p.deleted_at IS NULL
            """).flatMap(Database.date(fromTimestamp:))
    }

    private func jobValues(_ j: AgentJob) -> [SQLiteValue] {
        [.text(j.id), .integer(j.paperPK), .text(j.provider), .text(j.state.rawValue), .int(j.priority),
         .int(j.attempt), .int(j.textBudget), .string(j.effort), .string(j.notBefore.map(Database.timestamp)),
         .string(j.errorKind), .string(j.errorMessage), .string(j.model), .int(j.durationMs), .double(j.costUSD),
         .int(j.inputTokens), .int(j.outputTokens), .text(Database.timestamp(j.createdAt)),
         .string(j.startedAt.map(Database.timestamp)), .string(j.finishedAt.map(Database.timestamp))]
    }

    private func readJob(_ s: SQLiteStatement) -> AgentJob {
        var c = Columns(s)
        return AgentJob(pk: c.int64(), id: c.string(), paperPK: c.int64(), provider: c.string(),
                        state: c.raw(AgentJobState.failed), priority: c.int(), attempt: c.int(),
                        textBudget: c.optInt(), effort: c.optString(), notBefore: c.optDate(),
                        errorKind: c.optString(), errorMessage: c.optString(), model: c.optString(),
                        durationMs: c.optInt(), costUSD: c.optDouble(), inputTokens: c.optInt(),
                        outputTokens: c.optInt(), createdAt: c.date(), startedAt: c.optDate(),
                        finishedAt: c.optDate())
    }

    // MARK: - Full-text search

    /// Replaces the paper's full-text row (the text itself is not stored — contentless).
    package func indexFullText(pk: Int64, text: String) throws {
        try write {
            guard try db.scalarInt("SELECT 1 FROM paper WHERE pk = ?", [.integer(pk)]) != nil else {
                throw DatabaseError.notFound("paper \(pk)")
            }
            try db.run("DELETE FROM paper_fts_text WHERE rowid = ?", [.integer(pk)])
            if !text.isEmpty {
                try db.run("INSERT INTO paper_fts_text(rowid, fulltext) VALUES(?, ?)", [.integer(pk), .text(text)])
            }
        }
    }

    /// Rebuilds the metadata FTS row from the current paper row, card and tags.
    package func reindexMeta(pk: Int64) throws {
        try write { try indexMeta(pk: pk) }
    }

    private func indexMeta(pk: Int64) throws {
        try db.run("DELETE FROM paper_fts_meta WHERE rowid = ?", [.integer(pk)])
        guard let p = try paper(pk: pk) else { return }
        let tagNames = try db.query("""
            SELECT t.name FROM paper_tag pt JOIN tag t ON t.pk = pt.tag_pk
            WHERE pt.paper_pk = ? AND pt.origin IN ('agent', 'user')
            """, [.integer(pk)]) { $0.string(0) }
        try db.run("""
            INSERT INTO paper_fts_meta(rowid, title, authors, abstract, card, tags, notes) VALUES(?, ?, ?, ?, ?, ?, ?)
            """, [.integer(pk), .text(p.title), .text(p.authors.joined(separator: ", ")), .text(p.abstract ?? ""),
                  .text(Database.cardText(p)), .text(tagNames.joined(separator: " ")), .text(p.notes)])
    }

    private static func cardText(_ p: Paper) -> String {
        var parts: [String] = []
        if let t = p.tldr { parts.append(t) }
        if let card = p.card {
            if card.tldr != p.tldr { parts.append(card.tldr) }
            parts.append(card.summary)
            parts.append(contentsOf: card.contributions)
            parts.append(card.method)
            parts.append(contentsOf: card.results)
            parts.append(contentsOf: card.keyTerms.map { "\($0.term): \($0.definition)" })
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Live paper pks for a search-box string (see `FTSQuery`): metadata hits
    /// first (bm25, title weighted), then full-text-only hits.
    package func search(_ query: String, limit: Int = 200) throws -> [Int64] {
        guard limit > 0 else { return [] }
        switch FTSQuery(query) {
        case .empty:
            return []
        case .doi(let doi):
            // Both bioRxiv prefixes find the same work (see `sameWorkDOIs`).
            let hits = try db.query("""
                SELECT pk FROM paper WHERE deleted_at IS NULL AND (doi IN (SELECT value FROM json_each(?1))
                  OR published_doi IN (SELECT value FROM json_each(?1))) ORDER BY pk LIMIT ?2
                """, [.text(try jsonStrings(Database.sameWorkDOIs(doi))), .int(limit)]) { $0.int64(0) }
            return hits.isEmpty ? try ftsFallback(query, limit: limit) : hits
        case .arxiv(let id):
            let hits = try db.query("""
                SELECT pk FROM paper WHERE deleted_at IS NULL AND arxiv_id = ?1 COLLATE NOCASE ORDER BY pk LIMIT ?2
                """, [.text(id), .int(limit)]) { $0.int64(0) }
            return hits.isEmpty ? try ftsFallback(query, limit: limit) : hits
        case .like(let needle):
            return try likeSearch(needle, limit: limit)
        case .match(let expr):
            do {
                return try ftsSearch(expr, limit: limit)
            } catch let e as SQLiteError {
                Log.db.error("FTS query failed, using LIKE: \(e.description, privacy: .public)")
                return try likeSearch(query.trimmingCharacters(in: .whitespacesAndNewlines), limit: limit)
            }
        }
    }

    /// An id that is not in the library may still be cited in some paper's text.
    private func ftsFallback(_ query: String, limit: Int) throws -> [Int64] {
        guard let expr = FTSQuery.matchExpression(query) else { return [] }
        return (try? ftsSearch(expr, limit: limit)) ?? []
    }

    private func ftsSearch(_ expr: String, limit: Int) throws -> [Int64] {
        var out = try db.query("""
            SELECT paper_fts_meta.rowid FROM paper_fts_meta JOIN paper ON paper.pk = paper_fts_meta.rowid
            WHERE paper_fts_meta MATCH ?1 AND paper.deleted_at IS NULL
            ORDER BY bm25(paper_fts_meta, 10.0, 4.0, 2.0, 2.0, 3.0, 1.0) LIMIT ?2
            """, [.text(expr), .int(limit)]) { $0.int64(0) }
        guard out.count < limit else { return out }
        var seen = Set(out)
        let text = try db.query("""
            SELECT paper_fts_text.rowid FROM paper_fts_text JOIN paper ON paper.pk = paper_fts_text.rowid
            WHERE paper_fts_text MATCH ?1 AND paper.deleted_at IS NULL
            ORDER BY bm25(paper_fts_text) LIMIT ?2
            """, [.text(expr), .int(limit + out.count)]) { $0.int64(0) }
        for pk in text where seen.insert(pk).inserted {
            out.append(pk)
            if out.count == limit { break }
        }
        return out
    }

    /// Substring match on title/tldr/notes/category name (CJK and 1–2 character input).
    private func likeSearch(_ needle: String, limit: Int) throws -> [Int64] {
        try db.query(#"""
            SELECT p.pk FROM paper p LEFT JOIN category c ON c.pk = p.category_pk
            WHERE p.deleted_at IS NULL AND (p.title LIKE ?1 ESCAPE '\' OR p.tldr LIKE ?1 ESCAPE '\'
              OR p.notes LIKE ?1 ESCAPE '\' OR c.name LIKE ?1 ESCAPE '\')
            ORDER BY (p.title LIKE ?1 ESCAPE '\') DESC, p.added_at DESC, p.pk DESC LIMIT ?2
            """#, [.text(FTSQuery.likePattern(needle)), .int(limit)]) { $0.int64(0) }
    }

    // MARK: - Metadata cache and key/value settings

    package func metaCache(key: String) throws -> (status: Int, body: Data?, fetchedAt: Date)? {
        try db.queryOne("SELECT status, body, fetched_at FROM meta_cache WHERE key = ?", [.text(key)]) {
            (status: $0.int(0), body: $0.data(1), fetchedAt: Database.date(fromTimestamp: $0.string(2)) ?? .distantPast)
        }
    }

    package func putMetaCache(key: String, status: Int, body: Data?, at date: Date = Date()) throws {
        try db.run("""
            INSERT INTO meta_cache(key, status, body, fetched_at) VALUES(?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET status = excluded.status, body = excluded.body, fetched_at = excluded.fetched_at
            """, [.text(key), .int(status), .data(body), .text(Database.timestamp(date))])
    }

    package func kv(_ key: String) throws -> String? {
        try db.scalarString("SELECT value FROM kv WHERE key = ?", [.text(key)])
    }

    package func setKV(_ key: String, _ value: String) throws {
        try write {
            try db.run("INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       [.text(key), .text(value)])
            note(.settings)
        }
    }

    package func removeKV(_ key: String) throws {
        try write {
            try db.run("DELETE FROM kv WHERE key = ?", [.text(key)])
            if db.changes > 0 { note(.settings) }
        }
    }

    // MARK: - Maintenance

    /// The schema level (for --doctor): 1 = library, 2 = library + mail (`Migrations`; on disk
    /// user_version 1 plus the `schema_feature` mail row).
    package func schemaVersion() throws -> Int { try Migrations.level(db) }

    package func quickCheck() -> Bool {
        (try? db.query("PRAGMA quick_check") { $0.string(0) }) == ["ok"]
    }

    /// "ok", or the problems found (one per line).
    package func integrityCheck() -> String {
        do {
            return try db.query("PRAGMA integrity_check") { $0.string(0) }.joined(separator: "\n")
        } catch {
            return String(describing: error)
        }
    }

    /// Consistent snapshot to `url` (daily backups). Fails if the file exists.
    package func vacuumInto(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try db.run("VACUUM INTO ?", [.text(url.path)])
    }

    /// Folds the WAL back into the main file and truncates it.
    package func checkpoint() throws {
        _ = try db.query("PRAGMA wal_checkpoint(TRUNCATE)") { $0.int(0) }
    }

    /// Closes the connection; any later call throws `SQLITE_MISUSE`.
    package func close() {
        guard db.isOpen else { return }
        try? db.exec("PRAGMA optimize")
        db.close()
    }

    // MARK: - Encoding helpers

    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()

    /// ISO-8601 UTC rounded to the millisecond, e.g. `2026-09-30T02:15:00.123Z`.
    /// Fixed width, so SQL string comparison orders instants correctly. Built from
    /// integer milliseconds (FormatStyle truncates) so that
    /// `timestamp(date(fromTimestamp: s)) == s` — rows never drift on re-save.
    package static func timestamp(_ date: Date) -> String {
        let t = date.timeIntervalSince1970
        let totalMS = t.isFinite ? Int64((t * 1000).rounded()) : 0
        let ms = floorMod(totalMS, 1000)
        let secs = (totalMS - ms) / 1000
        let sod = floorMod(secs, 86_400)
        let (y, m, d) = civil(fromDays: (secs - sod) / 86_400)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", Int(y), Int(m), Int(d),
                      Int(sod / 3600), Int(sod % 3600 / 60), Int(sod % 60), Int(ms))
    }

    /// Parses `timestamp` output (fast path) or any ISO-8601 instant, rounded to the millisecond.
    package static func date(fromTimestamp s: String) -> Date? {
        if let fixed = parseFixedTimestamp(s) { return fixed }   // our shape: valid date or nil, no lenient fallback
        guard let d = (try? isoFractional.parse(s)) ?? (try? isoPlain.parse(s)) else { return nil }
        return Date(timeIntervalSince1970: (d.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    /// `YYYY-MM-DDTHH:MM:SS[.fff]Z`: outer nil = other shape; inner nil = impossible date (Feb 30).
    private static func parseFixedTimestamp(_ s: String) -> Date?? {
        let b = Array(s.utf8)
        guard b.count == 20 || b.count == 24, b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-"),
              b[10] == UInt8(ascii: "T"), b[13] == UInt8(ascii: ":"), b[16] == UInt8(ascii: ":"),
              b[b.count - 1] == UInt8(ascii: "Z") else { return nil }
        func number(_ r: Range<Int>) -> Int64? {
            var v: Int64 = 0
            for i in r {
                guard b[i] >= UInt8(ascii: "0"), b[i] <= UInt8(ascii: "9") else { return nil }
                v = v * 10 + Int64(b[i] - UInt8(ascii: "0"))
            }
            return v
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19) else { return nil }
        var ms: Int64 = 0
        if b.count == 24 {
            guard b[19] == UInt8(ascii: "."), let f = number(20..<23) else { return nil }
            ms = f
        }
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else {
            return .some(nil)
        }
        let days = days(fromCivil: year, month, day)
        guard civil(fromDays: days) == (year, month, day) else { return .some(nil) }
        let secs = days * 86_400 + hour * 3600 + minute * 60 + second
        return Date(timeIntervalSince1970: Double(secs * 1000 + ms) / 1000)
    }

    private static func floorMod(_ a: Int64, _ n: Int64) -> Int64 { ((a % n) + n) % n }

    // Proleptic-Gregorian day arithmetic (H. Hinnant's algorithms): exact, no libc range limits.
    private static func days(fromCivil y0: Int64, _ m: Int64, _ d: Int64) -> Int64 {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civil(fromDays z0: Int64) -> (Int64, Int64, Int64) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    /// Empty or whitespace ids become NULL so they never collide in the unique indexes.
    static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func jsonArray(_ pks: [Int64]) -> String {
        "[" + pks.map(String.init).joined(separator: ",") + "]"
    }

    /// A JSON array of strings (bound to `json_each(?)`).
    func jsonStrings(_ values: [String]) throws -> String {
        String(decoding: try encoder.encode(values), as: UTF8.self)
    }
}

/// Sequential column reader so row mappers cannot get an index wrong.
struct Columns {
    let s: SQLiteStatement
    var i: Int32

    init(_ s: SQLiteStatement, start: Int32 = 0) { self.s = s; self.i = start }

    private mutating func next() -> Int32 { defer { i += 1 }; return i }

    mutating func int64() -> Int64 { s.int64(next()) }
    mutating func int() -> Int { s.int(next()) }
    mutating func double() -> Double { s.double(next()) }
    mutating func bool() -> Bool { s.bool(next()) }
    mutating func string() -> String { s.string(next()) }
    mutating func optString() -> String? { s.optionalString(next()) }
    mutating func optInt() -> Int? { s.optionalInt(next()) }
    mutating func optInt64() -> Int64? { s.optionalInt64(next()) }
    mutating func optDouble() -> Double? { s.optionalDouble(next()) }
    mutating func date() -> Date { optDate() ?? .distantPast }
    mutating func optDate() -> Date? { s.optionalString(next()).flatMap(Database.date(fromTimestamp:)) }
    mutating func localDate() -> LocalDate? { s.optionalString(next()).flatMap(LocalDate.init(iso:)) }
    mutating func raw<E: RawRepresentable>(_ fallback: E) -> E where E.RawValue == String {
        E(rawValue: s.string(next())) ?? fallback
    }
    mutating func rawInt<E: RawRepresentable>(_ fallback: E) -> E where E.RawValue == Int {
        E(rawValue: s.int(next())) ?? fallback
    }
}
