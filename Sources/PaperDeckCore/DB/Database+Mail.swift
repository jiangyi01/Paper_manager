import Foundation

// Mail tables (migration 2): `mail_message`, `mail_item`, `paper_source`, plus the per-account
// sync cursors in `kv`. Same rules as the rest of `Database`: every write is one
// transaction (helpers called inside `transaction {}` join it), change notifications go out
// after the outer COMMIT (`.mail(pk:)`, bursts coalesce into `.mailBulk`), reads return the
// stored rows (instants normalized to the millisecond).
//
// Privacy: message bodies and snippets are only ever written here, never logged. Once a
// message is purged (`bodyPurged`) the flag is sticky — a stale copy written back later
// cannot resurrect the body.

extension Database {
    // MARK: - Messages

    private static let mailColumns = [
        "id", "account_id", "source_ref", "internet_message_id", "from_address", "from_name", "rule_id",
        "sender_kind", "auth_state", "subject", "received_at", "web_link", "snippet", "body_text", "body_purged",
        "state", "user_touched", "snoozed_until", "triage_state", "triage_source", "triage_json",
        "triage_attempt", "triage_not_before", "triage_error", "triage_provider", "triage_model", "triage_ms",
        "triage_in_tokens", "triage_out_tokens", "triage_stdin_bytes", "seen", "created_at", "updated_at",
        "handled_at", "triage_consented", "triage_consent_provider", "is_bulk", "confidential",
    ]
    private static let mailSelect = "SELECT pk, " + mailColumns.joined(separator: ", ") + " FROM mail_message"
    private static let mailInsert = "INSERT INTO mail_message(" + mailColumns.joined(separator: ", ") + ") VALUES("
        + Array(repeating: "?", count: mailColumns.count).joined(separator: ", ") + ")"
    /// Positional parameters ?1…?n follow `mailColumns`; ?(n+1) is the pk. Purging is sticky:
    /// the right-hand sides see the OLD row, so a purged row keeps NULL body/snippet. So is the
    /// capture-time `confidential` verdict: once 1 it stays, and a copy without one (nil) keeps
    /// the stored value.
    private static let mailUpdate: String = {
        let n = mailColumns.count
        let purged = "?\(mailColumns.firstIndex(of: "body_purged")! + 1)"
        let sets = mailColumns.enumerated().map { i, col -> String in
            switch col {
            case "body_purged": return "body_purged = MAX(body_purged, \(purged))"
            case "confidential":
                return "confidential = CASE WHEN ?\(i + 1) IS NULL OR confidential = 1 THEN confidential ELSE ?\(i + 1) END"
            case "body_text", "snippet":
                return "\(col) = CASE WHEN body_purged = 1 OR \(purged) = 1 THEN NULL ELSE ?\(i + 1) END"
            default: return "\(col) = ?\(i + 1)"
            }
        }
        return "UPDATE mail_message SET " + sets.joined(separator: ", ") + " WHERE pk = ?\(n + 1)"
    }()

    /// Inserts a captured email and its candidate papers in one transaction. `pk`s are
    /// assigned (the given ones are ignored) and every item gets the new `messagePK`.
    /// Throws `DatabaseError.duplicate("mail message <existing pk>")` when a message with the
    /// same Message-ID (compared case-insensitively) exists — callers can pre-check with
    /// `mailMessage(internetMessageID:)`. (Errors never carry mail content or addresses.)
    /// Returns the stored message and items (items in the given order).
    @discardableResult
    package func insertMailMessage(_ m: MailMessage, items: [MailItem]) throws -> (MailMessage, [MailItem]) {
        let (pk, itemPKs) = try write { () throws -> (Int64, [Int64]) in
            if let existing = try db.scalarInt("SELECT pk FROM mail_message WHERE internet_message_id = ?",
                                               [.text(Database.messageKey(m.internetMessageID))]) {
                throw DatabaseError.duplicate("mail message \(existing)")
            }
            try db.run(Database.mailInsert, try mailValues(m))
            let pk = db.lastInsertRowID
            var itemPKs: [Int64] = []
            for item in items {
                var row = item
                row.messagePK = pk
                try db.run(Database.mailItemInsert, try mailItemValues(row))
                itemPKs.append(db.lastInsertRowID)
            }
            note(.mail(pk: pk))
            return (pk, itemPKs)
        }
        let byPK = Dictionary(try mailItems(messagePK: pk).map { ($0.pk, $0) }, uniquingKeysWith: { a, _ in a })
        return (try requireMailMessage(pk), itemPKs.compactMap { byPK[$0] })
    }

