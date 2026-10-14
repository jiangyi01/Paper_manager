import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckShared

/// `--render OUTDIR --root LIB [--lang zh|en] [--appearance light|dark] [--provider claude|codex] [--mode off|claude|codex] [--provider-state ready] [--mail-fixtures DIR] [--mail-folder DIR] [--mail-only] [--guide-only --scenario NAME]`
/// Renders the real library window (and a few components) from an isolated
/// library into PNGs, using an invisible offscreen window — no screen recording,
/// never the user's real library, never a real AI run: both provider slots are mocks
/// (`--mode claude|codex` only relabels the chrome; agent mode is off by default).
enum PreviewRenderer {
    /// The render's own settings domain (never the app's): an absolute-path suite inside the scratch
    /// `--root` (`<root>/.render-defaults/defaults.plist`, as the self-tests' scratch domains), so two
    /// renders on different roots never wipe each other's demo accounts and nothing is left in
    /// ~/Library/Preferences.
    static func suite(root: URL) -> String {
        let dir = root.standardizedFileURL.appendingPathComponent(".render-defaults", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("defaults").path
    }

    static func run(_ args: CLIArgs) async -> Int32 {
        guard let out = args.positional.map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }),
              let root = args.url("--root") else {
            return CLIRunner.fail("--render OUTDIR --root LIBRARY_ROOT [--lang zh|en] [--appearance light|dark] [--provider claude|codex] [--mode off|claude|codex]")
        }
        let suite = Self.suite(root: root)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let lang = UILang(rawValue: args.value("--lang") ?? "en") ?? .en
        let appearance = NSAppearance(named: args.value("--appearance") == "dark" ? .darkAqua : .aqua)
        let provider = AIProviderKind(rawValue: args.value("--provider") ?? "claude") ?? .claude
        // Only off / claude / codex; the codex and claude slots below are mocks either way.
        let mode = AgentMode(rawValue: args.value("--mode") ?? "off").flatMap { $0 == .mock ? nil : $0 } ?? .off

