import Foundation
import Testing
@testable import PaperDeckCore

/// Capture of document / shared-file mail through the real sync pipeline (fake transports), and
/// the one-time re-evaluation of mail captured before this build.
@Suite struct DocumentSyncTests {
    typealias Kit = MailSyncKit

    private func rows(_ env: Kit.Env, _ m: MailMessage) async throws -> [MailItem] {
        try await env.db.mailItems(messagePK: m.pk)
    }

    @Test func theManuscriptMailIsCapturedAsAPendingCardWithItsDocument() async throws {
        let docx = try DocKit.docx(paragraphs: 30)
        try await Kit.run { env in
            await env.source().add("r1", try DocKit.advisorManuscriptEML(messageID: "<m1@wustl.edu>", docx: docx))
            await env.sync()
            let m = try await env.message("<m1@wustl.edu>")
            #expect(m.state == .pending && m.senderKind == .advisor)
            #expect(m.triage?.requestKind == .fyi && m.triageSource == .heuristic)
            #expect(m.triageState == .awaitingConsent)                      // advisor rule asks first: nothing sent to AI
            let items = try await rows(env, m)
            #expect(items.count == 5)
            let doc = try #require(items.first)
            #expect(doc.origin == .document && doc.pdfState == .convertible && doc.status == .pending)
            #expect(doc.documentFileName == "Smith_lab_manuscript_v3.docx" && doc.documentKind == "docx")
            #expect(doc.documentPath == "\(m.id)/1.docx" && doc.pdfPath == nil && doc.pdfBytes == Int64(docx.count))
            #expect(doc.documentSHA256 == FileOps.sha256(of: docx))
            let stored = env.engine.paths.mailFiles.appendingPathComponent(try #require(doc.documentPath))
            #expect(try Data(contentsOf: stored) == docx)
            #expect((try? stored.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties != nil)
            let shares = items.dropFirst()
            #expect(shares.allSatisfy { $0.origin == .shareLink && $0.pdfState == .needsPDF && $0.shareHost == "sharepoint.com" })
            // Nothing was downloaded, nothing went to AI; the snapshot counts the shared files as waiting.
            #expect(MailInboxRules.chip(doc) == .convertible)
            let card = MailCard(message: m, items: items, rule: Kit.advisorRule, account: nil)
            #expect(card.needsPDFCount == 4 && card.readyCount == 1)
        }
    }

    @Test func storageFollowsTheSenderRuleAndTheSizeCap() async throws {
        var noSave = Kit.advisorRule
        noSave.autoDownload = false
        let big = DocKit.zipStub() + Data((0..<(1_500_000)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var mail = Kit.mailSettings(senders: [noSave, Kit.colleagueRule])
        mail.maxAttachmentMB = 1
        try await Kit.run(mail: mail) { env in
            await env.source().add("r1", DocKit.eml(from: "jsmith@wustl.edu", messageID: "<nosave@wustl.edu>",
                                                     attachments: [.init(name: "draft.docx", type: DocKit.docxType,
                                                                         data: try DocKit.docx(paragraphs: 3))]))
            await env.source().add("r2", DocKit.eml(from: "postdoc@wustl.edu", messageID: "<big@wustl.edu>",
                                                     attachments: [.init(name: "talk.pptx", type: DocKit.pptxType, data: big)]))
            await env.source().add("r3", DocKit.eml(from: "postdoc@wustl.edu", messageID: "<locked@wustl.edu>",
                                                     attachments: [.init(name: "locked.docx", type: DocKit.docxType,
                                                                         data: DocKit.encryptedDocx())]))
            await env.source().add("r4", DocKit.eml(from: "postdoc@wustl.edu", messageID: "<slides@wustl.edu>",
                                                     attachments: [.init(name: "talk.pptx", type: DocKit.pptxType,
                                                                         data: DocKit.zipStub())]))
            await env.sync()
            let nosave = try #require(try await rows(env, try await env.message("<nosave@wustl.edu>")).first)
            #expect(nosave.pdfState == .needsPDF && nosave.documentPath == nil)
            #expect(nosave.downloadError == MailSyncText.documentNotStored(.en))
            let bigRow = try #require(try await rows(env, try await env.message("<big@wustl.edu>")).first)
            #expect(bigRow.pdfState == .needsPDF && bigRow.documentPath == nil)
            #expect(bigRow.downloadError?.contains("(limit 1 MB)") == true)
            let locked = try #require(try await rows(env, try await env.message("<locked@wustl.edu>")).first)
            #expect(locked.pdfState == .openOnly && locked.documentPath != nil)
            #expect(locked.downloadError == DocumentConversionError.encrypted.message(.en))
            let slides = try #require(try await rows(env, try await env.message("<slides@wustl.edu>")).first)
            #expect(slides.pdfState == .openOnly && slides.documentKind == "pptx" && slides.downloadError == nil)
            #expect(MailInboxRules.chip(slides) == .openOnly)
            // Every card from a person with a document is in 待处理.
            for id in ["<nosave@wustl.edu>", "<big@wustl.edu>", "<locked@wustl.edu>", "<slides@wustl.edu>"] {
                #expect(try await env.message(id).state == .pending, "\(id)")
            }
        }
    }

    // MARK: - One-time re-evaluation

    /// A card as an earlier build left it: in 「无阅读需求」, no rows, a local triage of "no paper".
    private func oldCard(_ id: String, ref: String, from: String = "jsmith@wustl.edu", kind: SenderKind = .advisor,
                         state: MailState = .noRequest, touched: Bool = false) -> MailMessage {
        MailMessage(accountID: "acct-a", sourceRef: ref, internetMessageID: id, fromAddress: from, fromName: "Prof. Smith",
                    ruleID: kind == .advisor ? Kit.advisorRule.id : Kit.colleagueRule.id, senderKind: kind,
                    subject: "Lab manuscript draft", receivedAt: Kit.start.addingTimeInterval(-86_400),
                    snippet: "Here is the latest draft", bodyText: "Here is the latest draft [link gowustl-my.sharepoint.com]",
                    state: state, userTouched: touched, triageState: .awaitingConsent, triageSource: .heuristic,
                    triage: MailTriage(hasReadingRequest: false, requestKind: .notPaper, summary: "No paper-reading request found.",
                                       priority: .low, confidence: 0.15),
                    createdAt: Kit.start.addingTimeInterval(-86_000), updatedAt: Kit.start.addingTimeInterval(-86_000),
                    handledAt: state == .noRequest ? Kit.start.addingTimeInterval(-86_000) : nil)
    }

    private func started(_ mail: MailSettings = Kit.mailSettings(), _ body: (Kit.Env) async throws -> Void) async throws {
        let env = try await Kit.make(mail: mail, start: false)
        do {
            try await body(env)
        } catch {
            await env.cleanup()
            throw error
        }
        await env.cleanup()
    }

    @Test func mailCapturedBeforeTheUpgradeIsReevaluatedOnce() async throws {
        try await started { env in
            let eml = try DocKit.advisorManuscriptEML(messageID: "<old1@wustl.edu>")
            await env.source().add("r1", eml)
            let touched = DocKit.eml(messageID: "<old2@wustl.edu>",
                                     attachments: [.init(name: "b.docx", type: DocKit.docxType, data: try DocKit.docx(paragraphs: 1))])
            await env.source().add("r2", touched)
            _ = try await env.db.insertMailMessage(oldCard("<old1@wustl.edu>", ref: "r1"), items: [])
            _ = try await env.db.insertMailMessage(oldCard("<old2@wustl.edu>", ref: "r2", touched: true), items: [])
            await env.engine.start()
            await env.sync()

            let m = try await env.message("<old1@wustl.edu>")
            #expect(m.state == .pending && m.handledAt == nil && !m.userTouched)
            #expect(m.triage?.requestKind == .fyi && m.triageSource == .heuristic)
            #expect(m.triageState == .awaitingConsent)
            let items = try await rows(env, m)
            #expect(items.map(\.origin) == [.document, .shareLink, .shareLink, .shareLink, .shareLink])
            #expect(items.map(\.cand) == ["c1", "c2", "c3", "c4", "c5"])
            #expect(items[0].pdfState == .convertible && items[0].documentPath == "\(m.id)/1.docx")
            #expect(m.bodyText?.contains("[c2 gowustl-my.sharepoint.com]") == true)   // body markers name the rows
            // The card the user touched is left alone.
            let t = try await env.message("<old2@wustl.edu>")
            let untouchedRows = try await rows(env, t)
            #expect(t.state == .noRequest && untouchedRows.isEmpty)
            #expect(try await env.db.kv(MailSyncActor.reevaluateDocumentsKey) == "done")

            // Idempotent: running it again changes nothing.
            let again = await env.engine.mail.reevaluateDocuments(env.mail.value)
            #expect(again.examined == 0 && again.updated == 0)
            await env.sync()
            #expect(try await rows(env, m).count == 5)
        }
    }

    @Test func unreachableSourcesAreRetriedAndGoneOnesSkipped() async throws {
        try await started { env in
            await env.source().add("r1", try DocKit.advisorManuscriptEML(messageID: "<flaky@wustl.edu>"))
            await env.source().add("r2", try DocKit.advisorManuscriptEML(messageID: "<gone@wustl.edu>"))
            _ = try await env.db.insertMailMessage(oldCard("<flaky@wustl.edu>", ref: "r1"), items: [])
            _ = try await env.db.insertMailMessage(oldCard("<gone@wustl.edu>", ref: "r2"), items: [])
            await env.source().failFetch("r1", times: 1)
            await env.source().vanish("r2")
            await env.engine.start()
            await env.sync()
            #expect(try await env.message("<flaky@wustl.edu>").state == .noRequest)
            #expect(try await env.db.kv(MailSyncActor.reevaluateDocumentsKey) == "tries=1")
            await env.sync()
            #expect(try await env.message("<flaky@wustl.edu>").state == .pending)
            #expect(try await env.message("<gone@wustl.edu>").state == .noRequest)
            #expect(try await env.db.kv(MailSyncActor.reevaluateDocumentsKey) == "done")
        }
    }

    @Test func onlyAllowlistedPeoplesUntouchedCardsAreEligible() async throws {
        let mail = Kit.mailSettings()
        let base = oldCard("<x@wustl.edu>", ref: "r1")
        #expect(MailSyncActor.isReevaluationCandidate(base, items: [], settings: mail))
        var pendingEmpty = base; pendingEmpty.state = .pending
        #expect(MailSyncActor.isReevaluationCandidate(pendingEmpty, items: [], settings: mail))
        let link = MailItem(ord: 1, cand: "c1", origin: .link)
        #expect(!MailSyncActor.isReevaluationCandidate(pendingEmpty, items: [link], settings: mail))   // a pending card with rows
        #expect(MailSyncActor.isReevaluationCandidate(base, items: [link], settings: mail))           // no-request with rows: yes
        let doc = MailItem(ord: 1, cand: "c1", origin: .document)
        #expect(!MailSyncActor.isReevaluationCandidate(base, items: [doc], settings: mail))           // already done
        var touched = base; touched.userTouched = true
        #expect(!MailSyncActor.isReevaluationCandidate(touched, items: [], settings: mail))
        var alert = base; alert.senderKind = .alert
        #expect(!MailSyncActor.isReevaluationCandidate(alert, items: [], settings: mail))
        var manual = base; manual.accountID = MailSyncActor.manualAccountID
        #expect(!MailSyncActor.isReevaluationCandidate(manual, items: [], settings: mail))
        var noRef = base; noRef.sourceRef = nil
        #expect(!MailSyncActor.isReevaluationCandidate(noRef, items: [], settings: mail))
        var dismissed = base; dismissed.state = .dismissed
        #expect(!MailSyncActor.isReevaluationCandidate(dismissed, items: [], settings: mail))
        var stranger = base; stranger.fromAddress = "someone@gmail.com"
        #expect(!MailSyncActor.isReevaluationCandidate(stranger, items: [], settings: mail))       // not on the sender list
    }

    /// A card that already has rows gains the new ones after them; its body stays.
    @Test func rowsAreAppendedToACardThatHasSome() async throws {
        try await started { env in
            await env.source().add("r1", try DocKit.advisorManuscriptEML(messageID: "<rows@wustl.edu>"))
            let old = MailItem(ord: 1, cand: "c1", origin: .link, url: "https://example.org/x", pdfState: .needsPDF,
                               createdAt: Kit.start, updatedAt: Kit.start)
            _ = try await env.db.insertMailMessage(oldCard("<rows@wustl.edu>", ref: "r1"), items: [old])
            await env.engine.start()
            await env.sync()
            let m = try await env.message("<rows@wustl.edu>")
            let items = try await rows(env, m)
            #expect(items.map(\.cand) == ["c1", "c2", "c3", "c4", "c5", "c6"])
            #expect(items.map(\.ord) == [1, 2, 3, 4, 5, 6])
            #expect(items.first?.origin == .link && items[1].origin == .document)
            #expect(m.bodyText == "Here is the latest draft [link gowustl-my.sharepoint.com]")
            #expect(m.state == .pending)
        }
    }

    /// Accounts not checked since launch (manual-only sync): the job waits without counting a try.
    @Test func waitsForTheFirstSyncOfItsAccount() async throws {
        try await started { env in
            await env.source().add("r1", try DocKit.advisorManuscriptEML(messageID: "<wait@wustl.edu>"))
            _ = try await env.db.insertMailMessage(oldCard("<wait@wustl.edu>", ref: "r1"), items: [])
            let report = await env.engine.mail.reevaluateDocuments(env.mail.value)
            #expect(report.notYet == 1 && report.examined == 0 && report.failed == 0)
            #expect(try await env.db.kv(MailSyncActor.reevaluateDocumentsKey) == nil)
        }
    }

    /// A real watched folder: the job re-reads the stored file name.
    @Test func aFolderAccountsEmlIsReadAgain() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pd-docs-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Lab manuscript draft.eml")
        try DocKit.advisorManuscriptEML(messageID: "<folder@wustl.edu>").write(to: file)
        // Written "a minute ago" so the folder source's settle window has passed.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: file.path)
        var mail = Kit.mailSettings(accounts: [MailAccount(id: "acct-f", kind: .folder, displayName: "Exports", folderPath: folder.path)])
        mail.syncMinutes = 0
        let env = try await Kit.make(mail: mail, accounts: ["acct-f"], realSources: true)
        do {
            await env.sync()
            let m = try await env.message("<folder@wustl.edu>")
            #expect(m.sourceRef == "Lab manuscript draft.eml")
            #expect(try await rows(env, m).count == 5)
            // Make it look like an earlier build's card, then run the job on it.
            try await env.db.transaction { db in
                for row in try db.mailItems(messagePK: m.pk) { try db.deleteMailItem(id: row.id) }
                try db.modifyMailMessage(pk: m.pk) { $0.state = .noRequest }
            }
            let report = await env.engine.mail.reevaluateDocuments(env.mail.value)
            #expect(report.updated == 1 && report.failed == 0)
            #expect(try await rows(env, m).count == 5)
            #expect(try await env.message("<folder@wustl.edu>").state == .pending)
            // The file is gone → skipped for good.
            try FileManager.default.removeItem(at: folder.appendingPathComponent("Lab manuscript draft.eml"))
            try await env.db.transaction { db in
                for row in try db.mailItems(messagePK: m.pk) { try db.deleteMailItem(id: row.id) }
                try db.modifyMailMessage(pk: m.pk) { $0.state = .noRequest }
            }
            let gone = await env.engine.mail.reevaluateDocuments(env.mail.value)
            #expect(gone.gone == 1 && gone.updated == 0)
        } catch {
            await env.cleanup()
            throw error
        }
        await env.cleanup()
    }
}
