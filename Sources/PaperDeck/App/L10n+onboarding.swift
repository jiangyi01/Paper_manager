import Foundation
import PaperDeckCore
import PaperDeckConfig

// The setup window (preflight / live / revisit) and the launch's library alerts.
extension L {
    enum Onb {
        private static var zh: Bool { L.lang == .zh }

        // MARK: Shell
        static var windowTitle: String { zh ? "PaperDeck 设置" : "PaperDeck Setup" }
        static var revisitTitle: String { zh ? "PaperDeck 设置助手" : "PaperDeck Setup Assistant" }
        static func page(_ p: OnboardingPage) -> String {
            switch p {
            case .welcome: zh ? "欢迎" : "Welcome"
            case .about: zh ? "关于你" : "About you"
            case .ai: zh ? "AI 解读" : "AI reading"
            case .library: zh ? "论文库" : "Library"
            case .plan: zh ? "每日计划" : "Daily plan"
            case .mail: zh ? "邮件（可选）" : "Mail (optional)"
            case .importPapers: zh ? "导入（可选）" : "Import (optional)"
            case .finish: zh ? "完成" : "Finish"
            }
        }
        static var help: String { zh ? "帮助" : "Help" }
        static var back: String { zh ? "上一步" : "Back" }
        static var skip: String { zh ? "跳过" : "Skip" }
        static var continueButton: String { zh ? "继续" : "Continue" }
        static var finish: String { zh ? "完成" : "Finish" }
        static var done: String { zh ? "完成" : "Done" }
        static var switchToChinese: String { "切换到中文？" }
        static var quitTitle: String { zh ? "退出 PaperDeck？" : "Quit PaperDeck?" }
        static var quitBody: String {
            zh ? "下次打开 PaperDeck 时可以继续完成设置。" : "You can finish setup the next time you open PaperDeck."
        }
        static var quit: String { zh ? "退出" : "Quit" }
        static var keepSettingUp: String { zh ? "继续设置" : "Keep Setting Up" }
        static var stepDone: String { zh ? "已完成" : "done" }
        static var stepCurrent: String { zh ? "当前" : "current" }
        static var stepTodo: String { zh ? "待完成" : "to do" }
        static var stepSkipped: String { zh ? "已跳过" : "skipped" }
        static var stepProblem: String { zh ? "需要处理" : "needs attention" }

        // MARK: P1 Welcome
        static var welcomeTitle: String { zh ? "欢迎使用 PaperDeck" : "Welcome to PaperDeck" }
        static var welcomePoints: [(String, String)] {
            [("doc.richtext", zh ? "把 PDF 拖到任何地方——自动生成阅读卡片、清单和截止日期。"
                                 : "Drop a PDF anywhere — get a reading card, a checklist and a deadline."),
             ("calendar.badge.clock", zh ? "每日阅读计划，每天一次提醒（默认 11:00，随时可改）。"
                                         : "A daily reading plan with one reminder (default 11:00, change any time)."),
             ("sparkles", zh ? "可选：用你自己的 Claude 或 ChatGPT 订阅生成 AI 摘要——不需要 API 密钥。"
                             : "Optional: AI summaries through your own Claude or ChatGPT subscription — no API keys."),
             ("envelope", zh ? "可选：从邮件中读取阅读请求。" : "Optional: reading requests from your email.")]
        }
        static var livesTitle: String { zh ? "PaperDeck 在哪里" : "Where PaperDeck lives" }
        static var livesBody: String {
            zh ? "PaperDeck 住在菜单栏和屏幕边缘的一条细条上——没有程序坞图标。帮助随时在「帮助 ▸ PaperDeck 帮助」中。"
               : "PaperDeck lives in your menu bar and on a thin strip at the edge of your screen — there's no Dock icon. Help is always under Help ▸ PaperDeck Help."
        }
        static var getStarted: String { zh ? "开始" : "Get Started" }
        static var movingFromMac: String { zh ? "我从另一台 Mac 迁移过来…" : "I'm moving from another Mac…" }
        static var setupFile: String { zh ? "使用实验室或 IT 给的配置文件…" : "Use a setup file from my lab or IT…" }
        static var quickStart: String { zh ? "使用推荐设置快速开始" : "Quick start with recommended defaults" }
        static var quickStartNote: String {
            zh ? "在「文稿/PaperDeck」创建论文库（macOS 会请求访问权限），暂不使用 AI，不开启邮件。之后都可以修改。"
               : "Creates your library in Documents/PaperDeck (macOS will ask for access), no AI for now, mail off. You can change everything later."
        }
        static func pendingPDFs(_ n: Int) -> String {
            zh ? "有 \(n) 个 PDF 正在等待——设置完成后会自动导入。"
               : (n == 1 ? "1 PDF is waiting — it will be imported when setup finishes."
                         : "\(n) PDFs are waiting — they will be imported when setup finishes.")
        }
        static var movingNote: String {
            zh ? "下一步选择「使用已有的 PaperDeck 论文库」，打开从旧 Mac 拷过来的论文库文件夹。"
               : "Next, choose “Use an existing PaperDeck library” and open the library folder you copied from your old Mac."
        }

