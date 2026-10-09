import SwiftUI
import PaperDeckCore

// MARK: - Section names / symbols

/// Titles and SF Symbols of the sidebar sections (also the window title).
enum LibrarySections {
    static func title(_ item: SidebarItem, categories: [CategoryRow] = []) -> String {
        switch item {
        case .today: L.Shell.today
        case .toRead: L.Shell.toRead
        case .reading: L.Shell.reading
        case .done: L.Shell.done
        case .all: L.Shell.all
        case .needsAttention: L.Shell.needsAttention
        case .uncategorized: L.Shell.uncategorized
        case .recentlyDeleted: L.Shell.recentlyDeleted
        case .category(let pk): categories.first { $0.id == pk }?.category.name ?? L.Shell.categories
        case .mail: L.Mail.title
        }
    }

    static func symbol(_ item: SidebarItem) -> String {
        switch item {
        case .today: "sun.max"
        case .toRead: "tray.full"
        case .reading: "book"
        case .done: "checkmark.circle"
        case .all: "books.vertical"
        case .needsAttention: "exclamationmark.triangle"
        case .uncategorized: "square.dashed"
        case .recentlyDeleted: "trash"
        case .category: "circle.fill"
        case .mail: "envelope"
        }
    }
}

/// Per-section counts in one pass over the snapshot.
struct LibrarySidebarCounts: Equatable {
    var today = 0
    var overdue = 0
    var toRead = 0
    var reading = 0
    var needsAttention = 0
    var uncategorized = 0
    var deleted = 0

    init(_ snap: LibrarySnapshot?) {
        guard let snap else { return }
        today = snap.today.count
        overdue = snap.today.overdue.count
        for row in snap.rows {
            switch row.paper.status {
            case .toRead: toRead += 1
            case .reading: reading += 1
            case .done: break
            }
            if row.paper.categoryPK == nil { uncategorized += 1 }
        }
        needsAttention = snap.needsAttention.count
        deleted = snap.deleted.count
    }
}

// MARK: - Sidebar

/// §8 主窗口 sidebar: 邮件 ▸ 收件箱 | 今天 · 待读 · 在读 · 已读 · 全部 · 需要处理 | 分类 … 未分类 | 最近删除,
/// with the storage + Claude footer.
struct LibrarySidebarView: View {
    @Bindable var state: AppState
    @State private var editing: SidebarCategoryEdit?
    @State private var deleting: CategoryRow?

