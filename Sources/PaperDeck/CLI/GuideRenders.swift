import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// `--render OUT --root LIB --guide-only --scenario NAME`: every setup-window page (preflight and
/// live), the Help Center pages, the Getting Started card, the profile tab and the mail chooser —
/// with a scenario's canned facts (`FactScenario`), so nothing probes a CLI, the keychain or the
/// file system outside `--root`. A topic the catalog doesn't have yet is drawn from a short
/// stand-in (marked as such), so the layout can be reviewed before the content lands.
enum GuideRenders {
    static func render(state: AppState, defaults: UserDefaults, scenario: FactScenario, root: URL,
                       appearance: NSAppearance?, out: URL, suffix: String) async throws {
        func png(_ name: String) -> URL { out.appendingPathComponent("\(name)-\(suffix).png") }
        let settings = state.settings
        // The scenario's configuration origin, as `ConfigMigration` leaves it at launch (a new Mac:
        // fresh → generic institution, general field; an existing install: legacy), so the pages
        // show what that install would show; then the scenario's institution (wording only).
        let scenarioFacts = scenario.facts(home: root)
        if let origin = scenarioFacts.profile.origin {
            defaults.set(origin.rawValue, forKey: ConfigKeys.origin)
            settings.config.reload()
        }
        settings.config.organizationID = scenario.organization.id
        // The scenario's AI and mail decisions, which the setup window reads from the settings (not
        // the facts) — e.g. Finish is enabled once AI is on or "Not now" was chosen. The render
        // suite only; the engine's providers stay mocks and its agent queue isn't started.
        if let decision = scenarioFacts.ai.decision { defaults.set(decision, forKey: ConfigKeys.onboardingAIDecision) }
        if let decision = scenarioFacts.mail.decision { defaults.set(decision, forKey: ConfigKeys.onboardingMailDecision) }
        if scenarioFacts.ai.mode != .off { settings.agentMode = scenarioFacts.ai.mode.rawValue }
        let guide = GuideStore(defaults: defaults)
        let facts = SetupFactsCollector(settings: settings, guide: guide, sources: FakeFactSources(scenario: scenario, home: root),
                                        home: root)
        facts.fixed = scenario.facts(home: root)
        facts.state = state
        state.facts = facts
        let onboardingSize = NSSize(width: 820, height: 600)

        func onboarding(_ name: String, mode: OnboardingModel.Mode, page: OnboardingPage,
                        configure: (OnboardingModel) -> Void = { _ in }) async throws {
            // The preflight has no library yet.
            facts.state = mode == .preflight ? nil : state
            let model = OnboardingModel(settings: settings, guide: guide, facts: facts, mode: mode)
            model.go(page)
            configure(model)
            try await PreviewRenderer.captureView(OnboardingView(model: model).frame(width: onboardingSize.width, height: onboardingSize.height),
                                                  size: onboardingSize, appearance: appearance, png("onboarding-\(name)"))
        }

        try await onboarding("welcome", mode: .preflight, page: .welcome) { $0.pendingOpens = 1 }
        try await onboarding("about", mode: .preflight, page: .about)
        try await onboarding("ai", mode: .preflight, page: .ai) { $0.preselectAI() }
        try await onboarding("library", mode: .preflight, page: .library)
        try await onboarding("library-existing", mode: .preflight, page: .library) {
            $0.applyPicked(root.appendingPathComponent("PaperDeck", isDirectory: true),
                           kind: .existingLibrary(libraryID: "demo", cardCount: 42), existing: true)
        }
        try await onboarding("plan", mode: .live, page: .plan) { $0.preflightDone = true }
        try await onboarding("mail-router", mode: .live, page: .mail) { $0.mailStep = .routes }
        try await onboarding("mail-m365", mode: .live, page: .mail) {
            $0.chooseRoute(.m365)
            $0.answerM365(.yes)
        }
        try await onboarding("mail-senders", mode: .live, page: .mail) { $0.mailStep = .senders }
        try await onboarding("import", mode: .live, page: .importPapers)
        try await onboarding("finish", mode: .live, page: .finish) { $0.preflightDone = true }
        facts.state = state

        // Help Center pages (split views don't capture offscreen: each page alone).
        let runner = GuideActionRunner(settings: settings, state: state, openTopic: { _ in })
        let helpSize = NSSize(width: 660, height: 620)
        func help<V: View>(_ name: String, _ view: V) async throws {
            try await PreviewRenderer.captureView(ScrollView { view.padding(24) }.frame(width: helpSize.width, height: helpSize.height),
                                                  size: helpSize, appearance: appearance, png("help-\(name)"))
        }
        try await help("getting-started", GettingStartedView(facts: facts, runner: runner))
        try await help("tour-drop", TourView(facts: facts, runner: runner, topic: topic(.tour)))
        try await help("tutorial-m365", TutorialView(topic: topic(.mailM365PowerAutomate), facts: facts, runner: runner))
        try await help("tutorial-move-mac", TutorialView(topic: topic(.moveToNewMac), facts: facts, runner: runner))
        try await help("troubleshooting", TroubleshootingList(facts: facts, runner: runner, topics: troubleshooting()))
        try await help("diagnostics", DiagnosticsView(facts: facts, settings: settings))

        // Only where the app shows it (fresh installs; never the legacy scenario).
        if GettingStartedCard.isShown(facts) {
            try await PreviewRenderer.captureView(GettingStartedCard(facts: facts, runner: runner).frame(width: 712).padding(24),
                                                  size: nil, appearance: appearance, png("today-getting-started"))
        }
        try await PreviewRenderer.captureView(MailAddAccountSheet(state: state, editing: nil, onClose: {}),
                                              size: NSSize(width: 600, height: 700), appearance: appearance, png("mail-chooser"))
        // Settings ▸ Profile (the scenario's institution), General and Library, and — institution-neutral,
        // next to scratch cloud roots under `root` (a work tenant + a personal OneDrive) — the chooser,
        // the Power Automate form (the Contoso suggestion, never Personal) and the generic profile.
        try await MailRenders.portabilityPages(state: state, appearance: appearance, out: out, suffix: suffix, root: root)
        try await importSheet(root: root, appearance: appearance, out: png("transfer-import"))
        state.facts = nil
    }

