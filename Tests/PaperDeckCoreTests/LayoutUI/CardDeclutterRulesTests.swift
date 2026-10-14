import Foundation
import Testing
@testable import PaperDeckCore

/// The "cleaner card" rules: which badges a card shows, the chip budget, and the library's notices
/// shown one at a time (`CardBadgeRules`, `AgentBadgeKind`, `NoticeQueue`).
@Suite struct CardDeclutterRulesTests {
    static func paper(_ ai: AIState, note: String? = nil, seen: Bool = true, text: TextQuality? = nil) -> Paper {
        Paper(sha256: "x", fileSize: 1, title: "T", folder: "Papers/T", pdfName: "T.pdf", originalName: "T.pdf",
              textQuality: text, aiState: ai, aiNote: note, aiSeen: seen)
    }

    static let on = AgentQueueStatus(provider: .ready(plan: nil, version: "1"), mode: .claude)
    static let off = AgentQueueStatus(mode: .off)

    // MARK: AI badge

    @Test func theCardShowsTheAIBadgeOnlyWhileNotReadyOrNeedingTheUser() {
        let shown: [AIState] = [.queued, .running, .limited, .failed, .needsLogin]
        for state in shown {
            let kind = AgentBadgeKind.of(Self.paper(state), status: Self.on, queuePosition: 2)
            #expect(kind?.showsOnCard == true, "\(state)")
        }
        // Held for a batch confirmation (AI on): actionable.
        #expect(AgentBadgeKind.of(Self.paper(.held), status: Self.on, queuePosition: nil) == .awaitingConfirmation)
        #expect(AgentBadgeKind.awaitingConfirmation.showsOnCard)
    }

    @Test func aiOffSkippedFreshAndIncompleteTextStayOffTheCard() {
        // AI off: every card would say it — the toolbar pill does.
        let modeOff = AgentBadgeKind.of(Self.paper(.held, note: AgentQueue.modeOffNote), status: Self.on, queuePosition: nil)
        #expect(modeOff == .modeOff && modeOff?.showsOnCard == false)
        #expect(AgentBadgeKind.of(Self.paper(.held), status: Self.off, queuePosition: nil)?.showsOnCard == false)
        #expect(AgentBadgeKind.of(Self.paper(.skipped), status: Self.on, queuePosition: nil)?.showsOnCard == false)
        // A fresh reading: the title's blue dot says it.
        let fresh = AgentBadgeKind.of(Self.paper(.done, seen: false), status: Self.on, queuePosition: nil)
        #expect(fresh == .fresh && fresh?.showsOnCard == false)
        // Incomplete text: the inspector's file notes say it.
        let partial = AgentBadgeKind.of(Self.paper(.done, text: .partial), status: Self.on, queuePosition: nil)
        #expect(partial == .textIncomplete && partial?.showsOnCard == false)
        #expect(AgentBadgeKind.of(Self.paper(.none, text: .poor), status: Self.on, queuePosition: nil) == .textIncomplete)
        // Nothing at all for a read, seen paper.
        #expect(AgentBadgeKind.of(Self.paper(.done), status: Self.on, queuePosition: nil) == nil)
        #expect(AgentBadgeKind.of(Self.paper(.none), status: Self.on, queuePosition: nil) == nil)
    }

    @Test func theKindCarriesTheQueueDetails() {
        let since = Date(timeIntervalSince1970: 1_000)
        var p = Self.paper(.running)
        var status = Self.on
        status.runningPaperID = p.id
        status.runningSince = since
        #expect(AgentBadgeKind.of(p, status: status, queuePosition: nil) == .running(since: since))
        p.id = "other"
        #expect(AgentBadgeKind.of(p, status: status, queuePosition: nil) == .running(since: nil))
        #expect(AgentBadgeKind.of(Self.paper(.queued), status: Self.on, queuePosition: 3) == .queued(3))
        status.pausedUntil = since
        #expect(AgentBadgeKind.of(Self.paper(.limited), status: status, queuePosition: nil) == .limited(until: since))
    }

    // MARK: Priority mark and chips

    @Test func onlyAHighPriorityGetsAMark() {
        #expect(CardBadgeRules.showsPriorityMark(.high))
        #expect(!CardBadgeRules.showsPriorityMark(.normal))
        #expect(!CardBadgeRules.showsPriorityMark(.low))
    }

