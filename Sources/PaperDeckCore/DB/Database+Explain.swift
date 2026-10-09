import Foundation

// `explanation` (the assist feature, SchemaAssist.swift; LN §7.6): one row per Explain turn. The
// paper is optional (`ON DELETE SET NULL`: deleting a paper keeps its explanations, unmatched).
// Same rules as the rest of `Database`: every write is one transaction, a matched paper's change
// goes out as `.paper(pk:)` after COMMIT. Privacy: excerpts and answers are only ever written here
// (truncated to `ExplanationRecord.maxExcerpt`), never logged.
extension Database {
    private static let explanationColumns = [
        "id", "paper_pk", "thread_id", "turn", "source", "action", "lang", "page", "match_via", "match_score",
        "excerpt", "question", "answer", "had_image", "thumb_path", "provider", "model", "duration_ms",
        "input_tokens", "output_tokens", "cost_usd", "pinned", "saved_to_notes_at", "created_at",
    ]
    private static let explanationInsert = "INSERT INTO explanation(" + explanationColumns.joined(separator: ", ")
        + ") VALUES(" + Array(repeating: "?", count: explanationColumns.count).joined(separator: ", ") + ")"
    /// The row with its paper's id (NULL when unmatched or the paper is gone).
    private static let explanationSelect = """
        SELECT e.id, p.id, e.thread_id, e.turn, e.source, e.action, e.lang, e.page, e.match_via, e.match_score,
          e.excerpt, e.question, e.answer, e.had_image, e.thumb_path, e.provider, e.model, e.duration_ms,
          e.input_tokens, e.output_tokens, e.cost_usd, e.pinned, e.saved_to_notes_at, e.created_at
        FROM explanation e LEFT JOIN paper p ON p.pk = e.paper_pk
        """

    /// Stores `r` (its `paperID` must name an existing paper; nil = unmatched). Returns the stored
    /// row. Throws `duplicate` for an id that exists, `notFound` for an unknown paper.
    @discardableResult
    package func insertExplanation(_ r: ExplanationRecord) throws -> ExplanationRecord {
        try write {
            let paperPK: Int64? = try r.paperID.map { id in
                guard let pk = try db.scalarInt("SELECT pk FROM paper WHERE id = ?", [.text(id)]) else {
                    throw DatabaseError.notFound("paper \(id)")
                }
                return pk
            }
            if (try db.scalarInt("SELECT count(*) FROM explanation WHERE id = ?", [.text(r.id)]) ?? 0) > 0 {
                throw DatabaseError.duplicate("explanation \(r.id)")
            }
            try db.run(Database.explanationInsert, Database.explanationValues(r, paperPK: paperPK))
            if let paperPK { note(.paper(pk: paperPK)) }
        }
        guard let stored = try explanation(id: r.id) else { throw DatabaseError.notFound("explanation \(r.id)") }
        return stored
    }

    package func explanation(id: String) throws -> ExplanationRecord? {
        try db.query(Database.explanationSelect + " WHERE e.id = ?", [.text(id)], Database.readExplanation).first
    }

    /// Newest first. `paperPK` nil: every explanation (matched or not).
    package func explanations(paperPK: Int64?, limit: Int) throws -> [ExplanationRecord] {
        guard limit > 0 else { return [] }
        let order = " ORDER BY e.created_at DESC, e.pk DESC LIMIT ?"
        if let paperPK {
            return try db.query(Database.explanationSelect + " WHERE e.paper_pk = ?" + order,
                                [.integer(paperPK), .integer(Int64(limit))], Database.readExplanation)
        }
        return try db.query(Database.explanationSelect + order, [.integer(Int64(limit))], Database.readExplanation)
    }

    /// The turns of one panel / thread, in order.
    package func explanations(threadID: String) throws -> [ExplanationRecord] {
        try db.query(Database.explanationSelect + " WHERE e.thread_id = ? ORDER BY e.turn, e.pk", [.text(threadID)],
                     Database.readExplanation)
    }

    /// Throws `notFound` for an unknown id.
    package func setExplanationPinned(id: String, _ pinned: Bool) throws {
        try updateExplanation(id: id, "UPDATE explanation SET pinned = ? WHERE id = ?", [.bool(pinned), .text(id)])
    }

