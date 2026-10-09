import AppKit
import PaperDeckCore
import PaperDeckConfig

/// `--selftest onboarding [--lang en|zh]`: the setup window's writes, gate and routes on scratch
/// defaults (a path domain under $TMPDIR, removed afterwards) with fake facts — offline: no CLI,
/// no keychain, no network, the user's settings never read or written; the one engine is a
/// scratch library with mock providers.
enum SelfTestOnboarding {
    static func run(_ a: CLIArgs) async -> Int32 {
        let lang = UILang(rawValue: a.value("--lang") ?? "en") ?? .en
        let previous = LangStore.shared.lang
        LangStore.shared.lang = lang
        defer { LangStore.shared.lang = previous }
        _ = NSApplication.shared

        let c = SelfTestAppRules.Checker()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-selftest-onboarding-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        gate(c)
        await quickStart(scratch, c)
        await normalPath(scratch, c)
        preselection(scratch, c)
        await liveAI(scratch, c)
        await mail(scratch, c)
        helpTopics(c)
        finishGating(scratch, c)
        revisit(scratch, c)
        strings(lang, c)
        await guideFacts(scratch, c)

        print(c.ok ? "SELFTEST PASS" : "SELFTEST FAIL")
        return c.ok ? 0 : 1
    }

    // MARK: Scratch domains

    /// A throwaway defaults domain (an absolute-path suite: nothing lands in ~/Library/Preferences).
    final class Scratch {
        let name: String
        let defaults: UserDefaults
        init(_ dir: URL, _ tag: String) {
            let d = dir.appendingPathComponent(tag, isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            name = d.appendingPathComponent("defaults").path
            defaults = UserDefaults(suiteName: name)!
        }
        var persisted: [String: Any] { defaults.persistentDomain(forName: name) ?? [:] }
        var keys: Set<String> { Set(persisted.keys) }
        func drop() {
            defaults.removePersistentDomain(forName: name)
            CFPreferencesAppSynchronize(name as CFString)
        }
    }

    /// A fresh install's model on `s` (the migration's `config.origin = fresh` first).
    static func model(_ s: Scratch, mode: OnboardingModel.Mode, scenario: FactScenario = .fresh,
                      home: URL) -> (OnboardingModel, SettingsStore) {
        s.defaults.set("fresh", forKey: ConfigKeys.origin)
        s.defaults.set(LangStore.shared.lang.rawValue, forKey: "language")       // the run's --lang
        let settings = SettingsStore(defaults: s.defaults)
        settings.onMailSettingsChange = { _ in }
        let guide = GuideStore(defaults: s.defaults)
        let facts = SetupFactsCollector(settings: settings, guide: guide, sources: FakeFactSources(scenario: scenario, home: home),
                                        home: home)
        facts.fixed = scenario.facts(home: home)
        return (OnboardingModel(settings: settings, guide: guide, facts: facts, mode: mode), settings)
    }

    // MARK: 1. Gate

    static func gate(_ c: SelfTestAppRules.Checker) {
        func g(_ v: [String: Any], db: Bool = false, root: Bool = false) -> Bool {
            OnboardingGate.needsPreflight(PersistedDomain(v), databaseExists: db, rootOverride: root)
        }
        let fresh: [String: Any] = [ConfigKeys.origin: "fresh"]
        c.check("gate: a fresh origin with nothing set up → preflight", g(fresh))
        c.check("gate: setup.completed → none", !g(fresh.merging(["setup.completed": false]) { a, _ in a }))
        c.check("gate: library.path → none", !g(fresh.merging(["library.path": "/tmp/x"]) { a, _ in a }))
        c.check("gate: a database → none", !g(fresh, db: true))
        c.check("gate: --gui-root → none", !g(fresh, root: true))
        c.check("gate: onboarding.legacy → none", !g(fresh.merging([ConfigKeys.onboardingLegacy: true]) { a, _ in a }))
        c.check("gate: a legacy origin → none", !g([ConfigKeys.origin: "legacy"]))
        // No origin written: the legacy detector decides (every install before this build is legacy).
        c.check("gate: no origin and a database → none", !g([:], db: true))
    }