    @Test func twoChipsAtMostTheRestFoldIntoPlusN() {
        typealias C = CardBadgeRules.Chips
        #expect(CardBadgeRules.chips(hasCategory: true, tagCount: 3) == C(showsCategory: true, tags: 1, overflow: 2))
        #expect(CardBadgeRules.chips(hasCategory: true, tagCount: 1) == C(showsCategory: true, tags: 1, overflow: 0))
        #expect(CardBadgeRules.chips(hasCategory: true, tagCount: 0) == C(showsCategory: true, tags: 0, overflow: 0))
        #expect(CardBadgeRules.chips(hasCategory: false, tagCount: 4) == C(showsCategory: false, tags: 2, overflow: 2))
        #expect(CardBadgeRules.chips(hasCategory: false, tagCount: 0) == C(showsCategory: false, tags: 0, overflow: 0))
        #expect(CardBadgeRules.chips(hasCategory: true, tagCount: 2, budget: 1) == C(showsCategory: true, tags: 0, overflow: 2))
        #expect(CardBadgeRules.chips(hasCategory: true, tagCount: 2, budget: 0) == C(showsCategory: false, tags: 0, overflow: 2))
        for hasCategory in [true, false] {
            for tags in 0...6 {
                let c = CardBadgeRules.chips(hasCategory: hasCategory, tagCount: tags)
                #expect((c.showsCategory ? 1 : 0) + c.tags <= 2 && c.tags + c.overflow == tags)
            }
        }
    }

    // MARK: Notices

    @Test func noticesAreOrderedMostSevereFirstKeepingTheirOrder() {
        let ordered = NoticeQueue.ordered([(id: "missing", severity: .warning), (id: "login", severity: .error),
                                           (id: "at-risk", severity: .warning), (id: "tip", severity: .info),
                                           (id: "library", severity: .error)])
        #expect(ordered == ["login", "library", "missing", "at-risk", "tip"])
        #expect(NoticeQueue.ordered([(id: String, severity: NoticeQueue.Severity)]()).isEmpty)
    }

    @Test func oneNoticeIsShownAndThePagerWraps() {
        let ids = ["a", "b", "c"]
        #expect(NoticeQueue.shownIndex(ids, selected: nil) == 0)
        #expect(NoticeQueue.shownIndex(ids, selected: "c") == 2)
        #expect(NoticeQueue.shownIndex(ids, selected: "gone") == 0)          // it went away: the most severe
        #expect(NoticeQueue.shownIndex([String](), selected: "a") == nil)
        #expect(NoticeQueue.next(ids, after: "a") == "b")
        #expect(NoticeQueue.next(ids, after: "c") == "a")
        #expect(NoticeQueue.next(ids, after: nil) == "b")
        #expect(NoticeQueue.next(["only"], after: "only") == "only")
        #expect(NoticeQueue.next([String](), after: nil) == nil)
    }

    @Test func dismissingANoticeShowsTheNextOne() {
        let ids = ["a", "b", "c"]
        #expect(NoticeQueue.successor(ids, dismissing: "a") == "b")
        #expect(NoticeQueue.successor(ids, dismissing: "c") == "a")
        #expect(NoticeQueue.successor(["a"], dismissing: "a") == nil)
        #expect(NoticeQueue.successor(ids, dismissing: "gone") == "a")
    }

    @Test func aNoticeShowsTwoButtonsAtMostTheProminentFirst() {
        // Not signed in: How to Fix · I've Signed In · Settings… (prominent).
        let login = NoticeQueue.splitActions(prominent: [false, false, true])
        #expect(login.shown == [0, 2] && login.overflow == [1])
        // At risk: Push Back (prominent) · Ignore.
        let atRisk = NoticeQueue.splitActions(prominent: [true, false])
        #expect(atRisk.shown == [0, 1] && atRisk.overflow.isEmpty)
        #expect(NoticeQueue.splitActions(prominent: [false]).shown == [0])
        #expect(NoticeQueue.splitActions(prominent: []).shown.isEmpty)
        let many = NoticeQueue.splitActions(prominent: [false, true, false, true], limit: 2)
        #expect(many.shown == [1, 3] && many.overflow == [0, 2])
        #expect(NoticeQueue.splitActions(prominent: [true, true], limit: 0).overflow == [0, 1])
    }

    @Test func overTheMailInboxOnlyACriticalBannerAndOnlyWhenTheInboxIsQuiet() {
        // The inbox has its own notice line: the papers' warnings wait, an error shows only alone.
        #expect(NoticeQueue.showsOverInbox(.error, inboxHasNotice: false))
        #expect(!NoticeQueue.showsOverInbox(.error, inboxHasNotice: true))
        for severity in [NoticeQueue.Severity.warning, .info] {
            #expect(!NoticeQueue.showsOverInbox(severity, inboxHasNotice: false), "\(severity)")
            #expect(!NoticeQueue.showsOverInbox(severity, inboxHasNotice: true), "\(severity)")
        }
    }
}
