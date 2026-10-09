import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct DeadlineLabelTests {
    private static let chicago = LocalDate.gregorian(TimeZone(identifier: "America/Chicago")!)
    private static let today = LocalDate(year: 2026, month: 9, day: 29)     // Tuesday
    private static func d(_ s: String) -> LocalDate { LocalDate(iso: s)! }

    private static func chip(_ deadline: String?, done: Bool = false, doneAt: String? = nil, pinned: Bool = false,
                             provisional: Bool = false, atRisk: Bool = false, today: LocalDate = today,
                             _ lang: UILang) -> ChipSpec {
        DeadlineLabel.chip(deadline: deadline.map(d), done: done, doneAt: doneAt.map(d), pinned: pinned,
                           provisional: provisional, atRisk: atRisk, today: today, lang: lang, calendar: chicago)
    }

    /// Every row of the §8 DDLChip table in both languages.
    @Test(arguments: [
        // (deadline, zh, en, style)
        ("2026-09-27", "逾期 2 天", "2 days overdue", ChipSpec.Style.overdue),
        ("2026-09-28", "逾期 1 天", "1 day overdue", .overdue),
        ("2026-09-29", "今天", "Today", .today),
        ("2026-09-30", "明天", "Tomorrow", .tomorrow),
        ("2026-10-01", "周四", "Thu", .soon),
        ("2026-10-02", "周五", "Fri", .soon),
        ("2026-10-03", "周六 10/3", "Sat 10/3", .thisWeek),
        ("2026-10-05", "周一 10/5", "Mon 10/5", .thisWeek),
        ("2026-10-06", "10/6", "10/6", .later),
        ("2026-10-15", "10/15", "10/15", .later),
        ("2027-09-29", "9/29", "9/29", .later),
    ])
    func tableRow(_ row: (String, String, String, ChipSpec.Style)) {
        let zh = Self.chip(row.0, .zh), en = Self.chip(row.0, .en)
        #expect(zh.text == row.1)
        #expect(en.text == row.2)
        #expect(zh.style == row.3 && en.style == row.3)
        #expect(!zh.pinned && !zh.provisional && !zh.atRisk)
    }

    @Test func doneShowsCheckAndCompletionDay() {
        for lang in UILang.allCases {
            let c = Self.chip("2026-10-05", done: true, doneAt: "2026-09-28", pinned: true, provisional: true, atRisk: true, lang)
            #expect(c == ChipSpec(text: "✓ 9/28", style: .done))      // modifiers never apply to a read paper
            #expect(Self.chip(nil, done: true, lang).text == "✓")
        }
    }

    @Test func unscheduled() {
        #expect(Self.chip(nil, .zh) == ChipSpec(text: "未排期", style: .unscheduled))
        #expect(Self.chip(nil, provisional: true, .en) == ChipSpec(text: "Unscheduled", style: .unscheduled))
    }

    @Test func modifiers() {
        let pinned = Self.chip("2026-10-01", pinned: true, .zh)
        #expect(pinned.text == "周四" && pinned.pinned)
        let approx = Self.chip("2026-10-02", provisional: true, .zh)
        #expect(approx.text == "≈周五" && approx.provisional)
        #expect(Self.chip("2026-09-29", provisional: true, .en).text == "≈Today")
        #expect(Self.chip("2026-10-15", provisional: true, .en).text == "≈10/15")
        let risk = Self.chip("2026-09-30", atRisk: true, .en)
        #expect(risk.atRisk && risk.style == .tomorrow)
        // An overdue paper is overdue, not "at risk".
        #expect(Self.chip("2026-09-20", atRisk: true, .zh).atRisk == false)
        #expect(Self.chip("2026-09-29", atRisk: true, .zh).atRisk)
    }

    /// The chip flips exactly at local midnight of the injected time zone.
    @Test func midnightBoundary() {
        let deadline = Self.d("2026-09-30")
        let before = Self.d("2026-09-29").date(hour: 23, minute: 59, calendar: Self.chicago).addingTimeInterval(59)
        let after = before.addingTimeInterval(1)
        for (instant, zh, en) in [(before, "明天", "Tomorrow"), (after, "今天", "Today")] {
            let today = LocalDate(instant, calendar: Self.chicago)
            #expect(DeadlineLabel.chip(deadline: deadline, done: false, doneAt: nil, pinned: false, provisional: false,
                                       atRisk: false, today: today, lang: .zh, calendar: Self.chicago).text == zh)
            #expect(DeadlineLabel.chip(deadline: deadline, done: false, doneAt: nil, pinned: false, provisional: false,
                                       atRisk: false, today: today, lang: .en, calendar: Self.chicago).text == en)
        }
        // The same instant is already "today" in Shanghai.
        let shanghai = LocalDate.gregorian(TimeZone(identifier: "Asia/Shanghai")!)
        #expect(LocalDate(before, calendar: shanghai) == Self.d("2026-09-30"))
        // Past midnight the deadline turns overdue.
        let next = Self.d("2026-10-01")
        #expect(Self.chip("2026-09-30", today: next, .zh).text == "逾期 1 天")
    }

    @Test func weekdaysAcrossYearEnd() {
        let today = Self.d("2026-12-30")      // Wednesday
        #expect(Self.chip("2027-01-01", today: today, .zh).text == "周五")
        #expect(Self.chip("2027-01-02", today: today, .en).text == "Sat")
        #expect(Self.chip("2027-01-03", today: today, .en).text == "Sun 1/3")
        #expect(Self.chip("2027-01-06", today: today, .en).text == "1/6")
    }

    @Test func weekdayNames() {
        #expect((1...7).map { SharedStrings.weekday($0, .zh) } == ["周日", "周一", "周二", "周三", "周四", "周五", "周六"])
        #expect((1...7).map { SharedStrings.weekday($0, .en) } == ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"])
    }

    @Test func atRiskHint() {
        let today = Self.today
        #expect(DeadlineLabel.atRiskHint(finish: Self.d("2026-10-05"), today: today, lang: .zh) == "按当前预算预计 周一 10/5 才能读完")
        #expect(DeadlineLabel.atRiskHint(finish: Self.d("2026-10-01"), today: today, lang: .zh) == "按当前预算预计 周四 才能读完")
        #expect(DeadlineLabel.atRiskHint(finish: Self.d("2026-10-01"), today: today, lang: .en)
            == "At the current budget, expected to finish Thu")
        #expect(DeadlineLabel.atRiskHint(finish: nil, today: today, lang: .zh) == "按当前预算无法在排期范围内读完")
    }

    @Test func nonGregorianCalendarStillNamesGregorianWeekdays() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "America/Chicago")!
        let c = DeadlineLabel.chip(deadline: Self.d("2026-10-01"), done: false, doneAt: nil, pinned: false, provisional: false,
                                   atRisk: false, today: Self.today, lang: .zh, calendar: buddhist)
        #expect(c.text == "周四")
    }
}
