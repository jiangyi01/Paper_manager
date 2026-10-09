import Foundation
import PaperDeckCore

/// Where mail comes from (stored in `MailAccount.source`). Raw values are append-only.
package enum MailSourceID: String, Codable, Sendable, CaseIterable {
    case m365PowerAutomate = "m365.powerAutomate", folder = "folder"
    case imapGmail = "imap.gmail", imapICloud = "imap.icloud", imapYahoo = "imap.yahoo", imapFastmail = "imap.fastmail", imapCustom = "imap.custom"
    // Guide-only routes: no account of their own (a Help topic, often ending in a pre-filled sheet).
    case guideOutlookCom = "guide.outlookCom", guideWorkspace = "guide.workspace", guideM365Blocked = "guide.m365Blocked"
    case guideAppleMailRule = "guide.appleMailRule", guideAppsScript = "guide.appsScript", guideDragOnly = "guide.dragOnly"

    /// True for the routes that create an account (folder or IMAP transport).
    package var createsAccount: Bool {
        switch self {
        case .m365PowerAutomate, .folder, .imapGmail, .imapICloud, .imapYahoo, .imapFastmail, .imapCustom: return true
        case .guideOutlookCom, .guideWorkspace, .guideM365Blocked, .guideAppleMailRule, .guideAppsScript, .guideDragOnly:
            return false
        }
    }

    /// The IMAP preset of an IMAP route.
    package var imapPreset: MailAccount.IMAPPreset? {
        switch self {
        case .imapGmail: return .gmail
        case .imapICloud: return .icloud
        case .imapYahoo: return .yahoo
        case .imapFastmail: return .fastmail
        case .imapCustom: return .custom
        default: return nil
        }
    }
}

/// One row of the add-account chooser.
package struct MailSourceEntry: Sendable, Equatable, Identifiable {
    package enum Section: Sendable { case setUp, otherWays }

    package var id: MailSourceID
    package var section: Section
    package var symbol: String
    package var title: LocalizedText
    package var blurb: LocalizedText
    package var helpTopic: GuideTopicID
    package var beta: Bool

    package init(id: MailSourceID, section: Section, symbol: String, title: LocalizedText, blurb: LocalizedText,
                 helpTopic: GuideTopicID, beta: Bool) {
        self.id = id; self.section = section; self.symbol = symbol; self.title = title; self.blurb = blurb
        self.helpTopic = helpTopic; self.beta = beta
    }
}