    var body: some View {
        let snap = state.snapshot
        let counts = LibrarySidebarCounts(snap)
        List(selection: selection) {
            Section {
                SidebarMailRow(counts: state.mailSnapshot?.counts).tag(SidebarItem.mail)
            } header: {
                Text(L.Mail.section)
            }

            Section {
                SidebarSectionRow(item: .today, count: counts.today, alert: counts.overdue > 0).tag(SidebarItem.today)
                SidebarSectionRow(item: .toRead, count: counts.toRead).tag(SidebarItem.toRead)
                SidebarSectionRow(item: .reading, count: counts.reading).tag(SidebarItem.reading)
                SidebarSectionRow(item: .done, count: nil).tag(SidebarItem.done)
                SidebarSectionRow(item: .all, count: nil).tag(SidebarItem.all)
                if counts.needsAttention > 0 {
                    SidebarSectionRow(item: .needsAttention, count: counts.needsAttention).tag(SidebarItem.needsAttention)
                }
                // Duplicates (n): only while reviews are open; it opens the list (not a section).
                if DedupeUIModel.isAvailable, state.dedupe.openCount > 0 {
                    SidebarDuplicatesRow(count: state.dedupe.openCount) { state.dedupe.showList() }
                }
            } header: {
                Text(L.Shell.sectionLibrary)
            }

            Section {
                ForEach(snap?.categories ?? []) { row in
                    SidebarCategoryRow(row: row)
                        .tag(SidebarItem.category(row.id))
                        .contextMenu {
                            Button(L.Shell.renameCategory) { editing = SidebarCategoryEdit(kind: .rename, category: row.category) }
                            Button(L.Shell.editCategoryDescription) { editing = SidebarCategoryEdit(kind: .describe, category: row.category) }
                            Divider()
                            Button(L.Shell.deleteCategory, role: .destructive) { deleting = row }
                        }
                }
                SidebarSectionRow(item: .uncategorized, count: counts.uncategorized).tag(SidebarItem.uncategorized)
            } header: {
                Text(L.Shell.categories)
            }

            Section {
                SidebarSectionRow(item: .recentlyDeleted, count: nil).tag(SidebarItem.recentlyDeleted)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LibrarySidebarFooter(state: state)
        }
        .sheet(item: $editing) { edit in
            CategoryEditSheet(edit: edit) { text in save(edit, text) }
        }
        .alert(deleting.map { L.Shell.deleteCategoryConfirmTitle($0.category.name) } ?? "",
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
               presenting: deleting) { row in
            Button(L.Shell.delete, role: .destructive) { delete(row) }
            Button(L.cancel, role: .cancel) {}
        } message: { row in
            Text(L.Shell.deleteCategoryConfirmBody(row.paperCount))
        }
        .onChange(of: state.sidebar, initial: true) { _, item in acknowledgeIfNew(item) }
        .task { state.dedupe.prepare() }                      // open duplicate reviews (once per launch)
        .onChange(of: snap?.categories.map(\.id)) { _, ids in
            // The open category was deleted (here or by a rebuild): fall back to 未分类.
            if case .category(let pk) = state.sidebar, let ids, !ids.contains(pk) { state.sidebar = .uncategorized }
        }
    }

    private var selection: Binding<SidebarItem?> {
        Binding(get: { state.sidebar }, set: { if let item = $0 { state.sidebar = item } })
    }

    // MARK: Actions

    /// Opening a NEW category acknowledges it (badge off).
    private func acknowledgeIfNew(_ item: SidebarItem) {
        guard case .category(let pk) = item,
              state.snapshot?.categories.first(where: { $0.id == pk })?.isNew == true else { return }
        state.perform { try await state.engine.acknowledgeCategory(pk: pk) }
    }

    private func save(_ edit: SidebarCategoryEdit, _ text: String) {
        let pk = edit.category.pk
        switch edit.kind {
        case .rename:
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != edit.category.name else { return }
            state.perform { _ = try await state.engine.renameCategory(pk: pk, name: name) }
        case .describe:
            state.perform { _ = try await state.engine.setCategoryDescription(pk: pk, text) }
        }
    }

    private func delete(_ row: CategoryRow) {
        let pk = row.id
        if state.sidebar == .category(pk) { state.sidebar = .uncategorized }
        state.perform { try await state.engine.deleteCategory(pk: pk) }
    }
}

// MARK: - Rows

private struct SidebarSectionRow: View {
    let item: SidebarItem
    let count: Int?
    var alert = false

    var body: some View {
        HStack(spacing: 6) {
            Label(LibrarySections.title(item), systemImage: LibrarySections.symbol(item))
            Spacer(minLength: 4)
            if let count { SidebarCountBadge(count: count, alert: alert) }
        }
    }
}

private struct SidebarCategoryRow: View {
    let row: CategoryRow

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(row.category.name).lineLimit(1).truncationMode(.tail)
            } icon: {
                Image(systemName: "circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(ChipPalette.color(hue: row.category.hue))
            }
            if row.isNew {
                Text(L.Shell.newBadge)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.blue))
                    .accessibilityLabel(L.Shell.newCategoryA11y)
            }
            Spacer(minLength: 4)
            SidebarCountBadge(count: row.paperCount, alert: false)
        }
        .help(row.category.description ?? row.category.name)
    }
}

/// Duplicates (n): the open duplicate reviews; a click opens their list (DQ §4.3).
private struct SidebarDuplicatesRow: View {
    let count: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Label(L.Dedupe.sidebarRow, systemImage: "square.on.square")
                Spacer(minLength: 4)
                SidebarCountBadge(count: count, alert: false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L.Dedupe.sidebarHelp(count))
    }
}

/// 邮件 ▸ 收件箱 with the pending count; red (with an envelope glyph, never colour alone) when
/// people sent reading requests.
private struct SidebarMailRow: View {
    let counts: MailCounts?

    var body: some View {
        let pending = counts?.pending ?? 0
        let requests = counts?.requests ?? 0
        HStack(spacing: 6) {
            Label(L.Mail.inbox, systemImage: requests > 0 ? "envelope.badge" : "envelope")
            Spacer(minLength: 4)
            SidebarCountBadge(count: pending, alert: requests > 0, alertSymbol: "envelope.fill",
                              alertLabel: L.Mail.badgeA11y(pending: pending, requests: requests),
                              plainLabel: L.Mail.badgeA11y(pending: pending, requests: 0))
        }
        .help(pending > 0 ? L.Mail.badgeA11y(pending: pending, requests: requests) : L.Mail.inbox)
    }
}

