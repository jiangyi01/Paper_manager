import Foundation
import Testing
@testable import PaperDeckCore

/// MailTriageCoordinator end to end through AgentQueue's triage lane with zero-quota providers
/// (mode mock / off): alerts automatically within the daily cap, people only after consent,
/// heuristicOnly / never → no agent call at all, mode off → held, result reconciliation incl.
/// verified vs dropped model-only papers, failures, restart recovery.
@Suite(.serialized) struct MailSyncTriageTests {
    typealias K = MailSyncKit

    private static func alert(_ n: Int) throws -> Data {
        try K.variant("biorxiv-alert", messageID: "<alert-\(n)@alerts.highwire.org>")
    }

    private static func triageState(_ env: K.Env, _ mid: String) async -> MailTriageState? {
        try? await env.db.mailMessage(internetMessageID: mid)?.triageState
    }

    // MARK: Alerts: automatic, capped

    @Test func alertsAreTriagedAutomaticallyWithinTheDailyCap() async throws {
        let mock = MockAgentProvider()
        try await K.run(mode: .mock, mail: K.mailSettings(dailyMax: 1), mock: mock) { env in
            await env.source().add("a1.eml", try Self.alert(1))
            await env.source().add("a2.eml", try Self.alert(2))
            await env.sync()

            #expect(await K.eventually { await Self.triageState(env, "<alert-1@alerts.highwire.org>") == .done })
            #expect(await K.eventually { await Self.triageState(env, "<alert-2@alerts.highwire.org>") == .held })
            let first = try await env.message("<alert-1@alerts.highwire.org>")
            #expect(first.triageSource == .ai)
            #expect(first.triageProvider == "mock")
            #expect(first.triage?.requestKind == .alertDigest)
            #expect(first.state == .pending)
            #expect((first.triageStdinBytes ?? 0) > 0)
            let second = try await env.message("<alert-2@alerts.highwire.org>")
            #expect(second.triageError?.contains("limit") == true)
            let tomorrow = LocalDate(year: 2026, month: 10, day: 1).startOfDay(calendar: K.calendar)
            #expect(second.triageNotBefore == tomorrow)
            #expect(await env.engine.mailTriage.usage() == MailTriageUsage(day: LocalDate(year: 2026, month: 9, day: 30),
                                                                           used: 1, limit: 1))
            #expect(await mock.calls == 1)