        do {
            // The engine follows the render's language switches (`MailAppRenders`: the Settings ▸ Mail
            // rows before and after a switch).
            let engineLang = SharedValue(lang)
            let es: @Sendable () -> EngineSettings = { EngineSettings(plan: PlanSettings(), lang: engineLang.get, agentMode: mode, agentProvider: provider,
                                      autoReadNewPapers: false, metadataLookup: false) }
            // `--provider-state ready` shows the signed-in look (mock detection: version 0.0.0-mock).
            let behavior: MockAgentProvider.Behavior = args.value("--provider-state") == "ready" ? .success : .notLoggedIn
            // Settings ▸ Mail come from the render suite (demo accounts / senders below); never the
            // user's settings or the login keychain. The mail loop never starts (no engine.start()).
            let suiteName = suite
            let deps = Engine.Dependencies(loadSettings: es, fetcher: nil, claude: MockAgentProvider(behavior: behavior),
                                           codex: MockAgentProvider(behavior: behavior),
                                           mock: MockAgentProvider(), sidecarDelay: .milliseconds(20),
                                           cliFacts: .inMemory(),
                                           loadMailSettings: { UserDefaults(suiteName: suiteName).map { MailSettings.load(from: $0) } ?? MailSettings() },
                                           mailSecrets: InMemoryMailSecretStore())
            MailSecrets.store = InMemoryMailSecretStore()
            // The Power Automate form's OneDrive lookup stays inside the scratch root.
            MailAddAccountSheet.detectionHome = root
            let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: deps)
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            // `--seed-plist FILE`: the render suite starts as that settings domain (e.g. the synthetic
            // legacy fixture) instead of the demo accounts — before SettingsStore reads it.
            let seed = args.value("--seed-plist").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            if let seed {
                guard let data = try? Data(contentsOf: seed),
                      let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    return CLIRunner.fail("--seed-plist: can't read a settings dictionary from \(seed.path)")
                }
                for (key, value) in values { defaults.set(value, forKey: key) }
            }
            // `domain:` lets the transfer state (export, import plan, "Last exported") read the render
            // suite; a store on a non-standard defaults object without it reads nothing.
            let settings = SettingsStore(defaults: defaults, domain: suite)
            if seed != nil {
                // As with the demo: renders never reach the engine's mail loop.
                settings.onMailSettingsChange = { _ in }
            } else if !args.has("--no-mail-demo") && !args.has("--guide-only") {
                MailRenders.seedDemo(settings, root: root)
            } else if args.has("--guide-only") {
                settings.onMailSettingsChange = { _ in }
            }
            settings.language = lang
            settings.agentProvider = provider
            settings.agentMode = mode.rawValue
            let state = AppState(engine: engine, settings: settings)
            state.start()
            // `--mode` / `--provider-state`: run the agent queue against the MOCK providers so the
            // chrome shows a detected login state (it may also mark queued papers in this root).
            if args.has("--mode") || args.has("--provider-state") {
                await engine.agents.start()
                try await Task.sleep(for: .milliseconds(500))
            }
            var waited = 0
            while state.snapshot == nil && waited < 100 { try await Task.sleep(for: .milliseconds(100)); waited += 1 }
            // `--guide-only --scenario NAME`: the setup window's pages and the Help Center with canned
            // facts (`FakeFactSources`) — no CLI is probed, nothing else is drawn.
            if args.has("--guide-only") {
                let scenario = FactScenario(rawValue: args.value("--scenario") ?? "fresh") ?? .fresh
                let suffix = "\(scenario.rawValue)-\(lang.rawValue)-\(args.value("--appearance") ?? "light")"
                try await GuideRenders.render(state: state, defaults: defaults, scenario: scenario, root: root,
                                              appearance: appearance, out: out, suffix: suffix)
                state.stop()
                await engine.shutdown()
                defaults.removePersistentDomain(forName: suite)
                return 0
            }
            // `--select-only`: the multi-select surfaces (Slice C); `--probe-gestures` drives the grid.
            if args.has("--select-only") {
                let suffix = "\(lang.rawValue)-\(args.value("--appearance") ?? "light")"
                try await SelectionRenders.render(state: state, engine: engine, root: root, appearance: appearance, out: out,
                                                  suffix: suffix, probe: args.has("--probe-gestures"))
                state.stop()
                await engine.shutdown()
                defaults.removePersistentDomain(forName: suite)
                return 0
            }
            // `--reader-only`: the built-in reader (Slice C, C4); `--probe-reader` drives it.
            if args.has("--reader-only") {
                let suffix = "\(lang.rawValue)-\(args.value("--appearance") ?? "light")"
                try await ReaderRenders.render(state: state, engine: engine, root: root, appearance: appearance, out: out,
                                               suffix: suffix, probe: args.has("--probe-reader"))
                state.stop()
                await engine.shutdown()
                defaults.removePersistentDomain(forName: suite)
                return 0
            }
            // `--library-only [--widths "720, 900, …"]`: the library's columns at several window widths.
            if args.has("--library-only") {
                let suffix = "\(lang.rawValue)-\(args.value("--appearance") ?? "light")"
                try await LibraryRenders.render(state: state, engine: engine, root: root, appearance: appearance, out: out,
                                                suffix: suffix, widths: LibraryRenders.widths(args.value("--widths")))
                state.stop()
                await engine.shutdown()
                defaults.removePersistentDomain(forName: suite)
                return 0
            }
            // `--mail-folder DIR`: the demo Power Automate folder (under --root) gets DIR's files and one sync pass.
            if let folderFixtures = args.url("--mail-folder") {
                try await MailAppRenders.syncFolder(state: state, root: root, fixtures: folderFixtures)
            }

            let suffix = "\(lang.rawValue)-\(args.value("--appearance") ?? "light")" + (provider == .claude ? "" : "-\(provider.rawValue)")
            let chrome = LibraryChrome()
            // `--mail-only`: just the mail pages (+ pill and toasts) — skips Settings ▸ AI and the setup
            // assistant, whose CLI probes run `claude --version` / `codex --version`.
            let mailOnly = args.has("--mail-only")
            if !mailOnly {
                // Split views render through separate layers that cacheDisplay can't capture, so
                // each column is rendered on its own.
                try await captureView(LibrarySidebarView(state: state).environment(chrome).frame(width: 250, height: 780),
                                      size: NSSize(width: 250, height: 780), appearance: appearance,
                                      out.appendingPathComponent("sidebar-\(suffix).png"))
                try await captureView(TodayView(state: state).environment(chrome).frame(width: 900, height: 900),
                                      size: NSSize(width: 900, height: 900), appearance: appearance,
                                      out.appendingPathComponent("today-\(suffix).png"))
                for (name, item) in [("toread", SidebarItem.toRead), ("all", .all)] {
                    state.sidebar = item
                    try await Task.sleep(for: .milliseconds(300))
                    try await captureView(CardGridView(state: state, rows: state.visibleRows).environment(chrome)
                                            .frame(width: 1000, height: 1300),
                                          size: NSSize(width: 1000, height: 1300), appearance: appearance,
                                          out.appendingPathComponent("grid-\(name)-\(suffix).png"))
                }
                if let row = state.snapshot?.rows.first(where: { $0.paper.card != nil }) ?? state.snapshot?.rows.first {
                    state.selectedPaperID = row.id
                    try await captureView(PaperDetailView(state: state, row: row).environment(chrome)
                                            .frame(width: 380, height: 1500),
                                          size: NSSize(width: 380, height: 1400), appearance: appearance,
                                          out.appendingPathComponent("detail-\(suffix).png"))
                }
            }
            try await captureView(ClaudePill(state: state).padding(8), size: nil, appearance: appearance,
                                  out.appendingPathComponent("pill-\(suffix).png"))
            for tab in SettingsTab.shown where !mailOnly || tab == .mail {
                try await captureView(SettingsView(state: state, tab: tab).frame(width: 640, height: 820),
                                      size: NSSize(width: 640, height: 820), appearance: appearance,
                                      out.appendingPathComponent("settings-\(tab.rawValue)-\(suffix).png"))
            }
            try await MailRenders.render(state: state, appearance: appearance, out: out, suffix: suffix)
            try captureLaunchAlerts(appearance: appearance, out: out, suffix: suffix)
            if let fixtures = args.url("--mail-fixtures") {
                try await MailInboxRenders.render(state: state, fixtures: fixtures, appearance: appearance, out: out, suffix: suffix)
            }
            if args.has("--mail-fixtures") || args.has("--mail-folder") {
                try await MailAppRenders.render(state: state, appearance: appearance, out: out, suffix: suffix,
                                                engineLang: engineLang, root: root, folderFixtures: args.url("--mail-folder"))
            }
            if !mailOnly {
                try await captureView(SetupAssistantView(state: state, onFinish: {}).frame(width: 640, height: 900),
                                      size: NSSize(width: 640, height: 900), appearance: appearance,
                                      out.appendingPathComponent("setup-\(suffix).png"))
            }
            state.post(Toast(kind: .success, message: lang == .zh ? "已添加：Molecular and cellular dynamics… · DDL ≈周五" : "Added: Molecular and cellular dynamics… · DDL ≈Fri",
                             buttons: [Toast.Button(title: lang == .zh ? "查看" : "View", action: .openPaper(id: "x"))]))
            state.post(Toast(kind: .warning, message: lang == .zh ? "同一论文已在库中（v1）· 新文件 v2" : "Same paper already in library (v1) · new file v2",
                             buttons: [Toast.Button(title: lang == .zh ? "替换并保留清单" : "Replace, keep checklist", action: .replaceKeepingChecklist(pendingID: "p")),
                                       Toast.Button(title: lang == .zh ? "忽略" : "Ignore", action: .ignorePending(pendingID: "p"))]))
            try await captureView(ToastStack(state: state, maxVisible: 3).frame(width: 320).padding(10), size: nil,
                                  appearance: appearance, out.appendingPathComponent("toasts-\(suffix).png"))
            // Floating panel states (the controller drives the real window frame).
            if !mailOnly, let first = state.snapshot?.rows.first {
                engine.events.send(.importRow(ImportRowUpdate(id: "r1", batchID: "b", displayName: "s41586-024-08351-7.pdf", stage: .parsing)))
                engine.events.send(.importRow(ImportRowUpdate(id: "r2", batchID: "b", displayName: "2604.09554v2.pdf",
                                                              stage: .added(paperID: first.id, deadline: first.paper.deadline, provisional: true))))
                engine.events.send(.importRow(ImportRowUpdate(id: "r3", batchID: "b", displayName: "notes.pdf", stage: .rejected(reason: lang == .zh ? "不是 PDF" : "Not a PDF"))))
            }
            try await Task.sleep(for: .milliseconds(300))
            for (mode, size) in mailOnly ? [] : [(DropPanelModel.Mode.armed, NSSize(width: 300, height: 201)),
                                 (.targeted, NSSize(width: 300, height: 201)),
                                 (.processing, NSSize(width: 320, height: 330)),
                                 (.peek, NSSize(width: 280, height: 360)),
                                 (.collapsed, NSSize(width: 22, height: 85))] {
                let model = DropPanelModel()
                model.mode = mode
                let drop = DropTargetState()   // glass (armed/targeted) can't be captured offscreen — check on screen
                if mode == .targeted { drop.isTargeted = true; drop.summary = DropIntake.Summary(pdfFiles: 3, otherFiles: 1) }
                try await captureView(DropPanelView(model: model, state: state, dropState: drop).frame(width: size.width, height: size.height),
                                      size: size, appearance: appearance,
                                      out.appendingPathComponent("panel-\(String(describing: mode))-\(suffix).png"))
            }
            state.stop()
            await engine.shutdown()
            defaults.removePersistentDomain(forName: suite)
            return 0
        } catch {
            return CLIRunner.fail(String(describing: error))
        }
    }

    /// Renders one live SwiftUI view several times: before each PNG, `step` runs (a language
    /// switch…) and the view gets time to react — what a window on screen would show.
    static func captureSequence<V: View>(_ view: V, size: NSSize, appearance: NSAppearance?,
                                         _ steps: [(url: URL, step: () async -> Void)]) async throws {
        let hosting = NSHostingView(rootView: view.background(.background))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.appearance = appearance
        w.contentView = hosting
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.orderFrontRegardless()
        for (url, step) in steps {
            await step()
            try await Task.sleep(for: .milliseconds(1200))
            hosting.layoutSubtreeIfNeeded()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: url)
                print("wrote \(url.path)")
            }
        }
        w.orderOut(nil)
    }

    /// The launch alerts the renders draw, by PNG name.
    static func launchAlertCases() -> [(name: String, failure: LibraryOpenFailure)] {
        [("launch-alert-database", .database(diskFull: false)),
         ("launch-alert-diskfull", .database(diskFull: true)),
         ("launch-alert-newer", .newerVersion(found: 3, supported: 2)),
         ("launch-alert-appdata", .appData(folder: AppPaths.production().support)),
         ("launch-alert-folder", .libraryFolder)]
    }

    /// The missing-disk alert (Retry · Choose Another Folder… · Quit), drawn after the five above.
    /// Kept apart so `--selftest app-rules` (which checks those five) stays as it is until it covers it.
    static func volumeAlertCases() -> [(name: String, failure: LibraryOpenFailure)] {
        [("launch-alert-volume", .volumeMissing(volume: "Research"))]
    }

    /// One launch alert as the renders draw it: the real launch's `LaunchAlert.makeAlert` (only the
    /// library folder's path is a display stand-in — the renders never resolve the user's library).
    static func launchAlert(_ failure: LibraryOpenFailure) -> NSAlert {
        if case .volumeMissing(let volume) = failure {
            return LaunchAlert.makeAlert(for: failure, libraryPath: "/Volumes/\(volume)/PaperDeck", alternative: "~/Papers")
        }
        return LaunchAlert.makeAlert(for: failure, libraryPath: "~/Documents/PaperDeck", alternative: "~/Papers")
    }

    /// The launch alerts (`AppDelegate.askAfterOpenFailure`) as NSAlert lays them out, one PNG each.
    static func captureLaunchAlerts(appearance: NSAppearance?, out: URL, suffix: String) throws {
        for (name, failure) in launchAlertCases() + volumeAlertCases() {
            let alert = launchAlert(failure)
            alert.window.appearance = appearance
            alert.layout()
            guard let view = alert.window.contentView else { continue }
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = out.appendingPathComponent("\(name)-\(suffix).png")
                try rep.representation(using: .png, properties: [:])?.write(to: url)
                print("wrote \(url.path)")
            }
        }
    }

    /// Renders one SwiftUI view in an invisible borderless window and writes a PNG.
    static func captureView<V: View>(_ view: V, size: NSSize?, appearance: NSAppearance?, _ url: URL) async throws {
        let hosting = NSHostingView(rootView: view.background(.background))
        let fit = size ?? hosting.fittingSize
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: fit), styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.appearance = appearance
        w.contentView = hosting
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(900))
        hosting.layoutSubtreeIfNeeded()
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            print("wrote \(url.path)")
        }
        w.orderOut(nil)
    }
}

/// A value the engine's settings closures read while the renderer / self-test changes it.
nonisolated final class SharedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    var get: Value { lock.withLock { value } }
    func set(_ v: Value) { lock.withLock { value = v } }
}
