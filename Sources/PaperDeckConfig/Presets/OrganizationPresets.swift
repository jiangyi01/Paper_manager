import Foundation
import PaperDeckCore

/// The built-in organizations. This is the ONLY file allowed to contain institution literals
/// (lint G1): every WashU sentence moved here word for word, so `org = washu` renders exactly what
/// every install showed before institutions were configurable.
package enum OrganizationPresets {
    /// New installs: no institution; wording tells the user to check their own guidance.
    package static let generic = OrganizationProfile(id: "generic")

    /// Washington University in St. Louis — every legacy install (`LegacyInstall`).
    package static let washu = OrganizationProfile(
        id: "washu",
        name: LocalizedText(en: "Washington University in St. Louis", zh: "圣路易斯华盛顿大学"),
        shortName: "WashU",
        approvedAITools: ["Claude Edu", "ChatGPT Edu"],
        policyURL: nil,
        peopleDefault: .ask,
        texts: [
            OrgTextKey.accountsIntro.rawValue: LocalizedText(
                en: "Add the mailbox or folder PaperDeck should check. WashU (Microsoft 365): use Power Automate — or Gmail if IT blocks it.",
                zh: "添加 PaperDeck 要检查的邮箱或文件夹。WashU（Microsoft 365）用 Power Automate；如果 IT 禁止，改用 Gmail。"),
            OrgTextKey.paTemplateName.rawValue: LocalizedText(
                en: "Microsoft 365 via Power Automate (WashU)",
                zh: "Microsoft 365 · Power Automate（WashU）"),
            OrgTextKey.paTemplateBlurb.rawValue: LocalizedText(
                en: "Your own Power Automate flow saves allowlisted emails as .eml files to OneDrive; PaperDeck watches the synced folder. No IT app approval needed.",
                zh: "用你自己的 Power Automate 流把白名单发件人的邮件存成 .eml 到 OneDrive，PaperDeck 监视同步到本机的文件夹。无需 IT 审批应用。"),
            OrgTextKey.gmailBlurb.rawValue: LocalizedText(
                en: "Recommended if WashU blocks Power Automate: subscribe or forward your alerts to a Gmail address. Needs 2-Step Verification.",
                zh: "如果 WashU 禁止 Power Automate，推荐改用：把论文提醒订阅或转发到 Gmail。需要开启两步验证。"),
            OrgTextKey.paDefaultAccountName.rawValue: LocalizedText(
                en: "WashU (Power Automate)",
                zh: "WashU（Power Automate）"),
            OrgTextKey.oneDriveMissing.rawValue: LocalizedText(
                en: "OneDrive isn't set up on this Mac (no “OneDrive – Washington University in St. Louis” folder). Install OneDrive and sign in with your WashU account, or choose another folder.",
                zh: "这台 Mac 上还没有 OneDrive（找不到 OneDrive – Washington University in St. Louis 文件夹）。请安装 OneDrive 并用 WashU 账号登录，或选择其他文件夹。"),
            OrgTextKey.paBlockedNote.rawValue: LocalizedText(
                en: "If WashU blocks Power Automate or the OneDrive connector, use Gmail (IMAP) instead: subscribe or forward the alerts to a Gmail address and add it here.",
                zh: "如果 WashU 禁止 Power Automate 或 OneDrive 连接器，就改用 Gmail（IMAP）：把提醒订阅或转发到一个 Gmail 地址，再在这里添加。"),
            OrgTextKey.paIntro.rawValue: LocalizedText(
                en: "Set this up once at make.powerautomate.com with your WashU account (about 5 minutes). The flow copies new emails from your sender list into OneDrive as .eml files; OneDrive syncs them to this Mac. Already built it? Check it against the steps below.",
                zh: "用 WashU 账号在 make.powerautomate.com 设置一次（约 5 分钟）。这个流把发件人列表中的新邮件存成 .eml 放进 OneDrive，OneDrive 再同步到这台 Mac。已经建好了？对照下面的步骤检查一遍。"),
            OrgTextKey.patternInvalid.rawValue: LocalizedText(
                en: "Not an address or a domain. Examples: prof.x@wustl.edu, @biorxiv.org, @*.nature.com",
                zh: "不是地址或域名。例如：prof.x@wustl.edu、@biorxiv.org、@*.nature.com"),
            OrgTextKey.personSenderWarning.rawValue: LocalizedText(
                en: "People may send unpublished work; WashU asks not to put it into AI tools that aren't approved.",
                zh: "个人发件人可能发来未发表的工作；WashU 要求不要放进未经批准的 AI 工具。"),
            OrgTextKey.policyNote.rawValue: LocalizedText(
                en: "WashU AI guidance: don't put WashU data or unpublished work into AI platforms that aren't approved (Claude Edu / ChatGPT Edu are). “Ask each time” keeps this sender's mail on your Mac until you decide per email.",
                zh: "WashU AI 使用指引：不要把 WashU 数据或未发表的工作放进未经批准的 AI 平台（Claude Edu / ChatGPT Edu 已获批准）。「每次询问」让这位发件人的邮件留在本机，直到你逐封决定。"),
            OrgTextKey.triagePrivacy.rawValue: LocalizedText(
                en: "Only emails from your sender list, cleaned first: links become [c1 biorxiv.org] markers, phone numbers and other people's addresses are removed, signatures are cut. The model has no tools and the email is marked as untrusted. WashU: prefer Claude Edu / ChatGPT Edu logins for people's mail.",
                zh: "只发送发件人列表中的邮件，并先清理：链接换成 [c1 biorxiv.org] 标记，电话号码和他人的邮箱地址会被移除，签名会被截掉。模型没有任何工具，邮件标记为不可信数据。WashU：个人发件人的邮件建议使用 Claude Edu / ChatGPT Edu 登录。"),
            OrgTextKey.consentNote.rawValue: LocalizedText(
                en: "Sends this one email's text to {provider} once (links become markers; the signature and other addresses are removed). WashU guidance: don't send unpublished work to an unapproved AI.",
                zh: "只把这一封邮件的文字发送给 {provider} 一次（链接换成标记，签名和其他邮箱地址会去掉）。WashU 规定：未发表的工作不要发给未经批准的 AI。"),
            // Settings ▸ Profile, shown only for `config.origin == legacy`.
            "legacyNote": LocalizedText(
                en: "Set to WashU because this Mac used PaperDeck before institutions were configurable. Change it any time.",
                zh: "已设为 WashU，因为这台 Mac 在可以选择机构之前就已在使用 PaperDeck。可以随时更改。"),
        ],
        mail: OrgMailHints(oneDriveRootHint: "WashingtonUniversity",
                           oneDriveFallbackRootName: "OneDrive-WashingtonUniversityinSt.Louis",
                           knownSenderDomains: ["wustl.edu"],
                           powerAutomatePortal: nil))

    /// The presets the institution picker lists by name (generic = "No specific policy").
    package static let builtIn: [OrganizationProfile] = [generic, washu]

    /// The preset every install from before institutions were configurable maps to
    /// (`LegacyInstall`, `ConfigSnapshot.legacy`): those installs all showed these texts. Other
    /// files name it through this alias, so institution literals stay in this file (lint G1).
    package static var legacyInstallPreset: OrganizationProfile { washu }

    /// A user-entered organization (`org.custom`): never carries texts; free text is trimmed and
    /// capped (name ≤60, short name ≤16, ≤5 tools × 40), the policy link must be https, and the
    /// people default can only be ask or never.
    package static func custom(name: String, shortName: String?, approvedAITools: [String], policyURL: URL?,
                               peopleDefault: PeopleAIDefault, oneDriveRootHint: String?) -> OrganizationProfile {
        func clean(_ s: String?, _ cap: Int) -> String? {
            guard let s else { return nil }
            // One line of plain text: no control characters, no `{…}` slots or markup brackets.
            let scalars = s.unicodeScalars.map { u -> Character in
                if CharacterSet.newlines.contains(u) || u == "\t" { return " " }
                if CharacterSet.controlCharacters.contains(u) || "{}<>".unicodeScalars.contains(u) { return "\u{0}" }
                return Character(u)
            }.filter { $0 != "\u{0}" }
            let one = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            let capped = String(one.prefix(cap)).trimmingCharacters(in: .whitespaces)
            return capped.isEmpty ? nil : capped
        }
        let tools = approvedAITools.compactMap { clean($0, 40) }.prefix(5)
        return OrganizationProfile(
            id: "custom",
            name: clean(name, 60).map { LocalizedText($0) },
            shortName: clean(shortName, 16),
            approvedAITools: Array(tools),
            policyURL: policyURL.flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil },
            peopleDefault: peopleDefault,
            texts: [:],
            mail: OrgMailHints(oneDriveRootHint: clean(oneDriveRootHint, 60)))
    }

    /// The preset for a stored `org.preset` id (unknown → nil; the resolver falls back).
    package static func preset(id: String?) -> OrganizationProfile? {
        builtIn.first { $0.id == id }
    }
}
