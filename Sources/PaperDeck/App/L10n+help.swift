import Foundation
import PaperDeckCore
import PaperDeckConfig

// Help Center chrome (window, sidebar, checklist, tour, troubleshooting, diagnostics, menus).
// Topic texts live in `GuideContent` (bilingual data); these are the buttons and labels around them.
extension L {
    enum Help {
        private static var zh: Bool { L.lang == .zh }

        static var windowTitle: String { zh ? "PaperDeck 帮助" : "PaperDeck Help" }
        static var searchPrompt: String { zh ? "搜索帮助" : "Search Help" }
        static var noResults: String { zh ? "没有找到相关主题" : "No matching topics" }
        static var gettingStarted: String { zh ? "入门清单" : "Getting Started" }
        static var tour: String { zh ? "功能导览" : "Feature Tour" }
        static var tutorials: String { zh ? "教程" : "Tutorials" }
        static var mailTutorials: String { zh ? "连接邮件" : "Connect your mail" }
        static var troubleshooting: String { zh ? "故障排查" : "Troubleshooting" }
        static var diagnostics: String { zh ? "诊断信息" : "Diagnostics" }
        static var topicUnavailable: String { zh ? "这个主题暂时没有内容。" : "This topic isn't available yet." }
        static var openHelp: String { zh ? "打开帮助" : "Open Help" }

        // Status
        static var statusNow: String { zh ? "当前状态" : "Status now" }
        static var statusDone: String { zh ? "已完成" : "Done" }
        static func statusInProgress(_ done: Int, _ total: Int) -> String {
            zh ? "进行中 · \(done)/\(total)" : "In progress · \(done) of \(total)"
        }
        static var statusChecking: String { zh ? "正在检查…" : "Checking…" }
        static var statusNothing: String { zh ? "这一页没有需要检查的内容" : "Nothing to check on this page" }
        static var statusNotApplying: String { zh ? "目前这台 Mac 上没有这个问题" : "This doesn't apply to this Mac right now" }
        static var appliesNow: String { zh ? "当前适用" : "Applies now" }
        static var stepDone: String { zh ? "已完成" : "Done" }
        static var stepTodo: String { zh ? "待完成" : "To do" }
        static var stepChecking: String { zh ? "正在检查" : "Checking" }
        static var stepNotApplicable: String { zh ? "不适用" : "Doesn't apply" }
        static var markDone: String { zh ? "标记为已完成" : "Mark as Done" }
        static var unmarkDone: String { zh ? "取消完成标记" : "Mark as Not Done" }
        static var related: String { zh ? "相关主题" : "Related" }
        static var stillStuck: String { zh ? "仍然没解决？" : "Still stuck?" }
        static var copyDiagnostics: String { zh ? "复制诊断信息…" : "Copy Diagnostics…" }
        static func lastReviewed(_ s: String) -> String { zh ? "最近核对：\(s)" : "Last reviewed: \(s)" }
        static var beta: String { zh ? "测试版" : "Beta" }

        // Getting Started
        static func progress(_ done: Int, _ total: Int) -> String { zh ? "\(done)/\(total)" : "\(done) of \(total)" }
        static var gettingStartedSubtitle: String {
            zh ? "每一项都会实时检查这台 Mac 的真实状态，完成后自动打勾。"
               : "Each item checks this Mac live and ticks itself when it's done."
        }
        static var required: String { zh ? "必需" : "Required" }
        static var skipThis: String { zh ? "跳过" : "Skip" }
        static var showSkipped: String { zh ? "显示已跳过的项目" : "Show Skipped Items" }
        static var hideChecklist: String { zh ? "在「今天」中隐藏入门清单" : "Hide Getting Started on Today" }
        static var showChecklist: String { zh ? "在「今天」中显示入门清单" : "Show Getting Started on Today" }
        static var openChecklist: String { zh ? "打开清单" : "Open Checklist" }
        static var hide: String { zh ? "隐藏" : "Hide" }
        static var cardTitle: String { zh ? "入门" : "Getting Started" }
        static var allRequiredDone: String { zh ? "必需的步骤都已完成。" : "The required steps are done." }
        static var notUsingMail: String { zh ? "不使用邮件" : "Not using mail" }
        static var cloudLibraryNote: String { zh ? "在云文件夹中：同一时间只在一台 Mac 上使用" : "In a cloud folder: one Mac at a time" }

