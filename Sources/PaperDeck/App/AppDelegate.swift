import AppKit
import PaperDeckCore
import PaperDeckConfig
import PaperDeckShared

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var settings: SettingsStore!
    private(set) var state: AppState?
    private var libraryWindow: LibraryWindowController?
    private var settingsWindow: SettingsWindowController?
    /// Onboarding and Help exist before the engine (the preflight, Help from the setup window).
    private var guide: GuideStore!
    private var facts: SetupFactsCollector!
    private var onboarding: OnboardingWindowController!
    private var help: HelpWindowController!
    private var dropPanel: DropPanelController?
    private var statusBar: StatusBarController?
    private var reminders: ReminderService!
    private var refresher: DerivedRefresher?
    private var mailNotifier: MailRequestNotifier?
    private var sigtermSource: DispatchSourceSignal?
    private var sleepObserver: (any NSObjectProtocol)?
    private var instanceLockFD: Int32 = -1
    /// Files/URLs delivered before the engine finished opening (cold "Open With").
    private var pendingOpens: [URL] = []
    private var shuttingDown = false

    /// `--gui-root <dir>` runs the GUI against an isolated library (dev/testing only).
    private lazy var rootOverride: URL? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--gui-root"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
    }()

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard acquireSingleInstanceLock() else {
            // Another copy is running: hand it the "open" and quit quietly.
            NSWorkspace.shared.open(DeepLink.today.url)
            exit(0)
        }
        installSIGTERMHandler()
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        // The notification delegate must exist before launch finishes, or the click
        // that launched us is lost. Actions queue until the state exists.
        reminders = ReminderService(stateProvider: { [weak self] in self?.state })
        reminders.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Before SettingsStore registers its defaults: the migration reads the persisted domain only.
        ConfigMigration.runIfNeeded()
        settings = SettingsStore()
        // Explain's Services provider before anything else: a Services call that cold-launched the app
        // waits in its queue until the library is open (`ExplainBootstrap.install`).
        ExplainBootstrap.installServices()
        guide = GuideStore(defaults: .standard)
        let agentCwd = (rootOverride.map { AppPaths.rooted(at: $0) } ?? AppPaths.production()).agentCwd
        facts = SetupFactsCollector(settings: settings, guide: guide, sources: LiveFactSources(agentCwd: agentCwd))
        // First uses: the store with its policy (a legacy install records only while a guide is open).
        GuideActivity.install(guide, settings: settings, facts: facts)
        onboarding = OnboardingWindowController(settings: settings, guide: guide, facts: facts)
        help = HelpWindowController(settings: settings, facts: facts)
        installHelpRoutes()
        Task { await bootstrap() }
        Log.app.info("PaperDeck launched")
    }

    /// Help ▸ …, "?" buttons, deep links and the setup window reach Help and Setup through these
    /// (they work before the engine exists).
    private func installHelpRoutes() {
        HelpCenter.openTopic = { [weak self] topic in self?.help.show(topic: topic) }
        HelpCenter.openTour = { [weak self] in self?.help.showTour() }
        HelpCenter.openSetup = { [weak self] page in self?.onboarding.show(resume: page) }
        onboarding.onFinished = { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .tour: self.help.showTour()
            case .library: self.state?.router.showToday()
            case .close: if self.settings.setupCompleted, self.libraryWindow?.isVisible != true { self.state?.router.showToday() }
            }
        }
    }

    // MARK: - Engine

    private func libraryPaths() -> AppPaths {
        if let root = rootOverride {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return AppPaths.rooted(at: root)
        }
        return AppPaths.production(library: URL(fileURLWithPath: settings.libraryPath, isDirectory: true))
    }

    private func bootstrap() async {
        // A fresh install chooses its library (and profile, AI) before the engine exists; an
        // existing install (the gate is false) opens exactly as before.
        var preflight: PreflightResult?
        let databaseExists = FileManager.default.fileExists(atPath: AppPaths.production().database.path)
        if rootOverride == nil, !settings.config.legacyOnboardingFlag,
           OnboardingGate.needsPreflight(.app(), databaseExists: databaseExists, rootOverride: false) {
            guard let result = await onboarding.runPreflight(pendingOpens: pendingOpens.count(where: \.isFileURL)) else {
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
                return
            }
            preflight = result
        }
        // Settings ▸ Library ▸ Change… left an action for this launch: its folder first.
        let pending = rootOverride == nil ? LibraryPendingAction.load(.standard) : nil
        if let pending, settings.libraryPath != pending.path { settings.libraryPath = pending.path }

        // A failure shows an alert (`LaunchAlert`): Retry opens again; only a library *folder*
        // problem may switch to ~/Papers (and write library.path) — never a database or app-data one.
        let opened = await LaunchAlert.open(
            libraryPaths(), alternative: SharedPaths.realHome.appendingPathComponent("Papers", isDirectory: true),
            // The card prompt's reader comes from the profile (today: the comp-bio literal), per request.
            // The duplicate check's core hooks follow the UI's flag: a build without the Duplicates UI
            // never holds a paper it gives no way to release.
            open: { [dedupeShips = AssistRollout.dedupe] in
                try await Engine.open(paths: $0, deps: Engine.Dependencies(
                    loadSettings: {
                        var s = EngineSettings.load()
                        if !dedupeShips { s.dedupe.enabled = false }
                        return s
                    },
                    loadCardProfile: { ConfigResolver.cardPromptProfile() })) },
            ask: { failure, paths in self.askAfterOpenFailure(failure, paths: paths) },
            useLibrary: { alt in
                try? FileManager.default.createDirectory(at: alt, withIntermediateDirectories: true)
                // `--gui-root` ignores library.path: retry without touching the real setting.
                if self.rootOverride == nil { self.settings.libraryPath = alt.path }
                return self.libraryPaths()
            },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            log: { failure, error in
                // The class and the error's type only: an error's description may carry file paths.
                Log.app.error("engine open failed (\(failure.logName, privacy: .public)): \(String(describing: type(of: error)), privacy: .public)")
            },
            chooseLibrary: { Self.chooseLibraryFolder() })
        guard let engine = opened else {
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            return
        }
        // Before start(): an index rebuilt from the chosen folder (its manifest id), or the field's
        // starter categories on a pristine new library — so the first manifest write is right.
        var indexFailed = false
        if let pending {
            let pack = pending.kind == .startNew ? settings.config.snapshot.field.starterCategories : nil
            indexFailed = !(await replaceIndex(engine, starterPack: pack))
            LibraryPendingAction.clear(.standard)
            guide.reload()
        } else if preflight?.existingLibrary == true {
            indexFailed = !(await replaceIndex(engine, starterPack: nil))
        }
        if let pack = preflight?.starterPack {
            _ = try? await engine.applyStarterPackIfPristine(pack)
        }
        let state = AppState(engine: engine, settings: settings, guide: guide)
        state.facts = facts
        facts.state = state
        self.state = state
        buildUI(state)
        ExplainBootstrap.install(state)         // hotkey, Services provider: nothing until Explain ships
        AskRouter.install(state)                // the reader's Ask buttons, Services; inert while Ask is hidden
        installAssistSessionClosers(engine)
        onboarding.attach(state)
        state.start()
        if indexFailed { state.post(Toast(kind: .error, message: L.Onb.reindexFailed)) }
        // Launch maintenance + resume interrupted work before accepting queued opens. A folder that
        // holds another library stops it before anything is written (the alert decides).
        let report = await engine.start()
        facts.libraryIdentity = report.libraryMismatch
        if let mismatch = report.libraryMismatch { await resolveMismatch(mismatch, engine: engine) }
        refresher?.start()
        let opens = pendingOpens
        pendingOpens.removeAll()
        if !opens.isEmpty { handleOpen(opens) }
        // After a preflight the setup window is already on screen (live mode).
        if preflight == nil, !settings.setupCompleted { onboarding.show(resume: nil) }
    }

    /// A warm or live assist process (Explain & Ask) is closed when the Mac goes to sleep and when
    /// the user turns `assist.mode` off or switches it to another provider; Explain's shortcut
    /// follows the switch.
    private func installAssistSessionClosers(_ engine: Engine) {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { await engine.assist.closeAllSessions() }
        }
        settings.onAssistModeChange = {
            Task { await engine.assist.closeAllSessions() }
            ExplainBootstrap.assistModeChanged()    // the shortcut is registered only while assist.mode is on
        }
        // Another shortcut (the recorder in Settings, or a settings import) is registered again.
        settings.onExplainHotKeyChange = { ExplainBootstrap.shortcutChanged() }
    }

    /// "Open existing" / "Start new empty" / an existing library from the preflight. False when it failed.
    private func replaceIndex(_ engine: Engine, starterPack: [StarterCategory]?) async -> Bool {
        do {
            _ = try await engine.replaceIndexFromLibraryFolder(starterPackIfEmpty: starterPack)
            return true
        } catch {
            Log.app.error("re-indexing the library folder failed: \(String(describing: type(of: error)), privacy: .public)")
            return false
        }
    }

    /// The index belongs to another library than the folder (PORTABILITY_PLAN §3.3 P4): nothing was
    /// written; the user picks what happens.
    private func resolveMismatch(_ check: LibraryIdentityCheck, engine: Engine) async {
        guard case .mismatch(_, _, let papers) = check else { return }
        let current = engine.paths.library.path
        let previous = UserDefaults.standard.string(forKey: ConfigKeys.libraryPreviousPath)
            .flatMap { $0 == current || $0.isEmpty ? nil : $0 }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L.Onb.mismatchTitle
        alert.informativeText = L.Onb.mismatchBody(papers)
        var buttons: [String] = ["open"]
        alert.addButton(withTitle: L.Onb.openThisLibrary)
        if let previous {
            alert.addButton(withTitle: L.Onb.goBackTo(SettingsFormat.tildePath(previous)))
            buttons.append("back")
        }
        alert.addButton(withTitle: L.Onb.chooseAnotherFolder)
        buttons.append("choose")
        alert.addButton(withTitle: L.quit)
        buttons.append("quit")
        NSApp.activate()
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        switch buttons.indices.contains(index) ? buttons[index] : "quit" {
        case "open":
            if await replaceIndex(engine, starterPack: nil) {
                let again = await engine.start()
                facts.libraryIdentity = again.libraryMismatch
                if let still = again.libraryMismatch { await resolveMismatch(still, engine: engine) }
            } else {
                await resolveMismatch(check, engine: engine)
            }
        case "back":
            if let previous { settings.libraryPath = previous }
            Relaunch.now()
        case "choose":
            guard let url = Self.chooseLibraryFolder() else { await resolveMismatch(check, engine: engine); return }
            settings.libraryPath = url.path
            Relaunch.now()
        default:
            NSApp.terminate(nil)
        }
    }

    /// A folder for the library (the missing-disk alert, the mismatch alert).
    static func chooseLibraryFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L.Onb.chooseFolderPrompt
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func buildUI(_ state: AppState) {
        let library = LibraryWindowController(state: state)
        let settingsWindow = SettingsWindowController(state: state)
        libraryWindow = library
        self.settingsWindow = settingsWindow
        library.installRoutes()
        state.router.showSettings = { [weak settingsWindow] tab in settingsWindow?.show(tab: tab) }
        state.router.showSetupAssistant = { [weak self] in self?.onboarding.show(resume: nil) }
        state.router.showHelp = { [weak self] topic in self?.help.show(topic: topic) }
        state.router.armDropPanel = { [weak self] seconds in self?.dropPanel?.arm(for: seconds) }
        dropPanel = DropPanelController(state: state)
        statusBar = StatusBarController(state: state)
        refresher = DerivedRefresher(state: state, reminders: reminders)
        // Before state.start(): the first inbox snapshot already goes through it.
        let notifier = MailRequestNotifier(state: state, reminders: reminders)
        notifier.start()
        mailNotifier = notifier
    }

    /// The launch alert after a failed open (`LaunchAlert.makeAlert`, the one `--render` draws).
    /// A library folder problem (Documents access denied, volume missing) offers ~/Papers (never
    /// a silent fallback); a newer or failed database, or app folders that can't be created, say
    /// what happened and that nothing was deleted.
    private func askAfterOpenFailure(_ failure: LibraryOpenFailure, paths: AppPaths) -> LaunchAlert.Button {
        let alert = Self.launchAlert(for: failure, paths: paths)
        NSApp.activate()
        return LaunchAlert.button(for: alert.runModal(), failure: failure)
    }

    /// The alert `askAfterOpenFailure` runs for `paths` (the library folder it names, ~/Papers).
    static func launchAlert(for failure: LibraryOpenFailure, paths: AppPaths) -> NSAlert {
        let alt = SharedPaths.realHome.appendingPathComponent("Papers", isDirectory: true)
        return LaunchAlert.makeAlert(for: failure, libraryPath: paths.library.path, alternative: alt.path)
    }

    // MARK: - Open With / URL scheme

    func application(_ application: NSApplication, open urls: [URL]) {
        handleOpen(urls)
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        handleOpen([url])
    }

    private func handleOpen(_ urls: [URL]) {
        guard let state else {
            pendingOpens.append(contentsOf: urls)
            onboarding?.setPendingOpens(pendingOpens.count(where: \.isFileURL))
            return
        }
        let files = urls.filter(\.isFileURL)
        // Emails (Open With / Finder "Open" on an .eml) become Mail cards; everything else is imported.
        let emails = files.filter { MailDropIntake.isEmail($0) }
        if !emails.isEmpty { state.importMailFiles(emails, temporary: false) }
        let others = files.filter { !MailDropIntake.isEmail($0) }
        if !others.isEmpty {
            GuideActivity.record(.openWith)
            state.ingest(others.map { .file($0) }, origin: .openWith)
        }
        for url in urls where url.scheme == DeepLink.scheme {
            guard let link = DeepLink(url: url) else { continue }
            URLRouter.handle(link, state: state)
        }
    }

    /// Clicking the app in Finder/Launchpad while running opens the library.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Before the library exists (the preflight) the setup window comes forward.
        if let libraryWindow { libraryWindow.show() } else if onboarding?.isVisible == true { onboarding.show(resume: nil) }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Give the engine a moment to cancel the agent child, flush card.json and checkpoint.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engine = state?.engine, !shuttingDown else { return .terminateNow }
        shuttingDown = true
        refresher?.stop()
        mailNotifier?.stop()
        state?.stop()
        ExplainBootstrap.shutdown()             // Explain's panels close (their sessions end), the shortcut goes
        Task {
            await engine.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Process plumbing

    /// flock on Application Support/PaperDeck/.lock — one instance per user.
    private func acquireSingleInstanceLock() -> Bool {
        let dir = SharedPaths.supportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return false }
        instanceLockFD = fd
        return true
    }

    /// `pkill -TERM PaperDeck` (build script) goes through the normal terminate path.
    private func installSIGTERMHandler() {
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        // Never call terminate() from inside a main-queue callout: with .terminateLater AppKit
        // spins a nested event loop while the main queue is still busy, so the MainActor task
        // that replies can never run (deadlock). Perform it from the run loop instead.
        src.setEventHandler {
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }
        src.resume()
        sigtermSource = src
    }
}
