import Foundation

// Paper Q&A threads and messages (`qa_thread`, `qa_thread_paper`, `qa_message`; SchemaAssist.swift,
// DQ §8). Owned by Slice C. Every write is one transaction. Q&A writes post no library change: the
// Ask views are driven by `QAService`'s events, and a streaming answer must not refresh the library
// snapshot several times a second. Privacy: questions and answers are only ever written here (and
// to `qa.json` for papers whose verdict allows it), never logged.
extension Database {
    private static let qaThreadSelect = """
        SELECT t.pk, t.id, t.scope, t.title, t.lang, t.context_mode, t.created_at, t.updated_at, t.archived FROM qa_thread t
        """
    private static let qaMessageColumns = [
        "id", "thread_pk", "ord", "role", "text", "citations_json", "lang", "provider", "model", "depth", "context_json",
        "state", "error_kind", "duration_ms", "input_tokens", "output_tokens", "cost_usd", "created_at",
    ]
    private static let qaMessageSelect = """
        SELECT m.id, t.id, m.ord, m.role, m.text, m.citations_json, m.lang, m.provider, m.model, m.depth, m.context_json,
          m.state, m.error_kind, m.duration_ms, m.input_tokens, m.output_tokens, m.cost_usd, m.created_at
        FROM qa_message m JOIN qa_thread t ON t.pk = m.thread_pk
        """

    // MARK: Threads

    /// Stores `t` with its papers in order (`t.paperIDs`; each must exist). Throws `duplicate` for an
    /// id that exists, `notFound` for an unknown paper.
    @discardableResult
    package func insertQAThread(_ t: QAThread) throws -> QAThread {
        try write {
            if try db.scalarInt("SELECT pk FROM qa_thread WHERE id = ?", [.text(t.id)]) != nil {
                throw DatabaseError.duplicate("qa thread \(t.id)")
            }
            var pks: [Int64] = []
            for id in t.paperIDs {
                guard let pk = try db.scalarInt("SELECT pk FROM paper WHERE id = ?", [.text(id)]) else {
                    throw DatabaseError.notFound("paper \(id)")
                }
                pks.append(pk)
            }
            try db.run("""
                INSERT INTO qa_thread(id, scope, title, lang, context_mode, created_at, updated_at, archived)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                """, [.text(t.id), .text(t.scope.rawValue), .text(t.title), .text(t.language.rawValue), .text(t.mode.rawValue),
                      .text(Database.timestamp(t.createdAt)), .text(Database.timestamp(t.updatedAt)), .bool(t.archived)])
            let threadPK = db.lastInsertRowID
            for (ord, pk) in pks.enumerated() {
                try db.run("INSERT OR IGNORE INTO qa_thread_paper(thread_pk, paper_pk, ord) VALUES(?, ?, ?)",
                           [.integer(threadPK), .integer(pk), .integer(Int64(ord))])
            }
        }
        guard let stored = try qaThread(id: t.id) else { throw DatabaseError.notFound("qa thread \(t.id)") }
        return stored
    }

    package func qaThread(id: String) throws -> QAThread? {
        guard let row = try db.query(Database.qaThreadSelect + " WHERE t.id = ?", [.text(id)], Database.readQAThread).first
        else { return nil }
        return try withPapers(row)
    }

    /// The threads that include `paperID` (single-paper ones only for `scope: .paper`), most recently
    /// active first.
    package func qaThreads(paperID: String, scope: QAThread.Scope? = nil, includeArchived: Bool = false) throws -> [QAThread] {
        var sql = Database.qaThreadSelect + """
             JOIN qa_thread_paper tp ON tp.thread_pk = t.pk JOIN paper p ON p.pk = tp.paper_pk WHERE p.id = ?
            """
        var values: [SQLiteValue] = [.text(paperID)]
        if let scope { sql += " AND t.scope = ?"; values.append(.text(scope.rawValue)) }
        if !includeArchived { sql += " AND t.archived = 0" }
        sql += " ORDER BY t.updated_at DESC, t.pk DESC"
        return try db.query(sql, values, Database.readQAThread).map(withPapers)
    }

