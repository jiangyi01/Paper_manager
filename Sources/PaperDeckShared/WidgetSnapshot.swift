import Foundation

/// The widget's only data source (`support/widget/snapshot.json`, §6.6). The app
/// writes it; the sandboxed widget reads it and never touches the DB. Version 1
/// wire format — keys and value shapes are a contract between two binaries that
/// may be built at different times, so readers reject versions they don't know.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    /// After this long without a rewrite the widget asks the user to open the app.
    public static let staleAfter: TimeInterval = 36 * 3600

    public struct ReminderTime: Codable, Sendable, Equatable {
        public var h: Int
        public var m: Int
        public init(h: Int, m: Int) { self.h = h; self.m = m }
    }

    public struct Backlog: Codable, Sendable, Equatable {
        public var total: Int          // status ≠ done, not deleted
        public var unscheduled: Int    // of which mode = none or no deadline
        public init(total: Int, unscheduled: Int) { self.total = total; self.unscheduled = unscheduled }
    }

    /// Today's set for one day: overdue ids first, then due that day, then planned slices.
    public struct Day: Codable, Sendable, Equatable {
        public var date: LocalDate
        public var count: Int
        public var minutes: Int
        public var overdue: Int
        public var ids: [String]
        public init(date: LocalDate, count: Int, minutes: Int, overdue: Int, ids: [String]) {
            self.date = date; self.count = count; self.minutes = minutes; self.overdue = overdue; self.ids = ids
        }
    }

    public struct NextItem: Codable, Sendable, Equatable {
        public var text: String
        public var section: String?
        public init(text: String, section: String?) { self.text = text; self.section = section }

        private enum CodingKeys: String, CodingKey { case text, section }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(text, forKey: .text)
            try c.encode(section, forKey: .section)     // explicit null, as in the documented format
        }
    }

    public struct PaperEntry: Codable, Sendable, Equatable {
        public var title: String
        public var authors: String         // pre-formatted: "Wang L … Kriegstein AR"
        public var venue: String?
        public var year: Int?
        public var deadline: LocalDate?    // nil = unscheduled
        public var pinned: Bool
        public var provisional: Bool
        public var atRisk: Bool
        public var doneAt: LocalDate?      // local day the paper was marked read
        public var priority: Int           // -1 / 0 / 1
        public var status: String          // "to_read" | "reading" | "done"
        public var done: Int               // checked checklist items
        public var total: Int
        public var minutesToday: Int
        public var tldr: String?           // ≤ 120 chars
        public var category: String?
        public var hue: Int?
        public var aiState: String
        public var next: [NextItem]        // first unchecked checklist items
        public var thumb: String?          // relative to the widget directory, e.g. "thumbs/<id>.jpg"

        public init(title: String, authors: String, venue: String?, year: Int?, deadline: LocalDate?,
                    pinned: Bool, provisional: Bool, atRisk: Bool, doneAt: LocalDate?, priority: Int,
                    status: String, done: Int, total: Int, minutesToday: Int, tldr: String?,
                    category: String?, hue: Int?, aiState: String, next: [NextItem], thumb: String?) {
            self.title = title; self.authors = authors; self.venue = venue; self.year = year
            self.deadline = deadline; self.pinned = pinned; self.provisional = provisional
            self.atRisk = atRisk; self.doneAt = doneAt; self.priority = priority; self.status = status
            self.done = done; self.total = total; self.minutesToday = minutesToday; self.tldr = tldr
            self.category = category; self.hue = hue; self.aiState = aiState; self.next = next
            self.thumb = thumb
        }

        public var isDone: Bool { status == "done" }

        /// The DDL chip as of `today` — the widget calls this per timeline entry.
        public func chip(today: LocalDate, lang: UILang,
                         calendar: Calendar = Calendar(identifier: .gregorian)) -> ChipSpec {
            DeadlineLabel.chip(deadline: deadline, done: isDone, doneAt: doneAt, pinned: pinned,
                               provisional: provisional, atRisk: atRisk, today: today, lang: lang,
                               calendar: calendar)
        }

        private enum CodingKeys: String, CodingKey {
            case title, authors, venue, year, deadline, pinned, provisional, atRisk, doneAt, priority
            case status, done, total, minutesToday, tldr, category, hue, aiState, next, thumb
        }

        /// Optionals are written as explicit nulls so the file matches the documented format.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(title, forKey: .title)
            try c.encode(authors, forKey: .authors)
            try c.encode(venue, forKey: .venue)
            try c.encode(year, forKey: .year)
            try c.encode(deadline, forKey: .deadline)
            try c.encode(pinned, forKey: .pinned)
            try c.encode(provisional, forKey: .provisional)
            try c.encode(atRisk, forKey: .atRisk)
            try c.encode(doneAt, forKey: .doneAt)
            try c.encode(priority, forKey: .priority)
            try c.encode(status, forKey: .status)
            try c.encode(done, forKey: .done)
            try c.encode(total, forKey: .total)
            try c.encode(minutesToday, forKey: .minutesToday)
            try c.encode(tldr, forKey: .tldr)
            try c.encode(category, forKey: .category)
            try c.encode(hue, forKey: .hue)
            try c.encode(aiState, forKey: .aiState)
            try c.encode(next, forKey: .next)
            try c.encode(thumb, forKey: .thumb)
        }
    }

    public enum SnapshotError: Error, Equatable {
        case unsupportedVersion(Int)
    }

    public var v: Int
    public var generatedAt: Date
    public var lang: UILang
    public var reminder: ReminderTime
    public var backlog: Backlog
    public var days: [Day]                  // [today, tomorrow]; after midnight the widget uses days[1]
    public var recentIds: [String]          // newest first
    public var papers: [String: PaperEntry]

    public init(v: Int = WidgetSnapshot.currentVersion, generatedAt: Date, lang: UILang, reminder: ReminderTime,
                backlog: Backlog, days: [Day], recentIds: [String], papers: [String: PaperEntry]) {
        self.v = v; self.generatedAt = generatedAt; self.lang = lang; self.reminder = reminder
        self.backlog = backlog; self.days = days; self.recentIds = recentIds; self.papers = papers
    }

    /// The entry for `date`, if the snapshot covers it.
    public func day(_ date: LocalDate) -> Day? { days.first { $0.date == date } }

    public func isStale(now: Date) -> Bool { now.timeIntervalSince(generatedAt) > WidgetSnapshot.staleAfter }

    /// True when everything except `generatedAt` matches — the app skips the
    /// write (and the widget reload) in that case.
    public func sameContent(as other: WidgetSnapshot) -> Bool {
        var a = self
        a.generatedAt = other.generatedAt
        return a == other
    }

    /// Sorted-key JSON, so unchanged content produces identical bytes.
    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }

    /// Decodes a snapshot, rejecting versions newer than this binary understands
    /// (the widget then shows its placeholder instead of misreading the data).
    public static func decode(_ data: Data) throws -> WidgetSnapshot {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let d = try? Date(s, strategy: .iso8601) { return d }
            if let d = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return d }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid ISO-8601 date \(s)"))
        }
        let header = try dec.decode(VersionHeader.self, from: data)
        guard header.v >= 1, header.v <= currentVersion else { throw SnapshotError.unsupportedVersion(header.v) }
        return try dec.decode(WidgetSnapshot.self, from: data)
    }

    private struct VersionHeader: Decodable { let v: Int }
}