        // MARK: P2 About you
        static var aboutTitle: String { zh ? "关于你" : "About you" }
        static func addStarters(_ field: String) -> String {
            zh ? "添加「\(field)」的起始分类" : "Add \(field) Starter Categories"
        }
        static func addedStarters(_ n: Int) -> String {
            zh ? "已添加 \(n) 个分类。没有重命名或删除任何分类。" : "Added \(n) categor\(n == 1 ? "y" : "ies"). Nothing was renamed or removed."
        }

        // MARK: P3 AI
        static var aiTitle: String { zh ? "AI 解读（可选）" : "AI reading (optional)" }
        static var aiSubtitle: String {
            zh ? "PaperDeck 可以用你自己的 Claude 或 ChatGPT 订阅总结论文。它从不使用 API 密钥，在你开启解读之前不消耗任何额度。"
               : "PaperDeck can summarize papers with your own Claude or ChatGPT subscription. It never uses API keys and spends no quota until you turn reading on."
        }
        static var claudeCard: String { "Claude" }
        static var codexCard: String { "ChatGPT (Codex)" }
        static var noneCard: String { zh ? "暂不使用——不用 AI 也能使用 PaperDeck" : "Not now — use PaperDeck without AI" }
        static func signedIn(plan: String, path: String?) -> String {
            let p = path.map { " · \($0)" } ?? ""
            return zh ? "已登录 · \(plan)\(p)" : "Signed in · \(plan)\(p)"
        }
        static var notInstalled: String { zh ? "未安装" : "Not installed" }
        static var notSignedIn: String { zh ? "已安装——未登录" : "Installed — not signed in" }
        static var apiKeyLogin: String {
            zh ? "使用 API 密钥登录——PaperDeck 需要订阅登录" : "Signed in with an API key — PaperDeck needs a subscription login"
        }
        static var checking: String { zh ? "正在检查…" : "Checking…" }
        static var installInTerminal: String { zh ? "在「终端」中安装：" : "Install it in Terminal:" }
        static var codexAppHint: String {
            zh ? "……或安装 ChatGPT 桌面应用——PaperDeck 会找到其中自带的 codex。"
               : "…or install the ChatGPT desktop app — PaperDeck finds the codex inside it."
        }
        static var signInInTerminal: String { zh ? "在「终端」中登录：" : "Sign in in Terminal:" }
        static var claudeLoginHint: String {
            zh ? "在「终端」中运行 claude，然后输入 /login，用你的 Claude 订阅登录。"
               : "Run claude in Terminal, then type /login and sign in with your Claude subscription."
        }
        static var openTerminal: String { zh ? "打开「终端」" : "Open Terminal" }
        static var iveSignedIn: String { zh ? "我已登录" : "I've Signed In" }
        static var advanced: String { zh ? "高级" : "Advanced" }
        static var customPath: String { zh ? "自定义路径…" : "Custom path…" }
        static var customPathPrompt: String { zh ? "选择" : "Choose" }
        static var notNowBody: String {
            zh ? "你仍然可以使用阅读清单、标题/DOI/arXiv 查询、截止日期、每日提醒，以及按本地规则整理的邮件。你不会有 TL;DR、摘要、AI 分类或 AI 邮件分析。随时可以在「设置 ▸ AI」中开启。"
               : "You still get a reading checklist, title/DOI/arXiv lookup, deadlines, the daily reminder and mail sorted by local rules. You won't get TL;DRs, summaries, AI categories or AI mail triage. Turn AI on any time in Settings ▸ AI."
        }
        static func turnOn(_ k: AIProviderKind) -> String {
            zh ? "开启 \(k.shortName) 解读" : "Turn On \(k.shortName) Reading"
        }
        static var turnOnNote: String {
            zh ? "开启后，PaperDeck 会用你的订阅自动解读新论文。" : "Turning reading on lets PaperDeck read new papers automatically with your subscription."
        }
        static func readingOn(_ k: AIProviderKind) -> String { zh ? "\(k.shortName) 解读已开启" : "\(k.shortName) reading is on" }
        /// Reading is on with another provider than the selected card's.
        static func switchReading(to k: AIProviderKind) -> String {
            zh ? "改用 \(k.shortName) 解读" : "Switch Reading to \(k.shortName)"
        }
        static var turnOff: String { zh ? "关闭" : "Turn Off" }
        static var continueWithoutAITitle: String { zh ? "暂时不使用 AI 继续？" : "Continue without AI for now?" }
        static func continueWithoutAIBody(_ k: AIProviderKind) -> String {
            zh ? "你选择了 \(k.shortName)，但还没有开启解读。可以稍后在「设置 ▸ AI」中开启。"
               : "You chose \(k.shortName) but haven't turned reading on. You can turn it on later in Settings ▸ AI."
        }
        static var continueWithoutAI: String { zh ? "不使用 AI 继续" : "Continue Without AI" }
        static var turnOnEllipsis: String { zh ? "开启…" : "Turn On…" }

