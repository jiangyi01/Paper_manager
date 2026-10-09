import AppKit
import SwiftUI
import PaperDeckCore

/// Window-level UI state shared by LibraryWindowController and the SwiftUI tree
/// (injected with `.environment(chrome)`; LibraryRootView falls back to its own).
@Observable
final class LibraryChrome {
    /// The hosting view's drag-hover state (drives the 「松手添加 N 个 PDF」 / 「松手导入 N 封邮件」
    /// overlay; none while a Mail row or card is the target — it highlights itself).
    var drop: DropTargetState?
    var inspectorPresented = false
    /// Selecting a paper opens the inspector until the user hides it themselves (⌘I).
    var inspectorAutoOpens = true
    /// Banner ids closed with × this session.
    var dismissedBanners: Set<String> = []
    /// Bumped by ⌘F; the content column focuses the search field.
    var searchFocusRequest = 0

    @ObservationIgnored weak var window: NSWindow?
    /// Installed by the controller (sheet on the library window); fallback: a free panel.
    @ObservationIgnored var onPickFiles: (() -> Void)?
    @ObservationIgnored var onPickFolder: (() -> Void)?

    func toggleInspector() {
        inspectorPresented.toggle()
        inspectorAutoOpens = inspectorPresented
    }

    func pickFiles() { onPickFiles?() }
    func pickFolder() { onPickFolder?() }
}

/// sidebar | content | inspector (⌘I) with toolbar, search, banners, the batch
/// dialog sheet and the full-window drop overlay. 邮件 shows the Mail inbox and, in the
/// inspector, the selected email (`selectedMailID`).
struct LibraryRootView: View {
    @Bindable var state: AppState
    @Environment(LibraryChrome.self) private var injectedChrome: LibraryChrome?
    @State private var ownChrome = LibraryChrome()

    init(state: AppState) {
        self.state = state
    }

    private var chrome: LibraryChrome { injectedChrome ?? ownChrome }

    var body: some View {
        let chrome = self.chrome
        NavigationSplitView {
            LibrarySidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 340)
        } detail: {
            LibraryDetailColumn(state: state, chrome: chrome)
        }
        .overlay { MailAwareDropOverlay(drop: chrome.drop) }
        .sheet(item: batchItem) { item in
            BatchDialog(state: state, summary: item.summary) { state.pendingBatch = nil }
        }
        .onChange(of: state.selectedPaperID) { _, id in
            if id != nil, chrome.inspectorAutoOpens, !chrome.inspectorPresented { chrome.inspectorPresented = true }
        }
        .onChange(of: state.selectedMailID) { _, id in
            if id != nil, state.sidebar == .mail, chrome.inspectorAutoOpens, !chrome.inspectorPresented {
                chrome.inspectorPresented = true
            }
        }
        .onChange(of: state.searchText) { old, new in
            // Searching from 今天 (a plan, not a list) or 邮件 (not papers) searches the whole library.
            if old.isEmpty, !new.isEmpty, state.sidebar == .today || state.sidebar == .mail { state.sidebar = .all }
        }
        .onAppear {
            if chrome.onPickFiles == nil { chrome.onPickFiles = { [state] in LibraryImportPicker.pickFiles(state: state, window: nil) } }
            if chrome.onPickFolder == nil { chrome.onPickFolder = { [state] in LibraryImportPicker.pickFolder(state: state, window: nil) } }
        }
    }

    /// `.sheet(item:)` keeps the dialog's content during the dismissal animation.
    private var batchItem: Binding<BatchSheetItem?> {
        Binding(get: { state.pendingBatch.map(BatchSheetItem.init) },
                set: { if $0 == nil { state.pendingBatch = nil } })
    }
}

private struct BatchSheetItem: Identifiable {
    let summary: ImportBatchSummary
    var id: String { summary.batchID }
}

// MARK: - Content column

private struct LibraryDetailColumn: View {
    @Bindable var state: AppState
    @Bindable var chrome: LibraryChrome
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            LibraryBanners(state: state, chrome: chrome)
            LibraryContentSwitch(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background { LibraryShortcuts(chrome: chrome) }
        .toolbar { LibraryToolbar(state: state, chrome: chrome) }
        .searchable(text: $state.searchText, placement: .toolbar, prompt: Text(L.Shell.searchPrompt))
        .searchFocused($searchFocused)
        .onChange(of: chrome.searchFocusRequest) { searchFocused = true }
        .inspector(isPresented: $chrome.inspectorPresented) {
            LibraryInspector(state: state)
                .inspectorColumnWidth(min: 320, ideal: 380, max: 560)
        }
    }
}

/// Mail inbox, today list, card grid or empty state — and the window title for the section.
private struct LibraryContentSwitch: View {
    let state: AppState

    var body: some View {
        let section = state.sidebar
        let categories = state.snapshot?.categories ?? []
        let title = LibrarySections.title(section, categories: categories)
        Group {
            if section == .mail && state.searchText.isEmpty {
                MailInboxView(state: state)
                    .navigationSubtitle(L.Mail.subtitle(pending: state.mailSnapshot?.counts.pending ?? 0,
                                                        needsPDF: state.mailSnapshot?.counts.needsPDF ?? 0))
            } else if let snap = state.snapshot {
                if section == .today && state.searchText.isEmpty {
                    TodayView(state: state)
                        .navigationSubtitle(L.Shell.todaySubtitle(count: snap.today.count, minutes: snap.today.todayMinutes))
                } else {
                    let rows = state.visibleRows
                    Group {
                        if rows.isEmpty {
                            EmptyStateView(state: state, section: section)
                        } else {
                            CardGridView(state: state, rows: rows)
                        }
                    }
                    .navigationSubtitle(state.selection.isMulti
                                        ? L.Select.subtitle(papers: SharedStrings.papers(rows.count, L.lang),
                                                            selected: state.selection.targetIDs.count)
                                        : SharedStrings.papers(rows.count, L.lang))
                }
            } else {
                ProgressView(L.Shell.loading)
                    .controlSize(.large)
                    .navigationSubtitle("")
            }
        }
        .navigationTitle(title)
    }
}

private struct LibraryInspector: View {
    let state: AppState

    var body: some View {
        if state.sidebar == .mail {
            if let id = state.selectedMailID {
                MailDetailView(state: state, id: id)
                    .id(id)
            } else {
                ContentUnavailableView {
                    Label(L.Mail.detailEmptyTitle, systemImage: "envelope.open")
                } description: {
                    Text(L.Mail.detailEmptyHint)
                }
            }
        } else if state.selection.isMulti {
            MultiInspector(state: state)
        } else if let row = state.selectedRow {
            PaperDetailView(state: state, row: row)
                .id(row.id)
        } else {
            ContentUnavailableView {
                Label(L.Shell.inspectorEmptyTitle, systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(L.Shell.inspectorEmptyHint)
            }
        }
    }
}
