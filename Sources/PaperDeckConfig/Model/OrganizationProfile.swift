import Foundation
import PaperDeckCore

/// The organization-dependent texts (PORTABILITY_PLAN §2.7). Built-in presets carry them verbatim
/// (`OrganizationProfile.texts`); generic and custom organizations get composed wording.
package enum OrgTextKey: String, Codable, Sendable, CaseIterable {
    case accountsIntro, paTemplateName, paTemplateBlurb, gmailBlurb, paDefaultAccountName, oneDriveMissing,
         paBlockedNote, paIntro, patternInvalid, personSenderWarning, policyNote, triagePrivacy, consentNote
}

/// Mail hints of an organization. Data only — the cloud-root logic lives in `CloudRootLocator`.
package struct OrgMailHints: Codable, Sendable, Equatable {
    /// Substring preferring one OneDrive business root (part of the tenant's folder name); a preference only.
    package var oneDriveRootHint: String?
    /// Root name suggested when no OneDrive root is detected (nil: the form shows Choose…).
    package var oneDriveFallbackRootName: String?
    /// Domains of the organization's addresses (migration diagnostics only).
    package var knownSenderDomains: [String]
    /// Power Automate portal (nil: make.powerautomate.com).
    package var powerAutomatePortal: URL?

    package init(oneDriveRootHint: String? = nil, oneDriveFallbackRootName: String? = nil,
                 knownSenderDomains: [String] = [], powerAutomatePortal: URL? = nil) {
        self.oneDriveRootHint = oneDriveRootHint; self.oneDriveFallbackRootName = oneDriveFallbackRootName
        self.knownSenderDomains = knownSenderDomains; self.powerAutomatePortal = powerAutomatePortal
    }

    private enum CodingKeys: String, CodingKey {
        case oneDriveRootHint, oneDriveFallbackRootName, knownSenderDomains, powerAutomatePortal
    }

    /// Lenient: every field may be missing.
    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(oneDriveRootHint: (try? c.decodeIfPresent(String.self, forKey: .oneDriveRootHint)).flatMap { $0 },
                  oneDriveFallbackRootName: (try? c.decodeIfPresent(String.self, forKey: .oneDriveFallbackRootName)).flatMap { $0 },
                  knownSenderDomains: (try? c.decodeIfPresent([String].self, forKey: .knownSenderDomains)).flatMap { $0 } ?? [],
                  powerAutomatePortal: (try? c.decodeIfPresent(URL.self, forKey: .powerAutomatePortal)).flatMap { $0 })
    }
}

/// An institution's AI policy and mail hints (`org.preset` / `org.custom`). It changes wording and
/// stricter defaults for new person senders only — never a safety floor.
package struct OrganizationProfile: Codable, Sendable, Equatable, Identifiable {
    package var id: String                      // a built-in preset id, or "custom"
    package var name: LocalizedText?
    package var shortName: String?
    package var approvedAITools: [String]
    package var policyURL: URL?                 // https only
    package var peopleDefault: PeopleAIDefault
    /// `OrgTextKey.rawValue` (+ "legacyNote") → verbatim text; built-in presets only (never imported).
    package var texts: [String: LocalizedText]
    package var mail: OrgMailHints

    package init(id: String, name: LocalizedText? = nil, shortName: String? = nil, approvedAITools: [String] = [],
                 policyURL: URL? = nil, peopleDefault: PeopleAIDefault = .ask, texts: [String: LocalizedText] = [:],
                 mail: OrgMailHints = OrgMailHints()) {
        self.id = id; self.name = name; self.shortName = shortName; self.approvedAITools = approvedAITools
        self.policyURL = policyURL; self.peopleDefault = peopleDefault; self.texts = texts; self.mail = mail
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, shortName, approvedAITools, policyURL, peopleDefault, texts, mail
    }

    /// Lenient (`org.custom` JSON carries no `texts`): only `id` is required; an unknown people
    /// default falls back to `.ask`.
    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id),
                  name: (try? c.decodeIfPresent(LocalizedText.self, forKey: .name)).flatMap { $0 },
                  shortName: (try? c.decodeIfPresent(String.self, forKey: .shortName)).flatMap { $0 },
                  approvedAITools: (try? c.decodeIfPresent([String].self, forKey: .approvedAITools)).flatMap { $0 } ?? [],
                  policyURL: (try? c.decodeIfPresent(URL.self, forKey: .policyURL)).flatMap { $0 },
                  peopleDefault: (try? c.decodeIfPresent(String.self, forKey: .peopleDefault)).flatMap { $0 }
                    .map { PeopleAIDefault(rawValue: $0) ?? .ask } ?? .ask,
                  texts: (try? c.decodeIfPresent([String: LocalizedText].self, forKey: .texts)).flatMap { $0 } ?? [:],
                  mail: (try? c.decodeIfPresent(OrgMailHints.self, forKey: .mail)).flatMap { $0 } ?? OrgMailHints())
    }

    /// A verbatim built-in text, if this preset has one.
    package func text(_ key: OrgTextKey) -> LocalizedText? { texts[key.rawValue] }
}
