import Foundation
import Testing
@testable import PaperDeckCore

/// Mail retention (`Maintenance.mailRetention`) and document rows: when a handled card's folder
/// goes, its rows' stored originals go with it and the rows wait for the user's PDF.
@Suite struct DocumentRetentionTests {
    typealias Kit = MailMergeKit

    /// A handled card (handled at `handledAt`) with a Word row and a slides row whose originals
    /// are stored like the sync stores them (`<message id>/<n>.<ext>`).
    private func handledCard(_ env: Kit.Env, state: MailState, handledAt: Date) async throws -> (MailMessage, [MailItem]) {
        var m = Kit.message(kind: .advisor, subject: "Lab manuscript", state: state)
        m.handledAt = handledAt
        let word = MailItem(ord: 1, cand: "c1", origin: .document, title: "Lab manuscript v3", pdfState: .convertible,
                            createdAt: Kit.start, updatedAt: Kit.start, documentFileName: "Lab_manuscript_v3.docx",
                            documentKind: "docx")
        let slides = MailItem(ord: 2, cand: "c2", origin: .document, title: "Talk", pdfState: .openOnly,
                              createdAt: Kit.start, updatedAt: Kit.start, documentFileName: "Talk.pptx", documentKind: "pptx")
        let share = MailItem(ord: 3, cand: "c3", origin: .shareLink, url: "https://contoso-my.sharepoint.com/:w:/g/personal/a/E1",
                             pdfState: .needsPDF, createdAt: Kit.start, updatedAt: Kit.start, shareHost: "sharepoint.com")
        let (saved, rows) = try await Kit.insert(env, m, items: [word, slides, share])
        var out: [MailItem] = []
        for (i, var row) in rows.enumerated() {
            if let kind = row.documentKind, row.origin == .document {
                let rel = "\(saved.id)/\(i + 1).\(kind)"
                let url = env.paths.mailFiles.appendingPathComponent(rel)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try DocKit.zipStub().write(to: url)
                row.documentPath = rel
                row = try await env.db.upsertMailItem(row, now: Kit.start)
            }
            out.append(row)
        }
        return (saved, out)
    }

    @Test func retentionRemovesTheOriginalsAndTheRowsWaitForAPDF() async throws {
        var mail = MailSettings()
        mail.retentionDays = 30
        try await Kit.run(mail: mail) { env in
            let (old, oldRows) = try await handledCard(env, state: .noRequest, handledAt: Kit.start.addingTimeInterval(-31 * 86_400))
            let (recent, recentRows) = try await handledCard(env, state: .dismissed, handledAt: Kit.start.addingTimeInterval(-86_400))
            #expect(oldRows.compactMap(\.documentPath).count == 2 && recentRows.compactMap(\.documentPath).count == 2)

            let report = try await Maintenance(engine: env.engine, trash: { _ in false }).mailRetention()
            #expect(report.removedFiles == 2)

            // The old card: folder and originals gone, the rows say "needs a PDF" (no Convert / Open).
            #expect(!FileManager.default.fileExists(atPath: env.paths.mailFiles.appendingPathComponent(old.id).path))
            for row in oldRows {
                let after = try await env.item(row.id)
                #expect(after.documentPath == nil, "\(row.cand)")
                #expect(after.pdfState == .needsPDF, "\(row.cand)")
                #expect(!MailInboxRules.actions(after).contains(.convertAndMerge))
                #expect(!MailInboxRules.actions(after).contains(.openDocument))
            }
            #expect(MailInboxRules.chip(try await env.item(oldRows[0].id)) == .needsPDF)
            #expect(MailInboxRules.chip(try await env.item(oldRows[2].id)) == .shareLink)   // untouched share row
            // The card handled yesterday keeps its originals and states.
            for row in recentRows where row.origin == .document {
                let after = try await env.item(row.id)
                #expect(after.documentPath == row.documentPath && after.pdfState == row.pdfState)
                #expect(Kit.mailFileExists(env, row.documentPath))
            }
            #expect(try await env.message(recent.id).state == .dismissed)
        }
    }
}