    // MARK: 2. Quick Start

    static func quickStart(_ dir: URL, _ c: SelfTestAppRules.Checker) async {
        let s = Scratch(dir, "quick-start")
        defer { s.drop() }
        let (m, settings) = model(s, mode: .preflight, home: dir)
        var result: PreflightResult?
        m.onCommit = { result = $0 }
        let before = s.keys
        await m.runQuickStart(prepare: { _, _ in .ok })
        let written = s.keys.subtracting(before)
        let expected: Set<String> = ["library.path", ConfigKeys.profileField, ConfigKeys.orgPreset,
                                     ConfigKeys.onboardingAIDecision, ConfigKeys.onboardingMailDecision]
        c.check("quick start: writes exactly the expected keys", written == expected,
                ["written": written.sorted(), "expected": expected.sorted()])
        c.check("quick start: general field, generic institution, no AI, mail skipped, Documents library",
                s.defaults.string(forKey: ConfigKeys.profileField) == FieldPresets.general.id
                    && s.defaults.string(forKey: ConfigKeys.orgPreset) == OrganizationPresets.generic.id
                    && s.defaults.string(forKey: ConfigKeys.onboardingAIDecision) == "none"
                    && s.defaults.string(forKey: ConfigKeys.onboardingMailDecision) == "skipped"
                    && settings.libraryPath == OnboardingModel.documentsLibrary.path
                    && s.persisted["agent.mode"] == nil && s.persisted["mail.enabled"] == nil
                    && s.persisted["setup.completed"] == nil)
        c.check("quick start: the commit asks for Finish and a starter pack", result?.quickStart == true
                    && result?.existingLibrary == false && result?.starterPack?.isEmpty == false)
        m.didOpenLibrary()
        c.check("quick start: the window continues at Finish", m.page == .finish && m.mode == .live)
    }

    // MARK: 3. The normal path

