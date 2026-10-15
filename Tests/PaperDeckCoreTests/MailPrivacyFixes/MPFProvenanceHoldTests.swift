import Foundation
import Testing
@testable import PaperDeckCore

/// Mail privacy fixes, mail-ai-privacy-1 (+ its extra 2) and dedupe-batch extra 1: a paper merged
/// from a confidential email whose sender is an alert rule (the default '@*.nature.com' preset: an
/// editor's "Invitation to review manuscript …") used to get `AssistPrivacy.ok` — "Read with AI"
/// starts unticked for such mail, so no job and no hold note — and Explain / Ask sent it without
/// "Send Anyway", `qa.json` kept its answers beside it and batch Re-read sent its full text. Now the
/// email's confidentiality is a privacy input (`AssistPrivacy.Reason.mailConfidential`), and every
/// batch path holds whatever Explain and Ask would confirm first — a person's unidentified PDF
/// without its note too. Generated PDFs, mock backends, no CLI, no network.
@Suite(.timeLimit(.minutes(2))) struct MPFProvenanceHoldTests {
    typealias Kit = MailMergeKit

    static let natureRule = PFConfidentialMergeHoldTests.natureRule

    static func settings(agent: AgentMode = .off) -> EngineSettings {
        var s = Kit.settings(autoRead: true)
        s.assist.mode = .mock
        s.agentMode = agent
        return s
    }

    /// The editor's invitation merged with the suggested options ("Read with AI" unticked).
    static func mergedInvitation(_ env: Kit.Env) async throws -> Paper {
        let invitation = PFConfidentialMergeHoldTests.invitation()
        let (_, items) = try await Kit.insert(env, invitation, items: [Kit.item(1, origin: .attachment, pdf: .hasPDF)],
                                              attachments: [0: Kit.pdfData(title: "Manuscript under review: cortical folding")])
        let options = MailMergeOptions.suggested(for: invitation, rule: Self.natureRule, settings: env.settings.value,
                                                 today: Kit.day(2026, 9, 29))
        #expect(!options.readWithAI)
        let id = try #require(try await env.engine.mergeMailItem(itemID: items[0].id, options: options))
        await env.settle()
        let p = try await env.paper(id)
        #expect(p.aiNote == nil && p.aiState == AIState.none, "no job, no hold note: the case that used to leak")
        #expect(p.ids.doi == nil && p.ids.arxivID == nil)
        return p
    }

    static func qaJSON(_ env: Kit.Env, _ p: Paper) -> URL {
        env.engine.ctx.folderURL(p).appendingPathComponent(QASidecar.fileName)
    }

    @Test func aConfidentialAlertEmailsPaperAsksFirstAndKeepsNoQaJson() async throws {
        try await Kit.run(Self.settings(), mail: MailSettings(senders: [Self.natureRule])) { env in
            let p = try await Self.mergedInvitation(env)
            // Explain, Ask and the judge read this verdict.
            let inputs = try await env.engine.privacyInputs(paperID: p.id)
            #expect(inputs.provenance == [PaperSourceSummary(personSourced: false, identified: false, confidential: true)])
            #expect(try await env.engine.assistPrivacy(paperID: p.id, hostBundleID: nil) == .confirm([.mailConfidential]))
            #expect(try await env.engine.assistPrivacy(paperID: p.id, hostBundleID: "com.apple.mail")
                    == .confirm([.mailConfidential, .messagingHost]))
            #expect(try await env.db.mayRemember(p) == false)

            // A Q&A thread about it: no qa.json beside the manuscript, and a question asks first.
            let qa = await env.engine.qaService()
            let thread = try await env.db.insertQAThread(QAThread(paperIDs: [p.id], title: "t", mode: .fullText,
                                                                  createdAt: env.clock.value))
            try await env.db.insertQAMessage(QAMessage(threadID: thread.id, role: .user, text: "q", createdAt: env.clock.value))
            await env.engine.syncQASidecar(paperID: p.id)
            await qa.flushSidecars()
            #expect(!FileManager.default.fileExists(atPath: Self.qaJSON(env, p).path), "qa.json written beside a confidential manuscript")
            var events: [QAEvent] = []
            for await e in await qa.ask(threadID: thread.id, question: "What is the main claim?", options: QAOptions(),
                                        ticket: .mint(.ask, surface: .qa, now: env.clock.value)) {
                events.append(e)
            }
            #expect(events == [.needsConfirmation([.mailConfidential])], "\(events)")
            #expect(await qa.privacy(paperIDs: [p.id]) == .confirm([.mailConfidential]))
        }
    }

    @Test func batchReadingHoldsAConfidentialEmailsPaper() async throws {
        try await Kit.run(Self.settings(agent: .mock), mail: MailSettings(senders: [Self.natureRule])) { env in
            let p = try await Self.mergedInvitation(env)
            let published = try await env.db.insertPaper(Paper(sha256: String(repeating: "5", count: 64), fileSize: 1,
                                                               ids: PaperIDs(doi: "10.1000/published"), title: "Published",
                                                               folder: "Papers/pub", pdfName: "pub.pdf", originalName: "pub.pdf"))
            // The confirmation sheet's list, Re-read with AI, and Queue Existing Papers.
            #expect(try await env.engine.rereadHolds(paperIDs: [p.id, published.id])
                    == [RereadHeld(paperID: p.id, reason: .confidentialEmail)])
            let out = try await env.engine.requestReread(paperIDs: [p.id, published.id])
            #expect(out.applied == [published.id])
            #expect(out.held == [RereadHeld(paperID: p.id, reason: .confidentialEmail)])
            #expect(try await env.db.activeJob(paperPK: p.pk) == nil, "the batch queued the manuscript")
            let queued = await env.engine.queueExistingPapers([p.pk])
            #expect(queued.released == 0 && queued.held == [RereadHeld(paperID: p.id, reason: .confidentialEmail)])
            #expect(try await env.db.activeJob(paperPK: p.pk) == nil)
        }
    }

    /// Extra 2 / dedupe-batch extra 1: a person's PDF without DOI / arXiv id whose hold note is gone
    /// (merged with "Read with AI" unticked, or the AI queue's ✕) is still held by every batch.
    @Test func aPersonsUnidentifiedPaperWithoutItsNoteIsHeld() async throws {
        try await Kit.run(Self.settings(agent: .mock)) { env in
            let (m, _) = try await env.db.insertMailMessage(
                MailMessage(accountID: "a", internetMessageID: "<mpf-person@lab.example.edu>",
                            fromAddress: "colleague@lab.example.edu", senderKind: .person, subject: "draft",
                            receivedAt: Kit.start, bodyText: "Here is our draft."), items: [])
            let p = try await env.db.insertPaper(Paper(sha256: String(repeating: "6", count: 64), fileSize: 1, title: "Our draft",
                                                       folder: "Papers/draft", pdfName: "draft.pdf", originalName: "draft.pdf"))
            try await env.db.insertPaperSource(paperPK: p.pk, PaperProvenance(mailMessageID: m.id,
                                                                              internetMessageID: m.internetMessageID,
                                                                              addedAt: Kit.start))
            #expect(p.aiNote == nil)
            #expect(try await env.engine.assistPrivacy(paperID: p.id, hostBundleID: nil) == .confirm([.personSourcedNoID]))
            #expect(try await env.engine.rereadHolds(paperIDs: [p.id]) == [RereadHeld(paperID: p.id, reason: .possiblyUnpublished)])
            let out = try await env.engine.requestReread(paperIDs: [p.id])
            #expect(out.applied.isEmpty && out.held == [RereadHeld(paperID: p.id, reason: .possiblyUnpublished)])
            #expect(try await env.db.activeJob(paperPK: p.pk) == nil)
            // Once it resolves to a DOI it is published work: a batch may read it.
            _ = try await env.db.modifyPaper(pk: p.pk) { $0.ids.doi = "10.1000/now-published" }
            #expect(try await env.engine.rereadHolds(paperIDs: [p.id]).isEmpty)
        }
    }
}