/// The chooser's rows: "Set up an account" in today's order (`MailAccountTemplate.choices`), then
/// "Other ways to get mail in" (guide-only routes, each opening a Help topic).
package enum MailSourceCatalog {
    package static func entries(org: OrganizationProfile) -> [MailSourceEntry] {
        func both(_ k: OrgTextKey) -> LocalizedText {
            LocalizedText(en: OrgStrings.text(k, org: org, lang: .en), zh: OrgStrings.text(k, org: org, lang: .zh))
        }
        return [
            MailSourceEntry(id: .m365PowerAutomate, section: .setUp, symbol: "icloud.and.arrow.down",
                            title: both(.paTemplateName), blurb: both(.paTemplateBlurb),
                            helpTopic: .mailM365PowerAutomate, beta: false),
            MailSourceEntry(id: .imapGmail, section: .setUp, symbol: "envelope.badge",
                            title: LocalizedText(en: "Gmail (app password)", zh: "Gmail（应用专用密码）"),
                            blurb: both(.gmailBlurb), helpTopic: .mailGmail, beta: false),
            MailSourceEntry(id: .imapICloud, section: .setUp, symbol: "icloud",
                            title: LocalizedText(en: "iCloud Mail", zh: "iCloud 邮件"),
                            blurb: LocalizedText(en: "iCloud Mail with an app-specific password.", zh: "iCloud 邮件 + App 专用密码。"),
                            helpTopic: .mailICloud, beta: false),
            MailSourceEntry(id: .imapYahoo, section: .setUp, symbol: "envelope",
                            title: LocalizedText(en: "Yahoo Mail", zh: "Yahoo 邮件"),
                            blurb: LocalizedText(en: "Yahoo Mail with an app password.", zh: "Yahoo 邮件 + 应用密码。"),
                            helpTopic: .mailOtherIMAP, beta: false),
            MailSourceEntry(id: .imapFastmail, section: .setUp, symbol: "envelope",
                            title: LocalizedText("Fastmail"),
                            blurb: LocalizedText(en: "Fastmail with an app password.", zh: "Fastmail + 应用密码。"),
                            helpTopic: .mailOtherIMAP, beta: false),
            MailSourceEntry(id: .imapCustom, section: .setUp, symbol: "envelope",
                            title: LocalizedText(en: "Other IMAP server", zh: "其他 IMAP 服务器"),
                            blurb: LocalizedText(en: "Any IMAP server over TLS (port 993) with a password or app password.",
                                                 zh: "任何支持 TLS（端口 993）的 IMAP 服务器。"),
                            helpTopic: .mailOtherIMAP, beta: false),
            MailSourceEntry(id: .folder, section: .setUp, symbol: "folder",
                            title: LocalizedText(en: "Folder of .eml files", zh: ".eml 文件夹"),
                            blurb: LocalizedText(en: "Any folder that receives .eml files — an Apple Mail rule, Save As…, a script.",
                                                 zh: "任何会收到 .eml 文件的文件夹 — Apple Mail 规则、「另存为」、脚本等。"),
                            helpTopic: .mailFolderSources, beta: false),
            MailSourceEntry(id: .guideOutlookCom, section: .otherWays, symbol: "envelope.open",
                            title: LocalizedText(en: "Outlook.com / Hotmail", zh: "Outlook.com / Hotmail"),
                            blurb: LocalizedText(en: "Microsoft doesn't offer app passwords for these mailboxes: forward your alerts or drag emails in.",
                                                 zh: "Microsoft 不为这类邮箱提供应用专用密码：可以转发提醒，或把邮件拖进来。"),
                            helpTopic: .mailOutlookCom, beta: false),
            MailSourceEntry(id: .guideWorkspace, section: .otherWays, symbol: "building.2",
                            title: LocalizedText(en: "Google Workspace without app passwords", zh: "不允许应用专用密码的 Google Workspace"),
                            blurb: LocalizedText(en: "Save your alerts into a Google Drive folder with a small Apps Script, or forward them.",
                                                 zh: "用一个小的 Apps Script 把提醒存进 Google 云端硬盘文件夹，或转发提醒。"),
                            helpTopic: .mailGoogleWorkspace, beta: true),
            MailSourceEntry(id: .guideM365Blocked, section: .otherWays, symbol: "nosign",
                            title: LocalizedText(en: "Microsoft 365 that blocks Power Automate", zh: "禁止 Power Automate 的 Microsoft 365"),
                            blurb: LocalizedText(en: "Drag emails from Outlook, save them with an Apple Mail rule, or forward alerts to Gmail or iCloud.",
                                                 zh: "从 Outlook 拖入邮件、用 Apple 邮件规则保存，或把提醒转发到 Gmail 或 iCloud。"),
                            helpTopic: .mailM365Blocked, beta: false),
            MailSourceEntry(id: .guideAppleMailRule, section: .otherWays, symbol: "tray.and.arrow.down",
                            title: LocalizedText(en: "Apple Mail rule → folder", zh: "Apple 邮件规则 → 文件夹"),
                            blurb: LocalizedText(en: "A Mail rule runs a script that saves matching emails as .eml files into a folder PaperDeck watches.",
                                                 zh: "邮件规则运行一个脚本，把匹配的邮件存成 .eml 放进 PaperDeck 监视的文件夹。"),
                            helpTopic: .mailFolderSources, beta: true),
            MailSourceEntry(id: .guideAppsScript, section: .otherWays, symbol: "doc.text",
                            title: LocalizedText(en: "Gmail → Google Drive (Apps Script)", zh: "Gmail → Google 云端硬盘（Apps Script）"),
                            blurb: LocalizedText(en: "A script in your own Google account copies alert emails into a Drive folder that syncs to this Mac.",
                                                 zh: "在你自己的 Google 账户里运行的脚本，把提醒邮件复制到会同步到这台 Mac 的云端硬盘文件夹。"),
                            helpTopic: .mailFolderSources, beta: true),
            MailSourceEntry(id: .guideDragOnly, section: .otherWays, symbol: "hand.draw",
                            title: LocalizedText(en: "Just drag emails in", zh: "直接拖入邮件"),
                            blurb: LocalizedText(en: "No account needed: drag emails from Outlook or Mail (or .eml files) onto PaperDeck.",
                                                 zh: "无需账户：把 Outlook 或「邮件」中的邮件（或 .eml 文件）拖到 PaperDeck 上。"),
                            helpTopic: .mailDragOnly, beta: false),
        ]
    }
}