    /// The papers with single-paper threads (archived ones too): the papers a `qa.json` may sit beside.
    package func qaSidecarPapers() throws -> [(pk: Int64, id: String)] {
        try db.query("""
            SELECT DISTINCT p.pk, p.id FROM qa_thread t JOIN qa_thread_paper tp ON tp.thread_pk = t.pk
              JOIN paper p ON p.pk = tp.paper_pk WHERE t.scope = 'paper' ORDER BY p.pk
            """) { s in (pk: s.int64(0), id: s.string(1)) }
    }

    /// Adds `paperID` to a stored thread, after its other papers (nothing when it is there already).
    /// A thread whose papers were all hard-deleted is linked back this way when its paper's
    /// `qa.json` is read again (index rebuild). Throws `notFound` for an unknown thread or paper.
    package func linkQAThread(id: String, paperID: String) throws {
        try write {
            guard let threadPK = try db.scalarInt("SELECT pk FROM qa_thread WHERE id = ?", [.text(id)]) else {
                throw DatabaseError.notFound("qa thread \(id)")
            }
            guard let paperPK = try db.scalarInt("SELECT pk FROM paper WHERE id = ?", [.text(paperID.lowercased())]) else {
                throw DatabaseError.notFound("paper \(paperID)")
            }
            let ord = try db.scalarInt("SELECT coalesce(max(ord) + 1, 0) FROM qa_thread_paper WHERE thread_pk = ?",
                                       [.integer(threadPK)]) ?? 0
            try db.run("INSERT OR IGNORE INTO qa_thread_paper(thread_pk, paper_pk, ord) VALUES(?, ?, ?)",
                       [.integer(threadPK), .integer(paperPK), .integer(ord)])
        }
    }

    /// Title, language, context mode, archived flag and `updated_at` of a stored thread (nil: unchanged).
    package func updateQAThread(id: String, title: String? = nil, language: AssistSettings.AnswerLanguage? = nil,
                                mode: QAContextMode? = nil, archived: Bool? = nil, updatedAt: Date? = nil) throws {
        try write {
            guard let pk = try db.scalarInt("SELECT pk FROM qa_thread WHERE id = ?", [.text(id)]) else {
                throw DatabaseError.notFound("qa thread \(id)")
            }
            if let title { try db.run("UPDATE qa_thread SET title = ? WHERE pk = ?", [.text(title), .integer(pk)]) }
            if let language { try db.run("UPDATE qa_thread SET lang = ? WHERE pk = ?", [.text(language.rawValue), .integer(pk)]) }
            if let mode { try db.run("UPDATE qa_thread SET context_mode = ? WHERE pk = ?", [.text(mode.rawValue), .integer(pk)]) }
            if let archived { try db.run("UPDATE qa_thread SET archived = ? WHERE pk = ?", [.bool(archived), .integer(pk)]) }
            if let updatedAt {
                try db.run("UPDATE qa_thread SET updated_at = ? WHERE pk = ?", [.text(Database.timestamp(updatedAt)), .integer(pk)])
            }
        }
    }

    /// Removes a thread and its messages. Returns its paper ids (empty: it didn't exist).
    @discardableResult
    package func deleteQAThread(id: String) throws -> [String] {
        try write {
            guard let thread = try qaThread(id: id) else { return [] }
            try db.run("DELETE FROM qa_thread WHERE id = ?", [.text(id)])
            return thread.paperIDs
        }
    }

    // MARK: Messages

