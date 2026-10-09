import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct TodaySetTests {
    private static let cal = LocalDate.gregorian(TimeZone(identifier: "America/Chicago")!)
    private static let weekdays60 = PlanSettings(dailyBudgetMinutes: 60, readingWeekdays: [2, 3, 4, 5, 6])
    private static func d(_ s: String) -> LocalDate { LocalDate(iso: s)! }
    private static func at(_ day: String, _ h: Int, _ m: Int = 0) -> Date { d(day).date(hour: h, minute: m, calendar: cal) }
    private static func plan(_ items: [SchedItem], _ day: String = "2026-09-29", _ h: Int = 10,
                             settings: PlanSettings = weekdays60) -> TodayPlan {
        TodaySet.compute(items, settings: settings, now: at(day, h), calendar: cal)
    }
    private static func item(_ id: String, _ deadline: String?, _ minutes: Int, rank: Int, priority: Priority = .normal,
                             mode: ScheduleMode = .auto, status: PaperStatus = .toRead) -> SchedItem {
        SchedItem(id: id, status: status, priority: priority, deadline: deadline.map(d), scheduleMode: mode,
                  queueRank: rank, remainingMinutes: minutes)
    }

    @Test func overdueDueTodayAndPlanned() {
        let items = [
            Self.item("P", "2026-10-02", 100, rank: 3),
            Self.item("T", "2026-09-29", 20, rank: 2),
            Self.item("O", "2026-09-28", 30, rank: 1),
            Self.item("U", "2026-10-01", 15, rank: 4),
            Self.item("far", "2026-10-20", 15, rank: 5),
        ]
        let p = Self.plan(items)
        #expect(p.today == Self.d("2026-09-29"))
        #expect(p.overdue == ["O"])
        #expect(p.dueToday == ["T"])
        // 9/29: O 30 + T 20 → U (10/1) gets the last 10′ (EDF), which is exactly the 10′ threshold.
        #expect(p.plannedToday == [.init(id: "U", minutes: 10)])
        #expect(p.ids == ["O", "T", "U"])
        #expect(p.count == 3)
        #expect(p.todayMinutes == 60)
        #expect(p.minutesToday == ["O": 30, "T": 20, "U": 10])
        #expect(p.upcoming == ["P"])                          // U is already in today's set; far is Δ21
        #expect(p.nextDeadline == .init(id: "U", date: Self.d("2026-10-01")))
        #expect(p.backlogTotal == 5)
        #expect(p.unscheduled == 0)
    }

    @Test func upcomingWithinSixDaysExcludesTodaySet() {
        let items = [
            Self.item("today", "2026-09-29", 60, rank: 1),
            Self.item("thu", "2026-10-01", 30, rank: 2),
            Self.item("mon", "2026-10-05", 30, rank: 3),
            Self.item("tue", "2026-10-06", 30, rank: 4),      // Δ7: outside the window
        ]
        let p = Self.plan(items)
        #expect(p.ids == ["today"])
        #expect(p.upcoming == ["thu", "mon"])
    }

    @Test func smallSlicesAreNotListedNorCounted() {
        let items = [
            Self.item("T", "2026-09-29", 25, rank: 1),
            Self.item("O", "2026-09-28", 30, rank: 2),
            Self.item("P", "2026-10-02", 100, rank: 3),       // gets 5′ today
        ]
        let p = Self.plan(items)
        #expect(p.simulation.minutes(of: "P", on: Self.d("2026-09-29")) == 5)
        #expect(p.plannedToday.isEmpty)
        #expect(p.todayMinutes == 55)
        #expect(p.minutesToday["P"] == nil)
    }

    @Test func overdueSortedMostOverdueFirstAndCountFullRemaining() {
        let items = [
            Self.item("o2", "2026-09-27", 90, rank: 1),
            Self.item("o1", "2026-09-20", 80, rank: 2),
            Self.item("o3", "2026-09-27", 10, rank: 0, priority: .high),
        ]
        let p = Self.plan(items)
        #expect(p.overdue == ["o1", "o3", "o2"])
        #expect(p.todayMinutes == 180)                        // full remaining, not just today's 60′
        #expect(p.plannedToday.isEmpty)
    }

    @Test func afterCutoffNothingIsPlannedButDueStillListed() {
        let items = [
            Self.item("T", "2026-09-29", 20, rank: 1),
            Self.item("P", "2026-10-02", 100, rank: 2),
        ]
        let p = Self.plan(items, "2026-09-29", 19)
        #expect(p.startDay == Self.d("2026-09-30"))
        #expect(p.dueToday == ["T"])
        #expect(p.plannedToday.isEmpty)
        #expect(p.todayMinutes == 20)
        #expect(p.atRisk == ["T"])                            // can only finish tomorrow now
    }

    @Test func nonReadingDayHasNoPlan() {
        let items = [
            Self.item("over", "2026-10-01", 20, rank: 1),
            Self.item("mon", "2026-10-05", 30, rank: 2),
        ]
        let p = Self.plan(items, "2026-10-03", 10)            // Saturday
        #expect(p.startDay == Self.d("2026-10-05"))
        #expect(p.overdue == ["over"])
        #expect(p.plannedToday.isEmpty)
        #expect(p.upcoming == ["mon"])
        #expect(p.nextDeadline?.id == "mon")
    }

    @Test func backlogCountsAndUnscheduled() {
        let items = [
            Self.item("a", "2026-10-01", 30, rank: 1),
            Self.item("none", nil, 30, rank: 2, mode: .none),
            Self.item("nodate", nil, 30, rank: 3),            // auto without a date also counts as unscheduled
            Self.item("done", "2026-09-29", 0, rank: 4, status: .done),
            Self.item("reading", nil, 10, rank: 5, mode: .none, status: .reading),
        ]
        let p = Self.plan(items)
        #expect(p.backlogTotal == 4)
        #expect(p.unscheduled == 3)
        #expect(p.dueToday.isEmpty)                           // the done paper is not "due"
        #expect(p.ids == ["a"])
    }

    @Test func workedExampleAtRiskAndFinish() {
        let s = Scheduler(settings: Self.weekdays60, now: Self.at("2026-09-29", 10), calendar: Self.cal)
        let items = [
            SchedItem(id: "A", deadline: Self.d("2026-09-30"), queueRank: 1, remainingMinutes: 75),
            SchedItem(id: "B", deadline: Self.d("2026-10-02"), queueRank: 2, remainingMinutes: 150),
            SchedItem(id: "C", priority: .low, deadline: Self.d("2026-10-05"), queueRank: 3, remainingMinutes: 45),
            SchedItem(id: "D", deadline: Self.d("2026-10-06"), queueRank: 4, remainingMinutes: 60),
            SchedItem(id: "E", priority: .high, deadline: Self.d("2026-09-29"), queueRank: 5, remainingMinutes: 60),
        ]
        let p = TodaySet.compute(items, scheduler: s)
        #expect(p.dueToday == ["E"])
        #expect(p.plannedToday.isEmpty)
        #expect(p.todayMinutes == 60)
        #expect(p.atRisk == ["A", "B", "C", "D"])
        #expect(p.finish["D"] == Self.d("2026-10-07"))
        #expect(p.upcoming == ["A", "B", "C"])                // 10/5 is Δ6, inside the window; D (Δ7) is not
    }

    @Test func emptyLibrary() {
        let p = Self.plan([])
        #expect(p.isEmpty)
        #expect(p.backlogTotal == 0)
        #expect(p.nextDeadline == nil)
        #expect(p.todayMinutes == 0)
    }
}