    static func normalPath(_ dir: URL, _ c: SelfTestAppRules.Checker) async {
        let s = Scratch(dir, "normal")
        defer { s.drop() }
        let (m, _) = model(s, mode: .preflight, scenario: .allReady, home: dir)
        m.go(.about)
        m.next()
        c.check("preflight: About → AI", m.page == .ai)
        m.selectAI(.claude)
        m.turnOnAI()
        m.next()
        c.check("preflight: AI turned on → Library", m.page == .library)
        let held: [String] = ["library.path", "agent.mode", "agent.provider", ConfigKeys.onboardingAIDecision]
        c.check("preflight: nothing held back is written before the commit", held.allSatisfy { s.persisted[$0] == nil },
                ["keys": s.keys.sorted()])
        c.check("preflight: quitting now leaves the gate open",
                OnboardingGate.needsPreflight(PersistedDomain(s.persisted), databaseExists: false, rootOverride: false))
        // A denied folder: nothing written, the page says why.
        await m.commit(prepare: { _, _ in .denied })
        c.check("preflight: a denied folder writes nothing", m.libraryProblem == .denied && s.persisted["library.path"] == nil)
        var result: PreflightResult?
        m.onCommit = { result = $0 }
        await m.commit(prepare: { _, _ in .ok })
        c.check("preflight: the commit writes library.path, agent.* and the AI decision",
                s.persisted["library.path"] as? String == OnboardingModel.documentsLibrary.path
                    && s.persisted["agent.mode"] as? String == "claude" && s.persisted["agent.provider"] as? String == "claude"
                    && s.persisted[ConfigKeys.onboardingAIDecision] as? String == "claude"
                    && result?.existingLibrary == false && result?.quickStart == false)
        c.check("preflight: after the commit the gate is closed",
                !OnboardingGate.needsPreflight(PersistedDomain(s.persisted), databaseExists: false, rootOverride: false))
        // A relaunch: the stores the app creates at launch read the decisions and write nothing.
        let committed = s.persisted as NSDictionary
        let relaunched = GuideStore(defaults: s.defaults)
        _ = ConfigStore(defaults: s.defaults)
        c.check("relaunch: GuideStore / ConfigStore keep the decisions and write nothing at launch",
                relaunched.aiDecision == "claude" && (s.persisted as NSDictionary) == committed,
                ["aiDecision": relaunched.aiDecision ?? "nil"])
        // An existing library: no starter pack; a folder without one can't be committed.
        let s2 = Scratch(dir, "existing")
        defer { s2.drop() }
        let (m2, _) = model(s2, mode: .preflight, home: dir)
        var r2: PreflightResult?
        m2.onCommit = { r2 = $0 }
        m2.go(.library)
        m2.applyPicked(dir.appendingPathComponent("Empty"), kind: .empty, existing: true)
        await m2.commit(prepare: { _, _ in .ok })
        c.check("preflight: 'existing' on a folder without a library commits nothing", r2 == nil && s2.persisted["library.path"] == nil)
        m2.applyPicked(dir.appendingPathComponent("Lib"), kind: .existingLibrary(libraryID: "x", cardCount: 3), existing: true)
        await m2.commit(prepare: { _, _ in .ok })
        c.check("preflight: an existing library is indexed, without a starter pack",
                r2?.existingLibrary == true && r2?.starterPack == nil
                    && s2.persisted["library.path"] as? String == dir.appendingPathComponent("Lib").path)
        m2.applyPicked(dir, kind: .parentOfLibrary(child: dir.appendingPathComponent("PaperDeck"), cardCount: 2), existing: true)
        c.check("preflight: the parent of a library suggests the library", m2.libraryChoice == .existing(dir.appendingPathComponent("PaperDeck")))
    }

    // MARK: 4. AI preselection

    static func preselection(_ dir: URL, _ c: SelfTestAppRules.Checker) {
        let ready = ProviderStatus.ready(plan: "max", version: "1", path: "/x")
        let table: [(ProviderStatus, ProviderStatus, OnboardingRules.AIChoice)] = [
            (ready, ready, .claude), (.notInstalled, ready, .codex), (ready, .notInstalled, .claude),
            (.notLoggedIn("logged_out"), .notInstalled, .claude), (.notInstalled, .notLoggedIn("logged_out"), .codex),
            (.notLoggedIn("logged_out"), .notLoggedIn("logged_out"), .claude), (.notInstalled, .notInstalled, .none),
        ]
        for (claude, codex, want) in table {
            let got = OnboardingRules.preselect(claude: .value(claude), codex: .value(codex))
            c.check("preselect: \(claude) / \(codex) → \(want.rawValue)", got == want)
        }
        c.check("preselect: nothing while a provider is still checked",
                OnboardingRules.preselect(claude: .checking, codex: .value(ready)) == nil
                    && OnboardingRules.preselect(claude: nil, codex: .value(ready)) == nil)
        for (scenario, want) in [(FactScenario.codexOnly, OnboardingRules.AIChoice.codex), (.noAI, .none), (.allReady, .claude)] {
            let s = Scratch(dir, "preselect-\(scenario.rawValue)")
            let (m, _) = model(s, mode: .preflight, scenario: scenario, home: dir)
            m.preselectAI()
            c.check("preselect: scenario \(scenario.rawValue) → \(want.rawValue), nothing written",
                    m.aiChoice == want && s.persisted["agent.provider"] == nil && s.persisted["agent.mode"] == nil)
            s.drop()
        }
    }

    // MARK: 5. Live mode: selecting never turns AI on; Turn On does