    /// Import Settings… with a file from "another Mac" into a Mac that already has two senders and
    /// a mail account (a scratch domain under `root`): the sheet names what it adds, replaces and
    /// keeps (this Mac's account is kept) before Import, and — this Mac sorting mail by local rules
    /// only, the file with AI triage and a higher daily limit — lists those two under "Kept
    /// stricter", unticked. Nothing is imported; no file or cloud folder outside `root` is read.
    static func importSheet(root: URL, appearance: NSAppearance?, out: URL) async throws {
        let suite = root.appendingPathComponent("import-render-defaults").path
        guard let d = UserDefaults(suiteName: suite) else { return }
        // A second store mirrors its language and institution into LangStore: keep the render's.
        let lang = LangStore.shared
        let saved = (lang.lang, lang.provider, lang.org, lang.field, lang.importFolderExample)
        defer {
            (lang.lang, lang.provider, lang.org, lang.field, lang.importFolderExample) = saved
            d.removePersistentDomain(forName: suite)
        }
        d.set(saved.0.rawValue, forKey: "language")
        d.set(saved.2.id, forKey: ConfigKeys.orgPreset)
        let advisor = SenderRule(id: "render-advisor", pattern: "advisor@example.edu", label: "Prof. Example", kind: .advisor)
        let alert = SenderRule(id: "render-alert", pattern: "@alerts.example.org", label: "Example Alerts", kind: .alert)
        let here = MailAccount(id: "render-here", kind: .imap, displayName: "Lab Gmail", imapPreset: .gmail,
                               host: "imap.gmail.com", username: "lab@example.com")
        d.set(MailSettings.encode([advisor, alert]), forKey: MailSettings.Keys.senders)
        d.set(MailSettings.encode([here]), forKey: MailSettings.Keys.accounts)
        d.set(MailSettings.AIMode.heuristicOnly.rawValue, forKey: MailSettings.Keys.aiMode)
        let settings = SettingsStore(defaults: d, domain: suite)
        settings.onMailSettingsChange = { _ in }

        var changed = advisor
        changed.useDueDateAsDDL.toggle()        // replaced (automatic merge turned on would be kept stricter)
        let journal = SenderRule(id: "render-journal", pattern: "@journal.example.org", label: "Example Journal", kind: .alert)
        let there = MailAccount(id: "render-old-mac", kind: .imap, displayName: "Old Mac — iCloud", imapPreset: .icloud,
                                host: "imap.mail.me.com", username: "reader@example.com")
        var values = settings.persistedDomain.values
        values[MailSettings.Keys.senders] = MailSettings.encode([changed, alert, journal])
        values[MailSettings.Keys.accounts] = MailSettings.encode([there])
        values["reminder.hour"] = 8
        values[MailSettings.Keys.aiMode] = MailSettings.AIMode.ai.rawValue
        values[MailSettings.Keys.triageDailyMax] = 200
        let home = FileManager.default.temporaryDirectory
        let bundle = SettingsExporter.export(PersistedDomain(values), sections: Set(SettingsSection.allCases),
                                             includePersonal: false, home: home, roots: [], app: "PaperDeck 1.0 (27)",
                                             now: Date(timeIntervalSince1970: 1_790_000_000))
        try await PreviewRenderer.captureView(SettingsImportSheet(settings: settings, fileURL: nil, preloaded: (bundle, []),
                                                                  onClose: { _ in }),
                                              size: NSSize(width: 600, height: 640), appearance: appearance, out)
    }

    // MARK: Stand-ins (only while the catalog lacks a topic)

