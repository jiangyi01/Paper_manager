import Foundation
import PaperDeckCore

/// The pure decisions of the onboarding window (unit tests and `--selftest onboarding` check them).
package enum OnboardingRules {
    /// `onboarding.aiDecision`.
    package enum AIChoice: String, Sendable, CaseIterable {
        case claude, codex, none

        package var provider: AIProviderKind? {
            switch self {
            case .claude: return .claude
            case .codex: return .codex
            case .none: return nil
            }
        }
    }

    /// `onboarding.mailDecision`.
    package enum MailDecision: String, Sendable, CaseIterable {
        case configured, dragOnly, skipped
    }

    /// The AI page's preselection on a fresh install (no writes, no quota): both providers ready →
    /// Claude (today's default); exactly one ready → that one; none ready but one installed → that
    /// one (Claude when both are); nothing installed → "Not now". Nil while either is still probed.
    package static func preselect(claude: ProbeState<ProviderStatus>?, codex: ProbeState<ProviderStatus>?) -> AIChoice? {
        guard let c = claude?.known, let x = codex?.known else { return nil }
        func ready(_ s: ProviderStatus) -> Bool { if case .ready = s { return true }; return false }
        func installed(_ s: ProviderStatus) -> Bool { if case .notInstalled = s { return false }; return true }
        switch (ready(c), ready(x)) {
        case (true, _): return .claude
        case (false, true): return .codex
        case (false, false):
            if installed(c) { return .claude }
            if installed(x) { return .codex }
            return AIChoice.none
        }
    }

    /// "Where does your mail live?" (the Mail page and the `connect-mail` router).
    package enum MailRoute: String, Sendable, CaseIterable {
        case m365, gmail, workspace, icloud, outlookCom, otherIMAP, folder
    }

    /// "Can you use Power Automate at your organization?"
    package enum M365Answer: String, Sendable, CaseIterable {
        case yes, unsure, blocked
    }

    /// Where a route leads: the add-account form to open (nil: guide only) and its tutorial.
    package struct RouteTarget: Sendable, Equatable {
        package var source: MailSourceID?
        package var topic: GuideTopicID

        package init(source: MailSourceID?, topic: GuideTopicID) {
            self.source = source; self.topic = topic
        }
    }

    package static func target(_ route: MailRoute, m365: M365Answer? = nil) -> RouteTarget {
        switch route {
        case .m365:
            return m365 == .blocked
                ? RouteTarget(source: nil, topic: .mailM365Blocked)
                : RouteTarget(source: .m365PowerAutomate, topic: .mailM365PowerAutomate)
        case .gmail: return RouteTarget(source: .imapGmail, topic: .mailGmail)
        // Workspace: try the Gmail form first; the tutorial has the ways around disabled app passwords.
        case .workspace: return RouteTarget(source: .imapGmail, topic: .mailGoogleWorkspace)
        case .icloud: return RouteTarget(source: .imapICloud, topic: .mailICloud)
        // Outlook.com can't sign in with an app password any more: guides only (rule → folder, forward, drag).
        case .outlookCom: return RouteTarget(source: nil, topic: .mailOutlookCom)
        case .otherIMAP: return RouteTarget(source: .imapCustom, topic: .mailOtherIMAP)
        case .folder: return RouteTarget(source: .folder, topic: .mailFolderSources)
        }
    }

    /// [Turn On Mail]: at least one account that isn't waiting for setup or rejected.
    package static func canTurnOnMail(_ accounts: [MailAccountFact]) -> Bool {
        accounts.contains { a in
            switch a.status {
            case .needsSetup?, .authFailed?: return false
            default: return true
            }
        }
    }

    /// Finish: a usable library and a decision about AI (today's minimum).
    package static func canFinish(libraryUsable: Bool, aiDecided: Bool) -> Bool {
        libraryUsable && aiDecided
    }

    /// The AI page has a decision: reading turned on, or an explicit "Not now".
    package static func aiDecided(mode: AgentMode, decision: String?) -> Bool {
        mode.providerKind != nil || decision == AIChoice.none.rawValue
    }
}
