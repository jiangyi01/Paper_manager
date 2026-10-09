import Foundation
import PaperDeckCore
import PaperDeckConfig

// Strings of Settings ▸ Mail (accounts portal, senders, criteria, AI triage, merge) — zh + en,
// English by default. Namespaced under `L.MailPref` so they never collide with the Mail inbox
// slice's strings. Status / error texts from Core (IMAP, folder, triage) arrive already worded.
// Organization- and field-dependent sentences come from `OrgStrings` / `FieldStrings` (the
// configured institution and research field, `L.org` / `L.field`): this file holds no institution.

extension L {
    enum MailPref {
        private static var zh: Bool { L.lang == .zh }
        /// The configured institution's text for `key` in the UI language.
        private static func org(_ key: OrgTextKey) -> String { OrgStrings.text(key, org: L.org, lang: L.lang) }

        static var tabMail: String { zh ? "邮件" : "Mail" }

        // MARK: Common

        static var edit: String { zh ? "编辑…" : "Edit…" }
        static var remove: String { zh ? "移除…" : "Remove…" }
        static var done: String { zh ? "完成" : "Done" }
        static var back: String { zh ? "返回" : "Back" }
        static func days(_ n: Int) -> String { zh ? "\(n) 天" : (n == 1 ? "1 day" : "\(n) days") }
        static func megabytes(_ n: Int) -> String { "\(n) MB" }
        static func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
        static func removeKeyword(_ w: String) -> String { zh ? "移除「\(w)」" : "Remove “\(w)”" }

        // MARK: 1. Master switch

        static var sectionMail: String { zh ? "邮件" : "Mail" }
        static var enable: String { zh ? "从邮件中收集阅读请求" : "Collect reading requests from email" }
        static var enableHint: String {
            zh ? "只打开发件人列表中的邮件（只读）；所有内容都留在这台 Mac 上。"
               : "PaperDeck opens only emails from your sender list, read-only; everything stays on this Mac."
        }
        static var syncNowLabel: String { zh ? "检查新邮件" : "Check for new mail" }
        static var syncNow: String { zh ? "立即同步" : "Sync Now" }
        static var syncNowHint: String { zh ? "立即检查所有已启用的账户。" : "Checks every enabled account now." }
        static var syncNowOffHint: String { zh ? "请先打开上方的开关并添加账户。" : "Turn mail on and add an account first." }
        static var syncInterval: String { zh ? "自动检查" : "Check automatically" }
        static var manualOnly: String { zh ? "仅手动" : "Manually only" }
        static func every(minutes m: Int) -> String { zh ? "每 \(m) 分钟" : "Every \(m) min" }
        static var dropAlwaysWorks: String {
            zh ? "不需要账户也能用：把 Outlook 里的邮件（或 .eml 文件）拖到 PaperDeck 上即可。"
               : "No account needed: dragging emails from Outlook (or .eml files) onto PaperDeck always works."
        }

        static var summaryOff: String { zh ? "已关闭 — PaperDeck 不会检查任何邮箱。" : "Off — PaperDeck doesn't check any mailbox." }
        static var summaryNoAccounts: String { zh ? "还没有账户 — 在下方添加。" : "No account yet — add one below." }
        static var summaryAllPaused: String { zh ? "所有账户都已暂停。" : "All accounts are paused." }
        static func summarySyncing(_ n: Int) -> String { zh ? "正在检查 \(n) 个账户…" : "Checking \(accounts(n))…" }
        static func summaryProblems(_ n: Int) -> String {
            zh ? "\(n) 个账户需要处理（见下方）。" : (n == 1 ? "1 account needs attention — see below." : "\(n) accounts need attention — see below.")
        }
        static func summaryOK(accounts n: Int, last: String?) -> String {
            if let last { return zh ? "\(n) 个账户 · 上次检查 \(last)" : "\(accounts(n)) · last checked \(last)" }
            return zh ? "\(n) 个账户 · 尚未检查" : "\(accounts(n)) · not checked yet"
        }
        private static func accounts(_ n: Int) -> String { n == 1 ? "1 account" : "\(n) accounts" }

        // MARK: Account status

        static var statusReady: String { zh ? "就绪" : "Ready" }
        static var statusNeedsSetup: String { zh ? "需要设置" : "Needs setup" }
        static var statusSignInFailed: String { zh ? "登录失败" : "Sign-in failed" }
        static var statusUnavailable: String { zh ? "暂时无法访问" : "Unavailable for now" }
        static var statusMailOff: String { zh ? "邮件已关闭" : "Mail is off" }
        static var statusPaused: String { zh ? "已暂停" : "Paused" }
        static var statusSyncing: String { zh ? "正在检查…" : "Checking…" }
        static var statusNotChecked: String { zh ? "尚未检查" : "Not checked yet" }
        static func lastChecked(_ t: String, new: Int) -> String { zh ? "上次检查 \(t) · 新增 \(new) 封" : "Last checked \(t) · \(new) new" }
        static var waitingForSettings: String {
            zh ? "等待修改设置 — 编辑账户或点「立即同步」" : "Waiting for new settings — edit the account or click Sync Now"
        }
        static func nextRetry(_ t: String) -> String { zh ? "\(t) 重试" : "Retrying at \(t)" }

        // MARK: 2. Accounts

