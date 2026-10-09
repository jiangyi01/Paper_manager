import Foundation
import Testing
@testable import PaperDeckCore

/// Round 3, r3-10 / C-H (runtime-8): the inbox snapshot neither reads nor carries message bodies
/// (`message.bodyText` nil); `MailCard.hasBody` tells a stripped body from an empty or purged
/// one, and `Engine.mailCard(id:)` still returns the full message.
@Suite struct R3SnapshotBodyTests {
    typealias K = MailSyncKit

    @Test func snapshotsCarryNoBodiesButTheCardDoes() async throws {
        try await K.run { env in
            await env.source().add("advisor.eml", try K.data("advisor-request-pdf"))
            await env.sync()
            let stored = try await env.message("<caf3xyz+abc123@mail.gmail.com>")
            #expect(!(stored.bodyText ?? "").isEmpty)

            // An empty body and a purged one, for contrast.
            let empty = try await env.db.insertMailMessage(MailMessage(
                accountID: "acct-a", internetMessageID: "<r3-empty@x.org>", fromAddress: "a@x.org", senderKind: .person,
                subject: "No text", receivedAt: K.start, bodyText: "", createdAt: K.start, updatedAt: K.start), items: []).0
            let purged = try await env.db.insertMailMessage(MailMessage(
                accountID: "acct-a", internetMessageID: "<r3-purged@x.org>", fromAddress: "a@x.org", senderKind: .person,
                subject: "Old", receivedAt: K.start, bodyText: "gone soon", state: .dismissed, createdAt: K.start,
                updatedAt: K.start, handledAt: K.start.addingTimeInterval(-90 * 86_400)), items: []).0
            #expect(try await env.db.purgeMailBodies(handledBefore: K.start, now: K.start) == 1)

            let snap = try await env.engine.mailSnapshot()
            let all = MailInboxFilter.allCases.flatMap { snap.cards($0) }
            #expect(all.allSatisfy { $0.message.bodyText == nil })                 // never in a list snapshot
            let card = try #require(snap.card(id: stored.id))
            #expect(card.hasBody && card.message.snippet != nil)
            #expect(snap.card(id: empty.id)?.hasBody == false)
            let gone = try #require(snap.card(id: purged.id))
            #expect(!gone.hasBody && gone.message.bodyPurged)

            let full = try #require(try await env.engine.mailCard(id: stored.id))
            #expect(full.message.bodyText == stored.bodyText && full.hasBody)
            #expect(try await env.engine.mailCard(id: purged.id)?.hasBody == false)

            // The list read itself skips the column.
            let heads = try await env.db.mailMessageHeads(states: [.pending], limit: 10)
            #expect(heads.contains { $0.message.id == stored.id && $0.hasBody && $0.message.bodyText == nil })
            #expect(heads.contains { $0.message.id == empty.id && !$0.hasBody })
        }
    }
}
