import Foundation
import Testing
@testable import PaperDeckCore

/// 「转换为 PDF 并合并」, 「打开文档」 and the other merge paths for document / shared-file rows —
/// temp-rooted engines, no network (the link downloader records requests), no AI CLI.
@Suite struct DocumentMergeTests {
    typealias Kit = MailMergeKit

    static let docName = "Smith_lab_manuscript_v3.docx"

    /// A card with one document row whose original is stored like the sync stores it.
    static func insertDocument(_ env: Kit.Env, data: Data, kind: String = "docx", name: String = docName,
                               state: MailPDFState = .convertible, sender: SenderKind = .advisor,
                               extra: [MailItem] = []) async throws -> (MailMessage, MailItem) {
        let row = MailItem(ord: 1, cand: "c1", origin: .document, title: MailExtractor.documentTitle(name),
                           relevance: .highlighted, pdfState: state, pdfBytes: Int64(data.count),
                           createdAt: Kit.start, updatedAt: Kit.start, documentFileName: name, documentKind: kind,
                           documentSHA256: FileOps.sha256(of: data))
        let (m, rows) = try await Kit.insert(env, Kit.message(kind: sender, triage: Kit.triage(request: false, kind: .fyi)),
                                             items: [row] + extra)
        var stored = rows[0]
        let rel = "\(m.id)/1.\(kind)"
        let url = env.paths.mailFiles.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        stored.documentPath = rel
        stored = try await env.db.upsertMailItem(stored, now: Kit.start)
        return (m, stored)
    }

    @Test func convertingAddsThePaperHeldForAIAndKeepsTheOriginal() async throws {
        try await Kit.run { env in
            let docx = try DocKit.docx(paragraphs: 30)
            let (m, row) = try await Self.insertDocument(env, data: docx)
            let id = try #require(try await env.engine.convertAndMergeMailItem(itemID: row.id, options: MailMergeOptions()))
            await env.settle()

            let paper = try await env.paper(id)
            #expect(paper.originalName == "Smith_lab_manuscript_v3.pdf")
            // Possibly unpublished: the reading job waits for the user's confirmation.
            #expect(paper.aiState == .held && paper.aiNote == ImportAnnotation.unpublishedHoldNote)
            #expect(try await env.db.activeJob(paperPK: paper.pk)?.state == .held)
            // The row and the card.
            let after = try await env.item(row.id)
            #expect(after.status == .merged && after.paperID == id && after.pdfState == .inLibrary)
            #expect(after.documentPath == nil && after.pdfPath == nil && after.downloadError == nil)
            let card = try await env.message(m.id)
            #expect(card.state == .merged && card.userTouched)
            // Our copies are gone; the original sits next to the PDF and card.json names it.
            #expect(!FileManager.default.fileExists(atPath: env.paths.mailFiles.appendingPathComponent(m.id).path))
            let folder = env.engine.ctx.folderURL(paper)
            let kept = folder.appendingPathComponent("Smith_lab_manuscript_v3.source.docx")
            #expect(try Data(contentsOf: kept) == docx)
            let sources = try await env.db.paperSources(paperPK: paper.pk)
            #expect(sources.count == 1 && sources.first?.document == "Smith_lab_manuscript_v3.source.docx")
            #expect(sources.first?.mailMessageID == m.id)
            let sidecar = try env.sidecar(paper)
            #expect(sidecar.provenance.first?.document == "Smith_lab_manuscript_v3.source.docx")
            // Converted and imported locally: nothing was fetched.
            #expect(env.downloader.requested.isEmpty)
            // The paper's PDF has the document's text.
            let pdf = try Data(contentsOf: env.engine.ctx.pdfURL(paper))
            #expect(PDFTextProbe.text(pdf).contains(DocKit.lastLine))
        }
    }

