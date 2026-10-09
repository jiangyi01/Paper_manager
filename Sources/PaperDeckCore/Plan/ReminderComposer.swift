import Foundation
import CryptoKit

/// A paper as the daily reminder sees it: the scheduler's view plus what the
/// notification text needs.
package struct ReminderPaper: Sendable, Equatable {
    package var item: SchedItem
    package var title: String              // English; truncated when rendered
    package var doneItems: Int
    package var totalItems: Int
    package var nextSection: String?       // section of the first unchecked item, e.g. "Fig. 1–3"

    package init(item: SchedItem, title: String, doneItems: Int = 0, totalItems: Int = 0, nextSection: String? = nil) {
        self.item = item; self.title = title; self.doneItems = doneItems
        self.totalItems = totalItems; self.nextSection = nextSection
    }

    /// Builds from DB rows; callers pass live (non-deleted) papers only.
    package init(paper: Paper, checklist: [ChecklistItem]) {
        self.init(item: Scheduler.item(for: paper, checklist: checklist), title: paper.title,
                  doneItems: checklist.filter(\.isDone).count, totalItems: checklist.count,
                  nextSection: checklist.sorted { $0.ord < $1.ord }.first { !$0.isDone }?.section)
    }
}

/// The mail line of the daily reminder: 「邮件待处理 N 封（M 封请求）」. For day X the count
/// is the pending cards plus the snoozed ones that will have woken by X's reminder time.
package struct MailReminderInfo: Sendable, Equatable {
    /// A snoozed card: when it wakes and whether it is a reading request.
    package struct Snoozed: Sendable, Equatable {
        package var until: Date
        package var isRequest: Bool
        package init(until: Date, isRequest: Bool) { self.until = until; self.isRequest = isRequest }
    }

    package var pending: Int
    package var requests: Int                   // pending cards from people with a reading request
    package var snoozed: [Snoozed]

    package init(pending: Int, requests: Int, snoozed: [Snoozed] = []) {
        self.pending = pending; self.requests = requests; self.snoozed = snoozed
    }

    /// (cards, requests) to mention in a reminder firing at `fire`.
    package func counts(at fire: Date) -> (total: Int, requests: Int) {
        let woken = snoozed.filter { $0.until <= fire }
        return (pending + woken.count, requests + woken.filter(\.isRequest).count)
    }

    /// 「邮件待处理 3 封（1 封请求）」 / "3 emails to handle (1 request)"; nil for no mail.
    package static func line(total: Int, requests: Int, _ lang: UILang) -> String? {
        guard total > 0 else { return nil }
        if lang == .zh {
            return requests > 0 ? "邮件待处理 \(total) 封（\(requests) 封请求）" : "邮件待处理 \(total) 封"
        }
        let emails = total == 1 ? "1 email" : "\(total) emails"
        guard requests > 0 else { return "\(emails) to handle" }
        return "\(emails) to handle (\(requests) \(requests == 1 ? "request" : "requests"))"
    }
}

/// One day's one-shot notification request (§3.5): id `daily-YYYY-MM-DD`,
/// fired by calendar components so it stays at local 11:00 across DST.
package struct ReminderSpec: Sendable, Equatable {
    package static let idPrefix = "daily-"
    /// UNNotificationContent.categoryIdentifier (actions OPEN_LIST / POSTPONE_DAY / REMIND_1H).
    package static let categoryIdentifier = "DAILY_LIST"
    package static let threadIdentifier = "daily"

    package var id: String
    package var day: LocalDate
    package var hour: Int
    package var minute: Int
    package var fireDate: Date
    package var title: String
    package var subtitle: String
    package var body: String
    /// Stable hash of the texts AND the fire time (stored in userInfo "h"); a change means
    /// "replace the pending request" — so moving the reminder time reschedules it too.
    package var hash: String
    package var url: String

    package init(day: LocalDate, hour: Int, minute: Int, fireDate: Date, title: String, subtitle: String, body: String) {
        self.id = ReminderSpec.id(for: day)
        self.day = day; self.hour = hour; self.minute = minute; self.fireDate = fireDate
        self.title = title; self.subtitle = subtitle; self.body = body
        self.hash = ReminderComposer.hash(title: title, subtitle: subtitle, body: body, hour: hour, minute: minute)
        self.url = DeepLink.today.url.absoluteString
    }

    package static func id(for day: LocalDate) -> String { idPrefix + day.iso }

    /// Notification userInfo: the deep link and the hash that `diff` compares.
    package var userInfo: [String: String] { ["url": url, "h": hash] }

    /// For `UNCalendarNotificationTrigger(dateMatching:repeats: false)`; no time
    /// zone on purpose, so the trigger follows the Mac's current local time.
    package var fireComponents: DateComponents {
        DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute)
    }
}