        // MARK: P4 Library
        static var libraryTitle: String { zh ? "你的论文库" : "Your library" }
        static var librarySubtitle: String {
            zh ? "PaperDeck 把每篇论文的 PDF 和 card.json 保存在一个普通文件夹中，以后可以移动它，或在另一台 Mac 上打开。"
               : "PaperDeck keeps every paper in a normal folder with its PDF and a card.json file, so you can move it or open it on another Mac later."
        }
        static var optDocuments: String { zh ? "在「文稿」中新建论文库" : "New library in Documents" }
        static var optHome: String { zh ? "在个人文件夹中新建论文库（~/PaperDeck）" : "New library in your home folder (~/PaperDeck)" }
        static var optOther: String { zh ? "在其他文件夹中新建论文库…" : "New library in another folder…" }
        static var optExisting: String { zh ? "使用已有的 PaperDeck 论文库…" : "Use an existing PaperDeck library…" }
        static var tccNote: String {
            zh ? "macOS 会询问是否允许 PaperDeck 使用你的「文稿」文件夹，请点「允许」。"
               : "macOS will ask to let PaperDeck use your Documents folder. Click Allow."
        }
        static var documentsInICloud: String {
            zh ? "你的「文稿」文件夹与 iCloud 同步，文件可能会被移出这台 Mac。只用一台 Mac 没问题；想要本地副本请改用 ~/PaperDeck。"
               : "Your Documents folder syncs with iCloud, so files can be moved off this Mac. That's fine on one Mac; for a local copy use ~/PaperDeck instead."
        }
        static var useHomeFolder: String { zh ? "改用 ~/PaperDeck" : "Use ~/PaperDeck" }
        static var choose: String { zh ? "选择…" : "Choose…" }
        static var chooseFolderPrompt: String { zh ? "使用这个文件夹" : "Use This Folder" }
        static var classifyCloud: String {
            zh ? "这个文件夹由云服务同步。同一时间只在一台 Mac 上使用 PaperDeck，并保持文件夹已下载。"
               : "This folder is synced by a cloud service. Use PaperDeck on one Mac at a time and keep the folder downloaded."
        }
        static var classifyRemovable: String { zh ? "这个磁盘连接时 PaperDeck 才能工作。" : "PaperDeck works while this disk is connected." }
        static var classifyOther: String { zh ? "PaperDeck 会在里面创建 Papers 文件夹。" : "PaperDeck will create a Papers folder inside." }
        static func foundLibrary(_ n: Int) -> String {
            zh ? "找到一个 PaperDeck 论文库 · 约 \(n) 篇论文。继续后会为它建立索引。"
               : "Found a PaperDeck library · about \(n) papers. It will be indexed when you continue."
        }
        static func didYouMean(_ path: String) -> String { zh ? "你是指 \(path) 吗？" : "Did you mean \(path)?" }
        static var useIt: String { zh ? "使用它" : "Use It" }
        static var noLibraryHere: String { zh ? "这里没有 PaperDeck 论文库。" : "No PaperDeck library here." }
        static var chooseAnother: String { zh ? "选择其他文件夹" : "Choose Another" }
        static var createHere: String { zh ? "在这里新建论文库" : "Create a New Library Here" }
        static var deniedInline: String {
            zh ? "PaperDeck 无法使用这个文件夹。请在「系统设置 ▸ 隐私与安全性 ▸ 文件与文件夹」中允许，或选择其他文件夹。"
               : "PaperDeck can't use this folder. Allow access in System Settings ▸ Privacy & Security ▸ Files and Folders, or choose another folder."
        }
        static var openPrivacy: String { zh ? "打开隐私与安全性" : "Open Privacy & Security" }
        static var chooseAnotherFolder: String { zh ? "选择其他文件夹…" : "Choose Another Folder…" }
        static var retry: String { zh ? "重试" : "Retry" }
        static var missingParent: String { zh ? "这个位置已经不存在，请重新选择。" : "This location doesn't exist any more. Choose again." }
        static var readOnly: String { zh ? "PaperDeck 无法写入这个文件夹，请重新选择。" : "PaperDeck can't write to this folder. Choose again." }
        static var opening: String { zh ? "正在打开你的论文库…" : "Opening your library…" }
        static var currentLibrary: String { zh ? "当前论文库" : "Current library" }
        static func paperCount(_ n: Int) -> String { zh ? "\(n) 篇论文" : "\(n) paper\(n == 1 ? "" : "s")" }
        static var changeLocation: String { zh ? "更改位置…" : "Change Location…" }
        static var restartNow: String { zh ? "立即重启 PaperDeck" : "Restart PaperDeck Now" }
        static var restartPending: String { zh ? "新的论文库位置会在重启后生效。" : "The new library location applies after a restart." }

