import Foundation
import Testing
@testable import PaperDeckCore

/// Engine.mergeMailItem / mergeAllMailItems / attachPDFToMailItem / downloadMailItem: email rows
/// become library papers (or link to existing ones) with provenance and the user's choices.
@Suite struct MailMergeOperationTests {
    private typealias Kit = MailMergeKit

    @Test func mergingAnAttachmentCreatesAnAnnotatedPaper() async throws {
        try await Kit.run { env in
            let due = Kit.day(2026, 10, 2)
            let m = Kit.message(kind: .advisor, subject: "Papers for [journal] club",
                                triage: Kit.triage(summary: "Read the neocortex atlas before Friday.", due: due, dueConfidence: 0.9))
            let (message, items) = try await Kit.insert(env, m, items: [Kit.item(1)],
                                                        attachments: [0: Kit.pdfData(title: "Molecular dynamics of the developing neocortex",
                                                                                     doi: "10.1038/s41586-024-08351-7")])
            let copy = try #require(items[0].pdfPath)
            let options = MailMergeOptions(priority: .high, pinDeadline: due, category: "Journal Club", readWithAI: true)
            let paperID = try #require(try await env.engine.mergeMailItem(itemID: items[0].id, options: options))
            await env.settle()

            let p = try await env.paper(paperID)
            #expect(p.priority == .high)
            #expect(p.deadline == due && p.scheduleMode == .pinned && p.deadlineOrigin == .user && !p.provisional)
            #expect(p.ids.doi == "10.1038/s41586-024-08351-7")
            let category = try #require(try await env.db.category(named: "Journal Club"))
            #expect(p.categoryPK == category.pk && p.categoryUserSet && category.origin == .user)
            #expect(p.notes.hasPrefix("From email: Prof. X — Papers for \\[journal\\] club (9/29)"))
            #expect(p.notes.contains("\nRead the neocortex atlas before Friday."))

            // Provenance: DB row and card.json.
            let sources = try await env.db.paperSources(paperPK: p.pk)
            #expect(sources.count == 1)
            #expect(sources.first?.mailMessageID == message.id)
            #expect(sources.first?.internetMessageID == message.internetMessageID)
            #expect(sources.first?.fromAddress == "prof.x@wustl.edu" && sources.first?.requestKind == .advisorRequest)
            #expect(sources.first?.dueHint == due && sources.first?.summary == "Read the neocortex atlas before Friday.")
            #expect(try env.sidecar(p).provenance.map(\.model) == sources)

            // Advisor request + AI reading → a queued job at raised priority.
            let job = try #require(try await env.db.activeJob(paperPK: p.pk))
            #expect(job.priority == 1 && job.state == .queued)

            // Row merged, copy deleted, card complete.
            let row = try await env.item(items[0].id)
            #expect(row.status == .merged && row.paperID == paperID && row.pdfState == .inLibrary && row.pdfPath == nil)
            #expect(!Kit.mailFileExists(env, copy))
            let card = try await env.message(message.id)
            #expect(card.state == .merged && card.userTouched && card.handledAt == Kit.start)

            // Idempotent.
            #expect(try await env.engine.mergeMailItem(itemID: items[0].id, options: options) == paperID)
            #expect(try await env.db.livePapers().count == 1)
        }
    }

    @Test func siblingRowsOfTheSamePaperAreLinkedSilently() async throws {
        try await Kit.run { env in
            let doi = "10.1038/s41586-024-08351-7"
            let (message, items) = try await Kit.insert(env, Kit.message(kind: .advisor), items: [
                Kit.item(1),
                Kit.item(2, origin: .link, relevance: .requested, pdf: .needsPDF, doi: doi,
                         url: "https://www.nature.com/articles/s41586-024-08351-7", host: "www.nature.com"),
            ], attachments: [0: Kit.pdfData(title: "Neocortex atlas", doi: doi)])
            let id = try #require(try await env.engine.mergeMailItem(itemID: items[0].id, options: MailMergeOptions(readWithAI: false)))
            await env.settle()
            let sibling = try await env.item(items[1].id)
            #expect(sibling.status == .linked && sibling.paperID == id)
            #expect(try await env.message(message.id).state == .merged)
            #expect(!env.events.toasts.contains { $0.message.hasPrefix("Matched an email request") })
            #expect(try await env.db.paperSources(paperPK: try await env.paper(id).pk).count == 1)
        }
    }

