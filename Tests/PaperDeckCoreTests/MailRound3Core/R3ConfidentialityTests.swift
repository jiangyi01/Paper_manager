import Foundation
import Testing
@testable import PaperDeckCore

/// Round 3, r3-1 (safety-7 residual): `isBulk` counts only the list headers, and the
/// confidentiality guard (`MailHeuristics.isConfidential`) keeps manuscript / peer-review /
/// submission system mail away from automatic AI triage and automatic merges, for every sender
/// kind — while 「让 AI 分析」 still works. Zero-quota mock provider; no network.
@Suite(.serialized) struct R3ConfidentialityTests {
    typealias K = MailSyncKit

    private static func confidential(_ subject: String, from: String = "alerts@nature.com", body: String = "") -> Bool {
        MailHeuristics.isConfidential(subject: subject, fromAddress: from, body: body)
    }

    /// The fixture as the capture sees it (parsed, extracted body).
    private static func captured(_ data: Data, kind: SenderKind) throws -> (MailContent, String) {
        let content = try MIMEParser.parse(data, maxAttachmentBytes: 1 << 20)
        let x = MailExtractor.extract(content, senderKind: kind, bodyCap: MailExtractor.defaultBodyCap)
        return (content, x.bodyText)
    }

    // MARK: The pure guard

