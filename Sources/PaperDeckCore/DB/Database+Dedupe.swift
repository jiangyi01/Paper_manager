import Foundation

// The duplicate check's tables (SchemaAssist.swift): `paper_key`, `paper_fingerprint`,
// `paper_history`, `dup_review`, `dup_pair`, `reading_cycle`. Owned by Slice B. Writes to them
// never touch a paper row (those go through updatePaper / modifyPaper as everywhere else), so
// they announce no library change of their own; reviews reach the UI as `EngineEvent.dedupe`.
extension Database {
    // MARK: - paper_key

    /// Every key of a paper (local ones included; `DupSubject.paper` re-derives those).
    package func dupKeys(paperPK: Int64) throws -> [DupKey] {
        try db.query("SELECT kind, value, source FROM paper_key WHERE paper_pk = ? ORDER BY kind, value",
                     [.integer(paperPK)]) { s in
            DupKey(kind: DupKey.Kind(rawValue: s.string(0)) ?? .doi, value: s.string(1),
                   source: DupKey.Source(rawValue: s.string(2)) ?? .crossref)
        }
    }

    /// Keys of several papers; every requested pk is a key of the result.
    package func dupKeys(paperPKs: [Int64]) throws -> [Int64: [DupKey]] {
        var out = Dictionary(paperPKs.map { ($0, [DupKey]()) }, uniquingKeysWith: { a, _ in a })
        guard !paperPKs.isEmpty else { return out }
        let rows = try db.query("""
            SELECT paper_pk, kind, value, source FROM paper_key WHERE paper_pk IN (SELECT value FROM json_each(?))
            """, [.text(Database.jsonArray(paperPKs))]) { s in
            (s.int64(0), DupKey(kind: DupKey.Kind(rawValue: s.string(1)) ?? .doi, value: s.string(2),
                                source: DupKey.Source(rawValue: s.string(3)) ?? .crossref))
        }
        for (pk, key) in rows { out[pk, default: []].append(key) }
        return out
    }

    /// Adds keys (an existing (kind, value) of the paper keeps its first source).
    package func addDupKeys(paperPK: Int64, _ keys: [DupKey]) throws {
        guard !keys.isEmpty else { return }
        try write {
            for k in keys {
                try db.run("INSERT OR IGNORE INTO paper_key(paper_pk, kind, value, source) VALUES(?, ?, ?, ?)",
                           [.integer(paperPK), .text(k.kind.rawValue), .text(k.value), .text(k.source.rawValue)])
            }
        }
    }

    /// Removes the paper's keys of one source (an undone merge's aliases).
    package func deleteDupKeys(paperPK: Int64, source: DupKey.Source) throws {
        try write {
            try db.run("DELETE FROM paper_key WHERE paper_pk = ? AND source = ?", [.integer(paperPK), .text(source.rawValue)])
        }
    }

    /// Re-derives the paper's `local` keys from its row (after its ids changed).
    package func refreshLocalDupKeys(paperPK: Int64) throws {
        try write {
            guard let p = try paper(pk: paperPK) else { return }
            try db.run("DELETE FROM paper_key WHERE paper_pk = ? AND source = 'local'", [.integer(paperPK)])
            for k in DupKeys.local(p.ids) {
                try db.run("INSERT OR IGNORE INTO paper_key(paper_pk, kind, value, source) VALUES(?, ?, ?, ?)",
                           [.integer(paperPK), .text(k.kind.rawValue), .text(k.value), .text(k.source.rawValue)])
            }
        }
    }

    /// Gives every paper with ids but no local key its local keys (papers imported before the
    /// duplicate check, or by an older build). Returns how many papers got keys.
    @discardableResult
    package func backfillLocalDupKeys() throws -> Int {
        try write {
            let pks = try db.query("""
                SELECT p.pk FROM paper p WHERE (p.doi IS NOT NULL OR p.published_doi IS NOT NULL OR p.arxiv_id IS NOT NULL)
                  AND NOT EXISTS (SELECT 1 FROM paper_key k WHERE k.paper_pk = p.pk AND k.source = 'local')
                """) { $0.int64(0) }
            for pk in pks { try refreshLocalDupKeys(paperPK: pk) }
            return pks.count
        }
    }

