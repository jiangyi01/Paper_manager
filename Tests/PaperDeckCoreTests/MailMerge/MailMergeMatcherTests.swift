import Foundation
import Testing
@testable import PaperDeckCore

/// MailMatcher: a paper imported any other way satisfies the email rows waiting for it.
@Suite struct MailMergeMatcherTests {
    private typealias Kit = MailMergeKit

    @Test func dropAnywhereWithMatchingDOIAutoLinks() async throws {
        try await Kit.run { env in
            let doi = "10.1101/2026.04.06.716850"
            let (open, openItems) = try await Kit.insert(env, Kit.message(kind: .advisor, subject: "Please read this bioRxiv"), items: [
                Kit.item(1, origin: .link, pdf: .needsPDF, doi: doi, url: "https://www.biorxiv.org/content/\(doi)v1"),
            ])
            let (dismissed, dismissedItems) = try await Kit.insert(env, Kit.message(kind: .person, subject: "Old", state: .dismissed),
                                                                   items: [Kit.item(1, origin: .link, pdf: .needsPDF, doi: doi)])
            // A listed alert entry for the same work links silently.
            let (alert, alertItems) = try await Kit.insert(env, Kit.message(kind: .alert, subject: "bioRxiv alert", triage: nil),
                                                           items: [Kit.item(1, origin: .alertEntry, relevance: .listed,
                                                                            pdf: .downloadable, doi: doi)])
            // The floating panel import (new bioRxiv prefix in the PDF; the email has the old one).
            let file = try Kit.writeUserPDF(env, name: "2026.04.06.716850.full.pdf", title: "Agentic systems",
                                            doi: "10.64898/2026.04.06.716850")
            let summary = await env.engine.intake.ingest([.file(file)], options: ImportOptions(origin: .drop, ai: .skip))
            let paperID = try #require(summary.added.first)
            await env.settle()

            let row = try await env.item(openItems[0].id)
            #expect(row.status == .linked && row.paperID == paperID && row.pdfState == .inLibrary)
            let card = try await env.message(open.id)
            #expect(card.state == .merged && !card.userTouched)                  // automatic, not a user action
            let p = try await env.paper(paperID)
            let sources = try await env.db.paperSources(paperPK: p.pk)
            #expect(Set(sources.compactMap(\.mailMessageID)) == [open.id, alert.id])
            #expect(try await env.item(alertItems[0].id).status == .linked)
            #expect(try await env.item(dismissedItems[0].id).status == .pending)  // dismissed cards are left alone
            #expect(try await env.message(dismissed.id).state == .dismissed)

            let matched = env.events.toasts.filter { $0.message.hasPrefix("Matched an email request:") }
            #expect(matched.map(\.message) == ["Matched an email request: Please read this bioRxiv"])
            #expect(matched.first?.buttons.first?.action == .openMail(id: open.id))
        }
    }

    @Test func arxivMatchIgnoresVersionsAndSkipsInFlightRows() async throws {
        try await Kit.run { env in
            let (_, items) = try await Kit.insert(env, Kit.message(kind: .person), items: [
                Kit.item(1, origin: .link, pdf: .downloadable, arxiv: "2604.09554", url: "https://arxiv.org/abs/2604.09554"),
                Kit.item(2, origin: .link, pdf: .needsPDF, arxiv: "2604.09554"),
            ])
            MailMergeInFlight.shared.insert(items[1].id)
            defer { MailMergeInFlight.shared.remove(items[1].id) }
            let file = try Kit.writeUserPDF(env, name: "2604.09554v2.pdf", title: "LABBench2")
            _ = await env.engine.intake.ingest([.file(file)], options: ImportOptions(origin: .drop, ai: .skip))
            await env.settle()
            #expect(try await env.item(items[0].id).status == .linked)
            #expect(try await env.item(items[1].id).status == .pending)
        }
    }

    @Test func titleOnlyMatchOffersALinkToast() async throws {
        try await Kit.run { env in
            let title = "Spatial transcriptomic atlas of the developing human cortex"
            let (message, items) = try await Kit.insert(env, Kit.message(kind: .advisor, subject: "Read for lab meeting"), items: [
                Kit.item(1, origin: .citation, pdf: .needsPDF, title: title, year: 2025, authors: ["Li Wang", "A. Kriegstein"]),
                Kit.item(2, origin: .citation, pdf: .needsPDF, title: title, year: 2019),                 // no corroboration
            ])
            let file = try Kit.writeUserPDF(env, name: "atlas.pdf", title: title)
            let id = try #require(await env.engine.intake.ingest([.file(file)], options: ImportOptions(origin: .drop, ai: .skip)).added.first)
            await env.settle()
            // Without metadata the paper has no year / authors yet: nothing is suggested.
            #expect(!env.events.toasts.contains { $0.message.hasPrefix("May match") })

            let p = try await env.engine.editMetadata(paperID: id, title: title, authors: ["Wang, Li", "Kriegstein, Arnold"],
                                                      year: 2025, venue: nil, doi: nil, arxivID: nil)
            await MailMatcher.paperReady(pk: p.pk, ctx: env.engine.ctx)
            await env.events.drain()
            let offers = env.events.toasts.filter { $0.message.hasPrefix("May match an email request: Read for lab meeting") }
            #expect(offers.count == 1)
            #expect(offers.first?.buttons.map(\.action) == [.linkMailItem(itemID: items[0].id, paperID: id), .openMail(id: message.id)])
            #expect(try await env.item(items[0].id).status == .pending)                // never applied by itself

            // 「关联」
            try await env.engine.linkMailItem(itemID: items[0].id, paperID: id)
            let row = try await env.item(items[0].id)
            #expect(row.status == .linked && row.paperID == id)
            #expect(try await env.message(message.id).userTouched)
            #expect(try await env.db.paperSources(paperPK: p.pk).count == 1)
        }
    }

