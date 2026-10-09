import Foundation
import Testing
@testable import PaperDeckCore
import PaperDeckConfig

/// The Getting Started checklist: rows, visibility, progress, and who sees the Today card.
@Suite("Getting Started")
struct GettingStartedTests {
    typealias S = GuideSamples
    typealias G = GettingStarted

    private func item(_ items: [G.Item], _ id: String) -> G.Item? { items.first { $0.id == id } }

    @Test func theRowsAreTheTableInOrder() {
        let items = G.items(S.facts(), skipped: [], mailDecision: nil)
        #expect(items.map(\.id) == G.allIDs)
        #expect(Set(items.filter(\.required).map(\.id)) == [G.library, G.firstPaper, G.ai])
        for id in G.allIDs {
            let t = G.title(id)
            #expect(!t.en.isEmpty && !t.zh.isEmpty && t.en != id)
        }
    }

    @Test func visibility() {
        // Senders only once an account exists; the backup row only with ≥ 10 papers.
        var items = G.items(S.facts(), skipped: [], mailDecision: nil)
        #expect(item(items, G.senders)?.visible == false)
        #expect(item(items, G.backup)?.visible == false)
        let busy = S.facts {
            $0.papers = .value(PaperCounts(live: 12))
            $0.mail = MailFact(accounts: [MailAccountFact(id: "a", source: .imapGmail)])
        }
        items = G.items(busy, skipped: [], mailDecision: nil)
        #expect(item(items, G.senders)?.visible == true)
        #expect(item(items, G.backup)?.visible == true)
        #expect(item(G.items(S.facts { $0.papers = .value(PaperCounts(live: 12)); $0.features = [] },
                             skipped: [], mailDecision: nil), G.backup)?.visible == false)
        // "Not using mail" instead of the mail row.
        for decision in ["skipped", "dragOnly"] {
            #expect(item(G.items(S.facts(), skipped: [], mailDecision: decision), G.mail)?.state == .notApplicable)
        }
        #expect(item(G.items(S.facts(), skipped: [], mailDecision: "configured"), G.mail)?.state == .todo)
        // Skipped optional rows hide; required rows can't be skipped.
        items = G.items(S.facts(), skipped: [G.login, G.library], mailDecision: nil)
        #expect(item(items, G.login)?.visible == false)
        #expect(item(items, G.library)?.visible == true)
    }

    @Test func liveStates() {
        let f = S.facts {
            $0.papers = .value(PaperCounts(live: 2))
            $0.ai.decision = "none"
            $0.activity[.panelDrop] = Date()
            $0.notifications = .value(NotificationFact(authorization: .authorized, reminderEnabled: true))
        }
        let items = G.items(f, skipped: [], mailDecision: nil)
        for id in [G.library, G.firstPaper, G.ai, G.dropStrip, G.reminder] { #expect(item(items, id)?.state == .done, "\(id)") }
        // The reminder row doesn't apply while the reminder is off.
        let off = S.facts { $0.notifications = .value(NotificationFact(authorization: .notDetermined, reminderEnabled: false)) }
        #expect(item(G.items(off, skipped: [], mailDecision: nil), G.reminder)?.state == .notApplicable)
        // The widget: placed counts; when macOS doesn't say, registered + the one manual tick.
        let unknownPlacement = S.facts { $0.widget = .value(WidgetFact(registration: .registered, placedCount: nil)) }
        #expect(item(G.items(unknownPlacement, skipped: [], mailDecision: nil), G.widget)?.state == .todo)
        #expect(item(G.items(unknownPlacement, skipped: [], mailDecision: nil, manualDone: [G.widgetManualKey]), G.widget)?.state == .done)
        let placed = S.facts { $0.widget = .value(WidgetFact(registration: .registered, placedCount: 1)) }
        #expect(item(G.items(placed, skipped: [], mailDecision: nil), G.widget)?.state == .done)
        // AI on but signed out: a problem with its reason.
        let signedOut = S.facts { $0.ai = AIFact(mode: .claude, provider: .claude, statuses: [.claude: .value(.notLoggedIn("logged_out"))]) }
        if case .problem? = item(G.items(signedOut, skipped: [], mailDecision: nil), G.ai)?.state {} else { Issue.record("expected a problem") }
    }

    @Test func progressCountsVisibleApplicableRows() {
        let f = S.facts { $0.papers = .value(PaperCounts(live: 1)); $0.ai.decision = "none" }
        let items = G.items(f, skipped: [G.login], mailDecision: "skipped")
        let p = G.progress(items)
        // Visible: 11 rows − login (skipped) − senders − backup = 8; mail doesn't apply → 7.
        #expect(p.total == 7)
        #expect(p.done == 3)          // library, first paper, AI
        #expect(G.progress([]).total == 0 && G.progress([]).done == 0)
    }

    @Test func onlyAFreshInstallSeesTheTodayCard() {
        let open = G.items(S.facts(), skipped: [], mailDecision: nil)
        #expect(G.showOnToday(origin: .fresh, dismissed: false, items: open))
        #expect(!G.showOnToday(origin: .legacy, dismissed: false, items: open))     // the current user: never
        #expect(!G.showOnToday(origin: .fresh, dismissed: true, items: open))
        let done = G.items(S.facts { $0.papers = .value(PaperCounts(live: 1)); $0.ai.decision = "none" }, skipped: [], mailDecision: nil)
        #expect(!G.showOnToday(origin: .fresh, dismissed: false, items: done))      // every required row done
    }

    @Test func everyRowTopicIsACatalogID() {
        for id in G.allIDs { if let t = G.topic(id) { #expect(GuideTopicID.catalog.contains(t)) } }
    }
}

/// The preflight gate: only a never-set-up fresh install (persisted values only).
@Suite("Onboarding gate")
struct OnboardingGateTests {
    private func gate(_ v: [String: Any], db: Bool = false, root: Bool = false) -> Bool {
        OnboardingGate.needsPreflight(PersistedDomain(v), databaseExists: db, rootOverride: root)
    }

    @Test func truthTable() {
        let fresh: [String: Any] = [ConfigKeys.origin: "fresh"]
        #expect(gate(fresh))
        #expect(gate(fresh.merging(["language": "zh", ConfigKeys.profileField: "csML"]) { a, _ in a }))   // harmless keys
        #expect(!gate(fresh, db: true))
        #expect(!gate(fresh, root: true))
        #expect(!gate(fresh.merging(["setup.completed": false]) { a, _ in a }))
        #expect(!gate(fresh.merging(["library.path": "/Users/example/Documents/PaperDeck"]) { a, _ in a }))
        #expect(!gate(fresh.merging([ConfigKeys.onboardingLegacy: true]) { a, _ in a }))
        #expect(gate(fresh.merging([ConfigKeys.onboardingLegacy: false]) { a, _ in a }))
        #expect(!gate([ConfigKeys.origin: "legacy"]))
    }

    /// The current user's shape: setup completed, a library, a database — never the preflight.
    @Test func theLegacyFixtureNeverSeesThePreflight() throws {
        let p = PersistedDomain(try GoldenFixtures.plist("legacy-washu-domain"))
        #expect(!OnboardingGate.needsPreflight(p, databaseExists: true, rootOverride: false))
        #expect(!OnboardingGate.needsPreflight(p, databaseExists: false, rootOverride: false))
    }

    /// No origin stored yet (the migration didn't run): the legacy detector's answer.
    @Test func aMissingOriginFollowsTheDetector() {
        let p = PersistedDomain([:])
        #expect(OnboardingGate.origin(p, databaseExists: true) == .legacy)
        #expect(OnboardingGate.needsPreflight(p, databaseExists: false, rootOverride: false)
                == (LegacyInstallDetector.isLegacy(p, databaseExists: false) == false))
        #expect(OnboardingGate.origin(PersistedDomain([ConfigKeys.origin: "fresh"]), databaseExists: true) == .fresh)
    }
}

/// The onboarding window's pure decisions.
@Suite("Onboarding rules")
struct OnboardingRulesTests {
    typealias R = OnboardingRules

    @Test func preselection() {
        let ready = ProviderStatus.ready(plan: nil, version: "1", path: "")
        let out = ProviderStatus.notLoggedIn("logged_out")
        #expect(R.preselect(claude: .value(ready), codex: .value(ready)) == .claude)
        #expect(R.preselect(claude: .value(.notInstalled), codex: .value(ready)) == .codex)
        #expect(R.preselect(claude: .value(out), codex: .value(ready)) == .codex)
        #expect(R.preselect(claude: .value(out), codex: .value(.notInstalled)) == .claude)
        #expect(R.preselect(claude: .value(.notInstalled), codex: .value(out)) == .codex)
        #expect(R.preselect(claude: .value(.notInstalled), codex: .value(.notInstalled)) == R.AIChoice.none)
        #expect(R.preselect(claude: .checking, codex: .value(ready)) == nil)
        #expect(R.preselect(claude: .value(ready), codex: nil) == nil)
    }

    @Test func everyRouteHasATopicAndMaybeAForm() {
        for route in R.MailRoute.allCases {
            let t = R.target(route)
            #expect(GuideTopicID.catalog.contains(t.topic))
            if let s = t.source { #expect(s.createsAccount) }
        }
        #expect(R.target(.m365, m365: .yes) == R.RouteTarget(source: .m365PowerAutomate, topic: .mailM365PowerAutomate))
        #expect(R.target(.m365, m365: .unsure).source == .m365PowerAutomate)
        #expect(R.target(.m365, m365: .blocked) == R.RouteTarget(source: nil, topic: .mailM365Blocked))
        #expect(R.target(.outlookCom).source == nil)
        #expect(R.target(.workspace) == R.RouteTarget(source: .imapGmail, topic: .mailGoogleWorkspace))
        #expect(R.target(.folder).source == .folder)
    }

    @Test func mailTurnsOnOnlyWithAWorkingAccount() {
        #expect(!R.canTurnOnMail([]))
        #expect(!R.canTurnOnMail([MailAccountFact(id: "a", source: .imapGmail, status: .needsSetup("no password"))]))
        #expect(!R.canTurnOnMail([MailAccountFact(id: "a", source: .imapGmail, status: .authFailed("no"))]))
        #expect(R.canTurnOnMail([MailAccountFact(id: "a", source: .folder)]))
        #expect(R.canTurnOnMail([MailAccountFact(id: "a", source: .folder, status: .ready(detail: ""))]))
    }

    @Test func finishGating() {
        #expect(R.canFinish(libraryUsable: true, aiDecided: true))
        #expect(!R.canFinish(libraryUsable: false, aiDecided: true))
        #expect(!R.canFinish(libraryUsable: true, aiDecided: false))
        #expect(R.aiDecided(mode: .claude, decision: nil))
        #expect(R.aiDecided(mode: .off, decision: "none"))
        #expect(!R.aiDecided(mode: .off, decision: "codex"))
        #expect(!R.aiDecided(mode: .mock, decision: nil))
    }
}