    /// card.json carries the kept original's name: an index rebuild restores it.
    @Test func aRebuildRestoresTheKeptOriginalsRecord() async throws {
        let first = try await Kit.make()
        let root = first.root
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, row) = try await Self.insertDocument(first, data: try DocKit.docx(paragraphs: 3))
        let id = try #require(try await first.engine.convertAndMergeMailItem(itemID: row.id, options: MailMergeOptions(readWithAI: false)))
        await first.settle()
        let now = first.clock.value
        await first.engine.shutdown()
        await first.engine.db.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: first.paths.database.path + suffix) }

        let second = try await Kit.make(root: root, now: now)
        let report = try await second.engine.rebuildFromSidecars()
        #expect(report.papers == 1 && report.skipped.isEmpty)
        let paper = try await second.paper(id)
        #expect(try await second.db.paperSources(paperPK: paper.pk).first?.document == "Smith_lab_manuscript_v3.source.docx")
        #expect(FileManager.default.fileExists(atPath: second.engine.ctx.folderURL(paper)
            .appendingPathComponent("Smith_lab_manuscript_v3.source.docx").path))
        #expect(paper.pdfName.hasSuffix(".pdf"))                                    // the original is not taken for the PDF
        await second.engine.shutdown()
        await second.engine.db.close()
    }

    /// A DOI in the text (a reference, a template) must not release the hold of someone's manuscript.
    @Test func aDOIInTheTextDoesNotReleaseTheHold() async throws {
        try await Kit.run { env in
            let s = NSMutableAttributedString(attributedString: DocKit.attributed(paragraphs: 5))
            s.insert(NSAttributedString(string: "DOI: 10.1038/s41586-024-08351-7\n"), at: 0)
            let (_, row) = try await Self.insertDocument(env, data: try DocKit.write(s, .officeOpenXML), sender: .person)
            let id = try #require(try await env.engine.convertAndMergeMailItem(itemID: row.id, options: MailMergeOptions()))
            await env.settle()
            let paper = try await env.paper(id)
            #expect(paper.aiState == .held)
            #expect(try await env.db.activeJob(paperPK: paper.pk)?.state == .held)
        }
    }

    @Test func withoutAIReadingNoJobAtAll() async throws {
        try await Kit.run { env in
            let (_, row) = try await Self.insertDocument(env, data: try DocKit.docx(paragraphs: 3))
            let id = try #require(try await env.engine.convertAndMergeMailItem(itemID: row.id, options: MailMergeOptions(readWithAI: false)))
            await env.settle()
            let paper = try await env.paper(id)
            let job = try await env.db.activeJob(paperPK: paper.pk)
            #expect(paper.aiState == .none && job == nil)
        }
    }

    @Test func aFailedConversionLeavesTheRowConvertibleWithTheReason() async throws {
        try await Kit.run { env in
            let (m, row) = try await Self.insertDocument(env, data: DocKit.zipStub())       // not a Word package
            #expect(try await env.engine.convertAndMergeMailItem(itemID: row.id, options: MailMergeOptions()) == nil)
            let after = try await env.item(row.id)
            #expect(after.status == .pending && after.pdfState == .convertible && after.documentPath == row.documentPath)
            #expect(after.downloadError == DocumentConversionError.unreadable.message(.en))
            #expect(MailMachineText.localized(after.downloadError ?? "", .zh) == DocumentConversionError.unreadable.message(.zh))
            #expect(try await env.message(m.id).userTouched)
            #expect(try await env.db.livePapers().isEmpty)
            #expect(Kit.mailFileExists(env, row.documentPath))                          // the original stays
        }
    }

    @Test func aMissingOriginalWaitsForAPDF() async throws {
        try await Kit.run { env in
            let (_, row) = try await Self.insertDocument(env, data: try DocKit.docx(paragraphs: 2))
            try FileManager.default.removeItem(at: env.paths.mailFiles.appendingPathComponent(try #require(row.documentPath)))
            await #expect(throws: MailOperationError.fileMissing(itemID: row.id)) {
                try await env.engine.convertAndMergeMailItem(itemID: row.id, options: MailMergeOptions())
            }
            let after = try await env.item(row.id)
            #expect(after.pdfState == .needsPDF && after.documentPath == nil)
            #expect(after.downloadError == MailOpsText.documentMissing(.en))
            #expect(MailInboxRules.actions(after).contains(.dropBox))
        }
    }

    @Test func wrongRowsAreRefusedWithClearErrors() async throws {
        try await Kit.run { env in
            let link = Kit.item(2, origin: .link, pdf: .needsPDF, url: "https://example.org/a")
            let (_, row) = try await Self.insertDocument(env, data: DocKit.zipStub(), kind: "pptx", name: "talk.pptx",
                                                         state: .openOnly, extra: [link])
            let rows = try await env.db.mailItems(messagePK: row.messagePK)
            let linkRow = try #require(rows.first { $0.origin == .link })
            await #expect(throws: MailOperationError.notADocument(itemID: linkRow.id)) {
                try await env.engine.convertAndMergeMailItem(itemID: linkRow.id, options: MailMergeOptions())
            }
            await #expect(throws: MailOperationError.notConvertible(itemID: row.id)) {
                try await env.engine.convertAndMergeMailItem(itemID: row.id, options: MailMergeOptions())
            }
            await #expect(throws: MailOperationError.needsPDF(itemID: row.id)) {
                try await env.engine.mergeMailItem(itemID: row.id, options: MailMergeOptions())
            }
            await #expect(throws: MailOperationError.notADocument(itemID: linkRow.id)) {
                try await env.engine.openMailDocument(itemID: linkRow.id)
            }
            for e in [MailOperationError.notADocument(itemID: "x"), .notConvertible(itemID: "x")] {
                #expect(!e.message(.en).isEmpty && !e.message(.zh).isEmpty && e.message(.en) != e.message(.zh))
            }
        }
    }

    @Test func openingReturnsTheStoredOriginal() async throws {
        try await Kit.run { env in
            let (_, row) = try await Self.insertDocument(env, data: DocKit.zipStub(), kind: "pptx", name: "talk.pptx", state: .openOnly)
            let url = try await env.engine.openMailDocument(itemID: row.id)
            #expect(url.standardizedFileURL == env.paths.mailFiles.appendingPathComponent(try #require(row.documentPath)).standardizedFileURL)
            #expect(try await env.item(row.id) == row)                              // opening changes nothing
            try FileManager.default.removeItem(at: url)
            await #expect(throws: MailOperationError.fileMissing(itemID: row.id)) {
                try await env.engine.openMailDocument(itemID: row.id)
            }
            #expect(try await env.item(row.id).pdfState == .needsPDF)
        }
    }

    /// 「全部合并」 and the sender's auto-merge never convert; the user's merge of the row does.
    @Test func onlyAnExplicitClickConverts() async throws {
        try await Kit.run { env in
            let pdfRow = Kit.item(2, relevance: .highlighted)
            let (m, row) = try await Self.insertDocument(env, data: try DocKit.docx(paragraphs: 3), extra: [pdfRow])
            let rows = try await env.db.mailItems(messagePK: m.pk)
            let attachment = try #require(rows.first { $0.origin == .attachment })
            var stored = attachment
            let rel = "\(m.id)/\(attachment.id).pdf"
            let url = env.paths.mailFiles.appendingPathComponent(rel)
            try Kit.pdfData(title: "An attached paper").write(to: url)
            stored.pdfPath = rel
            _ = try await env.db.upsertMailItem(stored, now: Kit.start)
            #expect(MailInboxRules.mergeAllCount(try await env.db.mailItems(messagePK: m.pk)) == 1)

            let auto = try await env.engine.mergeAllMailItems(messageID: m.id, options: MailMergeOptions(), userAction: false)
            #expect(auto.count == 1)
            #expect(try await env.item(row.id).pdfState == .convertible)
            await #expect(throws: MailOperationError.needsPDF(itemID: row.id)) {
                try await env.engine.mergeMailItem(itemID: row.id, options: MailMergeOptions(), userAction: false)
            }
            let all = try await env.engine.mergeAllMailItems(messageID: m.id, options: MailMergeOptions())
            let stillPending = try await env.item(row.id).status == .pending
            #expect(all.isEmpty && stillPending)
            let id = try #require(try await env.engine.mergeMailItem(itemID: row.id, options: MailMergeOptions()))
            #expect(try await env.item(row.id).status == .merged)
            #expect(try await env.paper(id).isLive)
            #expect(try await env.message(m.id).state == .merged)
        }
    }

    /// The same original in another email (a forward, a re-send) links to the paper converted before.
    @Test func theSameOriginalIsNotConvertedTwice() async throws {
        try await Kit.run { env in
            let docx = try DocKit.docx(paragraphs: 4)
            let (_, first) = try await Self.insertDocument(env, data: docx)
            let id = try #require(try await env.engine.convertAndMergeMailItem(itemID: first.id, options: MailMergeOptions()))
            let (m2, second) = try await Self.insertDocument(env, data: docx)
            #expect(try await env.engine.convertAndMergeMailItem(itemID: second.id, options: MailMergeOptions()) == id)
            await env.settle()
            #expect(try await env.db.livePapers().count == 1)
            let after = try await env.item(second.id)
            #expect(after.status == .linked && after.paperID == id && after.documentPath == nil)
            #expect(!Kit.mailFileExists(env, second.documentPath))
            #expect(try await env.db.paperSources(paperPK: try await env.paper(id).pk).count == 2)
            #expect(try await env.message(m2.id).state == .merged)
        }
    }

    /// Slides: the user exports a PDF and drops it on the row — the deck is kept next to it and
    /// the paper is held for AI like any document.
    @Test func aPDFDroppedOnASlidesRowKeepsTheDeck() async throws {
        try await Kit.run { env in
            let deck = DocKit.zipStub("deck")
            let (m, row) = try await Self.insertDocument(env, data: deck, kind: "pptx", name: "Lab talk.pptx", state: .openOnly)
            let file = try Kit.writeUserPDF(env, name: "Lab talk.pdf", title: "Lab talk slides", doi: "10.1038/s41586-024-08351-7")
            let id = try #require(try await env.engine.attachPDFToMailItem(itemID: row.id, file: file))
            await env.settle()
            let paper = try await env.paper(id)
            #expect(paper.aiState == .held)                                          // a DOI does not release it
            let kept = env.engine.ctx.folderURL(paper).appendingPathComponent("Lab talk.source.pptx")
            #expect(try Data(contentsOf: kept) == deck)
            #expect(try await env.db.paperSources(paperPK: paper.pk).first?.document == "Lab talk.source.pptx")
            #expect(try await env.item(row.id).status == .merged)
            #expect(try await env.message(m.id).state == .merged)
            #expect(FileManager.default.fileExists(atPath: file.path))               // the user's file is never moved
        }
    }

    /// Shared files are never downloaded; a PDF the user brings merges, held for AI.
    @Test func sharedFilesWaitForTheUsersPDF() async throws {
        try await Kit.run { env in
            let share = MailItem(ord: 1, cand: "c1", origin: .shareLink, title: "Lab draft",
                                 url: "https://www.dropbox.com/s/abc/paper.pdf?dl=1", urlOriginal: DocKit.safeLink("https://www.dropbox.com/s/abc/paper.pdf?dl=1"),
                                 host: "dropbox.com", relevance: .highlighted, pdfState: .needsPDF,
                                 createdAt: Kit.start, updatedAt: Kit.start, documentKind: "pdf", shareHost: "dropbox.com")
            let (m, rows) = try await Kit.insert(env, Kit.message(kind: .person), items: [share])
            let row = rows[0]
            #expect(Engine.mailDownloadURL(row) == nil)
            #expect(MailInboxRules.chip(row) == .shareLink)
            try await env.engine.downloadMailItem(itemID: row.id)
            #expect(env.downloader.requested.isEmpty)
            #expect(try await env.item(row.id) == row)
            await #expect(throws: MailOperationError.needsPDF(itemID: row.id)) {
                try await env.engine.mergeMailItem(itemID: row.id, options: MailMergeOptions())
            }
            let all = try await env.engine.mergeAllMailItems(messageID: m.id, options: MailMergeOptions())
            #expect(all.isEmpty && env.downloader.requested.isEmpty)
            let file = try Kit.writeUserPDF(env, name: "draft.pdf", title: "Lab draft", doi: "10.1038/s41586-024-08351-7")
            let id = try #require(try await env.engine.attachPDFToMailItem(itemID: row.id, file: file))
            await env.settle()
            #expect(try await env.paper(id).aiState == .held)
            #expect(try await env.item(row.id).status == .merged)
        }
    }
}