/// The source of an existing account: the stored `MailAccount.source` wins; otherwise today's
/// inference (a folder under OneDrive or named "… Power Automate" is the Power Automate route).
package enum MailSourceResolver {
    package static func source(of a: MailAccount) -> MailSourceID {
        if let raw = a.source, let id = MailSourceID(rawValue: raw) { return id }
        switch a.kind {
        case .imap:
            switch a.imapPreset ?? .custom {
            case .gmail: return .imapGmail
            case .icloud: return .imapICloud
            case .yahoo: return .imapYahoo
            case .fastmail: return .imapFastmail
            case .custom: return .imapCustom
            }
        case .folder:
            let powerAutomate = CloudRootLocator.isOneDrivePath(a.folderPath ?? "") || a.displayName.contains("Power Automate")
            return powerAutomate ? .m365PowerAutomate : .folder
        }
    }
}

/// Generators of the folder-route helpers (Apple Mail rule, Google Apps Script): pure text, labeled
/// Beta until PORTABILITY_PLAN §7.3 V3 / V4 are verified. They embed only a folder name and the
/// sender patterns — never an address book, a password or a token.
package enum MailRuleScripts {
    /// An AppleScript for Apple Mail's "Run AppleScript" rule action: every message the rule
    /// matches is written (`source of`) to `<folder>/<message id>.eml`. The rule's own conditions
    /// pick the senders.
    package static func appleMailRule(folder: URL) -> String {
        var path = folder.standardizedFileURL.path
        if !path.hasSuffix("/") { path += "/" }
        return """
        -- PaperDeck (Beta): save the emails this Mail rule matches as .eml files for PaperDeck.
        -- Install: save this script in ~/Library/Application Scripts/com.apple.mail/, then in
        -- Mail ▸ Settings ▸ Rules add a rule (From contains … your alert senders) with the action
        -- "Run AppleScript" and choose this script. PaperDeck watches the folder below.
        property targetFolder : "\(appleScriptEscaped(path))"

        using terms from application "Mail"
        \ton perform mail action with messages theMessages for rule theRule
        \t\trepeat with msg in theMessages
        \t\t\ttry
        \t\t\t\tset rawSource to source of msg
        \t\t\t\tset fileName to my safeName(message id of msg) & ".eml"
        \t\t\t\tmy saveText(rawSource, targetFolder & fileName)
        \t\t\tend try
        \t\tend repeat
        \tend perform mail action with messages
        end using terms from

        on saveText(theText, posixPath)
        \tset fileRef to open for access (POSIX file posixPath) with write permission
        \ttry
        \t\tset eof of fileRef to 0
        \t\twrite theText to fileRef as «class utf8»
        \tend try
        \tclose access fileRef
        end saveText

        on safeName(theID)
        \tset allowed to "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
        \tset out to ""
        \trepeat with c in (characters of (theID as text))
        \t\tif allowed contains (c as text) then
        \t\t\tset out to out & (c as text)
        \t\telse
        \t\t\tset out to out & "_"
        \t\tend if
        \tend repeat
        \tif out is "" then set out to "message"
        \tif (length of out) > 120 then set out to text 1 thru 120 of out
        \treturn out
        end safeName

        """
    }

    /// A Google Apps Script (script.google.com, in the user's own Google account) that copies the
    /// raw source (`getRawContent()`) of recent emails from the sender patterns into a Drive folder
    /// as `<message id>.eml` — the folder Google Drive for desktop syncs to this Mac. `label`, when
    /// given, also limits the search to that Gmail label. Run it once by hand, then add a
    /// time-driven trigger.
    package static func googleAppsScript(driveFolderName: String, senders: [String], label: String?) -> String {
        let patterns = senders.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        let folder = driveFolderName.trimmingCharacters(in: .whitespaces).isEmpty ? "PaperDeck Mail" : driveFolderName
        let trimmedLabel = label?.trimmingCharacters(in: .whitespaces)
        let labelLiteral = (trimmedLabel?.isEmpty == false) ? jsString(trimmedLabel!) : "null"
        return """
        // PaperDeck (Beta): copy alert emails from Gmail into a Google Drive folder as .eml files.
        // Runs in your own Google account: script.google.com ▸ New project ▸ paste ▸ Run
        // savePaperDeckMail once (allow access) ▸ Triggers ▸ add a time-driven trigger (every hour).
        // Google Drive for desktop syncs the folder to your Mac; add it in PaperDeck as a folder account.
        const FOLDER_NAME = \(jsString(folder));
        const SENDERS = \(jsArray(patterns));
        const LABEL = \(labelLiteral);
        const LOOK_BACK_DAYS = 14;

        function savePaperDeckMail() {
          const folder = paperDeckFolder_();
          const from = SENDERS.map(function (s) { return "from:" + s.replace(/^@\\*?\\.?/, ""); }).join(" OR ");
          let query = "(" + from + ") newer_than:" + LOOK_BACK_DAYS + "d";
          if (LABEL) query += " label:" + LABEL.replace(/[\\s\\/]+/g, "-");
          GmailApp.search(query, 0, 100).forEach(function (thread) {
            thread.getMessages().forEach(function (message) {
              if (!fromAllowed_(message.getFrom())) return;
              const name = message.getId() + ".eml";
              if (folder.getFilesByName(name).hasNext()) return;
              folder.createFile(Utilities.newBlob(message.getRawContent(), "message/rfc822", name));
            });
          });
        }

        function fromAllowed_(header) {
          const match = /<([^>]+)>/.exec(header);
          const address = (match ? match[1] : header).trim().toLowerCase();
          return SENDERS.some(function (p) {
            if (p.indexOf("@*.") === 0) return address.endsWith("." + p.slice(3));
            if (p.indexOf("@") === 0) return address.endsWith(p);
            return address === p;
          });
        }

        function paperDeckFolder_() {
          const found = DriveApp.getFoldersByName(FOLDER_NAME);
          return found.hasNext() ? found.next() : DriveApp.createFolder(FOLDER_NAME);
        }

        """
    }

    /// An AppleScript string literal's contents: `\` and `"` escaped, control characters dropped.
    static func appleScriptEscaped(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            if CharacterSet.controlCharacters.contains(u) { continue }
            if u == "\\" { out += "\\\\" } else if u == "\"" { out += "\\\"" } else { out.unicodeScalars.append(u) }
        }
        return out
    }

    /// A JavaScript string literal (JSON-encoded: quotes, backslashes and control characters escaped;
    /// `</` broken up so the text can't end a script tag).
    static func jsString(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
    }

    static func jsArray(_ items: [String]) -> String {
        "[" + items.map(jsString).joined(separator: ", ") + "]"
    }
}