    static func liveAI(_ dir: URL, _ c: SelfTestAppRules.Checker) async {
        let s = Scratch(dir, "live-ai")
        defer { s.drop() }
        let root = dir.appendingPathComponent("live-library", isDirectory: true)
        let (m, settings) = model(s, mode: .live, scenario: .allReady, home: dir)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine: Engine
        do {
            engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: SelfTestAppRules.deps())
        } catch {
            c.check("live: a scratch engine opens", false, ["error": String(describing: type(of: error))])
            return
        }
        let state = AppState(engine: engine, settings: settings, guide: m.guide)
        m.facts.state = state
        m.selectAI(.codex)
        try? await Task.sleep(for: .milliseconds(50))
        c.check("live: selecting ChatGPT sets the provider only",
                settings.agentProvider == .codex && settings.agentMode == "off" && s.persisted["agent.mode"] == nil)
        m.turnOnAI()
        c.check("live: Turn On writes agent.mode and the decision",
                s.persisted["agent.mode"] as? String == "codex" && m.guide.aiDecision == "codex")
        m.selectAI(.none)
        c.check("live: Not now turns reading off and records it",
                settings.agentMode == "off" && m.guide.aiDecision == "none")
        await engine.shutdown()
        await engine.db.close()
    }

    // MARK: 6. Mail

    static func mail(_ dir: URL, _ c: SelfTestAppRules.Checker) async {
        for route in OnboardingRules.MailRoute.allCases {
            for answer in route == .m365 ? OnboardingRules.M365Answer.allCases.map(Optional.some) : [nil] {
                let t = OnboardingRules.target(route, m365: answer)
                let opens = t.source.map { MailAccountTemplate(source: $0) != nil } ?? true
                c.check("mail: route \(route.rawValue)\(answer.map { "/" + $0.rawValue } ?? "") → a topic and a form",
                        GuideTopicID.catalog.contains(t.topic) && opens)
            }
        }
        c.check("mail: blocked Microsoft 365 and Outlook.com are guide-only",
                OnboardingRules.target(.m365, m365: .blocked).source == nil && OnboardingRules.target(.outlookCom).source == nil)

        let s = Scratch(dir, "mail")
        defer { s.drop() }
        let (m, settings) = model(s, mode: .live, home: dir)
        m.go(.mail)
        m.turnOnMail()
        c.check("mail: Turn On Mail needs a saved account", !settings.mailEnabled && s.persisted["mail.enabled"] == nil)
        let suggested = SenderPresetCatalog.suggested(for: settings.config.snapshot.field)
        c.check("mail: alert presets start unchecked", !suggested.isEmpty && suggested.allSatisfy { !m.presetEnabled($0.id) })
        m.advisorAddress = "advisor@example.edu"
        let added = m.addAdvisor()
        let rule = settings.mailSenders.first { $0.pattern == "advisor@example.edu" }
        c.check("mail: a person sender keeps the organization's people default (never always)",
                added && rule?.kind == .advisor && rule?.aiPolicy == settings.config.snapshot.organization.peopleDefault.policy
                    && rule?.aiPolicy != .always)
        m.chooseMail(.dragOnly)
        c.check("mail: drag only records the decision and shows the senders", m.guide.mailDecision == "dragOnly" && m.mailStep == .senders)
        m.next()
        c.check("mail: Continue keeps a decision", m.guide.mailDecision == "dragOnly" && m.page == .importPapers)
        c.check("mail: still never turned on", s.persisted["mail.enabled"] == nil)
    }

    // MARK: 7. Help topics used by the views