        static var accountsSection: String { zh ? "账户" : "Accounts" }
        static var noAccounts: String { org(.accountsIntro) }
        static var addAccount: String { zh ? "添加账户…" : "Add Account…" }
        static var accountsFooter: String {
            zh ? "只读：IMAP 账户用 EXAMINE 与 BODY.PEEK 打开，不会标记已读、移动或删除任何邮件。应用专用密码只保存在这台 Mac 的登录钥匙串里。"
               : "Read-only: IMAP accounts are opened with EXAMINE and BODY.PEEK — nothing is marked read, moved or deleted. App passwords stay in this Mac's login keychain."
        }
        static func removeAccountTitle(_ name: String) -> String { zh ? "移除「\(name)」？" : "Remove “\(name)”?" }
        static var removeAccount: String { zh ? "移除" : "Remove" }
        static var removeIMAPBody: String {
            zh ? "PaperDeck 将停止检查这个邮箱，并从钥匙串删除它的应用专用密码。已收集的邮件仍保留在「邮件」里。你也可以在邮箱服务商处撤销该应用专用密码。"
               : "PaperDeck stops checking this mailbox and deletes its app password from the keychain. Emails already captured stay in Mail. You can also revoke the app password with your provider."
        }
        static var removeFolderBody: String {
            zh ? "PaperDeck 将停止监视这个文件夹。文件夹中的文件和已收集的邮件都会保留。"
               : "PaperDeck stops watching this folder. Its files and the emails already captured stay."
        }
        static var unnamedAccount: String { zh ? "账户" : "Account" }
        static var accountEnabled: String { zh ? "启用" : "Enabled" }
        static var pauseHelp: String { zh ? "暂停此账户" : "Pause this account" }
        static var resumeHelp: String { zh ? "恢复此账户" : "Resume this account" }
        static var lookback: String { zh ? "首次检查回溯" : "First check looks back" }
        static var lookbackShort: String { zh ? "回溯" : "Look back" }
        static var lookbackHelp: String {
            zh ? "首次检查读取多久以前的邮件；之后只读新邮件。" : "How far back the first check reads; after that only new mail is read."
        }

        // MARK: Add account sheet

        static var addAccountTitle: String { zh ? "添加邮件账户" : "Add Mail Account" }
        static func editAccountTitle(_ kind: String) -> String { zh ? "编辑 — \(kind)" : "Edit — \(kind)" }
        static var addAccountButton: String { zh ? "添加账户" : "Add Account" }
        static var testAndSave: String { zh ? "测试并保存" : "Test & Save" }
        static var turnOnAndClose: String { zh ? "打开邮件并关闭" : "Turn On Mail & Close" }

        static func templateName(_ t: MailAccountTemplate) -> String {
            switch t {
            case .powerAutomate: return org(.paTemplateName)
            case .imap(.gmail): return zh ? "Gmail（应用专用密码）" : "Gmail (app password)"
            case .imap(.icloud): return zh ? "iCloud 邮件" : "iCloud Mail"
            case .imap(.yahoo): return zh ? "Yahoo 邮件" : "Yahoo Mail"
            case .imap(.fastmail): return "Fastmail"
            case .imap(.custom): return zh ? "其他 IMAP 服务器" : "Other IMAP server"
            case .folder: return zh ? ".eml 文件夹" : "Folder of .eml files"
            }
        }

        static func templateBlurb(_ t: MailAccountTemplate) -> String {
            switch t {
            case .powerAutomate: return org(.paTemplateBlurb)
            case .imap(.gmail): return org(.gmailBlurb)
            case .imap(.icloud): return zh ? "iCloud 邮件 + App 专用密码。" : "iCloud Mail with an app-specific password."
            case .imap(.yahoo): return zh ? "Yahoo 邮件 + 应用密码。" : "Yahoo Mail with an app password."
            case .imap(.fastmail): return zh ? "Fastmail + 应用密码。" : "Fastmail with an app password."
            case .imap(.custom):
                return zh ? "任何支持 TLS（端口 993）的 IMAP 服务器。" : "Any IMAP server over TLS (port 993) with a password or app password."
            case .folder:
                return zh ? "任何会收到 .eml 文件的文件夹 — Apple Mail 规则、「另存为」、脚本等。"
                          : "Any folder that receives .eml files — an Apple Mail rule, Save As…, a script."
            }
        }

        /// Always contains "Power Automate" (the legacy source inference relies on it).
        static var powerAutomateDefaultName: String { OrgStrings.paDefaultAccountName(org: L.org, lang: L.lang) }
        static var folderDefaultName: String { zh ? "文件夹" : "Folder" }
        static var displayName: String { zh ? "名称" : "Name" }

        // Folder
        static var paFolderSection: String { zh ? "OneDrive 文件夹" : "OneDrive folder" }
        static var folderSection: String { zh ? "监视的文件夹" : "Watched folder" }
        static var watchedFolder: String { zh ? "文件夹" : "Folder" }
        static var createFolder: String { zh ? "创建文件夹" : "Create Folder" }
        static var chooseFolder: String { zh ? "选择…" : "Choose…" }
        static var chooseFolderMessage: String { zh ? "选择存放 .eml 邮件文件的文件夹" : "Choose the folder that receives .eml files" }
        static var deleteProcessed: String { zh ? "处理后删除文件" : "Delete processed files" }
        static var deleteProcessedHint: String {
            zh ? "邮件收集后删除对应的 .eml（OneDrive 中的副本也会删除）。" : "Removes an .eml once its email is captured (the OneDrive copy goes too)."
        }
        /// The delete hint for a folder synced by `provider` (OneDrive keeps today's text; nil: a
        /// local folder).
        static func deleteProcessedHint(_ provider: CloudProvider?) -> String {
            guard let name = cloudName(provider) else {
                return zh ? "邮件收集后删除对应的 .eml 文件。" : "Removes an .eml once its email is captured."
            }
            if isOneDrive(provider) { return deleteProcessedHint }
            return zh ? "邮件收集后删除对应的 .eml（\(name) 中的副本也会删除）。" : "Removes an .eml once its email is captured (the \(name) copy goes too)."
        }
        static var folderExists: String { zh ? "已找到文件夹" : "Folder found" }
        static var notAFolder: String { zh ? "这个路径是文件，不是文件夹。" : "This path is a file, not a folder." }
        static var folderMissingCreate: String {
            zh ? "文件夹还不存在 — 可以现在创建，或等 OneDrive 同步。" : "The folder doesn't exist yet — create it now, or let OneDrive sync it."
        }
        /// The missing-folder line for a folder synced by `provider` (OneDrive keeps today's text).
        static func folderMissingCreate(_ provider: CloudProvider?) -> String {
            guard let name = cloudName(provider) else {
                return zh ? "文件夹还不存在 — 可以现在创建。" : "The folder doesn't exist yet — create it now."
            }
            if isOneDrive(provider) { return folderMissingCreate }
            return zh ? "文件夹还不存在 — 可以现在创建，或等 \(name) 同步。" : "The folder doesn't exist yet — create it now, or let \(name) sync it."
        }
        static var oneDriveMissing: String { org(.oneDriveMissing) }
        /// The missing-OneDrive line plus the cloud roots this Mac does have (none: as is).
        static func oneDriveMissing(found roots: [String]) -> String {
            guard !roots.isEmpty else { return oneDriveMissing }
            return oneDriveMissing + (zh ? " 已找到：" + roots.joined(separator: "、") : " Found: " + roots.joined(separator: ", "))
        }
        /// The provider's name in folder texts (nil: not a cloud folder).
        static func cloudName(_ p: CloudProvider?) -> String? {
            switch p {
            case .oneDriveBusiness?, .oneDrivePersonal?, .oneDriveShared?: return "OneDrive"
            case .dropbox?: return "Dropbox"
            case .googleDrive?: return "Google Drive"
            case .box?: return "Box"
            case .iCloudDrive?: return zh ? "iCloud 云盘" : "iCloud Drive"
            case .other?, nil: return nil
            }
        }
        private static func isOneDrive(_ p: CloudProvider?) -> Bool {
            p == .oneDriveBusiness || p == .oneDrivePersonal || p == .oneDriveShared
        }
        static var folderMissing: String { zh ? "找不到文件夹。" : "Folder not found." }
        static var noFolderYet: String { zh ? "请选择文件夹。" : "Choose a folder." }
        static var folderCreated: String { zh ? "已创建文件夹。" : "Folder created." }
        static func folderCreateFailed(_ m: String) -> String { zh ? "无法创建文件夹：\(m)" : "Couldn't create the folder: \(m)" }
        static var savedFolder: String { zh ? "已保存。下次同步时会检查这个文件夹。" : "Saved. PaperDeck checks the folder on the next sync." }
        static var folderHowTo: String {
            zh ? "PaperDeck 在这个文件夹里查找新的 .eml 文件（不含子文件夹）；正在写入的文件会等写完再读。只有发件人列表中的邮件会被读取。"
               : "PaperDeck looks for new .eml files in this folder (not subfolders); files still being written are read once they settle. Only emails from your sender list are read."
        }