    package func mailMessage(pk: Int64) throws -> MailMessage? {
        try db.queryOne(Database.mailSelect + " WHERE pk = ?", [.integer(pk)]) { try readMailMessage($0) }
    }

    /// By the uuid used in `paperdeck://mail/<id>` (case-insensitive input).
    package func mailMessage(id: String) throws -> MailMessage? {
        try db.queryOne(Database.mailSelect + " WHERE id = ?", [.text(id.lowercased())]) { try readMailMessage($0) }
    }

    /// Dedupe pre-check (the column compares case-insensitively).
    package func mailMessage(internetMessageID: String) throws -> MailMessage? {
        let key = Database.messageKey(internetMessageID)
        guard !key.isEmpty else { return nil }
        return try db.queryOne(Database.mailSelect + " WHERE internet_message_id = ?", [.text(key)]) {
            try readMailMessage($0)
        }
    }

    /// Messages in any of `states`, newest received first.
    package func mailMessages(states: Set<MailState>, limit: Int) throws -> [MailMessage] {
        guard !states.isEmpty, limit > 0 else { return [] }
        return try db.query(Database.mailSelect + """
             WHERE state IN (SELECT value FROM json_each(?1)) ORDER BY received_at DESC, pk DESC LIMIT ?2
            """, [.text(try jsonStrings(states.map(\.rawValue).sorted())), .int(limit)]) { try readMailMessage($0) }
    }

    /// `mailSelect` without the body: `body_text` reads as NULL and a last column says whether
    /// the stored row has one (list views never load or compare bodies).
    private static let mailHeadSelect = "SELECT pk, "
        + mailColumns.map { $0 == "body_text" ? "NULL" : $0 }.joined(separator: ", ")
        + ", (body_text IS NOT NULL AND body_text <> '') FROM mail_message"

    /// `mailMessages(states:limit:)` without the bodies (`bodyText` nil) — the inbox snapshot.
    /// `hasBody`: the stored message has a body (`mailMessage(id:)` returns it), as opposed to
    /// an empty or purged one.
    package func mailMessageHeads(states: Set<MailState>, limit: Int) throws -> [(message: MailMessage, hasBody: Bool)] {
        guard !states.isEmpty, limit > 0 else { return [] }
        let flag = Int32(1 + Database.mailColumns.count)
        return try db.query(Database.mailHeadSelect + """
             WHERE state IN (SELECT value FROM json_each(?1)) ORDER BY received_at DESC, pk DESC LIMIT ?2
            """, [.text(try jsonStrings(states.map(\.rawValue).sorted())), .int(limit)]) {
            (try readMailMessage($0), $0.bool(flag))
        }
    }

    /// Messages whose AI triage is in any of `states` (queue recovery at launch), in run order:
    /// earliest `triage_not_before` (none first), then oldest received.
    package func mailMessages(triageStates states: Set<MailTriageState>, limit: Int) throws -> [MailMessage] {
        guard !states.isEmpty, limit > 0 else { return [] }
        return try db.query(Database.mailSelect + """
             WHERE triage_state IN (SELECT value FROM json_each(?1))
             ORDER BY triage_not_before IS NOT NULL, triage_not_before, received_at, pk LIMIT ?2
            """, [.text(try jsonStrings(states.map(\.rawValue).sorted())), .int(limit)]) { try readMailMessage($0) }
    }

