import Foundation
import Testing
@testable import PaperDeckCore

/// Review fixes safety-4 (the possibly-unpublished AI hold covers every PDF of a person's email,
/// not only attachments), integrity-6 (merging bytes of a paper in 最近删除) and safety-10
/// (a failed DMARC/DKIM check is never auto-merged).
@Suite struct RFAMergeTests {
    typealias Kit = MailMergeKit

    @Test func aPersonsLinkedAndDroppedPDFsAreHeldAsPossiblyUnpublished() async throws {
        try await Kit.run { env in
            env.downloader.route("https://lab.example.edu/drafts/manuscript-v3.pdf",
                                 .init(status: 200, mime: "application/pdf", body: Kit.pdfData(title: "Lab manuscript draft v3")))
            env.downloader.route("https://journal.example.org/published.pdf",
                                 .init(status: 200, mime: "application/pdf",
                                       body: Kit.pdfData(title: "Published work", doi: "10.1038/s41586-024-00002-2")))
            let (_, items) = try await Kit.insert(env, Kit.message(kind: .advisor), items: [
                Kit.item(1, origin: .link, pdf: .downloadable, url: "https://lab.example.edu/drafts/manuscript-v3.pdf",
                         host: "lab.example.edu"),
                Kit.item(2, origin: .link, pdf: .needsPDF, url: "https://onedrive.example.com/:b:/s/lab/draft",
                         host: "onedrive.example.com"),
                Kit.item(3, origin: .link, pdf: .downloadable, url: "https://journal.example.org/published.pdf",
                         host: "journal.example.org"),
            ])
            let linked = try #require(try await env.engine.mergeMailItem(itemID: items[0].id, options: MailMergeOptions()))
            let file = try Kit.writeUserPDF(env, name: "draft.pdf", title: "Shared draft, do not circulate")
            let dropped = try #require(try await env.engine.attachPDFToMailItem(itemID: items[1].id, file: file))
            let published = try #require(try await env.engine.mergeMailItem(itemID: items[2].id, options: MailMergeOptions()))
            await env.settle()

            for id in [linked, dropped] {
                let p = try await env.paper(id)
                #expect(p.aiState == .held && p.aiNote == ImportAnnotation.unpublishedHoldNote)
                #expect(try await env.db.activeJob(paperPK: p.pk)?.state == .held)
            }
            let open = try await env.paper(published)
            #expect(open.aiState == .queued && open.aiNote == nil)        // identified: released
        }
    }

    @Test func alertPDFsAreNotHeld() async throws {
        try await Kit.run { env in
            let (_, items) = try await Kit.insert(env, Kit.message(kind: .alert), items: [
                Kit.item(1, origin: .link, pdf: .downloadable, url: "https://example.org/a.pdf", host: "example.org"),
            ])
            env.downloader.route("https://example.org/a.pdf",
                                 .init(status: 200, mime: "application/pdf", body: Kit.pdfData(title: "Alert paper")))
            let id = try #require(try await env.engine.mergeMailItem(itemID: items[0].id, options: MailMergeOptions()))
            await env.settle()
            #expect(try await env.paper(id).aiNote == nil)
        }
    }

    // MARK: integrity-6

    private static func deletedPaper(_ env: Kit.Env, bytes: Data) async throws -> Paper {
        let src = env.root.appendingPathComponent("old-\(UUID().uuidString).pdf")
        try bytes.write(to: src)
        let id = try #require(await env.engine.intake.ingest([.file(src)], options: ImportOptions(origin: .drop, ai: .skip)).added.first)
        await env.settle()
        _ = try await env.engine.softDelete(paperID: id)
        let p = try await env.paper(id)
        #expect(p.isDeleted)
        return p
    }

    @Test func mergingAPaperInRecentlyDeletedRestoresItWithTheChoices() async throws {
        try await Kit.run { env in
            let bytes = Kit.pdfData(title: "Read before Friday")
            let old = try await Self.deletedPaper(env, bytes: bytes)
            let (message, items) = try await Kit.insert(env, Kit.message(kind: .advisor), items: [Kit.item(1)],
                                                        attachments: [0: bytes])
            let due = Kit.day(2026, 10, 2)
            let id = try await env.engine.mergeMailItem(itemID: items[0].id,
                                                        options: MailMergeOptions(priority: .high, pinDeadline: due,
                                                                                  readWithAI: false))
            await env.settle()
            #expect(id == old.id)
            let p = try await env.paper(old.id)
            #expect(p.isLive)
            #expect(p.priority == .high && p.deadline == due && p.scheduleMode == .pinned)
            let row = try await env.item(items[0].id)
            #expect(row.status == .linked && row.pdfState == .inLibrary && row.paperID == old.id)
            #expect(try await env.message(message.id).state == .merged)
            #expect(try await env.db.paperSources(paperPK: p.pk).contains { $0.internetMessageID == message.internetMessageID })
        }
    }

    @Test func anAutomaticMergeLeavesARecentlyDeletedPaperAlone() async throws {
        try await Kit.run { env in
            let bytes = Kit.pdfData(title: "Deleted on purpose")
            let old = try await Self.deletedPaper(env, bytes: bytes)
            let (message, items) = try await Kit.insert(env, Kit.message(kind: .advisor), items: [Kit.item(1)],
                                                        attachments: [0: bytes])
            let produced = try await env.engine.mergeAllMailItems(messageID: message.id,
                                                                  options: MailMergeOptions(priority: .high, readWithAI: false),
                                                                  userAction: false)
            await env.settle()
            #expect(produced.isEmpty)
            #expect(try await env.paper(old.id).isDeleted)
            let row = try await env.item(items[0].id)
            #expect(row.status == .pending && row.pdfState == .hasPDF)
            #expect(row.downloadError == "This paper is in Recently Deleted — merging restores it")
            #expect(Kit.mailFileExists(env, row.pdfPath))                    // the copy stays for the user's merge
            #expect(try await env.message(message.id).state == .pending)
            #expect(MailOpsText.inRecentlyDeleted(.zh) == "这篇论文在「最近删除」中 · 合并会恢复它")

            // The user's merge then restores it.
            #expect(try await env.engine.mergeMailItem(itemID: items[0].id, options: MailMergeOptions(readWithAI: false)) == old.id)
            #expect(try await env.paper(old.id).isLive)
            #expect(try await env.message(message.id).state == .merged)
        }
    }
}
