import Foundation
import Testing
@testable import PaperDeckCore

/// Round 3, r3-3 (K2 seam): the post-processing marker (`mail.cursor.~postprocess`, the only such
/// key) is cleared only once the triage hand-off happened or the row left `queued`. An aborted
/// hand-off keeps it and is retried at the next pass (hand-off only), a few times, then the card
/// offers 「让 AI 分析」; a row `queued` without a hand-off and without a marker for longer than a
/// pass is moved to `awaitingConsent` / `none`. Zero-quota mock provider.
@Suite(.serialized) struct R3PostProcessTests {
    typealias K = MailSyncKit

    private static func marker(_ env: K.Env) async throws -> [Int64] {
        MailSyncActor.decodePKs(try await env.db.mailCursor(accountID: MailSyncActor.pendingPostKey)?.value)
    }

    /// `buildJob` reads the library's categories: hiding that table makes every hand-off throw.
    private static func breakHandOffs(_ env: K.Env, _ broken: Bool) async throws {
        try await env.db.transaction { db in
            try db.db.exec(broken ? "ALTER TABLE category RENAME TO category_r3_hidden"
                                  : "ALTER TABLE category_r3_hidden RENAME TO category")
        }
    }

    private static func state(_ env: K.Env, _ mid: String) async -> MailTriageState? {
        try? await env.db.mailMessage(internetMessageID: mid)?.triageState
    }

    @Test func anAbortedHandOffKeepsTheMarkerAndIsRetriedAtTheNextPass() async throws {
        let mock = MockAgentProvider()
        try await K.run(mode: .mock, mock: mock) { env in
            try await Self.breakHandOffs(env, true)
            await env.source().add("a1.eml", try RFAKit.alert(1))
            await env.sync()
            let m = try await env.message(RFAKit.alertID(1))
            #expect(m.triageState == .queued && m.triageStdinBytes == nil)       // the hand-off threw
            #expect(try await Self.marker(env) == [m.pk])                         // …so the marker stays
            #expect(await mock.calls == 0)

            try await Self.breakHandOffs(env, false)
            await env.sync()                                                      // the next pass retries it
            #expect(await K.eventually { await Self.state(env, RFAKit.alertID(1)) == .done })
            #expect(await mock.calls == 1)
            #expect(try await Self.marker(env).isEmpty)
            #expect(await env.engine.mailTriage.usage().used == 1)
        }
    }

    @Test func aHandOffThatKeepsFailingEndsAtLetAIAnalyzeNotQueuedForever() async throws {
        let mock = MockAgentProvider()
        try await K.run(mode: .mock, mock: mock) { env in
            try await Self.breakHandOffs(env, true)
            await env.source().add("a2.eml", try RFAKit.alert(2))
            await env.sync()
            #expect(MailSyncActor.maxHandOffRetries <= 3)
            for _ in 0..<4 { await env.sync() }                                   // retried, still failing → given up
            let m = try await env.message(RFAKit.alertID(2))
            #expect(m.triageState == .awaitingConsent && !m.triageConsented)
            #expect(try await Self.marker(env).isEmpty)
            #expect(await env.engine.mailTriage.usage().used == 0)               // every failed attempt refunded
            try await Self.breakHandOffs(env, false)
            let card = try #require(try await env.engine.mailCard(id: m.id))
            #expect(card.canRequestAI)
            #expect(try await env.engine.requestMailAI(messageID: m.id) == .queued)
            #expect(await K.eventually { await Self.state(env, RFAKit.alertID(2)) == .done })
            #expect(await mock.calls == 1)
        }
    }

    /// The coordinator stopping mid-hand-off (quit) keeps the marker for the next launch.
    @Test func aQuitDuringTheHandOffLeavesTheMarkerForTheNextLaunch() async throws {
        let root = try RFB.tempRoot("pd-r3-quit")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await K.make(mode: .mock, root: root)
        await first.engine.mailTriage.shutdown()                                  // stopping, like at quit
        await first.source().add("a3.eml", try RFAKit.alert(3))
        await first.sync()
        let m = try await first.message(RFAKit.alertID(3))
        #expect(m.triageState == .queued && m.triageStdinBytes == nil)
        #expect(try await Self.marker(first) == [m.pk])
        await first.engine.shutdown()
        await first.engine.db.close()

        let mock = MockAgentProvider()
        let second = try await K.make(mode: .mock, mock: mock, root: root)
        #expect(await K.eventually { await Self.state(second, RFAKit.alertID(3)) == .done })
        #expect(await mock.calls == 1)
        #expect(try await Self.marker(second).isEmpty)
        await second.cleanup()
    }

    @Test func aQueuedRowWithoutHandOffOrMarkerOffersAIAfterAPass() async throws {
        let mock = MockAgentProvider()
        try await RFAKit.run(mode: .mock, mock: mock) { env in
            // The engine's startup pass (post-processing recovery, then a sync pass whose triage
            // tick read the settings before the `never` sender below existed) is over before the
            // fixture is built: it saw neither the rows nor the marker (the flake at "alert 5 →
            // none"; the coordinator fix is PFTriageSnapshotTests).
            await env.engine.mail.syncNow()
            let stale = try await RFAKit.insertAlert(env, 4)                      // queued, no stdin, no marker
            var never = K.biorxivRule
            never.id = "rule-never"
            never.pattern = "@never.example"
            never.aiPolicy = .never
            env.mail.update { $0.senders.append(never) }
            let silent = try await RFAKit.insertAlert(env, 5, ruleID: never.id)
            let fresh = try await RFAKit.insertAlert(env, 6)
            try await env.db.setMailCursor(accountID: MailSyncActor.pendingPostKey, MailCursor(String(fresh.pk)))
            try await env.db.modifyMailMessage(pk: fresh.pk, now: K.start) { $0.subject = "still post-processing" }

            await env.engine.mail.syncNow()                                       // within the pass: left alone
            #expect(await RFAKit.triageState(env, RFAKit.alertID(4)) == .queued)
            env.advance(301)                                                      // older than a pass (5 min)
            await env.engine.mail.syncNow()
            #expect(await RFAKit.triageState(env, RFAKit.alertID(4)) == .awaitingConsent)
            #expect(await RFAKit.triageState(env, RFAKit.alertID(5)) == MailTriageState.none)   // never → none
            #expect(await RFAKit.triageState(env, RFAKit.alertID(6)) == .queued)  // its hand-off is still owed
            try await Task.sleep(for: .milliseconds(150))
            #expect(await mock.calls == 0)
            _ = stale; _ = silent
        }
    }
}