/// Trailing count; red capsule with `!` when something is overdue (never colour-only).
private struct SidebarCountBadge: View {
    let count: Int
    let alert: Bool
    var alertSymbol = "exclamationmark"
    var alertLabel: String?
    var plainLabel: String?

    var body: some View {
        if count > 0 {
            if alert {
                HStack(spacing: 2) {
                    Image(systemName: alertSymbol).font(.system(size: 8, weight: .heavy))
                    Text("\(count)")
                }
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .background(Capsule().fill(Color.red))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(alertLabel ?? L.Shell.overdueCount(count))
            } else {
                Text("\(count)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(plainLabel ?? L.Shell.count(count))
            }
        }
    }
}

// MARK: - Footer

extension LibrarySidebarView {
    /// `57 papers · 1.8 GB` / `0 篇 · 0字节`: the size in the UI language (`L.bytes`).
    static func footerTotals(count: Int, bytes: Int64) -> String {
        L.Shell.footerTotals(count: count, size: L.bytes(bytes))
    }
    static func footerShared(bytes: Int64) -> String { L.Shell.footerShared(L.bytes(bytes)) }
}

/// `57 篇 · 1.8 GB` + `约 320 MB 可能与原文件共享（估算）` + the AI (Claude / ChatGPT) status line.
private struct LibrarySidebarFooter: View {
    let state: AppState
    @State private var stats: StorageStats?

    var body: some View {
        let totals = state.snapshot?.totals
        let claude = ClaudePillStatus(state.agentStatus)
        VStack(alignment: .leading, spacing: 5) {
            if let totals {
                Text(LibrarySidebarView.footerTotals(count: totals.count, bytes: totals.logicalBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let shared = stats?.estimatedSharedBytes, shared > 0 {
                    Text(LibrarySidebarView.footerShared(bytes: shared))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Button { state.router.showSettings("ai") } label: {
                HStack(spacing: 5) {
                    ClaudePillDot(summary: claude).font(.caption)
                    Text(L.Shell.footerClaude(state.agentStatus.shownKind, claude.text))
                        .font(.caption)
                        .foregroundStyle(claude.needsAttention ? claude.color : .secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L.Shell.openAISettings)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .task(id: totals?.count) { await loadStats() }
    }

    /// Debounced on count changes (a 500-paper import changes it 500 times), then every 10 min.
    private func loadStats() async {
        guard state.snapshot != nil else { return }
        try? await Task.sleep(for: .seconds(stats == nil ? 0.5 : 3))
        while !Task.isCancelled {
            if let s = try? await state.engine.storage.stats(), !Task.isCancelled { stats = s }
            try? await Task.sleep(for: .seconds(600))
        }
    }

}

// MARK: - Category sheets

private struct SidebarCategoryEdit: Identifiable {
    enum Kind { case rename, describe }
    var kind: Kind
    var category: PaperCategory
    var id: String { "\(kind)-\(category.pk)" }
}

private struct CategoryEditSheet: View {
    let edit: SidebarCategoryEdit
    let onSave: (String) -> Void
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(edit: SidebarCategoryEdit, onSave: @escaping (String) -> Void) {
        self.edit = edit
        self.onSave = onSave
        _text = State(initialValue: edit.kind == .rename ? edit.category.name : (edit.category.description ?? ""))
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(ChipPalette.color(hue: edit.category.hue))
                Text(edit.kind == .rename ? L.Shell.renameCategoryTitle : L.Shell.categoryDescriptionTitle)
                    .font(.headline)
            }
            if edit.kind == .describe {
                Text(edit.category.name).font(.callout.weight(.medium))
                Text(L.Shell.categoryDescriptionHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(edit.kind == .rename ? L.Shell.categoryName : L.Shell.categoryDescriptionPlaceholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button(L.cancel, role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L.Shell.save, action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(edit.kind == .rename && trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func save() {
        guard edit.kind == .describe || !trimmed.isEmpty else { return }
        onSave(text)
        dismiss()
    }
}
