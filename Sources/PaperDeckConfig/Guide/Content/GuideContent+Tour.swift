import Foundation
import PaperDeckCore

extension GuideContent {
    /// Getting started: the checklist, the feature tour and the diagnostics page.
    package static var tour: [GuideTopic] { tourTopics }

    private static let tourTopics: [GuideTopic] = [gettingStarted, featureTour, diagnostics]

    // MARK: getting-started

    /// The Getting Started checklist as a page (the live checklist itself is `GettingStarted`;
    /// the step ids are its item ids).
    private static let gettingStarted = GuideTopic(
        id: .gettingStarted, kind: .checklist,
        title: t("Getting started", "入门清单"),
        summary: t("The few things that make PaperDeck useful from day one. Each item ticks itself when PaperDeck sees it done on this Mac.",
                   "让 PaperDeck 从第一天起就好用的几件事。PaperDeck 在这台 Mac 上看到某项已完成时会自动打勾。"),
        keywords: [t("checklist", "清单"), t("first steps", "第一步"), t("setup", "设置"), t("start", "开始")],
        steps: [
            GuideStep(id: "library",
                      text: t("Your library folder is ready. PaperDeck keeps every paper in a normal folder (default Documents/PaperDeck).",
                              "论文库文件夹已就绪。PaperDeck 把每篇论文都放在一个普通文件夹里（默认「文稿/PaperDeck」）。"),
                      verification: .check(.libraryUsable),
                      actions: [.openSettings(tab: "library"), .openTopic(.libraryLocation)]),
            GuideStep(id: "first-paper",
                      text: t("Add your first paper: choose a PDF, or drag one onto the strip at the edge of your screen.",
                              "添加第一篇论文：选择一个 PDF，或把它拖到屏幕边缘的竖条上。"),
                      verification: .check(.hasPapers(1)),
                      actions: [.router(.pickAndImportFiles), .router(.armDropPanel)]),
            GuideStep(id: "drop-strip",
                      text: t("Drop a PDF on the edge strip or the menu-bar icon — they work from any app.",
                              "把 PDF 拖到边缘竖条或菜单栏图标上——在任何应用里都可以。"),
                      verification: .check(.activity([.panelDrop, .menuBarDrop])),
                      actions: [.router(.armDropPanel)]),
            GuideStep(id: "open-card",
                      text: t("Open a paper's reading card: the summary, the checklist and the deadline in one place.",
                              "打开一篇论文的阅读卡片：总结、阅读清单和截止日期都在一处。"),
                      verification: .check(.openedPaper),
                      actions: [.router(.showToday)]),
            GuideStep(id: "ai",
                      text: t("Choose AI reading — Claude or ChatGPT with your own subscription — or decide to go without.",
                              "选择 AI 解读——用你自己的 Claude 或 ChatGPT 订阅——或者决定暂不使用。"),
                      verification: .check(.aiDecided),
                      actions: [.openSettings(tab: "ai"), .openTopic(.aiSetup)]),
            GuideStep(id: "reminder",
                      text: t("Allow the daily reminder: one notification a day (11:00 by default) with what to read next.",
                              "允许每日提醒：每天一条通知（默认 11:00），告诉你接下来读什么。"),
                      verification: .check(.notificationsAllowed),
                      actions: [.systemSettings(.notifications), .openTopic(.fixNotifications)]),
            GuideStep(id: "login",
                      text: t("Open PaperDeck at login, so the menu-bar icon and the edge strip are always there.",
                              "登录时打开 PaperDeck，让菜单栏图标和边缘竖条一直都在。"),
                      verification: .check(.launchAtLogin),
                      actions: [.openSettings(tab: "general"), .openTopic(.fixLoginItem)]),
            GuideStep(id: "widget",
                      text: t("Add the desktop widget: right-click the desktop ▸ Edit Widgets… ▸ search for PaperDeck.",
                              "添加桌面小组件：在桌面上右键 ▸ 编辑小组件… ▸ 搜索 PaperDeck。"),
                      verification: .check(.widgetPlaced),
                      actions: [.openSettings(tab: "widget"), .openTopic(.fixWidgetMissing)]),
            GuideStep(id: "mail",
                      text: t("Optional: connect your mail, so reading requests and paper alerts become cards.",
                              "可选：连接邮件，让阅读请求和论文提醒变成卡片。"),
                      verification: .check(.mailAccountReady(nil)),
                      actions: [.openTopic(.connectMail)]),
            GuideStep(id: "senders",
                      text: t("Tell PaperDeck who sends you papers: your advisor, colleagues and alert services.",
                              "告诉 PaperDeck 谁会给你发论文：导师、同事和论文提醒服务。"),
                      verification: .check(.sendersAdded(nil)),
                      actions: [.openSettings(tab: "mail"), .openTopic(.mailSendersAndAI)]),
            GuideStep(id: "backup",
                      text: t("Keep a settings backup: export your settings once you've set things up — handy for a new Mac.",
                              "保留一份设置备份：设置好之后导出一次——换新 Mac 时用得上。"),
                      verification: .check(.settingsExported),
                      actions: [.router(.exportSettings), .openTopic(.moveToNewMac)]),
        ],
        related: [.tour, .connectMail, .aiSetup, .libraryLocation],
        lastReviewed: reviewed)