    /// Rewrites the whole row by `pk` and sets `updated_at = now`. Throws `.notFound` for an
    /// unknown pk and `.duplicate` when the new Message-ID belongs to another message.
    /// Prefer `modifyMailMessage` for read-modify-write around an `await`.
    @discardableResult
    package func updateMailMessage(_ m: MailMessage, now: Date = Date()) throws -> MailMessage {
        try write {
            if let existing = try db.scalarInt("SELECT pk FROM mail_message WHERE internet_message_id = ? AND pk <> ?",
                                               [.text(Database.messageKey(m.internetMessageID)), .integer(m.pk)]) {
                throw DatabaseError.duplicate("mail message \(existing)")
            }
            var row = m
            row.updatedAt = now
            try db.run(Database.mailUpdate, try mailValues(row) + [.integer(m.pk)])
            guard db.changes == 1 else { throw DatabaseError.notFound("mail message \(m.pk)") }
            note(.mail(pk: m.pk))
        }
        return try requireMailMessage(m.pk)
    }

    /// Atomic read-modify-write on the current row (use this, not `updateMailMessage` with a
    /// copy read before an `await`, so user actions made meanwhile are never overwritten).
    @discardableResult
    package func modifyMailMessage(pk: Int64, now: Date = Date(),
                                   _ body: @Sendable (inout MailMessage) throws -> Void) throws -> MailMessage {
        try write {
            var m = try requireMailMessage(pk)
            try body(&m)
            m.pk = pk
            return try updateMailMessage(m, now: now)
        }
    }

    /// Startup recovery for the triage lane: `running` → `queued`. Returns the count.
    @discardableResult
    package func resetRunningTriageToQueued(now: Date = Date()) throws -> Int {
        try write {
            try db.run("UPDATE mail_message SET triage_state = 'queued', updated_at = ? WHERE triage_state = 'running'",
                       [.text(Database.timestamp(now))])
            let n = db.changes
            if n > 0 { note(.mailBulk) }
            return n
        }
    }

    /// Snoozed messages whose `snoozed_until` has passed go back to `pending`. Returns the count.
    @discardableResult
    package func wakeSnoozedMail(now: Date = Date()) throws -> Int {
        try write {
            let ts = Database.timestamp(now)
            try db.run("""
                UPDATE mail_message SET state = 'pending', snoozed_until = NULL, updated_at = ?1
                WHERE state = 'snoozed' AND snoozed_until IS NOT NULL AND snoozed_until <= ?1
                """, [.text(ts)])
            let n = db.changes
            if n > 0 { note(.mailBulk) }
            return n
        }
    }

    /// Inbox badge numbers: `pending` = messages in 待处理; `requests` = those from a person or
    /// advisor whose triage found a reading request.
    package func mailCounts() throws -> (pending: Int, requests: Int) {
        try db.queryOne("""
            SELECT COUNT(*), COALESCE(SUM(sender_kind IN ('advisor', 'person') AND
              CASE WHEN json_valid(triage_json) THEN json_extract(triage_json, '$.hasReadingRequest') = 1 ELSE 0 END), 0)
            FROM mail_message WHERE state = 'pending'
            """) { (pending: $0.int(0), requests: $0.int(1)) } ?? (pending: 0, requests: 0)
    }

    /// Retention: clears `body_text` and `snippet` (and sets `bodyPurged`) of handled messages —
    /// not pending/snoozed — whose `handled_at` (or, when unset, `updated_at`) is before
    /// `handledBefore`. Subject, sender, link, triage and items stay for provenance.
    /// Returns the number of messages purged.
    @discardableResult
    package func purgeMailBodies(handledBefore cutoff: Date, now: Date = Date()) throws -> Int {
        try write {
            try db.run("""
                UPDATE mail_message SET body_text = NULL, snippet = NULL, body_purged = 1, updated_at = ?1
                WHERE state NOT IN ('pending', 'snoozed') AND COALESCE(handled_at, updated_at) < ?2
                  AND (body_purged = 0 OR body_text IS NOT NULL OR snippet IS NOT NULL)
                """, [.text(Database.timestamp(now)), .text(Database.timestamp(cutoff))])
            let n = db.changes
            if n > 0 {
                note(.mailBulk)
                Log.db.info("Purged the bodies of \(n) handled emails")
            }
            return n
        }
    }

