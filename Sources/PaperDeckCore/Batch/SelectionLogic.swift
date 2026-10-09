import Foundation

// Multi-select in the library grid as pure values (DQ §5.1; READING_ASSIST_PLAN §6.4 C1, §7
// "Selection"). The App's `SelectionModel` keeps one `SelectionState` and asks these functions for
// the next one; nothing here touches the database. Owned by Slice C.

/// The grid's selection. `focused` is the paper the normal inspector shows
/// (`AppState.selectedPaperID`); other code may set it on its own (router, toasts, Today), which
/// collapses a multi-selection — see `SelectionLogic.normalized`.
package struct SelectionState: Sendable, Equatable {
    /// Selected ids. Empty or `[focused]`: a single selection; two or more: the selection bar.
    package var ids: Set<String>
    package var focused: String?
    /// Where a ⇧-range starts (the last plainly clicked or ⌘-clicked card).
    package var anchor: String?

    package init(ids: Set<String> = [], focused: String? = nil, anchor: String? = nil) {
        self.ids = ids; self.focused = focused; self.anchor = anchor
    }

    package static let empty = SelectionState()
}

/// How a click changes the selection (from the event's modifier keys).
package enum SelectionClick: Sendable, Equatable {
    /// Select only this card.
    case plain
    /// ⌘-click: add or remove this card.
    case toggle
    /// ⇧-click: the cards from the anchor to this one, in the order the grid draws them.
    case range
    /// ⌘⇧-click: that range added to the selection.
    case addRange

    package static func from(command: Bool, shift: Bool) -> SelectionClick {
        switch (command, shift) {
        case (true, true): return .addRange
        case (false, true): return .range
        case (true, false): return .toggle
        case (false, false): return .plain
        }
    }
}

/// Arrow keys in the grid.
package enum GridDirection: Sendable, Equatable, CaseIterable {
    case left, right, up, down
}

package enum SelectionLogic {
    /// The state with its invariant restored: the focused paper is always selected, and a focus set
    /// from outside the grid (a toast's [View], the router, the Today list) that isn't part of the
    /// selection collapses it to that one paper. No focus → nothing selected.
    package static func normalized(_ s: SelectionState) -> SelectionState {
        guard let f = s.focused else { return .empty }
        if s.ids.contains(f) { return s }
        return SelectionState(ids: [f], focused: f, anchor: f)
    }

    /// The selected ids that are in `order` (the visible rows, as drawn), in that order. Batch
    /// actions use only these, so nothing hidden by a filter or a search is changed by surprise.
    package static func selected(in order: [String], _ s: SelectionState) -> [String] {
        let n = normalized(s)
        guard !n.ids.isEmpty else { return [] }
        return order.filter(n.ids.contains)
    }

    /// Two or more visible papers selected (the selection bar and the multi-inspector).
    package static func isMulti(in order: [String], _ s: SelectionState) -> Bool {
        selected(in: order, s).count >= 2
    }

    /// The multi-inspector's paper list: the first `limit` items and how many more there are (a ⌘A
    /// over thousands of papers draws `limit` rows and a "+N more" line, not one row per paper).
    package static func capped<T>(_ items: [T], limit: Int) -> (shown: [T], more: Int) {
        let n = max(0, limit)
        guard items.count > n else { return (items, 0) }
        return (Array(items.prefix(n)), items.count - n)
    }

    /// One click on the card `id`. `order` = every visible id in the order the grid draws them
    /// (the To Read DDL groups flattened).
    package static func click(_ id: String, _ kind: SelectionClick, order: [String],
                              _ current: SelectionState) -> SelectionState {
        let s = normalized(current)
        switch kind {
        case .plain:
            return SelectionState(ids: [id], focused: id, anchor: id)
        case .toggle:
            var out = s
            if out.ids.contains(id) {
                out.ids.remove(id)
                if out.ids.isEmpty { return .empty }
                if out.focused == id { out.focused = neighbour(of: id, in: order, among: out.ids) }
                out.anchor = out.focused
            } else {
                out.ids.insert(id)
                out.focused = id
                out.anchor = id
            }
            return out
        case .range, .addRange:
            guard let anchor = s.anchor ?? s.focused,
                  let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) else {
                // No usable anchor (nothing selected yet, or it is hidden now): a plain click.
                return kind == .range ? SelectionState(ids: [id], focused: id, anchor: id)
                                      : click(id, .toggle, order: order, s)
            }
            let span = Set(order[min(a, b)...max(a, b)])
            return SelectionState(ids: kind == .range ? span : s.ids.union(span), focused: id, anchor: anchor)
        }
    }

    /// Edit ▸ Select All (⌘A) / Select ▸ All Papers: every visible card. The focused paper stays
    /// when it is visible, else the first card.
    package static func selectAll(order: [String], _ current: SelectionState) -> SelectionState {
        guard !order.isEmpty else { return normalized(current) }
        let focus = current.focused.flatMap { order.contains($0) ? $0 : nil } ?? order[0]
        return SelectionState(ids: Set(order), focused: focus, anchor: focus)
    }

    /// Select ▸ N most recently added / oldest unread / recently opened: exactly `picked` (those
    /// that are visible), focused on the first one as drawn. Nothing picked → unchanged.
    package static func select(_ picked: [String], order: [String], _ current: SelectionState) -> SelectionState {
        let wanted = Set(picked)
        guard let first = order.first(where: wanted.contains) else { return normalized(current) }
        return SelectionState(ids: wanted.intersection(order), focused: first, anchor: first)
    }

    /// The visible rows changed (sidebar section, search, a refresh): selected papers that left
    /// the view are dropped. A single selection is never changed (the inspector keeps showing a
    /// paper the router selected before it switched the section — today's behaviour); a
    /// multi-selection left with one visible paper becomes that paper.
    package static func prune(_ current: SelectionState, visible order: [String]) -> SelectionState {
        let s = normalized(current)
        guard s.ids.count >= 2 else { return s }
        let keep = s.ids.intersection(order)
        if keep.count >= 2 {
            guard keep != s.ids else { return s }
            var out = s
            out.ids = keep
            if let f = out.focused, !keep.contains(f) { out.focused = order.first(where: keep.contains) }
            if let a = out.anchor, !keep.contains(a) { out.anchor = out.focused }
            return out
        }
        if let f = s.focused, keep.contains(f) || keep.isEmpty {
            return SelectionState(ids: [f], focused: f, anchor: f)
        }
        let only = keep.first!
        return SelectionState(ids: [only], focused: only, anchor: only)
    }

    /// An arrow key: the next card in that direction becomes the selection (with ⇧: the range from
    /// the anchor to it). `sections` = the grid's sections as drawn, `columns` its column count.
    package static func move(_ current: SelectionState, _ direction: GridDirection, columns: Int,
                             sections: [[String]], extend: Bool) -> SelectionState {
        let s = normalized(current)
        let order = sections.flatMap { $0 }
        guard let target = GridNav.move(from: s.focused, direction, columns: columns, sections: sections) else { return s }
        return click(target, extend ? .range : .plain, order: order, s)
    }

    /// After ⌘-deselecting the focused card: the next selected card after it as drawn, else the
    /// closest one before it (any selected card when `id` isn't drawn).
    static func neighbour(of id: String, in order: [String], among ids: Set<String>) -> String? {
        if let i = order.firstIndex(of: id) {
            if let next = order[(i + 1)...].first(where: ids.contains) { return next }
            if let previous = order[..<i].last(where: ids.contains) { return previous }
        }
        return order.first(where: ids.contains) ?? ids.sorted().first
    }
}

