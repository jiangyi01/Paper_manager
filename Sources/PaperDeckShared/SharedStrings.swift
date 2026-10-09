import Foundation

/// PaperDeck's interface language. AI-generated content (titles, TL;DRs,
/// checklist text) is always English; only PaperDeck's own chrome follows this.
public enum UILang: String, Codable, Sendable, CaseIterable {
    case zh, en
}

/// zh/en strings rendered by both the app and the widget: DDL chips, the daily
/// reminder and widget chrome. They live here (not in the app's L10n) so the two
/// processes can never drift apart; the app's L10n delegates these keys.
public enum SharedStrings {

    // MARK: Days

    /// Short weekday name for a Foundation weekday (1 = Sunday … 7 = Saturday).
    public static func weekday(_ weekday: Int, _ lang: UILang) -> String {
        let zh = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let en = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let i = ((weekday - 1) % 7 + 7) % 7
        return lang == .zh ? zh[i] : en[i]
    }

    /// `9/28` — month/day without padding, identical in both languages.
    public static func monthDay(_ d: LocalDate) -> String { "\(d.month)/\(d.day)" }

    public static func today(_ lang: UILang) -> String { lang == .zh ? "今天" : "Today" }
    public static func tomorrow(_ lang: UILang) -> String { lang == .zh ? "明天" : "Tomorrow" }
    public static func unscheduled(_ lang: UILang) -> String { lang == .zh ? "未排期" : "Unscheduled" }

    /// `✓ 9/28`; bare `✓` when the completion day is unknown.
    public static func doneOn(_ d: LocalDate?) -> String { d.map { "✓ " + monthDay($0) } ?? "✓" }

    /// `逾期 3 天` / `3 days overdue` (chips, subtitles).
    public static func overdueDays(_ n: Int, _ lang: UILang) -> String {
        lang == .zh ? "逾期 \(n) 天" : (n == 1 ? "1 day overdue" : "\(n) days overdue")
    }

    /// `逾期3天` / `3d overdue` — the compact prefix used in list lines.
    public static func overdueCompact(_ n: Int, _ lang: UILang) -> String {
        lang == .zh ? "逾期\(n)天" : "\(n)d overdue"
    }

    /// Relative label for a day as seen from `today`, following the DDLChip table:
    /// overdue / today / tomorrow / weekday (Δ2–3) / weekday + M/D (Δ4–6) / M/D (Δ≥7).
    public static func relativeDay(_ day: LocalDate, today: LocalDate, lang: UILang,
                                   calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let delta = day.days(from: today)
        switch delta {
        case ..<0: return overdueDays(-delta, lang)
        case 0: return self.today(lang)
        case 1: return tomorrow(lang)
        case 2...3: return weekday(day.weekday(calendar: gregorian(like: calendar)), lang)
        case 4...6: return weekday(day.weekday(calendar: gregorian(like: calendar)), lang) + " " + monthDay(day)
        default: return monthDay(day)
        }
    }

    // MARK: Counts

    /// `3 篇` / `3 papers`.
    public static func papers(_ n: Int, _ lang: UILang) -> String {
        lang == .zh ? "\(n) 篇" : (n == 1 ? "1 paper" : "\(n) papers")
    }

    /// `约 70 分钟` / `~70 min`.
    public static func aboutMinutes(_ n: Int, _ lang: UILang) -> String {
        lang == .zh ? "约 \(n) 分钟" : "~\(n) min"
    }

    /// `约 70′` / `~70′` — widget-sized.
    public static func aboutMinutesShort(_ n: Int, _ lang: UILang) -> String {
        lang == .zh ? "约 \(n)′" : "~\(n)′"
    }

    /// `待读共 12 篇（未排期 3）` — always the last line of the daily reminder.
    public static func backlogLine(total: Int, unscheduled: Int, _ lang: UILang) -> String {
        lang == .zh ? "待读共 \(total) 篇（未排期 \(unscheduled)）"
                    : "\(papers(total, lang)) left (\(unscheduled) unscheduled)"
    }