    /// Records that the explanation went into its paper's notes (it is kept by every prune).
    package func markExplanationSaved(id: String, at date: Date) throws {
        try updateExplanation(id: id, "UPDATE explanation SET saved_to_notes_at = ? WHERE id = ?",
                              [.text(Database.timestamp(date)), .text(id)])
    }

    /// Removes explanations created before `date` that are neither pinned nor saved to notes.
    /// Returns how many.
    @discardableResult
    package func pruneExplanations(olderThan date: Date) throws -> Int {
        try write {
            let cutoff = SQLiteValue.text(Database.timestamp(date))
            let filter = "pinned = 0 AND saved_to_notes_at IS NULL AND created_at < ?"
            let pks = try db.query("SELECT DISTINCT paper_pk FROM explanation WHERE paper_pk IS NOT NULL AND " + filter,
                                   [cutoff]) { $0.int64(0) }
            try db.run("DELETE FROM explanation WHERE " + filter, [cutoff])
            let removed = db.changes
            if removed > 0 { for pk in pks { note(.paper(pk: pk)) } }
            return removed
        }
    }

    /// Removes one explanation (the history's delete). Throws `notFound` for an unknown id.
    package func deleteExplanation(id: String) throws {
        try write {
            guard let pk = try db.scalarInt("SELECT pk FROM explanation WHERE id = ?", [.text(id)]) else {
                throw DatabaseError.notFound("explanation \(id)")
            }
            let paperPK = try db.scalarInt("SELECT paper_pk FROM explanation WHERE pk = ?", [.integer(pk)])
            try db.run("DELETE FROM explanation WHERE pk = ?", [.integer(pk)])
            if let paperPK { note(.paper(pk: paperPK)) }
        }
    }

    /// Files the explanation under `paperPK` (the user picked the paper; nil unfiles it), with how it
    /// was matched. Both the old and the new paper hear of it. Throws `notFound` for an unknown id
    /// or paper.
    package func setExplanationPaper(id: String, paperPK: Int64?, via: MatchSource?, score: Double?) throws {
        try write {
            guard let pk = try db.scalarInt("SELECT pk FROM explanation WHERE id = ?", [.text(id)]) else {
                throw DatabaseError.notFound("explanation \(id)")
            }
            if let paperPK, try db.scalarInt("SELECT 1 FROM paper WHERE pk = ?", [.integer(paperPK)]) == nil {
                throw DatabaseError.notFound("paper \(paperPK)")
            }
            let old = try db.scalarInt("SELECT paper_pk FROM explanation WHERE pk = ?", [.integer(pk)])
            try db.run("UPDATE explanation SET paper_pk = ?, match_via = ?, match_score = ? WHERE pk = ?",
                       [.int64(paperPK), .string(via?.rawValue), .double(score), .integer(pk)])
            for p in Set([old, paperPK].compactMap { $0 }) { note(.paper(pk: p)) }
        }
    }

    // MARK: - Locating a capture's paper (Explain A3; LN §5)

    /// ≤ `limit` live papers whose full text matches `expr` (an `FTSQuery.anyOf` expression), best
    /// bm25 first. A malformed expression finds nothing (logged without the expression).
    package func fullTextCandidates(_ expr: String, limit: Int = 5) throws -> [Int64] {
        guard limit > 0, !expr.isEmpty else { return [] }
        do {
            return try db.query("""
                SELECT f.rowid FROM paper_fts_text f JOIN paper p ON p.pk = f.rowid
                 WHERE paper_fts_text MATCH ?1 AND p.deleted_at IS NULL
                 ORDER BY bm25(paper_fts_text) LIMIT ?2
                """, [.text(expr), .int(limit)]) { $0.int64(0) }
        } catch let e as SQLiteError {
            Log.db.error("explain text candidates failed: \(e.description, privacy: .public)")
            return []
        }
    }