    @Test func notesPrefillIsSkippedWhenOffAndNoAIJobWithoutReading() async throws {
        var mail = MailSettings()
        mail.prefillNotes = false
        try await Kit.run(mail: mail) { env in
            let (_, items) = try await Kit.insert(env, Kit.message(kind: .alert, triage: nil), items: [Kit.item(1)],
                                                  attachments: [0: Kit.pdfData(title: "Alert paper", doi: "10.1101/2026.09.14.612345")])
            let id = try #require(try await env.engine.mergeMailItem(itemID: items[0].id, options: MailMergeOptions(readWithAI: false)))
            await env.settle()
            let p = try await env.paper(id)
            #expect(p.notes.isEmpty)
            #expect(p.priority == .normal && p.scheduleMode == .auto)
            #expect(try await env.db.activeJob(paperPK: p.pk) == nil)
        }
    }

    @Test func mergeAllHandlesMixedRows() async throws {
        try await Kit.run { env in
            // An existing paper the card also names.
            let existingURL = try Kit.writeUserPDF(env, name: "existing.pdf", title: "Already here", doi: "10.1016/j.cell.2024.11.015")
            let first = await env.engine.intake.ingest([.file(existingURL)], options: ImportOptions(origin: .drop, ai: .skip))
            let existingID = try #require(first.added.first)
            await env.settle()

            let arxivURL = "https://arxiv.org/abs/2606.24530v2"
            env.downloader.route("https://arxiv.org/pdf/2606.24530",
                                 .init(status: 200, mime: "application/pdf", body: Kit.pdfData(title: "NatureBench")))
            let (message, _) = try await Kit.insert(env, Kit.message(), items: [
                Kit.item(1),                                                                          // attachment
                Kit.item(2, origin: .link, pdf: .downloadable, arxiv: "2606.24530", url: arxivURL, host: "arxiv.org"),
                Kit.item(3, origin: .link, pdf: .needsPDF, title: "Spatial atlas", doi: "10.1016/j.cell.2025.01.001",
                         url: "https://www.cell.com/cell/fulltext/S0092-8674(25)00001-1", host: "cell.com"),
                Kit.item(4, origin: .link, pdf: .inLibrary, doi: "10.1016/j.cell.2024.11.015", paperID: existingID),
                Kit.item(5, origin: .alertEntry, relevance: .listed, pdf: .downloadable, arxiv: "2604.09554",
                         url: "https://arxiv.org/abs/2604.09554", host: "arxiv.org"),
            ], attachments: [0: Kit.pdfData(title: "Attached manuscript", doi: "10.1038/s41586-024-08351-7")])

            let ids = try await env.engine.mergeAllMailItems(messageID: message.id, options: MailMergeOptions(readWithAI: false))
            await env.settle()
            #expect(ids.count == 3)
            #expect(ids.contains(existingID))
            let rows = try await env.db.mailItems(messagePK: message.pk)
            #expect(rows.map(\.status) == [.merged, .merged, .pending, .linked, .pending])
            try #require(rows.count > 4)          // no index past a failed expectation (QA-15)
            #expect(rows[1].paperID != nil && rows[1].pdfState == .inLibrary)
            #expect(rows[4].pdfState == .downloadable)                       // listed entries are not merged
            #expect(env.downloader.requested.map(\.absoluteString) == ["https://arxiv.org/pdf/2606.24530"])
            #expect(try await env.db.paperSources(paperPK: try await env.paper(existingID).pk).count == 1)

            var card = try await env.message(message.id)
            #expect(card.state == .pending && card.userTouched)
            #expect(MailMergeState.remaining(rows) == 1)
            #expect(MailMergeState.remainingText(1, .zh) == "还差 1 篇需要 PDF")
            #expect(MailMergeState.remainingText(2, .en) == "2 more papers need a PDF")

            // The last requested row gets its PDF from the user → the card is done.
            let dropped = try Kit.writeUserPDF(env, name: "atlas.pdf", title: "Spatial atlas", doi: "10.1016/j.cell.2025.01.001")
            let atlas = try #require(try await env.engine.attachPDFToMailItem(itemID: rows[2].id, file: dropped))
            await env.settle()
            #expect(try await env.item(rows[2].id).status == .merged)
            #expect(try await env.item(rows[2].id).paperID == atlas)
            card = try await env.message(message.id)
            #expect(card.state == .merged)
            #expect(try await env.db.livePapers().count == 4)
        }
    }