    /// Tooltip of the at-risk triangle: `按当前预算预计 周一 才能读完`.
    /// `finishLabel` nil means the plan cannot fit it inside the horizon.
    public static func atRiskHint(finishLabel: String?, _ lang: UILang) -> String {
        switch (lang, finishLabel) {
        case (.zh, let f?): return "按当前预算预计 \(f) 才能读完"
        case (.zh, nil): return "按当前预算无法在排期范围内读完"
        case (.en, let f?): return "At the current budget, expected to finish \(f)"
        case (.en, nil): return "Won't fit the plan at the current budget"
        }
    }

    // MARK: Daily reminder (§8 通知文案)

    public enum Reminder {
        /// Regular: `今日阅读 · 3 篇 · 约 70 分钟`.
        public static func titleRegular(count: Int, minutes: Int, _ lang: UILang) -> String {
            lang == .zh ? "今日阅读 · \(count) 篇 · 约 \(minutes) 分钟"
                        : "Today's reading · \(papers(count, lang)) · ~\(minutes) min"
        }

        /// With overdue papers: `今日阅读 · 4 篇（1 篇逾期）`.
        public static func titleOverdue(count: Int, overdue: Int, _ lang: UILang) -> String {
            lang == .zh ? "今日阅读 · \(count) 篇（\(overdue) 篇逾期）"
                        : "Today's reading · \(papers(count, lang)) (\(overdue) overdue)"
        }

        /// Only one planned slice: `今日阅读 · 约 25 分钟`.
        public static func titlePlanOnly(minutes: Int, _ lang: UILang) -> String {
            lang == .zh ? "今日阅读 · 约 \(minutes) 分钟" : "Today's reading · ~\(minutes) min"
        }

        /// Nothing for today but papers remain: `待读 12 篇`.
        public static func titleBacklog(_ n: Int, _ lang: UILang) -> String {
            lang == .zh ? "待读 \(n) 篇" : "\(papers(n, lang)) left"
        }

        /// Only sent when the user opted into reminders with an empty backlog.
        public static func titleEmpty(_ lang: UILang) -> String {
            lang == .zh ? "今天没有待读论文" : "Nothing left to read"
        }

        /// `今天到期 1 篇 · 下一个 DDL 周五` (either part may be absent).
        public static func subtitleRegular(dueToday: Int, nextDeadline: String?, _ lang: UILang) -> String {
            var parts: [String] = []
            if dueToday > 0 { parts.append(lang == .zh ? "今天到期 \(dueToday) 篇" : "\(dueToday) due today") }
            if let next = nextDeadline { parts.append(lang == .zh ? "下一个 DDL \(next)" : "next deadline \(next)") }
            return capitalizedFirst(parts.joined(separator: " · "))
        }

        /// `逾期 2 天：<title>`.
        public static func subtitleOverdue(days: Int, title: String, _ lang: UILang) -> String {
            lang == .zh ? "逾期 \(days) 天：\(title)" : "\(capitalizedFirst(overdueDays(days, lang))): \(title)"
        }

        /// `下一个 DDL：周五 · <title>`.
        public static func subtitleNextDeadline(day: String, title: String, _ lang: UILang) -> String {
            lang == .zh ? "下一个 DDL：\(day) · \(title)" : "Next deadline: \(day) · \(title)"
        }

        /// `其中 3 篇未排期`.
        public static func subtitleUnscheduled(_ m: Int, _ lang: UILang) -> String {
            lang == .zh ? "其中 \(m) 篇未排期" : "\(m) unscheduled"
        }

        /// ` (3/7)` checklist progress suffix; empty without a checklist.
        public static func progress(done: Int, total: Int) -> String {
            total > 0 ? " (\(done)/\(total))" : ""
        }

