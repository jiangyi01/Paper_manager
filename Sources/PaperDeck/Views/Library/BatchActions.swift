import AppKit
import SwiftUI
import UniformTypeIdentifiers
import PaperDeckCore

// Batch actions on a multi-selection (READING_ASSIST_PLAN §6.4 C1; DQ §5.3–5.4), shared by the
// selection bar, the multi-inspector and the multi-paper context menu. Every change goes through
// `SelectionModel.apply` → `Engine.applyBatch` (one transaction, one undo toast). Nothing here
// starts AI on its own: "Read with AI…" asks first and then queues ordinary card jobs (agent.mode
// decides whether and where they run). Owned by Slice C.

/// The batch menus for `rows` (the selected visible papers, as drawn).
struct BatchMenus {
    let state: AppState
    let rows: [PaperRow]

    private var ids: [String] { rows.map(\.id) }
    private var selection: SelectionModel { state.selection }

    /// Every paper is in Recently Deleted (that view's own actions: restore, delete permanently).
    var allDeleted: Bool { !rows.isEmpty && rows.allSatisfy(\.paper.isDeleted) }
    /// The DDL items do nothing for papers marked done (like the single-paper menu).
    var allDone: Bool { rows.allSatisfy { $0.paper.status == .done } }

    // MARK: Menus (label + items)

    var statusMenu: some View {
        Menu { statusItems } label: { Label(L.cardsMenuStatus, systemImage: "circle.lefthalf.filled") }
    }

    var priorityMenu: some View {
        Menu { priorityItems } label: { Label(L.cardsMenuPriority, systemImage: "flag") }
    }

    var categoryMenu: some View {
        Menu { categoryItems } label: { Label(L.cardsMenuCategory, systemImage: "folder.badge.gearshape") }
    }

    var deadlineMenu: some View {
        Menu { deadlineItems } label: { Label(L.cardsMenuDeadline, systemImage: "calendar") }
            .disabled(allDone)
    }

    var tagsMenu: some View {
        Menu { tagItems } label: { Label(L.Select.tags, systemImage: "tag") }
    }

    var exportMenu: some View {
        Menu { exportItems } label: { Label(L.Select.export, systemImage: "square.and.arrow.up") }
    }

    // MARK: Items

    @ViewBuilder var statusItems: some View {
        ForEach(PaperStatus.allCases, id: \.self) { s in
            Toggle(L.cardsMenuStatusName(s), isOn: choice(rows.allSatisfy { $0.paper.status == s }) {
                selection.apply(.setStatus(s), ids: ids)
            })
        }
    }

    @ViewBuilder var priorityItems: some View {
        ForEach([Priority.high, .normal, .low], id: \.self) { p in
            Toggle(L.cardsMenuPriorityName(p), isOn: choice(rows.allSatisfy { $0.paper.priority == p }) {
                selection.apply(.setPriority(p), ids: ids)
            })
        }
    }

    @ViewBuilder var categoryItems: some View {
        ForEach(state.snapshot?.categories ?? []) { c in
            Toggle(c.category.name, isOn: choice(rows.allSatisfy { $0.paper.categoryPK == c.category.pk }) {
                selection.apply(.setCategory(c.category.pk), ids: ids)
            })
        }
        Divider()
        Toggle(L.cardsUncategorized, isOn: choice(rows.allSatisfy { $0.paper.categoryPK == nil }) {
            selection.apply(.setCategory(nil), ids: ids)
        })
    }

    @ViewBuilder var deadlineItems: some View {
        Button(L.cardsMenuPostponeDay) { selection.apply(.postponeDay, ids: ids) }
        Button(L.cardsMenuPostponeWeek) { selection.apply(.postponeWeek, ids: ids) }
        Button(L.cardsMenuSetDate) { BatchActions.pickDeadline(state, rows: rows) }
        Divider()
        Button(L.cardsMenuRestoreAuto) { selection.apply(.restoreAuto, ids: ids) }
        Button(L.cardsMenuUnschedule) { selection.apply(.unschedule, ids: ids) }
            .disabled(rows.allSatisfy { $0.paper.scheduleMode == .none })
    }

