import SwiftUI
import PaperDeckConfig

/// The "?" button next to a settings section that opens a Help Center topic.
struct HelpButton: View {
    let topic: GuideTopicID

    init(_ topic: GuideTopicID) {
        self.topic = topic
    }

    var body: some View {
        // Small: it sits in grouped-form section headers next to secondary text.
        HelpLink { HelpCenter.openTopic(topic) }
            .controlSize(.small)
            .help(GuideCatalog.topic(topic)?.title(L.lang) ?? L.Help.openHelp)
            .accessibilityLabel(GuideCatalog.topic(topic)?.title(L.lang) ?? L.Help.openHelp)
    }
}

/// Routes into the Help Center and the setup window, installed at launch (before any window
/// exists) by AppDelegate. Until then (renders, self-tests) they do nothing.
@MainActor enum HelpCenter {
    static var openTopic: (GuideTopicID?) -> Void = { _ in }
    static var openSetup: (OnboardingPage?) -> Void = { _ in }
    static var openTour: () -> Void = {}

    /// Every topic a `HelpButton` (or a help action) in the views names — `--selftest onboarding`
    /// checks that each one exists in the catalog.
    static let topicsUsedInViews: [GuideTopicID] = [
        // HelpButtons placed by Settings (S2) and the guide pages
        .aiSetup, .aiWithout, .libraryLocation, .moveToNewMac, .fixWidgetMissing, .connectMail,
        .mailSendersAndAI, .profileFieldInstitution, .duplicates, .ask, .explain, .screenRecording,
        // Onboarding pages' (?) Help
        .gettingStarted, .profileFieldInstitution, .aiSetup, .libraryLocation, .fixNotifications, .connectMail,
        // Banners, the empty library, the mail inbox, the launch alert
        .fixCLINotFound, .fixCLINotSignedIn, .fixCLIAPIKey, .tour, .fixDocumentsAccess, .fixLibraryMissing,
        .fixLibraryMismatch,
        // Mail routes
        .mailM365PowerAutomate, .mailM365Blocked, .mailOutlookCom, .mailGmail, .mailGoogleWorkspace,
        .mailICloud, .mailOtherIMAP, .mailFolderSources, .mailDragOnly,
    ]
}