        /// `• 逾期2天 <title> (3/7)`.
        public static func lineOverdue(days: Int, title: String, progress: String, _ lang: UILang) -> String {
            "• \(overdueCompact(days, lang)) \(title)\(progress)"
        }

        /// `• 今天 <title> (3/7)`.
        public static func lineDueToday(title: String, progress: String, _ lang: UILang) -> String {
            "• \(today(lang)) \(title)\(progress)"
        }

        /// `• 今日计划 25′ <title>`.
        public static func linePlanned(minutes: Int, title: String, _ lang: UILang) -> String {
            lang == .zh ? "• 今日计划 \(minutes)′ \(title)" : "• Today's plan \(minutes)′ \(title)"
        }

        /// `建议今天读 <title> 25 分钟（从 Fig. 1–3 开始）`.
        public static func lineSuggestion(title: String, minutes: Int, startAt: String?, _ lang: UILang) -> String {
            switch (lang, startAt) {
            case (.zh, let s?): return "建议今天读 \(title) \(minutes) 分钟（从 \(s) 开始）"
            case (.zh, nil): return "建议今天读 \(title) \(minutes) 分钟"
            case (.en, let s?): return "Suggested today: \(title), \(minutes) min (start with \(s))"
            case (.en, nil): return "Suggested today: \(title), \(minutes) min"
            }
        }

        /// `• 下一个 DDL 周一：<title>`.
        public static func lineNextDeadline(day: String, title: String, _ lang: UILang) -> String {
            lang == .zh ? "• 下一个 DDL \(day)：\(title)" : "• Next deadline \(day): \(title)"
        }

        public static func lineScheduleHint(_ lang: UILang) -> String {
            lang == .zh ? "打开 PaperDeck 为未排期论文安排 DDL" : "Open PaperDeck to schedule the unscheduled papers"
        }

        /// `还有 2 篇` after the first four item lines.
        public static func lineMore(_ n: Int, _ lang: UILang) -> String {
            lang == .zh ? "还有 \(n) 篇" : "+\(n) more"
        }
    }

    // MARK: Widget

    public enum Widget {
        public static func todayKind(_ lang: UILang) -> String { lang == .zh ? "今日待读" : "Today's Reading" }
        public static func recentKind(_ lang: UILang) -> String { lang == .zh ? "最近添加" : "Recently Added" }
        /// `逾期 1` (red, small widget).
        public static func overdueCount(_ n: Int, _ lang: UILang) -> String { lang == .zh ? "逾期 \(n)" : "\(n) overdue" }
        /// `待读 12`.
        public static func backlog(_ n: Int, _ lang: UILang) -> String { lang == .zh ? "待读 \(n)" : "\(n) left" }
        /// `+2 更多`.
        public static func more(_ n: Int, _ lang: UILang) -> String { lang == .zh ? "+\(n) 更多" : "+\(n) more" }
        /// `→ <next checklist item>`.
        public static func nextItem(_ text: String) -> String { "→ " + text }
        public static func nothingToday(_ lang: UILang) -> String { lang == .zh ? "今天没有要读的" : "Nothing to read today" }
        /// Snapshot older than 36 h.
        public static func stale(_ lang: UILang) -> String { lang == .zh ? "打开 PaperDeck 以更新" : "Open PaperDeck to refresh" }
        /// Snapshot missing, corrupt or from a newer version.
        public static func placeholder(_ lang: UILang) -> String {
            lang == .zh ? "打开 PaperDeck 查看今日待读" : "Open PaperDeck to see today's reading"
        }
    }

    // MARK: Helpers

    private static func capitalizedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// Weekday math must use the Gregorian calendar even when the user's system
    /// calendar is e.g. Buddhist; only the time zone is taken from `calendar`.
    static func gregorian(like calendar: Calendar) -> Calendar {
        if calendar.identifier == .gregorian { return calendar }
        return LocalDate.gregorian(calendar.timeZone)
    }
}
