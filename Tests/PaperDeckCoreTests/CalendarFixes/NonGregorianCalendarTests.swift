import Foundation
import Testing
@testable import PaperDeckCore

/// A Mac set to a Buddhist, Hebrew, Japanese, Islamic or ROC calendar (core-data-2, core-data-3,
/// core-data-extra-2): every LocalDate is Gregorian (only the calendar's time zone is used), the
/// engine's own calendar is Gregorian, Skip today persists, email due dates and the import chip are
/// right, backups are named and pruned by their real day, and a stored 2569-… reminder day heals.
@Suite struct NonGregorianCalendarTests {
    private typealias Kit = OpsTestKit
    static let chicago = TimeZone(identifier: "America/Chicago")!
    static let systems: [Calendar.Identifier] = [.buddhist, .hebrew, .japanese, .islamicUmmAlQura, .republicOfChina]

    static func system(_ id: Calendar.Identifier, firstWeekday: Int? = nil) -> Calendar {
        var c = Calendar(identifier: id)
        c.timeZone = chicago
        if let firstWeekday { c.firstWeekday = firstWeekday }
        return c
    }

    // MARK: LocalDate

    @Test(arguments: systems)
    func localDateNumbersAreGregorian(_ id: Calendar.Identifier) {
        let cal = Self.system(id)
        let now = Kit.start                                             // Tue 2026-09-29 10:00 Chicago
        let day = LocalDate(year: 2026, month: 9, day: 29)
        #expect(LocalDate(now, calendar: cal) == day)
        #expect(LocalDate.today(now: now, calendar: cal) == day)
        #expect(day.date(hour: 10, minute: 0, calendar: cal) == now)
        #expect(day.startOfDay(calendar: cal) == Kit.calendar.startOfDay(for: now))
        #expect(day.adding(days: 3, calendar: cal) == LocalDate(year: 2026, month: 10, day: 2))
        #expect(day.adding(days: -60, calendar: cal) == LocalDate(year: 2026, month: 7, day: 31))
        #expect(day.weekday(calendar: cal) == 3)                          // Tuesday
        #expect(day.startOfWeek(calendar: Self.system(id, firstWeekday: 2)) == LocalDate(year: 2026, month: 9, day: 28))
        #expect(day.startOfWeek(calendar: Self.system(id, firstWeekday: 1)) == LocalDate(year: 2026, month: 9, day: 27))
    }

    @Test func theEngineCalendarIsGregorianByDefault() {
        #expect(LocalDate.localGregorian.identifier == .gregorian)
        #expect(Engine.Dependencies(fetcher: nil).calendar.identifier == .gregorian)
        #expect(AssistDailyCounter().day(Kit.start).year == 2026)
    }

    // MARK: Skip today, email due dates, the import chip

    @Test(arguments: [Calendar.Identifier.buddhist, .hebrew])
    func skipTodayPersistsItsDay(_ id: Calendar.Identifier) async throws {
        try await Kit.run(calendar: Self.system(id)) { env in
            let a = try await Kit.addPaper(env, title: "A", deadline: Kit.day(2026, 9, 29))
            let token = try await env.engine.skipToday()
            #expect(token.day == Kit.day(2026, 9, 29))
            #expect(await env.engine.ctx.skipDays() == [Kit.day(2026, 9, 29)])
            #expect(try await Kit.paper(env, a.id).deadline == Kit.day(2026, 9, 30))
            // A second press the same day moves nothing again (the skip day is known).
            _ = try await env.engine.skipToday()
            #expect(try await Kit.paper(env, a.id).deadline == Kit.day(2026, 9, 30))
            #expect(try await env.engine.undo(token: token))
        }
    }