        // Item / step buttons
        static var librarySettings: String { zh ? "论文库设置" : "Library Settings" }
        static var addPDF: String { zh ? "添加 PDF…" : "Add PDF…" }
        static var showDropStrip: String { zh ? "显示拖放条" : "Show the Drop Strip" }
        static var showMe: String { zh ? "演示给我看" : "Show Me" }
        static var openToday: String { zh ? "打开「今天」" : "Open Today" }
        static var aiSettings: String { zh ? "AI 设置" : "AI Settings" }
        static var allow: String { zh ? "允许" : "Allow" }
        static var openNotificationSettings: String { zh ? "打开通知设置" : "Open Notification Settings" }
        static var openAtLogin: String { zh ? "登录时打开" : "Open at Login" }
        static var widgetSettings: String { zh ? "小组件设置" : "Widget Settings" }
        static var iveAddedIt: String { zh ? "我已添加" : "I've Added It" }
        static var connectMail: String { zh ? "连接邮件" : "Connect Mail" }
        static var setUp: String { zh ? "设置" : "Set Up" }
        static var senderList: String { zh ? "发件人列表" : "Sender List" }
        static var exportSettings: String { zh ? "导出设置…" : "Export Settings…" }
        static var importSettings: String { zh ? "导入设置…" : "Import Settings…" }
        static var learnMore: String { zh ? "了解更多" : "Learn More" }
        static func openSettingsTab(_ tab: String) -> String {
            let name: String
            switch tab {
            case "general": name = zh ? "通用" : "General"
            case "plan": name = zh ? "阅读计划" : "Plan"
            case "ai": name = "AI"
            case "mail": name = zh ? "邮件" : "Mail"
            case "library": name = zh ? "论文库" : "Library"
            case "widget": name = zh ? "小组件" : "Widget"
            case "profile": name = zh ? "个人资料" : "Profile"
            default: name = tab
            }
            return zh ? "打开设置 ▸ \(name)" : "Open Settings ▸ \(name)"
        }
        static var openLink: String { zh ? "打开" : "Open" }
        static var openSystemSettings: String { zh ? "打开系统设置" : "Open System Settings" }
        static var addAccount: String { zh ? "添加账户…" : "Add the Account…" }
        static var copyAppleScript: String { zh ? "复制 AppleScript" : "Copy AppleScript" }
        static var copyAppsScript: String { zh ? "复制 Apps Script" : "Copy Apps Script" }
        static var savePackage: String { zh ? "保存流程包…" : "Save Flow Package…" }
        static var copied: String { zh ? "已复制" : "Copied" }
        static var reindexFullText: String { zh ? "重新建立全文索引" : "Re-index Full Text" }
        static func reindexed(_ n: Int) -> String {
            zh ? "已为 \(n) 篇论文建立全文索引" : "Indexed the full text of \(n) paper\(n == 1 ? "" : "s")"
        }
        static var revealLibrary: String { zh ? "在 Finder 中显示论文库" : "Show the Library in Finder" }
        static var openMail: String { zh ? "打开邮件" : "Open Mail" }
        static var openFirstPaper: String { zh ? "打开一篇论文" : "Open a Paper" }
        static var showMenuBarMenu: String { zh ? "打开菜单栏菜单" : "Open the Menu-Bar Menu" }
        static var openSetup: String { zh ? "设置助手…" : "Setup Assistant…" }
        static var openTour: String { zh ? "功能导览" : "Feature Tour" }
        static var repairWidget: String { zh ? "修复小组件注册" : "Repair Widget Registration" }

        // Tour
        static var tourNext: String { zh ? "下一页" : "Next" }
        static var tourBack: String { zh ? "上一页" : "Back" }
        static var tourDone: String { zh ? "完成" : "Done" }
        static var tryIt: String { zh ? "试一试：" : "Try it:" }
        static var triedIt: String { zh ? "你已经试过了" : "You've tried it" }
        static func tourPage(_ i: Int, _ n: Int) -> String { zh ? "第 \(i)/\(n) 页" : "\(i) of \(n)" }
        static var tourUnavailable: String { zh ? "导览内容暂时不可用。" : "The tour isn't available yet." }

        // Troubleshooting
        static var troubleshootingSubtitle: String {
            zh ? "PaperDeck 会实时检查这台 Mac；标记「当前适用」的问题正在发生。"
               : "PaperDeck checks this Mac live; entries marked “Applies now” are happening right now."
        }