        // Power Automate
        static var paGuideSection: String { zh ? "Power Automate 流" : "Power Automate flow" }
        static var paBlockedNote: String { org(.paBlockedNote) }
        static var useGmailInstead: String { zh ? "改用 Gmail" : "Set Up Gmail Instead" }
        static var otherWays: String { zh ? "其他方式…" : "Other Ways…" }
        static var paIntro: String { org(.paIntro) }
        static var paPackageTitle: String { zh ? "或者：导入现成的流" : "Or import a ready-made flow" }
        static var paPackageHint: String {
            zh ? "用于「我的流 ▸ 导入 ▸ 导入包(旧版)」的 .zip，包含同样的三个步骤，From 按你的发件人列表填好。"
               : "A .zip for My flows ▸ Import ▸ Import Package (Legacy) with the same three steps, From filled in from your sender list."
        }
        static var savePackage: String { zh ? "生成导入包…" : "Generate Import Package…" }
        static var savePackageMessage: String { zh ? "保存 Power Automate 导入包" : "Save the Power Automate import package" }
        static func packageSaved(_ path: String) -> String { zh ? "已保存 \(path)" : "Saved \(path)" }
        static func packageFailed(_ m: String) -> String { zh ? "无法写入流程包：\(m)" : "Couldn't write the package: \(m)" }
        static var paManualTitle: String { zh ? "创建流（或检查你建好的流）" : "Build the flow (or check the one you built)" }
        static var openPowerAutomate: String { zh ? "打开 Power Automate" : "Open Power Automate" }
        static var paStep1: String {
            zh ? "打开 make.powerautomate.com ▸「创建」▸「自动化云端流」，命名为「PaperDeck Mail」。"
               : "Open make.powerautomate.com ▸ Create ▸ Automated cloud flow, and name it “PaperDeck Mail”."
        }
        static var paStep2: String {
            zh ? "触发器：Office 365 Outlook —「When a new email arrives (V3)」。Folder：Inbox。在高级参数里找到 From，粘贴下面的地址（用分号 ; 分隔）。"
               : "Trigger: Office 365 Outlook — “When a new email arrives (V3)”. Folder: Inbox. Under the advanced parameters, paste the addresses below into From (separated by semicolons)."
        }
        static var paStep3: String {
            zh ? "新建步骤：Office 365 Outlook —「Export email (V2)」。Message Id：从触发器的动态内容中选「Message Id」。"
               : "New step: Office 365 Outlook — “Export email (V2)”. Message Id: pick the trigger's “Message Id” (dynamic content)."
        }
        static var paStep4: String {
            zh ? "新建步骤：OneDrive for Business —「Create file」（在这个连接器的操作列表里点「See more / 查看更多」才会出现）。Folder Path 填："
               : "New step: OneDrive for Business — “Create file” (click “See more” in the connector's list of actions to find it). Folder Path:"
        }
        static var paStep5: String {
            zh ? "File Name：点这个框 ▸ fx（插入表达式）▸ 粘贴下面的表达式 ▸「添加」。文件名是时间加随机编号，不含主题。"
               : "File Name: click the box ▸ fx (Insert expression) ▸ paste the expression below ▸ Add. The name is a timestamp plus a random id — never the subject."
        }
        static var paStep6: String {
            zh ? "File Content：fx ▸ 粘贴下面的表达式 ▸「添加」（也可以在动态内容的 Export email (V2) 下选「Body」）。"
               : "File Content: fx ▸ paste the expression below ▸ Add (or pick “Body” under Export email (V2) in the dynamic content)."
        }
        static var paFileContentWarning: String {
            zh ? "不要选触发器（When a new email arrives）的「Body」：那只是邮件的 HTML 正文，没有发件人和附件，PaperDeck 无法读取，这些文件会被标为「不是完整的邮件」。"
               : "Don't pick the trigger's “Body” (When a new email arrives): that is only the message's HTML, without sender or attachments — PaperDeck can't read those files and reports them as “not complete emails”."
        }
        static var paStep7: String {
            zh ? "保存，然后用列表中的发件人给自己发一封测试邮件：几分钟内 OneDrive ▸ PaperDeck Mail 里会出现 .eml，PaperDeck 会自动读取。"
               : "Save, then send yourself a test email from a listed sender: within a few minutes an .eml appears in OneDrive ▸ PaperDeck Mail and PaperDeck picks it up."
        }
        static var paFolderPath: String { "Folder Path" }
        static var paFileName: String { "File Name" }
        static var paFileContent: String { "File Content" }
        static var copyAllSteps: String { zh ? "复制全部步骤" : "Copy All Steps" }
        static var guideTitle: String { zh ? "Power Automate 设置指南" : "Power Automate Guide" }
        static var openGuide: String { zh ? "打开 Power Automate 指南…" : "Open Power Automate Guide…" }
        static var guideFixHeader: String {
            zh ? "请检查第 6 步 File Content：" : "Check step 6, File Content:"
        }