    @Test func confidentialMailIsRecognizedBySubjectBodyOrSender() {
        // Subject
        #expect(Self.confidential("Invitation to review manuscript NN-A12345"))
        #expect(Self.confidential("Reviewer Invitation: Nature Neuroscience"))
        #expect(Self.confidential("REVIEW REQUEST for Cell Reports"))
        #expect(Self.confidential("Decision on your manuscript NNEURO-123"))
        #expect(Self.confidential("bioRxiv Submission Received", from: "biorxiv@cshl.edu"))
        #expect(Self.confidential("Submission confirmation for BIORXIV/2026/614555", from: "no-reply@biorxiv.org"))
        #expect(Self.confidential("[arXiv] submit/5812345 received", from: "no-reply@arxiv.org"))
        #expect(Self.confidential("Your preprint is in screening", from: "no-reply@medrxiv.org"))
        #expect(Self.confidential("Manuscript ID CELL-REPORTS-D-26-01234"))
        #expect(Self.confidential("Confidential: draft for the grant"))
        // First body lines
        #expect(Self.confidential("Nature Neuroscience", body: "Dear Dr. Jiang,\n\nYour manuscript ID NN-A12345 has been received."))
        #expect(Self.confidential("bioRxiv", from: "no-reply@biorxiv.org",
                                  body: "Hello,\nyour article has passed screening and is now posted."))
        #expect(Self.confidential("arXiv notice", from: "no-reply@arxiv.org",
                                  body: "Our moderators have put your article on hold."))
        #expect(Self.confidential("Re: our paper", from: "a@lab.org", body: "Attached are the reviewers' comments."))
        // Manuscript systems and submission desks by sender
        #expect(Self.confidential("Nature Neuroscience", from: "em.nn.0.8a1b.c2@editorialmanager.com"))
        #expect(Self.confidential("Neuron", from: "onbehalfof@manuscriptcentral.com"))
        #expect(Self.confidential("Neuron", from: "neuron-eo@ejournalpress.com"))
        #expect(Self.confidential("Nature Neuroscience", from: "neuro@mts-nn.nature.com"))
        #expect(Self.confidential("Hello", from: "submissions@biorxiv.org"))
        #expect(Self.confidential("Hello", from: "moderation@arxiv.org"))
        #expect(Self.confidential("Hello", from: "Editorial.Office@cell.com"))

        // Not confidential: alert digests (even about screening), ordinary people's mail, a
        // disclaimer far below the top.
        #expect(!Self.confidential("bioRxiv alert: CRISPR screening", from: "biorxiv@alerts.highwire.org",
                                   body: "New results\nGenome-wide CRISPR screening identifies cortical regulators\nbioRxiv preprint"))
        #expect(!Self.confidential("q-bio daily Subj-class mailing 25 1", from: "no-reply@arxiv.org",
                                   body: "Submissions received from Mon 28 Sep 26 to Tue 29 Sep 26"))
        #expect(!Self.confidential("Nature Neuroscience: Table of contents", from: "alerts@nature.com",
                                   body: "Peer review in neuroscience: a commentary\nScreening of neural organoids"))
        let disclaimer = (1...40).map { "line \($0) of the email about cortex" }.joined(separator: "\n")
            + "\nThis email may contain confidential information."
        #expect(!Self.confidential("Lab meeting", from: "jsmith@wustl.edu", body: disclaimer))
    }

    @Test func theTestFixturesOfRealAlertsAreNotConfidential() throws {
        for (name, kind) in [("biorxiv-alert", SenderKind.alert), ("arxiv-listing", .alert), ("colleague-share", .person),
                             ("advisor-request-pdf", .advisor)] {
            let (content, body) = try Self.captured(try K.data(name), kind: kind)
            #expect(!MailHeuristics.isConfidential(content, bodyText: body), "\(name)")
        }
        for name in ["scholar-alert", "injection-alert", "safelinks-nature", "forwarded-toc"] {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: "eml",
                                                     subdirectory: "Fixtures/mail/mail-parse"))
            let (content, body) = try Self.captured(try Data(contentsOf: url), kind: .alert)
            #expect(!MailHeuristics.isConfidential(content, bodyText: body), "\(name)")
        }
    }

    @Test func captureStateAndSendGateApplyTheGuard() {
        let settings = K.mailSettings()
        let always = K.biorxivRule
        #expect(MailTriageCoordinator.initialState(senderKind: .alert, rule: always, candidates: 3, settings: settings,
                                                   isBulk: true, confidential: true) == .awaitingConsent)
        #expect(MailTriageCoordinator.initialState(senderKind: .alert, rule: always, candidates: 0, settings: settings,
                                                   isBulk: true, confidential: true) == .awaitingConsent)
        #expect(MailTriageCoordinator.initialState(senderKind: .alert, rule: always, candidates: 3, settings: settings,
                                                   isBulk: true, confidential: false) == .queued)
        var never = always
        never.aiPolicy = .never
        #expect(MailTriageCoordinator.initialState(senderKind: .alert, rule: never, candidates: 3, settings: settings,
                                                   isBulk: true, confidential: true) == .none)
        var personAlways = K.colleagueRule
        personAlways.aiPolicy = .always
        #expect(MailTriageCoordinator.initialState(senderKind: .person, rule: personAlways, candidates: 1,
                                                   settings: settings, confidential: true) == .awaitingConsent)

        // The gate re-checks the stored email (rows captured before the guard existed).
        var stored = MailMessage(accountID: "a", internetMessageID: "<x@y>", fromAddress: "biorxiv@alerts.highwire.org",
                                 ruleID: always.id, senderKind: .alert, subject: "Invitation to review: BIO-2026-77",
                                 receivedAt: K.start, bodyText: "Dear reviewer")
        var s2 = settings
        s2.senders = [always]
        #expect(MailTriageCoordinator.permission(stored, settings: s2, provider: .claude) == .needsConsent)
        stored.triageConsented = true
        stored.triageConsentProvider = AIProviderKind.claude.rawValue
        #expect(MailTriageCoordinator.permission(stored, settings: s2, provider: .claude) == .allowed)
        stored.subject = "bioRxiv alert: spatial transcriptomics"
        stored.triageConsented = false
        #expect(MailTriageCoordinator.permission(stored, settings: s2, provider: .claude) == .allowed)
    }

    // MARK: End to end

    private static let submissionRule = SenderRule(id: "rule-biorxiv-org", pattern: "@biorxiv.org", label: "bioRxiv",
                                                   kind: .alert, autoMerge: true, autoDownload: true)

    /// A bioRxiv submission notice: mailing-list headers (so `isBulk` is true), a link and the
    /// manuscript PDF attached — everything an alert rule would otherwise process on its own.
    private static func submissionNotice(_ pdf: Data) -> Data {
        let b64 = pdf.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let lines = [
            "From: bioRxiv <no-reply@biorxiv.org>", "To: yi@wustl.edu",
            "Subject: bioRxiv submission confirmation: BIORXIV/2026/614555",
            "Date: Tue, 29 Sep 2026 14:05:00 -0500", "Message-ID: <submission-614555@biorxiv.org>",
            "List-Unsubscribe: <mailto:unsubscribe@biorxiv.org>", "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"r3b\"", "",
            "--r3b", "Content-Type: text/plain; charset=utf-8", "",
            "Dear author,", "Thank you for submitting your manuscript to bioRxiv.",
            "https://www.biorxiv.org/content/10.1101/2026.09.25.614555v1", "",
            "--r3b", "Content-Type: application/pdf; name=\"manuscript.pdf\"",
            "Content-Disposition: attachment; filename=\"manuscript.pdf\"", "Content-Transfer-Encoding: base64", "",
            b64, "--r3b--", "",
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// A journal editor's reviewer invitation with the manuscript attached, from a person rule the
    /// user set to AI-always + auto-merge (the guard holds for every sender kind).
    private static let editorRule = SenderRule(id: "rule-editor", pattern: "@journal-office.example.org", label: "Journal",
                                               kind: .person, aiPolicy: .always, autoMerge: true, autoDownload: true)

    private static func reviewInvitation(_ pdf: Data) -> Data {
        let b64 = pdf.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let lines = [
            "From: Dr. Editor <editor@journal-office.example.org>", "To: yi@wustl.edu",
            "Subject: Invitation to review manuscript JN-2026-0042",
            "Date: Tue, 29 Sep 2026 15:05:00 -0500", "Message-ID: <invite-0042@journal-office.example.org>",
            "MIME-Version: 1.0", "Content-Type: multipart/mixed; boundary=\"r3i\"", "",
            "--r3i", "Content-Type: text/plain; charset=utf-8", "",
            "Dear Dr. Jiang,", "Could you please read the attached manuscript and let us know whether you can review it?", "",
            "--r3i", "Content-Type: application/pdf; name=\"JN-2026-0042.pdf\"",
            "Content-Disposition: attachment; filename=\"JN-2026-0042.pdf\"", "Content-Transfer-Encoding: base64", "",
            b64, "--r3i--", "",
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    @Test func aConfidentialAlertIsNeitherTriagedNorMergedAutomatically() async throws {
        let mock = MockAgentProvider()
        let mail = K.mailSettings(senders: [K.biorxivRule, Self.submissionRule, Self.editorRule])
        try await K.run(mode: .mock, mail: mail, mock: mock,
                        pdf: K.FakePDF(title: "Cortical progenitor dynamics in the developing human brain")) { env in
            await env.source().add("submission.eml", Self.submissionNotice(K.realPDF(title: "Unposted manuscript")))
            await env.source().add("invite.eml", Self.reviewInvitation(K.realPDF(title: "Manuscript under review")))
            await env.source().add("alert.eml", try K.variant("biorxiv-alert", messageID: "<r3-alert@alerts.highwire.org>"))
            await env.sync()

            // The ordinary alert is triaged automatically; the submission notice is not.
            #expect(await K.eventually { try await env.db.mailMessage(internetMessageID: "<r3-alert@alerts.highwire.org>")?.triageState == .done })
            let notice = try await env.message("<submission-614555@biorxiv.org>")
            #expect(notice.triageState == .awaitingConsent)
            try await Task.sleep(for: .milliseconds(150))
            #expect(await mock.calls == 1)
            let invite = try await env.message("<invite-0042@journal-office.example.org>")
            #expect(invite.triageState == .awaitingConsent)
            // …nor merged: the rules' auto-merge left the attachments waiting, the library is empty.
            #expect(try await env.db.livePapers().isEmpty)
            for m in [notice, invite] {
                let rows = try await env.db.mailItems(messagePK: m.pk)
                #expect(rows.contains { $0.origin == .attachment && $0.status == .pending && $0.pdfState == .hasPDF })
                #expect(try await env.message(m.internetMessageID).state == .pending)
            }
            let requested = try await env.db.mailItems(messagePK: invite.pk).filter { $0.relevance == .requested }
            #expect(!requested.isEmpty)                                         // a merge target, were it allowed

            // The user's click is the consent.
            let card = try #require(try await env.engine.mailCard(id: notice.id))
            #expect(card.canRequestAI)
            #expect(try await env.engine.requestMailAI(messageID: notice.id) == .queued)
            #expect(await K.eventually { try await env.db.mailMessage(internetMessageID: notice.internetMessageID)?.triageState == .done })
            #expect(await mock.calls == 2)
        }
    }

    /// Rows captured as `queued` / `held` before the guard existed are withdrawn by the gate at
    /// the next tick (→ 「让 AI 分析」), never sent.
    @Test func confidentialRowsWaitingFromBeforeTheGuardAreWithdrawn() async throws {
        let mock = MockAgentProvider()
        try await RFAKit.run(mode: .mock, mock: mock) { env in
            let queued = try await RFAKit.insertAlert(env, 1)
            try await env.db.modifyMailMessage(pk: queued.pk) { $0.subject = "Invitation to review manuscript BIO-2026-0001" }
            let held = try await RFAKit.insertAlert(env, 2, state: .held)
            try await env.db.modifyMailMessage(pk: held.pk) {
                $0.subject = "bioRxiv alert"
                $0.bodyText = "Your submission BIORXIV/2026/614556 is being screened."
                $0.triageNotBefore = K.start.addingTimeInterval(-60)
            }
            await env.engine.mail.settingsDidChange()
            #expect(await K.eventually {
                let a = await RFAKit.triageState(env, RFAKit.alertID(1))
                let b = await RFAKit.triageState(env, RFAKit.alertID(2))
                return a == .awaitingConsent && b == .awaitingConsent
            })
            try await Task.sleep(for: .milliseconds(150))
            #expect(await mock.calls == 0)
            #expect(await env.engine.mailTriage.usage().used == 0)
        }
    }
}