    // MARK: tour

    /// The 1-minute feature tour: one step per page ("Title\nBody"), the "Try it" check, and
    /// [Show Me] as the first action. The step ids pick the page's illustration.
    private static let featureTour = GuideTopic(
        id: .tour, kind: .tour,
        title: t("Feature tour", "功能导览"),
        summary: t("PaperDeck in one minute: seven short pages, each with a Show Me button that points at the real thing.",
                   "一分钟了解 PaperDeck：七个短页面，每页都有「演示给我看」按钮，直接指向真实的界面。"),
        keywords: [t("tour", "导览"), t("introduction", "介绍"), t("what can it do", "能做什么"), t("overview", "概览")],
        steps: [
            GuideStep(id: "tour-drop",
                      text: t("Drop papers anywhere\nDrag a PDF onto the thin strip at the edge of your screen, onto the menu-bar icon or into the window — or use Finder ▸ Open With ▸ PaperDeck. PaperDeck copies it into your library and starts its reading card.",
                              "把论文拖到任何地方\n把 PDF 拖到屏幕边缘的细竖条、菜单栏图标或主窗口里，或者在 Finder 中选「打开方式 ▸ PaperDeck」。PaperDeck 会把它复制进论文库，并开始生成阅读卡片。"),
                      verification: .check(.activity([.panelDrop, .menuBarDrop, .openWith])),
                      actions: [.router(.armDropPanel)]),
            GuideStep(id: "tour-today",
                      text: t("Today and your reading plan\nToday shows what to read next within your daily reading budget, papers with deadlines first. Busy day? Skip Today moves today's plan by a day.",
                              "今天与阅读计划\n「今天」列出在每日阅读量之内接下来要读的论文，有截止日期的排在前面。今天太忙？「今天跳过」会把今天的计划顺延一天。"),
                      verification: .check(.hasPapers(1)),
                      actions: [.router(.showToday)]),
            GuideStep(id: "tour-card",
                      text: t("Reading card and checklist\nEvery paper gets a card: a short summary, a reading checklist with minutes per step, tags and a deadline. Press ⌘I to show it next to the paper; tick steps off as you read.",
                              "阅读卡片与清单\n每篇论文都有一张卡片：简短总结、每步标好分钟数的阅读清单、标签和截止日期。按 ⌘I 在论文旁边显示卡片，边读边勾掉步骤。"),
                      verification: .check(.activity([.openedDetail])),
                      actions: [.router(.openFirstPaper)]),
            GuideStep(id: "tour-ai",
                      text: t("AI reading on your own subscription\nWith Claude or ChatGPT turned on, PaperDeck sends a paper's text to your own subscription to write the TL;DR, summary, category and tags — never with an API key. Nothing is sent and no quota is used until you turn it on.",
                              "用你自己的订阅做 AI 解读\n打开 Claude 或 ChatGPT 后，PaperDeck 会把论文文本发给你自己的订阅，生成 TL;DR、总结、分类和标签——从不使用 API key。在你打开之前，不会发送任何内容，也不消耗额度。"),
                      verification: .check(.aiDecided),
                      actions: [.openSettings(tab: "ai")]),
            GuideStep(id: "tour-mail",
                      text: t("Mail: requests become cards\nConnect your mail and emails from senders you list — an advisor's “please read this”, a journal alert — become cards in Mail. Merge a paper into your library with one click. People's emails are never sent to AI without asking you.",
                              "邮件：请求变成卡片\n连接邮件后，你列出的发件人发来的邮件——导师的「请读一下这篇」、期刊提醒——会在「邮件」里变成卡片，一键把论文合并进论文库。个人发来的邮件不经你同意绝不会发给 AI。"),
                      verification: .check(.mailAccountReady(nil)),
                      actions: [.router(.showMail)]),
            GuideStep(id: "tour-reminders",
                      text: t("Reminder and widget\nOne notification a day (11:00 by default — change it in Settings ▸ Plan & Reminders) and a desktop widget show what's next, without opening the app.",
                              "提醒与小组件\n每天一条通知（默认 11:00，可在「设置 ▸ 阅读计划与提醒」中修改），加上桌面小组件，不用打开应用就知道接下来读什么。"),
                      verification: .check(.notificationsAllowed),
                      actions: [.openSettings(tab: "widget")]),
            GuideStep(id: "tour-data",
                      text: t("Your data is a plain folder\nEach paper is a folder with its PDF, a card.json and your notes, so the library is yours: back it up, move it, or open it on another Mac. PaperDeck can always rebuild its index from these folders.",
                              "你的数据就是一个普通文件夹\n每篇论文是一个文件夹，里面有 PDF、card.json 和你的笔记，所以论文库完全属于你：可以备份、移动，或在另一台 Mac 上打开。PaperDeck 随时可以从这些文件夹重建索引。"),
                      verification: .check(.libraryUsable),
                      actions: [.router(.revealLibrary)]),
        ],
        related: [.gettingStarted, .aiSetup, .connectMail, .libraryLocation],
        lastReviewed: reviewed)

