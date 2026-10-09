import Foundation
import PaperDeckCore
import PaperDeckConfig

/// The one adapter from Core's privacy reason codes (`AssistPrivacy`) to what the user reads
/// (READING_ASSIST_PLAN §8). The organization's guidance comes from the configuration layer
/// (`OrgStrings.aiPolicyLine`: the institution's approved AI tools, or neutral wording), never a
/// literal here. Lead-owned; Slice A's confidential sheet and banners call it.
enum AssistPolicyText {
    /// The reasons, one per line, then the organization's guidance (in the UI language).
    static func confirmation(_ reasons: [AssistPrivacy.Reason], org: OrganizationProfile = LangStore.shared.org) -> String {
        (reasons.map(L.Policy.reason) + [OrgStrings.aiPolicyLine(org: org, lang: L.lang)]).joined(separator: "\n")
    }

    /// The text for a verdict (nil: nothing to show).
    static func text(for verdict: AssistPrivacy.Verdict, org: OrganizationProfile = LangStore.shared.org) -> String? {
        switch verdict {
        case .ok: return nil
        case .confirm(let reasons): return confirmation(reasons, org: org)
        case .blocked: return L.Policy.blocked
        }
    }
}
