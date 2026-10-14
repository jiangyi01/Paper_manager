import Foundation

/// The library grid's geometry for one content width (§8 主窗口), pure so it can be tested: the
/// column count follows the width, every column gets the same width and the row is filled exactly
/// (no ragged gap at the right edge), and below `compactBelow` the grid becomes one column of
/// compact horizontal cards. The App's `CardGridView` draws what this returns and its arrow keys
/// (`GridNav.move`) use the same `columns`.
///
/// Cards are at least `minCardWidth` wide; a new column is added as soon as one more fits, so from
/// three columns on a card is never wider than `maxCardWidth` (two columns can reach ≈ 428 pt
/// just before the third fits).
package struct CardGridMetrics: Equatable, Sendable {
    package enum Style: Equatable, Sendable {
        /// Vertical cards (thumbnail on top), `columns` per row.
        case tiles
        /// One column of horizontal cards (narrow content column: inspector open, small window).
        case compact
    }

    package static let minCardWidth: Double = 280
    package static let maxCardWidth: Double = 400
    package static let gutter: Double = 16
    /// Side margin of the grid (the gutter's rhythm: 20 = 16 + the card's shadow room).
    package static let margin: Double = 20
    /// Content widths below this get the compact one-column list.
    package static let compactBelow: Double = 620
    /// The thumbnail JPEG is the top 560 × 240 px of page 1 (`PDFExtractor.thumbnailSize`).
    package static let thumbnailAspect: Double = 240.0 / 560.0
    /// Thumbnail heights: 120 pt at the minimum card width, growing with the card, capped so a
    /// wide card doesn't turn into mostly picture.
    package static let thumbnailHeights: ClosedRange<Double> = 112...150
    /// The compact card's small page thumbnail, and the card width below which it's dropped (the
    /// title and the footer need the room more).
    package static let compactThumbnailWidth: Double = 64
    package static let compactThumbnailHeight: Double = 84
    package static let compactThumbnailMinCardWidth: Double = 360

    /// The content width this was computed for (the grid's whole width, margins included).
    package let width: Double
    package let style: Style
    package let columns: Int
    /// Every card's width (tiles) or the one card's width (compact).
    package let cardWidth: Double
    /// Thumbnail height of a tile (unused by compact cards).
    package let thumbnailHeight: Double

    package init(width: Double) {
        let usable = width.isFinite ? max(0, width) : 0
        self.width = usable
        let available = max(0, usable - 2 * Self.margin)
        if usable < Self.compactBelow {
            style = .compact
            columns = 1
            cardWidth = available
        } else {
            style = .tiles
            let n = max(1, Int(((available + Self.gutter) / (Self.minCardWidth + Self.gutter)).rounded(.down)))
            columns = n
            cardWidth = Self.floorPoint((available - Double(n - 1) * Self.gutter) / Double(n))
        }
        thumbnailHeight = Self.thumbnailHeight(cardWidth: cardWidth)
    }

    /// The tile thumbnail's height for a card width: the JPEG's own aspect, clamped.
    package static func thumbnailHeight(cardWidth: Double) -> Double {
        let natural = (cardWidth * thumbnailAspect).rounded()
        return min(thumbnailHeights.upperBound, max(thumbnailHeights.lowerBound, natural))
    }

    /// Whether compact cards show their thumbnail strip.
    package var showsCompactThumbnail: Bool { style == .compact && cardWidth >= Self.compactThumbnailMinCardWidth }

    /// Total width the cards and gutters of one full row take (≤ the available width; the
    /// difference is the sub-point rounding left at the end of the row).
    package var rowWidth: Double {
        style == .compact ? cardWidth : Double(columns) * cardWidth + Double(columns - 1) * Self.gutter
    }

    /// Rounds down to a half point so `columns` cards and their gutters never exceed the row.
    private static func floorPoint(_ v: Double) -> Double { (v * 2).rounded(.down) / 2 }

    /// `items` cut into rows of `columns` (the last row may be shorter); each section of the grid
    /// starts a new row, so call this per section.
    package static func rows<T>(_ items: [T], columns: Int) -> [[T]] {
        let n = max(1, columns)
        return stride(from: 0, to: items.count, by: n).map { Array(items[$0..<min($0 + n, items.count)]) }
    }
}

/// What a library card shows (the "cleaner card" rules, §8 卡片): badges only when they ask for
/// something or say the AI reading isn't ready, at most two chips with the rest folded into `+N`.
package enum CardBadgeRules {
    /// The card's chip budget: the category (when there is one) plus tags, `budget` in all.
    package struct Chips: Equatable, Sendable {
        package var showsCategory: Bool
        package var tags: Int
        /// Tags folded into the `+N` chip.
        package var overflow: Int
    }

    package static func chips(hasCategory: Bool, tagCount: Int, budget: Int = 2) -> Chips {
        let budget = max(0, budget)
        let showsCategory = hasCategory && budget > 0
        let tags = min(max(0, tagCount), budget - (showsCategory ? 1 : 0))
        return Chips(showsCategory: showsCategory, tags: tags, overflow: max(0, tagCount) - tags)
    }

    /// Only a high priority gets a mark on the card (normal is the default, low isn't a reason to
    /// look; the inspector shows every priority).
    package static func showsPriorityMark(_ priority: Priority) -> Bool { priority == .high }
}