        // OneDrive folder detection (existence checks only)
        static var oneDriveLooking: String { zh ? "正在查找 OneDrive 中的 PaperDeck Mail 文件夹…" : "Looking for a PaperDeck Mail folder in OneDrive…" }
        static var oneDriveFound: String {
            zh ? "已找到 OneDrive 中现有的「PaperDeck Mail」文件夹，已选中。" : "Found your existing “PaperDeck Mail” folder in OneDrive and selected it."
        }
        static var oneDrivePrompt: String {
            zh ? "PaperDeck 第一次读取这个文件夹时，macOS 可能会弹窗询问是否允许访问「由 OneDrive 管理的文件」。请点「允许」——PaperDeck 只读取这个文件夹里的 .eml 文件。"
               : "The first time PaperDeck reads this folder, macOS may ask whether to allow access to files managed by OneDrive. Click Allow — PaperDeck only reads the .eml files in this folder."
        }
        static func paFromLabel(_ n: Int) -> String {
            zh ? "From（\(n) 个地址，用 ; 分隔）" : (n == 1 ? "From (1 address)" : "From (\(n) addresses, separated by ;)")
        }
        static func paFromDomains(_ rules: [String]) -> String {
            let list = rules.joined(separator: ", ")
            return zh ? "域名规则（\(list)）无法填进 From。可以把 From 留空（流会把收件箱的所有邮件复制到你的 OneDrive，PaperDeck 只读取白名单中的），或在列表里添加这些发件人的具体地址。"
                      : "Domain rules (\(list)) can't go in the From field. Either leave From empty (the flow then copies every Inbox email to your OneDrive and PaperDeck reads only the allowlisted ones), or add those senders' exact addresses to the list."
        }
        static func paFromOnlyDomains(_ rules: [String]) -> String {
            let list = rules.joined(separator: ", ")
            return zh ? "列表里只有域名规则（\(list)），From 无法表达。请把 From 留空（流会把收件箱的所有邮件复制到你的 OneDrive，PaperDeck 只读取白名单中的），或添加具体地址。"
                      : "Your list only has domain rules (\(list)), which the From field can't express. Leave From empty (the flow then copies every Inbox email to your OneDrive and PaperDeck reads only the allowlisted ones), or add exact addresses."
        }
        static var paFromNoSenders: String {
            zh ? "请先在「发件人」里添加发件人；From 的值由列表生成。" : "Add your senders under Senders first; the From value is generated from that list."
        }
        static func paFromIgnored(_ list: [String]) -> String {
            zh ? "无法用于流：\(list.joined(separator: ", "))" : "Not usable in the flow: \(list.joined(separator: ", "))"
        }
        static var paFromEmptyText: String { zh ? "（留空 — 所有发件人）" : "(empty — all senders)" }

