import Foundation

/// A calendar day in the user's local time zone ("2026-09-30"), independent of
/// clock time. Deadlines, skip days and reminder days are all LocalDates so DST
/// and time-zone changes never shift them. Encodes as an ISO `YYYY-MM-DD` string.
public struct LocalDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `YYYY-MM-DD`; nil for anything else (including impossible dates).
    public init?(iso: String) {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        guard comps.isValidDate(in: LocalDate.gregorian(.gmt)) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The local day containing `date`.
    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public static func today(now: Date = Date(), calendar: Calendar = .current) -> LocalDate {
        LocalDate(now, calendar: calendar)
    }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { iso }

    /// Local midnight at the start of this day.
    public func startOfDay(calendar: Calendar = .current) -> Date {
        date(hour: 0, minute: 0, calendar: calendar)
    }

    /// The instant this day reaches `hour:minute` local time (DST-safe: uses
    /// calendar components rather than adding seconds).
    public func date(hour: Int, minute: Int, calendar: Calendar = .current) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute
        return calendar.date(from: comps)!
    }

    /// Calendar-day arithmetic (never 86400-second steps).
    public func adding(days: Int, calendar: Calendar = .current) -> LocalDate {
        let noon = date(hour: 12, minute: 0, calendar: calendar)
        return LocalDate(calendar.date(byAdding: .day, value: days, to: noon)!, calendar: calendar)
    }

    /// Whole days from `other` to self (positive when self is later).
    public func days(from other: LocalDate) -> Int {
        let cal = LocalDate.gregorian(.gmt)
        let a = other.date(hour: 12, minute: 0, calendar: cal)
        let b = self.date(hour: 12, minute: 0, calendar: cal)
        return cal.dateComponents([.day], from: a, to: b).day!
    }

    /// 1 = Sunday … 7 = Saturday (Foundation convention).
    public func weekday(calendar: Calendar = .current) -> Int {
        calendar.component(.weekday, from: date(hour: 12, minute: 0, calendar: calendar))
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let d = LocalDate(iso: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid LocalDate \(s)"))
        }
        self = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(iso)
    }

    /// Gregorian calendar pinned to a time zone (tests use fixed zones).
    public static func gregorian(_ tz: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal
    }
}