/// Composes the single daily reminder (§6.5, §8 通知文案) and diffs the rolling
/// 14-day plan against what the notification center already holds.
package enum ReminderComposer {
    package static let titleLimit = 60
    package static let maxItemLines = 4
    package static let planDays = 14

    /// The reminder for `day`, simulated as of that day's reminder time (or `now`
    /// for an on-the-spot recompute such as "remind me in 1 hour"), assuming no
    /// reading progress before then. nil only when nothing is left to read, no email
    /// waits (`mail`) and the user has "无待读时不提醒" on. Non-reading days still get a
    /// reminder. The mail line goes right before the fixed last line.
    package static func compose(day: LocalDate, papers: [ReminderPaper], settings: PlanSettings, lang: UILang,
                                calendar: Calendar = .current, now: Date? = nil,
                                mail: MailReminderInfo? = nil) -> ReminderSpec? {
        let cal = LocalDate.gregorian(calendar.timeZone)
        let (hour, minute) = reminderTime(settings)
        let fire = day.date(hour: hour, minute: minute, calendar: cal)
        let scheduler = Scheduler(settings: settings, now: now ?? fire, calendar: cal)
        let plan = TodaySet.compute(papers.map(\.item), scheduler: scheduler)
        let n = plan.backlogTotal, m = plan.unscheduled
        let mailCounts = mail?.counts(at: now ?? fire) ?? (total: 0, requests: 0)
        if n == 0 && mailCounts.total == 0 && !settings.remindWhenEmpty { return nil }

        typealias R = SharedStrings.Reminder
        let byID = Dictionary(papers.map { ($0.item.id, $0) }, uniquingKeysWith: { a, _ in a })
        let today = plan.today
        func title(_ id: String) -> String { clip(byID[id]?.title ?? "", titleLimit) }
        func progress(_ id: String) -> String { R.progress(done: byID[id]?.doneItems ?? 0, total: byID[id]?.totalItems ?? 0) }
        func overdueDays(_ id: String) -> Int { byID[id]?.item.deadline.map { today.days(from: $0) } ?? 0 }
        let next = plan.nextDeadline.map {
            (id: $0.id, label: SharedStrings.relativeDay($0.date, today: today, lang: lang, calendar: cal))
        }

        func itemLines() -> [String] {
            var lines = plan.overdue.map { R.lineOverdue(days: overdueDays($0), title: title($0), progress: progress($0), lang) }
            lines += plan.dueToday.map { R.lineDueToday(title: title($0), progress: progress($0), lang) }
            lines += plan.plannedToday.map { R.linePlanned(minutes: $0.minutes, title: title($0.id), lang) }
            guard lines.count > maxItemLines else { return lines }
            return Array(lines.prefix(maxItemLines)) + [R.lineMore(lines.count - maxItemLines, lang)]
        }

        let headline: String, subtitle: String
        var lines: [String] = []
        if n == 0 {
            headline = R.titleEmpty(lang)
            subtitle = ""
        } else if let worst = plan.overdue.first {
            headline = R.titleOverdue(count: plan.count, overdue: plan.overdue.count, lang)
            subtitle = R.subtitleOverdue(days: overdueDays(worst), title: title(worst), lang)
            lines = itemLines()
        } else if plan.dueToday.isEmpty, plan.plannedToday.count == 1, let slice = plan.plannedToday.first {
            headline = R.titlePlanOnly(minutes: plan.todayMinutes, lang)
            subtitle = next.map { R.subtitleNextDeadline(day: $0.label, title: title($0.id), lang) } ?? ""
            lines = [R.lineSuggestion(title: title(slice.id), minutes: slice.minutes,
                                      startAt: byID[slice.id]?.nextSection.map { clip($0, 40) }, lang)]
        } else if !plan.isEmpty {
            headline = R.titleRegular(count: plan.count, minutes: plan.todayMinutes, lang)
            subtitle = R.subtitleRegular(dueToday: plan.dueToday.count, nextDeadline: next?.label, lang)
            lines = itemLines()
        } else {
            // Nothing for today (all unscheduled, a non-reading day, or DDLs later): still remind.
            headline = R.titleBacklog(n, lang)
            subtitle = m > 0 ? R.subtitleUnscheduled(m, lang)
                             : next.map { R.subtitleNextDeadline(day: $0.label, title: title($0.id), lang) } ?? ""
            if let next { lines.append(R.lineNextDeadline(day: next.label, title: title(next.id), lang)) }
            if m > 0 { lines.append(R.lineScheduleHint(lang)) }
        }
        if let mailLine = MailReminderInfo.line(total: mailCounts.total, requests: mailCounts.requests, lang) {
            lines.append(mailLine)
        }
        lines.append(SharedStrings.backlogLine(total: n, unscheduled: m, lang))

        return ReminderSpec(day: day, hour: hour, minute: minute, fireDate: fire,
                            title: headline, subtitle: subtitle, body: lines.joined(separator: "\n"))
    }

    /// Reminders for the next `days` days, starting tomorrow once today's
    /// reminder time has passed. Days that compose to nil are simply absent.
    package static func plan(from now: Date, days: Int = planDays, papers: [ReminderPaper], settings: PlanSettings,
                             lang: UILang, calendar: Calendar = .current, mail: MailReminderInfo? = nil) -> [ReminderSpec] {
        let cal = LocalDate.gregorian(calendar.timeZone)
        let today = LocalDate(now, calendar: cal)
        let (hour, minute) = reminderTime(settings)
        let fireToday = today.date(hour: hour, minute: minute, calendar: cal)
        let first = now >= fireToday ? today.adding(days: 1, calendar: cal) : today
        return (0..<max(0, days)).compactMap { i in
            compose(day: first.adding(days: i, calendar: cal), papers: papers, settings: settings, lang: lang, calendar: cal,
                    mail: mail)
        }
    }

    /// Reconciles the plan with the notification center. Never re-adds a
    /// delivered id or the day already delivered (re-adding a delivered id makes
    /// it ring again); a changed hash means remove-then-add. Pending `daily-*`
    /// requests outside the plan are removed; other ids (e.g. `remind-1h-*`) are
    /// left alone.
    package static func diff(pending: [(id: String, hash: String)], delivered: Set<String>, plan: [ReminderSpec],
                             lastDelivered: LocalDate?) -> (remove: [String], add: [ReminderSpec]) {
        var pendingHash: [String: String] = [:]
        for p in pending where pendingHash[p.id] == nil { pendingHash[p.id] = p.hash }
        var remove: [String] = []
        var add: [ReminderSpec] = []
        var planned = Set<String>()

        for spec in plan.sorted(by: { $0.day < $1.day }) where planned.insert(spec.id).inserted {
            let existing = pendingHash[spec.id]
            if delivered.contains(spec.id) || spec.day == lastDelivered {
                if existing != nil { remove.append(spec.id) }    // would fire a second time
                continue
            }
            switch existing {
            case nil: add.append(spec)
            case spec.hash?: break
            default: remove.append(spec.id); add.append(spec)
            }
        }
        var seen = Set(remove)
        for p in pending where p.id.hasPrefix(ReminderSpec.idPrefix) && !planned.contains(p.id) {
            if seen.insert(p.id).inserted { remove.append(p.id) }
        }
        return (remove, add)
    }

    /// First 16 hex digits of SHA-256 over the three texts (unit-separated).
    package static func hash(title: String, subtitle: String, body: String) -> String {
        digest(title + "\u{1F}" + subtitle + "\u{1F}" + body)
    }

    /// `hash(title:subtitle:body:)` plus the local fire time (`fireComponents` hour:minute), so a
    /// request pending at the old time never survives a reminder-time change.
    package static func hash(title: String, subtitle: String, body: String, hour: Int, minute: Int) -> String {
        digest(title + "\u{1F}" + subtitle + "\u{1F}" + body + "\u{1F}" + String(format: "%02d:%02d", hour, minute))
    }

    private static func digest(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Out-of-range settings must not roll the fire time into another day.
    private static func reminderTime(_ s: PlanSettings) -> (Int, Int) {
        (min(max(s.reminderHour, 0), 23), min(max(s.reminderMinute, 0), 59))
    }

    /// Single-line text of at most `limit` characters (ellipsis included).
    private static func clip(_ s: String, _ limit: Int) -> String {
        let flat = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