        // IMAP
        static var accountSection: String { zh ? "账户" : "Account" }
        static var provider: String { zh ? "服务商" : "Provider" }
        static func presetName(_ p: MailAccount.IMAPPreset) -> String {
            switch p {
            case .gmail: return "Gmail"
            case .icloud: return "iCloud"
            case .yahoo: return "Yahoo"
            case .fastmail: return "Fastmail"
            case .custom: return zh ? "其他" : "Other"
            }
        }
        static var address: String { zh ? "邮箱地址" : "Email address" }
        static func addressPrompt(_ p: MailAccount.IMAPPreset) -> String {
            switch p {
            case .gmail: return "you@gmail.com"
            case .icloud: return "you@icloud.com"
            case .yahoo: return "you@yahoo.com"
            case .fastmail: return "you@fastmail.com"
            case .custom: return "you@example.org"
            }
        }
        static func presetNote(_ p: MailAccount.IMAPPreset) -> String? {
            switch p {
            case .gmail:
                return zh ? "提示：在 Gmail 里建一个过滤器，把论文提醒邮件加上「PaperDeck」标签，然后在下面的「邮箱文件夹或标签」填 PaperDeck。"
                          : "Tip: create a Gmail filter that labels your alert emails “PaperDeck”, then enter PaperDeck as the mailbox below."
            case .icloud:
                return zh ? "使用 iCloud 邮件地址（…@icloud.com / @me.com）。App 专用密码需要 Apple 账户开启双重认证。"
                          : "Use your iCloud Mail address (…@icloud.com / @me.com). App-specific passwords need two-factor authentication on your Apple Account."
            case .yahoo:
                return zh ? "在「账户安全 ▸ 其他登录方式」中生成应用密码。" : "Generate an app password under Account Security ▸ Other ways to sign in."
            case .fastmail:
                return zh ? "创建一个带 IMAP 权限的应用密码（只读即可）。" : "Create an app password with IMAP access (read-only is enough)."
            case .custom:
                return nil
            }
        }
        static var serverSection: String { zh ? "服务器" : "Server" }
        static var server: String { zh ? "IMAP 服务器" : "IMAP server" }
        static var port: String { zh ? "端口" : "Port" }
        static var mailbox: String { zh ? "邮箱文件夹或标签" : "Mailbox or label" }
        static func mailboxHint(_ p: MailAccount.IMAPPreset) -> String {
            p == .gmail ? (zh ? "INBOX，或 Gmail 标签名，例如 PaperDeck（标签在 IMAP 中就是文件夹）。"
                              : "INBOX, or a Gmail label such as PaperDeck (labels are IMAP folders).")
                        : (zh ? "INBOX 或文件夹名。" : "INBOX or a folder name.")
        }
        static var appPasswordSection: String { zh ? "应用专用密码" : "App password" }
        static var appPasswordStep: String { zh ? "创建应用专用密码" : "Create an app password" }
        static var openAppPasswordPage: String { zh ? "打开官方页面…" : "Open Official Page…" }
        static var appPassword: String { zh ? "应用专用密码" : "App password" }
        static var appPasswordPrompt: String { zh ? "粘贴应用专用密码" : "Paste the app password" }
        static var keepSavedPassword: String { zh ? "留空则保留已保存的密码" : "Leave empty to keep the saved password" }
        static var retypePasswordPrompt: String { zh ? "为新的服务器重新输入应用专用密码" : "Type the app password again for the new server" }
        static var serverChangedNote: String {
            zh ? "服务器、端口或邮箱地址已更改：PaperDeck 不会把已保存的密码发送到新的服务器，请重新输入应用专用密码。"
               : "The server, port or address changed, so PaperDeck won't send the saved password to it. Type the app password again."
        }
        static var readOnlyNote: String {
            zh ? "PaperDeck 只读取：用 EXAMINE 打开邮箱、用 BODY.PEEK 读取，不会标记已读、移动或删除任何邮件，也从不发信。密码只保存在这台 Mac 的登录钥匙串里。"
               : "PaperDeck only reads: it opens the mailbox with EXAMINE and fetches with BODY.PEEK, so nothing is marked read, moved or deleted, and it never sends mail. The password is stored only in this Mac's login keychain."
        }
        static var gmailTwoStep: String {
            zh ? "Gmail 应用专用密码需要 Google 账号开启两步验证（学校/工作账号和「高级保护」账号不支持）。"
               : "Gmail app passwords require 2-Step Verification on your Google Account (not available for work/school accounts or Advanced Protection)."
        }
        static func alertsTip(_ p: MailAccount.IMAPPreset) -> String { FieldStrings.alertsTip(L.field, L.lang) }
        static func testing(_ host: String) -> String { zh ? "正在登录 \(host)…" : "Signing in to \(host)…" }
        static var enterAppPassword: String { zh ? "请输入应用专用密码。" : "Enter the app password." }
        static var reenterAppPassword: String {
            zh ? "服务器、端口或地址已更改，请重新输入应用专用密码。" : "The server, port or address changed: type the app password again."
        }
        static func savedIMAP(_ detail: String) -> String { zh ? "\(detail) — 已保存" : "\(detail) — saved" }
        static func keychainFailed(_ m: String) -> String { zh ? "无法把密码存入钥匙串：\(m)" : "Couldn't save the password in the keychain: \(m)" }

        // MARK: 3. Senders

        static var sendersSection: String { zh ? "发件人" : "Senders" }
        static var noSenders: String {
            zh ? "还没有发件人。PaperDeck 只打开列表中发件人的邮件 — 请添加导师、合作者和论文提醒服务。"
               : "No senders yet. PaperDeck only opens emails from senders on this list — add your advisor, collaborators and alert services."
        }
        static var addSender: String { zh ? "添加发件人…" : "Add Sender…" }
        static var addPreset: String { zh ? "添加提醒预设" : "Add Alert Preset" }
        static var allPresetsAdded: String { zh ? "预设已全部添加" : "All presets are already in the list" }
        static var sendersFooter: String {
            zh ? "其他邮件不会被打开。只比较地址本身 —「Prof. X」这样的显示名称永远不算。规则：name@school.edu（一个地址）、@biorxiv.org（该域名）、@*.nature.com（任意子域）。"
               : "Everything else is skipped without being opened. Only the address counts — a display name such as “Prof. X” never matches. Patterns: name@school.edu (one address), @biorxiv.org (that domain), @*.nature.com (any subdomain)."
        }
        static func deleteSenderTitle(_ name: String) -> String { zh ? "删除「\(name)」？" : "Delete “\(name)”?" }
        static var deleteSenderBody: String {
            zh ? "之后不会再读取这位发件人的新邮件。已收集的邮件会保留。" : "New emails from this sender will no longer be read. Emails already captured stay."
        }
        static var colSender: String { zh ? "发件人" : "Sender" }
        static var colKind: String { zh ? "类型" : "Kind" }
        static var colAI: String { "AI" }
        static var senderEnabled: String { zh ? "启用" : "Enabled" }
        static var patternInvalidShort: String { zh ? "规则无效" : "Invalid pattern" }
        static func aiPolicyShort(_ p: MailAIPolicy) -> String {
            switch p {
            case .ask: return zh ? "询问" : "Ask"
            case .always: return zh ? "总是" : "Always"
            case .never: return zh ? "从不" : "Never"
            }
        }
        static func kindName(_ k: SenderKind) -> String {
            switch k {
            case .advisor: return zh ? "导师" : "Advisor"
            case .person: return zh ? "同事" : "Person"
            case .alert: return zh ? "论文提醒" : "Alert"
            case .manual: return zh ? "手动导入" : "Dropped"
            }
        }

