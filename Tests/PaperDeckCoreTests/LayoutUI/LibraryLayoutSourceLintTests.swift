import Foundation
import Testing

/// The App draws what the pure layout rules return (the test target doesn't link the app, so the
/// wiring is checked in the sources; behaviour: `CardGridMetricsTests`, `CardDeclutterRulesTests`).
@Suite("Library layout: sources", .enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
struct LibraryLayoutSourceLintTests {
    static func text(_ path: String) throws -> String { try String(contentsOf: LintRepo.url(path), encoding: .utf8) }

    @Test func theGridFollowsTheWidthNotAnAdaptiveGrid() throws {
        let grid = try Self.text("Sources/PaperDeck/Views/Library/CardGridView.swift")
        #expect(!grid.contains(".adaptive("), "the adaptive grid leaves ragged gaps")
        #expect(!grid.contains("LazyVGrid"))
        #expect(grid.contains("grid(CardGridMetrics(width: Double(proxy.size.width)))"))
        #expect(grid.contains("CardGridMetrics.rows(rows, columns: metrics.columns)"))
        #expect(grid.contains(".frame(width: metrics.cardWidth)"))
        // Every card of a row gets the row's tallest height.
        #expect(grid.contains(".fixedSize(horizontal: false, vertical: true)"))
        // The arrow keys use the columns drawn.
        #expect(grid.contains("state.selection.move(direction, columns: metrics.columns, extend: press.modifiers.contains(.shift))"))
        #expect(!grid.contains("GridNav.columns("))
        // scrollTo finds the lazy row that holds the paper.
        #expect(grid.contains("Self.rowID(of: id, sections: sections, columns: metrics.columns)"))
    }

    @Test func theCardHasNoFixedHeightAndFollowsTheRules() throws {
        let card = try Self.text("Sources/PaperDeck/Views/Components/PaperCardView.swift")
        #expect(!card.contains(".frame(height: Self.height)") && !card.contains("static let height"), "a fixed height clips text")
        #expect(card.contains("CardBadgeRules.chips(hasCategory: row.category != nil, tagCount: row.tags.count, budget: n)"))
        #expect(card.contains("private var chips: some View { chips(budget: 2) }"))
        #expect(card.contains("TagChips(tags: row.tags, limit: budget.tags)"))
        #expect(card.contains("if CardBadgeRules.showsPriorityMark(paper.priority) {"))
        #expect(!card.contains("L.cardsTLDRPending"), "no TL;DR placeholder on the card")
        #expect(!card.contains("L.cardsLowPriority"), "no low-priority mark on the card")
        let badge = try Self.text("Sources/PaperDeck/Views/Components/AgentBadge.swift")
        #expect(badge.contains("if let kind = Self.kind(for: paper, status: status, queuePosition: queuePosition), kind.showsOnCard {"))
    }

    @Test func oneBannerIsShownAtATime() throws {
        let banners = try Self.text("Sources/PaperDeck/Views/Library/Banners.swift")
        #expect(banners.contains("let index = NoticeQueue.shownIndex(ids, selected: shownID)"))
        #expect(!banners.contains("ForEach(banners)"), "every banner at once is the clutter this replaces")
        #expect(banners.contains("NoticeQueue.ordered(shown.map { (id: $0.id, severity: $0.severity) })"))
        #expect(banners.contains("shownID = NoticeQueue.successor(ids, dismissing: banner.id)"))
        #expect(banners.contains("NoticeQueue.splitActions(prominent: banner.actions.map(\\.prominent))"))
        #expect(banners.contains(".accessibilityLabel(L.Library.noticePosition(position.index, position.count))"))
        // Above the Mail inbox (its own notice line): never a second notice.
        #expect(banners.contains("MailInboxHeader.showsNotice($0, dismissed: MailNoticeDismissals.shared.keys)"))
        #expect(banners.contains("shown = shown.filter { NoticeQueue.showsOverInbox($0.severity, inboxHasNotice: inboxNotice) }"))
        let inbox = try Self.text("Sources/PaperDeck/Views/Mail/MailInboxView.swift")
        #expect(inbox.contains("static func showsNotice(_ snap: MailSnapshot, dismissed: Set<String>) -> Bool {"))
        #expect(inbox.contains("let notices = needsSetup ? [] : MailNoticePolicy.notices(snap.accounts, dismissed: dismissals.keys)"))
    }

    @Test func theNewStringsAreBilingual() throws {
        let strings = try Self.text("Sources/PaperDeck/App/L10n+library.swift")
        for needle in ["下一条提示", "Next Notice", "更多操作", "More Actions", "个步骤", "steps", "收起步骤", "Hide Steps"] {
            #expect(strings.contains(needle), "\(needle)")
        }
    }
}