    /// 「清除所有邮件数据」: every message and item plus the per-account sync cursors. Library
    /// provenance (`paper_source`) stays — it belongs to the papers and is mirrored in card.json.
    /// Files under `AppPaths.mailFiles` are the caller's to remove.
    package func deleteAllMailData() throws {
        try write {
            try db.run("DELETE FROM mail_item")
            var changed = db.changes > 0
            try db.run("DELETE FROM mail_message")
            changed = changed || db.changes > 0
            // Cursors and the sync's per-account / per-message bookkeeping (retry records, skipped
            // counts, the post-processing marker `mail.cursor.~postprocess`, which names pks that
            // are gone now — and pks are reused once the table is empty).
            try db.run("DELETE FROM kv WHERE key GLOB ?", [.text(Database.mailCursorPrefix + "*")])
            changed = changed || db.changes > 0
            if changed { note(.mailBulk) }
        }
    }

    /// The stored form of a Message-ID (surrounding whitespace dropped; the column itself
    /// compares case-insensitively).
    private static func messageKey(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func requireMailMessage(_ pk: Int64) throws -> MailMessage {
        guard let m = try mailMessage(pk: pk) else { throw DatabaseError.notFound("mail message \(pk)") }
        return m
    }

    private func touchMailMessage(_ pk: Int64, now: Date) throws {
        try db.run("UPDATE mail_message SET updated_at = ? WHERE pk = ?", [.text(Database.timestamp(now)), .integer(pk)])
    }

    private func mailValues(_ m: MailMessage) throws -> [SQLiteValue] {
        let triage = try m.triage.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        let values: [SQLiteValue] = [
            .text(m.id.lowercased()), .text(m.accountID), .string(m.sourceRef),
            .text(Database.messageKey(m.internetMessageID)),
            .text(m.fromAddress), .string(m.fromName), .string(m.ruleID),
            .text(m.senderKind.rawValue), .text(m.authState.rawValue), .text(m.subject),
            .text(Database.timestamp(m.receivedAt)), .string(m.webLink),
            .string(m.bodyPurged ? nil : m.snippet), .string(m.bodyPurged ? nil : m.bodyText), .bool(m.bodyPurged),
            .text(m.state.rawValue), .bool(m.userTouched), .string(m.snoozedUntil.map(Database.timestamp)),
            .text(m.triageState.rawValue), .string(m.triageSource?.rawValue), .string(triage),
            .int(m.triageAttempt), .string(m.triageNotBefore.map(Database.timestamp)), .string(m.triageError),
            .string(m.triageProvider), .string(m.triageModel), .int(m.triageMs),
            .int(m.triageInputTokens), .int(m.triageOutputTokens), .int(m.triageStdinBytes),
            .bool(m.seen), .text(Database.timestamp(m.createdAt)), .text(Database.timestamp(m.updatedAt)),
            .string(m.handledAt.map(Database.timestamp)), .bool(m.triageConsented), .string(m.triageConsentProvider),
            .int(m.isBulk.map { $0 ? 1 : 0 }), .int(m.confidential.map { $0 ? 1 : 0 }),
        ]
        assert(values.count == Database.mailColumns.count)
        return values
    }

    /// Column order = `mailSelect`. Unknown enum strings fall back to defaults; an
    /// undecodable `triage_json` reads as nil (logged) rather than failing the row.
    private func readMailMessage(_ s: SQLiteStatement) throws -> MailMessage {
        var c = Columns(s)
        let pk = c.int64()
        let id = c.string(), accountID = c.string(), sourceRef = c.optString(), messageID = c.string()
        let fromAddress = c.string(), fromName = c.optString(), ruleID = c.optString()
        let senderKind = c.raw(SenderKind.person), authState = c.raw(MailAuthState.unknown)
        let subject = c.string(), receivedAt = c.date(), webLink = c.optString()
        let snippet = c.optString(), bodyText = c.optString(), bodyPurged = c.bool()
        let state = c.raw(MailState.pending), userTouched = c.bool(), snoozedUntil = c.optDate()
        let triageState = c.raw(MailTriageState.none)
        let triageSource = c.optString().flatMap(MailTriageSource.init(rawValue:))
        let triageJSON = c.optString()
        let attempt = c.int(), notBefore = c.optDate(), error = c.optString()
        let provider = c.optString(), model = c.optString(), ms = c.optInt()
        let inTokens = c.optInt(), outTokens = c.optInt(), stdinBytes = c.optInt()
        let seen = c.bool(), createdAt = c.date(), updatedAt = c.date(), handledAt = c.optDate()
        let consented = c.bool(), consentProvider = c.optString()
        let isBulk = c.optInt().map { $0 != 0 }
        let confidential = c.optInt().map { $0 != 0 }

        var triage: MailTriage?
        if let triageJSON {
            triage = try? decoder.decode(MailTriage.self, from: Data(triageJSON.utf8))
            if triage == nil { Log.db.error("Undecodable triage_json for mail message \(pk)") }
        }
        return MailMessage(
            pk: pk, id: id, accountID: accountID, sourceRef: sourceRef, internetMessageID: messageID,
            fromAddress: fromAddress, fromName: fromName, ruleID: ruleID, senderKind: senderKind,
            authState: authState, subject: subject, receivedAt: receivedAt, webLink: webLink, snippet: snippet,
            bodyText: bodyText, bodyPurged: bodyPurged, state: state, userTouched: userTouched,
            snoozedUntil: snoozedUntil, triageState: triageState, triageSource: triageSource, triage: triage,
            triageAttempt: attempt, triageNotBefore: notBefore, triageError: error, triageProvider: provider,
            triageModel: model, triageMs: ms, triageInputTokens: inTokens, triageOutputTokens: outTokens,
            triageStdinBytes: stdinBytes, seen: seen, createdAt: createdAt, updatedAt: updatedAt,
            handledAt: handledAt, triageConsented: consented, triageConsentProvider: consentProvider, isBulk: isBulk,
            confidential: confidential)
    }

    // MARK: - Items

    private static let mailItemColumns = [
        "id", "message_pk", "ord", "cand", "origin", "found_by", "title", "authors_json", "venue", "year",
        "doi", "published_doi", "arxiv_id", "arxiv_version", "pii", "url", "url_original", "host", "meta_source",
        "relevance", "why", "confidence", "pdf_state", "pdf_path", "pdf_sha256", "pdf_bytes", "download_error",
        "paper_id", "status", "created_at", "updated_at",
        "origin_ext", "pdf_state_ext", "document_name", "document_kind", "document_path", "document_sha256", "share_host",
    ]
    private static let mailItemSelect = "SELECT pk, " + mailItemColumns.joined(separator: ", ") + " FROM mail_item"
    private static let mailItemInsert = "INSERT INTO mail_item(" + mailItemColumns.joined(separator: ", ") + ") VALUES("
        + Array(repeating: "?", count: mailItemColumns.count).joined(separator: ", ") + ")"
    /// Insert, or update everything but `created_at` of the row with the same id.
    private static let mailItemUpsert = mailItemInsert + " ON CONFLICT(id) DO UPDATE SET "
        + mailItemColumns.filter { $0 != "id" && $0 != "created_at" }.map { "\($0) = excluded.\($0)" }
            .joined(separator: ", ")
    private static let itemOrder = " ORDER BY message_pk, ord, pk"

    /// Items of one message in display order.
    package func mailItems(messagePK: Int64) throws -> [MailItem] {
        try db.query(Database.mailItemSelect + " WHERE message_pk = ? ORDER BY ord, pk", [.integer(messagePK)]) {
            try readMailItem($0)
        }
    }

    /// Batch form of `mailItems(messagePK:)`; every requested pk is a key.
    package func mailItems(messagePKs: [Int64]) throws -> [Int64: [MailItem]] {
        var out = Dictionary(messagePKs.map { ($0, [MailItem]()) }, uniquingKeysWith: { a, _ in a })
        guard !messagePKs.isEmpty else { return out }
        let rows = try db.query(Database.mailItemSelect + " WHERE message_pk IN (SELECT value FROM json_each(?))"
                                + Database.itemOrder, [.text(Database.jsonArray(messagePKs))]) { try readMailItem($0) }
        for item in rows { out[item.messagePK, default: []].append(item) }
        return out
    }

    package func mailItem(id: String) throws -> MailItem? {
        try db.queryOne(Database.mailItemSelect + " WHERE id = ?", [.text(id.lowercased())]) { try readMailItem($0) }
    }

    /// Insert or update by item id (its `pk` is ignored) and set `updated_at = now`; the
    /// owning message is touched too. Throws a foreign-key violation for an unknown `messagePK`.
    @discardableResult
    package func upsertMailItem(_ item: MailItem, now: Date = Date()) throws -> MailItem {
        try write {
            let previous = try db.scalarInt("SELECT message_pk FROM mail_item WHERE id = ?", [.text(item.id.lowercased())])
            var row = item
            row.updatedAt = now
            try db.run(Database.mailItemUpsert, try mailItemValues(row))
            for pk in Set([previous, item.messagePK].compactMap { $0 }) {
                try touchMailMessage(pk, now: now)
                note(.mail(pk: pk))
            }
        }
        guard let saved = try mailItem(id: item.id) else { throw DatabaseError.notFound("mail item \(item.id)") }
        return saved
    }

    /// Idempotent.
    package func deleteMailItem(id: String, now: Date = Date()) throws {
        try write {
            let key = id.lowercased()
            guard let messagePK = try db.scalarInt("SELECT message_pk FROM mail_item WHERE id = ?", [.text(key)]) else {
                return
            }
            try db.run("DELETE FROM mail_item WHERE id = ?", [.text(key)])
            try touchMailMessage(messagePK, now: now)
            note(.mail(pk: messagePK))
        }
    }

    /// Pending items still waiting for a PDF (`needs_pdf` or `downloadable`) — what an
    /// anywhere-drop or a finished import may satisfy.
    package func openMailItemsNeedingPDF() throws -> [MailItem] {
        try db.query(Database.mailItemSelect + """
             WHERE status = 'pending' AND pdf_state IN ('needs_pdf', 'downloadable')
            """ + Database.itemOrder) { try readMailItem($0) }
    }

    /// Pending items naming the same work as `doi` (case-insensitive, both bioRxiv prefixes,
    /// also via an item's `published_doi`).
    package func mailItems(doi: String) throws -> [MailItem] {
        let dois = Database.sameWorkDOIs(doi)
        guard !dois.isEmpty else { return [] }
        return try db.query(Database.mailItemSelect + """
             WHERE status = 'pending' AND (doi IN (SELECT value FROM json_each(?1))
               OR published_doi IN (SELECT value FROM json_each(?1)))
            """ + Database.itemOrder, [.text(try jsonStrings(dois))]) { try readMailItem($0) }
    }

    /// Pending items with this arXiv base id (case-insensitive; a trailing `vN` is ignored).
    package func mailItems(arxivID: String) throws -> [MailItem] {
        guard var id = Database.clean(arxivID) else { return [] }
        if let v = id.range(of: #"(?<=\d)v\d+$"#, options: .regularExpression) { id.removeSubrange(v) }
        return try db.query(Database.mailItemSelect + " WHERE status = 'pending' AND arxiv_id = ?" + Database.itemOrder,
                            [.text(id)]) { try readMailItem($0) }
    }

    /// The origin / PDF state go to the frozen CHECK columns as their `storedBase` (what an older
    /// build reads: an attachment / link waiting for a PDF); the exact value of a newer case
    /// (`document`, `share_link`, `convertible`, `open_only`) goes to `origin_ext` / `pdf_state_ext`.
    /// Rows (any status) whose stored document original had these bytes (`document_sha256`) —
    /// a document converted before links to that paper instead of converting again.
    package func mailItems(documentSHA256 sha: String) throws -> [MailItem] {
        guard let key = Database.clean(sha)?.lowercased() else { return [] }
        return try db.query(Database.mailItemSelect + " WHERE lower(document_sha256) = ?" + Database.itemOrder, [.text(key)]) {
            try readMailItem($0)
        }
    }

    private func mailItemValues(_ i: MailItem) throws -> [SQLiteValue] {
        let authors = String(decoding: try encoder.encode(i.authors), as: UTF8.self)
        let originExt = i.origin.storedBase != i.origin ? i.origin.rawValue : nil
        let pdfStateExt = i.pdfState.storedBase != i.pdfState ? i.pdfState.rawValue : nil
        let values: [SQLiteValue] = [
            .text(i.id.lowercased()), .integer(i.messagePK), .int(i.ord), .text(i.cand),
            .text(i.origin.storedBase.rawValue), .text(i.foundBy.rawValue), .string(i.title), .text(authors),
            .string(i.venue), .int(i.year),
            .string(Database.clean(i.ids.doi)), .string(Database.clean(i.ids.publishedDOI)),
            .string(Database.clean(i.ids.arxivID)), .int(i.ids.arxivVersion), .string(Database.clean(i.ids.pii)),
            .string(i.url), .string(i.urlOriginal), .string(i.host), .text(i.metaSource.rawValue),
            .string(i.relevance?.rawValue), .string(i.why), .double(i.confidence),
            .text(i.pdfState.storedBase.rawValue), .string(i.pdfPath), .string(i.pdfSHA256), .int64(i.pdfBytes),
            .string(i.downloadError), .string(i.paperID), .text(i.status.rawValue),
            .text(Database.timestamp(i.createdAt)), .text(Database.timestamp(i.updatedAt)),
            .string(originExt), .string(pdfStateExt), .string(i.documentFileName), .string(i.documentKind),
            .string(i.documentPath), .string(i.documentSHA256), .string(i.shareHost),
        ]
        assert(values.count == Database.mailItemColumns.count)
        return values
    }

    /// Column order = `mailItemSelect`. An `origin_ext` / `pdf_state_ext` value applies only while
    /// the base column still holds its `storedBase` — an older build that changed the row (a PDF
    /// dropped on a document row → `has_pdf`) wins over the stale extension.
    private func readMailItem(_ s: SQLiteStatement) throws -> MailItem {
        var c = Columns(s)
        let pk = c.int64()
        let id = c.string(), messagePK = c.int64(), ord = c.int(), cand = c.string()
        let origin = c.raw(MailItemOrigin.link), foundBy = c.raw(MailItemFoundBy.local)
        let title = c.optString(), authorsJSON = c.string()
        let authors = (try? decoder.decode([String].self, from: Data(authorsJSON.utf8))) ?? []
        let venue = c.optString(), year = c.optInt()
        let doi = c.optString(), publishedDOI = c.optString(), arxivID = c.optString()
        let arxivVersion = c.optInt(), pii = c.optString()
        let url = c.optString(), urlOriginal = c.optString(), host = c.optString()
        let metaSource = c.raw(MetaSource.none)
        let relevance = c.optString().flatMap(MailItemRelevance.init(rawValue:))
        let why = c.optString(), confidence = c.optDouble()
        let pdfState = c.raw(MailPDFState.unknown), pdfPath = c.optString(), pdfSHA256 = c.optString()
        let pdfBytes = c.optInt64(), downloadError = c.optString(), paperID = c.optString()
        let status = c.raw(MailItemStatus.pending), createdAt = c.date(), updatedAt = c.date()
        let originExt = c.optString().flatMap(MailItemOrigin.init(rawValue:))
        let pdfStateExt = c.optString().flatMap(MailPDFState.init(rawValue:))
        let documentName = c.optString(), documentKind = c.optString(), documentPath = c.optString()
        let documentSHA = c.optString(), shareHost = c.optString()
        let ids = PaperIDs(doi: doi, arxivID: arxivID, arxivVersion: arxivVersion, pii: pii, publishedDOI: publishedDOI)
        return MailItem(
            pk: pk, id: id, messagePK: messagePK, ord: ord, cand: cand,
            origin: originExt.flatMap { $0.storedBase == origin ? $0 : nil } ?? origin, foundBy: foundBy,
            title: title, authors: authors, venue: venue, year: year, ids: ids, url: url, urlOriginal: urlOriginal,
            host: host, metaSource: metaSource, relevance: relevance, why: why, confidence: confidence,
            pdfState: pdfStateExt.flatMap { $0.storedBase == pdfState ? $0 : nil } ?? pdfState,
            pdfPath: pdfPath, pdfSHA256: pdfSHA256, pdfBytes: pdfBytes,
            downloadError: downloadError, paperID: paperID, status: status, createdAt: createdAt,
            updatedAt: updatedAt, documentFileName: documentName, documentKind: documentKind, shareHost: shareHost,
            documentPath: documentPath, documentSHA256: documentSHA)
    }

    // MARK: - Provenance (paper_source)

    private static let sourceColumns = [
        "kind", "mail_message_id", "internet_message_id", "from_address", "from_name", "subject", "received_at",
        "web_link", "request_kind", "summary", "due_hint", "added_at", "document",
    ]

    /// Records that `paperPK` came from (or was linked to) an email. Idempotent per
    /// (paper, Message-ID): repeating it refreshes the stored fields and keeps the first
    /// `added_at` — and a kept original `document` unless the new record names one.
    /// Emits `.paper(pk:)`; throws a foreign-key violation for an unknown paper.
    package func insertPaperSource(paperPK: Int64, _ p: PaperProvenance) throws {
        try write {
            let messageID = Database.clean(p.internetMessageID)
            try db.run("INSERT INTO paper_source(paper_pk, " + Database.sourceColumns.joined(separator: ", ")
                       + ") VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                       + " ON CONFLICT(paper_pk, internet_message_id) DO UPDATE SET "
                       + Database.sourceColumns.filter { $0 != "internet_message_id" && $0 != "added_at" }
                        .map { $0 == "document" ? "document = COALESCE(excluded.document, paper_source.document)"
                                                : "\($0) = excluded.\($0)" }.joined(separator: ", "), [
                .integer(paperPK), .text(p.kind), .string(p.mailMessageID?.lowercased()), .string(messageID),
                .string(p.fromAddress), .string(p.fromName), .string(p.subject),
                .string(p.receivedAt.map(Database.timestamp)), .string(p.webLink), .string(p.requestKind?.rawValue),
                .string(p.summary), .string(p.dueHint?.iso), .text(Database.timestamp(p.addedAt)),
                .string(p.document),
            ])
            note(.paper(pk: paperPK))
        }
    }

    /// Names the original document kept in the paper's folder (`PaperProvenance.document`) on the
    /// paper's provenance row for that email. False when the paper has no row for the Message-ID.
    @discardableResult
    package func setPaperSourceDocument(paperPK: Int64, internetMessageID: String, document: String?) throws -> Bool {
        try write {
            guard let messageID = Database.clean(internetMessageID) else { return false }
            try db.run("UPDATE paper_source SET document = ? WHERE paper_pk = ? AND internet_message_id = ?",
                       [.string(document), .integer(paperPK), .text(messageID)])
            let changed = db.changes > 0
            if changed { note(.paper(pk: paperPK)) }
            return changed
        }
    }

    /// Provenance of one paper, oldest first.
    package func paperSources(paperPK: Int64) throws -> [PaperProvenance] {
        try db.query("SELECT " + Database.sourceColumns.joined(separator: ", ")
                     + " FROM paper_source WHERE paper_pk = ? ORDER BY added_at, pk", [.integer(paperPK)]) { s in
            var c = Columns(s)
            return PaperProvenance(
                kind: c.string(), mailMessageID: c.optString(), internetMessageID: c.optString(),
                fromAddress: c.optString(), fromName: c.optString(), subject: c.optString(),
                receivedAt: c.optDate(), webLink: c.optString(),
                requestKind: c.optString().flatMap(MailRequestKind.init(rawValue:)), summary: c.optString(),
                dueHint: c.localDate(), addedAt: c.date(), document: c.optString())
        }
    }

    // MARK: - Sync cursors (kv `mail.cursor.<account>`)

    package static let mailCursorPrefix = "mail.cursor."

    package func mailCursor(accountID: String) throws -> MailCursor? {
        try kv(Database.mailCursorPrefix + accountID).map(MailCursor.init)
    }

    /// Saves (or with nil, removes) an account's resume point. Call only after the batch it
    /// covers has committed. Internal state, so no change notification.
    package func setMailCursor(accountID: String, _ cursor: MailCursor?) throws {
        let key = Database.mailCursorPrefix + accountID
        try write {
            if let cursor {
                try db.run("INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           [.text(key), .text(cursor.value)])
            } else {
                try db.run("DELETE FROM kv WHERE key = ?", [.text(key)])
            }
        }
    }
}