        // Sender sheet
        static var addSenderTitle: String { zh ? "添加发件人" : "Add Sender" }
        static var editSenderTitle: String { zh ? "编辑发件人" : "Edit Sender" }
        static var addSenderButton: String { zh ? "添加" : "Add" }
        static var senderSection: String { zh ? "发件人" : "Sender" }
        static var pattern: String { zh ? "地址或域名" : "Address or domain" }
        static var patternPrompt: String { "name@school.edu, @biorxiv.org, @*.nature.com" }
        static var senderLabel: String { zh ? "名称" : "Label" }
        static var senderLabelPrompt: String { zh ? "例如：Smith 教授、Google Scholar" : "Prof. Smith, Google Scholar…" }
        static var patternFooter: String {
            zh ? "只比较地址部分（不区分大小写，忽略 +标签）；显示名称永远不算。" : "Only the address part is compared (case-insensitive, +tags ignored). Display names never count."
        }
        static var patternEmpty: String { zh ? "请输入地址或域名。" : "Enter an address or a domain." }
        static func patternDuplicate(_ name: String) -> String { zh ? "列表中已有「\(name)」。" : "Already in the list as “\(name)”." }
        static func patternMeaning(_ p: SenderMatcher.Pattern) -> String {
            switch p {
            case .address(let a): return zh ? "仅 \(a)" : "Exactly \(a)"
            case .domain(let d): return zh ? "\(d) 的所有地址（不含子域）" : "Everyone at \(d) (not its subdomains)"
            case .wildcard(let d): return zh ? "\(d) 及其所有子域（如 mail.\(d)）" : "\(d) and any subdomain (e.g. mail.\(d))"
            }
        }
        static var patternInvalid: String { org(.patternInvalid) }
        static var kind: String { zh ? "类型" : "Kind" }
        static func kindHint(_ k: SenderKind) -> String {
            switch k {
            case .advisor:
                return zh ? "导师 / PI：请求默认高优先级，邮件中的截止日期可作为 DDL。"
                          : "Your advisor / PI: requests are high priority and their due dates can become DDLs."
            case .person: return zh ? "分享或请你读论文的合作者、同事。" : "A collaborator or colleague who shares or requests papers."
            case .alert, .manual:
                return zh ? "期刊 / 预印本提醒与目录（公开内容）。" : "Journal / preprint alerts and tables of contents (public content)."
            }
        }
        static var aiSection: String { "AI" }
        static var aiPolicy: String { zh ? "发送给 AI 分拣" : "Send to AI for triage" }
        static func aiPolicyName(_ p: MailAIPolicy) -> String {
            switch p {
            case .ask: return zh ? "每次询问（在卡片上点「让 AI 分析」）" : "Ask each time (click “Analyze with AI” on the card)"
            case .always: return zh ? "总是" : "Always"
            case .never: return zh ? "从不 — 仅本地规则" : "Never — local rules only"
            }
        }
        static func aiPolicyHint(_ p: MailAIPolicy) -> String {
            switch p {
            case .ask:
                return zh ? "邮件先在本机用规则分拣；在你点击之前不会发给 AI。" : "Emails are sorted by local rules on your Mac; nothing goes to AI until you ask."
            case .always:
                return zh ? "这位发件人的每封邮件都会自动发给 AI（在每日上限内）。" : "Every email from this sender goes to AI automatically (within the daily limit)."
            case .never: return zh ? "这位发件人的邮件永远不会离开这台 Mac。" : "This sender's emails never leave your Mac."
            }
        }
        /// A person / advisor rule set to Always (the institution's wording; display only).
        static var personSenderWarning: String { org(.personSenderWarning) }
        /// The institution's AI guidance under a person / advisor rule (display only).
        static var policyNote: String { org(.policyNote) }
        static var mergeDefaultsSection: String { zh ? "合并该发件人的论文时" : "When merging this sender's papers" }
        static var defaultPriority: String { zh ? "优先级" : "Priority" }
        static func priorityByKind(_ k: SenderKind) -> String {
            k == .advisor ? (zh ? "按类型（高）" : "By kind (High)") : (zh ? "按类型（普通）" : "By kind (Normal)")
        }
        static func priorityName(_ p: Priority) -> String {
            switch p {
            case .high: return zh ? "高" : "High"
            case .normal: return zh ? "普通" : "Normal"
            case .low: return zh ? "低" : "Low"
            }
        }
        static var defaultCategory: String { zh ? "分类" : "Category" }
        static var noCategory: String { zh ? "无（由 AI 解读决定）" : "None (AI reading decides)" }
        static var useDueDate: String { zh ? "把邮件中的截止日期设为 DDL" : "Use the email's due date as the DDL" }
        static var useDueDateHint: String { zh ? "仅当日期明确且未过期时。" : "Only when the date is stated clearly and not past." }
        static var autoMerge: String { zh ? "有 PDF 的论文自动合并入库" : "Merge papers that have a PDF automatically" }
        static var autoMergeHint: String {
            zh ? "附件和可下载的 PDF 不等你确认就入库；其余论文仍留在卡片上。"
               : "Attachments and downloadable PDFs go into the library without waiting for you; the rest stay on the card."
        }
        static var autoDownload: String { zh ? "自动保存附件" : "Store attachments automatically" }
        static var autoDownloadHint: String {
            zh ? "收到邮件时保存附带的 PDF，合并时无需再下载。" : "Keeps attached PDFs when the email arrives so they're ready to merge."
        }

        // MARK: 4. Criteria

        static var criteriaSection: String { zh ? "什么算阅读需求" : "What counts as a reading request" }
        static var keepKinds: String { zh ? "作为阅读需求保留" : "Keep as reading requests" }
        static var keepKindsHint: String { zh ? "其他邮件归入「无阅读需求」。" : "Other emails go to “No reading request”." }
        static func requestKindName(_ k: MailRequestKind) -> String {
            switch k {
            case .advisorRequest: return zh ? "请我读或汇报论文" : "Requests to read or present a paper"
            case .journalClub: return zh ? "组会 / Journal club" : "Journal club / lab meeting"
            case .fyi: return zh ? "分享的论文（FYI）" : "Papers shared FYI"
            case .alertDigest: return zh ? "论文提醒摘要" : "Alert digests"
            case .other: return zh ? "其他论文相关邮件" : "Other paper emails"
            case .notPaper: return zh ? "与论文无关" : "Not about papers"
            }
        }
        static var includeKeywords: String { zh ? "关注关键词" : "Always relevant" }
        static var includeKeywordsHint: String { zh ? "提到这些词的论文会被标为重点。" : "Papers mentioning these are highlighted." }
        static var excludeKeywords: String { zh ? "排除关键词" : "Never relevant" }
        static var excludeKeywordsHint: String {
            zh ? "提到这些词的邮件或论文会被放到一边（永不自动合并）。" : "Emails or papers mentioning these are set aside (never merged automatically)."
        }
        static var includePrompt: String { zh ? "输入关键词后按回车" : "Add a keyword, press Return" }
        static var excludePrompt: String { zh ? "输入关键词后按回车" : "Add a keyword, press Return" }
        static var researchInterests: String { zh ? "研究兴趣" : "Research interests" }
        static var researchInterestsHint: String {
            zh ? "用于从论文提醒中挑出相关论文。" : "Used to pick the relevant papers of alert digests."
        }
        static var customInstructions: String { zh ? "给 AI 的说明" : "Instructions for the AI" }
        static var customInstructionsHint: String { FieldStrings.customInstructionsHint(L.field, L.lang) }
        static var minConfidence: String { zh ? "最低置信度" : "Minimum confidence" }
        static var minConfidenceHint: String {
            zh ? "AI 判断的阅读请求低于此置信度时归入「无阅读需求」。" : "AI-detected requests below this confidence go to “No reading request”."
        }
        static func maxAlertPapers(_ n: Int) -> String { zh ? "每封提醒最多 \(n) 篇" : "At most \(n) papers per alert" }
        static var maxAlertPapersHint: String {
            zh ? "只突出最相关的几篇，其余折叠。" : "Only the most relevant are highlighted; the rest stay collapsed."
        }
        static var criteriaFooter: String {
            zh ? "邮件到达时本地规则立即应用这些设置；AI 分拣把它们作为你的偏好（排除关键词始终优先）。"
               : "Local rules apply these as soon as an email arrives; the AI triage gets them as your preferences (an exclude always wins)."
        }

