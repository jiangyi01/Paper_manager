import Foundation
import Testing
@testable import PaperDeckCore
import PaperDeckConfig

/// `GuideEvaluator`: facts → check states. Unknown is never done; problems carry a reason.
@Suite("Guide evaluator")
struct GuideEvaluatorTests {
    typealias S = GuideSamples

    private func isProblem(_ s: CheckState) -> Bool {
        if case .problem(let why) = s { return !why.en.isEmpty && !why.zh.isEmpty }
        return false
    }

    @Test func nothingProbedIsNeverDone() {
        let f = SetupFacts.unknown
        let probed: [GuideCheck] = [
            .libraryUsable, .libraryLocal, .libraryHasManifest, .hasPapers(1), .notificationsAllowed, .launchAtLogin,
            .widgetRegistered, .widgetPlaced, .appInApplications, .notQuarantined, .stableSigning, .oneDriveBusinessPresent,
            .cloudRootPresent(.dropbox), .providerInstalled(.claude), .providerSignedIn(.codex), .documentsDenied,
            .papersMissing, .fullTextIncomplete, .libraryMismatchNow,
        ]
        for c in probed { #expect(GuideEvaluator.evaluate(c, f) == .unknown, "\(c)") }
    }

    @Test func library() {
        #expect(GuideEvaluator.evaluate(.libraryUsable, S.facts()) == .done)
        for status in [LibraryStatus.denied, .missing, .readOnly] {
            let f = S.facts { $0.library = .value(LibraryFact(status: status, tildePath: "~/x", volume: .local, hasManifest: false)) }
            #expect(isProblem(GuideEvaluator.evaluate(.libraryUsable, f)))
        }
        let cloud = S.facts { $0.library = .value(LibraryFact(status: .ubiquitous, tildePath: "~/x", volume: .cloud, hasManifest: true)) }
        #expect(GuideEvaluator.evaluate(.libraryUsable, cloud) == .done)
        #expect(isProblem(GuideEvaluator.evaluate(.libraryUsable, cloud)) == false)
        #expect(isProblem(GuideEvaluator.evaluate(.libraryUbiquitous, cloud)))
        #expect(GuideEvaluator.evaluate(.libraryUbiquitous, S.facts()) == .done)
        let denied = S.facts { $0.library = .value(LibraryFact(status: .denied, tildePath: "~/x", volume: .local, hasManifest: false)) }
        #expect(isProblem(GuideEvaluator.evaluate(.documentsDenied, denied)))
        #expect(GuideEvaluator.evaluate(.documentsDenied, S.facts()) == .done)
        let unplugged = S.facts { $0.library = .value(LibraryFact(status: .missing, tildePath: "/Volumes/Disk/PaperDeck", volume: .removable, hasManifest: false)) }
        #expect(isProblem(GuideEvaluator.evaluate(.libraryOnRemovableVolume, unplugged)))
        let mismatch = S.facts {
            $0.library = .value(LibraryFact(status: .ok, tildePath: "~/x", volume: .local, hasManifest: true,
                                            identity: .mismatch(manifestID: "a", indexID: "b", indexedPapers: 7)))
        }
        #expect(isProblem(GuideEvaluator.evaluate(.libraryMismatchNow, mismatch)))
        #expect(GuideEvaluator.evaluate(.libraryMismatchNow, S.facts()) == .done)
    }

    @Test func papersAndActivity() {
        #expect(GuideEvaluator.evaluate(.hasPapers(1), S.facts()) == .todo)
        let some = S.facts { $0.papers = .value(PaperCounts(live: 3, withCard: 1, opened: 0, missingFiles: 2, fullTextIndexed: 1)) }
        #expect(GuideEvaluator.evaluate(.hasPapers(1), some) == .done)
        #expect(GuideEvaluator.evaluate(.hasPapers(5), some) == .todo)
        #expect(GuideEvaluator.evaluate(.openedPaper, some) == .todo)
        #expect(isProblem(GuideEvaluator.evaluate(.papersMissing, some)))
        #expect(isProblem(GuideEvaluator.evaluate(.fullTextIncomplete, some)))
        let opened = S.facts { $0.activity[.openedDetail] = Date() }
        #expect(GuideEvaluator.evaluate(.openedPaper, opened) == .done)
        #expect(GuideEvaluator.evaluate(.activity([.panelDrop, .menuBarDrop]), S.facts()) == .todo)
        let dropped = S.facts { $0.activity[.menuBarDrop] = Date() }
        #expect(GuideEvaluator.evaluate(.activity([.panelDrop, .menuBarDrop]), dropped) == .done)
    }

    @Test func aiDecisions() {
        // Declined explicitly = decided.
        #expect(GuideEvaluator.evaluate(.aiDecided, S.facts { $0.ai.decision = "none" }) == .done)
        // A provider picked but never turned on is no decision.
        #expect(GuideEvaluator.evaluate(.aiDecided, S.facts { $0.ai.decision = "claude" }) == .todo)
        // On and ready.
        let on = S.facts { $0.ai = AIFact(mode: .codex, provider: .codex, statuses: [.codex: .value(S.ready)]) }
        #expect(GuideEvaluator.evaluate(.aiDecided, on) == .done)
        #expect(GuideEvaluator.evaluate(.aiReady, on) == .done)
        // On but not signed in: a problem with the provider's reason.
        let out = S.facts { $0.ai = AIFact(mode: .claude, provider: .claude, statuses: [.claude: .value(.notLoggedIn("logged_out"))]) }
        #expect(isProblem(GuideEvaluator.evaluate(.aiDecided, out)))
        // On, still checking: unknown (never done).
        let checking = S.facts { $0.ai = AIFact(mode: .claude, provider: .claude, statuses: [.claude: .checking]) }
        #expect(GuideEvaluator.evaluate(.aiDecided, checking) == .unknown)
        // Codex-only Mac.
        let codex = S.facts { $0.ai = AIFact(provider: .codex, statuses: [.claude: .value(.notInstalled), .codex: .value(S.ready)]) }
        #expect(GuideEvaluator.evaluate(.providerInstalled(.claude), codex) == .todo)
        #expect(GuideEvaluator.evaluate(.providerSignedIn(.codex), codex) == .done)
        // AI reading off: "is the AI working" doesn't apply (no troubleshooting entry applies either).
        #expect(GuideEvaluator.evaluate(.aiReady, codex) == .notApplicable)
        #expect(GuideEvaluator.evaluate(.aiReady, S.facts()) == .notApplicable)
        // An API-key login is a problem for "signed in" and "subscription".
        let key = S.facts { $0.ai.statuses[.claude] = .value(.notLoggedIn("non_subscription:api_key")) }
        #expect(isProblem(GuideEvaluator.evaluate(.providerSignedIn(.claude), key)))
        #expect(isProblem(GuideEvaluator.evaluate(.providerSubscription(.claude), key)))
        #expect(GuideEvaluator.evaluate(.providerInstalled(.claude), key) == .done)
        // A usage-limit pause.
        #expect(isProblem(GuideEvaluator.evaluate(.usageLimitPaused, S.facts { $0.ai.pausedUntil = Date().addingTimeInterval(600) })))
        #expect(GuideEvaluator.evaluate(.usageLimitPaused, S.facts()) == .done)
    }

    @Test func systemFacts() {
        let f = S.facts()
        #expect(GuideEvaluator.evaluate(.notificationsAllowed, f) == .todo)
        #expect(isProblem(GuideEvaluator.evaluate(.notificationsAllowed,
                                                  S.facts { $0.notifications = .value(NotificationFact(authorization: .denied, reminderEnabled: true)) })))
        #expect(GuideEvaluator.evaluate(.notificationsAllowed,
                                        S.facts { $0.notifications = .value(NotificationFact(authorization: .unavailable, reminderEnabled: true)) })
                == .notApplicable)
        #expect(isProblem(GuideEvaluator.evaluate(.launchAtLogin, S.facts { $0.loginItem = .value(LoginItemFact(status: .requiresApproval)) })))
        #expect(isProblem(GuideEvaluator.evaluate(.loginItemNeedsApproval, S.facts { $0.loginItem = .value(LoginItemFact(status: .requiresApproval)) })))
        #expect(GuideEvaluator.evaluate(.widgetPlaced, f) == .todo)
        #expect(GuideEvaluator.evaluate(.widgetPlaced, S.facts { $0.widget = .value(WidgetFact(registration: .registered)) }) == .unknown)
        #expect(isProblem(GuideEvaluator.evaluate(.widgetRegistered, S.facts { $0.widget = .value(WidgetFact(registration: .disabled)) })))
        #expect(isProblem(GuideEvaluator.evaluate(.appInApplications,
                                                  S.facts { $0.app = .value(AppLocationFact(location: .translocated, quarantined: true)) })))
        #expect(isProblem(GuideEvaluator.evaluate(.notQuarantined,
                                                  S.facts { $0.app = .value(AppLocationFact(location: .other, quarantined: true)) })))
        #expect(GuideEvaluator.evaluate(.appInApplications,
                                        S.facts { $0.app = .value(AppLocationFact(location: .userApplications, quarantined: false)) }) == .done)
        #expect(isProblem(GuideEvaluator.evaluate(.stableSigning, S.facts { $0.signing = .value(SigningFact(kind: .adhoc, channel: .local)) })))
    }

    @Test func cloudRoots() {
        let roots = S.facts { $0.cloud = .value(CloudFact(roots: [S.root(.oneDrivePersonal, "Personal"), S.root(.dropbox, "Dropbox")])) }
        #expect(GuideEvaluator.evaluate(.oneDriveBusinessPresent, roots) == .todo)
        #expect(GuideEvaluator.evaluate(.cloudRootPresent(.dropbox), roots) == .done)
        let business = S.facts { $0.cloud = .value(CloudFact(roots: [S.root(.oneDriveBusiness, "OneDrive-Contoso")])) }
        #expect(GuideEvaluator.evaluate(.oneDriveBusinessPresent, business) == .done)
    }

    @Test func mail() {
        let pa = MailAccountFact(id: "a", source: .m365PowerAutomate, status: .ready(detail: ""), captured: 0, folderExists: true)
        let f = S.facts { $0.mail = MailFact(enabled: false, accounts: [pa]) }
        #expect(GuideEvaluator.evaluate(.mailAccountExists(.m365PowerAutomate), f) == .done)
        #expect(GuideEvaluator.evaluate(.mailAccountExists(.imapGmail), f) == .todo)
        #expect(GuideEvaluator.evaluate(.mailAccountReady(nil), f) == .done)
        #expect(GuideEvaluator.evaluate(.mailEnabled, f) == .todo)
        #expect(GuideEvaluator.evaluate(.mailFirstCapture(.m365PowerAutomate), f) == .todo)
        #expect(GuideEvaluator.evaluate(.mailFolderExists, f) == .done)
        #expect(GuideEvaluator.evaluate(.mailNoNotEmailFiles, f) == .todo)
        let gmail = MailAccountFact(id: "g", source: .imapGmail, status: .authFailed("no"), passwordPresent: false)
        let broken = S.facts { $0.mail = MailFact(enabled: true, accounts: [gmail]) }
        #expect(isProblem(GuideEvaluator.evaluate(.mailAccountReady(.imapGmail), broken)))
        #expect(isProblem(GuideEvaluator.evaluate(.mailAccountAuthFailed, broken)))
        #expect(isProblem(GuideEvaluator.evaluate(.imapPasswordsPresent, broken)))
        #expect(GuideEvaluator.evaluate(.imapPasswordsPresent, f) == .notApplicable)
        let notEmail = S.facts { $0.mail = MailFact(accounts: [MailAccountFact(id: "f", source: .folder, captured: 2, notEmailFiles: 3, folderExists: false)]) }
        #expect(isProblem(GuideEvaluator.evaluate(.mailNoNotEmailFiles, notEmail)))
        #expect(isProblem(GuideEvaluator.evaluate(.mailFolderExists, notEmail)))
        // The tutorial's folder step before any account: the suggested folder.
        #expect(GuideEvaluator.evaluate(.mailFolderExists, S.facts { $0.mail = MailFact(suggestedFolderExists: true) }) == .done)
        #expect(GuideEvaluator.evaluate(.sendersAdded(nil), S.facts { $0.mail = MailFact(senders: [.alert: 2]) }) == .done)
        #expect(GuideEvaluator.evaluate(.sendersAdded(.advisor), S.facts { $0.mail = MailFact(senders: [.alert: 2]) }) == .todo)
        #expect(GuideEvaluator.evaluate(.emlImportedManually, S.facts { $0.activity[.emlImported] = Date() }) == .done)
    }

    /// The current user's account (no `source`, named "… (Power Automate)", under OneDrive) counts
    /// as the Power Automate route — through the same resolver the collector uses.
    @Test func theLegacyPowerAutomateAccountIsInferred() {
        let legacy = MailAccount(id: "work-pa", kind: .folder, displayName: "Work (Power Automate)",
                                 folderPath: "/Users/example/Library/CloudStorage/OneDrive-Example/PaperDeck Mail")
        let source = MailSourceResolver.source(of: legacy)
        #expect(source == .m365PowerAutomate)
        let f = S.facts { $0.mail = MailFact(accounts: [MailAccountFact(id: legacy.id, source: source, captured: 1)]) }
        #expect(GuideEvaluator.evaluate(.mailAccountExists(.m365PowerAutomate), f) == .done)
        #expect(GuideEvaluator.evaluate(.mailFirstCapture(.m365PowerAutomate), f) == .done)
    }

    @Test func transferAndProfile() {
        #expect(GuideEvaluator.evaluate(.settingsExported, S.facts()) == .todo)
        #expect(GuideEvaluator.evaluate(.settingsExported, S.facts { $0.transfer.lastExportedAt = Date() }) == .done)
        #expect(GuideEvaluator.evaluate(.settingsImported, S.facts { $0.features = [] }) == .notApplicable)
        #expect(GuideEvaluator.evaluate(.profileSet, S.facts()) == .todo)
        #expect(GuideEvaluator.evaluate(.profileSet, S.facts { $0.profile = ProfileFact(origin: .fresh, fieldID: "general", organizationID: "generic") }) == .done)
    }

    @Test func steps() {
        let t = S.m365
        let manual: Set<String> = []
        // Nothing yet: the implied step waits for its later step.
        var f = S.facts()
        #expect(GuideEvaluator.evaluate(step: 0, in: t, f, manualDone: manual) == .todo)
        #expect(GuideEvaluator.evaluate(step: 2, in: t, f, manualDone: manual) == .todo)
        // The first capture confirms the flow (impliedBy 5).
        f.mail = MailFact(enabled: true, accounts: [MailAccountFact(id: "a", source: .m365PowerAutomate, captured: 1)])
        #expect(GuideEvaluator.evaluate(step: 2, in: t, f, manualDone: manual) == .done)
        // Unknown stays unknown through impliedBy.
        let unknown = GuideTopic(id: "x", kind: .tutorial, title: S.text("t", "t"), summary: S.text("s", "s"),
                                 steps: [GuideStep(id: "a", text: S.text("a", "a"), verification: .impliedBy(step: 1)),
                                         GuideStep(id: "b", text: S.text("b", "b"), verification: .check(.libraryUsable))],
                                 lastReviewed: "2026-10")
        #expect(GuideEvaluator.evaluate(step: 0, in: unknown, .unknown, manualDone: manual) == .unknown)
        // A backward impliedBy never loops.
        let back = GuideTopic(id: "y", kind: .tutorial, title: S.text("t", "t"), summary: S.text("s", "s"),
                              steps: [GuideStep(id: "a", text: S.text("a", "a"), verification: .impliedBy(step: 0))],
                              lastReviewed: "2026-10")
        #expect(GuideEvaluator.evaluate(step: 0, in: back, f, manualDone: manual) == .unknown)
        // Manual: the user's tick.
        let key = GuideEvaluator.manualKey(topic: S.blocked.id, step: "drag")
        #expect(key == "mail-m365-blocked/drag")
        #expect(GuideEvaluator.evaluate(step: 0, in: S.blocked, f, manualDone: []) == .todo)
        #expect(GuideEvaluator.evaluate(step: 0, in: S.blocked, f, manualDone: [key]) == .done)
        // Out of range.
        #expect(GuideEvaluator.evaluate(step: 9, in: t, f, manualDone: manual) == .unknown)
    }

    @Test func topicStatus() {
        var f = S.facts()
        #expect(GuideEvaluator.status(of: S.m365, f, manualDone: []) == .inProgress(done: 0, total: 6))
        f.cloud = .value(CloudFact(roots: [S.root(.oneDriveBusiness, "OneDrive-Contoso")]))
        f.mail = MailFact(enabled: true, accounts: [MailAccountFact(id: "a", source: .m365PowerAutomate, captured: 1, folderExists: true)])
        #expect(GuideEvaluator.status(of: S.m365, f, manualDone: []) == .done)
        // A problem wins.
        f.mail.accounts[0].folderExists = false
        f.mail.accounts[0].notEmailFiles = 1
        if case .problem = GuideEvaluator.status(of: S.m365, f, manualDone: []) {} else { Issue.record("expected a problem") }
        // Troubleshooting: the diagnosis says whether it applies now.
        let denied = S.facts { $0.library = .value(LibraryFact(status: .denied, tildePath: "~/x", volume: .local, hasManifest: false)) }
        #expect(GuideEvaluator.appliesNow(S.documents, denied))
        #expect(!GuideEvaluator.appliesNow(S.documents, S.facts()))
        #expect(GuideEvaluator.status(of: S.documents, S.facts(), manualDone: []) == .nothingToCheck)
        #expect(!GuideEvaluator.appliesNow(S.m365, denied))
    }
}
