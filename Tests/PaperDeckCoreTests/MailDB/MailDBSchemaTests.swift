import Foundation
import Testing
@testable import PaperDeckCore

// Schema level 2 (mail tables; user_version stays 1, `schema_feature` records them), the enum ↔
// CHECK contract, and the `paperdeck://mail` deep link.

fileprivate let t0 = Date(timeIntervalSince1970: 1_790_000_000)

fileprivate func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pd-maildb-schema-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

fileprivate func message(_ n: Int, senderKind: SenderKind = .alert) -> MailMessage {
    MailMessage(accountID: "acct", internetMessageID: "<schema-\(n)@example.org>", fromAddress: "alerts@example.org",
                senderKind: senderKind, subject: "Alert \(n)", receivedAt: t0.addingTimeInterval(Double(n)))
}

/// Names in sqlite_master of `type` ('table' / 'index').
fileprivate func schemaNames(_ db: Database, type: String) async throws -> Set<String> {
    Set(try await db.transaction { db in
        try db.db.query("SELECT name FROM sqlite_master WHERE type = ?", [.text(type)]) { $0.string(0) }
    })
}

/// A v1 library file with one paper and a kv row, built by the real v1 migration.
fileprivate func makeV1File(at url: URL) throws {
    let raw = try SQLiteConnection(path: url.path)
    defer { raw.close() }
    let outcome = try Migrations.prepare(raw, backupsDir: nil, now: t0, targetVersion: 1)
    #expect(outcome == Migrations.Outcome(fromVersion: 0, toVersion: 1, backup: nil))
    try raw.run("""
        INSERT INTO paper(id, sha256, file_size, doi, title, title_rank, folder, pdf_name, original_name,
                          queue_rank, added_at, updated_at)
        VALUES('11111111-2222-3333-4444-555555555555', ?2, 1, '10.1/old', 'Old paper', 4, 'Papers/old',
               'old.pdf', 'old.pdf', 1, ?1, ?1)
        """, [.text(Database.timestamp(t0)), .text(String(repeating: "b", count: 64))])
    try raw.run("INSERT INTO kv(key, value) VALUES('plan.skipDays', '[]')")
}