    @ViewBuilder var tagItems: some View {
        Button(L.Select.addTag) { BatchActions.addTag(state, rows: rows) }
        let present = BatchActions.visibleTags(rows)
        Menu(L.Select.removeTag) {
            if present.isEmpty {
                Text(L.Select.noTags)
            } else {
                ForEach(present, id: \.self) { tag in
                    Button(tag) { selection.apply(.removeTags([tag]), ids: ids) }
                }
            }
        }
        .disabled(present.isEmpty)
    }

    @ViewBuilder var exportItems: some View {
        ForEach(BatchExport.Format.allCases, id: \.self) { f in
            Button(L.Select.copyAs(f)) { BatchActions.export(state, rows: rows, format: f, toFile: false) }
        }
        Divider()
        ForEach(BatchExport.Format.allCases, id: \.self) { f in
            Button(L.Select.saveAs(f)) { BatchActions.export(state, rows: rows, format: f, toFile: true) }
        }
        Divider()
        Text(L.Select.exportNote)
    }

    /// Read / Re-read with AI… — always through the confirmation sheet, which also explains when AI
    /// reading is off and links to Settings. `short`: the selection bar's title (the help keeps the
    /// full one).
    func rereadButton(short: Bool = false) -> some View {
        Button { BatchActions.confirmReread(state, rows: rows) } label: {
            Label(short ? L.Select.readShort : BatchActions.rereadTitle(rows), systemImage: "sparkles")
        }
        .help(BatchActions.rereadTitle(rows))
    }

    /// Check for Duplicates (only once the duplicate check ships).
    @ViewBuilder var duplicatesButton: some View {
        if AssistRollout.dedupe {
            Button { state.dedupe.checkSelected(ids: ids) } label: {
                Label(L.Select.checkDuplicates, systemImage: "square.on.square")
            }
            .help(L.Select.checkDuplicates)
        }
    }

    func trashButton(short: Bool = false) -> some View {
        Button(role: .destructive) { selection.apply(.moveToTrash, ids: ids) } label: {
            Label(short ? L.Select.trashShort : L.Select.moveToTrash(rows.count), systemImage: "trash")
        }
        .help(L.Select.moveToTrash(rows.count))
    }

    func restoreButton(short: Bool = false) -> some View {
        Button { selection.apply(.restore, ids: ids) } label: {
            Label(short ? L.cardsMenuRestore : L.Select.restore(rows.count), systemImage: "arrow.uturn.backward")
        }
        .help(L.Select.restore(rows.count))
    }

    func deleteNowButton(short: Bool = false) -> some View {
        Button(role: .destructive) { BatchActions.confirmDeleteNow(state, rows: rows) } label: {
            Label(short ? L.cardsMenuDeleteNow : L.Select.deleteNow(rows.count), systemImage: "trash.slash")
        }
        .help(L.Select.deleteNow(rows.count))
    }

    var clearButton: some View {
        Button { selection.clear() } label: { Label(L.Select.clear, systemImage: "xmark") }
            .help(L.Select.clear)
    }

    /// Checkmark item: shows `isCurrent` (every selected paper has the value); choosing it runs `apply`.
    private func choice(_ isCurrent: Bool, _ apply: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { isCurrent }, set: { _ in if !isCurrent { apply() } })
    }
}

/// The context menu of a card that is part of a multi-selection: every item acts on the whole
/// selection ("Move 12 papers to Recently Deleted").
struct BatchContextMenu: View {
    let state: AppState
    let rows: [PaperRow]

    var body: some View {
        let menus = BatchMenus(state: state, rows: rows)
        Text(L.Select.selected(rows.count))
        if menus.allDeleted {
            menus.restoreButton()
            Button { CardActions.copy(BatchActions.titles(rows)) } label: { Label(L.Select.copyTitles, systemImage: "doc.on.doc") }
            Divider()
            menus.deleteNowButton()
        } else {
            if rows.count <= BatchActions.openLimit {
                Button { BatchActions.openPDFs(state, rows: rows) } label: {
                    Label(L.Select.openPDFs(rows.count), systemImage: "doc.richtext")
                }
            }
            Divider()
            menus.statusMenu
            menus.priorityMenu
            menus.deadlineMenu
            menus.categoryMenu
            menus.tagsMenu
            Divider()
            menus.rereadButton()
            AskAcrossButton(state: state, rows: rows)
            menus.duplicatesButton
            Divider()
            menus.exportMenu
            Button { CardActions.copy(BatchActions.titles(rows)) } label: { Label(L.Select.copyTitles, systemImage: "doc.on.doc") }
            Divider()
            menus.trashButton()
        }
        Divider()
        menus.clearButton
    }
}

