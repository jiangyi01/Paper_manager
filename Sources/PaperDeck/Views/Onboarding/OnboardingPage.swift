import Foundation
import PaperDeckConfig

/// The pages of the onboarding window, in rail order.
enum OnboardingPage: String, CaseIterable {
    case welcome, about, ai, library, plan, mail, importPapers, finish

    /// The page's (?) Help topic.
    var helpTopic: GuideTopicID {
        switch self {
        case .welcome: .gettingStarted
        case .about: .profileFieldInstitution
        case .ai: .aiSetup
        case .library: .libraryLocation
        case .plan: .fixNotifications
        case .mail: .connectMail
        case .importPapers: .gettingStarted
        case .finish: .tour
        }
    }

    var symbol: String {
        switch self {
        case .welcome: "hand.wave"
        case .about: "person.text.rectangle"
        case .ai: "sparkles"
        case .library: "books.vertical"
        case .plan: "calendar.badge.clock"
        case .mail: "envelope"
        case .importPapers: "square.and.arrow.down.on.square"
        case .finish: "checkmark.seal"
        }
    }
}
