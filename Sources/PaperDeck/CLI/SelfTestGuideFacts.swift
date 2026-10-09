import AppKit
import PaperDeckCore
import PaperDeckConfig

/// Part of `--selftest onboarding`: the guides' live facts and what they cost an existing install
/// (scratch defaults and a scratch library; fake fact sources; no CLI, no keychain, no network):
/// - the full-text check is `.unknown` until the engine has counted, then the real count;
/// - Diagnostics rows are worded in the UI language (no raw value), both languages;
/// - the widget probe's callback-or-timeout returns even when the callback never comes;
/// - a legacy (or dismissed) Today never composes the guide facts;
/// - a legacy install records first uses only while a guide view is open — also through the app's
///   own path (`GuideActivity.install` + `GuideActivity.record`, what the views call), and a store
///   installed without its policy records nothing (fail closed).
extension SelfTestOnboarding {
    static func guideFacts(_ dir: URL, _ c: SelfTestAppRules.Checker) async {
        await fullText(dir, c)
        diagnosticsWording(dir, c)
        await probeTimeout(c)
        legacyToday(dir, c)
        activityPolicy(dir, c)
    }

    // MARK: Full text (F2)

    static func fullText(_ dir: URL, _ c: SelfTestAppRules.Checker) async {
        let pure = SetupFactsCollector.paperCounts([], fullTextMissing: nil)
        c.check("full text: no count from the engine → the paper facts are unknown", pure == .unknown)
        c.check("full text: an unknown count is never shown as done",
                GuideEvaluator.evaluate(.fullTextIncomplete, SetupFacts(papers: pure)) == .unknown)

        let s = Scratch(dir, "full-text")
        defer { s.drop() }
        s.defaults.set("fresh", forKey: ConfigKeys.origin)
        let settings = SettingsStore(defaults: s.defaults)
        settings.onMailSettingsChange = { _ in }
        let guide = GuideStore(defaults: s.defaults)
        let root = dir.appendingPathComponent("full-text-library", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine: Engine
        do {
            engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: SelfTestAppRules.deps())
        } catch {
            c.check("full text: a scratch engine opens", false, ["error": String(describing: type(of: error))])
            return
        }
        // One live paper without a full-text row (what a library rebuilt on a new Mac looks like).
        let inserted = (try? await engine.db.insertPaper(Paper(sha256: String(repeating: "f", count: 64), fileSize: 10,
                                                               title: "No text yet", folder: "Papers/no-text",
                                                               pdfName: "p.pdf", originalName: "p.pdf"))) != nil
        let state = AppState(engine: engine, settings: settings, guide: guide)
        state.scheduleRefresh(delay: .zero)
        for _ in 0..<60 where state.snapshot?.rows.count != 1 { try? await Task.sleep(for: .milliseconds(50)) }
        let facts = SetupFactsCollector(settings: settings, guide: guide, sources: FakeFactSources(scenario: .fresh, home: dir),
                                        home: dir)
        facts.state = state
        c.check("full text: before the count the step is not ticked (snapshot loaded)",
                inserted && state.snapshot?.rows.count == 1 && facts.facts.papers == .unknown
                    && GuideEvaluator.evaluate(.fullTextIncomplete, facts.facts) == .unknown,
                ["rows": state.snapshot?.rows.count])
        await facts.refresh(slow: true, providers: false)
        let after = GuideEvaluator.evaluate(.fullTextIncomplete, facts.facts)
        let isProblem: Bool = { if case .problem = after { return true }; return false }()
        c.check("full text: the slow refresh counts through the engine — 1 of 1 paper without full text",
                isProblem && facts.fullTextMissing == 1 && facts.facts.papers.known?.live == 1
                    && facts.facts.papers.known?.fullTextIndexed == 0,
                ["missing": facts.fullTextMissing, "state": String(describing: after)])
        c.check("full text: the other paper facts come with the count",
                GuideEvaluator.evaluate(.hasPapers(1), facts.facts) == .done)
        await engine.shutdown()
        await engine.db.close()
    }

