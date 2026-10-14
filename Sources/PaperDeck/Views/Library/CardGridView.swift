import SwiftUI
import PaperDeckCore

/// The card grid for every sidebar section except 今天 (§8 主窗口). Single click selects,
/// double click opens the PDF, right click shows `PaperContextMenu`. In 待读 sorted by
/// DDL (and not searching) the cards are grouped 逾期/今天/本周/下周/以后/未排期.
///
/// The layout follows the content column's width (`CardGridMetrics`): as many columns of at
/// least 280 pt as fit, all the same width and filling the row exactly; one column of compact
/// horizontal cards below 620 pt (inspector open, narrow window). Rows are drawn lazily; the cards
/// of a row share the tallest one's height.
///
/// Multi-select (READING_ASSIST_PLAN §6.4 C1, once `SelectionModel.isOn`): ⌘-click toggles a
/// card, ⇧-click selects the range from the anchor in the order drawn (the groups flattened); with
/// the grid focused (a click on a card) the arrow keys move (⇧ extends), ⌘A selects every card
/// (`onCommand(selectAll:)`, so a focused text field keeps its own ⌘A) and Esc deselects. Two or
/// more selected cards show `SelectionBar` at the bottom.
struct CardGridView: View {
    let state: AppState
    let rows: [PaperRow]
    /// The selection bar's chrome: glass on screen; `.material` in offscreen renders (glass can't be
    /// captured there).
    let chromeStyle: PanelChromeStyle

    @FocusState private var gridFocused: Bool

    init(state: AppState, rows: [PaperRow], chromeStyle: PanelChromeStyle = .glass) {
        self.state = state
        self.rows = rows
        self.chromeStyle = chromeStyle
    }

    private var multiSelect: Bool { SelectionModel.isOn }

    var body: some View {
        if rows.isEmpty {
            EmptyStateView(state: state, section: state.sidebar)
        } else {
            GeometryReader { proxy in
                grid(CardGridMetrics(width: Double(proxy.size.width)))
            }
        }
    }

