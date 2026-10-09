import Foundation
import Testing
@testable import PaperDeckCore

/// Round 4, r4-4: the triage hand-off refuses a closed card (dismissed or merged) on every path,
/// matching `requestAI`'s refusal — the user's 「让 AI 分析」 (a dismiss landing between its consent
/// and the hand-off), the pipeline's `messageReady`, and launch recovery of a job that was in the
/// lane at quit. Mock provider only (zero quota); the dismiss is committed from a second SQLite
/// connection at the exact step.
@Suite(.serialized) struct R4HandOffTests {
    typealias K = MailSyncKit

    private static func insert(_ env: R4.Env, _ n: Int, state: MailState = .pending, triage: MailTriageState,
                               stdinBytes: Int? = nil) async throws -> MailMessage {
        let msg = MailMessage(accountID: "acct-a", internetMessageID: "<r4-handoff-\(n)@alerts.highwire.org>",
                              fromAddress: "biorxiv@alerts.highwire.org", ruleID: K.biorxivRule.id, senderKind: .alert,
                              subject: "bioRxiv alert \(n)", receivedAt: K.start, bodyText: "New results [c1 biorxiv.org]",
                              state: state, triageState: triage, triageStdinBytes: stdinBytes, createdAt: K.start,
                              updatedAt: K.start, handledAt: state == .pending ? nil : K.start)
        let item = MailItem(ord: 1, cand: "c1", origin: .alertEntry, title: "Spatial atlas \(n)",
                            ids: PaperIDs(doi: "10.1101/2026.09.2\(n).61412\(n)"), pdfState: .downloadable)
        return try await env.db.insertMailMessage(msg, items: [item]).0
    }

    /// An alert under its `always` rule: the gate allows it without a consent, so only the
    /// closed-card check stands between a dismissed card and the AI.
    @Test func aDismissBetweenTheConsentAndTheHandOffSendsNothing() async throws {
        let mock = MockAgentProvider()
        try await R4.run(mode: .mock, mock: mock, start: false) { env in
            let m = try await Self.insert(env, 1, triage: .done)
            #expect(MailTriageCoordinator.permission(m, settings: env.mail.value, provider: .claude) == .allowed)
            let dbPath = env.paths.database.path
            // requestAI reads the mail settings once, then its hand-off does: the dismiss (as
            // `dismissMail` writes it, its withdraw already past) commits right before the hand-off reads the row.
            env.hook.arm(onRead: 2) {
                guard let raw = try? SQLiteConnection(path: dbPath) else { return }
                try? raw.exec("PRAGMA busy_timeout = 3000")
                try? raw.run("""
                    UPDATE mail_message SET state = 'dismissed', user_touched = 1, triage_consented = 0,
                    triage_consent_provider = NULL WHERE pk = ?
                    """, [.integer(m.pk)])
                raw.close()
            }
            _ = try await env.engine.requestMailAI(messageID: m.id)
            let row = try #require(try await env.db.mailMessage(pk: m.pk))
            #expect(row.state == .dismissed)
            #expect(row.triageStdinBytes == nil && row.triageState != .queued)
            #expect(await env.engine.mailTriage.laneMessagePKs().isEmpty)
            #expect(await env.engine.mailTriage.usage().used == 0)
            #expect(await mock.calls == 0)
        }
    }

    /// Launch recovery: a merged card whose job was in the lane at quit is not sent again.
    @Test func recoveryNeverHandsOffAMergedCard() async throws {
        let mock = MockAgentProvider()
        try await R4.run(mode: .mock, mock: mock, start: false) { env in
            let merged = try await Self.insert(env, 2, state: .merged, triage: .queued, stdinBytes: 1234)
            let open = try await Self.insert(env, 3, triage: .queued, stdinBytes: 1234)
            await env.engine.start()
            #expect(await K.eventually { try await env.db.mailMessage(pk: open.pk)?.triageState == .done })
            let row = try #require(try await env.db.mailMessage(pk: merged.pk))
            #expect(row.triageState == .none && row.state == .merged)
            #expect(await mock.calls == 1)                                    // the open card only
        }
    }

    /// The pipeline (post-processing's `messageReady`, resumed at launch): a card merged before its
    /// hand-off is not sent.
    @Test func messageReadyNeverHandsOffAMergedCard() async throws {
        let mock = MockAgentProvider()
        try await R4.run(mode: .mock, mock: mock, start: false) { env in
            let merged = try await Self.insert(env, 4, state: .merged, triage: .queued)
            try await env.db.setMailCursor(accountID: MailSyncActor.pendingPostKey, MailCursor(String(merged.pk)))
            await env.engine.start()
            #expect(await K.eventually { try await env.db.mailCursor(accountID: MailSyncActor.pendingPostKey) == nil })
            await env.engine.mail.waitUntilIdle()
            let row = try #require(try await env.db.mailMessage(pk: merged.pk))
            #expect(row.triageStdinBytes == nil && row.triageState == .none)
            #expect(await env.engine.mailTriage.laneMessagePKs().isEmpty)
            try await Task.sleep(for: .milliseconds(100))
            #expect(await mock.calls == 0)
        }
    }
}
