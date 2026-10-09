import AppKit
import SwiftUI
import PaperDeckCore

/// 阅读清单 in the inspector: progress header `3/7 · 剩 40′`, rows with checkbox, inline
/// editing (double-click), section chip `Fig. 2 · p.5` (opens the PDF), minutes, origin
/// mark, drag-to-reorder by the handle, context menu, and an add row (⌘Return).
///
/// Reordering is a plain SwiftUI drag gesture (no pasteboard): the library window's
/// DropHostingView owns the AppKit dragging-destination callbacks for PDF drops.
struct ChecklistView: View {
    let state: AppState
    let row: PaperRow

    init(state: AppState, row: PaperRow) {
        self.state = state
        self.row = row
    }

    private struct DragState: Equatable {
        var id: String
        var translation: CGFloat
        var locationY: CGFloat
    }

    // Optimistic UI until the next snapshot (or a failure) catches up.
    @State private var doneOverrides: [String: Bool] = [:]
    @State private var orderOverride: [String]?
    @State private var orderGeneration = 0

    @State private var editingID: String?
    @State private var hoveredID: String?
    @State private var drag: DragState?
    @State private var frames: [String: CGRect] = [:]

    @State private var newText = ""
    @State private var newMinutes = 10
    @FocusState private var addFieldFocused: Bool

    private static let minuteChoices = [5, 10, 15, 20, 30, 45, 60]
    private var readOnly: Bool { row.paper.isDeleted }

