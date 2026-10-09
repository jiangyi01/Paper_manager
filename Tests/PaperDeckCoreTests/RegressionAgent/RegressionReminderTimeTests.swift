import Foundation
import Testing
@testable import PaperDeckCore
import PaperDeckShared

/// Finding 2: the reminder diff hash ignored the fire time, so moving 11:00 → 09:00 left every
/// pending request ringing at 11:00.
@Suite struct RegressionReminderTimeTests {
    private static let cal = LocalDate.gregorian(TimeZone(identifier: "America/Chicago")!)
    private static let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 8))!
    private static let papers = [ReminderPaper(item: SchedItem(id: "p1", deadline: LocalDate(iso: "2026-10-02"),
                                                               queueRank: 1, remainingMinutes: 90), title: "A paper")]

    private static func plan(hour: Int, minute: Int = 0) -> [ReminderSpec] {
        var s = PlanSettings()
        s.reminderHour = hour
        s.reminderMinute = minute
        return ReminderComposer.plan(from: now, papers: papers, settings: s, lang: .zh, calendar: cal)
    }

    /// Ported.
    @Test func changingTheReminderTimeReschedulesPendingRequests() {
        let old = Self.plan(hour: 11)
        let new = Self.plan(hour: 9)
        let pending = old.map { (id: $0.id, hash: $0.hash) }
        let (remove, add) = ReminderComposer.diff(pending: pending, delivered: [], plan: new, lastDelivered: nil)
        #expect(add.count == new.count, "moving the reminder from 11:00 to 09:00 left every pending request at 11:00")
        #expect(Set(remove) == Set(old.map(\.id)))
        #expect(add.allSatisfy { $0.fireComponents.hour == 9 && $0.fireComponents.minute == 0 })
    }

    @Test func changingOnlyTheMinuteAlsoReschedules() {
        let old = Self.plan(hour: 11, minute: 0)
        let new = Self.plan(hour: 11, minute: 30)
        #expect(old.map(\.body) == new.map(\.body))                   // same texts, different time
        let (remove, add) = ReminderComposer.diff(pending: old.map { (id: $0.id, hash: $0.hash) }, delivered: [],
                                                  plan: new, lastDelivered: nil)
        #expect(add.count == new.count && remove.count == old.count)
        #expect(add.allSatisfy { $0.fireComponents.minute == 30 })
    }

    @Test func sameTimeAndTextsKeepPendingRequests() {
        let a = Self.plan(hour: 11), b = Self.plan(hour: 11)
        let (remove, add) = ReminderComposer.diff(pending: a.map { (id: $0.id, hash: $0.hash) }, delivered: [],
                                                  plan: b, lastDelivered: nil)
        #expect(remove.isEmpty && add.isEmpty)
        #expect(a.allSatisfy { $0.userInfo["h"] == $0.hash })
    }
}
