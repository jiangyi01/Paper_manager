import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PaperDeckCore

/// §8 toolbar (bridged through `sceneBridgingOptions`): Claude pill, sort, `+`
/// (添加 PDF… ⌘N / 导入文件夹… ⌥⌘N) and the inspector toggle (⌘I). The search
/// field comes from `.searchable` on the content column.
struct LibraryToolbar: ToolbarContent {
    @Bindable var state: AppState
    @Bindable var chrome: LibraryChrome

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ClaudePill(state: state)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            if AssistRollout.selection { SelectMenu(state: state) }       // multi-select (Slice C)
            sortMenu
            addMenu
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button {
                chrome.toggleInspector()
            } label: {
                Label(chrome.inspectorPresented ? L.Shell.hideInspector : L.Shell.showInspector,
                      systemImage: "sidebar.trailing")
            }
            .keyboardShortcut("i", modifiers: .command)
            .help(chrome.inspectorPresented ? L.Shell.hideInspector : L.Shell.showInspector)
        }
    }

    private var sortFixed: Bool { state.sidebar == .today || state.sidebar == .recentlyDeleted || state.sidebar == .mail }

    private var sortMenu: some View {
        Menu {
            Picker(L.Shell.sort, selection: $state.sort) {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Text(Self.title(order)).tag(order)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(L.Shell.sort, systemImage: "arrow.up.arrow.down")
        }
        .menuIndicator(.hidden)
        .disabled(sortFixed)
        .help(sortFixed ? L.Shell.sortDisabledHint : L.Shell.sort + " · " + Self.title(state.sort))
    }

    private var addMenu: some View {
        Menu {
            Button(L.Shell.addPDF) { chrome.pickFiles() }
                .keyboardShortcut("n", modifiers: .command)
            Button(L.Shell.importFolder) { chrome.pickFolder() }
                .keyboardShortcut("n", modifiers: [.command, .option])
        } label: {
            Label(L.Shell.add, systemImage: "plus")
        } primaryAction: {
            chrome.pickFiles()
        }
        .help(L.Shell.addPDF)
    }

    static func title(_ order: SortOrder) -> String {
        switch order {
        case .deadline: L.Shell.sortDeadline
        case .added: L.Shell.sortAdded
        case .title: L.Shell.sortTitle
        }
    }
}

/// Window-scoped shortcuts that have no always-visible control: ⌘F focuses the search
/// field; ⌘N / ⌥⌘N also work while the `+` menu is closed. Zero-size, invisible buttons.
struct LibraryShortcuts: View {
    let chrome: LibraryChrome

    var body: some View {
        ZStack {
            Button("") { chrome.searchFocusRequest += 1 }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { chrome.pickFiles() }
                .keyboardShortcut("n", modifiers: .command)
            Button("") { chrome.pickFolder() }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

// MARK: - NSOpenPanel import

/// 添加 PDF… / 导入文件夹…: NSOpenPanel → `state.ingest`. Attached as a sheet to
/// `window` when it is visible, otherwise a free-standing panel (menu bar, no window).
enum LibraryImportPicker {
    static func pickFiles(state: AppState, window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = L.Shell.addPrompt
        panel.message = L.Shell.addPDFMessage
        present(panel, window: window) { urls in
            state.ingest(urls.map { .file($0) }, origin: .openWith)
        }
    }

    static func pickFolder(state: AppState, window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.prompt = L.Shell.importPrompt
        panel.message = L.Shell.importFolderMessage
        present(panel, window: window) { urls in
            state.ingest(urls.map { .file($0) }, origin: .folderImport)
        }
    }

    private static func present(_ panel: NSOpenPanel, window: NSWindow?, completion: @escaping ([URL]) -> Void) {
        if let window, window.isVisible, !window.isMiniaturized, window.attachedSheet == nil {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK else { return }
                completion(panel.urls)
            }
        } else {
            NSApp.activate()
            panel.begin { response in
                guard response == .OK else { return }
                completion(panel.urls)
            }
        }
    }
}
