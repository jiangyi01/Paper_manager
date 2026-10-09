import Foundation
import Testing
@testable import PaperDeckCore

/// Round 5 (d): the round-4 verifier's probes, kept as regression tests.
/// - v-2b: held title lookups re-check confidentiality — after 「让 AI 分析」 on a confidential
///   email, its title-only attachment row stays held.
/// - v-2c: a paper the model names with an unknown DOI plus a title, in a confidential email: the
///   title never goes out as the DOI's fallback search.
/// - v-4a: a merge landing after the hand-off read the row but before its commit (`movedAway`'s
///   merged branch): nothing is sent.
/// Fake transports and mock providers only (zero quota, no network).
@Suite(.serialized) struct R5VerifierRegressionTests {
    typealias K = MailSyncKit
    static let editorRule = SenderRule(id: "rule-ed", pattern: "@journal-office.example.org", label: "J", kind: .person)

    @Test func v2bAConfidentialTitleOnlyRowStaysHeldAfterConsent() async throws {
        let recorder = R4.Recorder()
        let mail = K.mailSettings(senders: [K.advisorRule, Self.editorRule])
        try await R4.run(mode: .mock, mail: mail, fetcher: recorder,
                         pdf: K.FakePDF(title: "Secret manuscript title on cortical folding", doi: nil)) { env in
            let eml = R4.emlWithPDF(from: "editor@journal-office.example.org", messageID: "<r5-v2b@x>",
                                    subject: "Invitation to review manuscript JN-2026-0099",
                                    body: ["Dear Dr Jiang,", "Please see the attached manuscript."], pdf: K.realPDF(title: "M"))
            await env.source.add("v2b.eml", eml)
            await env.sync()
            let m = try await env.message("<r5-v2b@x>")
            #expect(MailHeuristics.isConfidential(m))
            #expect(recorder.titleSearches.isEmpty)
            try await env.engine.requestMailAI(messageID: m.id)
            #expect(await K.eventually { try await env.db.mailMessage(pk: m.pk)?.triageState == .done })
            await env.engine.mailTriage.waitForVerification()
            await env.engine.mail.waitUntilIdle()
            try await Task.sleep(for: .milliseconds(300))
            await env.engine.mail.waitUntilIdle()
            #expect(recorder.titleSearches.isEmpty, "\(recorder.titleSearches)")
            #expect(!recorder.requested.contains { $0.contains("Secret%20manuscript") })
        }
    }

    @Test func v2cAnUnknownDOIsTitleIsNeverTheFallbackSearch() async throws {
        let recorder = R4.Recorder()
        let mail = K.mailSettings(senders: [K.advisorRule, Self.editorRule])
        let answer: JSONValue = .object([
            "has_reading_request": .bool(true), "request_kind": .string("advisor_request"),
            "summary": .string("An invitation."), "requester": .string("Dr. Editor"),
            "due_date": .null, "due_evidence": .null, "priority": .string("normal"),
            "papers": .array([
                .object(["ref": .null, "title": .string("Hidden companion manuscript on cortical folding"),
                         "doi": .string("10.5555/unregistered.2026.7777"), "arxiv_id": .null,
                         "relevance": .string("highlighted"), "why": .string("x"), "confidence": .number(0.8)]),
            ]),
        ])
        try await R4.run(mode: .mock, mail: mail, fetcher: recorder, mock: K.ScriptedTriage(answer)) { env in
            let eml = R4.emlWithPDF(from: "editor@journal-office.example.org", messageID: "<r5-v2c@x>",
                                    subject: "Invitation to review manuscript JN-2026-0100",
                                    body: ["Dear Dr Jiang,", "Please also consider the companion paper."], pdf: K.realPDF(title: "M"))
            await env.source.add("v2c.eml", eml)
            await env.sync()
            let m = try await env.message("<r5-v2c@x>")
            try await env.engine.requestMailAI(messageID: m.id)
            #expect(await K.eventually { try await env.db.mailMessage(pk: m.pk)?.triageState == .done })
            await env.engine.mailTriage.waitForVerification()
            await env.engine.mail.waitUntilIdle()
            // The DOI was looked up; its title never was.
            #expect(recorder.requested.contains { $0.contains("10.5555/unregistered.2026.7777") }, "\(recorder.requested)")
            #expect(recorder.titleSearches.isEmpty, "\(recorder.titleSearches)")
            #expect(!recorder.requested.contains { $0.contains("Hidden%20companion") })
        }
    }

    @Test func v4aAMergeDuringTheHandOffSendsNothing() async throws {
        let mock = MockAgentProvider()
        try await R4.run(mode: .mock, mock: mock, start: false) { env in
            let msg = MailMessage(accountID: "acct-a", internetMessageID: "<r5-v4a@alerts.highwire.org>",
                                  fromAddress: "biorxiv@alerts.highwire.org", ruleID: K.biorxivRule.id, senderKind: .alert,
                                  subject: "bioRxiv alert", receivedAt: K.start, bodyText: "New results [c1 biorxiv.org]",
                                  state: .pending, triageState: .done, createdAt: K.start, updatedAt: K.start)
            let item = MailItem(ord: 1, cand: "c1", origin: .alertEntry, title: "Spatial atlas",
                                ids: PaperIDs(doi: "10.1101/2026.09.21.614121"), pdfState: .downloadable)
            let m = try await env.db.insertMailMessage(msg, items: [item]).0
            let dbPath = env.paths.database.path
            // requestAI reads the mail settings, then the hand-off reads them twice: the merge (as a
            // second connection commits it) lands after the hand-off read the row, before its commit.
            env.hook.arm(onRead: 3) {
                guard let raw = try? SQLiteConnection(path: dbPath) else { return }
                try? raw.exec("PRAGMA busy_timeout = 3000")
                try? raw.run("UPDATE mail_message SET state = 'merged' WHERE pk = ?", [.integer(m.pk)])
                raw.close()
            }
            _ = try await env.engine.requestMailAI(messageID: m.id)
            try await Task.sleep(for: .milliseconds(200))
            let row = try #require(try await env.db.mailMessage(pk: m.pk))
            #expect(row.state == .merged)
            #expect(row.triageStdinBytes == nil && row.triageState != .queued)
            #expect(await env.engine.mailTriage.laneMessagePKs().isEmpty)
            #expect(await mock.calls == 0)
        }
    }

    /// The pure branch v-4a relies on.
    @Test func movedAwayCountsAMergeAsClosing() {
        let open = MailMessage(accountID: "a", internetMessageID: "<x@y>", fromAddress: "a@b.org", senderKind: .alert,
                               subject: "s", receivedAt: K.start, state: .pending, triageState: .done)
        var merged = open
        merged.state = .merged
        #expect(MailTriageCoordinator.movedAway(merged, from: open))
        var dismissed = open
        dismissed.state = .dismissed
        #expect(MailTriageCoordinator.movedAway(dismissed, from: open))
        #expect(!MailTriageCoordinator.movedAway(open, from: open))
    }
}
