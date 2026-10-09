import Foundation
import Testing
@testable import PaperDeckCore

/// Round 5 (c): merging an attachment whose email may not send titles out (confidential mail, or a
/// person's / alert domain's non-list email before 「让 AI 分析」) never triggers a title search
/// in the library either: the new paper is flagged `titleLookupHeld` — enrichment looks up its
/// identifiers only, even on "Refresh Metadata" — until the user picks "Look up metadata online"
/// (`Engine.lookUpMetadataOnline`). A fake transport records every request; no CLI runs.
@Suite(.serialized) struct R5MergeEnrichTests {
    typealias K = MailSyncKit
    static let editorRule = SenderRule(id: "rule-editor", pattern: "@journal-office.example.org", label: "Journal", kind: .person)
    static let manuscript = "Cortical folding mechanics in a manuscript under review"

    /// One email with a real PDF attachment whose first page names `title`, merged by hand.
    static func mergeOne(_ env: R4.Env, from: String, messageID: String, subject: String, body: [String],
                         title: String, extraHeaders: [String] = []) async throws -> (MailMessage, Paper) {
        let eml = R4.emlWithPDF(from: from, messageID: messageID, subject: subject, body: body,
                                pdf: K.realPDF(title: title), extraHeaders: extraHeaders)
        await env.source.add(messageID + ".eml", eml)
        await env.sync()
        let m = try await env.message(messageID)
        let attachment = try #require(try await env.db.mailItems(messagePK: m.pk).first { $0.origin == .attachment })
        let merged = try await env.engine.mergeMailItem(itemID: attachment.id, options: MailMergeOptions(readWithAI: false))
        await env.engine.enrich.waitUntilIdle()
        let paperID = try #require(merged)
        let paper = try #require(try await env.db.paper(id: paperID))
        return (m, paper)
    }

    @Test func aConfidentialAttachmentIsLookedUpByIdentifiersOnly() async throws {
        let recorder = R4.Recorder()
        let mail = K.mailSettings(senders: [K.advisorRule, Self.editorRule])
        try await R4.run(mail: mail, fetcher: recorder, pdf: K.FakePDF(title: Self.manuscript, doi: nil)) { env in
            let (m, paper) = try await Self.mergeOne(env, from: "editor@journal-office.example.org", messageID: "<r5-merge-1@x>",
                                                     subject: "Invitation to review manuscript JN-2026-0042",
                                                     body: ["Dear Dr Jiang,", "Please see the attached manuscript."],
                                                     title: Self.manuscript)
            #expect(MailHeuristics.isConfidential(m))
            #expect(paper.flags.contains(.titleLookupHeld))
            #expect(paper.title.contains("Cortical folding"))
            #expect(recorder.titleSearches.isEmpty, "\(recorder.titleSearches)")
            #expect(!recorder.requested.contains { $0.contains("Cortical") })
            // "Refresh Metadata" keeps to identifiers too.
            _ = try await env.engine.refreshMetadata(paperID: paper.id)
            #expect(recorder.titleSearches.isEmpty, "\(recorder.titleSearches)")
            // The flag travels with the card (a rebuilt library keeps it).
            await env.engine.ctx.sidecars.flush()
            let card = try Data(contentsOf: env.engine.ctx.folderURL(paper).appendingPathComponent(CardSidecar.fileName))
            #expect(try CardSidecar.decoded(from: card).toModels(folder: paper.folder, fallbackDate: K.start)
                .paper.flags.contains(.titleLookupHeld))
            // The user's explicit "Look up metadata online": the flag goes, the title search runs.
            _ = try await env.engine.lookUpMetadataOnline(paperID: paper.id)
            #expect(try await env.db.paper(id: paper.id)?.flags.contains(.titleLookupHeld) == false)
            #expect(recorder.titleSearches.contains { $0.contains("Cortical%20folding") }, "\(recorder.requested)")
        }
    }

    @Test func aPersonsAttachmentIsHeldUntilTheUsersRequest() async throws {
        let recorder = R4.Recorder()
        let colleague = SenderRule(id: "rule-colleague", pattern: "@lab.example.org", label: "Lab", kind: .person)
        let mail = K.mailSettings(senders: [K.advisorRule, colleague])
        let title = "Draft chapter on radial glia lineage tracing"
        try await R4.run(mail: mail, fetcher: recorder, pdf: K.FakePDF(title: title, doi: nil)) { env in
            let (m, paper) = try await Self.mergeOne(env, from: "amy@lab.example.org", messageID: "<r5-merge-2@x>",
                                                     subject: "My draft", body: ["Here is my draft chapter."], title: title)
            #expect(!MailHeuristics.isConfidential(m) && !m.triageConsented)
            #expect(paper.flags.contains(.titleLookupHeld))
            #expect(recorder.titleSearches.isEmpty, "\(recorder.titleSearches)")
        }
    }

    @Test func aDigestsAttachmentIsLookedUpAsBefore() async throws {
        let recorder = R4.Recorder()
        let cellRule = SenderRule(id: "rule-cell", pattern: "@cell.com", label: "Cell Press", kind: .alert)
        let mail = K.mailSettings(senders: [K.advisorRule, cellRule])
        let title = "Published atlas of the developing ferret cortex"
        try await R4.run(mail: mail, fetcher: recorder, pdf: K.FakePDF(title: title, doi: nil)) { env in
            let (m, paper) = try await Self.mergeOne(env, from: "alerts@cell.com", messageID: "<r5-merge-3@cell.com>",
                                                     subject: "Cell Press: new issue", body: ["New this week in Neuron."],
                                                     title: title, extraHeaders: ["List-Unsubscribe: <mailto:u@cell.com>"])
            #expect(MailSyncActor.mayLookUpTitles(m))
            #expect(!paper.flags.contains(.titleLookupHeld))
            #expect(recorder.titleSearches.contains { $0.contains("ferret") }, "\(recorder.requested)")
        }
    }

    @Test func theAnnotationCarriesTheMessagesRule() {
        #expect(!ImportAnnotation().identifierLookupsOnly)
        #expect(ImportAnnotation(identifierLookupsOnly: true).identifierLookupsOnly)
        #expect(PaperFlags.titleLookupHeld.rawValue == 16)
        #expect(PaperFlags([.missing, .titleLookupHeld]).rawValue == 24)
    }
}
