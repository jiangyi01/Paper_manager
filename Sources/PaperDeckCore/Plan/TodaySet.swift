import Foundation

/// What "today" means for the reading plan (§6.3): overdue ∪ due today ∪
/// today's planned slices of ≥ 10 minutes, plus the backlog counts that every
/// surface (Today view, menu bar, reminder, widget) shows.
package struct TodayPlan: Sendable, Equatable {
    package struct NextDeadline: Sendable, Equatable {
        package var id: String
        package var date: LocalDate
    }

    package var today: LocalDate
    package var startDay: LocalDate
    /// Active papers with deadline < today, most overdue first.
    package var overdue: [String]
    /// Active papers due today (listed even after the cutoff hour).
    package var dueToday: [String]
    /// Other papers with ≥ 10′ allocated today, in EDF order.
    package var plannedToday: [Scheduler.Slice]
    /// Active papers due within the next 6 days that are not already in today's set.
    package var upcoming: [String]
    /// Full remaining minutes of overdue + due-today papers + the planned slices.
    package var todayMinutes: Int
    /// Minutes each paper in today's set contributes to `todayMinutes`.
    package var minutesToday: [String: Int]
    package var atRisk: Set<String>
    package var finish: [String: LocalDate]
    /// Soonest deadline strictly after today among active papers.
    package var nextDeadline: NextDeadline?
    /// N: papers with status ≠ done (callers pass live papers only).
    package var backlogTotal: Int
    /// M: of those, unscheduled (mode none or no deadline).
    package var unscheduled: Int
    package var simulation: Scheduler.Simulation

    /// Today's set in display order: overdue, due today, planned.
    package var ids: [String] { overdue + dueToday + plannedToday.map(\.id) }
    package var count: Int { overdue.count + dueToday.count + plannedToday.count }
    package var isEmpty: Bool { count == 0 }
}

package enum TodaySet {
    /// Smaller slices of today's budget are not worth listing as a task.
    package static let minPlannedMinutes = 10
    /// "本周接下来": deadlines within today+1 … today+6, matching the chip's weekday range.
    package static let upcomingDays = 6

    package static func compute(_ items: [SchedItem], settings: PlanSettings, now: Date,
                                calendar: Calendar = .current) -> TodayPlan {
        compute(items, scheduler: Scheduler(settings: settings, now: now, calendar: calendar))
    }

    package static func compute(_ items: [SchedItem], scheduler s: Scheduler) -> TodayPlan {
        let today = s.today
        let sim = s.simulate(items)
        // Active papers with their deadlines, by (deadline, −priority, queue_rank, id).
        let dated = items.compactMap { p -> (item: SchedItem, deadline: LocalDate)? in
            guard p.isActive, let d = p.deadline else { return nil }
            return (p, d)
        }.sorted { a, b in
            (a.deadline, -a.item.priority.rawValue, a.item.queueRank, a.item.id)
                < (b.deadline, -b.item.priority.rawValue, b.item.queueRank, b.item.id)
        }

        let overdue = dated.filter { $0.deadline < today }.map(\.item)
        let dueToday = dated.filter { $0.deadline == today }.map(\.item)
        let fixed = Set(overdue.map(\.id) + dueToday.map(\.id))

        var minutes: [String: Int] = [:]
        for p in overdue + dueToday { minutes[p.id] = max(0, p.remainingMinutes) }
        let planned = (sim.allocation[today] ?? [])
            .filter { !fixed.contains($0.id) && $0.minutes >= minPlannedMinutes }
        for slice in planned { minutes[slice.id] = slice.minutes }

        let inToday = fixed.union(planned.map(\.id))
        let horizon = today.adding(days: upcomingDays, calendar: s.calendar)
        let later = dated.filter { $0.deadline > today }
        let upcoming = later.filter { $0.deadline <= horizon && !inToday.contains($0.item.id) }.map(\.item.id)
        let next = later.first.map { TodayPlan.NextDeadline(id: $0.item.id, date: $0.deadline) }
        let open = items.filter { $0.status != .done }

        return TodayPlan(
            today: today, startDay: s.startDay,
            overdue: overdue.map(\.id), dueToday: dueToday.map(\.id), plannedToday: planned,
            upcoming: upcoming, todayMinutes: minutes.values.reduce(0, +), minutesToday: minutes,
            atRisk: sim.atRisk, finish: sim.finish, nextDeadline: next,
            backlogTotal: open.count,
            unscheduled: open.filter { $0.scheduleMode == .none || $0.deadline == nil }.count,
            simulation: sim)
    }
}
