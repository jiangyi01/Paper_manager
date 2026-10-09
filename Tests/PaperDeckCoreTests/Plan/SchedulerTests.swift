import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct SchedulerTests {
    private static let cal = LocalDate.gregorian(TimeZone(identifier: "America/Chicago")!)
    private static let weekdays60 = PlanSettings(dailyBudgetMinutes: 60, readingWeekdays: [2, 3, 4, 5, 6])

    private static func d(_ s: String) -> LocalDate { LocalDate(iso: s)! }
    private static func at(_ day: String, _ h: Int, _ m: Int = 0) -> Date { d(day).date(hour: h, minute: m, calendar: cal) }
    private static func scheduler(_ settings: PlanSettings = weekdays60, _ day: String = "2026-09-29", _ h: Int = 10,
                                  _ m: Int = 0) -> Scheduler {
        Scheduler(settings: settings, now: at(day, h, m), calendar: cal)
    }
    private static func deadlines(_ items: [SchedItem]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.deadline?.iso ?? "nil") })
    }
    private static func apply(_ changed: [SchedItem], to items: inout [SchedItem]) {
        for c in changed { if let i = items.firstIndex(where: { $0.id == c.id }) { items[i] = c } }
    }

    // MARK: §6.3 worked example

    /// B=60, W=Mon–Fri, now = Tue 2026-09-29 10:00. Drop A normal 90′ (Claude
    /// returns 75′), B normal 150′, C low 45′, D normal 60′, E high 60′.
    @Test func workedExample() throws {
        let s = Self.scheduler()
        #expect(s.startDay == Self.d("2026-09-29"))
        let now = Self.at("2026-09-29", 10)
        var items: [SchedItem] = []
        func drop(_ id: String, _ priority: Priority, _ minutes: Int, rank: Int) {
            let q = SchedItem(id: id, priority: priority, queueRank: rank, remainingMinutes: minutes, provisional: true)
            items.append(s.place(q, among: items))
        }

        drop("A", .normal, 90, rank: 1)
        #expect(items[0].deadline == Self.d("2026-09-30"))
        // Claude's 75′ arrives before the next drop: |75−90| = 15 triggers the one-time
        // re-place from placement_floor; the answer is still 9/30.
        var a = items[0]
        a.remainingMinutes = 75
        items[0] = s.applyAgentEstimate(a, heuristicMinutes: 90, agentMinutes: 75, addedAt: now.addingTimeInterval(-30),
                                        among: items)
        #expect(items[0].deadline == Self.d("2026-09-30"))
        #expect(items[0].placementFloor == Self.d("2026-09-29"))
        #expect(items[0].provisional == false)

        drop("B", .normal, 150, rank: 2)
        drop("C", .low, 45, rank: 3)
        drop("D", .normal, 60, rank: 4)
        drop("E", .high, 60, rank: 5)
        #expect(Self.deadlines(items) == ["A": "2026-09-30", "B": "2026-10-02", "C": "2026-10-05",
                                          "D": "2026-10-06", "E": "2026-09-29"])
        #expect(items.allSatisfy { $0.deadlineOrigin == .place && $0.scheduleMode == .auto })
        // Floors: tail(normal) after A = 9/30; tail(low) = 10/2; E (high) competes with nobody.
        #expect(items.map { $0.placementFloor?.iso } == ["2026-09-29", "2026-09-30", "2026-10-02", "2026-10-02", "2026-09-29"])

        let sim = s.simulate(items)
        #expect(sim.atRisk == ["A", "B", "C", "D"])
        #expect(sim.order == ["E", "A", "B", "C", "D"])
        #expect(sim.allocation[Self.d("2026-09-29")] == [.init(id: "E", minutes: 60)])
        #expect(sim.allocation[Self.d("2026-09-30")] == [.init(id: "A", minutes: 60)])
        #expect(sim.allocation[Self.d("2026-10-01")] == [.init(id: "A", minutes: 15), .init(id: "B", minutes: 45)])
        #expect(sim.allocation[Self.d("2026-10-03")] == nil)      // weekend

        // 顺延受影响的 4 篇.
        let shifted = s.shiftAtRisk(items)
        #expect(Set(shifted.map(\.id)) == ["A", "B", "C", "D"])
        #expect(shifted.allSatisfy { $0.deadlineOrigin == .user && $0.scheduleMode == .auto })
        Self.apply(shifted, to: &items)
        #expect(Self.deadlines(items) == ["A": "2026-10-01", "B": "2026-10-05", "C": "2026-10-06",
                                          "D": "2026-10-07", "E": "2026-09-29"])
        #expect(s.simulate(items).atRisk.isEmpty)

        // 今天跳过.
        let skip = s.skipToday(items)
        #expect(skip.skipDays == [Self.d("2026-09-29")])
        #expect(skip.changed.count == 5)
        Self.apply(skip.changed, to: &items)
        #expect(Self.deadlines(items) == ["A": "2026-10-02", "B": "2026-10-06", "C": "2026-10-07",
                                          "D": "2026-10-08", "E": "2026-09-30"])
        #expect(items.allSatisfy { $0.deadlineOrigin == .user })
    }

    /// Without the agent revision (A stays 90′) the table is identical.
    @Test func workedExampleWithoutAgentEstimate() {
        let s = Self.scheduler()
        var items: [SchedItem] = []
        for (i, (id, pr, min)) in [("A", Priority.normal, 90), ("B", .normal, 150), ("C", .low, 45),
                                   ("D", .normal, 60), ("E", .high, 60)].enumerated() {
            items.append(s.place(SchedItem(id: id, priority: pr, queueRank: i, remainingMinutes: min), among: items))
        }
        #expect(Self.deadlines(items) == ["A": "2026-09-30", "B": "2026-10-02", "C": "2026-10-05",
                                          "D": "2026-10-06", "E": "2026-09-29"])
        let sim = s.simulate(items)
        #expect(sim.atRisk == ["A", "B", "C", "D"])
        #expect(sim.finish.mapValues(\.iso) == ["E": "2026-09-29", "A": "2026-10-01", "B": "2026-10-05",
                                                "C": "2026-10-06", "D": "2026-10-07"])
    }

    // MARK: startDay / cutoff

    @Test func cutoffHourExcludesToday() {
        #expect(Self.scheduler(Self.weekdays60, "2026-09-29", 17, 59).startDay == Self.d("2026-09-29"))
        let late = Self.scheduler(Self.weekdays60, "2026-09-29", 18, 0)
        #expect(late.startDay == Self.d("2026-09-30"))
        #expect(late.today == Self.d("2026-09-29"))
        let q = late.place(SchedItem(id: "q", queueRank: 1, remainingMinutes: 60), among: [])
        #expect(q.deadline == Self.d("2026-09-30"))
        #expect(q.placementFloor == Self.d("2026-09-30"))
        // A paper due today is still due today; after the cutoff it can only finish tomorrow → at risk.
        let dueToday = SchedItem(id: "t", deadline: Self.d("2026-09-29"), queueRank: 1, remainingMinutes: 30)
        #expect(late.effectiveDeadline(dueToday) == Self.d("2026-09-30"))
        #expect(late.simulate([dueToday]).atRisk == ["t"])
    }

    @Test func cutoffHourOnFridayJumpsTheWeekend() {
        let s = Self.scheduler(Self.weekdays60, "2026-10-02", 19)
        #expect(s.startDay == Self.d("2026-10-05"))
    }

    // MARK: horizon

    @Test func horizonExceededLeavesPaperUnscheduled() {
        var settings = Self.weekdays60
        settings.horizonDays = 10
        let s = Self.scheduler(settings)
        let fits = s.place(SchedItem(id: "a", queueRank: 1, remainingMinutes: 300), among: [])
        #expect(fits.deadline == Self.d("2026-10-05"))
        let tooBig = s.place(SchedItem(id: "b", queueRank: 2, remainingMinutes: 1000), among: [fits])
        #expect(tooBig.scheduleMode == .none)
        #expect(tooBig.deadline == nil)
        #expect(tooBig.deadlineOrigin == .place)
        #expect(tooBig.isActive == false)
    }

    @Test func noCapacityAtAllNeverPlaces() {
        let s = Self.scheduler(PlanSettings(dailyBudgetMinutes: 60, readingWeekdays: []))
        #expect(s.place(SchedItem(id: "a", queueRank: 1, remainingMinutes: 10), among: []).scheduleMode == .none)
        #expect(s.nextReadingDay(after: Self.d("2026-09-29")) == Self.d("2026-09-30"))
        #expect(s.simulate([SchedItem(id: "p", deadline: Self.d("2026-10-01"), queueRank: 1, remainingMinutes: 5)]).atRisk == ["p"])
    }

    // MARK: pinned / priority

    @Test func pinnedPaperConsumesCapacity() {
        let s = Self.scheduler()
        let pinned = SchedItem(id: "p", deadline: Self.d("2026-09-29"), scheduleMode: .pinned, deadlineOrigin: .user,
                               queueRank: 1, remainingMinutes: 60)
        let q = s.place(SchedItem(id: "q", queueRank: 2, remainingMinutes: 60), among: [pinned])
        #expect(q.deadline == Self.d("2026-09-30"))
        // A pinned paper is not an auto tail: a later pin does not push lo.
        let farPin = SchedItem(id: "f", deadline: Self.d("2026-12-01"), scheduleMode: .pinned, queueRank: 3, remainingMinutes: 30)
        let r = s.place(SchedItem(id: "r", queueRank: 4, remainingMinutes: 30), among: [farPin])
        #expect(r.deadline == Self.d("2026-09-29"))
    }

    @Test func highPriorityCompetesOnlyWithHighAndPinned() throws {
        let s = Self.scheduler()
        var items = [
            SchedItem(id: "n", deadline: Self.d("2026-09-29"), queueRank: 1, remainingMinutes: 60),
            SchedItem(id: "p", deadline: Self.d("2026-09-30"), scheduleMode: .pinned, deadlineOrigin: .user,
                      queueRank: 2, remainingMinutes: 60),
        ]
        let h = s.place(SchedItem(id: "h", priority: .high, queueRank: 3, remainingMinutes: 60), among: items)
        #expect(h.deadline == Self.d("2026-09-29"))
        items.append(h)
        let h2 = s.place(SchedItem(id: "h2", priority: .high, queueRank: 4, remainingMinutes: 60), among: items)
        // tail(high) = 9/29; 9/29 is full with h; 9/30 is full with the pin → 10/1.
        #expect(h2.deadline == Self.d("2026-10-01"))

        let sim = s.simulate(items)
        #expect(sim.order == ["h", "n", "p"])
        #expect(sim.atRisk == ["n", "p"])
        // 顺延 moves the auto paper only; the pin stays and remains flagged.
        let shifted = s.shiftAtRisk(items)
        #expect(shifted.map(\.id) == ["n"])
        try #require(shifted.count > 0)          // no index past a failed expectation (QA-15)
        #expect(shifted[0].deadline == Self.d("2026-09-30"))
    }

    @Test func lowPriorityGoesAfterEveryAutoDeadline() {
        let s = Self.scheduler()
        let items = [
            SchedItem(id: "far", deadline: Self.d("2026-10-20"), queueRank: 1, remainingMinutes: 10),
            SchedItem(id: "pin", deadline: Self.d("2026-11-20"), scheduleMode: .pinned, queueRank: 2, remainingMinutes: 10),
        ]
        let low = s.place(SchedItem(id: "l", priority: .low, queueRank: 3, remainingMinutes: 10), among: items)
        #expect(low.deadline == Self.d("2026-10-20"))
        #expect(low.placementFloor == Self.d("2026-10-20"))
        // A normal paper only waits for normal/high autos.
        let lowAuto = SchedItem(id: "la", priority: .low, deadline: Self.d("2026-10-30"), queueRank: 4, remainingMinutes: 10)
        let n = s.place(SchedItem(id: "n", queueRank: 5, remainingMinutes: 10), among: [lowAuto])
        #expect(n.deadline == Self.d("2026-09-29"))
    }

    @Test func slackIsCheckedAtEveryLaterCheckpoint() {
        let s = Self.scheduler()
        // Tight pinned load on 10/1 (180′ = all capacity through Thu).
        let pin = SchedItem(id: "p", deadline: Self.d("2026-10-01"), scheduleMode: .pinned, queueRank: 1, remainingMinutes: 180)
        let q = s.place(SchedItem(id: "q", queueRank: 2, remainingMinutes: 30), among: [pin])
        // 9/29 has slack 60 locally, but slack(10/1) = 0 < 30 → first feasible day is Fri 10/2.
        #expect(q.deadline == Self.d("2026-10-02"))
    }

    @Test func overdueDemandCountsFromStartDay() {
        let s = Self.scheduler()
        let overdue = SchedItem(id: "o", deadline: Self.d("2026-09-20"), queueRank: 1, remainingMinutes: 60)
        #expect(s.effectiveDeadline(overdue) == Self.d("2026-09-29"))
        let q = s.place(SchedItem(id: "q", queueRank: 2, remainingMinutes: 60), among: [overdue])
        #expect(q.deadline == Self.d("2026-09-30"))
        // Overdue papers are not at risk (deadline < today) but are simulated first.
        let sim = s.simulate([overdue, q])
        #expect(sim.atRisk.isEmpty)
        #expect(sim.order == ["o", "q"])
    }

    @Test func doneAndUnscheduledPapersIgnored() {
        let s = Self.scheduler()
        let items = [
            SchedItem(id: "done", status: .done, deadline: Self.d("2026-09-29"), queueRank: 1, remainingMinutes: 60),
            SchedItem(id: "none", deadline: nil, scheduleMode: .none, queueRank: 2, remainingMinutes: 60),
        ]
        #expect(s.place(SchedItem(id: "q", queueRank: 3, remainingMinutes: 60), among: items).deadline == Self.d("2026-09-29"))
        #expect(s.simulate(items) == Scheduler.Simulation())
    }

    @Test func restoreAutoReplacesPinnedPaper() {
        let s = Self.scheduler()
        let q = SchedItem(id: "q", deadline: Self.d("2026-12-24"), scheduleMode: .pinned, deadlineOrigin: .user,
                          queueRank: 1, remainingMinutes: 45)
        let out = s.restoreAuto(q, among: [q])
        #expect(out.scheduleMode == .auto)
        #expect(out.deadlineOrigin == .place)
        #expect(out.deadline == Self.d("2026-09-29"))     // q itself is not in its own competition
    }

    @Test func zeroRemainingPlacesAtFloorAndFinishesToday() {
        let s = Self.scheduler()
        let q = s.place(SchedItem(id: "q", queueRank: 1, remainingMinutes: 0), among: [])
        #expect(q.deadline == Self.d("2026-09-29"))
        let sim = s.simulate([q])
        #expect(sim.finish["q"] == Self.d("2026-09-29"))
        #expect(sim.atRisk.isEmpty)
    }

    // MARK: weekend / reading days

    @Test func weekendHasNoCapacity() {
        let s = Self.scheduler(Self.weekdays60, "2026-10-02", 10)       // Friday
        let a = s.place(SchedItem(id: "a", queueRank: 1, remainingMinutes: 90), among: [])
        #expect(a.deadline == Self.d("2026-10-05"))
        #expect(s.cap(Self.d("2026-10-03")) == 0)
        #expect(s.cap(Self.d("2026-10-05")) == 60)
        #expect(s.nextReadingDay(after: Self.d("2026-10-02")) == Self.d("2026-10-05"))
        #expect(s.snapToReadingDay(Self.d("2026-10-03")) == Self.d("2026-10-05"))
        #expect(s.snapToReadingDay(Self.d("2026-10-02")) == Self.d("2026-10-02"))
        let sim = s.simulate([a])
        #expect(sim.allocation[Self.d("2026-10-02")] == [.init(id: "a", minutes: 60)])
        #expect(sim.allocation[Self.d("2026-10-05")] == [.init(id: "a", minutes: 30)])
        #expect(sim.finish["a"] == Self.d("2026-10-05"))
    }

    @Test func weekendNowStartsMonday() {
        let s = Self.scheduler(Self.weekdays60, "2026-10-03", 9)        // Saturday
        #expect(s.startDay == Self.d("2026-10-05"))
        let fri = SchedItem(id: "f", deadline: Self.d("2026-10-02"), queueRank: 1, remainingMinutes: 30)
        #expect(s.effectiveDeadline(fri) == Self.d("2026-10-05"))
    }

    // MARK: skip days

    @Test func skipDaysRemoveCapacity() {
        var settings = Self.weekdays60
        settings.skipDays = [Self.d("2026-09-30")]
        let s = Self.scheduler(settings)
        #expect(s.isReadingDay(Self.d("2026-09-30")) == false)
        #expect(s.nextReadingDay(after: Self.d("2026-09-29")) == Self.d("2026-10-01"))
        let a = s.place(SchedItem(id: "a", queueRank: 1, remainingMinutes: 90), among: [])
        #expect(a.deadline == Self.d("2026-10-01"))
        // Skipping today moves startDay.
        settings.skipDays.insert(Self.d("2026-09-29"))
        #expect(Self.scheduler(settings).startDay == Self.d("2026-10-01"))
    }

    @Test func skipTodayLeavesOverdueAndPinnedAlone() throws {
        let s = Self.scheduler()
        let items = [
            SchedItem(id: "over", deadline: Self.d("2026-09-28"), queueRank: 1, remainingMinutes: 30),
            SchedItem(id: "pin", deadline: Self.d("2026-09-29"), scheduleMode: .pinned, deadlineOrigin: .user,
                      queueRank: 2, remainingMinutes: 30),
            SchedItem(id: "auto", deadline: Self.d("2026-10-02"), queueRank: 3, remainingMinutes: 30),
            SchedItem(id: "done", status: .done, deadline: Self.d("2026-09-29"), queueRank: 4, remainingMinutes: 0),
            SchedItem(id: "none", scheduleMode: .none, queueRank: 5, remainingMinutes: 30),
        ]
        let r = s.skipToday(items)
        #expect(r.changed.map(\.id) == ["auto"])
        try #require(r.changed.count > 0)          // no index past a failed expectation (QA-15)
        #expect(r.changed[0].deadline == Self.d("2026-10-05"))       // Fri → next reading day Mon
        #expect(r.changed[0].scheduleMode == .auto)

        // Idempotent: once today is a skip day, nothing moves again.
        var settings = Self.weekdays60
        settings.skipDays = r.skipDays
        let again = Scheduler(settings: settings, now: Self.at("2026-09-29", 15), calendar: Self.cal).skipToday(items)
        #expect(again.changed.isEmpty)
        #expect(again.skipDays == r.skipDays)
    }

    // MARK: single-paper operations

    @Test func postponeDay() {
        let s = Self.scheduler()
        let fri = SchedItem(id: "a", deadline: Self.d("2026-10-02"), queueRank: 1, remainingMinutes: 10)
        let out = s.postponeDay(fri)
        #expect(out.deadline == Self.d("2026-10-05"))
        #expect(out.scheduleMode == .auto)
        #expect(out.deadlineOrigin == .user)
        // Overdue → counted from today.
        let pinnedOverdue = SchedItem(id: "b", deadline: Self.d("2026-09-20"), scheduleMode: .pinned, queueRank: 2,
                                      remainingMinutes: 10)
        let b = s.postponeDay(pinnedOverdue)
        #expect(b.deadline == Self.d("2026-09-30"))
        #expect(b.scheduleMode == .pinned)
        // Unscheduled papers are untouched.
        let none = SchedItem(id: "c", scheduleMode: .none, queueRank: 3, remainingMinutes: 10)
        #expect(s.postponeDay(none) == none)
    }

    @Test func postponeWeek() {
        let s = Self.scheduler()
        let a = s.postponeWeek(SchedItem(id: "a", deadline: Self.d("2026-10-02"), queueRank: 1, remainingMinutes: 10))
        #expect(a.deadline == Self.d("2026-10-09"))
        #expect(a.deadlineOrigin == .user)
        // Lands on a skip day → snaps forward.
        var settings = Self.weekdays60
        settings.skipDays = [Self.d("2026-10-06")]
        let s2 = Self.scheduler(settings)
        let b = s2.postponeWeek(SchedItem(id: "b", deadline: Self.d("2026-09-20"), queueRank: 2, remainingMinutes: 10))
        #expect(b.deadline == Self.d("2026-10-07"))                // max(9/20, 9/29) + 7 = 10/6 (skipped) → 10/7
        // Saturday + 7 → Saturday → snaps to Monday.
        #expect(s.postponeWeek(SchedItem(id: "c", deadline: Self.d("2026-10-03"), queueRank: 3, remainingMinutes: 1))
            .deadline == Self.d("2026-10-12"))
    }

    @Test func pinAndUnschedule() {
        let s = Self.scheduler()
        let q = SchedItem(id: "q", deadline: Self.d("2026-09-30"), queueRank: 1, remainingMinutes: 10)
        let pinned = s.pin(q, to: Self.d("2026-10-03"))           // any date, even a weekend
        #expect(pinned.deadline == Self.d("2026-10-03"))
        #expect(pinned.scheduleMode == .pinned)
        #expect(pinned.deadlineOrigin == .user)
        let none = s.unschedule(pinned)
        #expect(none.scheduleMode == .none)
        #expect(none.deadline == nil)
    }

    // MARK: provisional re-place (§6.2 applyAgentCard)

    @Test func agentEstimateReplacesProvisionalOnce() {
        let s = Self.scheduler()
        let now = Self.at("2026-09-29", 10)
        var items: [SchedItem] = []
        items.append(s.place(SchedItem(id: "a", queueRank: 1, remainingMinutes: 90, provisional: true), among: items))
        items.append(s.place(SchedItem(id: "b", queueRank: 2, remainingMinutes: 150, provisional: true), among: items))
        #expect(Self.deadlines(items) == ["a": "2026-09-30", "b": "2026-10-02"])

        var a = items[0]
        a.remainingMinutes = 30
        let revised = s.applyAgentEstimate(a, heuristicMinutes: 90, agentMinutes: 30, addedAt: now.addingTimeInterval(-3600),
                                           among: items)
        #expect(revised.deadline == Self.d("2026-09-29"))
        #expect(revised.placementFloor == Self.d("2026-09-29"))
        #expect(revised.provisional == false)
        #expect(revised.deadlineOrigin == .place)
    }

    @Test func agentEstimateLeavesDeadlineWhenRuleDoesNotApply() {
        let s = Self.scheduler()
        let now = Self.at("2026-09-29", 10)
        let placed = s.place(SchedItem(id: "a", queueRank: 1, remainingMinutes: 90, provisional: true), among: [])
        var small = placed; small.remainingMinutes = 30
        // |Δ| < 15
        let r1 = s.applyAgentEstimate(small, heuristicMinutes: 90, agentMinutes: 80, addedAt: now, among: [placed])
        #expect(r1.deadline == placed.deadline && r1.provisional == false)
        // imported ≥ 24 h ago
        let r2 = s.applyAgentEstimate(small, heuristicMinutes: 90, agentMinutes: 30, addedAt: now.addingTimeInterval(-86_400),
                                      among: [placed])
        #expect(r2.deadline == placed.deadline && r2.provisional == false)
        // user already moved it
        var userMoved = small; userMoved.deadlineOrigin = .user
        #expect(s.applyAgentEstimate(userMoved, heuristicMinutes: 90, agentMinutes: 30, addedAt: now, among: [placed])
            .deadline == placed.deadline)
        // not provisional any more
        var firm = small; firm.provisional = false
        #expect(s.applyAgentEstimate(firm, heuristicMinutes: 90, agentMinutes: 30, addedAt: now, among: [placed])
            .deadline == placed.deadline)
    }

    // MARK: building SchedItems

    @Test func remainingMinutesFromChecklist() {
        let items = [
            ChecklistItem(ord: 0, text: "a", minutes: 10, origin: .heuristic, doneAt: Date()),
            ChecklistItem(ord: 1, text: "b", minutes: 25, origin: .heuristic),
            ChecklistItem(ord: 2, text: "c", minutes: 15, origin: .agent),
        ]
        #expect(Scheduler.remainingMinutes(estMinutes: 999, checklist: items) == 40)
        #expect(Scheduler.remainingMinutes(estMinutes: 70, checklist: []) == 70)
        #expect(Scheduler.remainingMinutes(estMinutes: nil, checklist: []) == 0)
        let paper = Paper(id: "p1", sha256: "x", fileSize: 1, title: "T", folder: "f", pdfName: "p.pdf", originalName: "p.pdf",
                          priority: .high, deadline: Self.d("2026-10-01"), scheduleMode: .pinned, deadlineOrigin: .user,
                          queueRank: 7, placementFloor: Self.d("2026-09-29"), provisional: false, estMinutes: 50)
        let item = Scheduler.item(for: paper, checklist: items)
        #expect(item == SchedItem(id: "p1", priority: .high, deadline: Self.d("2026-10-01"), scheduleMode: .pinned,
                                  deadlineOrigin: .user, queueRank: 7, remainingMinutes: 40,
                                  placementFloor: Self.d("2026-09-29"), provisional: false))
    }

    // MARK: day arithmetic

    @Test func cumulativeCapacityMatchesBruteForce() {
        let skips: Set<LocalDate> = [Self.d("2026-10-01"), Self.d("2026-10-04"), Self.d("2026-12-25"), Self.d("2026-09-01")]
        for weekdays in [Set([2, 3, 4, 5, 6]), Set(1...7), Set([1, 7]), Set([4])] {
            let settings = PlanSettings(dailyBudgetMinutes: 45, readingWeekdays: weekdays, skipDays: skips)
            let s = Scheduler(settings: settings, now: Self.at("2026-09-29", 10), calendar: Self.cal)
            var brute = 0
            var day = s.startDay
            for _ in 0..<200 {
                brute += s.cap(day)
                #expect(s.cumulativeCapacity(through: day) == brute)
                day = day.adding(days: 1, calendar: Self.cal)
            }
            #expect(s.cumulativeCapacity(through: s.startDay.adding(days: -1, calendar: Self.cal)) == 0)
        }
    }

    @Test func dayArithmeticAcrossYearsLeapDaysAndDST() {
        let every = PlanSettings(dailyBudgetMinutes: 60)
        let s = Scheduler(settings: every, now: Self.at("2026-11-01", 1, 30), calendar: Self.cal)   // DST fall-back night
        #expect(s.today == Self.d("2026-11-01"))
        #expect(s.nextReadingDay(after: Self.d("2026-12-31")) == Self.d("2027-01-01"))
        #expect(s.nextReadingDay(after: Self.d("2028-02-28")) == Self.d("2028-02-29"))
        #expect(s.nextReadingDay(after: Self.d("2100-02-28")) == Self.d("2100-03-01"))
        #expect(s.nextReadingDay(after: Self.d("2027-03-13")) == Self.d("2027-03-14"))
        // Weekdays straddling DST and a leap day.
        let weekdays = Scheduler(settings: Self.weekdays60, now: Self.at("2027-03-12", 10), calendar: Self.cal)
        #expect(weekdays.nextReadingDay(after: Self.d("2027-03-12")) == Self.d("2027-03-15"))
        #expect(weekdays.snapToReadingDay(Self.d("2028-02-26")) == Self.d("2028-02-28"))
    }

    @Test func nonGregorianSystemCalendarGivesSameDays() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = Self.cal.timeZone
        let s = Scheduler(settings: Self.weekdays60, now: Self.at("2026-09-29", 10), calendar: buddhist)
        #expect(s.today == Self.d("2026-09-29"))
        #expect(s.place(SchedItem(id: "a", queueRank: 1, remainingMinutes: 90), among: []).deadline == Self.d("2026-09-30"))
    }

    @Test func simulationTieBreaksByPriorityThenQueueRank() {
        let s = Self.scheduler()
        let day = Self.d("2026-10-01")
        let items = [
            SchedItem(id: "n2", deadline: day, queueRank: 2, remainingMinutes: 10),
            SchedItem(id: "n1", deadline: day, queueRank: 1, remainingMinutes: 10),
            SchedItem(id: "hi", priority: .high, deadline: day, queueRank: 9, remainingMinutes: 10),
            SchedItem(id: "lo", priority: .low, deadline: day, queueRank: 0, remainingMinutes: 10),
        ]
        #expect(s.simulate(items).order == ["hi", "n1", "n2", "lo"])
    }

    @Test func farFuturePinWithoutCapacityTerminates() {
        let s = Self.scheduler(PlanSettings(dailyBudgetMinutes: 60, readingWeekdays: []))
        let pin = SchedItem(id: "p", deadline: Self.d("9999-12-31"), scheduleMode: .pinned, queueRank: 1, remainingMinutes: 30)
        let sim = s.simulate([pin])
        #expect(sim.finish["p"] == nil)
        #expect(sim.atRisk == ["p"])
    }

    @Test func largeLibraryStaysFast() {
        let s = Self.scheduler(PlanSettings(dailyBudgetMinutes: 60))
        var items: [SchedItem] = []
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<400 {
                items.append(s.place(SchedItem(id: "p\(i)", priority: .low, queueRank: i, remainingMinutes: 60 + i % 7 * 5),
                                     among: items))
            }
            _ = s.simulate(items)
        }
        #expect(items.filter { $0.scheduleMode == .auto }.count == 400)
        #expect(s.simulate(items).atRisk.isEmpty)
        #expect(elapsed < .seconds(10))
    }
}