// MARK: - Actions with their own UI (sheets, panels, alerts)

enum BatchActions {
    /// "Open N PDFs" is offered up to this many papers (the Paper menu's ⌘O too).
    static let openLimit = PaperCommandRules.openLimit

    static func rereadTitle(_ rows: [PaperRow]) -> String {
        rows.contains { $0.paper.card != nil } ? L.Select.reread(rows.count) : L.Select.read(rows.count)
    }

    /// The visible tags of the papers, sorted.
    static func visibleTags(_ rows: [PaperRow]) -> [String] {
        Array(Set(rows.flatMap { $0.tags.filter { $0.origin != .suppressed }.map(\.name) })).sorted()
    }

    static func titles(_ rows: [PaperRow]) -> String {
        rows.map { CardText.displayTitle($0.paper) }.joined(separator: "\n")
    }

    static func openPDFs(_ state: AppState, rows: [PaperRow]) {
        for row in rows.prefix(openLimit) where !row.paper.isDeleted { state.openPDF(row) }
    }

    /// Set Date… for every paper: the graphical date picker, then one pinned DDL batch.
    static func pickDeadline(_ state: AppState, rows: [PaperRow]) {
        let today = state.snapshot?.today.today ?? LocalDate.today()
        let ids = rows.map(\.id)
        let current = Set(rows.compactMap(\.paper.deadline)).count == 1 ? rows.first?.paper.deadline : nil
        CardSheetPresenter.present { close in
            CardDeadlinePickerSheet(title: L.Select.selected(rows.count), current: current, today: today,
                                    onCancel: close,
                                    onSet: { day in
                                        close()
                                        state.selection.apply(.pinDeadline(day), ids: ids)
                                    })
        }
    }

    /// Add Tag…: a name field with the library's frequent tags as suggestions.
    static func addTag(_ state: AppState, rows: [PaperRow]) {
        let ids = rows.map(\.id)
        let suggestions = frequentTags(state)
        CardSheetPresenter.present { close in
            BatchAddTagSheet(count: rows.count, suggestions: suggestions, onCancel: close) { tag in
                close()
                state.selection.apply(.addTags([tag]), ids: ids)
            }
        }
    }

