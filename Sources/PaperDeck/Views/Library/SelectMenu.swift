import SwiftUI
import PaperDeckCore

/// Toolbar ▸ Select ▾ (READING_ASSIST_PLAN §6.4 C1; DQ §5.2): Select All in "<section>" · Most
/// Recently Added ▸ 5 / 10 / 20 · Oldest Unread (by DDL) ▸ 5 / 10 / 20 / All · Recently Opened ▸
/// 5 / 10 · Deselect All. The picks are `SelectN` over the papers in the current view (sidebar
/// filter and search), so nothing hidden is selected. Disabled where cards can't be multi-selected
/// (Today, Mail). Owned by Slice C.
struct SelectMenu: View {
    let state: AppState

    var body: some View {
        let enabled = state.selection.supportsMulti && !state.visibleRows.isEmpty
        Menu {
            SelectMenuItems(state: state)
        } label: {
            Label(L.Select.menu, systemImage: "checkmark.circle")
        }
        .menuIndicator(.hidden)
        .disabled(!enabled)
        .help(state.selection.supportsMulti ? L.Select.menuHelp : L.Select.menuDisabledHint)
    }
}

/// The menu's items (also drawn as a plain list by the renders, which can't capture an open menu).
struct SelectMenuItems: View {
    let state: AppState

    var body: some View {
        let section = LibrarySections.title(state.sidebar, categories: state.snapshot?.categories ?? [])
        // No ⌘A shortcut here: ⌘A belongs to the focused text field, or to the focused grid
        // (CardGridView's `onCommand(selectAll:)`).
        Button(L.Select.allIn(section)) { state.selection.selectAllVisible() }
        Divider()
        kindMenu(.mostRecentlyAdded, counts: SelectN.counts, all: false)
        kindMenu(.oldestUnread, counts: SelectN.counts, all: true)
        kindMenu(.recentlyOpened, counts: [5, 10], all: false)
        Divider()
        Button(L.Select.none) { state.selection.clear() }
            .disabled(state.selectedPaperID == nil && state.selection.ids.isEmpty)
    }

    private func kindMenu(_ kind: SelectN.Kind, counts: [Int], all: Bool) -> some View {
        let available = state.selection.available(kind)
        return Menu(L.Select.kindTitle(kind)) {
            ForEach(counts, id: \.self) { n in
                Button(L.Select.count(n)) { state.selection.select(kind, n: n) }
            }
            if all {
                Divider()
                Button(L.Select.allCount(available)) { state.selection.select(kind, n: nil) }
            }
        }
        .disabled(available == 0)
    }
}
