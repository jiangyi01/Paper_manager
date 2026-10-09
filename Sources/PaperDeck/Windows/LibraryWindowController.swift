import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// Main card-library window (§8 主窗口, §3.3): an NSWindow whose content view is a
/// `DropHostingView` hosting `LibraryRootView`. Scene bridging makes SwiftUI's
/// `.toolbar` / `.searchable` / `.navigationTitle` reach the AppKit window.
/// While it is open the app is a regular app (Dock icon → Dock drops work);
/// closing it returns to menu-bar-only.
final class LibraryWindowController: NSObject, NSWindowDelegate {
    private static let autosaveName = "PaperDeckLibrary"
    private static let defaultSize = NSSize(width: 1280, height: 820)
    private static let minimumSize = NSSize(width: 900, height: 600)

    private let state: AppState
    private let chrome = LibraryChrome()
    private var window: NSWindow?

    init(state: AppState) {
        self.state = state
        super.init()
        chrome.onPickFiles = { [weak self] in self?.pickAndImportFiles() }
        chrome.onPickFolder = { [weak self] in self?.pickAndImportFolder() }
    }

    var isVisible: Bool { window?.isVisible == true }

    // MARK: Showing

    func show() {
        let w = window ?? makeWindow()
        ActivationPolicy.becomeRegular()
        LibraryMainMenu.installIfNeeded(state: state)
        NSApp.activate()
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
    }

    /// Selects the paper (switching to 全部 / 最近删除 when the current section or
    /// search hides it) and opens the inspector.
    func showPaper(id: String) {
        let id = id.lowercased()
        state.selectedPaperID = id
        func listed() -> Bool { state.visibleRows.contains { $0.id == id } }
        if !listed() {
            if !state.searchText.isEmpty { state.searchText = "" }   // clears the results synchronously
            if !listed() {
                let deleted = state.snapshot?.deleted.contains { $0.id == id } == true
                state.sidebar = deleted ? .recentlyDeleted : .all
            }
        }
        chrome.inspectorPresented = true
        show()
    }

    func showToday() {
        if !state.searchText.isEmpty { state.searchText = "" }
        state.sidebar = .today
        show()
    }

    // MARK: Import pickers (also installed as state.router.pickAndImportFiles/Folder)

    /// 添加 PDF… ⌘N — a sheet on the library window when it is visible.
    func pickAndImportFiles() {
        LibraryImportPicker.pickFiles(state: state, window: isVisible ? window : nil)
    }

    /// 导入文件夹… ⌥⌘N.
    func pickAndImportFolder() {
        LibraryImportPicker.pickFolder(state: state, window: isVisible ? window : nil)
    }

    /// Wires the router entries this window implements (leaves the others alone).
    func installRoutes() {
        state.router.showLibrary = { [weak self] in self?.show() }
        state.router.showPaper = { [weak self] id in self?.showPaper(id: id) }
        state.router.showToday = { [weak self] in self?.showToday() }
        state.router.pickAndImportFiles = { [weak self] in self?.pickAndImportFiles() }
        state.router.pickAndImportFolder = { [weak self] in self?.pickAndImportFolder() }
    }

    // MARK: Window

    private func makeWindow() -> NSWindow {
        let hosting = DropHostingView(rootView: LibraryHostRoot(state: state, chrome: chrome))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        // The window owns its size (autosaved frame, 900×600 minimum). SwiftUI's reported
        // minimum for the split view + inspector can equal the current height, which would
        // pin (and grow) the window, so no hosting-driven sizing at all.
        hosting.sizingOptions = []
        let engine = state.engine
        hosting.incomingDirectory = { engine.paths.incoming }
        hosting.onDrop = { [weak state] items, ignored in
            state?.ingest(items, origin: .drop, ignoredNames: ignored)
        }
        chrome.drop = hosting.dropState

        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.toolbarStyle = .unified
        w.title = L.libraryTitle
        w.contentView = hosting
        w.contentMinSize = Self.minimumSize
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.delegate = self
        w.identifier = ActivationPolicy.library
        let restored = w.setFrameUsingName(Self.autosaveName)
        w.setFrameAutosaveName(Self.autosaveName)
        if !restored { w.center() }
        chrome.window = w
        window = w
        return w
    }

    func windowWillClose(_ notification: Notification) {
        // Back to menu-bar only, unless the onboarding or Help window is still open.
        ActivationPolicy.update(closing: window)
    }
}

/// Root of the hosting view: injects the controller's chrome into the tree.
private struct LibraryHostRoot: View {
    let state: AppState
    let chrome: LibraryChrome

    var body: some View {
        LibraryRootView(state: state)
            .environment(chrome)
    }
}

// MARK: - Fallback main menu

/// A regular app without a main menu gets no ⌘C/⌘V/⌘A/⌘Z in text fields (search, notes,
/// sheets) and no ⌘W/⌘M. Installs a minimal App / File / Edit / Window / Help menu — only when the
/// app has no menu with a Paste item yet, so a main menu built by AppDelegate always wins.
/// `installStandalone()` builds it before the library exists (the onboarding preflight, Help):
/// the File items are disabled then.
enum LibraryMainMenu {
    private static var target: LibraryMenuTarget?
    private static weak var installed: NSMenu?