        // MARK: 5. AI triage

        static var triageSection: String { zh ? "AI 分拣" : "AI triage" }
        static var triageMode: String { zh ? "分拣方式" : "Triage" }
        static var modeAI: String { "AI" }
        static var modeLocal: String { zh ? "仅本地规则" : "Local rules only" }
        static var modeAIHint: String {
            zh ? "论文提醒自动发给 AI；个人发件人的邮件只有在你点「让 AI 分析」（或发件人设为「总是」）时才发送。"
               : "Alerts go to AI automatically; people's emails only when you click “Analyze with AI” (or their sender is set to Always)."
        }
        static var modeLocalHint: String {
            zh ? "任何内容都不会发给 AI。请求、截止日期和论文都由本机规则识别。"
               : "Nothing is ever sent to AI. Requests, due dates and papers are found by local rules on your Mac."
        }
        static var triageProvider: String { zh ? "服务" : "Provider" }
        static func sameAsReading(_ k: AIProviderKind) -> String {
            zh ? "与 AI 解读相同（\(k.shortName)）" : "Same as AI reading (\(k.shortName))"
        }
        static var claudeModel: String { zh ? "Claude 模型" : "Claude model" }
        static var codexModel: String { zh ? "ChatGPT 模型" : "ChatGPT model" }
        static func triageModelName(_ slug: String) -> String {
            switch slug {
            case "haiku": return zh ? "Haiku — 快、最省额度（推荐）" : "Haiku — fast, least quota (recommended)"
            case "sonnet": return zh ? "Sonnet — 更仔细" : "Sonnet — more careful"
            case "gpt-5.6-luna": return zh ? "GPT-5.6-Luna — 快、更省（推荐）" : "GPT-5.6-Luna — fast, less quota (recommended)"
            case "gpt-5.6-terra": return zh ? "GPT-5.6-Terra — 均衡" : "GPT-5.6-Terra — balanced"
            default: return slug
            }
        }
        static var dailyCap: String { zh ? "每日上限" : "Daily limit" }
        static var dailyCapHint: String {
            zh ? "超出后等到明天再分拣（「让 AI 分析」仍可用）。" : "Beyond it, triage waits until tomorrow (“Analyze with AI” still works)."
        }
        static func perDay(_ n: Int) -> String { zh ? "每天 \(n) 次" : "\(n) per day" }
        static func todayUsage(_ used: Int, _ limit: Int) -> String { zh ? "今天 \(used)/\(limit)" : "Today \(used)/\(limit)" }
        static var bodyCap: String { zh ? "发送的正文长度" : "Email text sent" }
        static var bodyCapHint: String { zh ? "更长的邮件会被截断。" : "Longer emails are cut at this length." }
        static var whatIsSent: String { zh ? "发送给 AI 的内容" : "What is sent to AI" }
        static var whatIsSentHint: String {
            zh ? "用示例邮件生成的一次分拣请求的完整内容" : "The exact text of one triage request, built from a sample email"
        }
        static var showSample: String { zh ? "显示示例…" : "Show Example…" }
        static var triagePrivacy: String { org(.triagePrivacy) }
        static var sampleTitle: String { zh ? "发送给 AI 的内容（示例）" : "What is sent to AI (example)" }
        static var sampleIntro: String {
            zh ? "一封虚构的导师邮件，按你当前的设置、分类和标签处理。真实请求的格式相同，内容是一封邮件清理后的文本。"
               : "A made-up advisor email processed with your current settings, categories and tags. A real request has the same format with one email's cleaned text."
        }
        static func sampleMeta(provider: String, model: String, bytes: Int) -> String {
            "\(provider) · \(model) · \(SettingsFormat.bytes(Int64(bytes)))"
        }
        static var systemPrompt: String { zh ? "系统提示词（固定）" : "System prompt (fixed)" }

        // MARK: 6. Merge & reminders