    @Test func duplicatesAndSameWorkLinkInsteadOfParking() async throws {
        try await Kit.run { env in
            let bytes = Kit.pdfData(title: "Eubiota agentic AI", doi: "10.64898/2026.02.27.708412")
            let src = env.root.appendingPathComponent("eubiota.pdf")
            try bytes.write(to: src)
            let existingID = try #require(await env.engine.intake.ingest([.file(src)], options: ImportOptions(origin: .drop)).added.first)
            await env.settle()
            let before = try await env.paper(existingID)
            env.events.clear()

            // Same bytes attached; then another file of the same work (old bioRxiv prefix).
            let (message, items) = try await Kit.insert(env, Kit.message(kind: .person), items: [
                Kit.item(1), Kit.item(2, relevance: .highlighted),
            ], attachments: [0: bytes, 1: Kit.pdfData(title: "Eubiota v2", doi: "10.1101/2026.02.27.708412")])
            let options = MailMergeOptions(priority: .high, pinDeadline: Kit.day(2026, 10, 9), readWithAI: false)
            #expect(try await env.engine.mergeMailItem(itemID: items[0].id, options: options) == existingID)
            #expect(try await env.engine.mergeMailItem(itemID: items[1].id, options: options) == existingID)
            await env.settle()

            #expect(await env.engine.intake.pendingIDs().isEmpty)
            #expect(!env.events.toasts.contains { $0.buttons.contains { if case .replaceKeepingChecklist = $0.action { true } else { false } } })
            #expect(env.events.batches.flatMap(\.items).map(\.linked) == [true, true])
            #expect(try await env.db.livePapers().count == 1)
            let p = try await env.paper(existingID)
            #expect(p.sha256 == before.sha256)                                   // the library copy stays
            #expect(p.priority == .high && p.deadline == Kit.day(2026, 10, 9) && p.scheduleMode == .pinned)
            #expect(try await env.db.paperSources(paperPK: p.pk).count == 1)    // one row per email
            let rows = try await env.db.mailItems(messagePK: message.pk)
            #expect(rows.allSatisfy { $0.status == .linked && $0.paperID == existingID && $0.pdfPath == nil })
            #expect(try await env.message(message.id).state == .merged)
        }
    }

