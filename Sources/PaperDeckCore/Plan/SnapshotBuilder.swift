import Foundation

/// Builds the widget snapshot (§6.6) from plain library values. Pure: the app's
/// DerivedRefresher gathers the inputs, calls this, and WidgetBridge writes the
/// result only when `sameContent(as:)` says something changed.
package enum SnapshotBuilder {
    package static let recentCount = 4
    package static let tldrLimit = 120
    package static let nextItemCount = 2

    /// - Parameters:
    ///   - checklists: checklist items keyed by paper id.
    ///   - categories: keyed by category pk.
    ///   - thumbnails: ids that have `widget/thumbs/<id>.jpg` on disk.
    package static func build(papers: [Paper], checklists: [String: [ChecklistItem]], categories: [Int64: PaperCategory],
                              settings: PlanSettings, lang: UILang, now: Date, calendar: Calendar = .current,
                              thumbnails: Set<String> = []) -> WidgetSnapshot {
        let cal = LocalDate.gregorian(calendar.timeZone)
        let live = papers.filter(\.isLive)
        let items = live.map { Scheduler.item(for: $0, checklist: checklists[$0.id] ?? []) }

        let todayPlan = TodaySet.compute(items, settings: settings, now: now, calendar: cal)
        // Tomorrow as it will look at midnight if nothing is read before then.
        let tomorrow = todayPlan.today.adding(days: 1, calendar: cal)
        let tomorrowPlan = TodaySet.compute(items, settings: settings, now: tomorrow.startOfDay(calendar: cal), calendar: cal)

        let recent = live.sorted { ($0.addedAt, $0.id) > ($1.addedAt, $1.id) }.prefix(recentCount).map(\.id)
        let wanted = Set(todayPlan.ids + tomorrowPlan.ids + recent)

        var entries: [String: WidgetSnapshot.PaperEntry] = [:]
        for p in live where wanted.contains(p.id) {
            let checklist = (checklists[p.id] ?? []).sorted { $0.ord < $1.ord }
            let category = p.categoryPK.flatMap { categories[$0] }
            entries[p.id] = WidgetSnapshot.PaperEntry(
                title: p.title,
                authors: authorLine(p.authors),
                venue: p.venue ?? (p.ids.doi?.hasPrefix("10.1101/") == true ? "bioRxiv" : nil),
                year: p.year,
                deadline: p.scheduleMode == .none ? nil : p.deadline,
                pinned: p.scheduleMode == .pinned,
                provisional: p.provisional,
                atRisk: todayPlan.atRisk.contains(p.id),
                doneAt: p.doneAt.map { LocalDate($0, calendar: cal) },
                priority: p.priority.rawValue,
                status: p.status.rawValue,
                done: checklist.filter(\.isDone).count,
                total: checklist.count,
                minutesToday: todayPlan.minutesToday[p.id] ?? 0,
                tldr: p.tldr.map { clip($0, tldrLimit) }.flatMap { $0.isEmpty ? nil : $0 },
                category: category?.name,
                hue: category?.hue,
                aiState: p.aiState.rawValue,
                next: checklist.filter { !$0.isDone }.prefix(nextItemCount)
                    .map { WidgetSnapshot.NextItem(text: clip($0.text, 160), section: $0.section) },
                thumb: thumbnails.contains(p.id) ? "thumbs/\(p.id).jpg" : nil)
        }

        func day(_ plan: TodayPlan) -> WidgetSnapshot.Day {
            WidgetSnapshot.Day(date: plan.today, count: plan.count, minutes: plan.todayMinutes,
                               overdue: plan.overdue.count, ids: plan.ids)
        }

        return WidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)),
            lang: lang,
            reminder: .init(h: settings.reminderHour, m: settings.reminderMinute),
            backlog: .init(total: todayPlan.backlogTotal, unscheduled: todayPlan.unscheduled),
            days: [day(todayPlan), day(tomorrowPlan)],
            recentIds: recent,
            papers: entries)
    }

    /// Card-style author line: `Wang L`, `Wang L & Chen Y`, `Wang L … Kriegstein AR`.
    package static func authorLine(_ authors: [String]) -> String {
        let names = authors.map(shortName).filter { !$0.isEmpty }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return names[0] + " & " + names[1]
        default: return names[0] + " … " + names[names.count - 1]
        }
    }

    /// "Arnold R. Kriegstein" / "Kriegstein, Arnold R." → "Kriegstein AR".
    private static func shortName(_ full: String) -> String {
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        let family: String, given: [Substring]
        if let comma = trimmed.firstIndex(of: ",") {
            family = trimmed[..<comma].trimmingCharacters(in: .whitespaces)
            given = trimmed[trimmed.index(after: comma)...].split(whereSeparator: { $0.isWhitespace })
        } else {
            let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard let last = parts.last else { return "" }
            family = String(last)
            given = parts.dropLast()
        }
        let initials = given.flatMap { $0.split(separator: "-") }
            .compactMap { $0.first(where: \.isLetter).map { String($0).uppercased() } }
            .joined()
        return initials.isEmpty ? family : family + " " + initials
    }

    /// Single-line text of at most `limit` characters (ellipsis included).
    private static func clip(_ s: String, _ limit: Int) -> String {
        let flat = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