        // Launch: identity mismatch, missing disk
        static var mismatchTitle: String {
            zh ? "这个文件夹里是另一个 PaperDeck 论文库" : "This folder contains a different PaperDeck library"
        }
        static func mismatchBody(_ n: Int) -> String {
            zh ? "PaperDeck 的索引属于另一个论文库（\(n) 篇论文）。为避免混在一起，没有做任何更改。"
               : "PaperDeck's index belongs to another library (\(n) papers). Nothing was changed, to avoid mixing them."
        }
        static var reindexFailed: String {
            zh ? "PaperDeck 无法为这个论文库文件夹建立索引。可以在「设置 ▸ 论文库」中重建索引。"
               : "PaperDeck couldn't index the library folder. You can rebuild the index in Settings ▸ Library."
        }
        static var openThisLibrary: String { zh ? "打开这个论文库" : "Open This Library" }
        static func goBackTo(_ path: String) -> String { zh ? "回到 \(path)" : "Go Back to \(path)" }
        static func volumeMissingTitle(_ volume: String) -> String {
            zh ? "没有连接磁盘「\(volume)」" : "The disk “\(volume)” isn't connected"
        }
        static func volumeMissingBody(path: String, volume: String) -> String {
            zh ? "你的论文库在 \(path)。请连接磁盘「\(volume)」后点「重试」，或选择其他论文库文件夹。没有做任何更改。"
               : "Your library is at \(path). Connect “\(volume)” and click Retry, or choose another library folder. Nothing was changed."
        }

        // MARK: P5 Daily plan
        static var planTitle: String { zh ? "每日计划与提醒" : "Daily plan & reminder" }
        static var planSubtitle: String {
            zh ? "PaperDeck 把待读论文排进每天的时间预算，并在每天提醒一次。" : "PaperDeck fits your papers into a daily time budget and reminds you once a day."
        }
        static var notificationsTitle: String { zh ? "通知" : "Notifications" }
        static var allowNotifications: String { zh ? "允许通知" : "Allow Notifications" }
        static var openNotificationSettings: String { zh ? "打开通知设置" : "Open Notification Settings" }
        static var notificationsAllowed: String { zh ? "已允许通知" : "Notifications are allowed" }
        static var notificationsDenied: String { zh ? "通知已关闭" : "Notifications are off" }
        static var notificationsUnknown: String { zh ? "尚未询问" : "Not asked yet" }
        static var notificationsUnavailable: String { zh ? "这个版本无法使用通知" : "Notifications aren't available in this build" }
        static var loginToggle: String {
            zh ? "登录时打开 PaperDeck（推荐——它住在菜单栏里）" : "Open PaperDeck at login (recommended — it lives in the menu bar)"
        }
        static var loginHint: String {
            zh ? "macOS 会显示「已添加后台项目」——那就是 PaperDeck。" : "macOS will show “Background item added” — that's PaperDeck."
        }
        static var loginNeedsApproval: String {
            zh ? "需要在「系统设置 ▸ 通用 ▸ 登录项」中允许。" : "Needs your approval in System Settings ▸ General ▸ Login Items."
        }
        static var openLoginItems: String { zh ? "打开登录项" : "Open Login Items" }
        static var moveToApplications: String {
            zh ? "请把 PaperDeck 移到「应用程序」文件夹——小组件和登录时打开都需要。"
               : "Move PaperDeck to your Applications folder — the widget and Open at Login need it."
        }
        static var showInFinder: String { zh ? "在 Finder 中显示" : "Show in Finder" }

