import Foundation
import Testing
@testable import PaperDeckCore

/// The new origins / PDF states and document fields in SQLite (frozen CHECK lists + additive
/// columns), card.json provenance and lenient decoding.
@Suite struct DocumentStorageTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func message(_ n: Int) -> MailMessage {
        MailMessage(accountID: "acct", internetMessageID: "<docdb-\(n)@x>", fromAddress: "prof@wustl.edu",
                    senderKind: .advisor, subject: "s", receivedAt: t0, createdAt: t0, updatedAt: t0)
    }

    private func docRow(_ ord: Int, state: MailPDFState = .convertible) -> MailItem {
        MailItem(ord: ord, cand: "c\(ord)", origin: .document, title: "Lab manuscript", pdfState: state, pdfBytes: 7_500_000,
                 createdAt: t0, updatedAt: t0, documentFileName: "Lab_manuscript.docx", documentKind: "docx",
                 documentPath: "0f8fad5b-d9cb-469f-a165-70867728950e/1.docx", documentSHA256: "ABC123")
    }

    @Test func newOriginsAndStatesRoundTripThroughTheFrozenColumns() async throws {
        let db = try Database.inMemory()
        let share = MailItem(ord: 2, cand: "c2", origin: .shareLink, url: "https://wustl.box.com/s/a", host: "wustl.box.com",
                             pdfState: .needsPDF, createdAt: t0, updatedAt: t0, documentKind: "docx", shareHost: "box.com")
        let slides = MailItem(ord: 3, cand: "c3", origin: .document, pdfState: .openOnly, createdAt: t0, updatedAt: t0,
                              documentFileName: "talk.pptx", documentKind: "pptx", documentPath: "x/3.pptx")
        let (saved, rows) = try await db.insertMailMessage(message(1), items: [docRow(1), share, slides])
        #expect(rows.map(\.origin) == [.document, .shareLink, .document])
        #expect(rows.map(\.pdfState) == [.convertible, .needsPDF, .openOnly])
        let d = rows[0]
        #expect(d.documentFileName == "Lab_manuscript.docx" && d.documentKind == "docx" && d.pdfBytes == 7_500_000)
        #expect(d.documentPath == "0f8fad5b-d9cb-469f-a165-70867728950e/1.docx" && d.documentSHA256 == "ABC123")
        #expect(rows[1].shareHost == "box.com" && rows[1].documentKind == "docx")
        // What an older build reads: the CHECK-list values.
        let raw = try await db.transaction { db in
            try db.db.query("SELECT origin, pdf_state, origin_ext, pdf_state_ext FROM mail_item WHERE message_pk = ? ORDER BY ord",
                            [.integer(saved.pk)]) { [$0.string(0), $0.string(1), $0.optionalString(2) ?? "-", $0.optionalString(3) ?? "-"] }
        }
        #expect(raw == [["attachment", "needs_pdf", "document", "convertible"], ["link", "needs_pdf", "share_link", "-"],
                        ["attachment", "needs_pdf", "document", "open_only"]])
        // Every PDF state is storable (the CHECK list is frozen).
        for (i, state) in MailPDFState.allCases.enumerated() {
            var row = docRow(10 + i, state: state)
            row.messagePK = saved.pk
            row.id = UUID().uuidString.lowercased()
            #expect(try await db.upsertMailItem(row).pdfState == state)
        }
        for (i, origin) in MailItemOrigin.allCases.enumerated() {
            let row = MailItem(messagePK: saved.pk, ord: 40 + i, cand: "c\(40 + i)", origin: origin)
            #expect(try await db.upsertMailItem(row).origin == origin)
        }
    }

    /// An older build that changed a document row (a PDF dropped → has_pdf) wins over the stale
    /// extension; an unknown extension value falls back to the base column.
    @Test func baseColumnChangesWinOverAStaleExtension() async throws {
        let db = try Database.inMemory()
        let (_, rows) = try await db.insertMailMessage(message(2), items: [docRow(1)])
        let pk = rows[0].pk
        try await db.transaction { db in
            try db.db.run("UPDATE mail_item SET pdf_state = 'has_pdf', pdf_path = 'x/1.pdf' WHERE pk = ?", [.integer(pk)])
        }
        let after = try #require(try await db.mailItem(id: rows[0].id))
        #expect(after.pdfState == .hasPDF && after.origin == .document)
        try await db.transaction { db in
            try db.db.run("UPDATE mail_item SET origin = 'link', origin_ext = 'document', pdf_state = 'needs_pdf', pdf_state_ext = 'future' WHERE pk = ?",
                          [.integer(pk)])
        }
        let odd = try #require(try await db.mailItem(id: rows[0].id))
        #expect(odd.origin == .link && odd.pdfState == .needsPDF)
    }

    /// Documents converted before are found by the original's SHA-256.
    @Test func itemsByDocumentHash() async throws {
        let db = try Database.inMemory()
        _ = try await db.insertMailMessage(message(3), items: [docRow(1)])
        #expect(try await db.mailItems(documentSHA256: "abc123").count == 1)          // stored lowercased, matched case-insensitively
        #expect(try await db.mailItems(documentSHA256: "nope").isEmpty)
    }

    @Test func anOlderMailSchemaGainsTheDocumentColumnsAtOpen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-docs-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        do {
            let raw = try SQLiteConnection(path: url.path)
            try Migrations.prepare(raw, backupsDir: nil)
            for col in ["origin_ext", "pdf_state_ext", "document_name", "document_kind", "document_path", "document_sha256", "share_host"] {
                try raw.exec("ALTER TABLE mail_item DROP COLUMN \(col)")
            }
            try raw.exec("ALTER TABLE paper_source DROP COLUMN document")
            try raw.run("""
                INSERT INTO mail_message(id, internet_message_id, from_address, received_at, created_at, updated_at)
                VALUES('m1', '<old-docs@x>', 'a@x', '2026-09-30T10:00:00.000Z', '2026-09-30T10:00:00.000Z', '2026-09-30T10:00:00.000Z')
                """)
            try raw.run("""
                INSERT INTO mail_item(id, message_pk, ord, cand, origin, pdf_state, created_at, updated_at)
                VALUES('i1', 1, 1, 'c1', 'link', 'needs_pdf', '2026-09-30T10:00:00.000Z', '2026-09-30T10:00:00.000Z')
                """)
            #expect(try raw.userVersion() == 1)
            raw.close()
        }
        let backups = dir.appendingPathComponent("Backups")
        let db = try await Database.open(url: url, backupsDir: backups)
        let old = try #require(try await db.mailItem(id: "i1"))
        #expect(old.origin == .link && old.pdfState == .needsPDF && old.documentPath == nil && old.shareHost == nil)
        let (_, rows) = try await db.insertMailMessage(message(4), items: [docRow(1)])
        #expect(rows.first?.pdfState == .convertible)
        await db.close()
        #expect(!FileManager.default.fileExists(atPath: backups.path))           // additive: no backup
        let raw = try SQLiteConnection(path: url.path)
        defer { raw.close() }
        #expect(try raw.userVersion() == 1)
        #expect(try Migrations.featureVersion(raw, Migrations.mailFeature) == 1)
        let itemColumns = try raw.query("SELECT name FROM pragma_table_info('mail_item')") { $0.string(0) }
        #expect(itemColumns.contains("origin_ext") && itemColumns.contains("share_host") && itemColumns.contains("document_sha256"))
        let sourceColumns = try raw.query("SELECT name FROM pragma_table_info('paper_source')") { $0.string(0) }
        #expect(sourceColumns.contains("document"))
        // What an older build runs: its own column list (no new columns) still inserts.
        try raw.run("""
            INSERT INTO mail_item(id, message_pk, ord, cand, origin, pdf_state, created_at, updated_at)
            VALUES('i9', 1, 9, 'c9', 'attachment', 'needs_pdf', '2026-09-30T10:00:00.000Z', '2026-09-30T10:00:00.000Z')
            """)
    }

    @Test func provenanceKeepsTheOriginalsName() async throws {
        let db = try Database.inMemory()
        let paper = try await db.insertPaper(Paper(sha256: "f00d", fileSize: 1, title: "T", folder: "Papers/T",
                                                   pdfName: "T.pdf", originalName: "T.pdf", addedAt: t0, updatedAt: t0),
                                             checklist: [])
        var p = PaperProvenance(internetMessageID: "<prov@x>", subject: "Draft", addedAt: t0)
        try await db.insertPaperSource(paperPK: paper.pk, p)
        #expect(try await db.paperSources(paperPK: paper.pk).first?.document == nil)
        #expect(try await db.setPaperSourceDocument(paperPK: paper.pk, internetMessageID: "<PROV@x>", document: "Lab.source.docx"))
        #expect(try await db.paperSources(paperPK: paper.pk).first?.document == "Lab.source.docx")
        // A later link from the same email (no document) keeps the name; a new name replaces it.
        p.summary = "again"
        try await db.insertPaperSource(paperPK: paper.pk, p)
        #expect(try await db.paperSources(paperPK: paper.pk).first?.document == "Lab.source.docx")
        p.document = "Lab.source 2.docx"
        try await db.insertPaperSource(paperPK: paper.pk, p)
        #expect(try await db.paperSources(paperPK: paper.pk).first?.document == "Lab.source 2.docx")
        #expect(!(try await db.setPaperSourceDocument(paperPK: paper.pk, internetMessageID: "<other@x>", document: "x")))
    }

    @Test func cardJSONListsTheOriginalOnlyWhenThereIsOne() throws {
        let with = CardSidecar.ProvenanceEntry(PaperProvenance(internetMessageID: "<a@x>", addedAt: t0, document: "Lab.source.docx"))
        let without = CardSidecar.ProvenanceEntry(PaperProvenance(internetMessageID: "<a@x>", addedAt: t0))
        let enc = CardSidecar.makeEncoder()
        let a = String(decoding: try enc.encode(with), as: UTF8.self)
        let b = String(decoding: try enc.encode(without), as: UTF8.self)
        #expect(a.contains("\"document\" : \"Lab.source.docx\""))
        #expect(!b.contains("document"))                                       // other cards keep their bytes
        let back = try JSONDecoder().decode(CardSidecar.ProvenanceEntry.self, from: Data(a.utf8))
        #expect(back.model.document == "Lab.source.docx")
        // A hand-edited path never names a file outside the folder.
        for bad in ["../../x.docx", ".hidden.docx", "a/b.docx", "a\\b.docx", "x\u{0}.docx", ""] {
            #expect(CardSidecar.safeDocumentName(bad) == nil, "\(bad)")
        }
        #expect(CardSidecar.safeDocumentName("Lab manuscript.source.docx") == "Lab manuscript.source.docx")
    }

    @Test func lenientDecodingOfTheNewRawValues() throws {
        let d = JSONDecoder()
        #expect(try d.decode([MailItemOrigin].self, from: Data(#"["document","share_link","future"]"#.utf8)) == [.document, .shareLink, .link])
        #expect(try d.decode([MailPDFState].self, from: Data(#"["convertible","open_only","future"]"#.utf8)) == [.convertible, .openOnly, .unknown])
        let e = String(decoding: try JSONEncoder().encode([MailItemOrigin.shareLink]), as: UTF8.self)
        #expect(e == #"["share_link"]"#)
        #expect(MailPDFState.convertible.storedBase == .needsPDF && MailPDFState.hasPDF.storedBase == .hasPDF)
        #expect(MailItemOrigin.document.storedBase == .attachment && MailItemOrigin.shareLink.storedBase == .link)
        #expect(MailPDFState.openOnly.waitsForPDF && MailPDFState.convertible.waitsForPDF && !MailPDFState.hasPDF.waitsForPDF)
    }
}
