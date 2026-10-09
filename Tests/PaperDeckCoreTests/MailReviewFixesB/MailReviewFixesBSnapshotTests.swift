import Foundation
import Testing
@testable import PaperDeckCore

/// The inbox read model after the review fixes: language switches reach stored machine text and
/// account statuses (runtime-7); an unchanged inbox reads as an equal snapshot (runtime-8).
@Suite(.serialized) struct MailReviewFixesBSnapshotTests {
    typealias K = MailSyncKit

    @Test func aLanguageSwitchRewordsStoredMachineTextAndTheFolderStatus() async throws {
        let root = try RFB.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("PaperDeck Mail", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let alert = folder.appendingPathComponent("alert.eml")
        try K.data("biorxiv-alert").write(to: alert)
        // An advisor's attachment over the 1 MB cap: its row keeps a download error.
        let big = Data("%PDF-1.4\n".utf8) + Data(repeating: 0x41, count: 1_500_000) + Data("\n%%EOF\n".utf8)
        let bigFile = folder.appendingPathComponent("big.eml")
        try MailSyncPipelineTests.emlWithAttachment(big, from: "jsmith@wustl.edu", messageID: "<rt7-big@wustl.edu>").write(to: bigFile)
        for f in [alert, bigFile] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: f.path)
        }
        let account = MailAccount(id: "pa", kind: .folder, displayName: "PA", lookbackDays: 14, folderPath: folder.path)
        var mail = RFB.settings(accounts: [account], aiMode: .heuristicOnly)
        mail.maxAttachmentMB = 1
        let env = try await RFB.make(root: root.appendingPathComponent("lib", isDirectory: true), mail: mail)
        do {
            await env.sync()
            var snap = try await env.engine.mailSnapshot()
            let alertCard = try #require(snap.cards(.pending).first { $0.message.senderKind == .alert })
            let enSummary = try #require(alertCard.message.triage?.summary)
            #expect(enSummary.hasPrefix("Alert digest with"))
            let bigCard = try #require(snap.cards(.pending).first { $0.message.internetMessageID == "<rt7-big@wustl.edu>" })
            #expect(bigCard.items.first { $0.origin == .attachment }?.downloadError?.contains("limit 1 MB") == true)
            #expect(snap.accounts.first?.status == .ready(detail: "Watching “PaperDeck Mail” · 2 emails"))

            env.settings.update { $0.lang = .zh }
            snap = try await env.engine.mailSnapshot()
            let zhAlert = try #require(snap.card(id: alertCard.id))
            #expect(zhAlert.message.triage?.summary.hasPrefix("论文提醒：共") == true)
            #expect(zhAlert.message.subject == alertCard.message.subject)
            let zhBig = try #require(snap.card(id: bigCard.id))
            #expect(zhBig.items.first { $0.origin == .attachment }?.downloadError?.contains("超过 1 MB 上限") == true)
            let detail = try #require(try await env.engine.mailCard(id: bigCard.id))
            #expect(detail.items.first { $0.origin == .attachment }?.downloadError?.contains("超过 1 MB 上限") == true)
            // The stored rows are unchanged (worded at display time only).
            #expect(try await env.db.mailMessage(id: alertCard.id)?.triage?.summary == enSummary)
            // The source is rebuilt in the new language (no settings edit, no relaunch, no sync).
            #expect(await RFB.eventually {
                (try? await env.engine.mailSnapshot())?.accounts.first?.status == .ready(detail: "正在监视「PaperDeck Mail」· 2 封邮件")
            })
            #expect(snap.accounts.first?.kind == .folder)
        } catch {
            await env.close(removeRoot: false)
            throw error
        }
        await env.close(removeRoot: false)
    }

    @Test func anUnchangedInboxReadsAsAnEqualSnapshot() async throws {
        let src = RFB.LedgerSource(accountID: "acct-f")
        // Local rules only: nothing changes behind the test's back (no triage lane).
        try await RFB.run(mail: RFB.settings(accounts: [RFB.fakeAccount()], aiMode: .heuristicOnly),
                          sources: { $0.id == "acct-f" ? src : nil }) { env in
            await src.add("alert.eml", try K.data("biorxiv-alert"))
            await env.sync()
            let a = try await env.engine.mailSnapshot()
            env.advance(90)
            let b = try await env.engine.mailSnapshot()
            #expect(a.generatedAt != b.generatedAt)
            #expect(a == b)
            await src.add("adv.eml", try K.data("advisor-request-pdf"))
            await env.sync()
            let c = try await env.engine.mailSnapshot()
            #expect(c != b)
        }
    }
}