    static func installIfNeeded(state: AppState) {
        install(LibraryMenuTarget(state: state))
    }

    /// Without a library (the setup window's text fields still get Edit ⌘C/⌘V).
    static func installStandalone() {
        if target?.hasState == true, let current = NSApp.mainMenu, current === installed { return }
        install(LibraryMenuTarget(state: nil))
    }

    private static func install(_ t: LibraryMenuTarget) {
        if let current = NSApp.mainMenu, current !== installed, hasPaste(current) { return }
        target = t
        let (menu, windowMenu, helpMenu) = build(target: t)
        installed = menu
        NSApp.mainMenu = menu      // rebuilt on every show(): picks up a language switch
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu  // macOS adds its Help search field
    }

    private static func hasPaste(_ menu: NSMenu) -> Bool {
        menu.items.contains { $0.submenu?.items.contains { $0.action == #selector(NSText.paste(_:)) } == true }
    }

    private static func build(target: LibraryMenuTarget) -> (NSMenu, NSMenu, NSMenu) {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = m
            main.addItem(holder)
            return m
        }
        func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command,
                  target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        _ = submenu(L.appName, [
            item(L.Shell.menuAbout, #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item(L.settings, #selector(LibraryMenuTarget.showSettings), ",", target: target),
            .separator(),
            item(L.Shell.menuHide, #selector(NSApplication.hide(_:)), "h"),
            item(L.Shell.menuHideOthers, #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(L.Shell.menuShowAll, #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(L.quit, #selector(NSApplication.terminate(_:)), "q"),
        ])
        let file = submenu(L.Shell.menuFile, [
            item(L.Shell.addPDF, #selector(LibraryMenuTarget.addPDF), "n", target: target),
            item(L.Shell.importFolder, #selector(LibraryMenuTarget.importFolder), "n", [.command, .option], target: target),
            .separator(),
            item(L.Shell.menuCloseWindow, #selector(NSWindow.performClose(_:)), "w"),
        ])
        if !target.hasState {
            // No library yet: Settings… and the import items wait for the engine.
            file.autoenablesItems = false
            file.items.prefix(2).forEach { $0.isEnabled = false }
            main.items.first?.submenu?.autoenablesItems = false
            main.items.first?.submenu?.items.first { $0.action == #selector(LibraryMenuTarget.showSettings) }?.isEnabled = false
        }
        let edit = submenu(L.Shell.menuEdit, [
            item(L.Shell.menuUndo, Selector(("undo:")), "z"),
            item(L.Shell.menuRedo, Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(L.Shell.menuCut, #selector(NSText.cut(_:)), "x"),
            item(L.Shell.menuCopy, #selector(NSText.copy(_:)), "c"),
            item(L.Shell.menuPaste, #selector(NSText.paste(_:)), "v"),
            item(L.Shell.menuDelete, #selector(NSText.delete(_:))),
            item(L.Shell.menuSelectAll, #selector(NSText.selectAll(_:)), "a"),
        ])
        // Reading assist (Edit ▸ Select ▸ …, Library, Explain): nothing until each slice ships.
        ReadingAssistMenus.appendSelectItems(to: edit, state: target.appState)
        ReadingAssistMenus.appendMenus(to: main, state: target.appState)
        let window = submenu(L.Shell.menuWindow, [
            item(L.Shell.menuMinimize, #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(L.Shell.menuZoom, #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(L.Shell.menuBringAllToFront, #selector(NSApplication.arrangeInFront(_:))),
        ])
        let help = submenu(L.Help.helpMenu, [
            item(L.Help.paperDeckHelp, #selector(LibraryMenuTarget.showHelp), "?", target: target),
            item(L.Help.gettingStartedMenu, #selector(LibraryMenuTarget.showGettingStarted), target: target),
            item(L.Help.featureTourMenu, #selector(LibraryMenuTarget.showTour), target: target),
            item(L.Help.setupAssistantMenu, #selector(LibraryMenuTarget.showSetup), target: target),
            .separator(),
            item(L.Help.troubleshootingMenu, #selector(LibraryMenuTarget.showTroubleshooting), target: target),
            item(L.Help.diagnosticsMenu, #selector(LibraryMenuTarget.showDiagnostics), target: target),
        ])
        return (main, window, help)
    }
}

private final class LibraryMenuTarget: NSObject {
    private weak var state: AppState?
    let hasState: Bool
    init(state: AppState?) {
        self.state = state
        hasState = state != nil
    }
    var appState: AppState? { state }
    @objc func showSettings() { state?.router.showSettings(nil) }
    @objc func addPDF() { state?.router.pickAndImportFiles() }
    @objc func importFolder() { state?.router.pickAndImportFolder() }
    @objc func showHelp() { HelpCenter.openTopic(nil) }
    @objc func showGettingStarted() { HelpCenter.openTopic(.gettingStarted) }
    @objc func showTour() { HelpCenter.openTour() }
    @objc func showSetup() { HelpCenter.openSetup(nil) }
    @objc func showTroubleshooting() { HelpCenter.openTopic(HelpCenterModel.troubleshootingID) }
    @objc func showDiagnostics() { HelpCenter.openTopic(.diagnostics) }
}
