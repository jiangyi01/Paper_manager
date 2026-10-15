import AppKit
import ImageIO
import PaperDeckCore
import PaperDeckConfig

/// The ui-runtime fixes (hunt wave 1) in `--selftest app-rules`:
/// - the library-mismatch alert's buttons and which one quits (ui-runtime-1);
/// - a card thumbnail rewritten in place is decoded again under its new versioned URL (ui-runtime-2);
/// - Help's mail facts: an account that syncs with skipped emails is ready (ui-runtime-3);
/// - the Paper menu: every key of the card menu, worded in the UI language, off outside the
///   library window, and its actions on a scratch library (ui-runtime-4);
/// - quitting writes the notes still waiting for their debounce (ui-runtime-5);
/// - a minimized window keeps the app regular (ui-runtime-6);
/// - the menu bar is built in the language switched to (ui-runtime-7).
/// Headless: no window, no menu bar installed (the menus are built, never set as NSApp's), a
/// scratch engine and scratch defaults; nothing posted, no network, no AI.
extension SelfTestAppRules {
    static func runUIRuntime(scratch: URL, _ c: Checker) async {
        mismatchChoices(c)
        activationPolicy(c)
        await thumbnails(scratch: scratch, c)
        let root = scratch.appendingPathComponent("ui-runtime-library", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = scratch.appendingPathComponent("ui-runtime-defaults/defaults").path
        try? FileManager.default.createDirectory(atPath: (suite as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let defaults = UserDefaults(suiteName: suite),
              let engine = try? await Engine.open(paths: AppPaths.rooted(at: root), deps: deps()) else {
            c.check("ui-runtime: scratch library and defaults", false)
            return
        }
        let savedLang = LangStore.shared.lang, savedProvider = LangStore.shared.provider
        let settings = SettingsStore(defaults: defaults)
        settings.language = savedLang
        settings.onMailSettingsChange = { _ in }
        let state = AppState(engine: engine, settings: settings)
        await mailFacts(state, scratch: scratch, c)
        await paperMenu(state, c)
        await pendingNotes(state, c)
        menuLanguage(state, c)
        defaults.removePersistentDomain(forName: suite)
        LangStore.shared.lang = savedLang
        LangStore.shared.provider = savedProvider
        await close(engine)
    }

    // MARK: ui-runtime-1

    static func mismatchChoices(_ c: Checker) {
        let withPrevious = MismatchChoice.buttons(hasPrevious: true)
        let without = MismatchChoice.buttons(hasPrevious: false)
        c.check("mismatch: Go back only with a previous library",
                withPrevious == [.openThisLibrary, .goBack, .chooseAnother, .quit] && without == [.openThisLibrary, .chooseAnother, .quit])
        c.check("mismatch: the button returned picks its choice; anything else quits",
                MismatchChoice.chosen(1, in: without) == .chooseAnother && MismatchChoice.chosen(1, in: withPrevious) == .goBack
                    && MismatchChoice.chosen(7, in: without) == .quit && MismatchChoice.chosen(-1, in: withPrevious) == .quit)
    }

    // MARK: ui-runtime-6

    static func activationPolicy(_ c: Checker) {
        c.check("activation: a minimized library keeps the app regular",
                ActivationPolicy.keepsRegular(identifier: ActivationPolicy.library, isVisible: false, isMiniaturized: true)
                    && ActivationPolicy.keepsRegular(identifier: ActivationPolicy.reader, isVisible: true, isMiniaturized: false))
        c.check("activation: hidden or other windows don't",
                !ActivationPolicy.keepsRegular(identifier: ActivationPolicy.ask, isVisible: false, isMiniaturized: false)
                    && !ActivationPolicy.keepsRegular(identifier: nil, isVisible: true, isMiniaturized: true)
                    && !ActivationPolicy.keepsRegular(identifier: NSUserInterfaceItemIdentifier("Other"), isVisible: true,
                                                      isMiniaturized: false))
    }

    // MARK: ui-runtime-2

    private static func jpeg(width: Int, height: Int) -> Data? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    static func thumbnails(scratch: URL, _ c: Checker) async {
        let dir = scratch.appendingPathComponent("ui-runtime-thumbs", isDirectory: true)
        let store = ThumbnailStore(cardDirectory: dir.appendingPathComponent("card", isDirectory: true),
                                   widgetDirectory: dir.appendingPathComponent("widget", isDirectory: true))
        let id = UUID().uuidString.lowercased()
        func current() -> URL {
            let file = store.cardURL(for: id)
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return ThumbnailStore.versioned(file, version: ThumbnailStore.version(modified: values?.contentModificationDate,
                                                                                 size: values?.fileSize))
        }
        guard let first = jpeg(width: 560, height: 240), let second = jpeg(width: 400, height: 200),
              (try? store.save(cardJPEG: first, id: id)) != nil else {
            c.check("thumbnails: fixture", false)
            return
        }
        let old = current()
        let oldImage = await CardThumbnailCache.shared.load(old)
        try? store.save(cardJPEG: second, id: id)               // a replaced PDF's page 1, same path
        let new = current()
        let newImage = await CardThumbnailCache.shared.load(new)
        c.check("thumbnails: the versioned URL decodes its file", oldImage?.size == NSSize(width: 280, height: 120),
                ["size": oldImage.map { "\($0.size)" }])
        c.check("thumbnails: the rewritten file is a new URL and the new image",
                new != old && newImage?.size == NSSize(width: 200, height: 100), ["size": newImage.map { "\($0.size)" }])
    }

    // MARK: ui-runtime-3

    static func mailFacts(_ state: AppState, scratch: URL, _ c: Checker) async {
        let account = fakeAccount("lab")
        state.settings.mailAccounts = [account]
        let hint = MailSyncText.skippedByCap(3, lookbackDays: 14, LangStore.shared.lang)
        func snapshot(_ info: MailAccountSyncInfo) -> MailSnapshot {
            MailSnapshot(groups: [:], counts: MailCounts(), accounts: [info],
                         triageUsage: MailTriageUsage(day: LocalDate.today(), used: 0, limit: 30),
                         triageQueued: 0, enabled: true, aiMode: .ai, generatedAt: Date())
        }
        let guide = GuideStore(defaults: nil)
        let facts = SetupFactsCollector(settings: state.settings, guide: guide,
                                        sources: FakeFactSources(scenario: .fresh, home: scratch), home: scratch)
        facts.state = state
        state.mailSnapshot = snapshot(MailAccountSyncInfo(
            id: account.id, displayName: account.displayName, kind: .imap, enabled: true,
            status: .unavailable("Signed in · " + hint), lastSuccessAt: Date(), consecutiveFailures: 0,
            skipped: 3, skippedHint: hint))
        let skipped = GuideEvaluator.evaluate(.mailAccountReady(nil), facts.facts)
        c.check("mail facts: an account that syncs with skipped emails is ready (no 'server isn't reachable')",
                skipped == .done, ["state": String(describing: skipped)])
        state.mailSnapshot = snapshot(MailAccountSyncInfo(
            id: account.id, displayName: account.displayName, kind: .imap, enabled: true,
            status: .unavailable("Couldn't connect"), lastSuccessAt: Date(), consecutiveFailures: 2))
        let failing = GuideEvaluator.evaluate(.mailAccountReady(nil), facts.facts)
        let isProblem: Bool = { if case .problem = failing { return true }; return false }()
        c.check("mail facts: a failing server is still a problem", isProblem, ["state": String(describing: failing)])
        state.mailSnapshot = nil
        state.settings.mailAccounts = []
    }

    // MARK: ui-runtime-4

    private static func paperItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            if let sub = item.submenu { return paperItems(sub) }
            return item.representedObject is String ? [item] : []
        }
    }

    static func paperMenu(_ state: AppState, _ c: Checker) async {
        let engine = state.engine
        var ids: [String] = []
        for title in ["Menu one", "Menu two", "Menu three"] {
            let p = Paper(sha256: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                            .padding(toLength: 64, withPad: "0", startingAt: 0),
                          fileSize: 10, title: title, folder: "Papers/" + title.replacingOccurrences(of: " ", with: "-"),
                          pdfName: "p.pdf", originalName: "p.pdf", stage: .ready, provisional: false)
            if let saved = try? await engine.db.insertPaper(p) { ids.append(saved.id) }
        }
        state.scheduleRefresh(delay: .zero)
        _ = await eventually(5) { state.snapshot?.rows.count == 3 }
        guard ids.count == 3, state.snapshot?.rows.count == 3 else {
            c.check("paper menu: scratch papers", false, ["ids": ids.count])
            return
        }

        // The menu: every key the card menu shows, worded in the UI language.
        let (bar, target) = LibraryMainMenu.built(state: state)
        let holder = bar.items.first { $0.submenu?.title == L.Shell.menuPaper }
        let items = holder?.submenu.map(paperItems) ?? []
        let keys = Set(items.map { "\($0.keyEquivalentModifierMask.rawValue)/\($0.keyEquivalent)" })
        let wanted = Set(PaperMenu.entries.map { "\($0.modifiers.rawValue)/\($0.key)" })
        c.check("paper menu: in the menu bar with ⌘O ⌥⌘O ⌘D ⌥⌘1/2/3 ⇧⌘P ⌥⌘R ⇧⌘R ⌘⌫",
                holder != nil && items.count == PaperCommand.allCases.count && keys == wanted && wanted.count == 10
                    && PaperMenu.entries.contains { $0.command == .moveToTrash && $0.key == "\u{8}" && $0.modifiers == .command },
                ["items": items.map(\.title)])
        c.check("paper menu: the items act through its target (kept by the menu target)",
                items.allSatisfy { $0.target === target.paper && $0.action == #selector(PaperMenuTarget.runCommand(_:)) })
        c.check("paper menu: titled in the UI language",
                items.contains { $0.title == L.cardsMenuMoveToRecentlyDeleted } && items.contains { $0.title == L.cardsMenuOpenPDF })

        // Outside the library window (no key window here) or while typing, nothing runs.
        state.selectedPaperID = ids[0]
        let rows = PaperMenu.targetRows(state)
        let outside = PaperMenu.context(state, rows: rows, keyWindow: nil)
        c.check("paper menu: the focused paper is the target; off without the library window",
                rows.map(\.id) == [ids[0]] && !outside.libraryIsKey
                    && PaperCommand.allCases.allSatisfy { !PaperCommandRules.isEnabled($0, outside) })
        c.check("paper menu: a text field or text view keeps its keys",
                PaperMenu.isEditingText(NSTextView()) && PaperMenu.isEditingText(NSTextField()) && !PaperMenu.isEditingText(NSView())
                    && !PaperMenu.isEditingText(nil))

        // The actions (what the context menu runs).
        func paper(_ id: String) async -> Paper? { try? await engine.db.paper(id: id) }
        PaperMenu.run(.toggleDone, state: state, rows: rows)
        let done = await eventually(5) { await paper(ids[0])?.status == .done }
        PaperMenu.run(.priorityHigh, state: state, rows: rows)
        let high = await eventually(5) { await paper(ids[0])?.priority == .high }
        c.check("paper menu: ⌘D marks the focused paper read, ⌥⌘1 makes it high priority", done && high)

        // A multi-selection in the grid: both selected papers, one batch.
        state.sidebar = .all
        state.scheduleRefresh(delay: .zero)
        _ = await eventually(3) { state.visibleRows.count == 3 }
        state.selection.click(ids[1], kind: .plain)
        state.selection.click(ids[2], kind: .toggle)
        let multi = PaperMenu.targetRows(state)
        PaperMenu.run(.priorityLow, state: state, rows: multi)
        let low = await eventually(5) {
            let a = await paper(ids[1]), b = await paper(ids[2])
            return a?.priority == .low && b?.priority == .low
        }
        PaperMenu.run(.toggleDone, state: state, rows: multi)
        let bothDone = await eventually(5) {
            let a = await paper(ids[1]), b = await paper(ids[2])
            return a?.status == .done && b?.status == .done
        }
        c.check("paper menu: a multi-selection's ⌥⌘3 and ⌘D apply to every selected paper",
                Set(multi.map(\.id)) == [ids[1], ids[2]] && low && bothDone, ["targets": multi.count])
        c.check("paper menu: titles follow the selection",
                PaperMenu.title(.moveToTrash, rows: multi) == L.Select.moveToTrash(2)
                    && PaperMenu.title(.toggleDone, rows: multi) == L.cardsMenuMarkDone)
        state.selection.clear()
        state.sidebar = .today
    }

    // MARK: ui-runtime-5

    static func pendingNotes(_ state: AppState, _ c: Checker) async {
        guard let id = state.snapshot?.rows.first?.id else {
            c.check("pending notes: a scratch paper", false)
            return
        }
        // What NotesEditor registers while its debounce runs; applicationShouldTerminate flushes it.
        let engine = state.engine, text = "typed just before quitting"
        state.pendingSaves.set("notes-selftest") { _ = try? await engine.setNotes(paperID: id, text) }
        await state.pendingSaves.flushAll()
        let saved = (try? await engine.db.paper(id: id))?.notes
        c.check("pending notes: the quit flush writes the unsaved notes", saved == text && state.pendingSaves.isEmpty)
    }

    // MARK: ui-runtime-7

    static func menuLanguage(_ state: AppState, _ c: Checker) {
        let store = LangStore.shared
        let saved = store.lang
        defer { store.lang = saved }
        var titles: [UILang: [String]] = [:]
        for lang in UILang.allCases {
            store.lang = lang
            let (bar, _) = LibraryMainMenu.built(state: state)
            titles[lang] = bar.items.map(\.title)
        }
        let en = titles[.en] ?? [], zh = titles[.zh] ?? []
        c.check("menu language: the menu bar is built in the language switched to",
                en.contains("Paper") && en.contains("Edit") && zh.contains("论文") && zh.contains("编辑") && en != zh,
                ["en": en, "zh": zh])
    }
}
