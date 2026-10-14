import Foundation
import Testing
@testable import PaperDeckCore

/// The decluttered Mail inbox header's rules (`MailNoticePolicy`): which account problems become
/// the one notice (most serious first), when the skipped-emails notice is due again, what the
/// status pill says — plus the list cards' chip budget (`MailCardDensity`) and the inbox columns
/// at every window width (`MailInboxLayout`). Pure: no engine, no files.
@Suite struct MailNoticePolicyTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private static func info(_ id: String, kind: MailAccount.Kind = .folder, enabled: Bool = true,
                             status: MailSourceStatus? = .ready(detail: "Watching “PaperDeck Mail” · 2 emails"),
                             failures: Int = 0, notEmail: Int = 0, ignored: Int = 0,
                             skipped: Int = 0, dismissed: Int = 0, syncing: Bool = false) -> MailAccountSyncInfo {
        MailAccountSyncInfo(id: id, displayName: "Account \(id)", kind: kind, enabled: enabled, status: status,
                            lastSuccessAt: now, consecutiveFailures: failures, isSyncing: syncing,
                            notEmailFiles: notEmail, notEmailHint: notEmail > 0 ? MailSyncText.notEmailFiles(notEmail, .en) : nil,
                            skipped: skipped,
                            skippedHint: skipped > 0 ? MailSyncText.skippedByCap(skipped, lookbackDays: 14, .en) : nil,
                            ignoredNotEmailFiles: ignored, skippedDismissed: dismissed)
    }

    // MARK: Notices

    @Test func aHealthyInboxHasNoNoticeAndASyncedPill() {
        let accounts = [Self.info("a"), Self.info("b", kind: .imap, status: .ready(detail: "Signed in as me@x.org"))]
        #expect(MailNoticePolicy.notices(accounts).isEmpty)
        #expect(MailNoticePolicy.pill(accounts, enabled: true) == .synced(Self.now))
    }

    @Test func ignoredFilesAreQuiet() {
        // The user's real case: one HTML-only file, ignored → no notice, no orange pill.
        let ignored = Self.info("pa", ignored: 1)
        #expect(MailNoticePolicy.notices([ignored]).isEmpty)
        #expect(!MailNoticePolicy.needsAttention(ignored))
        #expect(MailNoticePolicy.pill([ignored], enabled: true) == .synced(Self.now))
        // A new one (not ignored) warns again — about that one only.
        let fresh = Self.info("pa", notEmail: 1, ignored: 1)
        let notices = MailNoticePolicy.notices([fresh])
        #expect(notices.map(\.kind) == [.notEmail] && notices.first?.count == 1)
        #expect(MailNoticePolicy.pill([fresh], enabled: true) == .attention(accounts: 1, critical: false))
    }

    @Test func noticesComeMostSeriousFirstInSettingsOrder() {
        let accounts = [
            Self.info("files", notEmail: 2),
            Self.info("gmail", kind: .imap, status: .authFailed("Gmail rejected the app password")),
            Self.info("skips", kind: .imap, status: .ready(detail: "Signed in"), skipped: 3),
            Self.info("setup", kind: .imap, status: .needsSetup("No app password saved")),
            Self.info("gone", status: .unavailable("Folder not found: ~/x"), failures: 1),
        ]
        let notices = MailNoticePolicy.notices(accounts)
        #expect(notices.map(\.id) == ["gmail/authFailed", "setup/needsSetup", "gone/unavailable", "files/notEmail", "skips/skipped"])
        #expect(notices.first?.text == "Gmail rejected the app password")
        #expect(notices.first(where: { $0.kind == .notEmail })?.count == 2)
        #expect(MailNoticePolicy.pill(accounts, enabled: true) == .attention(accounts: 5, critical: true))
    }

    @Test func briefOutagesOnlyTintThePill() {
        // An IMAP server unreachable once, or emails still retried: no notice — the pill says it.
        let blip = Self.info("imap", kind: .imap, status: .unavailable("Network down"), failures: 1)
        let retrying = Self.info("imap2", kind: .imap, status: .unavailable("Signed in · 2 emails still retried"), failures: 0)
        #expect(MailNoticePolicy.notices([blip, retrying]).isEmpty)
        #expect(MailNoticePolicy.pill([blip, retrying], enabled: true) == .attention(accounts: 2, critical: false))
        // Failing three passes in a row is a real problem; a folder that can't be read at once.
        let down = Self.info("imap", kind: .imap, status: .unavailable("Network down"), failures: 3)
        let folder = Self.info("f", status: .unavailable("Folder not found"), failures: 1)
        #expect(MailNoticePolicy.notices([down, folder]).map(\.kind) == [.unavailable, .unavailable])
    }

    @Test func pausedAccountsRaiseNoStatusNotice() {
        let paused = Self.info("p", kind: .imap, enabled: false, status: .authFailed("rejected"), skipped: 2)
        #expect(MailNoticePolicy.notices([paused]).isEmpty)
        #expect(!MailNoticePolicy.needsAttention(paused))
        // Its folder's files still count (they are in the folder whether it syncs or not).
        let pausedFolder = Self.info("pf", enabled: false, notEmail: 1)
        #expect(MailNoticePolicy.notices([pausedFolder]).map(\.kind) == [.notEmail])
    }

    @Test func sessionDismissalHidesUntilTheSentenceChanges() throws {
        let failing = Self.info("g", kind: .imap, status: .authFailed("rejected"))
        let key = try #require(MailNoticePolicy.notices([failing]).first).dismissKey
        #expect(MailNoticePolicy.notices([failing], dismissed: [key]).isEmpty)
        let other = Self.info("g", kind: .imap, status: .authFailed("too many attempts"))
        #expect(MailNoticePolicy.notices([other], dismissed: [key]).map(\.kind) == [.authFailed])
        // The pill still says it: a hidden notice never hides the problem.
        #expect(MailNoticePolicy.pill([failing], enabled: true) == .attention(accounts: 1, critical: true))
    }

    // MARK: Skipped emails

    @Test func theSkippedNoticeIsHiddenUntilTheCountGrows() {
        let hidden = Self.info("k", kind: .imap, skipped: 3, dismissed: 3)
        #expect(!MailNoticePolicy.skippedNoticeDue(hidden, active: true))
        #expect(MailNoticePolicy.notices([hidden]).isEmpty)
        #expect(MailNoticePolicy.pill([hidden], enabled: true) == .synced(Self.now))
        let grown = Self.info("k", kind: .imap, skipped: 4, dismissed: 3)
        #expect(MailNoticePolicy.skippedNoticeDue(grown, active: true))
        #expect(MailNoticePolicy.notices([grown]).map(\.kind) == [.skipped])
        #expect(!MailNoticePolicy.skippedNoticeDue(grown, active: false))
        var noHint = grown
        noHint.skippedHint = nil                        // a row read in another language: no sentence yet
        #expect(!MailNoticePolicy.skippedNoticeDue(noHint, active: true))
    }

    @Test func theStatusLeavesTheSkippedSentenceOutWhileTheAccountSyncs() {
        let hint = MailSyncText.skippedByCap(3, lookbackDays: 14, .en)
        var info = Self.info("k", kind: .imap, skipped: 3)
        info.status = .unavailable("Signed in as k@x.org · " + hint)
        #expect(MailNoticePolicy.shownStatus(info, active: true) == .ready(detail: "Signed in as k@x.org"))
        info.skippedDismissed = 3                       // hidden: still left out (the user knows)
        #expect(MailNoticePolicy.shownStatus(info, active: true) == .ready(detail: "Signed in as k@x.org"))
        #expect(MailNoticePolicy.shownStatus(info, active: false) == info.status)
        info.undownloadable = 1
        #expect(MailNoticePolicy.shownStatus(info, active: true) == .unavailable("Signed in as k@x.org"))
        info.status = .unavailable("something else")
        #expect(MailNoticePolicy.shownStatus(info, active: true) == .unavailable("something else"))
    }

    // MARK: Pill

    @Test func thePillSaysOffNotSetUpPausedOrSyncing() {
        #expect(MailNoticePolicy.pill([], enabled: true) == .notSetUp)
        #expect(MailNoticePolicy.pill([Self.info("a")], enabled: false) == .off)
        #expect(MailNoticePolicy.pill([Self.info("a", enabled: false)], enabled: true) == .paused)
        #expect(MailNoticePolicy.pill([Self.info("a", syncing: true), Self.info("b", notEmail: 1)], enabled: true) == .syncing)
        #expect(MailNoticePolicy.pill([Self.info("a", status: nil)], enabled: true) == .synced(Self.now))
        var never = Self.info("a", status: nil)
        never.lastSuccessAt = nil
        #expect(MailNoticePolicy.pill([never], enabled: true) == .synced(nil))
    }

    // MARK: Card chips

    @Test func listCardsShowTwoChipsAndCollapseTheRest() {
        let all = MailCardDensity.chips([.request, .priorityHigh, .due, .unverified])
        #expect(all.shown == [.unverified, .due] && all.hidden == [.priorityHigh, .request])
        let two = MailCardDensity.chips([.request, .due])
        #expect(two.shown == [.due, .request] && two.hidden.isEmpty)
        #expect(MailCardDensity.chips([]).shown.isEmpty)
        #expect(MailCardDensity.chips([.request, .request]).shown == [.request])      // no duplicates
        #expect(MailCardDensity.chips([.due, .request], max: 0).hidden == [.due, .request])
    }

    // MARK: Columns

    /// The inbox column of a window `w` wide: sidebar 236 (+1 divider) from 900 pt, the inspector
    /// 380 (+1) when open, the list's 24-pt side padding.
    private static func listWidth(window w: Double, inspector: Bool) -> Double {
        let sidebar = w < 900 ? 0 : 237.0
        return w - sidebar - (inspector ? 381 : 0) - 48
    }

    @Test func columnsFollowTheWindowWidth() {
        let expected: [(Double, Bool, Int)] = [
            (720, false, 1), (900, false, 1), (1100, false, 1), (1280, false, 1), (1440, false, 1),
            (1680, false, 1), (2000, false, 2), (2560, false, 3),
            (1280, true, 1), (1440, true, 1), (1680, true, 1), (2000, true, 1), (2560, true, 2),
        ]
        for (w, inspector, columns) in expected {
            let width = Self.listWidth(window: w, inspector: inspector)
            let n = MailInboxLayout.columns(width: width)
            #expect(n == columns, "window \(w) inspector \(inspector): \(n) columns")
            let column = MailInboxLayout.columnWidth(width: width, columns: n)
            let content = MailInboxLayout.contentWidth(width: width, columns: n)
            // Never clipped, never narrower than a readable card (or the whole list when narrower).
            #expect(content <= width + 0.001)
            #expect(column <= MailInboxLayout.maxColumn)
            #expect(column >= min(width, MailInboxLayout.minColumn - 0.001) || n == 1)
            // Several columns: the cards fill the width they take (no orphan strip beside them).
            if n > 1 { #expect(width - content < MailInboxLayout.minColumn) }
        }
        #expect(MailInboxLayout.columns(width: 0) == 1 && MailInboxLayout.columns(width: .nan) == 1)
        #expect(MailInboxLayout.columns(width: 100_000) == MailInboxLayout.maxColumns)
    }

    @Test func cardsFlowIntoBalancedColumnsNewestFirst() {
        let heights: [Double] = [300, 200, 200, 200, 500, 100, 100]
        let groups = MailInboxLayout.distribute(heights: heights, columns: 2)
        #expect(groups.flatMap { $0 }.sorted() == Array(heights.indices))         // every card once
        for g in groups { #expect(g == g.sorted()) }                               // newest first in each
        let totals = groups.map { $0.reduce(0) { $0 + heights[$1] + MailInboxLayout.gap } }
        #expect(abs(totals[0] - totals[1]) <= heights.max()! + MailInboxLayout.gap)  // within one card
        #expect(groups == [[0, 3, 5, 6], [1, 2, 4]])
        #expect(MailInboxLayout.distribute(heights: heights, columns: 1) == [Array(heights.indices)])
        #expect(MailInboxLayout.distribute(heights: [], columns: 3) == [[], [], []])
        #expect(MailInboxLayout.estimatedHeight(rows: 3, hasMoreLine: true, hasConsent: false)
                > MailInboxLayout.estimatedHeight(rows: 1, hasMoreLine: false, hasConsent: false))
    }
}
