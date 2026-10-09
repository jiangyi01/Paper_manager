import AppKit
import Foundation
import Observation
import PaperDeckCore

/// Multi-select in the library (READING_ASSIST_PLAN §4, §6.4 C1, §7 "Selection"; DQ §5.1): UI
/// state only, no schema. The focused paper (the normal inspector) stays `AppState.selectedPaperID`;
/// `ids` is the set for batch actions. The rules are the pure `SelectionLogic` (Core); this model
/// stores the state and runs the batch actions. `AppState.selection`. Owned by Slice C.
///
/// - 0 or 1 paper: the app as before (the normal inspector, single-paper menus).
/// - 2 or more visible papers: the selection bar over the grid, the multi-inspector, menus that act
///   on all of them. Batch actions only ever reach the selected papers that are visible.
/// - Selecting never starts AI; "Read with AI…" asks first (`BatchActions.confirmReread`).
@Observable
final class SelectionModel {
    /// The UI ships (gestures, Select menu, selection bar). Slice C, milestone C1.
    static let isAvailable = true
    /// Offscreen renders and the gesture probe only (`--render … --select-only`): draws the
    /// multi-select UI before it ships. Never set by the app.
    static var previewOverride = false
    /// Multi-select is on in this process (shipped, or a render).
    static var isOn: Bool { isAvailable || previewOverride }

    /// The selected paper ids (0 or 1: the normal single selection; ≥ 2: the selection bar).
    var ids: Set<String> = []
    /// Where a ⇧-click range starts.
    var anchor: String?
    /// The focus this model last set. A different `selectedPaperID` was set by someone else (a
    /// toast's [View], the router, Today, the menu bar): that paper alone is then the selection.
    @ObservationIgnored private var committedFocus: String?
    @ObservationIgnored private weak var state: AppState?
    /// The grid's sections for `AppState.rowsGeneration` (computed once per refresh / view change,
    /// not on every read: the grid, the subtitle, the inspector and the selection bar all ask).
    @ObservationIgnored private var sectionsCache: (generation: Int, rows: [[PaperRow]], ids: [[String]])?

    init() {}

    /// Called once by `AppState.init`.
    func attach(_ state: AppState) { self.state = state }

    // MARK: Reading

    /// The focused paper (`AppState.selectedPaperID`).
    var focused: String? { state?.selectedPaperID }

    /// The current view lists papers that can be multi-selected: the card grid (not Today's plan,
    /// not the Mail inbox).
    var supportsMulti: Bool {
        guard Self.isOn, let state else { return false }
        return state.sidebar != .today && state.sidebar != .mail
    }

    /// The pure state (`SelectionLogic`). A focus set from outside collapses the selection to it.
    var current: SelectionState {
        let f = focused
        guard f == committedFocus else { return SelectionState(ids: f.map { [$0] } ?? [], focused: f, anchor: f) }
        return SelectionState(ids: ids, focused: f, anchor: anchor)
    }

    /// The visible ids as the grid draws them (the To Read DDL groups flattened).
    var order: [String] { sections.flatMap { $0 } }

    /// The grid's sections as drawn.
    var sections: [[String]] { cachedSections?.ids ?? [] }

    /// The grid's sections (rows and ids), cached per `AppState.rowsGeneration`. `visibleRows` is
    /// read every time, so each reader still observes the snapshot, the section, search and sort.
    private var cachedSections: (rows: [[PaperRow]], ids: [[String]])? {
        guard let state else { return nil }
        let visible = state.visibleRows
        let generation = state.rowsGeneration
        if let c = sectionsCache, c.generation == generation { return (c.rows, c.ids) }
        let rows = CardGridLayout.sections(visible, state: state)
        let ids = rows.map { $0.map(\.id) }
        sectionsCache = (generation, rows, ids)
        return (rows, ids)
    }

    /// The selected visible papers, as drawn — what every batch action applies to.
    var targetIDs: [String] {
        guard supportsMulti else { return focused.map { [$0] } ?? [] }
        return SelectionLogic.selected(in: order, current)
    }

    /// `targetIDs` as rows.
    var targetRows: [PaperRow] {
        let wanted = Set(targetIDs)
        guard !wanted.isEmpty, let rows = cachedSections?.rows else { return [] }
        return rows.flatMap { $0 }.filter { wanted.contains($0.id) }
    }

    /// ≥ 2 papers: the selection bar and the multi-inspector.
    var isMulti: Bool { supportsMulti && targetIDs.count >= 2 }

    /// The card is drawn selected (the focused one, or one of a multi-selection).
    func isSelected(_ id: String) -> Bool {
        let s = SelectionLogic.normalized(current)
        return supportsMulti ? s.ids.contains(id) : s.focused == id
    }

    /// The context menu of the card `id` acts on the whole selection (it is part of a multi-selection);
    /// otherwise on that card alone, like Finder. Cheap (asked per card): no visible-rows pass — a view
    /// change prunes the selection to the visible papers right away (`prune`).
    func menuActsOnSelection(_ id: String) -> Bool {
        guard supportsMulti else { return false }
        let s = SelectionLogic.normalized(current)
        return s.ids.count >= 2 && s.ids.contains(id)
    }

    // MARK: Changing it