    @Test func needsPDFRowThenAttachedPDFMerges() async throws {
        // Move mode must never trash a file dropped on an email row.
        try await Kit.run(Kit.settings(importMode: .move)) { env in
            let (message, items) = try await Kit.insert(env, Kit.message(kind: .person), items: [
                Kit.item(1, origin: .link, pdf: .needsPDF, title: "Spatial atlas", doi: "10.1016/j.cell.2025.02.002"),
            ])
            await #expect(throws: MailOperationError.needsPDF(itemID: items[0].id)) {
                try await env.engine.mergeMailItem(itemID: items[0].id, options: MailMergeOptions())
            }
            let file = try Kit.writeUserPDF(env, name: "atlas.pdf", title: "Spatial atlas", doi: "10.1016/j.cell.2025.02.002")
            let id = try #require(try await env.engine.attachPDFToMailItem(itemID: items[0].id, file: file))
            await env.settle()
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(try await env.item(items[0].id).status == .merged)
            #expect(try await env.message(message.id).state == .merged)
            #expect(try await env.db.paperSources(paperPK: try await env.paper(id).pk).first?.mailMessageID == message.id)
            // A link row from a person (not an attachment) is not held as unpublished.
            #expect(try await env.paper(id).aiNote != ImportAnnotation.unpublishedHoldNote)
        }
    }

    @Test func notAPDFAttachmentLeavesTheRowWaiting() async throws {
        try await Kit.run { env in
            let (message, items) = try await Kit.insert(env, Kit.message(kind: .person), items: [Kit.item(1)],
                                                        attachments: [0: Data("<html>not a pdf</html>".utf8)])
            #expect(try await env.engine.mergeMailItem(itemID: items[0].id, options: MailMergeOptions()) == nil)
            await env.settle()
            let row = try await env.item(items[0].id)
            #expect(row.status == .pending && row.pdfState == .needsPDF && row.pdfPath == nil)
            #expect(row.downloadError == "Not a PDF")
            #expect(try await env.message(message.id).state == .pending)
            #expect(try await env.db.livePapers().isEmpty)
        }
    }

    @Test func downloadSucceedsOrMarksTheRowNeedsPDF() async throws {
        try await Kit.run { env in
            env.downloader.route("https://arxiv.org/pdf/2606.24530",
                                 .init(status: 200, mime: "application/pdf", body: Kit.pdfData(title: "NatureBench")))
            env.downloader.route("https://www.biorxiv.org/content/10.1101/2026.09.14.612345v1.full.pdf",
                                 .init(status: 403, mime: "text/html", body: Data("<html>cf</html>".utf8)))
            env.downloader.route("https://example.org/paper.pdf",
                                 .init(status: 200, mime: "text/html", body: Data("<html>login</html>".utf8)))
            let (_, items) = try await Kit.insert(env, Kit.message(kind: .alert), items: [
                Kit.item(1, origin: .alertEntry, pdf: .downloadable, arxiv: "2606.24530",
                         url: "https://arxiv.org/abs/2606.24530v2", host: "arxiv.org"),
                Kit.item(2, origin: .link, pdf: .downloadable, doi: "10.1101/2026.09.14.612345",
                         url: "https://www.biorxiv.org/content/10.1101/2026.09.14.612345v1", host: "www.biorxiv.org"),
                Kit.item(3, origin: .link, pdf: .downloadable, url: "https://example.org/paper.pdf", host: "example.org"),
                Kit.item(4, origin: .citation, pdf: .downloadable, arxiv: "2604.09554", foundBy: .ai),
            ])
            for item in items { try await env.engine.downloadMailItem(itemID: item.id) }

            let ok = try await env.item(items[0].id)
            #expect(ok.pdfState == .hasPDF && ok.downloadError == nil && ok.pdfSHA256 != nil && (ok.pdfBytes ?? 0) > 0)
            #expect(Kit.mailFileExists(env, ok.pdfPath))
            #expect(ok.status == .pending)                                         // downloading never merges

            let blocked = try await env.item(items[1].id)
            #expect(blocked.pdfState == .needsPDF)
            #expect(blocked.downloadError == "bioRxiv refused the automatic download — download it in the browser and drop it here")
            let html = try await env.item(items[2].id)
            #expect(html.pdfState == .needsPDF && html.downloadError == "The link didn't return a PDF")
            let ai = try await env.item(items[3].id)
            #expect(ai.pdfState == .needsPDF && ai.downloadError == "No direct PDF link")
            // Only locally extracted links were fetched — never the AI's.
            #expect(env.downloader.requested.map(\.absoluteString) == [
                "https://arxiv.org/pdf/2606.24530",
                "https://www.biorxiv.org/content/10.1101/2026.09.14.612345v1.full.pdf",
                "https://example.org/paper.pdf",
            ])
            #expect(try await env.db.livePapers().isEmpty)
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: env.paths.incoming.path)) ?? []).isEmpty)

            // Merging the downloaded row imports the stored copy and removes it.
            let id = try #require(try await env.engine.mergeMailItem(itemID: ok.id, options: MailMergeOptions(readWithAI: false)))
            await env.settle()
            let merged = try await env.item(ok.id)
            #expect(merged.status == .merged && merged.paperID == id)
            #expect(!Kit.mailFileExists(env, ok.pdfPath))
        }
    }

    @Test func downloadedBytesAlreadyInTheLibraryMarkTheRowInLibrary() async throws {
        try await Kit.run { env in
            let bytes = Kit.pdfData(title: "Known paper")
            let src = env.root.appendingPathComponent("known.pdf")
            try bytes.write(to: src)
            let existing = try #require(await env.engine.intake.ingest([.file(src)], options: ImportOptions(origin: .drop, ai: .skip)).added.first)
            await env.settle()
            env.downloader.route("https://example.org/known.pdf", .init(status: 200, mime: "application/pdf", body: bytes))
            let (message, items) = try await Kit.insert(env, Kit.message(kind: .person), items: [
                Kit.item(1, origin: .link, pdf: .downloadable, url: "https://example.org/known.pdf", host: "example.org"),
            ])
            #expect(try await env.engine.mergeMailItem(itemID: items[0].id, options: MailMergeOptions()) == existing)
            let row = try await env.item(items[0].id)
            #expect(row.status == .linked && row.paperID == existing && row.pdfPath == nil)
            #expect(try await env.message(message.id).state == .merged)
            #expect(!FileManager.default.fileExists(atPath: env.paths.mailFiles.appendingPathComponent(message.id).path))
        }
    }

    @Test func personAttachmentWithoutIdentifiersIsHeldAsPossiblyUnpublished() async throws {
        try await Kit.run { env in
            let (_, items) = try await Kit.insert(env, Kit.message(kind: .person), items: [Kit.item(1), Kit.item(2)],
                                                  attachments: [0: Kit.pdfData(title: "Draft manuscript, do not share"),
                                                                1: Kit.pdfData(title: "Published one", doi: "10.1038/s41586-024-00001-1")])
            let draft = try #require(try await env.engine.mergeMailItem(itemID: items[0].id, options: MailMergeOptions()))
            let published = try #require(try await env.engine.mergeMailItem(itemID: items[1].id, options: MailMergeOptions()))
            await env.settle()

            let held = try await env.paper(draft)
            #expect(held.aiState == .held && held.aiNote == ImportAnnotation.unpublishedHoldNote)
            #expect(try await env.db.activeJob(paperPK: held.pk)?.state == .held)
            #expect(ImportAnnotation.unpublishedHoldText(.zh) == "可能是未发表稿件 · 解读前请确认")
            #expect(ImportAnnotation.unpublishedHoldText(.en) == "Possibly unpublished — confirm before AI reading")
            let queued = try await env.paper(published)
            #expect(queued.aiState == .queued && queued.aiNote == nil)
            #expect(try await env.db.activeJob(paperPK: queued.pk)?.priority == 0)      // a person, not the advisor
        }
    }

    @Test func mergingMoreThanThreeWithAIHoldsTheBatch() async throws {
        try await Kit.run { env in
            let rows = (1...4).map { Kit.item($0) }
            var files: [Int: Data] = [:]
            for i in 0..<4 { files[i] = Kit.pdfData(title: "Paper \(i)", doi: "10.1038/s41586-024-0000\(i)-1") }
            let (message, _) = try await Kit.insert(env, Kit.message(kind: .alert), items: rows, attachments: files)
            let ids = try await env.engine.mergeAllMailItems(messageID: message.id, options: MailMergeOptions(readWithAI: true))
            await env.settle()
            #expect(ids.count == 4)
            #expect(Set(env.events.batches.last?.heldForAI ?? []) == Set(ids))
            for id in ids { #expect(try await env.paper(id).aiState == .held) }
        }
    }

    @Test func automaticMergesAndDownloadsLeaveTheCardUntouched() async throws {
        try await Kit.run { env in
            env.downloader.route("https://arxiv.org/pdf/2606.24530",
                                 .init(status: 200, mime: "application/pdf", body: Kit.pdfData(title: "NatureBench")))
            let (message, items) = try await Kit.insert(env, Kit.message(kind: .alert, triage: nil), items: [
                Kit.item(1, origin: .alertEntry, relevance: .highlighted, pdf: .downloadable, arxiv: "2606.24530",
                         url: "https://arxiv.org/abs/2606.24530", host: "arxiv.org"),
                Kit.item(2, relevance: .highlighted),
            ], attachments: [1: Kit.pdfData(title: "Attached alert paper")])
            try await env.engine.downloadMailItem(itemID: items[0].id, userAction: false)
            #expect(try await env.item(items[0].id).pdfState == .hasPDF)
            #expect(try await !env.message(message.id).userTouched)
            let ids = try await env.engine.mergeAllMailItems(messageID: message.id, options: MailMergeOptions(readWithAI: false),
                                                             userAction: false)
            await env.settle()
            #expect(ids.count == 2)
            let card = try await env.message(message.id)
            #expect(card.state == .merged && !card.userTouched)

            // A dismissed card is never reopened or completed by automation.
            let (gone, goneItems) = try await Kit.insert(env, Kit.message(kind: .alert, triage: nil, state: .dismissed),
                                                         items: [Kit.item(1)], attachments: [0: Kit.pdfData(title: "Late")])
            _ = try await env.engine.mergeMailItem(itemID: goneItems[0].id, options: MailMergeOptions(readWithAI: false),
                                                   userAction: false)
            #expect(try await env.message(gone.id).state == .dismissed)
            #expect(try await env.item(goneItems[0].id).status == .merged)
        }
    }

    @Test func suggestedOptionsFollowTheSenderRule() {
        let today = Kit.day(2026, 9, 29)
        let settings = Kit.settings(autoRead: false)
        let advisor = Kit.message(kind: .advisor, triage: Kit.triage(due: Kit.day(2026, 10, 2), dueConfidence: 0.9))
        var o = MailMergeOptions.suggested(for: advisor, rule: nil, settings: settings, today: today)
        #expect(o == MailMergeOptions(priority: .high, pinDeadline: Kit.day(2026, 10, 2), category: nil, readWithAI: false))

        let rule = SenderRule(pattern: "prof.x@wustl.edu", kind: .advisor, defaultPriority: .normal,
                              defaultCategory: "Lab", useDueDateAsDDL: false)
        o = MailMergeOptions.suggested(for: advisor, rule: rule, settings: settings, today: today)
        #expect(o == MailMergeOptions(priority: nil, pinDeadline: nil, category: "Lab", readWithAI: false))

        let unsure = Kit.message(kind: .person, triage: Kit.triage(due: Kit.day(2026, 10, 2), dueConfidence: 0.6))
        #expect(MailMergeOptions.suggested(for: unsure, rule: nil, settings: settings, today: today).pinDeadline == nil)
        let past = Kit.message(kind: .person, triage: Kit.triage(due: Kit.day(2026, 9, 20), dueConfidence: 0.9, priority: .high))
        o = MailMergeOptions.suggested(for: past, rule: nil, settings: settings, today: today)
        #expect(o.pinDeadline == nil && o.priority == .high)
        let alert = Kit.message(kind: .alert, triage: Kit.triage(priority: .high))
        #expect(MailMergeOptions.suggested(for: alert, rule: nil, settings: settings, today: today).priority == nil)
    }

    @Test func unknownRowsAndCardsThrowTypedErrors() async throws {
        try await Kit.run { env in
            // An attachment copy cleaned up meanwhile: the row waits for a PDF again.
            let (_, items) = try await Kit.insert(env, Kit.message(), items: [Kit.item(1)],
                                                  attachments: [0: Kit.pdfData(title: "Gone")])
            try FileManager.default.removeItem(at: env.paths.mailFiles.appendingPathComponent(try #require(items[0].pdfPath)))
            await #expect(throws: MailOperationError.fileMissing(itemID: items[0].id)) {
                try await env.engine.mergeMailItem(itemID: items[0].id, options: MailMergeOptions())
            }
            #expect(try await env.item(items[0].id).pdfState == .needsPDF)

            let missing = UUID().uuidString.lowercased()
            await #expect(throws: MailOperationError.itemNotFound(missing)) {
                try await env.engine.mergeMailItem(itemID: missing, options: MailMergeOptions())
            }
            await #expect(throws: MailOperationError.messageNotFound(missing)) {
                try await env.engine.dismissMail(messageID: missing)
            }
            #expect(MailOperationError.needsPDF(itemID: "x").message(.zh) == "还没有 PDF：请下载后拖到这一行")
        }
    }
}