    // MARK: Diagnostics wording (F5)

    /// The raw values the facts carry (`rawValue`s and the generic organization's id): none of them
    /// may be what a Diagnostics row shows.
    static let rawDiagnosticsValues: [String] = {
        var raw: [String] = ["off", "on", "mock", "claude", "codex", OrganizationPresets.generic.id]
        raw += ["notDetermined", "denied", "authorized", "provisional", "unavailable"]
        raw += ["enabled", "notRegistered", "requiresApproval", "notFound"]
        raw += ["registered", "disabled", "failed"]
        raw += ["applications", "userApplications", "translocated", "other"]
        raw += ["adhoc", "unsigned", "certificate"]
        return raw
    }()

    static func diagnosticsWording(_ dir: URL, _ c: SelfTestAppRules.Checker) {
        let store = LangStore.shared
        let saved = store.lang
        defer { store.lang = saved }
        let generic = ConfigSnapshot(migrationVersion: 1, origin: .fresh, field: FieldPresets.general, stage: .phd,
                                     readerOverride: nil, organization: OrganizationPresets.generic, mailDateOrder: .auto)
        var details: [UILang: [String]] = [:]
        for lang in UILang.allCases {
            store.lang = lang
            var leaks: [String] = []
            for scenario in FactScenario.allCases {
                var f = scenario.facts(home: dir)
                let rows = DiagnosticsRows.rows(f, config: generic)
                for r in rows where showsRawValue(r.detail) { leaks.append("\(scenario.rawValue)/\(r.title): \(r.detail)") }
                details[lang, default: []] += rows.map(\.detail)
                // Every case of each fact once, so no value hides behind a scenario that doesn't use it.
                for a in [NotificationFact.Authorization.notDetermined, .denied, .authorized, .provisional, .unavailable] {
                    f.notifications = .value(NotificationFact(authorization: a, reminderEnabled: true))
                    if let d = DiagnosticsRows.rows(f, config: generic).first(where: { $0.title == L.Help.dNotifications })?.detail,
                       showsRawValue(d) { leaks.append("notifications: \(d)") }
                }
                for st in [LoginItemFact.Status.enabled, .notRegistered, .requiresApproval, .notFound] {
                    f.loginItem = .value(LoginItemFact(status: st))
                    if let d = DiagnosticsRows.rows(f, config: generic).first(where: { $0.title == L.Help.dLogin })?.detail,
                       showsRawValue(d) { leaks.append("login: \(d)") }
                }
                for reg in [WidgetFact.Registration.registered, .disabled, .notRegistered, .failed] {
                    f.widget = .value(WidgetFact(registration: reg))
                    if let d = DiagnosticsRows.rows(f, config: generic).first(where: { $0.title == L.Help.dWidget })?.detail,
                       showsRawValue(d) { leaks.append("widget: \(d)") }
                }
                for loc in [AppLocationFact.Location.applications, .userApplications, .translocated, .other] {
                    f.app = .value(AppLocationFact(location: loc, quarantined: false))
                    if let d = DiagnosticsRows.rows(f, config: generic).first(where: { $0.title == L.Help.dApp })?.detail,
                       showsRawValue(d) { leaks.append("app: \(d)") }
                }
                for kind in [SigningFact.Kind.adhoc, .unsigned, .certificate("X")] {
                    f.signing = .value(SigningFact(kind: kind, channel: .local))
                    if let d = DiagnosticsRows.rows(f, config: generic).first(where: { $0.title == L.Help.dSigning })?.detail,
                       showsRawValue(d) { leaks.append("signing: \(d)") }
                }
                for mode in [AgentMode.off, .mock, .claude, .codex] {
                    f.ai.mode = mode
                    if let d = DiagnosticsRows.rows(f, config: generic).first(where: { $0.title == L.Help.dAI })?.detail,
                       showsRawValue(d) { leaks.append("ai: \(d)") }
                }
            }
            c.check("diagnostics (\(lang.rawValue)): every row is worded, no raw value shown", leaks.isEmpty, ["leaks": leaks])
        }
        // The worded rows differ between the languages (the library path and counts aside).
        let en = details[.en] ?? [], zh = details[.zh] ?? []
        let worded = zip(en, zh).filter { a, _ in !a.isEmpty && !a.hasPrefix("~") && Int(a) == nil }
        c.check("diagnostics: the worded rows are translated", !worded.isEmpty && worded.allSatisfy { $0 != $1 },
                ["same": worded.filter { $0 == $1 }.map(\.0)])
    }