        static var mergeSection: String { zh ? "合并与提醒" : "Merge & reminders" }
        static var prefillNotes: String { zh ? "在合并论文的笔记里写入「来自邮件：…」" : "Add “From email: …” to the notes of merged papers" }
        static var prefillNotesHint: String { zh ? "发件人、主题与日期，仅当笔记为空时。" : "Sender, subject and date — only when the notes are empty." }
        static var notifyRequests: String { zh ? "有新的阅读请求时通知我" : "Notify me about new reading requests" }
        static var notifyRequestsHint: String {
            zh ? "导师和同事的每封新请求一条通知，只显示发件人名字和主题；新添加账户的首次同步不会通知。默认关闭（每日提醒已包含）。"
               : "One notification per new request from your advisor or colleagues — sender name and subject only; nothing for a new account's first sync. Off by default (the daily reminder covers them)."
        }
        static func includeInReminder(_ time: String) -> String { zh ? "在 \(time) 提醒中包含邮件" : "Include emails in the \(time) reminder" }
        static var includeInReminderHint: String {
            zh ? "在末行前加一行「邮件待处理 3 封（1 封导师请求）」。" : "Adds “3 emails to handle (1 request)” before the last line."
        }
        static var reminderIsOff: String {
            zh ? "每日提醒已关闭（设置 ▸ 阅读计划与提醒）。" : "The daily reminder is off (Settings ▸ Plan & Reminders)."
        }
        static var attachmentCap: String { zh ? "附件大小上限" : "Largest attachment stored" }
        static var attachmentCapHint: String { zh ? "更大的 PDF 会标为「需要 PDF」。" : "Bigger PDFs are marked “Needs PDF”." }
        static var retention: String { zh ? "邮件正文保留" : "Keep email text for" }
        static var retentionHint: String {
            zh ? "从卡片处理完毕起计算；主题、发件人、链接与论文记录会保留作来源。"
               : "Counted from when a card is handled; subject, sender, link and papers stay as the source."
        }
        static var keepForever: String { zh ? "永久保留" : "Forever" }
        static var clearAllLabel: String { zh ? "邮件数据" : "Mail data" }
        static var clearAll: String { zh ? "清除所有邮件数据…" : "Clear All Mail Data…" }
        static var clearAllHint: String {
            zh ? "所有已收集的邮件、论文条目、保存的附件和同步位置。已入库的论文保留来源记录。"
               : "Every captured email, its paper rows, stored attachments and sync positions. Library papers keep their source."
        }
        static var clearConfirmTitle: String { zh ? "清除所有邮件数据？" : "Clear all mail data?" }
        static var clearConfirm: String { zh ? "清除" : "Clear" }
        static var clearConfirmBody: String {
            zh ? "将删除所有邮件卡片、论文条目和保存的附件，以及同步位置（账户会按回溯天数重新开始）。账户、发件人列表和资料库中的论文都会保留。"
               : "Deletes every email card, its paper rows and stored attachments, and the sync positions (accounts start over with their look-back). Your accounts, sender list and library papers stay."
        }
        static var cleared: String { zh ? "已清除邮件数据" : "Mail data cleared" }
        static var backupNote: String {
            zh ? "每日数据库备份（保留 7 天）中也包含邮件数据。" : "Daily database backups (kept 7 days) also contain mail data."
        }

        // MARK: 7. Mail sources, presets, date order

        // Add-account chooser: "Set up an account" (today's rows) + "Other ways to get mail in".
        static var chooserSetUp: String { zh ? "设置账户" : "Set up an account" }
        static var chooserOtherWays: String { zh ? "其他收取邮件的方式" : "Other ways to get mail in" }
        static var beta: String { "Beta" }
        static var opensHelp: String { zh ? "在帮助中打开分步说明" : "Opens step-by-step help" }

        // Alert presets (the 「添加提醒预设」 menu): the field's suggestions first, then the rest.
        static func suggestedFor(_ field: String) -> String { zh ? "推荐给「\(field)」" : "Suggested for \(field)" }
        static var morePresets: String { zh ? "更多预设" : "More presets" }
        static var checkPresetAddress: String {
            zh ? "请在一封提醒邮件里核对发件人地址" : "Check the sender address in one of your alerts"
        }
        static func presetUnverified(_ label: String) -> String { zh ? "\(label)（待核对）" : "\(label) (check address)" }

        // Reading criteria: how "3/10" reads.
        static var dateOrder: String { zh ? "像 3/10 这样的日期表示" : "Dates like 3/10 mean" }
        static var dateOrderHint: String {
            zh ? "用于识别邮件里的截止日期。" : "Used to read due dates in emails."
        }
        static func dateOrderName(_ o: SlashDateOrder) -> String {
            switch o {
            case .mdy: return zh ? "3 月 10 日（月在前）" : "March 10 (month first)"
            case .dmy: return zh ? "10 月 3 日（日在前）" : "3 October (day first)"
            case .auto:
                let resolved = o.resolved() == .dmy ? (zh ? "日在前" : "day first") : (zh ? "月在前" : "month first")
                return zh ? "跟随这台 Mac 的地区（\(resolved)）" : "Follow my Mac's region (\(resolved))"
            }
        }

        // Folder form: the Apple Mail rule (Beta).
        static var appleMailRuleTitle: String { zh ? "用 Apple Mail 规则把邮件存到这里（Beta）" : "Save emails here with an Apple Mail rule (Beta)" }
        static var appleMailRuleIntro: String {
            zh ? "如果邮件在 Apple Mail 里（包括不能用 Power Automate 的 Microsoft 365 邮箱），可以用一条规则把发件人列表中的新邮件存成 .eml 放进这个文件夹：保存下面的脚本，然后在 Mail ▸ 设置 ▸ 规则中添加一条规则，「执行 AppleScript」选这个脚本。"
               : "If your mail is in Apple Mail (also a Microsoft 365 mailbox that can't use Power Automate), a rule can save new emails from your senders into this folder as .eml files: save the script below, then add a rule in Mail ▸ Settings ▸ Rules whose action is “Run AppleScript” with this script."
        }
        static var appleMailRuleNote: String {
            zh ? "Mail 必须保持打开。脚本只把邮件原文写进这个文件夹，不会发送或删除任何邮件。"
               : "Mail has to be running. The script only writes the message source into this folder — it never sends or deletes mail."
        }
        static var copyScript: String { zh ? "复制脚本" : "Copy Script" }
        static var saveScript: String { zh ? "保存脚本…" : "Save Script…" }
        static var saveScriptMessage: String {
            zh ? "保存到 Mail 的脚本文件夹，规则才能选到它" : "Save it in Mail's script folder so a rule can pick it"
        }
        static func scriptSaved(_ path: String) -> String { zh ? "已保存 \(path)" : "Saved \(path)" }
        static func scriptFailed(_ m: String) -> String { zh ? "无法保存脚本：\(m)" : "Couldn't save the script: \(m)" }
        static var chooseFolderFirst: String { zh ? "请先选择文件夹。" : "Choose the folder first." }
    }
}
