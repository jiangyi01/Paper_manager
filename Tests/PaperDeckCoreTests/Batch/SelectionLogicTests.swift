import Foundation
import Testing
@testable import PaperDeckCore

/// Multi-select's pure rules (READING_ASSIST_PLAN §9.1 C: click / ⌘ / ⇧ across DDL groups, prune;
/// GridNav): the App's `SelectionModel` only stores what these return.
@Suite struct SelectionLogicTests {
    typealias S = SelectionState
    /// Two DDL groups as the grid draws them (overdue: a b c, this week: d e), flattened.
    static let sections = [["a", "b", "c"], ["d", "e"]]
    static let order = ["a", "b", "c", "d", "e"]

    static func click(_ id: String, _ kind: SelectionClick, _ s: S) -> S {
        SelectionLogic.click(id, kind, order: order, s)
    }

    @Test func plainClickSelectsOnlyThatCard() {
        let s = Self.click("c", .plain, S(ids: ["a", "b"], focused: "a", anchor: "a"))
        #expect(s == S(ids: ["c"], focused: "c", anchor: "c"))
    }

    @Test func commandClickTogglesAndKeepsAFocusedCard() {
        var s = Self.click("b", .plain, .empty)
        s = Self.click("d", .toggle, s)
        #expect(s == S(ids: ["b", "d"], focused: "d", anchor: "d"))
        s = Self.click("e", .toggle, s)
        #expect(s.ids == ["b", "d", "e"] && s.focused == "e")
        // ⌘-deselecting the focused card moves the focus to the next selected card as drawn …
        s = Self.click("b", .toggle, S(ids: ["b", "d", "e"], focused: "b", anchor: "b"))
        #expect(s.ids == ["d", "e"] && s.focused == "d" && s.anchor == "d")
        // … or the closest one before it when it was the last.
        s = Self.click("e", .toggle, S(ids: ["b", "d", "e"], focused: "e", anchor: "e"))
        #expect(s.focused == "d")
        // Deselecting a card that isn't focused keeps the focus.
        s = Self.click("d", .toggle, S(ids: ["b", "d", "e"], focused: "e", anchor: "e"))
        #expect(s.ids == ["b", "e"] && s.focused == "e")
        // The last one off: nothing selected.
        #expect(Self.click("b", .toggle, S(ids: ["b"], focused: "b")) == .empty)
    }

    @Test func shiftClickSelectsTheRangeInDrawnOrderAcrossGroups() {
        var s = Self.click("b", .plain, .empty)
        s = Self.click("e", .range, s)                     // b … e crosses the group boundary
        #expect(s == S(ids: ["b", "c", "d", "e"], focused: "e", anchor: "b"))
        s = Self.click("a", .range, s)                     // the anchor stays: a … b replaces it
        #expect(s.ids == ["a", "b"] && s.focused == "a" && s.anchor == "b")
        // ⌘⇧ adds the range to what is selected.
        s = Self.click("e", .toggle, S(ids: ["a"], focused: "a", anchor: "a"))
        s = SelectionLogic.click("c", .addRange, order: Self.order, S(ids: s.ids, focused: s.focused, anchor: "b"))
        #expect(s.ids == ["a", "b", "c", "e"])
        // No anchor yet: ⇧ is a plain click.
        #expect(Self.click("d", .range, .empty) == S(ids: ["d"], focused: "d", anchor: "d"))
        // A hidden anchor (pruned by a search): a plain click too.
        #expect(Self.click("d", .range, S(ids: ["z"], focused: "z", anchor: "z")) == S(ids: ["d"], focused: "d", anchor: "d"))
    }

    @Test func modifierMapping() {
        #expect(SelectionClick.from(command: false, shift: false) == .plain)
        #expect(SelectionClick.from(command: true, shift: false) == .toggle)
        #expect(SelectionClick.from(command: false, shift: true) == .range)
        #expect(SelectionClick.from(command: true, shift: true) == .addRange)
    }

    @Test func aFocusSetFromOutsideCollapsesTheSelection() {
        // The router / a toast sets selectedPaperID to a paper outside the selection.
        #expect(SelectionLogic.normalized(S(ids: ["a", "b"], focused: "x", anchor: "a")) == S(ids: ["x"], focused: "x", anchor: "x"))
        // A single selection set from outside (ids still empty) is that paper.
        #expect(SelectionLogic.normalized(S(focused: "c")).ids == ["c"])
        // Focus cleared from outside: nothing selected.
        #expect(SelectionLogic.normalized(S(ids: ["a", "b"], focused: nil, anchor: "a")) == .empty)
        // A focus inside the selection keeps it.
        let multi = S(ids: ["a", "b"], focused: "b", anchor: "a")
        #expect(SelectionLogic.normalized(multi) == multi)
        #expect(SelectionLogic.isMulti(in: Self.order, multi))
        #expect(!SelectionLogic.isMulti(in: Self.order, S(ids: ["a", "b"], focused: "x")))
    }

    @Test func selectedIsOnlyTheVisibleIdsInDrawnOrder() {
        let s = S(ids: ["e", "a", "hidden", "c"], focused: "c", anchor: "c")
        #expect(SelectionLogic.selected(in: Self.order, s) == ["a", "c", "e"])
        #expect(SelectionLogic.selected(in: Self.order, .empty).isEmpty)
    }