@Suite struct MailDBSchemaTests {
    @Test func freshDatabaseHasTheMailTablesAndIndexes() async throws {
        let db = try Database.inMemory()
        #expect(Migrations.latestVersion == 2)
        #expect(try await db.schemaVersion() == 2)                          // level 2: library + mail
        #expect(db.migration == Migrations.Outcome(fromVersion: 0, toVersion: 2, backup: nil))
        // On disk (round 3, r3-2): user_version stays the core's 1; the mail tables are a marked feature.
        let marks = try await db.transaction { db in
            (try db.db.userVersion(), try Migrations.featureVersion(db.db, Migrations.mailFeature))
        }
        #expect(marks.0 == 1 && marks.1 == 1)
        let tables = try await schemaNames(db, type: "table")
        #expect(tables.isSuperset(of: ["mail_message", "mail_item", "paper_source", "paper", "kv"]))
        let indexes = try await schemaNames(db, type: "index")
        #expect(indexes.isSuperset(of: ["ux_mail_msgid", "ix_mail_state", "ix_mail_triage", "ix_mail_item_msg",
                                        "ix_mail_item_doi", "ix_mail_item_arxiv", "ix_mail_item_open"]))
        let secureDelete = try await db.transaction { db in try db.db.scalarInt("PRAGMA secure_delete") }
        #expect(secureDelete == 2)                                          // FAST
    }

    @Test func migratesAV1FileWithABackupFirst() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        let backups = dir.appendingPathComponent("Backups")
        try makeV1File(at: url)

        let db = try Database(url: url, backupsDir: backups)
        let backup = try #require(db.migration.backup)
        #expect(db.migration.fromVersion == 1 && db.migration.toVersion == 2)
        #expect(backup.lastPathComponent.hasPrefix("pre-migration-v1-") && backup.pathExtension == "sqlite")
        #expect(backup.deletingLastPathComponent().standardizedFileURL.path == backups.standardizedFileURL.path)

        // The backup is the untouched v1 file.
        let copy = try SQLiteConnection(path: backup.path)
        #expect(try copy.userVersion() == 1)
        #expect(try copy.scalarString("SELECT title FROM paper") == "Old paper")
        #expect(try copy.scalarInt("SELECT count(*) FROM sqlite_master WHERE name LIKE 'mail_%'") == 0)
        copy.close()

        // Existing data survives; the new tables work, including provenance on the old paper.
        #expect(try await db.schemaVersion() == 2)
        let marks = try await db.transaction { db in
            (try db.db.userVersion(), try Migrations.featureVersion(db.db, Migrations.mailFeature))
        }
        #expect(marks.0 == 1 && marks.1 == 1)                              // the pre-mail build's gate still passes
        let papers = try await db.livePapers()
        #expect(papers.map(\.title) == ["Old paper"])
        #expect(try await db.categories().count == PaperCategory.starters.count)
        #expect(try await db.kv("plan.skipDays") == "[]")
        let (saved, _) = try await db.insertMailMessage(message(1), items: [])
        #expect(try await db.mailMessage(pk: saved.pk) == saved)
        try #require(papers.count > 0)          // no index past a failed expectation (QA-15)
        try await db.insertPaperSource(paperPK: papers[0].pk, PaperProvenance(internetMessageID: "<schema-1@example.org>",
                                                                               addedAt: t0))
        #expect(try await db.paperSources(paperPK: papers[0].pk).count == 1)
        #expect(await db.integrityCheck() == "ok")
        await db.close()
    }

    @Test func reopeningAV2FileIsIdempotent() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Support/library.sqlite")
        let backups = dir.appendingPathComponent("Support/Backups")
        let first = try Database(url: url, backupsDir: backups)
        #expect(first.migration.backup == nil)                              // fresh file: nothing to back up
        let (m, _) = try await first.insertMailMessage(message(1), items: [])
        await first.close()

        let second = try await Database.open(url: url, backupsDir: backups)
        #expect(second.migration == Migrations.Outcome(fromVersion: 2, toVersion: 2, backup: nil))
        #expect(try await second.mailMessage(id: m.id) == m)
        #expect(!FileManager.default.fileExists(atPath: backups.path))
        await second.close()
    }

    @Test func refusesASchemaNewerThanV2() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        do {
            let raw = try SQLiteConnection(path: url.path)
            try raw.exec("CREATE TABLE future(x); PRAGMA user_version = 3")
            raw.close()
        }
        #expect(throws: DatabaseError.newerSchema(found: 3, supported: 2)) {
            _ = try Database(url: url, backupsDir: dir)
        }
        let raw = try SQLiteConnection(path: url.path)
        #expect(try raw.userVersion() == 3)
        #expect(try raw.scalarInt("SELECT count(*) FROM sqlite_master WHERE name = 'mail_message'") == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasPrefix("pre-migration") })
    }

    /// The CHECK lists in migration 2 are frozen; this fails if an enum gains a case the
    /// schema would reject (that needs a new migration).
    @Test func everyEnumRawValueIsStorable() async throws {
        let db = try Database.inMemory()
        let triageSources: [MailTriageSource?] = [.ai, .heuristic, nil]
        let auth: [MailAuthState] = [.pass, .fail, .unknown]
        let counts = [SenderKind.allCases.count, MailState.allCases.count, MailTriageState.allCases.count,
                      triageSources.count, auth.count]
        var saved: [MailMessage] = []
        for i in 0..<counts.max()! {
            var m = message(100 + i)
            m.senderKind = SenderKind.allCases[i % counts[0]]
            m.state = MailState.allCases[i % counts[1]]
            m.triageState = MailTriageState.allCases[i % counts[2]]
            m.triageSource = triageSources[i % counts[3]]
            m.authState = auth[i % counts[4]]
            let (row, _) = try await db.insertMailMessage(m, items: [])
            #expect(row.senderKind == m.senderKind && row.state == m.state && row.triageState == m.triageState
                    && row.triageSource == m.triageSource && row.authState == m.authState)
            saved.append(row)
        }

        let origins: [MailItemOrigin] = [.attachment, .link, .identifier, .citation, .alertEntry]
        let foundBy: [MailItemFoundBy] = [.local, .ai, .user]
        let relevance: [MailItemRelevance?] = [.requested, .highlighted, .listed, nil]
        let status: [MailItemStatus] = [.pending, .merged, .linked, .skipped]
        let metaSources: [MetaSource] = [.none, .pdf, .crossref, .arxiv, .biorxiv, .openalex, .agent, .user]
        let itemCounts = [origins.count, foundBy.count, relevance.count, status.count, MailPDFState.allCases.count,
                          metaSources.count]
        for i in 0..<itemCounts.max()! {
            let item = MailItem(messagePK: saved[0].pk, ord: i, cand: "c\(i + 1)", origin: origins[i % itemCounts[0]],
                                foundBy: foundBy[i % itemCounts[1]], metaSource: metaSources[i % itemCounts[5]],
                                relevance: relevance[i % itemCounts[2]],
                                pdfState: MailPDFState.allCases[i % itemCounts[4]], status: status[i % itemCounts[3]])
            let row = try await db.upsertMailItem(item)
            #expect(row.origin == item.origin && row.foundBy == item.foundBy && row.relevance == item.relevance
                    && row.status == item.status && row.pdfState == item.pdfState && row.metaSource == item.metaSource)
        }
        for kind in MailRequestKind.allCases {
            let p = PaperProvenance(internetMessageID: "<\(kind.rawValue)@x>", requestKind: kind, addedAt: t0)
            #expect(p.requestKind?.rawValue == kind.rawValue)
        }
    }

    /// Rows a newer build might write (unknown enum strings, JSON we can't decode) still read.
    @Test func unreadableValuesFallBackToDefaults() async throws {
        let db = try Database.inMemory()
        var m = message(1, senderKind: .advisor)
        m.triage = MailTriage(hasReadingRequest: true, requestKind: .advisorRequest, summary: "s")
        let (saved, items) = try await db.insertMailMessage(m, items: [MailItem(ord: 0, cand: "c1", origin: .link)])
        #expect(try await db.mailCounts().requests == 1)
        let pk = saved.pk, itemPK = items[0].pk
        try await db.transaction { db in
            try db.db.exec("PRAGMA ignore_check_constraints = ON")
            try db.db.run("""
                UPDATE mail_message SET triage_json = '{not json', state = 'future', triage_state = 'future',
                  sender_kind = 'future', auth_state = 'future', triage_source = 'future' WHERE pk = ?
                """, [.integer(pk)])
            try db.db.run("""
                UPDATE mail_item SET authors_json = 'nope', origin = 'future', found_by = 'future', relevance = 'future',
                  pdf_state = 'future', status = 'future', meta_source = 'future' WHERE pk = ?
                """, [.integer(itemPK)])
            try db.db.exec("PRAGMA ignore_check_constraints = OFF")
        }
        let row = try #require(try await db.mailMessage(pk: pk))
        #expect(row.triage == nil && row.state == .pending && row.triageState == MailTriageState.none)
        #expect(row.senderKind == .person && row.authState == .unknown && row.triageSource == nil)
        let item = try #require(try await db.mailItems(messagePK: pk).first)
        #expect(item.authors.isEmpty && item.origin == .link && item.foundBy == .local && item.relevance == nil)
        #expect(item.pdfState == .unknown && item.status == .pending && item.metaSource == MetaSource.none)
        let counts = try await db.mailCounts()                             // malformed JSON never breaks the count
        #expect(counts.pending == 0 && counts.requests == 0)               // 'future' is not 'pending'
    }
}