    private var items: [ChecklistItem] {
        guard let order = orderOverride else { return row.checklist }
        let byID = Dictionary(row.checklist.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let known = Set(order)
        return order.compactMap { byID[$0] } + row.checklist.filter { !known.contains($0.id) }
    }

    private func isDone(_ item: ChecklistItem) -> Bool { doneOverrides[item.id] ?? item.isDone }

    var body: some View {
        let items = self.items
        VStack(alignment: .leading, spacing: 8) {
            if !items.isEmpty { header(items) }
            if items.isEmpty {
                DetailPlaceholder(text: readOnly ? L.Detail.checklistEmptyReadOnly : L.Detail.checklistEmpty)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        rowView(item, in: items)
                    }
                }
                .coordinateSpace(.named("detail.checklist"))
                .overlay(alignment: .topLeading) { insertionMarker(items) }
            }
            if !readOnly { addRow }
        }
        .onChange(of: row.checklist) { _, new in reconcile(new) }
    }

    // MARK: Header

    private func header(_ items: [ChecklistItem]) -> some View {
        let done = items.count(where: { isDone($0) })
        let remaining = items.reduce(0) { $0 + (isDone($1) ? 0 : max(0, $1.minutes)) }
        return HStack(spacing: 8) {
            ProgressRing(done: done, total: items.count)
                .frame(width: 16, height: 16)
            Text(L.Detail.checklistProgress(done: done, total: items.count, remaining: remaining))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Rows

    @ViewBuilder private func rowView(_ item: ChecklistItem, in items: [ChecklistItem]) -> some View {
        let dragging = drag?.id == item.id
        Group {
            if editingID == item.id {
                DetailChecklistEditor(item: item,
                                      onCommit: { text, section, minutes in commitEdit(item, text, section, minutes) },
                                      onCancel: { editingID = nil })
            } else {
                rowContent(item)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(dragging ? AnyShapeStyle(.background) : (hoveredID == item.id ? AnyShapeStyle(.quinary) : AnyShapeStyle(Color.clear)))
                .shadow(color: .black.opacity(dragging ? 0.18 : 0), radius: 6, y: 2)
        }
        .onHover { inside in
            if inside { hoveredID = item.id } else if hoveredID == item.id { hoveredID = nil }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("detail.checklist")) } action: { frame in
            frames[item.id] = frame
        }
        .offset(y: dragging ? (drag?.translation ?? 0) : 0)
        .zIndex(dragging ? 1 : 0)
        .contextMenu {
            if !readOnly { contextMenu(item, in: items) }
        }
    }

    private func rowContent(_ item: ChecklistItem) -> some View {
        let done = isDone(item)
        return HStack(alignment: .top, spacing: 8) {
            Button { toggle(item) } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(done ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(readOnly)
            .help(done ? L.Detail.markNotDone : L.Detail.markDone)
            .accessibilityLabel(item.text)
            .accessibilityValue(done ? L.Detail.itemDone : L.Detail.itemNotDone)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.text)
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if !readOnly { editingID = item.id } }
                    .help(readOnly ? "" : L.Detail.doubleClickToEdit)
                HStack(spacing: 6) {
                    if let locator = DetailFormat.locator(section: item.section, page: item.page) {
                        Button { state.openPDF(row, page: item.page) } label: {
                            Text(verbatim: locator)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .disabled(readOnly)
                        .help(item.page.map { L.Detail.openPDFAtPage($0) } ?? L.Detail.openPDF)
                    }
                    Text(L.Detail.minutes(item.minutes))
                        .monospacedDigit()
                    originMark(item)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !readOnly { dragHandle(item) }
        }
    }

    private func originMark(_ item: ChecklistItem) -> some View {
        let (icon, help): (String, String) = switch item.origin {
        case .heuristic: ("wand.and.rays", L.Detail.originHeuristic)
        case .agent: ("sparkles", L.Detail.originAgent)
        case .user: ("person", L.Detail.originUser)
        }
        let edited = item.userEdited && item.origin != .user
        return HStack(spacing: 2) {
            Image(systemName: icon)
            if edited { Image(systemName: "pencil") }
        }
        .imageScale(.small)
        .foregroundStyle(.tertiary)
        .help(edited ? help + L.Detail.originEditedSuffix : help)
        .accessibilityLabel(edited ? help + L.Detail.originEditedSuffix : help)
    }

    private func dragHandle(_ item: ChecklistItem) -> some View {
        let active = hoveredID == item.id || drag?.id == item.id
        return Image(systemName: "line.3.horizontal")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(width: 16, height: 18)
            .contentShape(Rectangle())
            .opacity(active ? 1 : 0.35)
            .pointerStyle(drag?.id == item.id ? .grabActive : .grabIdle)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("detail.checklist"))
                    .onChanged { v in
                        drag = DragState(id: item.id, translation: v.translation.height, locationY: v.location.y)
                    }
                    .onEnded { v in finishDrag(item.id, locationY: v.location.y) }
            )
            .help(L.Detail.dragToReorder)
            .accessibilityHidden(true)
    }

    @ViewBuilder private func contextMenu(_ item: ChecklistItem, in items: [ChecklistItem]) -> some View {
        let index = items.firstIndex { $0.id == item.id } ?? 0
        Button(isDone(item) ? L.Detail.markNotDone : L.Detail.markDone) { toggle(item) }
        Button(L.Detail.editItem) { editingID = item.id }
        Menu(L.Detail.itemMinutesMenu) {
            ForEach(Self.minuteChoices, id: \.self) { m in
                Button(L.Detail.minutes(m)) { setMinutes(item, m) }
                    .disabled(m == item.minutes)
            }
        }
        Divider()
        Button(L.Detail.moveUp) { move(item.id, from: index, to: index - 1) }
            .disabled(index == 0)
        Button(L.Detail.moveDown) { move(item.id, from: index, to: index + 1) }
            .disabled(index >= items.count - 1)
        if item.section != nil || item.page != nil {
            Divider()
            Button(item.page.map { L.Detail.openPDFAtPage($0) } ?? L.Detail.openPDF) { state.openPDF(row, page: item.page) }
        }
        Divider()
        Button(L.Detail.deleteItem, role: .destructive) { delete(item) }
    }

    // MARK: Drag to reorder

    /// Index in the list *without* the dragged item (what `moveChecklistItem(toIndex:)` expects).
    private func targetIndex(for id: String, locationY: CGFloat, in items: [ChecklistItem]) -> Int {
        items.filter { $0.id != id }.count(where: { (frames[$0.id]?.midY ?? .infinity) < locationY })
    }

    @ViewBuilder private func insertionMarker(_ items: [ChecklistItem]) -> some View {
        if let drag, let from = items.firstIndex(where: { $0.id == drag.id }) {
            let others = items.filter { $0.id != drag.id }
            let target = targetIndex(for: drag.id, locationY: drag.locationY, in: items)
            if target != from, !others.isEmpty {
                let y = target == 0 ? (frames[others[0].id]?.minY ?? 0) : (frames[others[target - 1].id]?.maxY ?? 0)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 4)
                    .offset(y: y - 1)
                    .allowsHitTesting(false)
            }
        }
    }

    private func finishDrag(_ id: String, locationY: CGFloat) {
        let current = items
        defer { drag = nil }
        guard let from = current.firstIndex(where: { $0.id == id }) else { return }
        move(id, from: from, to: targetIndex(for: id, locationY: locationY, in: current))
    }

    /// Moves an item (drag, 上移/下移); optimistic, then `moveChecklistItem` (marks user_edited).
    private func move(_ id: String, from: Int, to target: Int) {
        let current = items
        guard target != from, target >= 0, target < current.count else { return }
        var order = current.map(\.id)
        order.remove(at: from)
        order.insert(id, at: target)
        withAnimation(.snappy(duration: 0.2)) { orderOverride = order }
        orderGeneration += 1
        let generation = orderGeneration
        let paperID = row.id
        state.detailRun({ _ = try await state.engine.moveChecklistItem(paperID: paperID, itemID: id, toIndex: target) },
                        onError: { orderOverride = nil })
        // Safety net: never keep a local order the snapshot doesn't confirm.
        Task {
            try? await Task.sleep(for: .seconds(4))
            if orderGeneration == generation { orderOverride = nil }
        }
    }

    /// Drops optimistic state the snapshot has confirmed.
    private func reconcile(_ new: [ChecklistItem]) {
        let actual = Dictionary(new.map { ($0.id, $0.isDone) }, uniquingKeysWith: { a, _ in a })
        doneOverrides = doneOverrides.filter { id, value in actual[id].map { $0 != value } ?? false }
        if let order = orderOverride, new.map(\.id) == order.filter({ actual[$0] != nil }) {
            orderOverride = nil
        }
        if let editing = editingID, actual[editing] == nil { editingID = nil }
    }

    // MARK: Operations

    private func toggle(_ item: ChecklistItem) {
        guard !readOnly else { return }
        let id = item.id
        doneOverrides[id] = !isDone(item)
        state.toggleChecklistItem(paperID: row.id, itemID: id)
        Task {
            try? await Task.sleep(for: .seconds(4))
            doneOverrides[id] = nil
        }
    }

    private func commitEdit(_ item: ChecklistItem, _ text: String, _ section: String?, _ minutes: Int) {
        editingID = nil
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = section?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let section: String? = trimmed.isEmpty ? nil : trimmed
        guard !text.isEmpty else { return }
        guard text != item.text || section != item.section || minutes != item.minutes else { return }
        let paperID = row.id
        state.perform {
            _ = try await state.engine.editChecklistItem(paperID: paperID, itemID: item.id, text: text,
                                                         section: section, minutes: minutes)
        }
    }

    private func setMinutes(_ item: ChecklistItem, _ minutes: Int) {
        let paperID = row.id
        state.perform {
            _ = try await state.engine.editChecklistItem(paperID: paperID, itemID: item.id, text: item.text,
                                                         section: item.section, minutes: minutes)
        }
    }

    private func delete(_ item: ChecklistItem) {
        let paperID = row.id
        state.perform { try await state.engine.deleteChecklistItem(paperID: paperID, itemID: item.id) }
    }

    // MARK: Add row

    private var addRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.tertiary)
                .frame(width: 18)
            TextField(L.Detail.addItemPlaceholder, text: $newText)
                .textFieldStyle(.plain)
                .focused($addFieldFocused)
                .onSubmit(addItem)
            Menu {
                ForEach(Self.minuteChoices, id: \.self) { m in
                    Button(L.Detail.minutes(m)) { newMinutes = m }
                }
            } label: {
                Text(L.Detail.minutes(newMinutes)).monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L.Detail.itemMinutesMenu)
            Button(L.Detail.add) {
                if newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    addFieldFocused = true
                } else {
                    addItem()
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .controlSize(.small)
            .help(L.Detail.addItemHelp)
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(addFieldFocused ? AnyShapeStyle(Color.accentColor.opacity(0.6)) : AnyShapeStyle(.separator),
                              style: StrokeStyle(lineWidth: 1, dash: addFieldFocused ? [] : [3, 2]))
        }
    }

    private func addItem() {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        newText = ""
        let paperID = row.id, minutes = newMinutes
        state.perform { _ = try await state.engine.addChecklistItem(paperID: paperID, text: text, minutes: minutes) }
        addFieldFocused = true
    }
}