/// Arrow-key navigation over the card grid (pure). The grid is `LazyVGrid(.adaptive(minimum:
/// 260, maximum: 340), spacing: 16)` with 20 pt side padding, split into sections (the To Read DDL
/// groups) that each start a new row.
package enum GridNav {
    /// The adaptive grid's column count for a content width.
    package static func columns(width: Double, minimum: Double = 260, spacing: Double = 16,
                                horizontalPadding: Double = 20) -> Int {
        let available = width - 2 * horizontalPadding
        guard available.isFinite, available > 0 else { return 1 }
        return max(1, Int(((available + spacing) / (minimum + spacing)).rounded(.down)))
    }

    /// The card an arrow key moves to; nil when there is none that way (the edge of the grid).
    /// ←/→ step through the drawn order; ↑/↓ move one row within a section, and from its first or
    /// last row to the same column of the neighbouring section (its nearest card when that row is
    /// shorter). Without a focused card (or one not drawn) the first card (→/↓) or the last (←/↑).
    package static func move(from id: String?, _ direction: GridDirection, columns: Int,
                             sections: [[String]]) -> String? {
        let sections = sections.filter { !$0.isEmpty }
        let order = sections.flatMap { $0 }
        guard !order.isEmpty else { return nil }
        let cols = max(1, columns)
        guard let id, let flat = order.firstIndex(of: id),
              let si = sections.firstIndex(where: { $0.contains(id) }),
              let p = sections[si].firstIndex(of: id) else {
            return direction == .left || direction == .up ? order.last : order.first
        }
        let section = sections[si]
        let column = p % cols
        switch direction {
        case .left:
            return flat > 0 ? order[flat - 1] : nil
        case .right:
            return flat + 1 < order.count ? order[flat + 1] : nil
        case .up:
            if p >= cols { return section[p - cols] }
            guard si > 0 else { return nil }
            let above = sections[si - 1]
            let lastRowStart = (above.count - 1) / cols * cols
            return above[min(lastRowStart + column, above.count - 1)]
        case .down:
            if p + cols < section.count { return section[p + cols] }
            let row = p / cols, lastRow = (section.count - 1) / cols
            if row < lastRow { return section[section.count - 1] }     // into a shorter last row
            guard si + 1 < sections.count else { return nil }
            let below = sections[si + 1]
            return below[min(column, below.count - 1)]
        }
    }
}