    /// Appends `m` to its thread (`ord` = the next position). Throws `notFound` for an unknown thread,
    /// `duplicate` for an id that exists.
    @discardableResult
    package func insertQAMessage(_ m: QAMessage) throws -> QAMessage {
        try write {
            guard let threadPK = try db.scalarInt("SELECT pk FROM qa_thread WHERE id = ?", [.text(m.threadID)]) else {
                throw DatabaseError.notFound("qa thread \(m.threadID)")
            }
            if try db.scalarInt("SELECT pk FROM qa_message WHERE id = ?", [.text(m.id)]) != nil {
                throw DatabaseError.duplicate("qa message \(m.id)")
            }
            let ord = try db.scalarInt("SELECT coalesce(max(ord) + 1, 0) FROM qa_message WHERE thread_pk = ?",
                                       [.integer(threadPK)]) ?? 0
            var stored = m
            stored.ord = Int(ord)
            try db.run("INSERT INTO qa_message(" + Database.qaMessageColumns.joined(separator: ", ") + ") VALUES("
                       + Array(repeating: "?", count: Database.qaMessageColumns.count).joined(separator: ", ") + ")",
                       Database.qaMessageValues(stored, threadPK: threadPK))
        }
        guard let stored = try qaMessage(id: m.id) else { throw DatabaseError.notFound("qa message \(m.id)") }
        return stored
    }

    /// Rewrites a stored message's content and state (text, citations, language, model, depth,
    /// context, state, error, timings). Throws `notFound` for an unknown id.
    package func updateQAMessage(_ m: QAMessage) throws {
        try write {
            guard try db.scalarInt("SELECT pk FROM qa_message WHERE id = ?", [.text(m.id)]) != nil else {
                throw DatabaseError.notFound("qa message \(m.id)")
            }
            try db.run("""
                UPDATE qa_message SET text = ?, citations_json = ?, lang = ?, provider = ?, model = ?, depth = ?,
                  context_json = ?, state = ?, error_kind = ?, duration_ms = ?, input_tokens = ?, output_tokens = ?, cost_usd = ?
                WHERE id = ?
                """, Array(Database.qaMessageValues(m, threadPK: 0)[4...16]) + [.text(m.id)])
        }
    }

    /// Only the text of a message still streaming (the periodic save of a partial answer).
    package func updateQAMessageText(id: String, text: String) throws {
        try write {
            try db.run("UPDATE qa_message SET text = ? WHERE id = ? AND state = 'streaming'", [.text(text), .text(id)])
        }
    }

    package func qaMessage(id: String) throws -> QAMessage? {
        try db.query(Database.qaMessageSelect + " WHERE m.id = ?", [.text(id)], Database.readQAMessage).first
    }

    /// The thread's messages in order.
    package func qaMessages(threadID: String) throws -> [QAMessage] {
        try db.query(Database.qaMessageSelect + " WHERE t.id = ? ORDER BY m.ord, m.pk", [.text(threadID)], Database.readQAMessage)
    }

    /// Removes one message. Returns its thread's id (nil: no such message).
    @discardableResult
    package func deleteQAMessage(id: String) throws -> String? {
        try write {
            guard let m = try qaMessage(id: id) else { return nil }
            try db.run("DELETE FROM qa_message WHERE id = ?", [.text(id)])
            return m.threadID
        }
    }

    /// Launch recovery: answers left `streaming` by a crash or a quit become `cancelled` (their saved
    /// partial text stays, shown as stopped), and threads whose papers are all gone are removed.
    @discardableResult
    package func recoverQA() throws -> (cancelled: Int, orphanThreads: Int) {
        try write {
            try db.run("UPDATE qa_message SET state = 'cancelled', error_kind = coalesce(error_kind, 'interrupted') WHERE state = 'streaming'")
            let cancelled = db.changes
            try db.run("DELETE FROM qa_thread WHERE pk NOT IN (SELECT thread_pk FROM qa_thread_paper)")
            return (cancelled, db.changes)
        }
    }

