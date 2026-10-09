import Foundation
import PaperDeckCore

/// How this Mac's configuration began (`config.origin`, written once by `ConfigMigration`):
/// an install from before institutions were configurable, or a fresh one.
package enum ConfigOrigin: String, Codable, Sendable {
    case legacy, fresh
}

/// The reader's career stage (`profile.stage`; absent = `.phd`).
package enum CareerStage: String, Codable, Sendable, CaseIterable {
    case masters, phd, postdoc, faculty

    /// Fills `{level}` of a field's reader pattern: "a computational-biology researcher (PhD level)".
    package var levelPhrase: String {
        switch self {
        case .masters: return "Master's level"
        case .phd: return "PhD level"
        case .postdoc: return "postdoc level"
        case .faculty: return "faculty level"
        }
    }

    /// Fills `{stage}` of a field's difficulty pattern: "a comp-bio PhD student".
    package var stageNoun: String {
        switch self {
        case .masters: return "Master's student"
        case .phd: return "PhD student"
        case .postdoc: return "postdoc"
        case .faculty: return "faculty member"
        }
    }

    /// Picker title.
    package var title: LocalizedText {
        switch self {
        case .masters: return LocalizedText(en: "Master's", zh: "硕士")
        case .phd: return LocalizedText(en: "PhD", zh: "博士")
        case .postdoc: return LocalizedText(en: "Postdoc", zh: "博士后")
        case .faculty: return LocalizedText(en: "Faculty", zh: "教职")
        }
    }
}

/// The AI policy an organization gives new person / advisor sender rules. There is no "always":
/// a preset or an imported file can only be as strict as today's default (`ask`) or stricter.
package enum PeopleAIDefault: String, Codable, Sendable, CaseIterable {
    case ask, never

    package var policy: MailAIPolicy {
        switch self {
        case .ask: return .ask
        case .never: return .never
        }
    }
}