/// The AI status a paper's badge shows (§8 AgentBadge table); the App's `AgentBadge` draws it.
package enum AgentBadgeKind: Equatable, Sendable {
    case modeOff, awaitingConfirmation, queued(Int?), running(since: Date?), failed
    case limited(until: Date?), needsLogin, skipped, textIncomplete, fresh

    /// The badge state for a paper, or nil when nothing should be shown.
    package static func of(_ paper: Paper, status: AgentQueueStatus, queuePosition: Int?) -> AgentBadgeKind? {
        let partialText = paper.textQuality == .partial || paper.textQuality == .poor
        switch paper.aiState {
        case .held:
            return paper.aiNote == AgentQueue.modeOffNote || status.mode == .off ? .modeOff : .awaitingConfirmation
        case .queued:
            return .queued(queuePosition)
        case .running:
            return .running(since: status.runningPaperID == paper.id ? status.runningSince : nil)
        case .failed:
            return .failed
        case .limited:
            return .limited(until: status.pausedUntil)
        case .needsLogin:
            return .needsLogin
        case .skipped:
            return .skipped
        case .done:
            if partialText { return .textIncomplete }
            return paper.aiSeen ? nil : .fresh
        case .none:
            return partialText ? .textIncomplete : nil
        }
    }

    /// Whether the card shows this badge: only while the reading isn't ready (waiting for a
    /// confirmation, queued, running, paused by a limit) or needs the user (failed, needs login).
    /// AI off is every card's state and the toolbar pill says it; skipped is the user's own choice;
    /// a fresh card already has the title's blue dot; incomplete text is in the inspector's notes.
    package var showsOnCard: Bool {
        switch self {
        case .awaitingConfirmation, .queued, .running, .limited, .failed, .needsLogin: return true
        case .modeOff, .skipped, .textIncomplete, .fresh: return false
        }
    }
}

/// The library's notices (banners) as a queue: one is shown at a time, the most severe first, and
/// a pager steps through the rest. Pure: the App keeps the shown id and the dismissed ids.
package enum NoticeQueue {
    package enum Severity: Int, Comparable, Sendable {
        case info, warning, error
        package static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    /// `items` (id, severity) most severe first, keeping their order within a severity.
    package static func ordered<ID>(_ items: [(id: ID, severity: Severity)]) -> [ID] {
        items.enumerated()
            .sorted { $0.element.severity != $1.element.severity ? $0.element.severity > $1.element.severity : $0.offset < $1.offset }
            .map(\.element.id)
    }

    /// The index of the notice on screen: the selected one while it's still queued, else the first
    /// (the most severe); nil when the queue is empty.
    package static func shownIndex<ID: Equatable>(_ ids: [ID], selected: ID?) -> Int? {
        guard !ids.isEmpty else { return nil }
        return selected.flatMap { ids.firstIndex(of: $0) } ?? 0
    }

    /// The notice "next" shows: the one after the shown one, wrapping to the first.
    package static func next<ID: Equatable>(_ ids: [ID], after selected: ID?) -> ID? {
        guard let i = shownIndex(ids, selected: selected) else { return nil }
        return ids[(i + 1) % ids.count]
    }

    /// The notice that takes the place of a dismissed one: the next in the queue (wrapping), nil
    /// when it was the only one.
    package static func successor<ID: Equatable>(_ ids: [ID], dismissing id: ID) -> ID? {
        guard let i = ids.firstIndex(of: id) else { return shownIndex(ids, selected: nil).map { ids[$0] } }
        let rest = ids.count - 1
        guard rest > 0 else { return nil }
        return ids[(i + 1) % ids.count]
    }

    /// A notice's buttons: at most `limit` stay visible — the prominent ones first, then the rest in
    /// order — and the others go into its ⋯ menu. Both lists keep the actions' own order.
    package static func splitActions(prominent: [Bool], limit: Int = 2) -> (shown: [Int], overflow: [Int]) {
        let ranked = prominent.indices.sorted { a, b in
            prominent[a] != prominent[b] ? prominent[a] : a < b
        }
        let shown = Set(ranked.prefix(max(0, limit)))
        return (prominent.indices.filter { shown.contains($0) }, prominent.indices.filter { !shown.contains($0) })
    }

    /// Whether a library banner shows above the Mail inbox, which has its own one-notice line
    /// (`MailInboxHeader`): only a critical one (an error — the library folder, the AI sign-in),
    /// and only while the inbox shows no notice of its own, so the column never stacks two. The
    /// papers' warnings (deadlines at risk, missing PDFs) wait for the library's own sections.
    package static func showsOverInbox(_ severity: Severity, inboxHasNotice: Bool) -> Bool {
        severity == .error && !inboxHasNotice
    }
}
