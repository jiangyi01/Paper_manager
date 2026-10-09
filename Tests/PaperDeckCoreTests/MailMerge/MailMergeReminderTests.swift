import Foundation
import Testing
@testable import PaperDeckCore

/// The 11:00 reminder's 「邮件待处理 N 封（M 封请求）」 line.
@Suite struct MailMergeReminderTests {
    private static let cal = LocalDate.gregorian(TimeZone(identifier: "America/Chicago")!)
    private static let settings = PlanSettings(dailyBudgetMinutes: 60, readingWeekdays: [2, 3, 4, 5, 6])
    private static func d(_ s: String) -> LocalDate { LocalDate(iso: s)! }
    private static func paper(_ id: String, _ deadline: String, _ minutes: Int, rank: Int) -> ReminderPaper {
        ReminderPaper(item: SchedItem(id: id, deadline: d(deadline), queueRank: rank, remainingMinutes: minutes),
                      title: "Title \(id)", doneItems: 0, totalItems: 0)
    }

    @Test func mailLineGoesBeforeTheLastLine() throws {
        let papers = [Self.paper("T", "2026-09-29", 20, rank: 1)]
        let mail = MailReminderInfo(pending: 3, requests: 1)
        let zh = try #require(ReminderComposer.compose(day: Self.d("2026-09-29"), papers: papers, settings: Self.settings,
                                                      lang: .zh, calendar: Self.cal, mail: mail))
        #expect(zh.body == "• 今天 Title T\n邮件待处理 3 封（1 封请求）\n待读共 1 篇（未排期 0）")
        let en = try #require(ReminderComposer.compose(day: Self.d("2026-09-29"), papers: papers, settings: Self.settings,
                                                      lang: .en, calendar: Self.cal, mail: mail))
        #expect(en.body.hasSuffix("\n3 emails to handle (1 request)\n1 paper left (0 unscheduled)"))

        // No mail → exactly today's text (and hash).
        let plain = try #require(ReminderComposer.compose(day: Self.d("2026-09-29"), papers: papers, settings: Self.settings,
                                                         lang: .zh, calendar: Self.cal))
        #expect(plain.body == "• 今天 Title T\n待读共 1 篇（未排期 0）")
        #expect(ReminderComposer.compose(day: Self.d("2026-09-29"), papers: papers, settings: Self.settings, lang: .zh,
                                         calendar: Self.cal, mail: MailReminderInfo(pending: 0, requests: 0)) == plain)
        #expect(zh.hash != plain.hash)

        #expect(MailReminderInfo.line(total: 1, requests: 0, .en) == "1 email to handle")
        #expect(MailReminderInfo.line(total: 2, requests: 2, .en) == "2 emails to handle (2 requests)")
        #expect(MailReminderInfo.line(total: 2, requests: 0, .zh) == "邮件待处理 2 封")
        #expect(MailReminderInfo.line(total: 0, requests: 0, .zh) == nil)
    }

    @Test func remindsForMailAloneAndCountsSnoozedCardsOnTheirDay() throws {
        let mail = MailReminderInfo(pending: 0, requests: 0, snoozed: [
            .init(until: Self.d("2026-10-01").date(hour: 9, minute: 0, calendar: Self.cal), isRequest: true),
        ])
        // Nothing to read, 无待读时不提醒 on (remindWhenEmpty false): no reminder until the card wakes.
        #expect(ReminderComposer.compose(day: Self.d("2026-09-30"), papers: [], settings: Self.settings, lang: .zh,
                                         calendar: Self.cal, mail: mail) == nil)
        let oct1 = try #require(ReminderComposer.compose(day: Self.d("2026-10-01"), papers: [], settings: Self.settings,
                                                        lang: .zh, calendar: Self.cal, mail: mail))
        #expect(oct1.title == "今天没有待读论文")
        #expect(oct1.body == "邮件待处理 1 封（1 封请求）\n待读共 0 篇（未排期 0）")
        let plan = ReminderComposer.plan(from: Self.d("2026-09-29").date(hour: 12, minute: 0, calendar: Self.cal), days: 5,
                                         papers: [], settings: Self.settings, lang: .en, calendar: Self.cal, mail: mail)
        #expect(plan.map(\.day.iso) == ["2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04"])
        #expect(plan.first?.body.hasPrefix("1 email to handle (1 request)\n") == true)
    }

    @Test func engineReminderPlanUsesTheMailCounts() async throws {
        let settings = MailMergeKit.settings(lang: .en)
        try await MailMergeKit.run(settings) { env in
            try await MailMergeKit.insert(env, MailMergeKit.message(kind: .advisor), items: [])
            try await MailMergeKit.insert(env, MailMergeKit.message(kind: .alert, triage: nil), items: [])
            try await MailMergeKit.insert(env, MailMergeKit.message(kind: .person, state: .dismissed), items: [])
            let plan = try await env.engine.reminderPlan(from: MailMergeKit.start, days: 1)
            #expect(plan.count == 1)
            #expect(plan.first?.body == "2 emails to handle (1 request)\n0 papers left (0 unscheduled)")

            var off = MailSettings()
            off.includeInDailyReminder = false
            env.mail.value = off
            #expect(try await env.engine.reminderPlan(from: MailMergeKit.start, days: 1).isEmpty)
            #expect(try await env.engine.composeReminder(day: MailMergeKit.day(2026, 9, 29)) == nil)
        }
    }
}