    /// Whether `detail` shows a raw value: the whole detail, its first or last " · " part, or the
    /// generic organization's id anywhere.
    private static func showsRawValue(_ detail: String) -> Bool {
        let parts = detail.components(separatedBy: " · ")
        if parts.contains(where: { rawDiagnosticsValues.contains($0) }) { return true }
        return detail.range(of: OrganizationPresets.generic.id) != nil
    }

    // MARK: Widget probe (F7)

    @MainActor final class ProbeBox { var answer: Int? = -1; var done = false }

    static func probeTimeout(_ c: SelfTestAppRules.Checker) async {
        // A callback that never comes: the answer is nil once the timeout passes.
        let silent = ProbeBox()
        let started = Date()
        Task {
            let answer: Int? = await LiveFactSources.firstAnswer(timeout: .milliseconds(200)) { (_: @escaping @Sendable (Int?) -> Void) in }
            silent.answer = answer
            silent.done = true
        }
        for _ in 0..<40 where !silent.done { try? await Task.sleep(for: .milliseconds(50)) }
        let elapsed = Date().timeIntervalSince(started)
        c.check("widget probe: a callback that never comes can't stall it (nil after the timeout)",
                silent.done && silent.answer == nil && elapsed < 1.9,
                ["elapsed": elapsed, "done": silent.done, "answer": silent.answer.map(String.init) ?? "nil"])
        // The callback first: its answer.
        let quick = await LiveFactSources.firstAnswer(timeout: .seconds(5)) { (answer: @escaping @Sendable (Int?) -> Void) in answer(3) }
        c.check("widget probe: the callback's answer when it comes first", quick == 3)
        // A late, repeated callback after the timeout: ignored (resumed once — no crash).
        let late = await LiveFactSources.firstAnswer(timeout: .milliseconds(50)) { (answer: @escaping @Sendable (Int?) -> Void) in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { answer(1); answer(2) }
        }
        try? await Task.sleep(for: .milliseconds(400))
        c.check("widget probe: a late or repeated callback is ignored", late == nil)
    }

    // MARK: Today on a legacy install (F8)

    static func legacyToday(_ dir: URL, _ c: SelfTestAppRules.Checker) {
        func collector(_ s: Scratch, origin: String) -> SetupFactsCollector {
            s.defaults.set(origin, forKey: ConfigKeys.origin)
            let settings = SettingsStore(defaults: s.defaults)
            settings.onMailSettingsChange = { _ in }
            return SetupFactsCollector(settings: settings, guide: GuideStore(defaults: s.defaults),
                                       sources: FakeFactSources(scenario: .fresh, home: dir), home: dir)
        }
        let legacy = Scratch(dir, "today-legacy")
        defer { legacy.drop() }
        let l = collector(legacy, origin: "legacy")
        let before = l.factsComposed
        let shown = GettingStartedCard.isShown(l)
        c.check("today: a legacy install decides without composing the guide facts",
                !shown && l.factsComposed == before, ["composed": l.factsComposed - before])

        let dismissed = Scratch(dir, "today-dismissed")
        defer { dismissed.drop() }
        let d = collector(dismissed, origin: "fresh")
        d.guide.checklistDismissed = true
        let before2 = d.factsComposed
        c.check("today: a dismissed card decides without composing the guide facts",
                !GettingStartedCard.isShown(d) && d.factsComposed == before2)

        let fresh = Scratch(dir, "today-fresh")
        defer { fresh.drop() }
        let f = collector(fresh, origin: "fresh")
        c.check("today: a fresh install still shows the card while setup is open", GettingStartedCard.isShown(f))
    }

