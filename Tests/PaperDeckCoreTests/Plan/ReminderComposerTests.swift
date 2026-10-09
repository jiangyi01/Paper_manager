import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct ReminderComposerTests {
    private static let cal = LocalDate.gregorian(TimeZone(identifier: "America/Chicago")!)
    private static let settings = PlanSettings(dailyBudgetMinutes: 60, readingWeekdays: [2, 3, 4, 5, 6])
    private static func d(_ s: String) -> LocalDate { LocalDate(iso: s)! }
    private static func at(_ day: String, _ h: Int, _ m: Int = 0) -> Date { d(day).date(hour: h, minute: m, calendar: cal) }

    private static func paper(_ id: String, _ deadline: String?, _ minutes: Int, rank: Int, done: Int = 0, total: Int = 0,
                              next: String? = nil, mode: ScheduleMode = .auto, status: PaperStatus = .toRead,
                              title: String? = nil) -> ReminderPaper {
        ReminderPaper(item: SchedItem(id: id, status: status, deadline: deadline.map(d), scheduleMode: mode,
                                      queueRank: rank, remainingMinutes: minutes),
                      title: title ?? "Title \(id)", doneItems: done, totalItems: total, nextSection: next)
    }
    private static func compose(_ day: String, _ papers: [ReminderPaper], _ lang: UILang = .zh,
                                settings: PlanSettings = settings) -> ReminderSpec? {
        ReminderComposer.compose(day: d(day), papers: papers, settings: settings, lang: lang, calendar: cal)
    }

    // MARK: §8 通知文案 cases

    @Test func regular() throws {
        let papers = [Self.paper("T", "2026-09-29", 20, rank: 1, done: 3, total: 7),
                      Self.paper("P", "2026-10-02", 100, rank: 2)]
        let zh = try #require(Self.compose("2026-09-29", papers))
        #expect(zh.id == "daily-2026-09-29")
        #expect(zh.title == "今日阅读 · 2 篇 · 约 60 分钟")
        #expect(zh.subtitle == "今天到期 1 篇 · 下一个 DDL 周五")
        #expect(zh.body == "• 今天 Title T (3/7)\n• 今日计划 40′ Title P\n待读共 2 篇（未排期 0）")
        #expect(zh.url == "paperdeck://today")

        let en = try #require(Self.compose("2026-09-29", papers, .en))
        #expect(en.title == "Today's reading · 2 papers · ~60 min")
        #expect(en.subtitle == "1 due today · next deadline Fri")
        #expect(en.body == "• Today Title T (3/7)\n• Today's plan 40′ Title P\n2 papers left (0 unscheduled)")
    }

    @Test func withOverdue() throws {
        let papers = [Self.paper("O", "2026-09-27", 30, rank: 1, done: 1, total: 4),
                      Self.paper("T", "2026-09-29", 20, rank: 2, done: 3, total: 7),
                      Self.paper("P", "2026-10-02", 100, rank: 3)]
        let zh = try #require(Self.compose("2026-09-29", papers))
        #expect(zh.title == "今日阅读 · 3 篇（1 篇逾期）")
        #expect(zh.subtitle == "逾期 2 天：Title O")
        #expect(zh.body == "• 逾期2天 Title O (1/4)\n• 今天 Title T (3/7)\n• 今日计划 10′ Title P\n待读共 3 篇（未排期 0）")

        let en = try #require(Self.compose("2026-09-29", papers, .en))
        #expect(en.title == "Today's reading · 3 papers (1 overdue)")
        #expect(en.subtitle == "2 days overdue: Title O")
        #expect(en.body.hasPrefix("• 2d overdue Title O (1/4)\n"))
    }

    @Test func planOnly() throws {
        let papers = [Self.paper("P", "2026-10-02", 100, rank: 1, total: 6, next: "Fig. 1–3")]
        let zh = try #require(Self.compose("2026-09-29", papers))
        #expect(zh.title == "今日阅读 · 约 60 分钟")
        #expect(zh.subtitle == "下一个 DDL：周五 · Title P")
        #expect(zh.body == "建议今天读 Title P 60 分钟（从 Fig. 1–3 开始）\n待读共 1 篇（未排期 0）")

        let en = try #require(Self.compose("2026-09-29", papers, .en))
        #expect(en.title == "Today's reading · ~60 min")
        #expect(en.subtitle == "Next deadline: Fri · Title P")
        #expect(en.body == "Suggested today: Title P, 60 min (start with Fig. 1–3)\n1 paper left (0 unscheduled)")
    }

    /// 只有未排期论文时照常提醒并含总数行.
    @Test func onlyUnscheduledStillReminds() throws {
        let papers = [Self.paper("a", nil, 60, rank: 1, mode: .none), Self.paper("b", nil, 30, rank: 2)]
        let zh = try #require(Self.compose("2026-09-29", papers))
        #expect(zh.title == "待读 2 篇")
        #expect(zh.subtitle == "其中 2 篇未排期")
        #expect(zh.body == "打开 PaperDeck 为未排期论文安排 DDL\n待读共 2 篇（未排期 2）")

        let en = try #require(Self.compose("2026-09-29", papers, .en))
        #expect(en.title == "2 papers left")
        #expect(en.subtitle == "2 unscheduled")
        #expect(en.body.hasSuffix("\n2 papers left (2 unscheduled)"))
    }

    @Test func emptyBacklogSkipsUnlessOptedIn() throws {
        #expect(Self.compose("2026-09-29", []) == nil)
        let doneOnly = [Self.paper("x", "2026-09-29", 0, rank: 1, status: .done)]
        #expect(Self.compose("2026-09-29", doneOnly) == nil)

        var optedIn = Self.settings
        optedIn.remindWhenEmpty = true
        let spec = try #require(Self.compose("2026-09-29", doneOnly, settings: optedIn))
        #expect(spec.title == "今天没有待读论文")
        #expect(spec.subtitle == "")
        #expect(spec.body == "待读共 0 篇（未排期 0）")
    }

    @Test func nonReadingDayStillReminds() throws {
        let papers = [Self.paper("M", "2026-10-05", 60, rank: 1), Self.paper("u", nil, 30, rank: 2, mode: .none)]
        let sat = try #require(Self.compose("2026-10-03", papers))
        #expect(sat.title == "待读 2 篇")
        #expect(sat.subtitle == "其中 1 篇未排期")
        #expect(sat.body == "• 下一个 DDL 周一：Title M\n打开 PaperDeck 为未排期论文安排 DDL\n待读共 2 篇（未排期 1）")

        // No unscheduled papers: the next DDL moves into the subtitle.
        let onlyDated = try #require(Self.compose("2026-10-03", [papers[0]]))
        #expect(onlyDated.subtitle == "下一个 DDL：周一 · Title M")
        #expect(onlyDated.body == "• 下一个 DDL 周一：Title M\n待读共 1 篇（未排期 0）")

        // Overdue work is still listed on a weekend.
        let friday = [Self.paper("F", "2026-10-02", 30, rank: 1)]
        let withOverdue = try #require(Self.compose("2026-10-03", friday))
        #expect(withOverdue.title == "今日阅读 · 1 篇（1 篇逾期）")
        #expect(withOverdue.body == "• 逾期1天 Title F\n待读共 1 篇（未排期 0）")
    }

    @Test func skipDayBehavesLikeNonReadingDay() throws {
        var s = Self.settings
        s.skipDays = [Self.d("2026-09-30")]
        let spec = try #require(Self.compose("2026-09-30", [Self.paper("P", "2026-10-02", 60, rank: 1)], settings: s))
        #expect(spec.title == "待读 1 篇")
    }

    @Test func futureDayAssumesNoProgress() throws {
        let papers = [Self.paper("A", "2026-09-30", 90, rank: 1)]
        let spec = try #require(Self.compose("2026-10-02", papers))
        #expect(spec.title == "今日阅读 · 1 篇（1 篇逾期）")
        #expect(spec.subtitle == "逾期 2 天：Title A")
    }

    @Test func titlesAreTruncatedTo60Characters() throws {
        let long = String(repeating: "X", count: 100)
        let messy = "Single-cell\n  atlas of the\tdeveloping neocortex"
        let papers = [Self.paper("L", "2026-09-29", 20, rank: 1, title: long),
                      Self.paper("M", "2026-09-29", 20, rank: 2, title: messy)]
        let spec = try #require(Self.compose("2026-09-29", papers))
        let clipped = String(repeating: "X", count: 59) + "…"
        #expect(clipped.count == 60)
        #expect(spec.body.contains("• 今天 \(clipped)\n"))
        #expect(!spec.body.contains(String(repeating: "X", count: 60)))
        #expect(spec.body.contains("• 今天 Single-cell atlas of the developing neocortex\n"))
    }

    @Test func atMostFourItemLinesThenMore() throws {
        let papers = (1...6).map { Self.paper("o\($0)", "2026-09-2\($0)", 10, rank: $0) }
        let spec = try #require(Self.compose("2026-09-29", papers))
        let lines = spec.body.split(separator: "\n").map(String.init)
        #expect(lines.count == 6)
        #expect(lines[0] == "• 逾期8天 Title o1")
        #expect(lines[4] == "还有 2 篇")
        #expect(lines[5] == "待读共 6 篇（未排期 0）")
        #expect(spec.title == "今日阅读 · 6 篇（6 篇逾期）")
    }

    // MARK: plan(from:)

    @Test func firstDayDependsOnReminderTime() {
        let papers = [Self.paper("u", nil, 30, rank: 1, mode: .none)]
        let before = ReminderComposer.plan(from: Self.at("2026-10-01", 10, 59), papers: papers, settings: Self.settings,
                                           lang: .zh, calendar: Self.cal)
        #expect(before.count == 14)
        #expect(before.first?.id == "daily-2026-10-01")
        #expect(before.last?.id == "daily-2026-10-14")
        let after = ReminderComposer.plan(from: Self.at("2026-10-01", 11, 0), papers: papers, settings: Self.settings,
                                          lang: .zh, calendar: Self.cal)
        #expect(after.count == 14)
        #expect(after.first?.id == "daily-2026-10-02")
        #expect(after.last?.id == "daily-2026-10-15")
        #expect(Set(after.map(\.id)).count == 14)
        // Consecutive days.
        for (a, b) in zip(after, after.dropFirst()) { #expect(b.day.days(from: a.day) == 1) }
    }

    @Test func customReminderTime() {
        var s = Self.settings
        s.reminderHour = 9; s.reminderMinute = 30
        let papers = [Self.paper("u", nil, 30, rank: 1, mode: .none)]
        let plan = ReminderComposer.plan(from: Self.at("2026-10-01", 9, 45), papers: papers, settings: s, lang: .en,
                                         calendar: Self.cal)
        #expect(plan.first?.id == "daily-2026-10-02")
        #expect(plan.first?.fireComponents == DateComponents(year: 2026, month: 10, day: 2, hour: 9, minute: 30))
    }

    @Test(arguments: [("2026-10-25", "2026-10-31", "2026-11-01", 25.0), ("2027-03-10", "2027-03-13", "2027-03-14", 23.0)])
    func dstKeepsLocalReminderTime(_ c: (String, String, String, Double)) throws {
        let papers = [Self.paper("u", nil, 30, rank: 1, mode: .none)]
        let plan = ReminderComposer.plan(from: Self.at(c.0, 12), papers: papers, settings: Self.settings, lang: .zh,
                                         calendar: Self.cal)
        #expect(plan.count == 14)
        for spec in plan {
            #expect(spec.fireComponents.hour == 11 && spec.fireComponents.minute == 0)
            #expect(Self.cal.component(.hour, from: spec.fireDate) == 11)
            #expect(Self.cal.component(.minute, from: spec.fireDate) == 0)
            #expect(LocalDate(spec.fireDate, calendar: Self.cal) == spec.day)
        }
        let eve = try #require(plan.first { $0.day == Self.d(c.1) })
        let switchDay = try #require(plan.first { $0.day == Self.d(c.2) })
        #expect(switchDay.fireComponents == DateComponents(year: switchDay.day.year, month: switchDay.day.month,
                                                           day: switchDay.day.day, hour: 11, minute: 0))
        #expect(switchDay.fireDate.timeIntervalSince(eve.fireDate) == c.3 * 3600)
    }

    @Test func everySpecEndsWithTheBacklogLine() {
        let papers = [Self.paper("A", "2026-10-01", 90, rank: 1, done: 1, total: 5),
                      Self.paper("B", "2026-10-06", 150, rank: 2),
                      Self.paper("C", nil, 45, rank: 3, mode: .none)]
        let plan = ReminderComposer.plan(from: Self.at("2026-09-29", 8), papers: papers, settings: Self.settings,
                                         lang: .zh, calendar: Self.cal)
        #expect(plan.count == 14)
        for spec in plan { #expect(spec.body.hasSuffix("待读共 3 篇（未排期 1）")) }
        // Bodies differ across days (the plan evolves as days pass without progress).
        #expect(Set(plan.map(\.hash)).count > 3)
    }

    @Test func hashIsStableAndContentSensitive() {
        let h = ReminderComposer.hash(title: "a", subtitle: "b", body: "c")
        #expect(h == ReminderComposer.hash(title: "a", subtitle: "b", body: "c"))
        #expect(h.count == 16)
        #expect(h.allSatisfy { $0.isHexDigit })
        #expect(h != ReminderComposer.hash(title: "a", subtitle: "b", body: "d"))
        #expect(h != ReminderComposer.hash(title: "ab", subtitle: "", body: "c"))
        let papers = [Self.paper("P", "2026-10-02", 100, rank: 1)]
        #expect(Self.compose("2026-09-29", papers)?.hash == Self.compose("2026-09-29", papers)?.hash)
        #expect(Self.compose("2026-09-29", papers)?.hash != Self.compose("2026-09-29", papers, .en)?.hash)
    }

    @Test func onTheSpotRecompute() throws {
        // "Remind me in 1 hour" recomputes at 12:00 with real progress so far.
        let papers = [Self.paper("P", "2026-10-02", 100, rank: 1)]
        let spec = try #require(ReminderComposer.compose(day: Self.d("2026-09-29"), papers: papers, settings: Self.settings,
                                                         lang: .zh, calendar: Self.cal, now: Self.at("2026-09-29", 19)))
        // After the cutoff nothing is planned for today any more.
        #expect(spec.title == "待读 1 篇")
    }

    @Test func userInfoAndOutOfRangeReminderTime() throws {
        var s = Self.settings
        s.reminderHour = 30; s.reminderMinute = -5
        let spec = try #require(Self.compose("2026-09-29", [Self.paper("u", nil, 10, rank: 1, mode: .none)], settings: s))
        #expect(spec.day == Self.d("2026-09-29"))
        #expect(spec.hour == 23 && spec.minute == 0)
        #expect(LocalDate(spec.fireDate, calendar: Self.cal) == spec.day)
        #expect(spec.userInfo == ["url": "paperdeck://today", "h": spec.hash])
        #expect(DeepLink(url: URL(string: spec.url)!) == .today)
    }

    @Test func reminderPaperFromRows() {
        let paper = Paper(id: "p", sha256: "s", fileSize: 1, title: "Neocortex", folder: "f", pdfName: "a.pdf",
                          originalName: "a.pdf", deadline: Self.d("2026-10-01"), queueRank: 3, estMinutes: 80)
        let checklist = [
            ChecklistItem(ord: 2, text: "c", section: "Discussion", minutes: 10, origin: .heuristic),
            ChecklistItem(ord: 0, text: "a", section: "Abstract", minutes: 5, origin: .heuristic, doneAt: Date()),
            ChecklistItem(ord: 1, text: "b", section: "Fig. 1–3", minutes: 45, origin: .heuristic),
        ]
        let rp = ReminderPaper(paper: paper, checklist: checklist)
        #expect(rp.doneItems == 1 && rp.totalItems == 3)
        #expect(rp.nextSection == "Fig. 1–3")
        #expect(rp.item.remainingMinutes == 55)
        #expect(rp.title == "Neocortex")
    }
}
