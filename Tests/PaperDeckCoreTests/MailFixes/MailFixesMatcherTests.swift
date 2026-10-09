import Foundation
import Testing
@testable import PaperDeckCore

/// MailMatcher vs. a merge of the same card (the in-flight check is taken before the link is
/// written), and 「撤销」 on the 「已匹配邮件请求」 toast. The interleavings are forced through
/// `MailMatcher.Probe` — no timing, no sleeps.
@Suite struct MailFixesMatcherTests {
    private typealias Kit = MailFixesKit
    private static let doi = "10.1038/s41586-026-07777-1"

    /// The original race: the merge's `defer` clears the card's in-flight marker after the
    /// matcher linked the sibling row but before it decided about the toast.
    @Test func mergeEndingRightAfterTheLinkStaysSilent() async throws {
        try await Kit.run { env in
            let paper = try await Kit.addPaper(env, doi: Self.doi)
            let (message, items) = try await Kit.insert(env, Kit.message(), items: [
                Kit.item(1, origin: .attachment, pdf: .hasPDF),
                Kit.item(2, doi: Self.doi),
            ])
            MailMergeInFlight.shared.insertMessage(message.id)                  // a merge of this card runs
            let probe = MailMatcher.Probe(afterLink: { id in MailMergeInFlight.shared.removeMessage(id) })
            await MailMatcher.paperReady(pk: paper.pk, ctx: env.ctx, probe: probe)
            #expect(!MailMergeInFlight.shared.containsMessage(message.id))
            await env.events.drain()

            let row = try await env.item(items[1].id)
            #expect(row.status == .linked && row.paperID == paper.id)
            #expect(env.events.matchedToasts.isEmpty)
        }
    }

    /// The merge finished (its own sibling-linking already linked the row, then its marker went)
    /// between the matcher reading the waiting rows and writing: nothing is linked twice, no toast.
    @Test func mergeThatAlreadyLinkedTheRowLeavesNothingToDo() async throws {
        try await Kit.run { env in
            let paper = try await Kit.addPaper(env, doi: Self.doi)
            let (message, items) = try await Kit.insert(env, Kit.message(), items: [
                Kit.item(1, origin: .attachment, pdf: .hasPDF),
                Kit.item(2, doi: Self.doi),
            ])
            let ctx = env.ctx
            let clock = env.clock
            let sibling = items[1].id
            MailMergeInFlight.shared.insertMessage(message.id)
            let probe = MailMatcher.Probe(beforeCapture: { id in
                // What the merge does last: link the sibling silently, then its defer runs.
                _ = try? await MailItemLinker.link(itemIDs: [sibling], messagePK: message.pk, to: paper, status: .linked,
                                                   annotation: nil, userAction: true, ctx: ctx)
                MailMergeInFlight.shared.removeMessage(id)
                clock.value = clock.value.addingTimeInterval(60)            // a second write would be stamped later
            })
            await MailMatcher.paperReady(pk: paper.pk, ctx: env.ctx, probe: probe)
            await env.events.drain()

            let row = try await env.item(sibling)
            #expect(row.status == .linked && row.paperID == paper.id)
            #expect(row.updatedAt == Kit.start)                              // linked once, by the "merge"
            #expect(env.events.matchedToasts.isEmpty)
            #expect(try await env.db.paperSources(paperPK: paper.pk).count == 1)
        }
    }

    @Test func undoPutsTheRowBackAndReopensTheCard() async throws {
        try await Kit.run { env in
            let paper = try await Kit.addPaper(env, doi: Self.doi)
            let (message, items) = try await Kit.insert(env, Kit.message(subject: "Read this"), items: [
                Kit.item(1, pdf: .downloadable, doi: Self.doi, downloadError: "Download failed (404)"),
                Kit.item(2, relevance: .listed, doi: "10.1101/2026.01.01.000001"),
            ])
            await MailMatcher.paperReady(pk: paper.pk, ctx: env.ctx)
            await env.events.drain()

            let linked = try await env.item(items[0].id)
            #expect(linked.status == .linked && linked.pdfState == .inLibrary)
            let card = try await env.message(message.id)
            #expect(card.state == .merged && card.handledAt != nil && !card.userTouched)
            #expect(try await env.db.paperSources(paperPK: paper.pk).count == 1)

            let toast = try #require(env.events.matchedToasts.first)
            #expect(toast.message == "Matched an email request: Read this")
            #expect(toast.buttons.map(\.title) == ["View", "Undo"])
            #expect(toast.buttons.first?.action == .openMail(id: message.id))
            guard case .undoMailLink(let token)? = toast.buttons.last?.action else {
                Issue.record("no undo action")
                return
            }

            #expect(try await env.engine.undoMailLink(token: token))
            let row = try await env.item(items[0].id)
            #expect(row.status == .pending && row.paperID == nil && row.pdfState == .downloadable)
            #expect(row.downloadError == "Download failed (404)")
            let reopened = try await env.message(message.id)
            #expect(reopened.state == .pending && reopened.handledAt == nil && !reopened.userTouched)
            #expect(try await env.db.paperSources(paperPK: paper.pk).isEmpty)
            await env.engine.ctx.sidecars.flush()
            let folder = env.engine.ctx.folderURL(paper)
            let sidecar = try CardSidecar.decoded(from: Data(contentsOf: folder.appendingPathComponent(CardSidecar.fileName)))
            #expect(sidecar.provenance.isEmpty)

            // Used once; and the matcher leaves that row alone for this paper from now on.
            #expect(try await env.engine.undoMailLink(token: token) == false)
            await MailMatcher.paperReady(pk: paper.pk, ctx: env.ctx)
            await env.events.drain()
            #expect(try await env.item(items[0].id).status == .pending)
            #expect(env.events.matchedToasts.count == 1)
        }
    }