    /// ≤ `limit` live papers whose title matches `expr` (an `FTSQuery.anyOf` expression), best bm25
    /// first.
    package func titleCandidates(_ expr: String, limit: Int = 10) throws -> [Int64] {
        guard limit > 0, !expr.isEmpty else { return [] }
        do {
            return try db.query("""
                SELECT f.rowid FROM paper_fts_meta f JOIN paper p ON p.pk = f.rowid
                 WHERE paper_fts_meta MATCH ?1 AND p.deleted_at IS NULL
                 ORDER BY bm25(paper_fts_meta, 10.0, 0.0, 0.0, 0.0, 0.0, 0.0) LIMIT ?2
                """, [.text("{title} : (" + expr + ")"), .int(limit)]) { $0.int64(0) }
        } catch let e as SQLiteError {
            Log.db.error("explain title candidates failed: \(e.description, privacy: .public)")
            return []
        }
    }

    /// Live papers whose PDF carries one of `names` — its canonical file name or the dropped file's
    /// original name — case-insensitively, oldest first.
    package func livePaperPKs(fileNames names: [String]) throws -> [Int64] {
        let wanted = Array(Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !wanted.isEmpty else { return [] }
        return try db.query("""
            SELECT pk FROM paper WHERE deleted_at IS NULL AND (
              pdf_name COLLATE NOCASE IN (SELECT value FROM json_each(?1))
              OR original_name COLLATE NOCASE IN (SELECT value FROM json_each(?1)))
            ORDER BY pk LIMIT 20
            """, [.text(try jsonStrings(wanted.sorted()))]) { $0.int64(0) }
    }

    private func updateExplanation(id: String, _ sql: String, _ values: [SQLiteValue]) throws {
        try write {
            guard let pk = try db.scalarInt("SELECT pk FROM explanation WHERE id = ?", [.text(id)]) else {
                throw DatabaseError.notFound("explanation \(id)")
            }
            try db.run(sql, values)
            if db.changes > 0, let paperPK = try db.scalarInt("SELECT paper_pk FROM explanation WHERE pk = ?", [.integer(pk)]) {
                note(.paper(pk: paperPK))
            }
        }
    }

    private static func explanationValues(_ r: ExplanationRecord, paperPK: Int64?) -> [SQLiteValue] {
        [.text(r.id), .int64(paperPK), .text(r.threadID), .int(r.turn), .text(r.source.rawValue), .text(r.action),
         .text(r.lang.rawValue), .int(r.page), .string(r.matchVia?.rawValue), .double(r.matchScore),
         .string(r.excerpt.map { String($0.prefix(ExplanationRecord.maxExcerpt)) }), .string(r.question), .text(r.answer),
         .bool(r.hadImage), .string(r.thumbPath), .text(r.meta.provider), .string(r.meta.model.isEmpty ? nil : r.meta.model),
         .int(r.meta.totalMs), .int(r.meta.inputTokens), .int(r.meta.outputTokens), .double(r.meta.costUSD),
         .bool(r.pinned), .string(r.savedToNotesAt.map(Database.timestamp)), .text(Database.timestamp(r.createdAt))]
    }

    private static func readExplanation(_ s: SQLiteStatement) -> ExplanationRecord {
        var c = Columns(s)
        let id = c.string(), paperID = c.optString(), threadID = c.string(), turn = c.int()
        let source = c.raw(ExplainSource.clipboard), action = c.string(), lang = c.raw(UILang.en)
        let page = c.optInt(), matchVia = c.optString().flatMap(PaperMatch.Via.init(rawValue:)), matchScore = c.optDouble()
        let excerpt = c.optString(), question = c.optString(), answer = c.string(), hadImage = c.bool()
        let thumbPath = c.optString(), provider = c.string(), model = c.optString(), duration = c.optInt()
        let inTokens = c.optInt(), outTokens = c.optInt(), cost = c.optDouble(), pinned = c.bool()
        let saved = c.optDate(), created = c.date()
        let meta = AssistMeta(provider: provider, model: model ?? "", warm: false, turnIndex: turn, ttftMs: nil,
                              totalMs: duration ?? 0, inputTokens: inTokens, outputTokens: outTokens, costUSD: cost)
        return ExplanationRecord(id: id, paperID: paperID, threadID: threadID, turn: turn, source: source, action: action,
                                 lang: lang, page: page, excerpt: excerpt, question: question, answer: answer,
                                 hadImage: hadImage, meta: meta, pinned: pinned, savedToNotesAt: saved, createdAt: created,
                                 matchVia: matchVia, matchScore: matchScore, thumbPath: thumbPath)
    }
}