    // MARK: First uses on a legacy install (F9)

    static func activityPolicy(_ dir: URL, _ c: SelfTestAppRules.Checker) {
        c.check("activity: wanted = fresh, or a guide view open",
                GuideActivity.wanted(origin: .fresh, guideOpen: false) && GuideActivity.wanted(origin: .legacy, guideOpen: true)
                    && !GuideActivity.wanted(origin: .legacy, guideOpen: false))
        for origin in ["legacy", "fresh"] {
            let s = Scratch(dir, "activity-\(origin)")
            defer { s.drop() }
            s.defaults.set(origin, forKey: ConfigKeys.origin)
            let settings = SettingsStore(defaults: s.defaults)
            settings.onMailSettingsChange = { _ in }
            let guide = GuideStore(defaults: s.defaults)
            let facts = SetupFactsCollector(settings: settings, guide: guide,
                                            sources: FakeFactSources(scenario: .fresh, home: dir), home: dir)
            guide.recordsActivity = GuideActivity.policy(settings: settings, facts: facts)
            guide.record(.panelDrop)
            let closed = s.persisted[ConfigKeys.guideActivity] != nil
            facts.activate("selftest")
            guide.record(.openedDetail)
            let open = (s.persisted[ConfigKeys.guideActivity] as? [String: Any])?[GuideActivityKind.openedDetail.rawValue] != nil
            facts.deactivate("selftest")
            if origin == "legacy" {
                c.check("activity: a legacy install writes no guide.activity with no guide open", !closed && guide.activity[.panelDrop] == nil)
                c.check("activity: … and records while a guide view is open", open)
            } else {
                c.check("activity: a fresh install records first uses (its checklist reads them)", closed && open)
            }
        }
        installedPath(dir, c)
    }

    /// The app's own path: what `AppDelegate` installs (`GuideActivity.install`) and what the views
    /// call (`GuideActivity.record`). A lost policy must not bring back legacy writes.
    static func installedPath(_ dir: URL, _ c: SelfTestAppRules.Checker) {
        let saved = GuideActivity.store
        defer { GuideActivity.store = saved }
        for origin in ["legacy", "fresh"] {
            let s = Scratch(dir, "activity-installed-\(origin)")
            defer { s.drop() }
            s.defaults.set(origin, forKey: ConfigKeys.origin)
            let settings = SettingsStore(defaults: s.defaults)
            settings.onMailSettingsChange = { _ in }
            let guide = GuideStore(defaults: s.defaults)
            let facts = SetupFactsCollector(settings: settings, guide: guide,
                                            sources: FakeFactSources(scenario: .fresh, home: dir), home: dir)
            GuideActivity.install(guide, settings: settings, facts: facts)
            let wired = GuideActivity.store === guide && guide.recordsActivity != nil
            GuideActivity.record(.panelDrop)
            let closed = s.persisted[ConfigKeys.guideActivity] != nil
            facts.activate("selftest")
            GuideActivity.record(.openedDetail)
            let open = (s.persisted[ConfigKeys.guideActivity] as? [String: Any])?[GuideActivityKind.openedDetail.rawValue] != nil
            facts.deactivate("selftest")
            if origin == "legacy" {
                c.check("activity (installed): a legacy install's views record nothing with no guide open",
                        wired && !closed && guide.activity[.panelDrop] == nil)
                c.check("activity (installed): … and record while a guide view is open", wired && open)
            } else {
                c.check("activity (installed): a fresh install's views record first uses", wired && closed && open)
            }
        }
        // A store without its policy (the wiring lost): nothing is recorded, not everything.
        let s = Scratch(dir, "activity-unwired")
        defer { s.drop() }
        s.defaults.set("fresh", forKey: ConfigKeys.origin)
        let guide = GuideStore(defaults: s.defaults)
        GuideActivity.store = guide
        GuideActivity.record(.panelDrop)
        c.check("activity (installed): a store without its policy records nothing (fail closed)",
                s.persisted[ConfigKeys.guideActivity] == nil && guide.activity.isEmpty)
    }
}
