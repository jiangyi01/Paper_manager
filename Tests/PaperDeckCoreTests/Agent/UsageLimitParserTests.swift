import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct UsageLimitParserTests {
    private static let la = TimeZone(identifier: "America/Los_Angeles")!
    private static let ny = TimeZone(identifier: "America/New_York")!

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0, _ zone: TimeZone = la) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func parse(_ text: String, now: Date) -> Date? {
        UsageLimitParser.resetDate(in: text, now: now, timeZone: Self.la)
    }

    @Test func timeWithMinutesLaterToday() {
        let now = at(2026, 9, 30, 10)
        #expect(parse("You've hit your session limit · resets 3:45pm", now: now) == at(2026, 9, 30, 15, 45))
        #expect(parse("Resets 3:45 PM", now: now) == at(2026, 9, 30, 15, 45))
        #expect(parse("resets at 3:45 p.m.", now: now) == at(2026, 9, 30, 15, 45))
    }

    @Test func hourOnly() {
        #expect(parse("resets 3pm", now: at(2026, 9, 30, 10)) == at(2026, 9, 30, 15))
        #expect(parse("resets 12pm", now: at(2026, 9, 30, 10)) == at(2026, 9, 30, 12))
    }

    @Test func crossesMidnight() {
        #expect(parse("You've hit your session limit · resets 1am", now: at(2026, 9, 30, 23, 30)) == at(2026, 10, 1, 1))
        #expect(parse("resets 12am", now: at(2026, 9, 30, 21)) == at(2026, 10, 1, 0))
        // Month end → next month.
        #expect(parse("resets 2:15am", now: at(2026, 10, 31, 22)) == at(2026, 11, 1, 2, 15))
    }

    @Test func timeZoneSuffixIsHonored() {
        // 10:00 in LA is 13:00 in New York: the next 9am New York time is tomorrow.
        let now = at(2026, 9, 30, 10)
        let d = parse("You've hit your session limit · resets 9am (America/New_York)", now: now)
        #expect(d == at(2026, 10, 1, 9, 0, Self.ny))
        #expect(d == at(2026, 10, 1, 6))
        // 3pm New York is still ahead today.
        #expect(parse("resets 3pm (America/New_York)", now: now) == at(2026, 9, 30, 15, 0, Self.ny))
    }

    @Test func unknownTimeZoneFallsBackToLocal() {
        #expect(parse("resets 3pm (Mars/Olympus_Mons)", now: at(2026, 9, 30, 10)) == at(2026, 9, 30, 15))
    }

    @Test func monthDayForms() {
        let now = at(2026, 9, 30, 10)
        #expect(parse("You've hit your weekly limit · resets Oct 2, 9am", now: now) == at(2026, 10, 2, 9))
        #expect(parse("resets October 2 at 9:30am", now: now) == at(2026, 10, 2, 9, 30))
        #expect(parse("resets Oct 2nd, 9am (America/New_York)", now: now) == at(2026, 10, 2, 9, 0, Self.ny))
        // Late December: a January reset belongs to next year.
        #expect(parse("resets Jan 2, 9am", now: at(2026, 12, 30, 10)) == at(2027, 1, 2, 9))
    }

    @Test func justPassedResetIsNotPushedADayOut() {
        #expect(parse("resets 3:45pm", now: at(2026, 9, 30, 15, 47)) == at(2026, 9, 30, 15, 45))
        #expect(parse("resets 3:45pm", now: at(2026, 9, 30, 16, 0)) == at(2026, 10, 1, 15, 45))
    }

    @Test func dstFallBackDay() throws {
        // 2026-11-01: PDT → PST at 02:00. "3am" is 03:00 PST that day.
        let d = try #require(parse("resets 3am", now: at(2026, 11, 1, 0, 30)))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.la
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        #expect(c == DateComponents(year: 2026, month: 11, day: 1, hour: 3, minute: 0))
    }

    @Test func legacyEpoch() {
        let now = at(2026, 9, 30, 10)
        #expect(parse("Claude AI usage limit reached|1759244400", now: now) == Date(timeIntervalSince1970: 1759244400))
        #expect(parse("Claude AI usage limit reached|1759244400000", now: now) == Date(timeIntervalSince1970: 1759244400))
    }

    @Test func relativeForms() {
        let now = at(2026, 9, 30, 10)
        #expect(parse("resets in 2h 30m", now: now) == now.addingTimeInterval(9000))
        #expect(parse("resets in 45 minutes", now: now) == now.addingTimeInterval(2700))
    }

    @Test func unparseable() {
        let now = at(2026, 9, 30, 10)
        #expect(parse("You've hit your session limit", now: now) == nil)
        #expect(parse("resets 3", now: now) == nil)
        #expect(parse("resets 13pm", now: now) == nil)
        #expect(parse("resets Feb 30, 9am", now: now) == nil)
        #expect(parse("", now: now) == nil)
    }

    @Test func skipsFalsePositiveBeforeTheRealPhrase() {
        #expect(parse("counter resets 3 times; resets 4pm", now: at(2026, 9, 30, 10)) == at(2026, 9, 30, 16))
    }
}
