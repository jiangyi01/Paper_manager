import Foundation
import Testing
@testable import PaperDeckCore

/// Review fixes safety-1 / integrity-2 (launch recovery and the daily cap), safety-2 / runtime-1
/// (the sender policy of the moment gates every send), safety-6 (jobs and consents bound to a
/// provider) — end to end through the triage lane with zero-quota mocks.
@Suite(.serialized) struct RFATriageGateTests {
    typealias K = MailSyncKit
    typealias R = RFAKit

    // MARK: safety-1 / integrity-2 — relaunch

    /// Captured as `queued` but never post-processed (no hand-off yet): launch recovery must not
    /// send them (nothing was counted); post-processing's `messageReady` hands them off through
    /// the cap like any new message.
    @Test func capturedButNeverHandedOffRowsAreNotSentAtLaunch() async throws {
        let mock = MockAgentProvider()
        let env = try await R.make(mode: .mock, mail: K.mailSettings(dailyMax: 1), mock: mock, start: false)
        do {
            var rows: [MailMessage] = []
            for n in 1...3 { rows.append(try await R.insertAlert(env, n)) }
            await env.engine.start()
            try await Task.sleep(for: .milliseconds(400))
            #expect(await mock.calls == 0)
            for m in rows { #expect(await R.triageState(env, m.internetMessageID) == .queued) }
            #expect(await env.engine.mailTriage.usage().used == 0)

            for m in rows { await env.engine.mailTriage.messageReady(pk: m.pk) }
            #expect(await K.eventually { await R.triageState(env, rows[0].internetMessageID) == .done })
            for m in rows.dropFirst() {
                let held = try await env.message(m.internetMessageID)
                #expect(held.triageState == .held)
                #expect(held.triageNotBefore == LocalDate(year: 2026, month: 10, day: 1).startOfDay(calendar: K.calendar))
            }
            #expect(await mock.calls == 1)
            #expect(await env.engine.mailTriage.usage().used == 1)
        } catch {
            await env.cleanup()
            throw error
        }
        await env.cleanup()
    }

    /// A job in the lane at quit: counted today → recovered without counting again; handed off
    /// on an earlier day (not in today's record) → counted today, so the cap holds it.
    @Test func recoveryCountsEachJobOnceAndHonoursTheCap() async throws {
        let mock = MockAgentProvider()
        let env = try await R.make(mode: .mock, mail: K.mailSettings(dailyMax: 1), mock: mock, start: false)
        do {
            let today = try await R.insertAlert(env, 1, stdinBytes: 900)
            let older = try await R.insertAlert(env, 2, state: .limited, stdinBytes: 900)
            try await R.setDayRecord(env, n: 1, open: [today.pk])
            await env.engine.start()
            #expect(await K.eventually { await R.triageState(env, today.internetMessageID) == .done })
            #expect(await K.eventually { await R.triageState(env, older.internetMessageID) == .held })
            #expect(await mock.calls == 1)
            #expect(await env.engine.mailTriage.usage().used == 1)
            #expect(try await env.message(older.internetMessageID).triageError?.contains("limit") == true)
        } catch {
            await env.cleanup()
            throw error
        }
        await env.cleanup()
    }

    // MARK: safety-2 / runtime-1 — the policy of the moment

    @Test func heldTriageOfASenderSwitchedToAskWaitsForConsent() async throws {
        let mock = MockAgentProvider()
        try await R.run(mode: .mock, mail: K.mailSettings(dailyMax: 1), mock: mock) { env in
            await env.source().add("a1.eml", try R.alert(1))
            await env.source().add("a2.eml", try R.alert(2))
            await env.sync()
            #expect(await K.eventually { await R.triageState(env, R.alertID(1)) == .done })
            #expect(await K.eventually { await R.triageState(env, R.alertID(2)) == .held })

            R.updateRule(env, K.biorxivRule.id) { $0.aiPolicy = .ask }
            env.clock.value = LocalDate(year: 2026, month: 10, day: 1).startOfDay(calendar: K.calendar).addingTimeInterval(60)
            await env.engine.mail.settingsDidChange()
            #expect(await K.eventually { await R.triageState(env, R.alertID(2)) == .awaitingConsent })
            try await Task.sleep(for: .milliseconds(300))
            #expect(await mock.calls == 1)
            let card = try #require(try await env.engine.mailCard(id: try await env.message(R.alertID(2)).id))
            #expect(card.canRequestAI)
        }
    }

    @Test func heldTriageOfADeletedOrDisabledRuleIsNotSent() async throws {
        let mock = MockAgentProvider()
        try await R.run(mode: .mock, mail: K.mailSettings(dailyMax: 1), mock: mock) { env in
            for n in 1...3 { await env.source().add("a\(n).eml", try R.alert(n)) }
            await env.sync()
            #expect(await K.eventually { await R.triageState(env, R.alertID(1)) == .done })
            #expect(await K.eventually { await R.triageState(env, R.alertID(3)) == .held })
            // Disabled: `always` no longer sends by itself.
            R.updateRule(env, K.biorxivRule.id) { $0.enabled = false }
            env.clock.value = LocalDate(year: 2026, month: 10, day: 1).startOfDay(calendar: K.calendar).addingTimeInterval(60)
            await env.engine.mail.settingsDidChange()
            #expect(await K.eventually {
                let second = await R.triageState(env, R.alertID(2))
                let third = await R.triageState(env, R.alertID(3))
                return second == .awaitingConsent && third == .awaitingConsent
            })
            // Deleted: the same.
            R.updateRule(env, K.biorxivRule.id) { $0.enabled = true }
            env.mail.update { $0.senders.removeAll { $0.id == K.biorxivRule.id } }
            try await env.db.modifyMailMessage(pk: try await env.message(R.alertID(2)).pk) { $0.triageState = .failed }
            await env.engine.mail.settingsDidChange()
            #expect(await K.eventually { await R.triageState(env, R.alertID(2)) == .awaitingConsent })
            try await Task.sleep(for: .milliseconds(300))
            #expect(await mock.calls == 1)
        }
    }

    /// Set to `never` while the message was still being post-processed: the hand-off refuses it.
    @Test func neverSetBeforeTheHandOffIsHonoured() async throws {
        let mock = MockAgentProvider()
        try await R.run(mode: .mock, mock: mock) { env in
            let m = try await R.insertAlert(env, 1)
            R.updateRule(env, K.biorxivRule.id) { $0.aiPolicy = .never }
            await env.engine.mailTriage.messageReady(pk: m.pk)
            try await Task.sleep(for: .milliseconds(300))
            #expect(await mock.calls == 0)
            #expect(await R.triageState(env, m.internetMessageID) == MailTriageState.none)
            #expect(await env.engine.mailTriage.usage().used == 0)
        }
    }

    /// Rows waiting outside the lane (captured, held, failed) follow a switch to `ask` at once.
    @Test func askWithdrawsRowsWaitingOutsideTheLane() async throws {
        let mock = MockAgentProvider()
        try await R.run(mode: .mock, mock: mock) { env in
            let captured = try await R.insertAlert(env, 1)
            let failed = try await R.insertAlert(env, 2, state: .failed, stdinBytes: 900)
            R.updateRule(env, K.biorxivRule.id) { $0.aiPolicy = .ask }
            await env.engine.mail.settingsDidChange()
            #expect(await R.triageState(env, captured.internetMessageID) == .awaitingConsent)
            #expect(await R.triageState(env, failed.internetMessageID) == .awaitingConsent)
            #expect(await mock.calls == 0)
        }
    }

    @Test func switchingToAskWithdrawsLaneJobsAndRefundsThem() async throws {
        let mock = MockAgentProvider(delay: .milliseconds(500))
        try await R.run(mode: .mock, mock: mock) { env in
            for n in 1...3 { await env.source().add("a\(n).eml", try R.alert(n)) }
            await env.sync()
            #expect(await K.eventually { await env.engine.agents.triageStatus().runningMessagePK != nil })
            let running = await env.engine.agents.triageStatus().runningMessagePK
            R.updateRule(env, K.biorxivRule.id) { $0.aiPolicy = .ask }
            await env.engine.mail.settingsDidChange()
            #expect(await env.engine.agents.queuedTriageMessagePKs().isEmpty)
            #expect(await K.eventually {
                var waiting = 0
                for n in 1...3 where await R.triageState(env, R.alertID(n)) == .awaitingConsent { waiting += 1 }
                return waiting == 3
            })
            try await Task.sleep(for: .milliseconds(700))
            #expect(await mock.calls <= 1)                          // only the one already running
            #expect(await env.engine.mailTriage.usage().used == 0)
            #expect(running != nil)
        }
    }

    // MARK: consent (K5) and provider binding (safety-6)

    @Test func consentIsStoredAndCarriesAHeldRequest() async throws {
        let mock = MockAgentProvider()
        try await R.run(mode: .off, mock: mock) { env in
            await env.source().add("advisor.eml", try K.data("advisor-request-pdf"))
            await env.sync()
            let m = try await env.message("<caf3xyz+abc123@mail.gmail.com>")
            #expect(m.triageState == .awaitingConsent && !m.triageConsented)
            _ = try await env.engine.requestMailAI(messageID: m.id)
            #expect(await K.eventually { await R.triageState(env, m.internetMessageID) == .held })
            let held = try await env.message(m.internetMessageID)
            #expect(held.triageConsented && held.triageConsentProvider == "claude")

            env.settings.update { $0.agentMode = .mock }
            await env.engine.agentProviderDidChange()
            #expect(await K.eventually { await R.triageState(env, m.internetMessageID) == .done })
            #expect(await mock.calls == 1)
        }
    }

    /// The consent named Claude; the user then moved mail triage to Codex: it is asked again.
    @Test func aHeldConsentIsNotReleasedToAnotherProvider() async throws {
        let codex = MockAgentProvider()
        try await R.run(mode: .off, codex: codex) { env in
            await env.source().add("advisor.eml", try K.data("advisor-request-pdf"))
            await env.sync()
            let m = try await env.message("<caf3xyz+abc123@mail.gmail.com>")
            _ = try await env.engine.requestMailAI(messageID: m.id)
            #expect(await K.eventually { await R.triageState(env, m.internetMessageID) == .held })

            env.mail.update { $0.triageProvider = .codex }
            env.settings.update { $0.agentMode = .codex }
            await env.engine.agentProviderDidChange()
            await env.engine.mail.settingsDidChange()
            #expect(await K.eventually { await R.triageState(env, m.internetMessageID) == .awaitingConsent })
            try await Task.sleep(for: .milliseconds(300))
            #expect(await codex.calls == 0)
            let again = try await env.message(m.internetMessageID)
            #expect(!again.triageConsented && again.triageConsentProvider == nil)
        }
    }

    /// Jobs built for Claude are withdrawn when mail triage moves to Codex — not run on Claude.
    @Test func aProviderSwitchWithdrawsLaneJobsBuiltForTheOldProvider() async throws {
        let claude = MockAgentProvider(delay: .milliseconds(800))
        let codex = MockAgentProvider()
        try await R.run(mode: .claude, claude: claude, codex: codex) { env in
            for n in 1...3 { await env.source().add("a\(n).eml", try R.alert(n)) }
            await env.sync()
            #expect(await K.eventually { await claude.calls == 1 })
            env.mail.update { $0.triageProvider = .codex }
            await env.engine.mail.settingsDidChange()
            #expect(await env.engine.agents.queuedTriageMessagePKs().isEmpty)
            try await Task.sleep(for: .milliseconds(1200))
            #expect(await claude.calls == 1)                       // only the one already running (terminated)
            #expect(await codex.calls == 0)                        // agent.mode still runs Claude
            for n in 1...3 {
                let m = try await env.message(R.alertID(n))
                #expect(m.triageState == .held)
                #expect(m.triageError == "Mail triage may only use ChatGPT; the AI mode is Claude")
            }
            #expect(await env.engine.mailTriage.laneMessagePKs().isEmpty)
        }
    }

    // MARK: Pure policy (K4, safety-7, safety-10)

    @Test func initialStateHonoursAuthenticationAndBulkHeaders() {
        let ai = MailSettings(aiMode: .ai)
        let alert = SenderRule(pattern: "@nature.com", kind: .alert)              // always
        let never = SenderRule(pattern: "x@nature.com", kind: .alert, aiPolicy: .never)
        let person = SenderRule(pattern: "a@b.org", kind: .person)
        var disabled = alert
        disabled.enabled = false
        typealias C = MailTriageCoordinator
        // Defaults reproduce the old behaviour.
        #expect(C.initialState(senderKind: .alert, rule: alert, candidates: 2, settings: ai) == .queued)
        // DMARC/DKIM failed → consent (never stays never).
        #expect(C.initialState(senderKind: .alert, rule: alert, candidates: 2, settings: ai, authState: .fail) == .awaitingConsent)
        #expect(C.initialState(senderKind: .alert, rule: never, candidates: 2, settings: ai, authState: .fail) == MailTriageState.none)
        #expect(C.initialState(senderKind: .alert, rule: alert, candidates: 2, settings: ai, authState: .pass) == .queued)
        // Not bulk mail from an alert rule (an editor's own email) → consent.
        #expect(C.initialState(senderKind: .alert, rule: alert, candidates: 2, settings: ai, isBulk: false) == .awaitingConsent)
        #expect(C.initialState(senderKind: .alert, rule: alert, candidates: 0, settings: ai, isBulk: false) == .skipped)
        #expect(C.initialState(senderKind: .person, rule: person, candidates: 1, settings: ai, isBulk: false) == .awaitingConsent)
        // A disabled `always` rule never sends by itself.
        #expect(C.initialState(senderKind: .alert, rule: disabled, candidates: 2, settings: ai) == .awaitingConsent)
    }

    @Test func permissionGate() {
        let alert = SenderRule(id: "r-alert", pattern: "@arxiv.org", kind: .alert)
        let person = SenderRule(id: "r-person", pattern: "a@b.org", kind: .person)
        let never = SenderRule(id: "r-never", pattern: "c@b.org", kind: .person, aiPolicy: .never)
        var off = SenderRule(id: "r-off", pattern: "@biorxiv.org", kind: .alert)
        off.enabled = false
        let settings = MailSettings(senders: [alert, person, never, off])
        func msg(_ rule: String?, auth: MailAuthState = .unknown, consent: String? = nil) -> MailMessage {
            MailMessage(accountID: "a", internetMessageID: "<x@y>", fromAddress: "x@y", ruleID: rule, senderKind: .alert,
                        authState: auth, subject: "s", receivedAt: K.start, triageConsented: consent != nil,
                        triageConsentProvider: consent)
        }
        typealias C = MailTriageCoordinator
        #expect(C.permission(msg("r-alert"), settings: settings, provider: .claude) == .allowed)
        #expect(C.permission(msg("r-alert", auth: .fail), settings: settings, provider: .claude) == .needsConsent)
        #expect(C.permission(msg("r-alert", auth: .fail, consent: "claude"), settings: settings, provider: .claude) == .allowed)
        #expect(C.permission(msg("r-person"), settings: settings, provider: .claude) == .needsConsent)
        #expect(C.permission(msg("r-person", consent: "claude"), settings: settings, provider: .claude) == .allowed)
        #expect(C.permission(msg("r-person", consent: "claude"), settings: settings, provider: .codex) == .needsConsent)
        #expect(C.permission(msg("r-never", consent: "claude"), settings: settings, provider: .claude) == .senderNever)
        #expect(C.permission(msg("r-off"), settings: settings, provider: .claude) == .needsConsent)
        #expect(C.permission(msg("gone"), settings: settings, provider: .claude) == .needsConsent)
        #expect(C.permission(msg(nil, consent: "codex"), settings: settings, provider: .codex) == .allowed)
        var local = settings
        local.aiMode = .heuristicOnly
        #expect(C.permission(msg("r-alert", consent: "claude"), settings: local, provider: .claude) == .aiOff)
    }

    /// safety-10: a possibly forged From (DMARC failed) is never merged automatically, even when
    /// the sender's rule says auto-merge; the same email with a passing check is.
    @Test func aFailedAuthCheckIsNeverAutoMerged() async throws {
        var mail = K.mailSettings()
        var advisor = K.advisorRule
        advisor.autoMerge = true
        mail.senders = [advisor] + mail.senders.filter { $0.id != advisor.id }
        try await R.run(mode: .off, mail: mail) { env in
            let pdf = K.realPDF(title: "Cortical progenitor dynamics in the developing human brain")
            await env.source().add("forged.eml", Self.eml(pdf, messageID: "<forged-1@wustl.edu>", auth: "dmarc=fail"))
            await env.source().add("real.eml", Self.eml(K.realPDF(title: "Radial glia lineage tracing at scale"),
                                                       messageID: "<real-1@wustl.edu>", auth: "dmarc=pass"))
            await env.sync()
            let real = try await env.message("<real-1@wustl.edu>")
            let realRow = try #require(try await env.db.mailItems(messagePK: real.pk).first { $0.origin == .attachment })
            #expect(await K.eventually { (try await env.db.mailItem(id: realRow.id))?.status == .merged })
            let forged = try await env.message("<forged-1@wustl.edu>")
            #expect(forged.authState == .fail)
            let row = try #require(try await env.db.mailItems(messagePK: forged.pk).first { $0.origin == .attachment })
            #expect(row.status == .pending && row.paperID == nil)
            #expect(try await env.db.livePapers().count == 1)
            #expect(forged.state == .pending && !forged.userTouched)
        }
    }

    static func eml(_ pdf: Data, messageID: String, auth: String) -> Data {
        let b64 = pdf.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let text = """
            Authentication-Results: mx.google.com; spf=pass; \(auth) header.from=wustl.edu
            From: Jane Smith <jsmith@wustl.edu>
            To: yi@wustl.edu
            Subject: Please read before Friday
            Date: Tue, 29 Sep 2026 14:05:00 -0500
            Message-ID: \(messageID)
            MIME-Version: 1.0
            Content-Type: multipart/mixed; boundary="b1"

            --b1
            Content-Type: text/plain; charset=utf-8

            Please read the attached paper before Friday.

            --b1
            Content-Type: application/pdf; name="paper.pdf"
            Content-Disposition: attachment; filename="paper.pdf"
            Content-Transfer-Encoding: base64

            """
        return Data((text.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n" + b64 + "\r\n--b1--\r\n").utf8)
    }

    /// A message whose DMARC check failed is captured `queued` by a build that does not pass
    /// the auth state yet — the hand-off gate still keeps it from the AI.
    @Test func aFailedAuthCheckNeverAutoTriages() async throws {
        let mock = MockAgentProvider()
        try await R.run(mode: .mock, mock: mock) { env in
            var msg = try await R.insertAlert(env, 1)
            msg = try await env.db.modifyMailMessage(pk: msg.pk) { $0.authState = .fail }
            await env.engine.mailTriage.messageReady(pk: msg.pk)
            try await Task.sleep(for: .milliseconds(300))
            #expect(await mock.calls == 0)
            #expect(await R.triageState(env, msg.internetMessageID) == .awaitingConsent)
            // The user may still ask for it.
            #expect(try await env.engine.requestMailAI(messageID: msg.id) == .queued)
            #expect(await K.eventually { await R.triageState(env, msg.internetMessageID) == .done })
        }
    }
}