    /// Papers — live and Recently Deleted — holding any of `tokens` (paper_key), any of `dois`
    /// (their own or published DOI) or the arXiv id; `excluding` is skipped.
    package func paperPKs(holdingTokens tokens: [String], dois: [String], arxivID: String?,
                          excluding pk: Int64?) throws -> [Int64] {
        guard !tokens.isEmpty || !dois.isEmpty || arxivID != nil else { return [] }
        let kinds = try jsonStrings(DupKey.Kind.allCases.map(\.rawValue))
        return try db.query("""
            SELECT pk FROM paper WHERE (?3 IS NULL OR pk <> ?3) AND (
              doi IN (SELECT value FROM json_each(?1)) OR published_doi IN (SELECT value FROM json_each(?1))
              OR (?2 IS NOT NULL AND arxiv_id = ?2 COLLATE NOCASE))
            UNION
            SELECT paper_pk FROM paper_key WHERE kind IN (SELECT value FROM json_each(?5))
              AND value IN (SELECT value FROM json_each(?4)) AND (?3 IS NULL OR paper_pk <> ?3)
            ORDER BY 1 LIMIT 50
            """, [.text(try jsonStrings(dois.map { $0.lowercased() })), .string(arxivID), .int64(pk),
                  .text(try jsonStrings(Array(Set(tokens)).sorted())), .text(kinds)]) { $0.int64(0) }
    }

    // MARK: - paper_fingerprint

    /// The stored signatures of a paper and when they were computed (`source_updated_at` = the
    /// paper's `updated_at` then).
    package func dupFingerprint(paperPK: Int64) throws -> (page: [UInt32]?, abstract: [UInt32]?, sha256Prefix: String?,
                                                          sourceUpdatedAt: Date)? {
        try db.queryOne("SELECT minhash, source_updated_at FROM paper_fingerprint WHERE paper_pk = ? AND algo = 1",
                        [.integer(paperPK)]) { s in
            let d = MinHash.decode(s.data(0))
            return (d.page, d.abstract, d.sha256Prefix, Database.date(fromTimestamp: s.string(1)) ?? .distantPast)
        }
    }

    /// Several papers' stored signatures.
    package func dupFingerprints(paperPKs: [Int64]) throws -> [Int64: (page: [UInt32]?, abstract: [UInt32]?, sha256Prefix: String?)] {
        guard !paperPKs.isEmpty else { return [:] }
        let rows = try db.query("""
            SELECT paper_pk, minhash FROM paper_fingerprint WHERE algo = 1 AND paper_pk IN (SELECT value FROM json_each(?))
            """, [.text(Database.jsonArray(paperPKs))]) { s in (s.int64(0), MinHash.decode(s.data(1))) }
        var out: [Int64: (page: [UInt32]?, abstract: [UInt32]?, sha256Prefix: String?)] = [:]
        for (pk, d) in rows { out[pk] = (d.page, d.abstract, d.sha256Prefix) }
        return out
    }

    /// Stores a paper's fingerprint (recomputable; never in the sidecar).
    package func upsertDupFingerprint(paperPK: Int64, subject: DupSubject, sha256: String, sourceUpdatedAt: Date,
                                      now: Date) throws {
        try write {
            try db.run("""
                INSERT INTO paper_fingerprint(paper_pk, algo, title_norm, first_surname, surnames_json, year, version_rank,
                  minhash, source_updated_at, computed_at) VALUES(?1, 1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                ON CONFLICT(paper_pk) DO UPDATE SET algo = 1, title_norm = ?2, first_surname = ?3, surnames_json = ?4,
                  year = ?5, version_rank = ?6, minhash = ?7, source_updated_at = ?8, computed_at = ?9
                """, [.integer(paperPK), .text(subject.titleNorm), .string(subject.surnames.first),
                      .text(try jsonStrings(subject.surnames)), .int(subject.year), .int(subject.rank.code),
                      .data(MinHash.encode(page: subject.page, abstract: subject.abstract, sha256: sha256)),
                      .text(Database.timestamp(sourceUpdatedAt)), .text(Database.timestamp(now))])
        }
    }

    package func deleteDupFingerprint(paperPK: Int64) throws {
        try write { try db.run("DELETE FROM paper_fingerprint WHERE paper_pk = ?", [.integer(paperPK)]) }
    }

    // MARK: - Candidates (FTS5 bm25; live and Recently Deleted)