    // MARK: diagnostics

    private static let diagnostics = GuideTopic(
        id: .diagnostics, kind: .reference,
        title: t("Diagnostics", "诊断信息"),
        summary: t("What Help ▸ Diagnostics… shows and copies — useful when you ask someone for help. It never includes paper titles, email subjects or passwords.",
                   "「帮助 ▸ 诊断信息…」显示和复制的内容——向别人求助时很有用。其中从不包含论文标题、邮件主题或密码。"),
        keywords: [t("diagnostics", "诊断"), t("support", "求助"), t("report a problem", "报告问题"), t("version", "版本")],
        steps: [
            GuideStep(id: "what",
                      text: t("Diagnostics lists this Mac's setup: version and build, bundle id, where the app runs from, signing, the library's location and status, paper counts, both AI services' status (checked without using quota), notifications, Open at Login, the widget, mail accounts and the configuration (institution preset, field, date order).",
                              "诊断信息列出这台 Mac 的设置情况：版本与构建号、bundle id、应用的运行位置、签名、论文库的位置与状态、论文数量、两个 AI 服务的状态（检测不消耗额度）、通知、登录时打开、小组件、邮件账户，以及配置（机构预设、研究领域、日期顺序）。")),
            GuideStep(id: "redacted",
                      text: t("Copy Diagnostics… shows exactly what will be copied first. Your home folder becomes ~, email addresses are masked (j***@example.edu), and paper titles, email subjects and passwords are never included.",
                              "「复制诊断信息…」会先显示将要复制的全部内容。个人文件夹显示为 ~，邮箱地址会被遮盖（j***@example.edu），论文标题、邮件主题和密码从不包含在内。")),
            GuideStep(id: "terminal",
                      text: t("In Terminal, the app prints similar facts without opening a window: --config (institution, field, identity) and --doctor --mail-only (mail accounts). Neither uses AI quota.",
                              "在「终端」里，应用无需打开窗口也能打印类似信息：--config（机构、领域、身份）和 --doctor --mail-only（邮件账户）。两者都不消耗 AI 额度。"),
                      commands: [appBinary + " --config", appBinary + " --doctor --mail-only"]),
        ],
        related: [.gettingStarted, .fixAppBlocked],
        lastReviewed: reviewed)
}
