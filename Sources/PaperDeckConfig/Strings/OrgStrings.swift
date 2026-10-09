import Foundation
import PaperDeckCore

/// The organization-dependent UI texts (PORTABILITY_PLAN §2.7). A built-in preset with verbatim
/// texts renders them word for word (the legacy preset: every install's wording before
/// institutions were configurable); `generic` renders neutral wording; a custom organization
/// composes the neutral wording with its short name, name and approved tools. Display-only: none
/// of these ever reaches an AI.
package enum OrgStrings {
    /// `.consentNote` keeps its `{provider}` slot here; use `consentNote(provider:org:lang:)`.
    package static func text(_ k: OrgTextKey, org: OrganizationProfile, lang: UILang) -> String {
        if let verbatim = org.text(k) { return verbatim(lang) }
        return composed(k, org: org, lang: lang)
    }

    /// The consent sheet's note for sending one email to `provider` ("Claude", "ChatGPT").
    package static func consentNote(provider: String, org: OrganizationProfile, lang: UILang) -> String {
        text(.consentNote, org: org, lang: lang).replacingOccurrences(of: "{provider}", with: provider)
    }

    /// The default name of a new Power Automate account (always contains "Power Automate", which
    /// the legacy source inference relies on).
    package static func paDefaultAccountName(org: OrganizationProfile, lang: UILang) -> String {
        let name = text(.paDefaultAccountName, org: org, lang: lang)
        return name.contains("Power Automate") ? name : name + (lang == .zh ? "（Power Automate）" : " (Power Automate)")
    }

    /// One line for the onboarding AI page.
    package static func aiPolicyLine(org: OrganizationProfile, lang: UILang) -> String {
        if let short = label(org), !org.approvedAITools.isEmpty {
            return lang == .zh
                ? "\(short) 指引：未发表的工作请使用获批准的 AI 登录（\(org.approvedAITools.joined(separator: "、"))）。"
                : "\(short) guidance: use an approved AI login (\(org.approvedAITools.joined(separator: ", "))) for unpublished work."
        }
        return lang == .zh
            ? "把未发表的工作发给 AI 之前，请先查看你所在机构的规定。"
            : "Check your institution's guidance before sending unpublished work to an AI."
    }

    /// Settings ▸ Profile's note for an install mapped to its preset by the migration.
    package static func legacyNote(org: OrganizationProfile, origin: ConfigOrigin, lang: UILang) -> String? {
        guard origin == .legacy else { return nil }
        return org.texts["legacyNote"]?(lang)
    }

    // MARK: - Composition (generic and custom organizations)

    /// How a custom organization is named in its texts: the short name, else the name; nil for
    /// `generic` (and a custom organization without either).
    static func label(_ org: OrganizationProfile) -> String? {
        let short = org.shortName?.trimmingCharacters(in: .whitespaces)
        if let short, !short.isEmpty { return short }
        let name = org.name?.en.trimmingCharacters(in: .whitespaces)
        if let name, !name.isEmpty { return name }
        return nil
    }

    /// The full name (en) of a custom organization, else its label.
    static func fullName(_ org: OrganizationProfile) -> String? {
        let name = org.name?.en.trimmingCharacters(in: .whitespaces)
        if let name, !name.isEmpty { return name }
        return label(org)
    }

    static func composed(_ k: OrgTextKey, org: OrganizationProfile, lang: UILang) -> String {
        let zh = lang == .zh
        let short = label(org)
        let tools = org.approvedAITools.filter { !$0.isEmpty }
        let toolList = tools.joined(separator: " / ")
        switch k {
        case .accountsIntro:
            return zh
                ? "添加 PaperDeck 要检查的邮箱或文件夹。工作或学校的 Microsoft 365 用 Power Automate；其他情况可用 Gmail、iCloud 或其他 IMAP 账户，也可以直接拖入 .eml 文件。"
                : "Add the mailbox or folder PaperDeck should check. Work or school Microsoft 365: use Power Automate. Otherwise Gmail, iCloud or another IMAP account — or drag .eml files in."
        case .paTemplateName:
            if let short {
                return zh ? "Microsoft 365 · Power Automate（\(short)）" : "Microsoft 365 via Power Automate (\(short))"
            }
            return zh ? "Microsoft 365（工作或学校）· Power Automate" : "Microsoft 365 (work or school) via Power Automate"
        case .paTemplateBlurb:
            return zh
                ? "用你自己的 Power Automate 流把白名单发件人的邮件存成 .eml 到 OneDrive，PaperDeck 监视同步到本机的文件夹。无需注册应用——只要你的机构允许使用 Power Automate。"
                : "Your own Power Automate flow saves allowlisted emails as .eml files to OneDrive; PaperDeck watches the synced folder. No app registration needed — works if your organization allows Power Automate."
        case .gmailBlurb:
            if let short {
                return zh
                    ? "如果 \(short) 禁止 Power Automate，可以改用：把论文提醒订阅或转发到 Gmail。需要开启两步验证。"
                    : "Good if \(short) blocks Power Automate: subscribe or forward your alerts to a Gmail address. Needs 2-Step Verification."
            }
            return zh
                ? "如果你的机构禁止 Power Automate，可以改用：把论文提醒订阅或转发到 Gmail。需要开启两步验证。"
                : "Good if your organization blocks Power Automate: subscribe or forward your alerts to a Gmail address. Needs 2-Step Verification."
        case .paDefaultAccountName:
            if let short { return zh ? "\(short)（Power Automate）" : "\(short) (Power Automate)" }
            return zh ? "Microsoft 365（Power Automate）" : "Microsoft 365 (Power Automate)"
        case .oneDriveMissing:
            let account = short.map { zh ? "\($0) 账号" : "your \($0) account" } ?? (zh ? "工作或学校账号" : "your work or school account")
            return zh
                ? "这台 Mac 上没有找到工作或学校的 OneDrive。请安装 OneDrive 并用\(account)登录，或选择其他文件夹。"
                : "No OneDrive for work or school was found on this Mac. Install OneDrive and sign in with \(account), or choose another folder."
        case .paBlockedNote:
            let who = short.map { zh ? " \($0) " : $0 } ?? (zh ? "你的机构" : "your organization")
            return zh
                ? "如果\(who)禁止 Power Automate 或 OneDrive 连接器：可以把 Outlook 中的邮件直接拖进 PaperDeck，用 Apple 邮件规则把邮件存进一个文件夹，或把提醒转发到 Gmail 或 iCloud（IMAP）。"
                : "If \(who) blocks Power Automate or the OneDrive connector: drag emails from Outlook into PaperDeck, save them into a folder with an Apple Mail rule, or forward alerts to Gmail or iCloud (IMAP)."
        case .paIntro:
            let portal = portalHost(org)
            let account = short.map { zh ? "\($0) 账号" : "your \($0) account" } ?? (zh ? "工作或学校账号" : "your work or school account")
            return zh
                ? "用\(account)在 \(portal) 设置一次（约 5 分钟）。这个流把发件人列表中的新邮件存成 .eml 放进 OneDrive，OneDrive 再同步到这台 Mac。已经建好了？对照下面的步骤检查一遍。"
                : "Set this up once at \(portal) with \(account) (about 5 minutes). The flow copies new emails from your sender list into OneDrive as .eml files; OneDrive syncs them to this Mac. Already built it? Check it against the steps below."
        case .patternInvalid:
            return zh
                ? "不是地址或域名。例如：name@university.edu、@biorxiv.org、@*.nature.com"
                : "Not an address or a domain. Examples: name@university.edu, @biorxiv.org, @*.nature.com"
        case .personSenderWarning:
            if let name = fullName(org) {
                return zh
                    ? "个人发件人可能发来未发表的工作；\(name) 要求不要放进未经批准的 AI 工具。"
                    : "People may send unpublished work; \(name) asks not to put it into AI tools that aren't approved."
            }
            return zh
                ? "个人发件人可能发来未发表的工作；你所在的机构可能限制哪些 AI 工具可以接收——请查看相关规定。"
                : "People may send unpublished work; your institution may restrict which AI tools may receive it — check its policy."
        case .policyNote:
            let ask = zh ? "「每次询问」让这位发件人的邮件留在本机，直到你逐封决定。"
                         : "“Ask each time” keeps this sender's mail on your Mac until you decide per email."
            if let short, !tools.isEmpty {
                return zh
                    ? "\(short) AI 使用指引：不要把未发表的工作放进未经批准的 AI 平台（\(toolList) 已获批准）。" + ask
                    : "\(short) AI guidance: don't put unpublished work into AI platforms that aren't approved (\(toolList) are). " + ask
            }
            if let short {
                return zh
                    ? "把未发表的工作或机构数据发给 AI 工具之前，请先查看 \(short) 的 AI 使用指引。" + ask
                    : "Check \(short)'s AI guidance before sending unpublished work or institutional data to an AI tool. " + ask
            }
            return zh
                ? "把未发表的工作或机构数据发给 AI 工具之前，请先查看你所在机构的 AI 使用指引。" + ask
                : "Check your institution's AI guidance before sending unpublished work or institutional data to an AI tool. " + ask
        case .triagePrivacy:
            let common = zh
                ? "只发送发件人列表中的邮件，并先清理：链接换成 [c1 biorxiv.org] 标记，电话号码和他人的邮箱地址会被移除，签名会被截掉。模型没有任何工具，邮件标记为不可信数据。"
                : "Only emails from your sender list, cleaned first: links become [c1 biorxiv.org] markers, phone numbers and other people's addresses are removed, signatures are cut. The model has no tools and the email is marked as untrusted."
            guard let short, !tools.isEmpty else { return common }
            return zh
                ? common + "\(short)：个人发件人的邮件建议使用 \(toolList) 登录。"
                : common + " \(short): prefer \(toolList) logins for people's mail."
        case .consentNote:
            let head = zh
                ? "只把这一封邮件的文字发送给 {provider} 一次（链接换成标记，签名和其他邮箱地址会去掉）。"
                : "Sends this one email's text to {provider} once (links become markers; the signature and other addresses are removed). "
            if let short, !tools.isEmpty {
                return head + (zh ? "\(short) 规定：未发表的工作不要发给未经批准的 AI。"
                                  : "\(short) guidance: don't send unpublished work to an unapproved AI.")
            }
            return head + (zh ? "把未发表的工作发给 AI 之前，请先查看你所在机构的规定。"
                              : "Check your institution's guidance before sending unpublished work to an AI.")
        }
    }

    /// The Power Automate portal named in the texts: the organization's (https) host, else
    /// make.powerautomate.com.
    static func portalHost(_ org: OrganizationProfile) -> String {
        guard let url = org.mail.powerAutomatePortal, url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return "make.powerautomate.com" }
        return host
    }
}