    @Test(arguments: [Calendar.Identifier.buddhist, .hebrew])
    func emailDueDatesStayInTheirYear(_ id: Calendar.Identifier) throws {
        let cal = Self.system(id)
        let received = LocalDate(year: 2026, month: 10, day: 14).date(hour: 10, minute: 0, calendar: Kit.calendar)
        let slash = try #require(MailHeuristics.findDue(in: "Please read the attached paper by 10/20 so we can discuss it.",
                                                        received: received, now: received, calendar: cal))
        #expect(slash.date == LocalDate(year: 2026, month: 10, day: 20))
        let explicit = try #require(MailHeuristics.findDue(in: "Please read it by Oct 20, 2026 before the meeting.",
                                                           received: received, now: received, calendar: cal))
        #expect(explicit.date == LocalDate(year: 2026, month: 10, day: 20))
    }

    @Test func theImportChipReadsTheSameUnderABuddhistCalendar() async throws {
        let gregorian = try await Self.addedToast(calendar: Kit.calendar)
        let buddhist = try await Self.addedToast(calendar: Self.system(.buddhist))
        #expect(buddhist == gregorian)
        #expect(!buddhist.contains("overdue"))
    }

    /// The "Added: … · due …" toast of one imported PDF, for an engine on `calendar`.
    private static func addedToast(calendar: Calendar) async throws -> String {
        let env = try await Kit.make(Kit.settings(lang: .en), calendar: calendar)
        let events = DedupeKit.Events(hub: env.engine.events)
        let downloads = env.root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let pdf = downloads.appendingPathComponent("chip.pdf")
        try DedupeKit.pdfData(title: "Lineage tracing of organoid progenitors at scale", doi: nil,
                              body: DedupeKit.body(seed: "chip"), pages: 3, tag: "chip").write(to: pdf)
        _ = await env.engine.intake.ingest([.file(pdf)], options: ImportOptions(origin: .drop))
        await events.drain()
        let message = events.toasts.map(\.message).first { $0.hasPrefix("Added") }
        await env.cleanup()
        return try #require(message)
    }

    // MARK: Backups

    @Test func dailyBackupIsNamedByTheGregorianDay() async throws {
        try await Kit.run(calendar: Self.system(.buddhist)) { env in
            _ = try await Kit.addPaper(env)
            let made = try await Maintenance(engine: env.engine, trash: { _ in false }).dailyBackup()
            #expect(made.created?.lastPathComponent == "library-2026-09-29.sqlite")
        }
    }

    @Test func pruningOrdersByTheRealDay() {
        let today = LocalDate(year: 2026, month: 9, day: 29)
        func ago(_ days: Double) -> Date { Kit.start.addingTimeInterval(-days * 86_400) }
        // Seven backups a Buddhist calendar named (2569-…), taken 1…7 days ago, plus today's.
        var entries: [(name: String, modified: Date?)] = (1...7).map { ("library-2569-09-\(29 - $0).sqlite", ago(Double($0))) }
        entries.append(("library-2026-09-29.sqlite", Kit.start))
        let pruned = Maintenance.backupsToPrune(entries, today: today, calendar: Kit.calendar)
        #expect(pruned == ["library-2569-09-22.sqlite"])                   // the oldest by its date, not today's
        // Hebrew (5787-…), Islamic (1448-…) and Japanese (0008-…) names count by their file date too.
        let odd: [(name: String, modified: Date?)] = [
            ("library-5787-01-18.sqlite", ago(1)), ("library-1448-04-18.sqlite", ago(2)),
            ("library-0008-09-26.sqlite", ago(3)), ("library-2026-09-20.sqlite", ago(9)),
        ]
        #expect(Maintenance.backupsToPrune(odd, today: today, calendar: Kit.calendar, keep: 3) == ["library-2026-09-20.sqlite"])
        // Gregorian names keep their name order (a day's daily backup and its manual snapshots).
        let plain: [(name: String, modified: Date?)] = [
            ("library-2026-09-28.sqlite", nil), ("library-2026-09-29.sqlite", nil), ("library-2026-09-29-100000.sqlite", nil),
        ]
        #expect(Maintenance.backupsToPrune(plain, today: today, calendar: Kit.calendar, keep: 2) == ["library-2026-09-28.sqlite"])
    }

    @Test func todaysBackupIsKeptNextToBuddhistNamedOnes() async throws {
        try await Kit.run { env in
            _ = try await Kit.addPaper(env)
            let fm = FileManager.default
            for k in 1...7 {
                let url = env.paths.backups.appendingPathComponent("library-2569-09-\(29 - k).sqlite")
                try Data("old".utf8).write(to: url)
                try fm.setAttributes([.modificationDate: Kit.start.addingTimeInterval(-Double(k) * 86_400)], ofItemAtPath: url.path)
            }
            let made = try await Maintenance(engine: env.engine, trash: { _ in false }).dailyBackup()
            #expect(made.created?.lastPathComponent == "library-2026-09-29.sqlite")
            #expect(made.pruned == ["library-2569-09-22.sqlite"])
            #expect(fm.fileExists(atPath: env.paths.backups.appendingPathComponent("library-2026-09-29.sqlite").path))
        }
    }

    @Test func countersOfANonGregorianYearArePruned() {
        let today = LocalDate(year: 2026, month: 10, day: 14)
        #expect(Maintenance.isEarlierCounterDay("assist.count.2569-10-14.claude", prefix: "assist.count", today: today))
        #expect(Maintenance.isEarlierCounterDay("dedupe.ai.count.5787-01-18", prefix: "dedupe.ai.count", today: today))
        #expect(!Maintenance.isEarlierCounterDay("assist.count.2026-10-14.claude", prefix: "assist.count", today: today))
        #expect(!Maintenance.isEarlierCounterDay("assist.count.2026-10-15.codex", prefix: "assist.count", today: today))
    }

    // MARK: Reminders

    @Test func aStoredReminderDayAfterTodayIsClamped() {
        let today = LocalDate(year: 2026, month: 10, day: 14)
        #expect(ReminderComposer.clampedLastDelivered(LocalDate(year: 2569, month: 10, day: 14), today: today) == today)
        #expect(ReminderComposer.clampedLastDelivered(LocalDate(year: 5787, month: 1, day: 18), today: today) == today)
        #expect(ReminderComposer.clampedLastDelivered(LocalDate(year: 2026, month: 10, day: 13), today: today)
            == LocalDate(year: 2026, month: 10, day: 13))
        #expect(ReminderComposer.clampedLastDelivered(nil, today: today) == nil)
    }

    @Test func reminderTriggersCarryAGregorianCalendarOnANonGregorianMac() throws {
        let papers: [ReminderPaper] = []
        var settings = PlanSettings()
        settings.remindWhenEmpty = true
        let spec = try #require(ReminderComposer.compose(day: LocalDate(year: 2026, month: 10, day: 14), papers: papers,
                                                         settings: settings, lang: .en, calendar: Self.system(.buddhist)))
        #expect(spec.id == "daily-2026-10-14")
        let plain = spec.triggerComponents(system: Kit.calendar)
        #expect(plain == spec.fireComponents && plain.calendar == nil)
        let buddhist = spec.triggerComponents(system: Self.system(.buddhist))
        #expect(buddhist.calendar?.identifier == .gregorian && buddhist.timeZone == nil)
        #expect(buddhist.year == 2026 && buddhist.month == 10 && buddhist.day == 14)
        // Read in that calendar, the trigger is the Gregorian day (not 543 years earlier).
        let fire = try #require(buddhist.calendar?.date(from: buddhist))
        #expect(LocalDate(fire, calendar: LocalDate.localGregorian) == LocalDate(year: 2026, month: 10, day: 14))
    }
}