@Suite struct MailDeepLinkTests {
    private let id = "0f8fad5b-d9cb-469f-a165-70867728950e"

    @Test func parsesInboxAndMessageLinks() throws {
        #expect(DeepLink(url: URL(string: "paperdeck://mail")!) == .mail(id: nil))
        #expect(DeepLink(url: URL(string: "paperdeck://mail/")!) == .mail(id: nil))
        #expect(DeepLink(url: URL(string: "PAPERDECK://Mail")!) == .mail(id: nil))
        #expect(DeepLink(url: URL(string: "paperdeck://mail/\(id)")!) == .mail(id: id))
        #expect(DeepLink(url: URL(string: "paperdeck://mail/\(id.uppercased())")!) == .mail(id: id))   // normalized
    }

    @Test func rejectsMalformedMailLinks() throws {
        for s in ["paperdeck://mail/not-a-uuid", "paperdeck://mail/\(id)/extra", "paperdeck://mail/\(id)x",
                  "paperdeck://mails", "https://mail/\(id)"] {
            #expect(DeepLink(url: URL(string: s)!) == nil, "\(s)")
        }
    }

    @Test func printsAndRoundTrips() throws {
        #expect(DeepLink.mail(id: nil).url.absoluteString == "paperdeck://mail")
        #expect(DeepLink.mail(id: id).url.absoluteString == "paperdeck://mail/\(id)")
        for link: DeepLink in [.mail(id: nil), .mail(id: id), .paper(id: id), .today, .settings(tab: "mail")] {
            #expect(DeepLink(url: link.url) == link)
        }
    }
}