    private func grid(_ metrics: CardGridMetrics) -> some View {
        let today = state.snapshot?.today.today ?? LocalDate.today()
        let lang = L.lang
        let groups = groupsIfNeeded(today: today)
        let sections = groups?.map { $0.rows.map(\.id) } ?? [rows.map(\.id)]
        let order = sections.flatMap { $0 }
        let isMulti = multiSelect && state.selection.isMulti
        let context = CardContext(today: today, lang: lang, order: order, isMulti: isMulti, metrics: metrics)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: CardGridMetrics.gutter, pinnedViews: [.sectionHeaders]) {
                    if let groups {
                        ForEach(groups) { group in
                            Section {
                                cardRows(group.rows, context)
                            } header: {
                                ToReadGroupHeader(bucket: group.bucket, count: group.rows.count)
                            }
                        }
                    } else {
                        cardRows(rows, context)
                    }
                }
                .padding(.horizontal, CardGridMetrics.margin)
                .padding(.vertical, 18)
                .background {
                    // Clicking empty space clears the selection.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if multiSelect { state.selection.clear() } else { state.selectedPaperID = nil }
                        }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isMulti {
                    SelectionBar(state: state, style: chromeStyle)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: isMulti)
            .focusable(multiSelect)
            .focusEffectDisabled()
            .focused($gridFocused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
                guard multiSelect, let direction = GridDirection(press.key) else { return .ignored }
                state.selection.move(direction, columns: metrics.columns, extend: press.modifiers.contains(.shift))
                return .handled
            }
            .onCommand(#selector(NSResponder.selectAll(_:)), perform: multiSelect ? { state.selection.selectAllVisible() } : nil)
            .onExitCommand(perform: multiSelect ? { state.selection.clear() } : nil)
            .onChange(of: state.selectedPaperID) { _, id in
                if multiSelect { state.selection.focusDidChange() }
                guard let id, let target = Self.rowID(of: id, sections: sections, columns: metrics.columns) else { return }
                withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(target) }
            }
            .onChange(of: order) {
                if multiSelect { state.selection.prune() }
            }
            .onAppear { if multiSelect { ClickModifiers.install() } }
        }
        .agentBadgeActions(state)
    }

    /// What every card of one drawing shares.
    private struct CardContext {
        let today: LocalDate
        let lang: UILang
        let order: [String]
        let isMulti: Bool
        let metrics: CardGridMetrics
    }

    /// One drawn row: the cards of a section's `columns`-wide slice.
    private struct CardRow: Identifiable {
        let rows: [PaperRow]
        var id: String { CardGridView.rowKey(rows.first?.id ?? "") }
    }

    static func rowKey(_ firstID: String) -> String { "row:" + firstID }

    /// The drawn row holding paper `id` (what `scrollTo` can find: rows are the lazy stack's items).
    static func rowID(of id: String, sections: [[String]], columns: Int) -> String? {
        for section in sections {
            guard let i = section.firstIndex(of: id) else { continue }
            return rowKey(section[i - i % max(1, columns)])
        }
        return nil
    }

    private func cardRows(_ rows: [PaperRow], _ context: CardContext) -> some View {
        let metrics = context.metrics
        let slices = CardGridMetrics.rows(rows, columns: metrics.columns).map(CardRow.init)
        return ForEach(slices) { slice in
            HStack(alignment: .top, spacing: CardGridMetrics.gutter) {
                ForEach(slice.rows) { row in
                    card(row, context)
                        .frame(width: metrics.cardWidth)
                }
            }
            // Every card of the row gets the row's tallest height (the footers line up).
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(slice.id)
        }
    }

    private func card(_ row: PaperRow, _ context: CardContext) -> some View {
        let selected = multiSelect ? state.selection.isSelected(row.id) : state.selectedPaperID == row.id
        let metrics = context.metrics
        return PaperCardView(row: row, today: context.today, lang: context.lang, agentStatus: state.agentStatus,
                             queuePosition: state.queuePositions[row.paper.pk], isSelected: selected,
                             style: metrics.style, thumbnailHeight: metrics.thumbnailHeight,
                             showsThumbnailStrip: metrics.showsCompactThumbnail,
                             showsCheckmark: context.isMulti && selected)
            .contentShape(RoundedRectangle(cornerRadius: PaperCardView.cornerRadius, style: .continuous))
            .onTapGesture(count: 2) { doubleClick(row, order: context.order) }
            .simultaneousGesture(TapGesture().onEnded { click(row, order: context.order) })
            .contextMenu { PaperContextMenu(state: state, row: row) }
            .accessibilityAction(named: L.cardsMenuOpenPDF) { if !row.paper.isDeleted { state.openPDF(row) } }
            .id(row.id)
    }

// MARK: Clicks

    private func click(_ row: PaperRow, order: [String]) {
        guard multiSelect else { state.selectedPaperID = row.id; return }
        let flags = ClickModifiers.current
        state.selection.click(row.id, kind: .from(command: flags.contains(.command), shift: flags.contains(.shift)), order: order)
        gridFocused = true
    }

    /// Opens the PDF. A ⌘ / ⇧ double click is two selection clicks, never an open.
    private func doubleClick(_ row: PaperRow, order: [String]) {
        if multiSelect {
            let flags = ClickModifiers.current
            guard !flags.contains(.command), !flags.contains(.shift) else { return }
            state.selection.click(row.id, kind: .plain, order: order)
        } else {
            state.selectedPaperID = row.id
        }
        if !row.paper.isDeleted { state.openPDF(row) }
    }

    // MARK: DDL grouping (待读 · sort by DDL)

    private func groupsIfNeeded(today: LocalDate) -> [ToReadGroup]? {
        CardGridLayout.groups(rows, state: state, today: today)
    }
}

/// The grid's sections as drawn — shared with `SelectionModel`, whose ⇧-ranges and arrow keys
/// follow the drawn order.
enum CardGridLayout {
    /// 待读 sorted by DDL (and not searching): the DDL groups; nil = one plain section.
    fileprivate static func groups(_ rows: [PaperRow], state: AppState, today: LocalDate) -> [ToReadGroup]? {
        guard state.sidebar == .toRead, state.sort == .deadline, state.searchResults == nil else { return nil }
        return ToReadBucket.group(rows, today: today)
    }