        // MARK: P6 Mail
        static var mailAskTitle: String { zh ? "要让 PaperDeck 查看你的邮件吗？" : "Do you want PaperDeck to look at your email?" }
        static var mailAskBody: String {
            zh ? "PaperDeck 只读取你列出的发件人的邮件，保存在这台 Mac 上，从不发送邮件。"
               : "PaperDeck reads only emails from senders you list, keeps them on this Mac and never sends mail."
        }
        static var setUpNow: String { zh ? "现在设置" : "Set Up Now" }
        static var dragOnly: String { zh ? "只在我拖入邮件时" : "Only When I Drag Emails In" }
        static var notNow: String { zh ? "暂不" : "Not Now" }
        static var dragTip: String {
            zh ? "把邮件从「邮件」或 Outlook 拖到 PaperDeck 的窗口或屏幕边缘的条上——它会变成一张卡片。"
               : "Drag an email from Mail or Outlook onto PaperDeck's window or the edge strip — it becomes a card."
        }
        static var whereTitle: String { zh ? "你的邮件在哪里？" : "Where does your mail live?" }
        static func route(_ r: OnboardingRules.MailRoute) -> String {
            switch r {
            case .m365: zh ? "学校或公司的 Microsoft 365（Outlook）" : "Work or school Microsoft 365 (Outlook)"
            case .gmail: zh ? "Gmail（个人）" : "Gmail (personal)"
            case .workspace: zh ? "Google Workspace（学校或公司的 Gmail）" : "Google Workspace (work or school Gmail)"
            case .icloud: zh ? "iCloud 邮件" : "iCloud Mail"
            case .outlookCom: zh ? "个人 Outlook.com / Hotmail" : "Personal Outlook.com / Hotmail"
            case .otherIMAP: zh ? "其他邮件服务（Yahoo、Fastmail、学校 IMAP…）" : "Another provider (Yahoo, Fastmail, university IMAP…)"
            case .folder: zh ? "一个已经在接收 .eml 文件的文件夹" : "A folder that already receives .eml files"
            }
        }
        static func routeSymbol(_ r: OnboardingRules.MailRoute) -> String {
            switch r {
            case .m365: "building.2"
            case .gmail: "envelope.badge"
            case .workspace: "person.2"
            case .icloud: "icloud"
            case .outlookCom: "envelope"
            case .otherIMAP: "server.rack"
            case .folder: "folder"
            }
        }
        static var m365Title: String { zh ? "你所在的机构能使用 Power Automate 吗？" : "Can you use Power Automate at your organization?" }
        static var m365Yes: String { zh ? "能" : "Yes" }
        static var m365Unsure: String { zh ? "不确定——试试看" : "Not Sure — Try It" }
        static var m365Blocked: String { zh ? "不能，被禁止了" : "No, It's Blocked" }
        static var addAccount: String { zh ? "添加账户…" : "Add the Account…" }
        static var otherRoutes: String { zh ? "其他方式" : "Other routes" }
        static var guidePending: String { zh ? "这条路线的详细步骤在帮助中心。" : "The step-by-step guide for this route is in the Help Center." }
        static var openGuide: String { zh ? "打开指南" : "Open the Guide" }
        static var sendersTitle: String { zh ? "谁会给你发论文？" : "Who sends you papers?" }
        static var advisorPlaceholder: String { zh ? "导师或同事的邮箱地址" : "Advisor or colleague address" }
        static var addSender: String { zh ? "添加" : "Add" }
        static var addedSender: String { zh ? "已添加到发件人列表" : "Added to the sender list" }
        static func suggestedFor(_ field: String) -> String { zh ? "「\(field)」建议的提醒发件人" : "Suggested alert senders for \(field)" }
        static var presetNote: String {
            zh ? "提醒类发件人的邮件会自动交给 AI 阅读（它们是公开的订阅通讯）。人发来的邮件总是先询问你。"
               : "Alert senders are read by AI automatically (they're public newsletters). People's emails always ask first."
        }
        static var turnOnMail: String { zh ? "开启邮件" : "Turn On Mail" }
        static var mailIsOn: String { zh ? "邮件已开启" : "Mail is on" }
        static func synced(_ ago: String, _ n: Int) -> String {
            zh ? "\(ago)同步 · 已收到 \(n) 封邮件" : "Synced \(ago) · \(n) email\(n == 1 ? "" : "s") captured"
        }
        static var notSyncedYet: String { zh ? "尚未同步" : "Not synced yet" }

