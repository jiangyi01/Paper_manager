import Foundation
import PaperDeckCore

/// A live check of this Mac's state (evaluated by `GuideEvaluator` over `SetupFacts`).
/// Cases may be added (S3); never renamed.
package enum GuideCheck: Sendable, Hashable {
    case libraryUsable, libraryLocal, libraryHasManifest, libraryUbiquitous, libraryOnRemovableVolume, documentsDenied
    case libraryMismatchNow, papersMissing, fullTextIncomplete, hasPapers(Int), openedPaper, activity(Set<GuideActivityKind>)
    case aiDecided, aiReady, usageLimitPaused, providerInstalled(AIProviderKind), providerSignedIn(AIProviderKind), providerSubscription(AIProviderKind)
    case notificationsAllowed, reminderEnabled, launchAtLogin, loginItemNeedsApproval, widgetRegistered, widgetPlaced
    case appInApplications, notTranslocated, notQuarantined, stableSigning
    case cloudRootPresent(CloudProvider), oneDriveBusinessPresent
    case mailEnabled, mailAccountExists(MailSourceID?), mailAccountReady(MailSourceID?), mailAccountAuthFailed
    case mailFirstCapture(MailSourceID?), mailFolderExists, mailNoNotEmailFiles, sendersAdded(SenderKind?)
    case imapPasswordsPresent, emlImportedManually, settingsExported, settingsImported, profileSet
}

/// The state of a check or step. `unknown` (still probing) is never shown as done; a `problem`
/// always carries its reason.
package enum CheckState: Sendable, Equatable {
    case done, todo, problem(LocalizedText), unknown, notApplicable
}
