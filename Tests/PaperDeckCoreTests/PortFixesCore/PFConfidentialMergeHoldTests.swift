import Foundation
import Testing
@testable import PaperDeckCore

/// Portability verification F13: a confidential email from an alert preset's domain (an editor's
/// "Invitation to review manuscript …" from @*.nature.com) merged by hand used to queue the
/// manuscript for AI reading by default — the unpublished hold covered person senders only. Now
/// the merge suggestions leave 「用 AI 解读」 off for confidential mail, and a merge that asks for
/// it anyway holds the job like a person's possibly unpublished PDF (released only when the paper
/// resolves to a DOI / arXiv id). Generated PDFs, offline, agent mode off.
@Suite struct PFConfidentialMergeHoldTests {
    typealias Kit = MailMergeKit

    static let natureRule = SenderRule(id: "rule-nature", pattern: "@*.nature.com", label: "Nature", kind: .alert)

    static func invitation() -> MailMessage {
        var m = Kit.message(kind: .alert, subject: "Invitation to review manuscript NN-A12345",
                            from: "editor@neuroscience.nature.com", name: "Nature Neuroscience", triage: nil)
        m.ruleID = natureRule.id
        m.bodyText = "Dear Dr Jiang,\nWould you be able to review the attached manuscript?\nBest wishes"
        return m
    }

    static func alertIssue() -> MailMessage {
        var m = Kit.message(kind: .alert, subject: "Nature Neuroscience: new issue", from: "alerts@neuroscience.nature.com",
                            name: "Nature Neuroscience", triage: nil)
        m.ruleID = natureRule.id
        m.bodyText = "New this month in Nature Neuroscience [c1 nature.com]"
        return m
    }

    @Test func theSuggestionLeavesAIReadingOffForConfidentialMail() {
        let settings = Kit.settings(autoRead: true)
        let today = Kit.day(2026, 9, 29)
        let confidential = Self.invitation()
        #expect(MailHeuristics.isConfidential(confidential))
        #expect(!MailMergeOptions.suggested(for: confidential, rule: Self.natureRule, settings: settings, today: today).readWithAI)
        // Ordinary alert mail (and every sender kind's ordinary mail) still follows 「自动解读新论文」.
        #expect(MailMergeOptions.suggested(for: Self.alertIssue(), rule: Self.natureRule, settings: settings, today: today).readWithAI)
        #expect(MailMergeOptions.suggested(for: Kit.message(kind: .advisor), rule: nil, settings: settings, today: today).readWithAI)
        #expect(!MailMergeOptions.suggested(for: Self.alertIssue(), rule: Self.natureRule,
                                            settings: Kit.settings(autoRead: false), today: today).readWithAI)
        // A person's confidential mail too.
        var person = Self.invitation()
        person.senderKind = .person
        #expect(!MailMergeOptions.suggested(for: person, rule: nil, settings: settings, today: today).readWithAI)
    }

    @Test func aConfidentialAlertDomainPDFIsHeldLikeAnUnpublishedOne() async throws {
        try await Kit.run(mail: MailSettings(senders: [Self.natureRule])) { env in
            let (_, items) = try await Kit.insert(env, Self.invitation(), items: [
                Kit.item(1, origin: .attachment, pdf: .hasPDF),
                Kit.item(2, origin: .attachment, pdf: .hasPDF),
            ], attachments: [0: Kit.pdfData(title: "Manuscript under review: cortical folding"),
                             1: Kit.pdfData(title: "Supplementary published work", doi: "10.1038/s41593-024-00007-7")])
            // The user ticks 「用 AI 解读」 anyway: the job is created held, with the unpublished note.
            let held = try #require(try await env.engine.mergeMailItem(itemID: items[0].id, options: MailMergeOptions(readWithAI: true)))
            let identified = try #require(try await env.engine.mergeMailItem(itemID: items[1].id,
                                                                             options: MailMergeOptions(readWithAI: true)))
            await env.settle()
            let p = try await env.paper(held)
            #expect(p.aiState == .held && p.aiNote == ImportAnnotation.unpublishedHoldNote)
            #expect(try await env.db.activeJob(paperPK: p.pk)?.state == .held)
            // Like the person hold: a paper that resolves to a DOI is released.
            let open = try await env.paper(identified)
            #expect(open.aiState == .queued && open.aiNote == nil)
        }
    }

    @Test func aDroppedPDFOnAConfidentialRowGetsNoAIJobByDefault() async throws {
        try await Kit.run(mail: MailSettings(senders: [Self.natureRule])) { env in
            let (_, items) = try await Kit.insert(env, Self.invitation(), items: [Kit.item(1, origin: .link, pdf: .needsPDF)])
            let file = try Kit.writeUserPDF(env, name: "manuscript.pdf", title: "Manuscript under review: radial glia")
            // `attachPDFToMailItem(itemID:file:)` merges with the suggested options.
            let id = try #require(try await env.engine.attachPDFToMailItem(itemID: items[0].id, file: file))
            await env.settle()
            let p = try await env.paper(id)
            #expect(p.aiState == AIState.none)
            #expect(try await env.db.activeJob(paperPK: p.pk) == nil)
        }
    }

    @Test func ordinaryAlertPDFsAreStillReadAsBefore() async throws {
        try await Kit.run(mail: MailSettings(senders: [Self.natureRule])) { env in
            let (_, items) = try await Kit.insert(env, Self.alertIssue(), items: [Kit.item(1, origin: .attachment, pdf: .hasPDF)],
                                                  attachments: [0: Kit.pdfData(title: "A published atlas of the ferret cortex")])
            let id = try #require(try await env.engine.mergeMailItem(itemID: items[0].id, options: MailMergeOptions(readWithAI: true)))
            await env.settle()
            let p = try await env.paper(id)
            #expect(p.aiState == .queued && p.aiNote == nil)
        }
    }
}
