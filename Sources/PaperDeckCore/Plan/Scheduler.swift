import Foundation

/// DDL planner (§6.3). Pure and deterministic: settings, the clock and the
/// calendar are all injected, so the same inputs always give the same plan.
///
/// DDLs are commitments. Nothing here moves a deadline except `place()` — the
/// only producer of automatic DDLs, and it writes only the paper being placed —
/// and the explicit user operations below. Everything else (`simulate`) merely
/// *reports* conflicts as at-risk.
///
/// Day arithmetic uses proleptic-Gregorian day numbers, so DST, time-zone and
/// the user's system calendar never shift a LocalDate; the time zone only
/// decides which day `now` falls on.
package struct Scheduler: Sendable {
    /// Minutes of one paper allocated to one day.
    package struct Slice: Sendable, Equatable, Hashable {
        package var id: String
        package var minutes: Int
        package init(id: String, minutes: Int) { self.id = id; self.minutes = minutes }
    }

    /// EDF simulation of the current plan, assuming reading exactly the budget on
    /// every reading day from `startDay`.
    package struct Simulation: Sendable, Equatable {
        package var allocation: [LocalDate: [Slice]]
        /// Day each paper's remaining minutes run out. Missing = does not finish
        /// within the simulated range (treated as at risk).
        package var finish: [String: LocalDate]
        /// Live, dated papers whose deadline ≥ today but finish > deadline.
        package var atRisk: Set<String>
        /// Active paper ids in EDF order (D', −priority, queue_rank).
        package var order: [String]

        package init(allocation: [LocalDate: [Slice]] = [:], finish: [String: LocalDate] = [:],
                     atRisk: Set<String> = [], order: [String] = []) {
            self.allocation = allocation; self.finish = finish; self.atRisk = atRisk; self.order = order
        }

        package func minutes(of id: String, on day: LocalDate) -> Int {
            allocation[day]?.first { $0.id == id }?.minutes ?? 0
        }
    }

    /// Result of "今天跳过": the new skip-day set to persist and the moved papers.
    package struct SkipResult: Sendable, Equatable {
        package var skipDays: Set<LocalDate>
        package var changed: [SchedItem]
    }

    /// Agent estimates that differ from the heuristic by at least this much
    /// trigger a one-time re-place of a provisional DDL.
    package static let provisionalRevisionThreshold = 15
    package static let provisionalRevisionWindow: TimeInterval = 24 * 3600

    package let settings: PlanSettings
    package let now: Date
    /// Gregorian calendar in the caller's time zone.
    package let calendar: Calendar
    package let today: LocalDate
    /// First day ≥ today with capacity; today is excluded once now.hour ≥ cutoffHour.
    package let startDay: LocalDate

    private let startN: Int
    private let horizonEndN: Int
    private let budget: Int
    private let weekdays: Set<Int>
    private let skipNs: Set<Int>
    /// Skip days that remove capacity on/after startDay, sorted (for C(t)).
    private let capacitySkips: [Int]

    package init(settings: PlanSettings, now: Date, calendar: Calendar = .current) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = calendar.timeZone
        self.settings = settings
        self.now = now
        self.calendar = cal
        let today = LocalDate(now, calendar: cal)
        self.today = today
        let tN = today.schedDayNumber
        self.budget = max(0, settings.dailyBudgetMinutes)
        self.weekdays = settings.readingWeekdays.filter { (1...7).contains($0) }
        self.skipNs = Set(settings.skipDays.map(\.schedDayNumber))
        self.horizonEndN = tN + max(0, settings.horizonDays)

        let candidate = cal.component(.hour, from: now) >= settings.cutoffHour ? tN + 1 : tN
        var s = candidate
        let budget = self.budget, weekdays = self.weekdays, skipNs = self.skipNs
        let hasCap = { (n: Int) in budget > 0 && weekdays.contains(Scheduler.weekdayOf(n)) && !skipNs.contains(n) }
        let searchEnd = candidate + max(366, settings.horizonDays) + 7 * skipNs.count
        while s <= searchEnd && !hasCap(s) { s += 1 }
        if s > searchEnd { s = candidate }          // no capacity at all: nothing can be placed anyway
        self.startN = s
        self.startDay = LocalDate(schedDayNumber: s)
        self.capacitySkips = skipNs.filter { $0 >= s && weekdays.contains(Scheduler.weekdayOf($0)) }.sorted()
    }

    // MARK: Calendar of reading days

    /// Weekday ∈ W and not a skip day (independent of the budget and of the cutoff).
    package func isReadingDay(_ d: LocalDate) -> Bool { isReadingDay(d.schedDayNumber) }

    /// cap(d) = B on reading days, else 0.
    package func cap(_ d: LocalDate) -> Int { cap(d.schedDayNumber) }

    /// First reading day strictly after `d` (falls back to d+1 when W is empty).
    package func nextReadingDay(after d: LocalDate) -> LocalDate {
        LocalDate(schedDayNumber: firstReadingDay(from: d.schedDayNumber + 1) ?? d.schedDayNumber + 1)
    }

    /// `d` itself when it is a reading day, else the next one.
    package func snapToReadingDay(_ d: LocalDate) -> LocalDate {
        LocalDate(schedDayNumber: firstReadingDay(from: d.schedDayNumber) ?? d.schedDayNumber)
    }

    /// D'(p) = max(deadline, startDay); nil when the paper has no deadline.
    package func effectiveDeadline(_ p: SchedItem) -> LocalDate? {
        p.deadline.map { max($0, startDay) }
    }

    /// C(t) = Σ cap over startDay…t.
    package func cumulativeCapacity(through t: LocalDate) -> Int { cumulativeCap(through: t.schedDayNumber) }

    // MARK: place()

    /// The only function that produces an automatic DDL (§6.3). Returns `q` with
    /// deadline, placement_floor and deadline_origin = place; when no day within
    /// the horizon fits, schedule mode becomes `none` (deadline nil).
    ///
    /// High priority competes only with high ∪ pinned papers; every other
    /// priority competes with all active papers. `floor` overrides the
    /// tail(priority) lower bound (used by the provisional re-place).
    package func place(_ q: SchedItem, among items: [SchedItem], floor: LocalDate? = nil) -> SchedItem {
        let others = items.filter { $0.id != q.id && $0.isActive }
        let base = q.priority == .high ? others.filter { $0.priority == .high || $0.scheduleMode == .pinned } : others
        let loN: Int
        if let floor {
            loN = max(startN, floor.schedDayNumber)
        } else {
            let tail = others.filter { $0.scheduleMode == .auto && $0.priority >= q.priority }
                .compactMap { $0.deadline?.schedDayNumber }.max()
            loN = max(startN, tail ?? startN)
        }

        var out = q
        out.deadlineOrigin = .place
        out.placementFloor = LocalDate(schedDayNumber: loN)
        if let d = firstFeasibleDay(from: loN, need: max(0, q.remainingMinutes), base: base) {
            out.deadline = LocalDate(schedDayNumber: d)
            out.scheduleMode = .auto
        } else {
            out.deadline = nil
            out.scheduleMode = .none
        }
        return out
    }

    /// First d ≥ lo with cap(d) > 0 and d ≤ horizon such that the slack of `base`
    /// is ≥ need at d and at every later checkpoint D'(p) of base.
    private func firstFeasibleDay(from loN: Int, need: Int, base: [SchedItem]) -> Int? {
        // Demand grouped by D', ascending, with the slack at each checkpoint.
        var demandByDay: [Int: Int] = [:]
        for p in base {
            guard let d = p.deadline?.schedDayNumber else { continue }
            demandByDay[max(d, startN), default: 0] += max(0, p.remainingMinutes)
        }
        let checkpoints = demandByDay.keys.sorted()
        var cumulativeDemand: [Int] = []
        var running = 0
        for t in checkpoints { running += demandByDay[t] ?? 0; cumulativeDemand.append(running) }
        let slackAt = checkpoints.indices.map { cumulativeCap(through: checkpoints[$0]) - cumulativeDemand[$0] }
        var suffixMin = slackAt
        for i in stride(from: suffixMin.count - 2, through: 0, by: -1) { suffixMin[i] = min(suffixMin[i], suffixMin[i + 1]) }

        var d = loN
        var capC = cumulativeCap(through: loN - 1)
        var j = 0                       // first checkpoint with D' ≥ d
        while d <= horizonEndN {
            capC += cap(d)
            if cap(d) > 0 {
                while j < checkpoints.count && checkpoints[j] < d { j += 1 }
                // Demand due on or before d.
                let k = (j < checkpoints.count && checkpoints[j] == d) ? j + 1 : j
                let demand = k > 0 ? cumulativeDemand[k - 1] : 0
                let laterOK = j >= checkpoints.count || suffixMin[j] >= need
                if capC - demand >= need && laterOK { return d }
            }
            d += 1
        }
        return nil
    }

    // MARK: simulate()

    /// EDF by (D', −priority, queue_rank): fills each reading day from startDay
    /// up to its cap, giving per-day allocations, finish days and the at-risk set.
    package func simulate(_ items: [SchedItem]) -> Simulation {
        let active = items.filter(\.isActive).sorted(by: edfPrecedes)
        var remaining = active.map { max(0, $0.remainingMinutes) }
        var allocation: [LocalDate: [Slice]] = [:]
        var finish: [String: LocalDate] = [:]

        // Nothing left to read: already "finished" today, never at risk.
        for (i, p) in active.enumerated() where remaining[i] == 0 { finish[p.id] = today }

        var i = 0
        func skipFinished() { while i < active.count && remaining[i] == 0 { i += 1 } }
        skipFinished()
        // EDF finishes far-future pins early anyway; the bound only matters when capacity is
        // (nearly) zero, and then a user-picked date years ahead must not make this loop huge.
        let limit = horizonEndN + 3650
        var n = startN
        while i < active.count && n <= limit {
            var left = cap(n)
            if left > 0 {
                let day = LocalDate(schedDayNumber: n)
                var slices: [Slice] = []
                while left > 0 && i < active.count {
                    let take = min(left, remaining[i])
                    slices.append(Slice(id: active[i].id, minutes: take))
                    remaining[i] -= take
                    left -= take
                    if remaining[i] == 0 { finish[active[i].id] = day; skipFinished() }
                }
                allocation[day] = slices
            }
            n += 1
        }

        var atRisk = Set<String>()
        for p in active {
            guard let d = p.deadline, d >= today else { continue }
            if let f = finish[p.id] { if f > d { atRisk.insert(p.id) } } else { atRisk.insert(p.id) }
        }
        return Simulation(allocation: allocation, finish: finish, atRisk: atRisk, order: active.map(\.id))
    }

    /// EDF order: D' ascending, then higher priority, then queue_rank, then id.
    package func edfPrecedes(_ a: SchedItem, _ b: SchedItem) -> Bool {
        let da = a.deadline.map { max($0.schedDayNumber, startN) } ?? Int.max
        let db = b.deadline.map { max($0.schedDayNumber, startN) } ?? Int.max
        if da != db { return da < db }
        if a.priority != b.priority { return a.priority > b.priority }
        if a.queueRank != b.queueRank { return a.queueRank < b.queueRank }
        return a.id < b.id
    }

    // MARK: Operations (§6.3 table) — each returns the updated paper(s)

    /// 选日期: the user's date wins and is never moved automatically.
    package func pin(_ p: SchedItem, to date: LocalDate) -> SchedItem {
        var out = p
        out.deadline = date
        out.scheduleMode = .pinned
        out.deadlineOrigin = .user
        return out
    }

    /// 恢复自动 (also "按新优先级重新排期" after a priority change).
    package func restoreAuto(_ p: SchedItem, among items: [SchedItem]) -> SchedItem {
        var q = p
        q.scheduleMode = .auto
        return place(q, among: items)
    }

    /// 移到未排期.
    package func unschedule(_ p: SchedItem) -> SchedItem {
        var out = p
        out.scheduleMode = .none
        out.deadline = nil
        out.deadlineOrigin = .user
        return out
    }

    /// 推迟一天 ⇧⌘P: next reading day after max(deadline, today); mode unchanged.
    /// Unscheduled papers are returned unchanged.
    package func postponeDay(_ p: SchedItem) -> SchedItem {
        guard p.scheduleMode != .none, let d = p.deadline else { return p }
        var out = p
        out.deadline = nextReadingDay(after: max(d, today))
        out.deadlineOrigin = .user
        return out
    }

    /// 推迟一周: snapToReadingDay(max(deadline, today) + 7); mode unchanged.
    package func postponeWeek(_ p: SchedItem) -> SchedItem {
        guard p.scheduleMode != .none, let d = p.deadline else { return p }
        var out = p
        out.deadline = snapToReadingDay(LocalDate(schedDayNumber: max(d, today).schedDayNumber + 7))
        out.deadlineOrigin = .user
        return out
    }

    /// 今天跳过 (also the notification's POSTPONE_DAY): today joins skipDays and
    /// every auto paper due today or later moves to the next reading day after
    /// its deadline. Overdue and pinned papers stay. Idempotent — skipping an
    /// already-skipped day changes nothing. Undo = restore the returned papers'
    /// previous values and the previous skip set (the caller keeps them).
    package func skipToday(_ items: [SchedItem]) -> SkipResult {
        guard !settings.skipDays.contains(today) else { return SkipResult(skipDays: settings.skipDays, changed: []) }
        var s = settings
        s.skipDays.insert(today)
        let after = Scheduler(settings: s, now: now, calendar: calendar)
        var changed: [SchedItem] = []
        for p in items where p.status != .done && p.scheduleMode == .auto {
            guard let d = p.deadline, d >= today else { continue }
            var out = p
            out.deadline = after.nextReadingDay(after: d)
            out.deadlineOrigin = .user
            changed.append(out)
        }
        return SkipResult(skipDays: s.skipDays, changed: changed)
    }

    /// 顺延受影响的 N 篇: at-risk auto papers get deadline = simulated finish.
    /// Pinned papers are only flagged, never moved. Papers that don't finish
    /// within the simulated range are left alone.
    package func shiftAtRisk(_ items: [SchedItem]) -> [SchedItem] {
        let sim = simulate(items)
        return items.compactMap { p in
            guard p.scheduleMode == .auto, sim.atRisk.contains(p.id), let f = sim.finish[p.id] else { return nil }
            var out = p
            out.deadline = f
            out.deadlineOrigin = .user
            return out
        }
    }

    /// First agent result for a paper (§6.2 applyAgentCard). `q` must already
    /// carry the post-merge remaining minutes. When the provisional ≈DDL came
    /// from a heuristic estimate that was off by ≥ 15′, the paper was imported
    /// < 24 h ago and the DDL is still place()'s, re-place it from its original
    /// floor. Always clears `provisional`. Other papers are never moved.
    package func applyAgentEstimate(_ q: SchedItem, heuristicMinutes: Int, agentMinutes: Int,
                                    addedAt: Date, among items: [SchedItem]) -> SchedItem {
        var out = q
        let age = now.timeIntervalSince(addedAt)
        if q.provisional, q.scheduleMode == .auto, q.deadline != nil, q.deadlineOrigin == .place,
           abs(agentMinutes - heuristicMinutes) >= Scheduler.provisionalRevisionThreshold,
           age >= 0, age < Scheduler.provisionalRevisionWindow {
            out = place(q, among: items, floor: q.placementFloor)
        }
        out.provisional = false
        return out
    }

    // MARK: Building SchedItems

    /// remaining(p) = Σ unchecked item minutes; the estimate only when there is no checklist.
    package static func remainingMinutes(estMinutes: Int?, checklist: [ChecklistItem]) -> Int {
        if checklist.isEmpty { return max(0, estMinutes ?? 0) }
        return checklist.reduce(0) { $0 + ($1.isDone ? 0 : max(0, $1.minutes)) }
    }

    /// The scheduler's view of a paper.
    package static func item(for paper: Paper, checklist: [ChecklistItem]) -> SchedItem {
        SchedItem(id: paper.id, status: paper.status, priority: paper.priority, deadline: paper.deadline,
                  scheduleMode: paper.scheduleMode, deadlineOrigin: paper.deadlineOrigin,
                  queueRank: paper.queueRank,
                  remainingMinutes: remainingMinutes(estMinutes: paper.estMinutes, checklist: checklist),
                  placementFloor: paper.placementFloor, provisional: paper.provisional)
    }

    // MARK: Private day-number helpers

    private func isReadingDay(_ n: Int) -> Bool { weekdays.contains(Scheduler.weekdayOf(n)) && !skipNs.contains(n) }
    private func cap(_ n: Int) -> Int { budget > 0 && isReadingDay(n) ? budget : 0 }

    private func firstReadingDay(from n: Int) -> Int? {
        guard !weekdays.isEmpty else { return nil }
        var d = n
        let end = n + 7 * (skipNs.count + 1)    // each skip day can push the answer back one week at most
        while d <= end { if isReadingDay(d) { return d }; d += 1 }
        return nil
    }

    /// Σ cap over startDay…t in O(|W| + log|skips|) — checkpoints may be pinned years ahead.
    private func cumulativeCap(through t: Int) -> Int {
        guard t >= startN, budget > 0, !weekdays.isEmpty else { return 0 }
        let total = t - startN + 1
        let full = total / 7, rest = total % 7
        let w0 = Scheduler.weekdayOf(startN)
        var days = 0
        for w in weekdays {
            let offset = ((w - w0) % 7 + 7) % 7
            days += full + (offset < rest ? 1 : 0)
        }
        days -= upperBound(capacitySkips, t)
        return days * budget
    }

    /// Foundation weekday (1 = Sunday) of a day number (0 = 1970-01-01, a Thursday).
    private static func weekdayOf(_ n: Int) -> Int { ((n + 4) % 7 + 7) % 7 + 1 }

    /// Number of elements ≤ x in a sorted array.
    private func upperBound(_ a: [Int], _ x: Int) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let mid = (lo + hi) / 2; if a[mid] <= x { lo = mid + 1 } else { hi = mid } }
        return lo
    }
}

private extension LocalDate {
    /// Days since 1970-01-01 in the proleptic Gregorian calendar (H. Hinnant's
    /// days_from_civil) — exact integer arithmetic, no Calendar or time zone.
    var schedDayNumber: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    init(schedDayNumber n: Int) {
        let z = n + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.init(year: yoe + era * 400 + (m <= 2 ? 1 : 0), month: m, day: d)
    }
}
