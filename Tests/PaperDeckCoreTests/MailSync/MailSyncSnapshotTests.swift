import Foundation
import Testing
@testable import PaperDeckCore

/// `Engine.mailSnapshot()`: cards grouped by the inbox filter, badge counts, account statuses and
/// today's triage usage; `mailCard(id:)`; snooze wake-up and clear-all through the sync actor.
@Suite(.serialized) struct MailSyncSnapshotTests {
    typealias K = MailSyncKit

    @Test func snapshotGroupsCardsAndCountsBadges() async throws {
        try await K.run { env in
            let src = env.source()
            await src.add("advisor.eml", try K.data("advisor-request-pdf"))
            await src.add("share.eml", try K.data("colleague-share"))
            await src.add("alert.eml", try K.data("biorxiv-alert"))
            let big = Data("%PDF-1.4\n".utf8) + Data(repeating: 0x41, count: 1_200_000)
            await src.add("big.eml", MailSyncPipelineTests.emlWithAttachment(big, from: "jsmith@wustl.edu",
                                                                             messageID: "<big-2@wustl.edu>"))
            let notice = """
                From: bioRxiv <biorxiv@alerts.highwire.org>
                Subject: Account notice
                Date: Wed, 30 Sep 2026 05:00:00 +0000
                Message-ID: <notice-2@alerts.highwire.org>
                List-Unsubscribe: <mailto:unsubscribe@alerts.highwire.org>
                Content-Type: text/plain; charset=utf-8

                Nothing to read today.
                """
            await src.add("notice.eml", Data(notice.replacingOccurrences(of: "\n", with: "\r\n").utf8))
            env.mail.update { $0.maxAttachmentMB = 1 }
            await env.sync()
            // The alert's triage (mode off) was handed to the lane and came back held (count refunded).
            #expect(await K.eventually {
                (try await env.db.mailMessage(internetMessageID: "<alert.20260930.998877@alerts.highwire.org>"))?.triageState == .held
            })

            let snap = try await env.engine.mailSnapshot()
            #expect(snap.enabled)
            #expect(snap.aiMode == .ai)
            let pending = snap.cards(.pending)
            #expect(Set(pending.map(\.message.internetMessageID)) == [
                "<caf3xyz+abc123@mail.gmail.com>", "<share-7781@wustl.edu>",
                "<alert.20260930.998877@alerts.highwire.org>", "<big-2@wustl.edu>",
            ])
            #expect(snap.cards(.noRequest).map(\.message.internetMessageID) == ["<notice-2@alerts.highwire.org>"])
            #expect(snap.cards(.snoozed).isEmpty && snap.cards(.handled).isEmpty && snap.cards(.dismissed).isEmpty)
            // Newest received first.
            let received = pending.map(\.message.receivedAt)
            #expect(received == received.sorted(by: >))

            #expect(snap.counts.pending == 4)
            #expect(snap.counts.requests == 2)                   // two advisor requests
            #expect(snap.counts.awaitingConsent == 3)            // advisor ×2 + colleague (ask)
            #expect(snap.counts.needsPDF == 1)                   // the over-cap attachment
            #expect(snap.counts.needsPDF == pending.reduce(0) { $0 + $1.needsPDFCount })

            let advisor = try #require(pending.first { $0.message.internetMessageID == "<caf3xyz+abc123@mail.gmail.com>" })
            #expect(advisor.rule?.id == K.advisorRule.id)
            #expect(advisor.account?.id == "acct-a")
            #expect(advisor.readyCount == 2)                     // attachment + downloadable bioRxiv link
            #expect(advisor.items.map(\.ord) == advisor.items.map(\.ord).sorted())
            #expect(snap.card(id: advisor.id.uppercased()) == advisor)

            #expect(snap.accounts.map(\.id) == ["acct-a"])
            #expect(snap.accounts.first?.lastCaptured == 5)
            #expect(snap.accountStatuses["acct-a"] == .ready(detail: "fake ready"))
            #expect(snap.triageUsage == MailTriageUsage(day: LocalDate(year: 2026, month: 9, day: 30), used: 0, limit: 30))

            // Round 3 (C-H, intended change): the inbox snapshot carries no bodies; the card does.
            let detail = try #require(try await env.engine.mailCard(id: advisor.id))
            #expect(advisor.message.bodyText == nil && advisor.hasBody)
            #expect(detail.message.bodyText?.isEmpty == false && detail.hasBody)
            #expect(try await env.engine.mailCard(id: UUID().uuidString) == nil)
        }
    }

    @Test func snoozedCardsComeBackAndClearAllRemovesEverything() async throws {
        try await K.run { env in
            await env.source().add("advisor.eml", try K.data("advisor-request-pdf"))
            await env.sync()
            let m = try await env.message("<caf3xyz+abc123@mail.gmail.com>")
            try await env.db.modifyMailMessage(pk: m.pk) {
                $0.state = .snoozed
                $0.snoozedUntil = MailSyncKit.start.addingTimeInterval(3600)
                $0.userTouched = true
            }
            #expect(try await env.engine.mailSnapshot().cards(.snoozed).count == 1)
            env.advance(3601)
            await env.sync()                                      // the maintenance pass wakes it
            let snap = try await env.engine.mailSnapshot()
            #expect(snap.cards(.pending).map(\.id) == [m.id])
            #expect(snap.counts.snoozed == 0)

            let dir = env.engine.paths.mailFiles.appendingPathComponent(m.id)
            #expect(FileManager.default.fileExists(atPath: dir.path))
            try await env.engine.mail.deleteAllMailData()
            #expect(try await env.engine.mailSnapshot().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: dir.path))
            #expect(try await env.db.mailCursor(accountID: "acct-a") == nil)
        }
    }
}