    /// ≤ `limit` papers whose title (or, weaker, abstract) shares words with `tokens` (raw-title
    /// words: the index holds "β", not "beta"), best bm25 first.
    package func dedupeTitleCandidates(tokens: [String], excluding pk: Int64?, limit: Int = 20) throws -> [Int64] {
        guard tokens.count >= 2 else { return [] }
        let expr = "{title abstract} : (" + tokens.prefix(16).map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"" }
            .joined(separator: " OR ") + ")"
        do {
            return try db.query("""
                SELECT f.rowid FROM paper_fts_meta f JOIN paper p ON p.pk = f.rowid
                 WHERE paper_fts_meta MATCH ?1 AND (?2 IS NULL OR p.pk <> ?2)
                 ORDER BY bm25(paper_fts_meta, 10.0, 0.0, 2.0, 0.0, 0.0, 0.0) LIMIT ?3
                """, [.text(expr), .int64(pk), .int(limit)]) { $0.int64(0) }
        } catch let e as SQLiteError {
            Log.db.error("dedupe title candidates failed: \(e.description, privacy: .public)")
            return []
        }
    }

    /// ≤ `limit` papers whose full text shares the most words with `tokens` (a paper without a
    /// usable title: its first page's words).
    package func dedupeTextCandidates(tokens: [String], excluding pk: Int64?, limit: Int = 10) throws -> [Int64] {
        guard tokens.count >= 4 else { return [] }
        let expr = tokens.prefix(24).map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"" }.joined(separator: " OR ")
        do {
            return try db.query("""
                SELECT f.rowid FROM paper_fts_text f JOIN paper p ON p.pk = f.rowid
                 WHERE paper_fts_text MATCH ?1 AND (?2 IS NULL OR p.pk <> ?2)
                 ORDER BY bm25(paper_fts_text) LIMIT ?3
                """, [.text(expr), .int64(pk), .int(limit)]) { $0.int64(0) }
        } catch let e as SQLiteError {
            Log.db.error("dedupe text candidates failed: \(e.description, privacy: .public)")
            return []
        }
    }

    // MARK: - paper_history (tombstones)

    private static let historyColumns = """
        pk, paper_id, sha256, doi, arxiv_id, published_doi, keys_json, title, title_norm, first_surname, year, minhash,
        last_status, read_count, done_at, added_at, purged_at
        """

    private func readHistory(_ s: SQLiteStatement) -> DupHistoryRow {
        var c = Columns(s)
        let pk = c.int64(), paperID = c.string(), sha = c.optString(), doi = c.optString(), arxiv = c.optString()
        let published = c.optString(), keysJSON = c.string(), title = c.string(), norm = c.string()
        let surname = c.optString(), year = c.optInt()
        let sig = MinHash.decode(s.data(c.i)); c.i += 1
        let status = c.raw(PaperStatus.toRead), reads = c.int(), done = c.optDate(), added = c.optDate(), purged = c.date()
        let keys = (try? decoder.decode([String].self, from: Data(keysJSON.utf8))) ?? []
        return DupHistoryRow(pk: pk, paperID: paperID, sha256: sha, doi: doi, arxivID: arxiv, publishedDOI: published,
                             keys: keys, title: title, titleNorm: norm, firstSurname: surname, year: year,
                             page: sig.page, abstract: sig.abstract, lastStatus: status, readCount: reads, doneAt: done,
                             addedAt: added, purgedAt: purged)
    }

    @discardableResult
    package func insertHistory(_ h: DupHistoryRow) throws -> Int64 {
        try write {
            try db.run("""
                INSERT INTO paper_history(paper_id, sha256, doi, arxiv_id, published_doi, keys_json, title, title_norm,
                  first_surname, year, minhash, last_status, read_count, done_at, added_at, purged_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.text(h.paperID), .string(h.sha256?.lowercased()), .string(h.doi), .string(h.arxivID),
                      .string(h.publishedDOI), .text(try jsonStrings(h.keys)), .text(h.title), .text(h.titleNorm),
                      .string(h.firstSurname), .int(h.year),
                      .data(MinHash.encode(page: h.page, abstract: h.abstract, sha256: h.sha256)),
                      .text(h.lastStatus.rawValue), .int(h.readCount), .string(h.doneAt.map(Database.timestamp)),
                      .string(h.addedAt.map(Database.timestamp)), .text(Database.timestamp(h.purgedAt))])
            return db.lastInsertRowID
        }
    }

    /// Whether a removed paper may leave a tombstone: not when its title or identifiers are
    /// private — marked unpublished / confidential or "never use AI", held as a possibly
    /// unpublished emailed PDF, from a confidential email (a manuscript under review), or from a
    /// person's email without a public identifier (a purged or unknown message counts as a
    /// person's, as `Engine.privacyInputs` reads it).
    package func mayRemember(_ p: Paper) throws -> Bool {
        if let policy = try paperPolicy(paperPK: p.pk), !policy.isEmpty { return false }
        if p.aiNote == ImportAnnotation.unpublishedHoldNote { return false }
        let identified = p.ids.doi != nil || p.ids.arxivID != nil || p.ids.publishedDOI != nil
        for source in try paperSources(paperPK: p.pk) {
            var message: MailMessage?
            if let id = source.mailMessageID { message = try mailMessage(id: id) }
            if message == nil, let mid = source.internetMessageID { message = try mailMessage(internetMessageID: mid) }
            if let message, MailHeuristics.isConfidential(message) { return false }
            if !identified, message.map({ $0.senderKind != .alert }) ?? true { return false }
        }
        return true
    }

    /// The tombstone of a paper about to be hard-deleted (call inside that transaction): its ids
    /// and identity tokens, title, first author, year, signatures and reading history. Returns its pk.
    @discardableResult
    package func writeTombstone(_ p: Paper, at date: Date) throws -> Int64 {
        try write {
            let stored = try dupKeys(paperPK: p.pk).filter { $0.source != .local }
            let keys = Array(Set((DupKeys.local(p.ids) + stored).map(\.value))).sorted()
            let fp = try dupFingerprint(paperPK: p.pk)
            let cycles = try readingCycles(paperPK: p.pk)
            let reads = ReadingCycle.readCount(cycles, doneAt: p.doneAt ?? (p.status == .done ? p.updatedAt : nil))
            let row = DupHistoryRow(paperID: p.id, sha256: p.sha256, doi: p.ids.doi, arxivID: p.ids.arxivID,
                                    publishedDOI: p.ids.publishedDOI, keys: keys, title: p.title,
                                    titleNorm: DedupeText.titleNorm(p.title), firstSurname: DedupeText.surnames(p.authors).first,
                                    year: p.year, page: fp?.page, abstract: fp?.abstract ?? MinHash.abstractSignature(p.abstract),
                                    lastStatus: p.status, readCount: reads, doneAt: p.doneAt, addedAt: p.addedAt,
                                    purgedAt: date)
            return try insertHistory(row)
        }
    }

    package func historyRow(pk: Int64) throws -> DupHistoryRow? {
        try db.queryOne("SELECT \(Database.historyColumns) FROM paper_history WHERE pk = ?", [.integer(pk)]) { readHistory($0) }
    }

    /// Tombstones with the bytes or an identity token (exact matches; at most 20).
    package func historyMatching(sha256: String?, tokens: [String], dois: [String], arxivID: String?) throws -> [DupHistoryRow] {
        try db.query("""
            SELECT \(Database.historyColumns) FROM paper_history h
             WHERE (?1 IS NOT NULL AND h.sha256 = ?1)
                OR h.doi IN (SELECT value FROM json_each(?2)) OR h.published_doi IN (SELECT value FROM json_each(?2))
                OR (?3 IS NOT NULL AND h.arxiv_id = ?3 COLLATE NOCASE)
                OR EXISTS (SELECT 1 FROM json_each(h.keys_json) k WHERE k.value IN (SELECT value FROM json_each(?4)))
             ORDER BY h.purged_at DESC LIMIT 20
            """, [.string(sha256?.lowercased()), .text(try jsonStrings(dois.map { $0.lowercased() })), .string(arxivID),
                  .text(try jsonStrings(tokens))]) { readHistory($0) }
    }

    /// The most recent tombstones (fuzzy comparisons; the table is small).
    package func recentHistory(limit: Int = 500) throws -> [DupHistoryRow] {
        try db.query("SELECT \(Database.historyColumns) FROM paper_history ORDER BY purged_at DESC LIMIT ?",
                     [.int(limit)]) { readHistory($0) }
    }

    /// The normalized titles of the most recent tombstones (pk, title_norm) — what the import's
    /// title scan reads first, without decoding every row's signatures.
    package func historyTitles(limit: Int = 500) throws -> [(pk: Int64, titleNorm: String)] {
        try db.query("SELECT pk, title_norm FROM paper_history ORDER BY purged_at DESC LIMIT ?", [.int(limit)]) {
            ($0.int64(0), $0.string(1))
        }
    }

    /// Tombstones by pk (most recent first).
    package func historyRows(pks: [Int64]) throws -> [DupHistoryRow] {
        guard !pks.isEmpty else { return [] }
        return try db.query("""
            SELECT \(Database.historyColumns) FROM paper_history WHERE pk IN (SELECT value FROM json_each(?))
             ORDER BY purged_at DESC
            """, [.text(Database.jsonArray(pks))]) { readHistory($0) }
    }

    package func historyCount() throws -> Int { Int(try db.scalarInt("SELECT count(*) FROM paper_history") ?? 0) }

    /// Settings ▸ Library ▸ Duplicates ▸ Clear History: every tombstone (and the reviews that matched one).
    @discardableResult
    package func clearHistory() throws -> Int {
        try write {
            try db.run("DELETE FROM paper_history")
            return db.changes
        }
    }

    // MARK: - dup_review

    private static let reviewSelect = """
        SELECT r.id, np.id, ep.id, r.band, r.score, r.state, r.ai_state, r.created_at, r.new_paper_pk,
          r.existing_paper_pk, r.history_pk, r.relation, r.evidence_json, r.newer_side, r.origin, r.batch_id,
          r.pending_id, r.staged_name, r.held_schedule_json, r.choice, r.resolved_at, r.ai_verdict_json
        FROM dup_review r LEFT JOIN paper np ON np.pk = r.new_paper_pk LEFT JOIN paper ep ON ep.pk = r.existing_paper_pk
        """

    private func readReview(_ s: SQLiteStatement) -> DupReview {
        var c = Columns(s)
        let id = c.string(), newID = c.optString(), existingID = c.optString()
        let band = c.raw(DupBand.possible), score = c.double(), state = c.raw(DupReviewState.open), ai = c.string()
        let created = c.date(), newPK = c.optInt64(), existingPK = c.optInt64(), historyPK = c.optInt64()
        let relation = c.raw(DupRelation.sameWork), evidenceJSON = c.string(), newer = c.optString()
        let origin = c.raw(DupOrigin.intake), batch = c.optString(), pending = c.optString(), staged = c.optString()
        let heldJSON = c.optString(), choice = c.optString(), resolved = c.optDate(), verdictJSON = c.optString()
        let evidence = (try? decoder.decode([DupEvidence].self, from: Data(evidenceJSON.utf8))) ?? []
        let held = heldJSON.flatMap { try? decoder.decode(DupHeldIntent.self, from: Data($0.utf8)) }
        // A verdict this build can't read (a later build's) is shown as none, never guessed.
        let verdict = verdictJSON.flatMap { try? decoder.decode(DupAIVerdict.self, from: Data($0.utf8)) }
        return DupReview(id: id, newPaperID: newID, existingPaperID: existingID, band: band, score: score, state: state,
                         aiState: ai, createdAt: created, newPaperPK: newPK, existingPaperPK: existingPK,
                         historyPK: historyPK, relation: relation, evidence: evidence,
                         newerSide: newer.flatMap(DupSide.init(rawValue:)), origin: origin, batchID: batch,
                         pendingID: pending, stagedName: staged, held: held, choice: choice, resolvedAt: resolved,
                         aiVerdict: verdict)
    }

    private func reviewValues(_ r: DupReview) throws -> [SQLiteValue] {
        let evidence = String(decoding: try encoder.encode(r.evidence), as: UTF8.self)
        let held = try r.held.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        let verdict = try r.aiVerdict.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        return [.text(r.id), .int64(r.newPaperPK), .string(r.pendingID), .string(r.stagedName), .int64(r.existingPaperPK),
                .int64(r.historyPK), .text(r.band.rawValue), .text(r.relation.rawValue), .real(r.score), .text(evidence),
                .string(r.newerSide?.rawValue), .text(r.origin.rawValue), .string(r.batchID), .string(held),
                .text(r.aiState), .text(r.state.rawValue), .string(r.choice), .text(Database.timestamp(r.createdAt)),
                .string(r.resolvedAt.map(Database.timestamp)), .string(verdict)]
    }

    private static let reviewColumns = """
        id, new_paper_pk, pending_id, staged_name, existing_paper_pk, history_pk, band, relation, score, evidence_json,
        newer_side, origin, batch_id, held_schedule_json, ai_state, state, choice, created_at, resolved_at, ai_verdict_json
        """

    package func insertDupReview(_ r: DupReview) throws {
        try write {
            try db.run("INSERT INTO dup_review(\(Database.reviewColumns)) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                       try reviewValues(r))
        }
    }

    /// Rewrites a review by id (every column but the pk).
    package func updateDupReview(_ r: DupReview) throws {
        try write {
            let sets = Database.reviewColumns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .enumerated().map { "\($1) = ?\($0 + 1)" }.joined(separator: ", ")
            try db.run("UPDATE dup_review SET \(sets) WHERE id = ?1", try reviewValues(r))
            guard db.changes == 1 else { throw DatabaseError.notFound("duplicate review \(r.id)") }
        }
    }

    package func dupReview(id: String) throws -> DupReview? {
        try db.queryOne(Database.reviewSelect + " WHERE r.id = ?", [.text(id)]) { readReview($0) }
    }

    /// Reads, changes and rewrites one review in one step — no other write (the AI judge's answer,
    /// the import's enrichment, a resolution) lands between the read and the write. `body` returns
    /// false to leave it as it is. The stored review, or nil when the id is unknown or nothing changed.
    @discardableResult
    package func modifyDupReview(id: String, _ body: @Sendable (inout DupReview) throws -> Bool) throws -> DupReview? {
        guard var r = try dupReview(id: id) else { return nil }
        guard try body(&r) else { return nil }
        try updateDupReview(r)
        return r
    }

    /// Reviews in `state`, newest first.
    package func dupReviews(state: DupReviewState) throws -> [DupReview] {
        try db.query(Database.reviewSelect + " WHERE r.state = ? ORDER BY r.created_at DESC, r.pk DESC",
                     [.text(state.rawValue)]) { readReview($0) }
    }

    /// The open review whose new paper is `paperPK` (at most one is kept open per new paper).
    package func openDupReview(newPaperPK: Int64) throws -> DupReview? {
        try db.queryOne(Database.reviewSelect + " WHERE r.state = 'open' AND r.new_paper_pk = ? ORDER BY r.pk DESC LIMIT 1",
                        [.integer(newPaperPK)]) { readReview($0) }
    }

    /// The open review of a parked file.
    package func openDupReview(pendingID: String) throws -> DupReview? {
        try db.queryOne(Database.reviewSelect + " WHERE r.state = 'open' AND r.pending_id = ? ORDER BY r.pk DESC LIMIT 1",
                        [.text(pendingID)]) { readReview($0) }
    }

    /// Open reviews that involve `paperPK` on either side.
    package func openDupReviews(involving paperPK: Int64) throws -> [DupReview] {
        try db.query(Database.reviewSelect + """
             WHERE r.state = 'open' AND (r.new_paper_pk = ?1 OR r.existing_paper_pk = ?1) ORDER BY r.pk
            """, [.integer(paperPK)]) { readReview($0) }
    }

    /// An open review of this exact pair (either direction).
    package func openDupReview(pair a: Int64, _ b: Int64) throws -> DupReview? {
        try db.queryOne(Database.reviewSelect + """
             WHERE r.state = 'open' AND ((r.new_paper_pk = ?1 AND r.existing_paper_pk = ?2)
               OR (r.new_paper_pk = ?2 AND r.existing_paper_pk = ?1)) LIMIT 1
            """, [.integer(a), .integer(b)]) { readReview($0) }
    }

    package func openDupReviewCount() throws -> Int {
        Int(try db.scalarInt("SELECT count(*) FROM dup_review WHERE state = 'open'") ?? 0)
    }

    /// Open reviews of one import batch, oldest first.
    package func openDupReviews(batchID: String) throws -> [DupReview] {
        try db.query(Database.reviewSelect + " WHERE r.state = 'open' AND r.batch_id = ? ORDER BY r.created_at, r.pk",
                     [.text(batchID)]) { readReview($0) }
    }

    /// Open reviews whose earlier paper is `pk`, which is about to be hard-deleted (their rows
    /// would go with it, ON DELETE CASCADE, and leave a held new paper held for nothing): pointed
    /// at `history` (its tombstone) or at `to` (the paper it was merged into). A parked file's
    /// review, or one that would compare a paper with itself, is dismissed instead. Returns the
    /// dismissed reviews that hold a committed new paper (the caller releases it). Call inside
    /// the deleting transaction.
    package func retargetOpenDupReviews(existing pk: Int64, to newExisting: Int64?, history: Int64?,
                                        now: Date) throws -> [DupReview] {
        try write {
            let open = try db.query(Database.reviewSelect + " WHERE r.state = 'open' AND r.existing_paper_pk = ?",
                                    [.integer(pk)]) { readReview($0) }
            var released: [DupReview] = []
            for var r in open {
                if r.newPaperPK != nil, let history {
                    r.existingPaperPK = nil
                    r.existingPaperID = nil
                    r.historyPK = history
                } else if let to = newExisting, r.newPaperPK != nil, r.newPaperPK != to {
                    r.existingPaperPK = to
                } else {
                    r.state = .dismissed
                    r.resolvedAt = now
                    r.pendingID = nil
                    if r.newPaperPK != nil { released.append(r) }
                }
                try updateDupReview(r)
            }
            return released
        }
    }

    /// Every review (any state) that names a paper on either side — what a hard delete of every
    /// paper would cascade away (`paperAssistLinks`, index rebuild).
    package func dupReviewsNamingPapers() throws -> [DupReview] {
        try db.query(Database.reviewSelect + """
             WHERE r.new_paper_pk IS NOT NULL OR r.existing_paper_pk IS NOT NULL ORDER BY r.pk
            """) { readReview($0) }
    }

    /// Open reviews that matched a tombstone (Clear History removes those rows with them).
    package func openDupReviewsMatchingHistory() throws -> [DupReview] {
        try db.query(Database.reviewSelect + " WHERE r.state = 'open' AND r.history_pk IS NOT NULL ORDER BY r.pk") {
            readReview($0)
        }
    }

    // MARK: - dup_pair

    /// The user's (or the judge's) decision about a pair, either order.
    package func dupPair(_ a: Int64, _ b: Int64) throws -> (decision: String, relation: String?, decidedBy: String)? {
        let (lo, hi) = a < b ? (a, b) : (b, a)
        return try db.queryOne("SELECT decision, relation, decided_by FROM dup_pair WHERE a_pk = ? AND b_pk = ?",
                               [.integer(lo), .integer(hi)]) { ($0.string(0), $0.optionalString(1), $0.string(2)) }
    }

    /// Pairs decided for any of `pks` (so a check never asks about them again): `dup_pair`
    /// decisions, and pairs whose review the user answered or dismissed (a skipped copy in
    /// Recently Deleted is not asked about again when its earlier paper is refreshed). Each
    /// pair is `[smaller pk, larger pk]`.
    package func decidedPairs(involving pks: [Int64]) throws -> Set<[Int64]> {
        guard !pks.isEmpty else { return [] }
        let rows = try db.query("""
            SELECT a_pk, b_pk FROM dup_pair WHERE a_pk IN (SELECT value FROM json_each(?1)) OR b_pk IN (SELECT value FROM json_each(?1))
            UNION
            SELECT min(new_paper_pk, existing_paper_pk), max(new_paper_pk, existing_paper_pk) FROM dup_review
             WHERE state IN ('resolved', 'dismissed') AND new_paper_pk IS NOT NULL AND existing_paper_pk IS NOT NULL
               AND (new_paper_pk IN (SELECT value FROM json_each(?1)) OR existing_paper_pk IN (SELECT value FROM json_each(?1)))
            """, [.text(Database.jsonArray(pks))]) { [$0.int64(0), $0.int64(1)] }
        return Set(rows)
    }

    package func setDupPair(_ a: Int64, _ b: Int64, decision: String, relation: String?, decidedBy: String, at date: Date) throws {
        guard a != b else { return }
        let (lo, hi) = a < b ? (a, b) : (b, a)
        try write {
            try db.run("""
                INSERT INTO dup_pair(a_pk, b_pk, decision, relation, decided_by, decided_at) VALUES(?, ?, ?, ?, ?, ?)
                ON CONFLICT(a_pk, b_pk) DO UPDATE SET decision = excluded.decision, relation = excluded.relation,
                  decided_by = excluded.decided_by, decided_at = excluded.decided_at
                """, [.integer(lo), .integer(hi), .text(decision), .string(relation), .text(decidedBy),
                      .text(Database.timestamp(date))])
        }
    }

    /// The papers `paperPK` has a `dup_pair` decision with, for its card: every partner's id, sorted
    /// (card.json `distinctFrom`), then a `CardSidecar.relatedPartnerEntry` for each pair kept
    /// linked as related (card.json `relatedTo`: a rebuild restores the relation, not "distinct").
    package func dupPairPartnerIDs(paperPK: Int64) throws -> [String] {
        let rows = try db.query("""
            SELECT p.id, d.decision, d.relation FROM dup_pair d
              JOIN paper p ON p.pk = (CASE WHEN d.a_pk = ?1 THEN d.b_pk ELSE d.a_pk END)
             WHERE d.a_pk = ?1 OR d.b_pk = ?1 ORDER BY p.id
            """, [.integer(paperPK)]) { ($0.string(0), $0.string(1), $0.optionalString(2)) }
        return rows.map(\.0)
            + rows.filter { $0.1 == "related" }.map { CardSidecar.relatedPartnerEntry(id: $0.0, relation: $0.2) }
    }

    package func removeDupPair(_ a: Int64, _ b: Int64) throws {
        let (lo, hi) = a < b ? (a, b) : (b, a)
        try write { try db.run("DELETE FROM dup_pair WHERE a_pk = ? AND b_pk = ?", [.integer(lo), .integer(hi)]) }
    }

    // MARK: - Merges (provenance and email rows follow the kept paper)

    /// Replaces a paper's provenance rows with `sources` (a merge's undo).
    package func replacePaperSources(paperPK: Int64, _ sources: [PaperProvenance]) throws {
        try write {
            try db.run("DELETE FROM paper_source WHERE paper_pk = ?", [.integer(paperPK)])
            for p in sources { try insertPaperSource(paperPK: paperPK, p) }
            note(.paper(pk: paperPK))
        }
    }

    /// Email rows that name `fromID` name `toID` instead; returns the rows' ids.
    @discardableResult
    package func repointMailItems(from fromID: String, to toID: String, only ids: [String]? = nil) throws -> [String] {
        try write {
            let rows = try db.query("SELECT id FROM mail_item WHERE paper_id = ?", [.text(fromID.lowercased())]) { $0.string(0) }
            let chosen = ids.map { wanted in rows.filter { wanted.contains($0) } } ?? rows
            for id in chosen {
                try db.run("UPDATE mail_item SET paper_id = ? WHERE id = ?", [.text(toID.lowercased()), .text(id)])
            }
            if !chosen.isEmpty { note(.mailBulk) }
            return chosen
        }
    }

    // MARK: - reading_cycle

    package func readingCycles(paperPK: Int64) throws -> [ReadingCycle] {
        try db.query("SELECT n, started_at, done_at, reason FROM reading_cycle WHERE paper_pk = ? ORDER BY n",
                     [.integer(paperPK)]) { s in
            ReadingCycle(n: s.int(0), startedAt: Database.date(fromTimestamp: s.string(1)) ?? .distantPast,
                         doneAt: s.optionalString(2).flatMap(Database.date(fromTimestamp:)), reason: s.optionalString(3))
        }
    }

    package func insertReadingCycle(paperPK: Int64, _ c: ReadingCycle) throws {
        try write {
            try db.run("""
                INSERT INTO reading_cycle(paper_pk, n, started_at, done_at, reason) VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(paper_pk, n) DO UPDATE SET started_at = excluded.started_at, done_at = excluded.done_at,
                  reason = excluded.reason
                """, [.integer(paperPK), .int(c.n), .text(Database.timestamp(c.startedAt)),
                      .string(c.doneAt.map(Database.timestamp)), .string(c.reason)])
        }
    }

    package func deleteReadingCycle(paperPK: Int64, n: Int) throws {
        try write { try db.run("DELETE FROM reading_cycle WHERE paper_pk = ? AND n = ?", [.integer(paperPK), .int(n)]) }
    }
}