    /// Durations (ms) of the latest finished answers on `provider` at `depth`, newest first (the
    /// depth, not the model: a CLI reports its own model name, e.g. `claude-haiku-4-5` for `haiku`).
    package func qaRecentDurations(provider: String, depth: AssistSettings.Depth, limit: Int = 20) throws -> [Int] {
        try db.query("""
            SELECT duration_ms FROM qa_message WHERE role = 'assistant' AND state = 'done' AND provider = ? AND depth = ?
              AND duration_ms IS NOT NULL ORDER BY created_at DESC, pk DESC LIMIT ?
            """, [.text(provider), .text(depth.rawValue), .integer(Int64(max(0, limit)))]) { $0.int(0) }
    }

    // MARK: Rows

    private func withPapers(_ row: (pk: Int64, thread: QAThread)) throws -> QAThread {
        var t = row.thread
        t.paperIDs = try db.query("""
            SELECT p.id FROM qa_thread_paper tp JOIN paper p ON p.pk = tp.paper_pk WHERE tp.thread_pk = ? ORDER BY tp.ord
            """, [.integer(row.pk)]) { $0.string(0) }
        return t
    }

    private static func readQAThread(_ s: SQLiteStatement) -> (pk: Int64, thread: QAThread) {
        var c = Columns(s)
        let pk = c.int64(), id = c.string(), scope = c.raw(QAThread.Scope.paper), title = c.string()
        let lang = c.raw(AssistSettings.AnswerLanguage.auto), mode = c.optString().flatMap(QAContextMode.init(rawValue:))
        let created = c.date(), updated = c.date(), archived = c.bool()
        var t = QAThread(id: id, paperIDs: [], title: title, mode: mode ?? .fullText, createdAt: created, archived: archived,
                         language: lang, persisted: true)
        t.scope = scope
        t.updatedAt = updated
        return (pk, t)
    }

    private static func qaMessageValues(_ m: QAMessage, threadPK: Int64) -> [SQLiteValue] {
        [.text(m.id), .integer(threadPK), .int(m.ord), .text(m.role.rawValue), .text(m.text),
         .string(m.citations.isEmpty ? nil : json(m.citations)), .string(m.language), .string(m.meta?.provider),
         .string(m.meta.flatMap { $0.model.isEmpty ? nil : $0.model }), .string(m.depth?.rawValue),
         .string(m.context.flatMap(json)), .text(m.state.rawValue), .string(m.errorKind),
         .int(m.meta.map(\.totalMs)), .int(m.meta?.inputTokens), .int(m.meta?.outputTokens), .double(m.meta?.costUSD),
         .text(Database.timestamp(m.createdAt))]
    }

    private static func readQAMessage(_ s: SQLiteStatement) -> QAMessage {
        var c = Columns(s)
        let id = c.string(), threadID = c.string(), ord = c.int(), role = c.raw(AssistTurnText.Role.user), text = c.string()
        let citations = c.optString().flatMap { decode([QACitation].self, $0) } ?? []
        let lang = c.optString(), provider = c.optString(), model = c.optString()
        let depth = c.optString().flatMap(AssistSettings.Depth.init(rawValue:))
        let context = c.optString().flatMap { decode(QAContextStats.self, $0) }
        let state = c.raw(QAMessage.State.done), errorKind = c.optString(), duration = c.optInt()
        let inTokens = c.optInt(), outTokens = c.optInt(), cost = c.optDouble(), created = c.date()
        let meta = provider.map {
            AssistMeta(provider: $0, model: model ?? "", totalMs: duration ?? 0, inputTokens: inTokens,
                       outputTokens: outTokens, costUSD: cost)
        }
        return QAMessage(id: id, threadID: threadID, role: role, text: text, state: state, meta: meta, createdAt: created,
                         citations: citations, language: lang, depth: depth, errorKind: errorKind, context: context, ord: ord)
    }

    private static func json<T: Encodable>(_ value: T) -> String? {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ s: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(s.utf8))
    }
}