    @Test func titleMatchingRules() {
        let paper = Paper(sha256: "x", fileSize: 1, ids: PaperIDs(doi: "10.1/a"), title: "Deep learning for single-cell biology",
                          authors: ["Maria Müller", "Bo Chen"], year: 2024, folder: "f", pdfName: "p.pdf", originalName: "p.pdf")
        var item = MailMergeKit.item(1, origin: .citation, pdf: .needsPDF, title: "Deep Learning for Single-Cell Biology",
                                     authors: ["Muller M"])
        #expect(MailMatcher.titleMatches(item: item, paper: paper))
        item.authors = []
        #expect(!MailMatcher.titleMatches(item: item, paper: paper))
        item.year = 2024
        #expect(MailMatcher.titleMatches(item: item, paper: paper))
        item.ids.doi = "10.1/other"                                             // conflicting ids
        #expect(!MailMatcher.titleMatches(item: item, paper: paper))
        item.ids.doi = nil
        item.title = "Deep learning for bulk proteomics"
        #expect(!MailMatcher.titleMatches(item: item, paper: paper))
        #expect(MailMatcher.surname("Kriegstein AR") == "kriegstein")
        #expect(MailMatcher.surname("Wang, Li") == "wang")
        #expect(MailMatcher.surname("Li Wang") == "wang")
    }
}

/// Card state after user actions (merged / pending / snoozed / dismissed) and userTouched.
@Suite struct MailMergeStateTests {
    private typealias Kit = MailMergeKit

    @Test func completionRules() {
        var a = Kit.item(1, relevance: .requested), b = Kit.item(2, relevance: .highlighted), c = Kit.item(3, relevance: .listed)
        #expect(MailMergeState.targetItems([a, b, c]).map(\.ord) == [1, 2])
        #expect(!MailMergeState.isComplete([a, b, c]))
        a.status = .merged; b.status = .skipped
        #expect(MailMergeState.isComplete([a, b, c]))
        #expect(MailMergeState.remaining([a, b, c]) == 0)

        // Nothing rated: every unrated row decides.
        var u1 = Kit.item(1, relevance: nil), u2 = Kit.item(2, relevance: nil)
        u1.status = .linked
        #expect(!MailMergeState.isComplete([u1, u2]) && MailMergeState.remaining([u1, u2]) == 1)
        u2.status = .skipped
        #expect(MailMergeState.isComplete([u1, u2]))

        // An all-listed digest completes once anything was taken.
        var l1 = Kit.item(1, relevance: .listed); let l2 = Kit.item(2, relevance: .listed)
        #expect(!MailMergeState.isComplete([l1, l2]))
        l1.status = .merged
        #expect(MailMergeState.isComplete([l1, l2]))
    }

    @Test func userActionsMoveTheCard() async throws {
        try await Kit.run { env in
            let (message, items) = try await Kit.insert(env, Kit.message(), items: [
                Kit.item(1, origin: .link, pdf: .needsPDF), Kit.item(2, origin: .link, pdf: .needsPDF),
                Kit.item(3, origin: .alertEntry, relevance: .listed, pdf: .needsPDF),
            ])
            try await env.engine.skipMailItem(itemID: items[0].id)
            var card = try await env.message(message.id)
            #expect(card.state == .pending && card.userTouched && card.handledAt == nil)

            let later = Kit.start.addingTimeInterval(86_400)
            try await env.engine.snoozeMail(messageID: message.id, until: later)
            card = try await env.message(message.id)
            #expect(card.state == .snoozed && card.snoozedUntil == later)
            #expect(try await env.engine.unsnoozeDue() == 0)
            env.clock.value = later.addingTimeInterval(1)
            #expect(try await env.engine.unsnoozeDue() == 1)
            card = try await env.message(message.id)
            #expect(card.state == .pending && card.snoozedUntil == nil)

            try await env.engine.dismissMail(messageID: message.id)
            card = try await env.message(message.id)
            #expect(card.state == .dismissed && card.handledAt == env.clock.value)
            try await env.engine.reopenMail(messageID: message.id)
            #expect(try await env.message(message.id).state == .pending)

            // Skipping the last requested row completes the card (the listed one doesn't count).
            try await env.engine.skipMailItem(itemID: items[1].id)
            card = try await env.message(message.id)
            #expect(card.state == .merged && card.handledAt == env.clock.value)
            #expect(try await env.item(items[2].id).status == .pending)
        }
    }

    /// Review fix integrity-5: a triage on its way is withdrawn to `none` (a reopened card offers
    /// 「让 AI 分析」 again); a card still waiting for consent keeps `awaitingConsent` (no job).
    @Test func dismissCancelsAWaitingTriage() async throws {
        try await Kit.run { env in
            var m = Kit.message(kind: .person)
            m.triageState = .awaitingConsent
            let (message, _) = try await Kit.insert(env, m, items: [])
            try await env.engine.dismissMail(messageID: message.id)
            let card = try await env.message(message.id)
            #expect(card.state == .dismissed && card.triageState == .awaitingConsent && card.userTouched)

            var q = Kit.message(kind: .alert)
            q.triageState = .queued
            q.triageConsented = true
            q.triageConsentProvider = "claude"
            let (queued, _) = try await Kit.insert(env, q, items: [])
            try await env.engine.dismissMail(messageID: queued.id)
            let withdrawn = try await env.message(queued.id)
            #expect(withdrawn.state == .dismissed && withdrawn.triageState == MailTriageState.none)
            #expect(!withdrawn.triageConsented && withdrawn.triageConsentProvider == nil)
        }
    }
}