    /// `rows` split into the sections the grid draws, in order.
    static func sections(_ rows: [PaperRow], state: AppState) -> [[PaperRow]] {
        let today = state.snapshot?.today.today ?? LocalDate.today()
        return groups(rows, state: state, today: today)?.map(\.rows) ?? [rows]
    }
}

extension GridDirection {
    init?(_ key: KeyEquivalent) {
        switch key {
        case .leftArrow: self = .left
        case .rightArrow: self = .right
        case .upArrow: self = .up
        case .downArrow: self = .down
        default: return nil
        }
    }
}

/// The modifier keys of the click a card's tap gesture is handling. SwiftUI runs `onEnded` after
/// AppKit dispatched the mouse events, so `NSApp.currentEvent` no longer is the click; this local
/// monitor (the AppKit side of the grid's click handling, READING_ASSIST_PLAN §6.4 C1) remembers
/// the flags of the latest left mouse-down — what Finder decides by — and passes every event on
/// unchanged. Installed once, when a multi-select grid first appears.
enum ClickModifiers {
    private static var monitor: Any?
    private static var last: (flags: NSEvent.ModifierFlags, at: TimeInterval)?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            ClickModifiers.record(event)
            return event
        }
    }

    static func record(_ mouseDown: NSEvent) {
        last = (mouseDown.modifierFlags, mouseDown.timestamp)
    }

    /// ⌘ / ⇧ of the current click: the latest mouse-down when it was just now, else the keys held.
    static var current: NSEvent.ModifierFlags {
        let now = ProcessInfo.processInfo.systemUptime
        if let last, now - last.at < 2 { return last.flags.intersection([.command, .shift]) }
        return NSEvent.modifierFlags.intersection([.command, .shift])
    }
}

/// 待读 grouping buckets (calendar weeks follow the user's first weekday).
private enum ToReadBucket: Int, CaseIterable, Identifiable, Sendable {
    case overdue, today, thisWeek, nextWeek, later, unscheduled

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .overdue: return L.cardsBucketOverdue
        case .today: return L.cardsBucketToday
        case .thisWeek: return L.cardsBucketThisWeek
        case .nextWeek: return L.cardsBucketNextWeek
        case .later: return L.cardsBucketLater
        case .unscheduled: return L.cardsBucketUnscheduled
        }
    }

    var symbol: String {
        switch self {
        case .overdue: return "exclamationmark.circle.fill"
        case .today: return "sun.max.fill"
        case .thisWeek: return "calendar"
        case .nextWeek: return "calendar.badge.clock"
        case .later: return "tray.full"
        case .unscheduled: return "questionmark.circle"
        }
    }

    /// Groups rows (keeping their order) into non-empty buckets, in bucket order.
    static func group(_ rows: [PaperRow], today: LocalDate, calendar: Calendar = .current) -> [ToReadGroup] {
        let noon = today.date(hour: 12, minute: 0, calendar: calendar)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: noon).map { LocalDate($0.start, calendar: calendar) } ?? today
        let nextWeek = weekStart.adding(days: 7, calendar: calendar)
        let afterNext = weekStart.adding(days: 14, calendar: calendar)
        var buckets: [ToReadBucket: [PaperRow]] = [:]
        for row in rows {
            let b: ToReadBucket
            if row.paper.scheduleMode == .none || row.paper.deadline == nil {
                b = .unscheduled
            } else if let d = row.paper.deadline {
                if d < today { b = .overdue }
                else if d == today { b = .today }
                else if d < nextWeek { b = .thisWeek }
                else if d < afterNext { b = .nextWeek }
                else { b = .later }
            } else {
                b = .unscheduled
            }
            buckets[b, default: []].append(row)
        }
        return allCases.compactMap { b in buckets[b].map { ToReadGroup(bucket: b, rows: $0) } }
    }
}

private struct ToReadGroup: Identifiable {
    let bucket: ToReadBucket
    let rows: [PaperRow]
    var id: Int { bucket.rawValue }
}

/// Pinned section header of the grouped 待读 grid.
private struct ToReadGroupHeader: View {
    let bucket: ToReadBucket
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: bucket.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(bucket == .overdue ? AnyShapeStyle(ChipPalette.dynamic(light: 0xC62828, dark: 0xFF6B61))
                                                    : AnyShapeStyle(.secondary))
            Text(bucket.title)
                .font(.system(size: 13, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
