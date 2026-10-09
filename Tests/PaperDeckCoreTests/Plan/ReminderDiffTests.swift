import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct ReminderDiffTests {
    private static let cal = LocalDate.gregorian(TimeZone(identifier: "America/Chicago")!)
    private static func d(_ s: String) -> LocalDate { LocalDate(iso: s)! }
    private static func spec(_ day: String, body: String = "body") -> ReminderSpec {
        let date = d(day)
        return ReminderSpec(day: date, hour: 11, minute: 0, fireDate: date.date(hour: 11, minute: 0, calendar: cal),
                            title: "t", subtitle: "s", body: body)
    }
    private static let plan = ["2026-10-01", "2026-10-02", "2026-10-03"].map { spec($0) }

    @Test func emptyCenterAddsEverything() {
        let r = ReminderComposer.diff(pending: [], delivered: [], plan: Self.plan, lastDelivered: nil)
        #expect(r.remove.isEmpty)
        #expect(r.add.map(\.id) == ["daily-2026-10-01", "daily-2026-10-02", "daily-2026-10-03"])
    }

    @Test func unchangedHashIsLeftAlone() {
        let pending = Self.plan.map { (id: $0.id, hash: $0.hash) }
        let r = ReminderComposer.diff(pending: pending, delivered: [], plan: Self.plan, lastDelivered: nil)
        #expect(r.remove.isEmpty && r.add.isEmpty)
    }

    @Test func changedHashIsReplaced() {
        var pending = Self.plan.map { (id: $0.id, hash: $0.hash) }
        pending[1].hash = "0000000000000000"
        let r = ReminderComposer.diff(pending: pending, delivered: [], plan: Self.plan, lastDelivered: nil)
        #expect(r.remove == ["daily-2026-10-02"])
        #expect(r.add.map(\.id) == ["daily-2026-10-02"])
    }

    @Test func deliveredIdIsNeverReadded() {
        let r = ReminderComposer.diff(pending: [], delivered: ["daily-2026-10-01"], plan: Self.plan, lastDelivered: nil)
        #expect(r.add.map(\.id) == ["daily-2026-10-02", "daily-2026-10-03"])
        #expect(r.remove.isEmpty)
    }

    @Test func lastDeliveredDayIsNeverAdded() {
        let r = ReminderComposer.diff(pending: [], delivered: [], plan: Self.plan, lastDelivered: Self.d("2026-10-01"))
        #expect(r.add.map(\.id) == ["daily-2026-10-02", "daily-2026-10-03"])
        // Catch-up already delivered today but the calendar request is still pending → drop it.
        let pending = [(id: "daily-2026-10-01", hash: Self.plan[0].hash)]
        let r2 = ReminderComposer.diff(pending: pending, delivered: [], plan: Self.plan, lastDelivered: Self.d("2026-10-01"))
        #expect(r2.remove == ["daily-2026-10-01"])
        #expect(!r2.add.contains { $0.id == "daily-2026-10-01" })
    }

    @Test func staleDailyRequestsAreRemovedOthersKept() {
        let pending = [
            (id: "daily-2026-09-30", hash: "x"),          // yesterday, missed
            (id: "daily-2026-10-01", hash: Self.plan[0].hash),
            (id: "remind-1h-2026-10-01", hash: "y"),      // not ours to manage here
            (id: "daily-2026-10-20", hash: "z"),          // beyond the new window / day composed to nil
        ]
        let r = ReminderComposer.diff(pending: pending, delivered: [], plan: Self.plan, lastDelivered: nil)
        #expect(r.remove == ["daily-2026-09-30", "daily-2026-10-20"])
        #expect(r.add.map(\.id) == ["daily-2026-10-02", "daily-2026-10-03"])
    }

    @Test func duplicatePendingEntriesAreHandled() {
        let pending = [(id: "daily-2026-10-09", hash: "a"), (id: "daily-2026-10-09", hash: "a")]
        let r = ReminderComposer.diff(pending: pending, delivered: [], plan: [], lastDelivered: nil)
        #expect(r.remove == ["daily-2026-10-09"])
        #expect(r.add.isEmpty)
    }

    /// Same texts at another time (11:00 → 09:00, or 11:00 → 11:30): every pending request is
    /// replaced, so nothing keeps ringing at the old time.
    @Test func reminderTimeChangeReplacesPendingRequests() {
        func spec(_ day: String, _ hour: Int, _ minute: Int) -> ReminderSpec {
            let date = Self.d(day)
            return ReminderSpec(day: date, hour: hour, minute: minute,
                                fireDate: date.date(hour: hour, minute: minute, calendar: Self.cal),
                                title: "t", subtitle: "s", body: "body")
        }
        let days = ["2026-10-01", "2026-10-02"]
        let at11 = days.map { spec($0, 11, 0) }
        let pending = at11.map { (id: $0.id, hash: $0.hash) }
        for (hour, minute) in [(9, 0), (11, 30)] {
            let moved = days.map { spec($0, hour, minute) }
            let r = ReminderComposer.diff(pending: pending, delivered: [], plan: moved, lastDelivered: nil)
            #expect(r.remove == at11.map(\.id))
            #expect(r.add.map(\.id) == moved.map(\.id))
            #expect(r.add.allSatisfy { $0.fireComponents.hour == hour && $0.fireComponents.minute == minute })
        }
        let same = ReminderComposer.diff(pending: pending, delivered: [], plan: days.map { spec($0, 11, 0) },
                                         lastDelivered: nil)
        #expect(same.remove.isEmpty && same.add.isEmpty)
    }

    @Test func realPlanRoundTrip() {
        let settings = PlanSettings(dailyBudgetMinutes: 60, readingWeekdays: [2, 3, 4, 5, 6])
        let papers = [ReminderPaper(item: SchedItem(id: "a", deadline: Self.d("2026-10-02"), queueRank: 1, remainingMinutes: 90),
                                    title: "A paper")]
        let now = Self.d("2026-09-29").date(hour: 9, minute: 0, calendar: Self.cal)
        let plan = ReminderComposer.plan(from: now, papers: papers, settings: settings, lang: .zh, calendar: Self.cal)
        let first = ReminderComposer.diff(pending: [], delivered: [], plan: plan, lastDelivered: nil)
        #expect(first.add.count == 14)
        // After scheduling, the same plan is a no-op.
        let pending = first.add.map { (id: $0.id, hash: $0.hash) }
        let second = ReminderComposer.diff(pending: pending, delivered: [], plan: plan, lastDelivered: nil)
        #expect(second.remove.isEmpty && second.add.isEmpty)
        // Progress changes the bodies → replaced (never the delivered first day).
        var progressed = papers
        progressed[0].item.remainingMinutes = 30
        let plan2 = ReminderComposer.plan(from: now.addingTimeInterval(3 * 3600), papers: progressed, settings: settings,
                                          lang: .zh, calendar: Self.cal)
        let third = ReminderComposer.diff(pending: Array(pending.dropFirst()), delivered: [plan[0].id], plan: plan2,
                                          lastDelivered: Self.d("2026-09-29"))
        #expect(!third.add.contains { $0.day == Self.d("2026-09-29") })
        #expect(!third.remove.isEmpty)
        #expect(Set(third.remove).isSubset(of: Set(third.add.map(\.id))))
    }
}