    static func helpTopics(_ c: SelfTestAppRules.Checker) {
        let ids = Set(GuideTopicID.catalog)
        let missing = HelpCenter.topicsUsedInViews.filter { !ids.contains($0) }
        c.check("help: every topic a view links to is a catalog id", missing.isEmpty, ["missing": missing.map(\.rawValue)])
        let pages = OnboardingPage.allCases.map(\.helpTopic).filter { !ids.contains($0) }
        c.check("help: every setup page's (?) topic is a catalog id", pages.isEmpty)
        if !GuideCatalog.topics.isEmpty {
            let noContent = (HelpCenter.topicsUsedInViews + OnboardingPage.allCases.map(\.helpTopic))
                .filter { GuideCatalog.topic($0) == nil }
            c.check("help: every linked topic has content", noContent.isEmpty, ["missing": noContent.map(\.rawValue)])
        }
        let routes = GettingStarted.allIDs.compactMap(GettingStarted.topic).filter { !ids.contains($0) }
        c.check("help: every checklist row's topic is a catalog id", routes.isEmpty)
    }

    // MARK: 8. Finish

    static func finishGating(_ dir: URL, _ c: SelfTestAppRules.Checker) {
        for (usable, decided) in [(true, true), (true, false), (false, true), (false, false)] {
            c.check("finish: usable \(usable) · decided \(decided)",
                    OnboardingRules.canFinish(libraryUsable: usable, aiDecided: decided) == (usable && decided))
        }
        let s = Scratch(dir, "finish")
        defer { s.drop() }
        let (m, settings) = model(s, mode: .live, home: dir)
        m.go(.finish)
        m.finish(.close)
        c.check("finish: no AI decision → not finished", !settings.setupCompleted && s.persisted["setup.completed"] == nil)
        m.guide.aiDecision = "none"
        var closed = false
        m.onFinish = { _ in closed = true }
        m.showChecklistOnToday = false
        m.finish(.close)
        c.check("finish: writes setup.completed, onboarding.version and the checklist choice",
                closed && s.persisted["setup.completed"] as? Bool == true
                    && (s.persisted[ConfigKeys.onboardingVersion] as? NSNumber)?.intValue == 1
                    && s.persisted[ConfigKeys.onboardingCompletedAt] != nil
                    && s.persisted[ConfigKeys.guideChecklistDismissed] as? Bool == true)
    }

    // MARK: 9. Revisit

    static func revisit(_ dir: URL, _ c: SelfTestAppRules.Checker) {
        let s = Scratch(dir, "revisit")
        defer { s.drop() }
        s.defaults.set(true, forKey: "setup.completed")
        let (m, _) = model(s, mode: .revisit, home: dir)
        let before = s.persisted["library.path"]
        for p in OnboardingPage.allCases where p != .finish && p != .mail {
            m.go(p)
            m.next()
        }
        c.check("revisit: every page is reachable", OnboardingPage.allCases.allSatisfy(m.canJump))
        c.check("revisit: walking the pages never writes library.path", before == nil && s.persisted["library.path"] == nil)
        m.go(.mail)
        m.next()
        m.go(.mail)
        m.skip()
        c.check("revisit: Continue / Skip record no decision",
                s.persisted[ConfigKeys.onboardingMailDecision] == nil && s.persisted[ConfigKeys.onboardingAIDecision] == nil
                    && s.persisted["agent.mode"] == nil)
    }

    // MARK: 10. Strings

    static func strings(_ lang: UILang, _ c: SelfTestAppRules.Checker) {
        let texts = OnboardingPage.allCases.map(L.Onb.page) + [L.Onb.welcomeTitle, L.Onb.aiTitle, L.Onb.libraryTitle,
                                                                L.Help.windowTitle, L.Help.gettingStarted, L.Help.howToFix]
        c.check("strings: setup and help chrome are present in \(lang.rawValue)", texts.allSatisfy { !$0.isEmpty })
        // The built-in preset's names come from the preset itself (no institution literal here).
        let generic = OrgStrings.aiPolicyLine(org: OrganizationPresets.generic, lang: lang)
        let names = OrganizationPresets.builtIn.filter { $0.id != OrganizationPresets.generic.id }
            .flatMap { [$0.shortName, $0.name?.en].compactMap { $0 } }
        c.check("strings: the generic AI policy line names no institution",
                !names.isEmpty && names.allSatisfy { !generic.localizedCaseInsensitiveContains($0) })
    }
}