            // The stdin carries markers, never the raw (tracking) URLs.
            let stdin = String(decoding: try #require(await mock.lastRequest).stdin, as: UTF8.self)
            #expect(!stdin.contains("utm_source"))
            #expect(!stdin.contains("https://"))

            // Next day: released by the maintenance tick.
            env.clock.value = tomorrow.addingTimeInterval(60)
            await env.engine.mail.settingsDidChange()
            #expect(await K.eventually { await Self.triageState(env, "<alert-2@alerts.highwire.org>") == .done })
            #expect(await mock.calls == 2)
            #expect(await env.engine.mailTriage.usage().used == 1)
            #expect(await env.engine.mailTriage.usage().day == LocalDate(year: 2026, month: 10, day: 1))
        }
    }

    // MARK: People: consent first

    @Test func personMailWaitsForConsentThenRuns() async throws {
        let mock = MockAgentProvider()
        try await K.run(mode: .mock, mock: mock) { env in
            await env.source().add("advisor.eml", try K.data("advisor-request-pdf"))
            await env.sync()
            let m = try await env.message("<caf3xyz+abc123@mail.gmail.com>")
            #expect(m.triageState == .awaitingConsent)
            try await Task.sleep(for: .milliseconds(150))
            #expect(await mock.calls == 0)
            let card = try #require(try await env.engine.mailCard(id: m.id))
            #expect(card.canRequestAI)

            #expect(try await env.engine.requestMailAI(messageID: m.id) == .queued)
            #expect(await K.eventually { await Self.triageState(env, m.internetMessageID) == .done })
            #expect(await mock.calls == 1)
            let done = try await env.message(m.internetMessageID)
            #expect(done.triageSource == .ai)
            #expect(done.triage?.requestKind == .journalClub)     // "lab meeting"
            #expect(done.state == .pending)
            let att = try #require(try await env.db.mailItems(messagePK: m.pk).first { $0.origin == .attachment })
            #expect(att.relevance == .requested)
            #expect(att.why?.contains("MOCK") == true)
        }
    }

    @Test func consentBypassesTheCapButStillCounts() async throws {
        let mock = MockAgentProvider()
        try await K.run(mode: .mock, mail: K.mailSettings(dailyMax: 0), mock: mock) { env in
            await env.source().add("advisor.eml", try K.data("advisor-request-pdf"))
            await env.sync()
            let m = try await env.message("<caf3xyz+abc123@mail.gmail.com>")
            try await env.engine.requestMailAI(messageID: m.id)
            #expect(await K.eventually { await Self.triageState(env, m.internetMessageID) == .done })
            #expect(await env.engine.mailTriage.usage().used == 1)
        }
    }

    @Test func neverAndHeuristicOnlyNeverReachTheAgent() async throws {
        let mock = MockAgentProvider()
        var mail = K.mailSettings()
        mail.senders = [SenderRule(id: "rule-colleague", pattern: "@wustl.edu", kind: .person, aiPolicy: .never),
                        K.biorxivRule]
        try await K.run(mode: .mock, mail: mail, mock: mock) { env in
            await env.source().add("share.eml", try K.data("colleague-share"))
            await env.sync()
            let share = try await env.message("<share-7781@wustl.edu>")
            #expect(share.triageState == MailTriageState.none)
            await #expect(throws: MailTriageError.senderNever) { try await env.engine.requestMailAI(messageID: share.id) }
            #expect(try #require(try await env.engine.mailCard(id: share.id)).canRequestAI == false)

            // Local rules only: even an alert (policy always) stays local; consent is refused too.
            env.mail.update { $0.aiMode = .heuristicOnly }
            await env.source().add("a1.eml", try Self.alert(1))
            await env.sync()
            let alert = try await env.message("<alert-1@alerts.highwire.org>")
            #expect(alert.triageState == MailTriageState.none)
            #expect(alert.triageSource == .heuristic)
            await #expect(throws: MailTriageError.aiDisabled) { try await env.engine.requestMailAI(messageID: alert.id) }
            try await Task.sleep(for: .milliseconds(150))
            #expect(await mock.calls == 0)
        }
    }

    @Test func switchingToLocalRulesWithdrawsQueuedJobs() async throws {
        let mock = MockAgentProvider(delay: .milliseconds(400))
        try await K.run(mode: .mock, mock: mock) { env in
            await env.source().add("a1.eml", try Self.alert(1))
            await env.source().add("a2.eml", try Self.alert(2))
            await env.sync()
            #expect(await K.eventually { await env.engine.agents.triageStatus().runningMessagePK != nil })
            env.mail.update { $0.aiMode = .heuristicOnly }
            await env.engine.mail.settingsDidChange()
            #expect(await K.eventually {
                let a = await Self.triageState(env, "<alert-1@alerts.highwire.org>")
                let b = await Self.triageState(env, "<alert-2@alerts.highwire.org>")
                return a == MailTriageState.none && b == MailTriageState.none
            })
            try await Task.sleep(for: .milliseconds(600))
            #expect(await mock.calls <= 1)                    // only the one already running
            #expect(await env.engine.mailTriage.usage().used == 0)
        }
    }

    // MARK: agent.mode off → held, released on switch

    @Test func modeOffHoldsTheTriageAndASwitchReleasesIt() async throws {
        let mock = MockAgentProvider()
        try await K.run(mode: .off, mock: mock) { env in
            await env.source().add("a1.eml", try Self.alert(1))
            await env.sync()
            #expect(await K.eventually { await Self.triageState(env, "<alert-1@alerts.highwire.org>") == .held })
            let held = try await env.message("<alert-1@alerts.highwire.org>")
            #expect(held.triageError == "AI is off · the email was not sent to AI")
            #expect(held.triageNotBefore == nil)
            #expect(await env.engine.mailTriage.usage().used == 0)      // refunded: nothing was sent
            #expect(await mock.calls == 0)

            // A tick while still off keeps it held (no churn, no WOULD RUN spam).
            await env.engine.mail.settingsDidChange()
            #expect(await Self.triageState(env, held.internetMessageID) == .held)

            env.settings.update { $0.agentMode = .mock }
            await env.engine.agentProviderDidChange()           // the queue publishes the new mode
            #expect(await K.eventually { await Self.triageState(env, held.internetMessageID) == .done })
            #expect(await mock.calls == 1)
        }
    }

    // MARK: Results

    private static let reconcileAnswer: JSONValue = .object([
        "has_reading_request": .bool(true),
        "request_kind": .string("advisor_request"),
        "summary": .string("Asks you to read the attached paper before Thursday."),
        "requester": .string("Jane Smith"),
        "due_date": .null, "due_evidence": .null,
        "priority": .string("high"),
        "papers": .array([
            .object(["ref": .string("c1"), "title": .null, "doi": .null, "arxiv_id": .null,
                     "relevance": .string("requested"), "why": .string("Attached for the lab meeting"),
                     "confidence": .number(0.9)]),
            // Model-only, verifiable: Crossref knows this DOI with this title.
            .object(["ref": .null, "title": .string("Molecular and cellular dynamics of the developing human neocortex"),
                     "doi": .string("10.1038/s41586-024-08351-7"), "arxiv_id": .null,
                     "relevance": .string("highlighted"), "why": .string("Background for Fig. 2"),
                     "confidence": .number(0.7)]),
            // Model-only, invented: no Crossref match → dropped.
            .object(["ref": .null, "title": .string("Dragons of the upper cortex: a hallucinated survey of nothing"),
                     "doi": .null, "arxiv_id": .null, "relevance": .string("highlighted"), "why": .string("x"),
                     "confidence": .number(0.6)]),
            .object(["ref": .null, "title": .null, "doi": .string("10.9999/fake.12345"), "arxiv_id": .null,
                     "relevance": .string("highlighted"), "why": .string("y"), "confidence": .number(0.6)]),
        ]),
    ])

    @Test func resultsReconcileRowsAndOnlyVerifiedModelPapersBecomeRows() async throws {
        let provider = K.ScriptedTriage(Self.reconcileAnswer)
        let fetcher = K.Fetcher()
        try await K.run(mode: .mock, fetcher: fetcher, mock: provider, metadata: true) { env in
            await env.source().add("advisor.eml", try K.data("advisor-request-pdf"))
            await env.sync()
            let m = try await env.message("<caf3xyz+abc123@mail.gmail.com>")
            try await env.engine.requestMailAI(messageID: m.id)
            #expect(await K.eventually { await Self.triageState(env, m.internetMessageID) == .done })
            #expect(await K.eventually { try await env.db.mailItems(messagePK: m.pk).contains { $0.foundBy == .ai } })
            await env.engine.mailTriage.waitForVerification()

            let done = try await env.message(m.internetMessageID)
            #expect(done.state == .pending)
            #expect(done.triage?.priority == .high)
            #expect(done.triage?.summary == "Asks you to read the attached paper before Thursday.")
            let items = try await env.db.mailItems(messagePK: m.pk)
            let att = try #require(items.first { $0.cand == "c1" })
            #expect(att.relevance == .requested)
            #expect(att.why == "Attached for the lab meeting")
            #expect(att.confidence == 0.9)

            let ai = items.filter { $0.foundBy == .ai }
            #expect(ai.count == 1)
            let cited = try #require(ai.first)
            #expect(cited.origin == .citation)
            #expect(cited.ids.doi == "10.1038/s41586-024-08351-7")
            #expect(cited.title == "Molecular and cellular dynamics of the developing human neocortex")
            #expect(cited.metaSource == .crossref)
            #expect(cited.venue == "Nature")
            #expect(cited.pdfState == .needsPDF)                  // never downloadable from a model's ids
            #expect(cited.url == nil && cited.urlOriginal == nil)
            #expect(cited.relevance == .highlighted)
            #expect(cited.ord == (items.filter { $0.foundBy != .ai }.map(\.ord).max() ?? 0) + 1)
            #expect(!items.contains { $0.title?.contains("Dragons") == true || $0.ids.doi == "10.9999/fake.12345" })
            // Only metadata APIs were asked — nothing from the mail or the model was opened.
            #expect(fetcher.requested.allSatisfy { u in
                ["api.crossref.org", "api.openalex.org", "api.biorxiv.org", "export.arxiv.org"].contains { u.contains($0) }
            })
        }
    }

    @Test func verificationRules() {
        let hint = MailTriageSanitizer.PaperHint(title: "Molecular and cellular dynamics of the developing human neocortex",
                                                 unverifiedIDs: PaperIDs(doi: "10.1038/s41586-024-08351-7"))
        let same = BiblioMetadata(title: "Molecular and cellular dynamics of the developing human neocortex",
                                  ids: PaperIDs(doi: "10.1038/s41586-024-08351-7"), source: .crossref)
        let otherTitle = BiblioMetadata(title: "Zebrafish fin regeneration at single-cell resolution",
                                        ids: PaperIDs(doi: "10.1038/s41586-024-08351-7"), source: .crossref)
        let ids = hint.unverifiedIDs
        #expect(MailTriageCoordinator.verifies(same, hint: hint, ids: ids))
        #expect(!MailTriageCoordinator.verifies(otherTitle, hint: hint, ids: ids))   // hallucinated pairing
        let doiOnly = MailTriageSanitizer.PaperHint(unverifiedIDs: PaperIDs(doi: "10.1101/2026.09.25.614123"))
        let preprint = BiblioMetadata(title: "Multiplexed imaging", ids: PaperIDs(doi: "10.64898/2026.09.25.614123"),
                                      source: .biorxiv)
        #expect(MailTriageCoordinator.verifies(preprint, hint: doiOnly, ids: doiOnly.unverifiedIDs))
        let unrelated = BiblioMetadata(title: "Something else", ids: PaperIDs(doi: "10.1016/j.cell.2024.11.015"), source: .crossref)
        #expect(!MailTriageCoordinator.verifies(unrelated, hint: doiOnly, ids: doiOnly.unverifiedIDs))
    }

    private static let notPaperAnswer: JSONValue = .object([
        "has_reading_request": .bool(false), "request_kind": .string("not_paper"),
        "summary": .string("Scheduling note."), "requester": .null, "due_date": .null, "due_evidence": .null,
        "priority": .string("normal"), "papers": .array([]),
    ])

    @Test func aiNeverOverridesAUserAction() async throws {
        let provider = K.ScriptedTriage(Self.notPaperAnswer)
        try await K.run(mode: .mock, mock: provider) { env in
            await env.source().add("advisor.eml", try K.data("advisor-request-pdf"))
            await env.source().add("share.eml", try K.data("colleague-share"))
            await env.sync()
            let touched = try await env.message("<caf3xyz+abc123@mail.gmail.com>")
            let plain = try await env.message("<share-7781@wustl.edu>")
            try await env.db.modifyMailMessage(pk: touched.pk) { $0.userTouched = true }
            try await env.engine.requestMailAI(messageID: touched.id)
            try await env.engine.requestMailAI(messageID: plain.id)
            #expect(await K.eventually {
                let a = await Self.triageState(env, touched.internetMessageID)
                let b = await Self.triageState(env, plain.internetMessageID)
                return a == .done && b == .done
            })
            let t = try await env.message(touched.internetMessageID)
            #expect(t.state == .pending)                           // the user's decision stands
            #expect(t.triage?.requestKind == .notPaper)
            let p = try await env.message(plain.internetMessageID)
            #expect(p.state == .noRequest)
            #expect(p.handledAt != nil)
        }
    }

    @Test func failuresAreRetriedAfterABackoff() async throws {
        let mock = MockAgentProvider(script: [.invalidOutput])
        try await K.run(mode: .mock, mock: mock) { env in
            await env.source().add("a1.eml", try Self.alert(1))
            await env.sync()
            let mid = "<alert-1@alerts.highwire.org>"
            #expect(await K.eventually { await Self.triageState(env, mid) == .failed })
            let failed = try await env.message(mid)
            #expect(failed.triageAttempt == 1)
            #expect(failed.triageError == "The AI returned an invalid result")
            #expect(failed.triageNotBefore == env.clock.value.addingTimeInterval(300))

            await env.engine.mail.settingsDidChange()            // not due yet
            try await Task.sleep(for: .milliseconds(100))
            #expect(await Self.triageState(env, mid) == .failed)
            env.advance(301)
            await env.engine.mail.settingsDidChange()
            #expect(await K.eventually { await Self.triageState(env, mid) == .done })
            #expect(await mock.calls == 2)
        }
    }

    @Test func usageLimitShowsLimitedWhileTheLaneWaits() async throws {
        let mock = MockAgentProvider(script: [.usageLimit(resetsAt: MailSyncKit.start.addingTimeInterval(3600))])
        try await K.run(mode: .mock, mock: mock) { env in
            await env.source().add("a1.eml", try Self.alert(1))
            await env.sync()
            #expect(await K.eventually { await Self.triageState(env, "<alert-1@alerts.highwire.org>") == .limited })
            let m = try await env.message("<alert-1@alerts.highwire.org>")
            #expect(m.triageError?.contains("usage limit") == true)
            #expect(await env.engine.agents.queuedTriageMessagePKs() == [m.pk])
        }
    }

    // MARK: Restart

    @Test func launchReEnqueuesInterruptedTriage() async throws {
        let mock = MockAgentProvider()
        let env = try await K.make(mode: .mock, mock: mock, start: false)
        do {
            var pks: [Int64] = []
            for (n, state) in [(1, MailTriageState.running), (2, .queued), (3, .limited)] {
                // Handed off to the lane before the restart (handOff records the stdin size).
                var msg = MailMessage(accountID: "acct-a", internetMessageID: "<restart-\(n)@alerts.highwire.org>",
                                      fromAddress: "biorxiv@alerts.highwire.org", ruleID: K.biorxivRule.id,
                                      senderKind: .alert, subject: "bioRxiv alert \(n)", receivedAt: K.start,
                                      bodyText: "New results [c1 biorxiv.org]", triageState: state)
                msg.triageStdinBytes = 512
                let item = MailItem(ord: 1, cand: "c1", origin: .alertEntry, title: "Spatial atlas \(n)",
                                    ids: PaperIDs(doi: "10.1101/2026.09.2\(n).61412\(n)"), pdfState: .downloadable)
                pks.append(try await env.db.insertMailMessage(msg, items: [item]).0.pk)
            }
            // …and counted today when they were handed off (the daily cap's own record).
            try await env.db.setKV(MailTriageCoordinator.dayKey,
                                   #"{"day":"2026-09-30","n":3,"open":["# + pks.map(String.init).joined(separator: ",") + "]}")
            await env.engine.start()
            #expect(await K.eventually {
                for pk in pks where (try await env.db.mailMessage(pk: pk))?.triageState != .done { return false }
                return true
            })
            #expect(await mock.calls == 3)
            #expect(await env.engine.mailTriage.usage().used == 3)    // counted before the restart, not again
        } catch {
            await env.cleanup()
            throw error
        }
        await env.cleanup()
    }
}