        // MARK: P7 Import
        static var importTitle: String { zh ? "导入你已有的论文" : "Bring in papers you already have" }
        static var importHint: String {
            zh ? "例如你的「下载」文件夹或存放 PDF 的文件夹。Zotero 用户：~/Zotero/storage（只导入 PDF，不含 Zotero 笔记）。"
               : "e.g. your Downloads folder or the folder where you keep PDFs. Zotero users: ~/Zotero/storage (PDFs only, not your notes)."
        }

        // MARK: P8 Finish
        static var finishTitle: String { zh ? "设置完成" : "You're set" }
        static func libraryLine(_ path: String, _ n: Int) -> String {
            zh ? "论文库 \(path) · \(n) 篇论文" : "Library \(path) · \(n) paper\(n == 1 ? "" : "s")"
        }
        static func aiLine(_ k: AIProviderKind, plan: String?) -> String {
            let p = plan.map { "（\($0)）" } ?? ""
            return zh ? "AI：\(k.shortName)\(p)" : "AI: \(k.shortName)" + (plan.map { " (\($0))" } ?? "")
        }
        static var aiNotNow: String { zh ? "AI：暂不使用" : "AI: not now" }
        static func reminderLine(_ time: String, allowed: Bool) -> String {
            zh ? "提醒 \(time)" + (allowed ? " · 已允许通知" : " · 通知未允许")
               : "Reminder \(time)" + (allowed ? " · notifications allowed" : " · notifications not allowed")
        }
        static var reminderOff: String { zh ? "每日提醒已关闭" : "Daily reminder off" }
        static var mailNotSetUp: String { zh ? "邮件：未设置" : "Mail: not set up" }
        static var mailDragOnly: String { zh ? "邮件：只在拖入时" : "Mail: only when you drag emails in" }
        static func mailLine(_ n: Int, on: Bool) -> String {
            zh ? "邮件：\(n) 个账户" + (on ? " · 已开启" : " · 未开启") : "Mail: \(n) account\(n == 1 ? "" : "s")" + (on ? " · on" : " · off")
        }
        static func signingLine(_ name: String) -> String { zh ? "签名：证书「\(name)」" : "Signing: certificate “\(name)”" }
        static var signingAdhoc: String {
            zh ? "签名：临时签名——每次重新构建后需要重新授权（见「帮助 ▸ 从源代码构建」）"
               : "Signing: ad hoc — permissions reset after each rebuild (see Help ▸ Build from source)"
        }
        static var change: String { zh ? "更改" : "Change" }
        static var findHere: String { zh ? "在这里找到 PaperDeck" : "Find PaperDeck here" }
        static var findMenuBar: String { zh ? "菜单栏图标：今天的计划、添加 PDF、设置" : "The menu-bar icon: today's plan, Add PDF, Settings" }
        static var findStrip: String { zh ? "屏幕边缘的细条：把 PDF 拖到上面" : "The edge strip: drop PDFs on it" }
        static var findHelp: String { zh ? "帮助 ▸ PaperDeck 帮助：教程和故障排查" : "Help ▸ PaperDeck Help: tutorials and troubleshooting" }
        static var takeTour: String { zh ? "看看 1 分钟功能导览" : "Take the 1-Minute Tour" }
        static var openLibrary: String { zh ? "打开论文库" : "Open Library" }
        static var showChecklist: String { zh ? "在「今天」中显示入门清单" : "Show Getting Started on Today" }
        static var finishNeeds: String {
            zh ? "完成前需要：可用的论文库和关于 AI 的选择。" : "To finish: a usable library and a choice about AI."
        }
    }
}