        // Diagnostics
        static var diagnosticsSubtitle: String {
            zh ? "复制的诊断信息不包含密码、论文标题或邮件内容；用户目录显示为 ~，邮箱地址会被遮盖。"
               : "Copied diagnostics never include passwords, paper titles or email contents; your home folder shows as ~ and email addresses are masked."
        }
        static var diagnosticsPreview: String { zh ? "诊断信息预览" : "Diagnostics Preview" }
        static var copy: String { zh ? "复制" : "Copy" }
        static var close: String { zh ? "关闭" : "Close" }
        static var refresh: String { zh ? "重新检查" : "Check Again" }
        static var dLibrary: String { zh ? "论文库" : "Library" }
        static var dPapers: String { zh ? "论文" : "Papers" }
        static var dAI: String { "AI" }
        static var dNotifications: String { zh ? "通知" : "Notifications" }
        static var dLogin: String { zh ? "登录时打开" : "Open at login" }
        static var dWidget: String { zh ? "小组件" : "Widget" }
        static var dApp: String { zh ? "应用位置" : "App location" }
        static var dSigning: String { zh ? "签名" : "Signing" }
        static var dMail: String { zh ? "邮件" : "Mail" }
        static var dConfig: String { zh ? "机构与领域" : "Institution & field" }
        // Diagnostics row details (the copied report keeps the raw values).
        static func dAIDetail(_ mode: AgentMode, _ provider: AIProviderKind) -> String {
            switch mode {
            case .off: return zh ? "AI 解读已关闭 · \(provider.shortName)" : "Reading off · \(provider.shortName)"
            case .mock: return zh ? "演示模式（mock）" : "Demo mode (mock)"
            case .claude, .codex:
                let name = mode.providerKind?.shortName ?? provider.shortName
                return zh ? "AI 解读已开启 · \(name)" : "Reading on · \(name)"
            }
        }
        static func dNotificationsDetail(_ a: NotificationFact.Authorization) -> String {
            switch a {
            case .authorized: return zh ? "已允许" : "Allowed"
            case .provisional: return zh ? "静默送达" : "Delivered quietly"
            case .denied: return zh ? "未允许" : "Not allowed"
            case .notDetermined: return zh ? "尚未询问" : "Not asked yet"
            case .unavailable: return zh ? "此版本不可用" : "Not available in this build"
            }
        }
        static func dLoginDetail(_ s: LoginItemFact.Status) -> String {
            switch s {
            case .enabled: return zh ? "已开启" : "On"
            case .notRegistered: return zh ? "未开启" : "Off"
            case .requiresApproval: return zh ? "需要在系统设置中批准" : "Needs approval in System Settings"
            case .notFound: return zh ? "此版本不可用" : "Not available in this build"
            }
        }
        static func dWidgetDetail(_ r: WidgetFact.Registration) -> String {
            switch r {
            case .registered: return zh ? "macOS 已识别" : "Known to macOS"
            case .disabled: return zh ? "已在系统设置中停用" : "Turned off in System Settings"
            case .notRegistered: return zh ? "macOS 尚未识别" : "Not known to macOS yet"
            case .failed: return zh ? "无法检查" : "Couldn't check"
            }
        }
        static func dAppDetail(_ l: AppLocationFact.Location) -> String {
            switch l {
            case .applications: return zh ? "「应用程序」文件夹" : "Applications folder"
            case .userApplications: return zh ? "个人的「应用程序」文件夹（~/Applications）" : "Your Applications folder (~/Applications)"
            case .translocated: return zh ? "从隔离位置运行（请移到「应用程序」）" : "Running from a quarantine location (move it to Applications)"
            case .other: return zh ? "其他文件夹" : "Another folder"
            }
        }
        static func dSigningDetail(_ k: SigningFact.Kind) -> String {
            switch k {
            case .certificate(let name): return zh ? "证书“\(name)”" : "Certificate “\(name)”"
            case .adhoc: return zh ? "临时签名（ad hoc）" : "Ad hoc"
            case .unsigned: return zh ? "未签名" : "Unsigned"
            }
        }
        static func dMailDetail(enabled: Bool, accounts n: Int) -> String {
            let state = enabled ? (zh ? "已开启" : "On") : (zh ? "已关闭" : "Off")
            let count = zh ? "\(n) 个账户" : (n == 1 ? "1 account" : "\(n) accounts")
            return "\(state) · \(count)"
        }
        static var dNoInstitution: String { zh ? "未指定机构" : "No specific institution" }

        // Menus
        static var helpMenu: String { zh ? "帮助" : "Help" }
        static var paperDeckHelp: String { zh ? "PaperDeck 帮助" : "PaperDeck Help" }
        static var gettingStartedMenu: String { zh ? "入门清单" : "Getting Started" }
        static var featureTourMenu: String { zh ? "功能导览" : "Feature Tour" }
        static var setupAssistantMenu: String { zh ? "设置助手…" : "Setup Assistant…" }
        static var troubleshootingMenu: String { zh ? "故障排查" : "Troubleshooting" }
        static var diagnosticsMenu: String { zh ? "诊断信息…" : "Diagnostics…" }
        static var helpAndSetup: String { zh ? "帮助与设置" : "Help & Setup" }
        static func gettingStartedCount(_ done: Int, _ total: Int) -> String {
            zh ? "入门清单（\(done)/\(total)）…" : "Getting Started (\(done) of \(total))…"
        }

        // Elsewhere in the app
        static var howToFix: String { zh ? "如何解决" : "How to Fix" }
        static var newHereTour: String { zh ? "第一次使用？看看功能导览" : "New here? Take the tour" }
    }
}
