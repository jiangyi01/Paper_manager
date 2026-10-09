import Foundation
import PaperDeckCore

/// A Help Center topic id (also the docs anchor and the `paperdeck://help/<id>` path).
package struct GuideTopicID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    package var rawValue: String

    package init(rawValue: String) { self.rawValue = rawValue }
    package init(stringLiteral value: String) { self.rawValue = value }

    // Getting started
    package static let gettingStarted: GuideTopicID = "getting-started"
    package static let tour: GuideTopicID = "tour"
    package static let diagnostics: GuideTopicID = "diagnostics"
    // Mail
    package static let connectMail: GuideTopicID = "connect-mail"
    package static let mailM365PowerAutomate: GuideTopicID = "mail-m365-power-automate"
    package static let mailM365Blocked: GuideTopicID = "mail-m365-blocked"
    package static let mailOutlookCom: GuideTopicID = "mail-outlook-com"
    package static let mailGmail: GuideTopicID = "mail-gmail"
    package static let mailGoogleWorkspace: GuideTopicID = "mail-google-workspace"
    package static let mailICloud: GuideTopicID = "mail-icloud"
    package static let mailOtherIMAP: GuideTopicID = "mail-other-imap"
    package static let mailFolderSources: GuideTopicID = "mail-folder-sources"
    package static let mailDragOnly: GuideTopicID = "mail-drag-only"
    package static let mailSendersAndAI: GuideTopicID = "mail-senders-and-ai"
    // AI
    package static let aiSetup: GuideTopicID = "ai-setup"
    package static let aiWithout: GuideTopicID = "ai-without"
    package static let aiSwitchAccount: GuideTopicID = "ai-switch-account"
    // Library
    package static let libraryLocation: GuideTopicID = "library-location"
    package static let moveToNewMac: GuideTopicID = "move-to-new-mac"
    package static let libraryTwoMacs: GuideTopicID = "library-two-macs"
    // Reading assist (READING_ASSIST_PLAN §8: duplicates — B, multi-select — C; phase 2: Ask, the reader)
    package static let duplicates: GuideTopicID = "duplicates"
    package static let multiSelect: GuideTopicID = "multi-select"
    package static let ask: GuideTopicID = "ask"
    package static let reader: GuideTopicID = "reader"
    // Phase 3: Explain, and the one permission its box and lens need.
    package static let explain: GuideTopicID = "explain"
    package static let screenRecording: GuideTopicID = "screen-recording"
    // Profile
    package static let profileFieldInstitution: GuideTopicID = "profile-field-institution"
    // Distribution
    package static let installForLabmate: GuideTopicID = "install-for-labmate"
    package static let buildFromSource: GuideTopicID = "build-from-source"
    // Troubleshooting
    package static let fixDocumentsAccess: GuideTopicID = "fix-documents-access"
    package static let fixLibraryMissing: GuideTopicID = "fix-library-missing"
    package static let fixLibraryMismatch: GuideTopicID = "fix-library-mismatch"
    package static let fixCloudEvicted: GuideTopicID = "fix-cloud-evicted"
    package static let fixCLINotFound: GuideTopicID = "fix-cli-not-found"
    package static let fixCLINotSignedIn: GuideTopicID = "fix-cli-not-signed-in"
    package static let fixCLIAPIKey: GuideTopicID = "fix-cli-api-key"
    package static let fixUsageLimit: GuideTopicID = "fix-usage-limit"
    package static let fixNotifications: GuideTopicID = "fix-notifications"
    package static let fixWidgetMissing: GuideTopicID = "fix-widget-missing"
    package static let fixLoginItem: GuideTopicID = "fix-login-item"
    package static let fixAppBlocked: GuideTopicID = "fix-app-blocked"
    package static let fixMailAuthFailed: GuideTopicID = "fix-mail-auth-failed"
    package static let fixMailNotEmailFiles: GuideTopicID = "fix-mail-not-email-files"
    package static let fixMailOneDriveMissing: GuideTopicID = "fix-mail-onedrive-missing"
    package static let fixSearchAfterMove: GuideTopicID = "fix-search-after-move"
    package static let fixTwoMacsDiverged: GuideTopicID = "fix-two-macs-diverged"

    /// Every id of the topic catalog (PORTABILITY_PLAN §3.8), in catalog order.
    package static let catalog: [GuideTopicID] = [
        .gettingStarted, .tour, .diagnostics,
        .connectMail, .mailM365PowerAutomate, .mailM365Blocked, .mailOutlookCom, .mailGmail, .mailGoogleWorkspace,
        .mailICloud, .mailOtherIMAP, .mailFolderSources, .mailDragOnly, .mailSendersAndAI,
        .aiSetup, .aiWithout, .aiSwitchAccount,
        .libraryLocation, .moveToNewMac, .libraryTwoMacs,
        .duplicates, .multiSelect, .ask, .reader, .explain, .screenRecording,
        .profileFieldInstitution,
        .installForLabmate, .buildFromSource,
        .fixDocumentsAccess, .fixLibraryMissing, .fixLibraryMismatch, .fixCloudEvicted, .fixCLINotFound,
        .fixCLINotSignedIn, .fixCLIAPIKey, .fixUsageLimit, .fixNotifications, .fixWidgetMissing, .fixLoginItem,
        .fixAppBlocked, .fixMailAuthFailed, .fixMailNotEmailFiles, .fixMailOneDriveMissing, .fixSearchAfterMove,
        .fixTwoMacsDiverged,
    ]
}