    static func topic(_ id: GuideTopicID) -> GuideTopic {
        GuideCatalog.topic(id) ?? standIns.first { $0.id == id } ?? GuideTopic(id: id, kind: .tutorial,
            title: LocalizedText(id.rawValue), summary: LocalizedText(""), lastReviewed: "—")
    }

    static func troubleshooting() -> [GuideTopic] {
        let real = GuideCatalog.topics.filter { $0.kind == .troubleshoot }
        return real.isEmpty ? standIns.filter { $0.kind == .troubleshoot } : real
    }

    private static let note = LocalizedText(en: "(Render stand-in — the Help content is not in this build.)",
                                            zh: "（渲染占位——这个版本还没有帮助内容。）")

    static let standIns: [GuideTopic] = [
        GuideTopic(id: .tour, kind: .tour, title: LocalizedText(en: "Feature tour", zh: "功能导览"), summary: note,
                   steps: [GuideStep(id: "tour-drop",
                                     text: LocalizedText(en: "Drop papers anywhere\nThe edge strip, the menu-bar icon, Finder ▸ Open With or the window.",
                                                         zh: "把论文拖到任何地方\n屏幕边缘的条、菜单栏图标、Finder ▸ 打开方式，或窗口。"),
                                     verification: .check(.activity([.panelDrop, .menuBarDrop, .openWith])),
                                     actions: [.router(.armDropPanel)])],
                   lastReviewed: "—"),
        GuideTopic(id: .mailM365PowerAutomate, kind: .tutorial,
                   title: LocalizedText(en: "Microsoft 365 with Power Automate", zh: "Microsoft 365 + Power Automate"), summary: note,
                   steps: [
                    GuideStep(id: "onedrive", text: LocalizedText(en: "Install OneDrive and sign in with your work or school account.",
                                                                  zh: "安装 OneDrive 并用学校或公司账户登录。"),
                              verification: .check(.oneDriveBusinessPresent)),
                    GuideStep(id: "folder", text: LocalizedText(en: "Create the **PaperDeck Mail** folder.", zh: "创建 **PaperDeck Mail** 文件夹。"),
                              verification: .check(.mailFolderExists)),
                    GuideStep(id: "flow", text: LocalizedText(en: "Build the flow (or import the package).", zh: "创建流程（或导入流程包）。"),
                              verification: .impliedBy(step: 5), actions: [.copyGenerated(.powerAutomatePackage)]),
                    GuideStep(id: "account", text: LocalizedText(en: "Add the folder as an account.", zh: "把文件夹添加为账户。"),
                              verification: .check(.mailAccountExists(.m365PowerAutomate)), actions: [.openMailSheet(.m365PowerAutomate)]),
                    GuideStep(id: "on", text: LocalizedText(en: "Turn on Mail.", zh: "开启邮件。"), verification: .check(.mailEnabled)),
                    GuideStep(id: "first", text: LocalizedText(en: "The first email file arrives.", zh: "收到第一封邮件文件。"),
                              verification: .check(.mailFirstCapture(.m365PowerAutomate))),
                   ], related: [.mailM365Blocked], lastReviewed: "—"),
        GuideTopic(id: .moveToNewMac, kind: .tutorial, title: LocalizedText(en: "Move to another Mac", zh: "迁移到另一台 Mac"),
                   summary: note,
                   steps: [
                    GuideStep(id: "old", text: LocalizedText(en: "On the old Mac: quit PaperDeck and copy the library folder.",
                                                             zh: "在旧 Mac 上：退出 PaperDeck 并拷贝论文库文件夹。"),
                              verification: .manual(reason: LocalizedText(en: "happens on the other Mac", zh: "在另一台 Mac 上完成"))),
                    GuideStep(id: "apps", text: LocalizedText(en: "Put PaperDeck in Applications and open it.", zh: "把 PaperDeck 放进「应用程序」并打开。"),
                              verification: .check(.appInApplications)),
                    GuideStep(id: "library", text: LocalizedText(en: "Use the existing library.", zh: "使用已有的论文库。"),
                              verification: .check(.libraryHasManifest)),
                    GuideStep(id: "passwords", text: LocalizedText(en: "Re-enter IMAP app passwords.", zh: "重新输入 IMAP 应用专用密码。"),
                              verification: .check(.imapPasswordsPresent)),
                   ], lastReviewed: "—"),
        GuideTopic(id: .fixDocumentsAccess, kind: .troubleshoot,
                   title: LocalizedText(en: "Can't use the library folder", zh: "无法使用论文库文件夹"), summary: note,
                   diagnosis: .documentsDenied, lastReviewed: "—"),
        GuideTopic(id: .fixMailAuthFailed, kind: .troubleshoot,
                   title: LocalizedText(en: "Mail account sign-in failed", zh: "邮件账户登录失败"), summary: note,
                   diagnosis: .mailAccountAuthFailed, lastReviewed: "—"),
    ]
}