    @Test func selectAllAndSelectN() {
        var s = SelectionLogic.selectAll(order: Self.order, S(ids: ["c"], focused: "c", anchor: "c"))
        #expect(s == S(ids: Set(Self.order), focused: "c", anchor: "c"))
        s = SelectionLogic.selectAll(order: Self.order, S(ids: ["zz"], focused: "zz"))
        #expect(s.focused == "a")
        #expect(SelectionLogic.selectAll(order: [], S(focused: "c")) == S(ids: ["c"], focused: "c", anchor: "c"))
        // Select-N picks: exactly the visible picks, focused on the first one as drawn.
        s = SelectionLogic.select(["e", "b", "gone"], order: Self.order, .empty)
        #expect(s == S(ids: ["b", "e"], focused: "b", anchor: "b"))
        // Nothing picked: unchanged.
        let before = S(ids: ["a", "b"], focused: "a", anchor: "a")
        #expect(SelectionLogic.select([], order: Self.order, before) == before)
    }

    @Test func pruneDropsPapersThatLeftTheView() {
        // A multi-selection keeps its visible part; the focus moves to the first visible one.
        var s = SelectionLogic.prune(S(ids: ["a", "b", "d"], focused: "a", anchor: "a"), visible: ["b", "c", "d"])
        #expect(s == S(ids: ["b", "d"], focused: "b", anchor: "b"))
        // One left: that paper alone.
        s = SelectionLogic.prune(S(ids: ["a", "b"], focused: "a", anchor: "a"), visible: ["b", "c"])
        #expect(s == S(ids: ["b"], focused: "b", anchor: "b"))
        // The focused one is the one left.
        s = SelectionLogic.prune(S(ids: ["a", "b"], focused: "b", anchor: "a"), visible: ["b"])
        #expect(s == S(ids: ["b"], focused: "b", anchor: "b"))
        // None left: the focused paper stays (the inspector keeps it, as before multi-select).
        s = SelectionLogic.prune(S(ids: ["a", "b"], focused: "a", anchor: "a"), visible: ["x"])
        #expect(s == S(ids: ["a"], focused: "a", anchor: "a"))
        // A single selection is never changed by a view change (the router selects, then switches).
        #expect(SelectionLogic.prune(S(ids: ["a"], focused: "a", anchor: "a"), visible: ["x"]) == S(ids: ["a"], focused: "a", anchor: "a"))
        // Nothing to drop: unchanged.
        let all = S(ids: ["a", "b"], focused: "a", anchor: "b")
        #expect(SelectionLogic.prune(all, visible: Self.order) == all)
    }

    // MARK: Arrow keys

    @Test func gridNavMovesThroughRowsAndSections() {
        // 2 columns: section 1 = [a b] [c], section 2 = [d e].
        let s = Self.sections
        func go(_ from: String?, _ d: GridDirection) -> String? { GridNav.move(from: from, d, columns: 2, sections: s) }
        #expect(go("a", .right) == "b")
        #expect(go("c", .right) == "d")                     // ←/→ follow the drawn order across sections
        #expect(go("d", .left) == "c")
        #expect(go("a", .left) == nil && go("e", .right) == nil)
        #expect(go("a", .down) == "c")
        #expect(go("b", .down) == "c")                      // into the shorter last row: its last card
        #expect(go("c", .down) == "d")                      // same column of the next section
        #expect(go("e", .up) == "c")                        // last row above, nearest card in that column
        #expect(go("d", .up) == "c")
        #expect(go("c", .up) == "a")
        #expect(go("a", .up) == nil && go("e", .down) == nil)
        #expect(go(nil, .down) == "a" && go(nil, .up) == "e")
        #expect(go("gone", .right) == "a")
        // 3 columns, one section of 5: [a b c] [d e].
        let one = [Self.order]
        #expect(GridNav.move(from: "c", .down, columns: 3, sections: one) == "e")
        #expect(GridNav.move(from: "b", .down, columns: 3, sections: one) == "e")
        #expect(GridNav.move(from: "e", .up, columns: 3, sections: one) == "b")
        // One column: up/down step by one.
        #expect(GridNav.move(from: "b", .down, columns: 1, sections: one) == "c")
        #expect(GridNav.move(from: "a", .down, columns: 0, sections: one) == "b")
        #expect(GridNav.move(from: "a", .down, columns: 2, sections: [[], []]) == nil)
    }

    @Test func arrowKeysSelectAndShiftExtends() {
        var s = SelectionLogic.move(S(ids: ["a"], focused: "a", anchor: "a"), .right, columns: 2, sections: Self.sections, extend: false)
        #expect(s == S(ids: ["b"], focused: "b", anchor: "b"))
        s = SelectionLogic.move(s, .down, columns: 2, sections: Self.sections, extend: true)
        #expect(s == S(ids: ["b", "c"], focused: "c", anchor: "b"))
        s = SelectionLogic.move(s, .down, columns: 2, sections: Self.sections, extend: true)
        #expect(s.ids == ["b", "c", "d"] && s.focused == "d")
        // At the edge nothing changes.
        let edge = S(ids: ["e"], focused: "e", anchor: "e")
        #expect(SelectionLogic.move(edge, .right, columns: 2, sections: Self.sections, extend: false) == edge)
    }

    @Test func columnCountMatchesTheAdaptiveGrid() {
        // GridItem(.adaptive(minimum: 260), spacing: 16) with 20 pt padding on both sides.
        #expect(GridNav.columns(width: 300) == 1)
        #expect(GridNav.columns(width: 40 + 260 * 2 + 16) == 2)
        #expect(GridNav.columns(width: 40 + 260 * 2 + 15) == 1)
        #expect(GridNav.columns(width: 1000) == 3)
        #expect(GridNav.columns(width: 0) == 1 && GridNav.columns(width: .nan) == 1)
    }
}
