import Foundation
import PaperDeckShared

/// User's reading-plan settings (a value snapshot passed into pure planners).
package struct PlanSettings: Sendable, Equatable, Codable {
    package var dailyBudgetMinutes: Int
    package var readingWeekdays: Set<Int>       // Foundation weekdays, 1 = Sunday … 7 = Saturday
    package var cutoffHour: Int                 // at/after this local hour, today is no longer schedulable
    package var skipDays: Set<LocalDate>
    package var horizonDays: Int
    package var reminderHour: Int
    package var reminderMinute: Int
    package var remindWhenEmpty: Bool           // false → skip the daily reminder when nothing is left

    package init(dailyBudgetMinutes: Int = 60, readingWeekdays: Set<Int> = Set(1...7), cutoffHour: Int = 18,
                 skipDays: Set<LocalDate> = [], horizonDays: Int = 730, reminderHour: Int = 11,
                 reminderMinute: Int = 0, remindWhenEmpty: Bool = false) {
        self.dailyBudgetMinutes = dailyBudgetMinutes; self.readingWeekdays = readingWeekdays
        self.cutoffHour = cutoffHour; self.skipDays = skipDays; self.horizonDays = horizonDays
        self.reminderHour = reminderHour; self.reminderMinute = reminderMinute
        self.remindWhenEmpty = remindWhenEmpty
    }
}

/// The scheduler's view of a paper (pure input; built from Paper + checklist).
package struct SchedItem: Sendable, Equatable, Identifiable {
    package var id: String
    package var status: PaperStatus
    package var priority: Priority
    package var deadline: LocalDate?
    package var scheduleMode: ScheduleMode
    package var deadlineOrigin: DeadlineOrigin
    package var queueRank: Int
    package var remainingMinutes: Int           // Σ unchecked item minutes (est_minutes if no items)
    package var placementFloor: LocalDate?
    package var provisional: Bool

    package init(id: String, status: PaperStatus = .toRead, priority: Priority = .normal,
                 deadline: LocalDate? = nil, scheduleMode: ScheduleMode = .auto,
                 deadlineOrigin: DeadlineOrigin = .place, queueRank: Int, remainingMinutes: Int,
                 placementFloor: LocalDate? = nil, provisional: Bool = false) {
        self.id = id; self.status = status; self.priority = priority; self.deadline = deadline
        self.scheduleMode = scheduleMode; self.deadlineOrigin = deadlineOrigin; self.queueRank = queueRank
        self.remainingMinutes = remainingMinutes; self.placementFloor = placementFloor
        self.provisional = provisional
    }

    /// Participates in capacity accounting (live, not done, scheduled with a date).
    package var isActive: Bool { status != .done && scheduleMode != .none && deadline != nil }
}