    /// A click on a card. `order` = the visible ids as drawn.
    func click(_ id: String, kind: SelectionClick, order: [String]? = nil) {
        guard supportsMulti else { state?.selectedPaperID = id; return }
        commit(SelectionLogic.click(id, kind, order: order ?? self.order, current))
    }

    /// Edit ▸ Select ▸ All Papers, ⌘A in the grid, Select ▾ ▸ Select All: every visible paper.
    func selectAllVisible() {
        guard supportsMulti else { return }
        commit(SelectionLogic.selectAll(order: order, current))
    }

    /// Select ▾ ▸ N most recently added / oldest unread / recently opened (nil: every match).
    func select(_ kind: SelectN.Kind, n: Int?) {
        guard supportsMulti, let state else { return }
        let picked = SelectN.pick(kind, n: n, from: state.visibleRows.map(\.paper), recentOpens: recentOpens)
        commit(SelectionLogic.select(picked, order: order, current))
    }

    /// How many papers Select ▾ ▸ `kind` can pick in this view (0: disabled).
    func available(_ kind: SelectN.Kind) -> Int {
        guard let state else { return 0 }
        return SelectN.available(kind, from: state.visibleRows.map(\.paper), recentOpens: recentOpens)
    }

    /// Edit ▸ Select ▸ Deselect All, Esc in the grid, a click on empty space, the bar's ✕: nothing
    /// selected (the inspector shows its empty state).
    func clear() {
        if !ids.isEmpty { ids = [] }
        anchor = nil
        committedFocus = nil
        if state?.selectedPaperID != nil { state?.selectedPaperID = nil }
    }

    /// The multi-inspector's [Show only this paper]: that paper alone.
    func showOnly(_ id: String) {
        commit(SelectionState(ids: [id], focused: id, anchor: id))
    }

    /// Moves the focus to `id` and keeps the selection (another paper: that paper alone).
    func focus(_ id: String) {
        let s = current
        commit(s.ids.contains(id) ? SelectionState(ids: s.ids, focused: id, anchor: id) : SelectionState(ids: [id], focused: id, anchor: id))
    }

    /// The multi-inspector's [−]: that paper leaves the selection.
    func deselect(_ id: String) {
        guard supportsMulti else { return }
        commit(SelectionLogic.click(id, .toggle, order: order, current))
    }

    /// An arrow key in the focused grid (⇧: extend from the anchor).
    func move(_ direction: GridDirection, columns: Int, extend: Bool) {
        guard supportsMulti else { return }
        commit(SelectionLogic.move(current, direction, columns: columns, sections: sections, extend: extend))
    }

    /// The visible rows changed (section, search, refresh): selected papers that left the view drop out.
    func prune() {
        guard supportsMulti else { return }
        commit(SelectionLogic.prune(current, visible: order))
    }

    /// `selectedPaperID` was set (maybe from outside the grid: a toast, the router, Today, the menu
    /// bar): a focus outside the selection collapses it to that paper.
    func focusDidChange() {
        commit(SelectionLogic.normalized(current))
    }

    private func commit(_ next: SelectionState) {
        if ids != next.ids { ids = next.ids }
        if anchor != next.anchor { anchor = next.anchor }
        committedFocus = next.focused
        if let state, state.selectedPaperID != next.focused { state.selectedPaperID = next.focused }
    }

    private var recentOpens: [String] {
        state?.engine.recentOpens.recent().map(\.paperID) ?? []
    }

    // MARK: Batch actions

    /// Runs `op` on the selected visible papers (one transaction, one undo token; the engine
    /// announces it and `didApply` shows the toast). `ids` overrides the target (the context menu).
    func apply(_ op: BatchOperation, ids explicit: [String]? = nil) {
        guard let state else { return }
        let targets = explicit ?? targetIDs
        guard !targets.isEmpty else { return }
        state.perform { [weak self] in
            let outcome = try await state.engine.applyBatch(op, paperIDs: targets)
            if op == .moveToTrash || op == .restore {
                // The papers left this view; the next refresh would prune them anyway.
                if let f = state.selectedPaperID, outcome.applied.contains(f) { self?.clear() }
            }
            if !outcome.skipped.isEmpty {
                if op.isSchedule {
                    state.post(Toast(kind: .info, message: L.Select.skippedDone(outcome.skipped.count)))
                } else if op == .restore {
                    state.post(Toast(kind: .warning, message: L.Select.skippedRestore(outcome.skipped.count)))
                }
            }
        }
    }

    /// `EngineEvent.batchApplied`: a batch committed — one toast, with [Undo] when it can be undone.
    func didApply(_ notice: BatchNotice) {
        guard let state, !notice.paperIDs.isEmpty else { return }
        state.post(Self.toast(for: notice))
    }

    /// The toast for a committed batch.
    static func toast(for notice: BatchNotice) -> Toast {
        let message = L.Select.applied(notice.operation, notice.paperIDs.count)
        guard let token = notice.undoToken else {
            return Toast(id: "batch-" + UUID().uuidString.lowercased(), kind: .success, message: message)
        }
        return Toast(id: "batch-" + token, kind: .success, message: message,
                     buttons: [Toast.Button(title: L.Select.undo, action: .undo(token: token))])
    }
}