package enum GuideKind: String, Sendable {
    case checklist, tour, tutorial, troubleshoot, reference
}

/// Features a topic needs (a topic whose feature isn't in `SetupFacts.features` is hidden).
package enum GuideFeature: String, Sendable {
    case settingsTransfer, libraryFlows, widgetRepair
}

/// First uses recorded in `guide.activity` (machine-local, never exported).
package enum GuideActivityKind: String, Codable, Sendable, CaseIterable {
    case panelDrop, menuBarDrop, openWith, openedDetail, tourCompleted, emlImported
}

/// How a step is verified: a live check, a later step that implies it, the user's tick (at most
/// one per topic, with a reason), or nothing (information).
package enum GuideVerification: Sendable, Equatable {
    case check(GuideCheck), impliedBy(step: Int), manual(reason: LocalizedText), info
}

/// App actions a guide button can trigger (the app's router implements them).
package enum GuideRouterAction: String, Sendable {
    case pickAndImportFiles, armDropPanel, showToday, showMail, openFirstPaper, showMenuBarMenu, revealLibrary
    case exportSettings, importSettings, openSetup, openTour, reindexFullText, repairWidget
}

package enum SystemPane: String, Sendable {
    case notifications, loginItems, filesAndFolders, privacySecurity
    /// Privacy & Security ▸ Screen & System Audio Recording; Keyboard ▸ Keyboard Shortcuts (Services).
    case screenRecording, keyboardShortcuts
}

/// Text a guide step can copy for the user (generated from their settings).
package enum GeneratedArtifact: String, Sendable {
    case appleMailRuleScript, googleAppsScript, powerAutomatePackage
}

package enum GuideAction: Sendable, Equatable {
    case openTopic(GuideTopicID), openSettings(tab: String), deepLink(DeepLink), openURL(URL)   // URL host allowlisted
    case router(GuideRouterAction), systemSettings(SystemPane), openMailSheet(MailSourceID), copyGenerated(GeneratedArtifact)
}

package struct GuideStep: Sendable, Equatable {
    package var id: String
    package var text: LocalizedText
    package var verification: GuideVerification
    package var actions: [GuideAction]
    /// Terminal commands shown with a copy button (never a personal path or address).
    package var commands: [String]

    package init(id: String, text: LocalizedText, verification: GuideVerification = .info,
                 actions: [GuideAction] = [], commands: [String] = []) {
        self.id = id; self.text = text; self.verification = verification; self.actions = actions
        self.commands = commands
    }
}

package struct GuideTopic: Sendable, Equatable, Identifiable {
    package var id: GuideTopicID
    package var kind: GuideKind
    package var title: LocalizedText
    package var summary: LocalizedText
    package var keywords: [LocalizedText]
    package var steps: [GuideStep]
    package var related: [GuideTopicID]
    package var requires: Set<GuideFeature>
    /// The check whose problem state badges a troubleshooting entry "Applies now".
    package var diagnosis: GuideCheck?
    package var lastReviewed: String               // "2026-10"

    package init(id: GuideTopicID, kind: GuideKind, title: LocalizedText, summary: LocalizedText,
                 keywords: [LocalizedText] = [], steps: [GuideStep] = [], related: [GuideTopicID] = [],
                 requires: Set<GuideFeature> = [], diagnosis: GuideCheck? = nil, lastReviewed: String) {
        self.id = id; self.kind = kind; self.title = title; self.summary = summary; self.keywords = keywords
        self.steps = steps; self.related = related; self.requires = requires; self.diagnosis = diagnosis
        self.lastReviewed = lastReviewed
    }
}