    @Test func undoReturnsASnoozedCardToSnoozed() async throws {
        try await Kit.run { env in
            let paper = try await Kit.addPaper(env, doi: Self.doi)
            let until = Kit.start.addingTimeInterval(2 * Kit.day)
            let (message, _) = try await Kit.insert(env, Kit.message(state: .snoozed, snoozedUntil: until),
                                                    items: [Kit.item(1, doi: Self.doi)])
            await MailMatcher.paperReady(pk: paper.pk, ctx: env.ctx)
            await env.events.drain()
            #expect(try await env.message(message.id).state == .merged)
            let token = try #require(Self.undoToken(env.events.matchedToasts.first))
            #expect(try await env.engine.undoMailLink(token: token))
            let m = try await env.message(message.id)
            #expect(m.state == .snoozed && m.snoozedUntil == until && m.handledAt == nil)
        }
    }

    @Test func undoLeavesRowsAndCardsTouchedSinceAlone() async throws {
        try await Kit.run { env in
            let paper = try await Kit.addPaper(env, doi: Self.doi)
            let other = try await Kit.addPaper(env, doi: "10.1016/j.cell.2026.02.002")
            // Card 1: the user re-linked the row to another paper after the automatic link.
            let (m1, i1) = try await Kit.insert(env, Kit.message(subject: "One"), items: [Kit.item(1, doi: Self.doi)])
            // Card 2: the row is untouched, but the user reopened the card meanwhile.
            let (m2, i2) = try await Kit.insert(env, Kit.message(subject: "Two"), items: [Kit.item(1, doi: Self.doi)])
            await MailMatcher.paperReady(pk: paper.pk, ctx: env.ctx)
            await env.events.drain()
            let toasts = env.events.matchedToasts
            #expect(toasts.count == 2)
            let t1 = try #require(Self.undoToken(toasts.first { $0.message.hasSuffix("One") }))
            let t2 = try #require(Self.undoToken(toasts.first { $0.message.hasSuffix("Two") }))

            env.advance(60)
            try await env.engine.linkMailItem(itemID: i1[0].id, paperID: other.id)
            #expect(try await env.engine.undoMailLink(token: t1) == false)
            #expect(try await env.item(i1[0].id).paperID == other.id)
            #expect(try await env.message(m1.id).state == .merged)

            try await env.engine.reopenMail(messageID: m2.id)
            #expect(try await env.engine.undoMailLink(token: t2))
            #expect(try await env.item(i2[0].id).status == .pending)
            let card2 = try await env.message(m2.id)
            #expect(card2.state == .pending && card2.userTouched)                // the user's reopen stands
        }
    }

    @Test func undoKeepsProvenanceTheLinkDidNotAdd() async throws {
        try await Kit.run { env in
            let paper = try await Kit.addPaper(env, doi: Self.doi)
            let (message, items) = try await Kit.insert(env, Kit.message(), items: [
                Kit.item(1, doi: Self.doi),
                Kit.item(2, relevance: .highlighted, doi: "10.1101/2026.03.03.000003"),
            ])
            try await env.engine.linkMailItem(itemID: items[1].id, paperID: paper.id)   // the user's own link
            await MailMatcher.paperReady(pk: paper.pk, ctx: env.ctx)
            await env.events.drain()
            #expect(try await env.message(message.id).state == .merged)
            let token = try #require(Self.undoToken(env.events.matchedToasts.first))
            #expect(try await env.engine.undoMailLink(token: token))
            #expect(try await env.item(items[0].id).status == .pending)
            #expect(try await env.item(items[1].id).status == .linked)
            #expect(try await env.db.paperSources(paperPK: paper.pk).count == 1)
            let card = try await env.message(message.id)                       // incomplete again → 待处理
            #expect(card.state == .pending && card.handledAt == nil && card.userTouched)
        }
    }

    @Test func undoTokensExpireAndBelongToTheirEngine() async throws {
        try await Kit.run { env in
            let paper = try await Kit.addPaper(env, doi: Self.doi)
            try await Kit.insert(env, Kit.message(subject: "A"), items: [Kit.item(1, doi: Self.doi)])
            try await Kit.insert(env, Kit.message(subject: "B"), items: [Kit.item(1, doi: Self.doi)])
            await MailMatcher.paperReady(pk: paper.pk, ctx: env.ctx)
            await env.events.drain()
            let toasts = env.events.matchedToasts
            let a = try #require(Self.undoToken(toasts.first { $0.message.hasSuffix("A") }))
            let b = try #require(Self.undoToken(toasts.first { $0.message.hasSuffix("B") }))

            try await Kit.run { other in
                let undone = try await other.engine.undoMailLink(token: a)        // another library
                #expect(!undone)
            }
            env.advance(MailLinkUndo.lifetime + 1)
            #expect(try await env.engine.undoMailLink(token: b) == false)
            #expect(try await env.engine.undoMailLink(token: "not-a-token") == false)
        }
    }

    private static func undoToken(_ toast: Toast?) -> String? {
        guard case .undoMailLink(let token)? = toast?.buttons.last?.action else { return nil }
        return token
    }
}