// MARK: - Inline editor

/// Double-click editor: text, locator (`Fig. 2`), minutes. Return saves, Esc cancels.
private struct DetailChecklistEditor: View {
    let item: ChecklistItem
    let onCommit: (_ text: String, _ section: String?, _ minutes: Int) -> Void
    let onCancel: () -> Void

    private enum Field: Hashable { case text, section }

    @State private var text: String
    @State private var section: String
    @State private var minutes: Int
    @FocusState private var focus: Field?

    init(item: ChecklistItem, onCommit: @escaping (String, String?, Int) -> Void, onCancel: @escaping () -> Void) {
        self.item = item
        self.onCommit = onCommit
        self.onCancel = onCancel
        _text = State(initialValue: item.text)
        _section = State(initialValue: item.section ?? "")
        _minutes = State(initialValue: item.minutes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(L.Detail.itemTextPlaceholder, text: $text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .text)
                .onSubmit(commit)
            HStack(spacing: 8) {
                TextField(L.Detail.itemSectionPlaceholder, text: $section)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 110)
                    .focused($focus, equals: .section)
                    .onSubmit(commit)
                Stepper(value: $minutes, in: 1...600, step: 5) {
                    Text(L.Detail.minutes(minutes)).monospacedDigit()
                }
                Spacer(minLength: 0)
                Button(L.cancel, action: onCancel)
                Button(L.Detail.save, action: commit)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
            .font(.callout)
        }
        .onAppear { Task { @MainActor in focus = .text } }
        .onExitCommand(perform: onCancel)
    }

    private func commit() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onCommit(text, section, minutes)
    }
}