    /// The ten most used visible tags in the library.
    static func frequentTags(_ state: AppState) -> [String] {
        var counts: [String: Int] = [:]
        for row in state.snapshot?.rows ?? [] {
            for t in row.tags where t.origin != .suppressed { counts[t.name, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(10).map(\.key)
    }

    /// Read / Re-read with AI…: the confirmation sheet; its default button queues the card jobs.
    /// Papers that wait for their own confirmation (possibly unpublished, under duplicate review,
    /// marked confidential or "Never use AI") are listed as left out first — the engine never
    /// queues them from a batch (`Engine.requestReread(paperIDs:)`), and a toast names any it held.
    static func confirmReread(_ state: AppState, rows: [PaperRow]) {
        let ids = rows.map(\.id)
        Task {
            let held = (try? await state.engine.rereadHolds(paperIDs: ids)) ?? []
            CardSheetPresenter.present { close in
                BatchRereadSheet(state: state, count: rows.count - held.count, held: held, onCancel: close) {
                    close()
                    state.perform {
                        let outcome = try await state.engine.requestReread(paperIDs: ids)
                        if let note = L.Select.rereadHeld(outcome.held) {
                            state.post(Toast(kind: .info, message: note))
                        }
                    }
                } onOpenSettings: {
                    close()
                    state.router.showSettings("ai")
                }
            }
        }
    }

    /// Delete N Permanently… (Recently Deleted) with the destructive confirmation alert.
    static func confirmDeleteNow(_ state: AppState, rows: [PaperRow]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L.Select.deleteNowTitle(rows.count)
        alert.informativeText = L.Select.deleteNowBody
        let confirm = alert.addButton(withTitle: L.cardsMenuDeleteNowConfirm)
        confirm.hasDestructiveAction = true
        alert.addButton(withTitle: L.cancel)
        let ids = rows.map(\.id)
        Task {
            let response: NSApplication.ModalResponse
            if let parent = CardSheetPresenter.parentWindow() {
                response = await alert.beginSheetModal(for: parent)
            } else {
                NSApp.activate()
                response = alert.runModal()
            }
            guard response == .alertFirstButtonReturn else { return }
            state.perform {
                for id in ids { try await state.engine.deleteNow(paperID: id) }
                if let f = state.selectedPaperID, ids.contains(f) { state.selection.clear() }
            }
        }
    }

    /// Export ▸ Copy as / Save as: metadata of the papers in the order drawn.
    static func export(_ state: AppState, rows: [PaperRow], format: BatchExport.Format, toFile: Bool) {
        let text = BatchExport.text(rows.map(BatchExport.Entry.init), format: format, calendar: state.engine.ctx.calendar)
        let n = rows.count
        guard toFile else {
            CardActions.copy(text)
            state.post(Toast(kind: .success, message: L.Select.copied(format, n)))
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = L.Select.exportFileName(n) + "." + format.fileExtension
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        let write: (URL) -> Void = { url in
            do {
                try BatchExport.fileData(text, format: format).write(to: url, options: .atomic)
                state.post(Toast(kind: .success, message: L.Select.saved(n, url.lastPathComponent)))
            } catch {
                state.post(Toast(kind: .error, message: L.Select.saveFailed))
            }
        }
        if let parent = CardSheetPresenter.parentWindow() {
            panel.beginSheetModal(for: parent) { if $0 == .OK, let url = panel.url { write(url) } }
        } else {
            NSApp.activate()
            panel.begin { if $0 == .OK, let url = panel.url { write(url) } }
        }
    }
}

// MARK: - Sheets

/// "Read N papers with Claude?" — the only way the batch reaches the AI queue. `count`: the papers
/// it would queue; `held`: the ones it leaves out (each needs its own confirmation).
struct BatchRereadSheet: View {
    let state: AppState
    let count: Int
    var held: [RereadHeld] = []
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onOpenSettings: () -> Void

    private var aiEnabled: Bool { state.settings.agentMode != AgentMode.off.rawValue }
    /// Every selected paper is held: nothing to confirm here.
    private var nothingToRead: Bool { count <= 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.purple)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(nothingToRead ? L.Select.rereadNothing : L.Select.rereadTitle(count)).font(.title3.weight(.semibold))
                    if aiEnabled {
                        if !nothingToRead {
                            Text(L.Shell.batchAIDetail).font(.callout).foregroundStyle(.secondary)
                            Text(L.Select.rereadDetail).font(.callout).foregroundStyle(.secondary)
                        }
                        if let note = L.Select.rereadHeld(held) {
                            Label(note, systemImage: "pause.circle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(L.Select.rereadOff).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L.cancel, action: onCancel).keyboardShortcut(.cancelAction)
                if aiEnabled {
                    Button(L.Select.rereadConfirm(count), action: onConfirm)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(nothingToRead)
                } else {
                    Button(L.Shell.openAISettings, action: onOpenSettings)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

/// Add Tag…: one tag for every selected paper.
struct BatchAddTagSheet: View {
    let count: Int
    let suggestions: [String]
    let onCancel: () -> Void
    let onAdd: (String) -> Void
    @State private var name = ""

    private var normalized: String? { Taxonomy.normalizeTag(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.Select.addTagTitle(count)).font(.headline)
            TextField(L.Select.tagPlaceholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if let t = normalized { onAdd(t) } }
            Text(name.isEmpty || normalized != nil ? L.Select.tagHint : L.Select.tagInvalid)
                .font(.caption)
                .foregroundStyle(name.isEmpty || normalized != nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            if !suggestions.isEmpty {
                Text(L.Select.frequentTags).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                FlowTagRow(tags: suggestions) { name = $0 }
            }
            HStack {
                Spacer()
                Button(L.cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(L.Select.add) { if let t = normalized { onAdd(t) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(normalized == nil)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// Suggested tags as small capsules (wrapping).
private struct FlowTagRow: View {
    let tags: [String]
    let pick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Button(tag) { pick(tag) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .lineLimit(1)
            }
        }
    }
}
