import Foundation
import Testing
@testable import PaperDeckCore

/// Round 4, r4-2: post-processing's metadata lookups never send the title of an attachment or a
/// candidate of confidential mail to Crossref / OpenAlex / arXiv — not as a title search, not as
/// the fallback of an identifier lookup that found nothing, not when verifying the papers the AI
/// named after the user's 「让 AI 分析」. Identifier lookups (a DOI / arXiv id already in the mail)
/// still run. A person's / advisor's / dropped email keeps its title-only lookups until the user
/// asks for 「让 AI 分析」 (the attachment may be unpublished work). A fake transport records every
/// request; nothing leaves the machine.
@Suite(.serialized) struct R4MetadataGuardTests {
    typealias K = MailSyncKit

    // MARK: The pure rule

    @Test func titlesMayGoOutOnlyForAlertsOrAfterTheUsersRequest() {
        func message(_ kind: SenderKind, subject: String = "Hello", consented: Bool = false) -> MailMessage {
            MailMessage(accountID: "a", internetMessageID: "<\(UUID().uuidString)@x>", fromAddress: "sender@lab.org",
                        senderKind: kind, subject: subject, receivedAt: K.start, bodyText: "Please read the attached paper.",
                        triageConsented: consented, triageConsentProvider: consented ? "claude" : nil)
        }
        #expect(MailSyncActor.mayLookUpTitles(message(.alert, subject: "bioRxiv alert: cortex")))
        #expect(!MailSyncActor.mayLookUpTitles(message(.alert, subject: "Invitation to peer review: NN-A12345")))
        for kind in [SenderKind.advisor, .person, .manual] {
            #expect(!MailSyncActor.mayLookUpTitles(message(kind)), "\(kind)")
            #expect(MailSyncActor.mayLookUpTitles(message(kind, consented: true)), "\(kind) after 让 AI 分析")
            #expect(!MailSyncActor.mayLookUpTitles(message(kind, subject: "Your manuscript was accepted", consented: true)),
                    "\(kind) confidential")
        }
        // Title-only rows are left out of the lookups when titles may not go out.
        let titled = MailItem(id: "t", ord: 1, cand: "c1", origin: .attachment, title: "An unpublished manuscript title")
        let withDOI = MailItem(id: "d", ord: 2, cand: "c2", origin: .link, title: "Published work",
                               ids: PaperIDs(doi: "10.1038/s41586-024-08351-7"))
        #expect(MailSyncActor.lookupTargets([titled, withDOI]).map(\.id) == ["d", "t"])
        #expect(MailSyncActor.lookupTargets([titled, withDOI], titles: false).map(\.id) == ["d"])
    }

    /// A metadata log line names the host and path only — never a title search's query (the title
    /// of an email's attachment) nor an error description that quotes it.
    @Test func metadataLogLinesNeverCarryATitle() throws {
        let search = try #require(MetadataClients.crossrefSearchURL(title: "Unpublished draft on cortical folding",
                                                                    author: "Smith", mailto: "me@wustl.edu"))
        let logged = MetadataResolver.logKey(for: search)
        #expect(logged == "https://api.crossref.org/works?…", "\(logged)")
        #expect(!logged.contains("Unpublished") && !logged.contains("Smith") && !logged.contains("wustl"))
        let work = try #require(MetadataClients.crossrefWorkURL(doi: "10.1038/s41586-024-08351-7", mailto: nil))
        #expect(MetadataResolver.logKey(for: work).contains("10.1038/s41586-024-08351-7"))
        let failure = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: search])
        #expect(String(describing: failure).contains("Unpublished"))       // what used to be logged
        #expect(MetadataResolver.logReason(failure) == "URLError(\(URLError.Code.timedOut.rawValue))")
    }

    // MARK: Confidential mail

    private static let editorRule = SenderRule(id: "rule-editor", pattern: "@journal-office.example.org", label: "Journal",
                                               kind: .person)
    /// The manuscript's own title (what the first page shows) and an unregistered DOI on it.
    private static let manuscriptTitle = "Cortical folding mechanics in a manuscript under review"
    private static let manuscriptDOI = "10.5555/under-review.2026.0042"

    /// The model names the manuscript by title only, plus a published paper by DOI.
    private static let triageAnswer: JSONValue = .object([
        "has_reading_request": .bool(true), "request_kind": .string("advisor_request"),
        "summary": .string("An invitation to review a manuscript."), "requester": .string("Dr. Editor"),
        "due_date": .null, "due_evidence": .null, "priority": .string("normal"),
        "papers": .array([
            .object(["ref": .string("c1"), "title": .null, "doi": .null, "arxiv_id": .null,
                     "relevance": .string("requested"), "why": .string("The manuscript"), "confidence": .number(0.9)]),
            .object(["ref": .null, "title": .string("Cortical folding mechanics: the companion manuscript under review"),
                     "doi": .null, "arxiv_id": .null, "relevance": .string("highlighted"), "why": .string("x"),
                     "confidence": .number(0.6)]),
            .object(["ref": .null, "title": .string("Molecular and cellular dynamics of the developing human neocortex"),
                     "doi": .string("10.1038/s41586-024-08351-7"), "arxiv_id": .null,
                     "relevance": .string("highlighted"), "why": .string("Background"), "confidence": .number(0.7)]),
        ]),
    ])

    @Test func confidentialMailNeverSendsATitle() async throws {
        let recorder = R4.Recorder()
        let provider = K.ScriptedTriage(Self.triageAnswer)
        let mail = K.mailSettings(senders: [K.advisorRule, K.biorxivRule, Self.editorRule])
        try await R4.run(mode: .mock, mail: mail, fetcher: recorder, mock: provider,
                         pdf: K.FakePDF(title: Self.manuscriptTitle, doi: Self.manuscriptDOI)) { env in
            let invite = R4.emlWithPDF(from: "editor@journal-office.example.org", messageID: "<r4-invite@journal-office.example.org>",
                                       subject: "Invitation to review manuscript JN-2026-0042",
                                       body: ["Dear Dr. Jiang,", "Could you review the attached manuscript?"],
                                       pdf: K.realPDF(title: "Manuscript under review"), fileName: "JN-2026-0042.pdf")
            await env.source.add("invite.eml", invite)
            await env.sync()

            let m = try await env.message("<r4-invite@journal-office.example.org>")
            #expect(MailHeuristics.isConfidential(m))
            // The identifier lookup ran (the DOI on the manuscript's first page; nobody knows it) …
            #expect(recorder.requested.contains { $0.contains("api.crossref.org/works/10.5555/under-review.2026.0042") })
            // … but the manuscript's title never left, not even as the fallback of the DOI nobody knows.
            #expect(recorder.titleSearches.isEmpty, "\(recorder.titleSearches)")
            #expect(!recorder.requested.contains { $0.contains("Cortical") || $0.contains("folding") })
            let attachment = try #require(try await env.db.mailItems(messagePK: m.pk).first { $0.origin == .attachment })
            #expect(attachment.title == Self.manuscriptTitle && attachment.metaSource == .pdf)

            // 「让 AI 分析」 on it: the AI result's title-only paper is not searched, the attachment stays
            // held; the DOI the model named is still verified.
            try await env.engine.requestMailAI(messageID: m.id)
            #expect(await K.eventually { try await env.db.mailMessage(pk: m.pk)?.triageState == .done })
            await env.engine.mailTriage.waitForVerification()
            await env.engine.mail.waitUntilIdle()
            #expect(await provider.calls == 1)
            #expect(recorder.titleSearches.isEmpty, "\(recorder.titleSearches)")
            #expect(!recorder.requested.contains { $0.contains("Cortical") || $0.contains("folding") })
            #expect(recorder.requested.contains { $0.contains("api.crossref.org/works/10.1038/s41586-024-08351-7") })
            let rows = try await env.db.mailItems(messagePK: m.pk)
            #expect(rows.contains { $0.foundBy == .ai && $0.ids.doi == "10.1038/s41586-024-08351-7" })
            #expect(!rows.contains { $0.title?.contains("companion manuscript") == true })
        }
    }

    // MARK: A person's attachment

    @Test func anAdvisorsAttachmentTitleWaitsForTheUsersRequest() async throws {
        let recorder = R4.Recorder()
        let title = "Unpublished draft on cortical folding dynamics"
        try await R4.run(mode: .mock, fetcher: recorder, pdf: K.FakePDF(title: title, doi: nil)) { env in
            await env.source.add("advisor.eml", try K.data("advisor-request-pdf"))
            await env.sync()
            let m = try await env.message("<caf3xyz+abc123@mail.gmail.com>")
            #expect(m.senderKind == .advisor && !MailHeuristics.isConfidential(m))
            let attachment = try #require(try await env.db.mailItems(messagePK: m.pk).first { $0.origin == .attachment })
            #expect(attachment.title == title && attachment.ids.isEmpty)
            // Identifier rows (the bioRxiv link) were looked up; the attachment's title was not.
            #expect(recorder.requested.contains { $0.contains("api.biorxiv.org") })
            #expect(!recorder.requested.contains { $0.contains("Unpublished") }, "\(recorder.requested)")
            #expect(recorder.titleSearches.isEmpty, "\(recorder.titleSearches)")

            // The user's 「让 AI 分析」: the held title-only lookup runs now.
            try await env.engine.requestMailAI(messageID: m.id)
            #expect(await K.eventually {
                await env.engine.mail.waitUntilIdle()
                return recorder.titleSearches.contains { $0.contains("Unpublished%20draft%20on%20cortical%20folding%20dynamics") }
            }, "\(recorder.requested)")
        }
    }

    /// A dropped `.eml` (kind `manual`) is held the same way.
    @Test func aDroppedEmailsAttachmentTitleIsHeldToo() async throws {
        let recorder = R4.Recorder()
        try await R4.run(fetcher: recorder, pdf: K.FakePDF(title: "Draft chapter on cortical folding mechanics", doi: nil)) { env in
            let file = env.root.appendingPathComponent("dropped.eml")
            try R4.emlWithPDF(from: "someone@elsewhere.example.org", messageID: "<r4-dropped@elsewhere.example.org>",
                              subject: "Have a look", body: ["Here is my draft."],
                              pdf: K.realPDF(title: "Draft chapter")).write(to: file)
            let ids = await env.engine.mail.importEML([file])
            #expect(ids.count == 1)
            await env.engine.mail.waitUntilIdle()
            let m = try await env.message("<r4-dropped@elsewhere.example.org>")
            #expect(m.senderKind == .manual)
            #expect(try await env.db.mailItems(messagePK: m.pk).contains { $0.origin == .attachment && $0.title != nil })
            #expect(recorder.titleSearches.isEmpty, "\(recorder.titleSearches)")
            #expect(!recorder.requested.contains { $0.contains("Draft") })
        }
    }
}
