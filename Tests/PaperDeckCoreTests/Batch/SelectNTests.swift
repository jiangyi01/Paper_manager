import Foundation
import Testing
@testable import PaperDeckCore

/// Toolbar ▸ Select ▾ picks (READING_ASSIST_PLAN §9.1 C "Select-N"): pure functions over the
/// papers in the current view.
@Suite struct SelectNTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func paper(_ id: String, added: Int, status: PaperStatus = .toRead, deadline: LocalDate? = nil,
                      opened: Int? = nil, deleted: Bool = false) -> Paper {
        Paper(id: id, sha256: id, fileSize: 1, title: id, folder: "Papers/" + id, pdfName: id + ".pdf",
              originalName: id + ".pdf", status: status, deadline: deadline,
              scheduleMode: deadline == nil ? .none : .auto,
              addedAt: t0.addingTimeInterval(Double(added) * 60),
              openedAt: opened.map { t0.addingTimeInterval(Double($0) * 60) },
              deletedAt: deleted ? t0 : nil)
    }

    static func d(_ m: Int, _ day: Int) -> LocalDate { LocalDate(year: 2026, month: m, day: day) }

    @Test func mostRecentlyAddedIsNewestFirst() {
        let papers = [Self.paper("a", added: 1), Self.paper("b", added: 5), Self.paper("c", added: 3), Self.paper("d", added: 3)]
        #expect(SelectN.pick(.mostRecentlyAdded, n: 2, from: papers) == ["b", "c"])     // c / d tie → id order
        #expect(SelectN.pick(.mostRecentlyAdded, n: nil, from: papers) == ["b", "c", "d", "a"])
        #expect(SelectN.pick(.mostRecentlyAdded, n: 10, from: papers).count == 4)
        #expect(SelectN.pick(.mostRecentlyAdded, n: 0, from: papers).isEmpty)
        #expect(SelectN.pick(.mostRecentlyAdded, n: -1, from: papers).isEmpty)
    }

    @Test func oldestUnreadIsToReadByEarliestDeadlineThenLongestWaiting() {
        let papers = [
            Self.paper("late", added: 1, deadline: Self.d(10, 20)),
            Self.paper("soon", added: 9, deadline: Self.d(10, 2)),
            Self.paper("unscheduledOld", added: 0),
            Self.paper("unscheduledNew", added: 8),
            Self.paper("reading", added: 0, status: .reading, deadline: Self.d(10, 1)),
            Self.paper("done", added: 0, status: .done, deadline: Self.d(9, 1)),
            Self.paper("deleted", added: 0, deadline: Self.d(9, 1), deleted: true),
            Self.paper("sameDayOlder", added: 2, deadline: Self.d(10, 2)),
        ]
        #expect(SelectN.pick(.oldestUnread, n: nil, from: papers)
                == ["sameDayOlder", "soon", "late", "unscheduledOld", "unscheduledNew"])
        #expect(SelectN.pick(.oldestUnread, n: 2, from: papers) == ["sameDayOlder", "soon"])
        #expect(SelectN.available(.oldestUnread, from: papers) == 5)
    }

    @Test func recentlyOpenedPrefersThisSessionsOpens() {
        let papers = [
            Self.paper("a", added: 0, opened: 50),
            Self.paper("b", added: 0, opened: 10),
            Self.paper("c", added: 0),                 // never opened
            Self.paper("d", added: 0, opened: 30),
        ]
        // b was opened again from PaperDeck just now (RecentOpens, newest first); "x" isn't in the view.
        #expect(SelectN.pick(.recentlyOpened, n: nil, from: papers, recentOpens: ["b", "x", "b"]) == ["b", "a", "d"])
        #expect(SelectN.pick(.recentlyOpened, n: 2, from: papers) == ["a", "d"])
        #expect(SelectN.available(.recentlyOpened, from: [Self.paper("c", added: 0)]) == 0)
        #expect(SelectN.available(.recentlyOpened, from: [Self.paper("c", added: 0)], recentOpens: ["c"]) == 1)
    }
}
