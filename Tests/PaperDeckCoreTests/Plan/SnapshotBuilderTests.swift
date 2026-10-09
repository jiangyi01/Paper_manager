import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct SnapshotBuilderTests {
    private static let cal = LocalDate.gregorian(TimeZone(identifier: "America/Chicago")!)
    private static let settings = PlanSettings(dailyBudgetMinutes: 60, readingWeekdays: [2, 3, 4, 5, 6])
    private static func d(_ s: String) -> LocalDate { LocalDate(iso: s)! }
    private static func at(_ day: String, _ h: Int, _ m: Int = 0) -> Date { d(day).date(hour: h, minute: m, calendar: cal) }

    private static func paper(_ id: String, added: Int, deadline: String?, mode: ScheduleMode = .auto, est: Int = 60,
                              status: PaperStatus = .toRead, doneAt: Date? = nil, deleted: Bool = false,
                              category: Int64? = nil, tldr: String? = nil, authors: [String] = ["Li Wang"]) -> Paper {
        Paper(id: id, sha256: id, fileSize: 1, ids: PaperIDs(doi: id == "bio" ? "10.1101/2025.09.01.673319" : nil),
              title: "Title \(id)", authors: authors, year: 2024, venue: id == "bio" ? nil : "Nature",
              folder: "Papers/\(id)", pdfName: "\(id).pdf", originalName: "\(id).pdf", status: status,
              deadline: deadline.map(d), scheduleMode: mode, queueRank: added, provisional: false, estMinutes: est,
              categoryPK: category, tldr: tldr, aiState: .done,
              addedAt: at("2026-09-01", 9).addingTimeInterval(Double(added) * 60), doneAt: doneAt,
              deletedAt: deleted ? at("2026-09-20", 9) : nil)
    }

    private static func sample() -> ([Paper], [String: [ChecklistItem]], [Int64: PaperDeckCore.PaperCategory]) {
        let papers = [
            paper("over", added: 1, deadline: "2026-09-28", category: 3,
                  tldr: String(repeating: "Cortical progenitors expand. ", count: 10),
                  authors: ["Li Wang", "Yu Chen", "Arnold R. Kriegstein"]),
            paper("due", added: 2, deadline: "2026-09-29", est: 20, authors: ["Kriegstein, Arnold R.", "Jean-Pierre Dupont"]),
            paper("plan", added: 3, deadline: "2026-10-02", est: 100),
            paper("none", added: 4, deadline: nil, mode: .none),
            paper("done", added: 5, deadline: "2026-09-25", status: .done, doneAt: at("2026-09-28", 23, 30)),
            paper("bio", added: 6, deadline: "2026-10-20"),
            paper("gone", added: 7, deadline: "2026-09-29", deleted: true),
        ]
        let checklists: [String: [ChecklistItem]] = [
            "over": [
                ChecklistItem(id: "c1", ord: 0, text: "Read abstract", section: "Abstract", minutes: 5, origin: .heuristic, doneAt: Date()),
                ChecklistItem(id: "c2", ord: 1, text: "Fig. 2: compare proportions", section: "Fig. 2", minutes: 15, origin: .agent),
                ChecklistItem(id: "c3", ord: 2, text: "Methods: stats", section: nil, minutes: 10, origin: .agent),
                ChecklistItem(id: "c4", ord: 3, text: "Discussion", section: "Discussion", minutes: 5, origin: .agent),
            ],
        ]
        let categories: [Int64: PaperDeckCore.PaperCategory] = [3: PaperDeckCore.PaperCategory(pk: 3, name: "Neuroscience & Development", hue: 4, origin: .starter)]
        return (papers, checklists, categories)
    }

    private static func build(now: Date = at("2026-09-29", 10, 0), thumbs: Set<String> = ["over"]) -> WidgetSnapshot {
        let (p, c, k) = sample()
        return SnapshotBuilder.build(papers: p, checklists: c, categories: k, settings: settings, lang: .zh,
                                     now: now, calendar: cal, thumbnails: thumbs)
    }

    @Test func buildsDaysBacklogAndRecent() throws {
        let s = Self.build()
        #expect(s.v == 1)
        #expect(s.lang == .zh)
        #expect(s.reminder == .init(h: 11, m: 0))
        #expect(s.backlog == .init(total: 5, unscheduled: 1))     // "done" and deleted excluded
        #expect(s.days.map(\.date) == [Self.d("2026-09-29"), Self.d("2026-09-30")])
        // Today: over (30 left) + due (20) are fixed; plan gets the last 10′.
        try #require(s.days.count > 1)          // no index past a failed expectation (QA-15)
        #expect(s.days[0] == .init(date: Self.d("2026-09-29"), count: 3, minutes: 60, overdue: 1, ids: ["over", "due", "plan"]))
        // Tomorrow, assuming nothing is read today: both fixed papers are overdue.
        #expect(s.days[1] == .init(date: Self.d("2026-09-30"), count: 3, minutes: 60, overdue: 2, ids: ["over", "due", "plan"]))
        #expect(s.recentIds == ["bio", "done", "none", "plan"])
        #expect(Set(s.papers.keys) == ["over", "due", "plan", "none", "done", "bio"])
    }

    @Test func paperEntryFields() throws {
        let s = Self.build()
        let over = try #require(s.papers["over"])
        #expect(over.title == "Title over")
        #expect(over.authors == "Wang L … Kriegstein AR")
        #expect(over.venue == "Nature" && over.year == 2024)
        #expect(over.deadline == Self.d("2026-09-28"))
        #expect(over.status == "to_read" && over.priority == 0 && over.aiState == "done")
        #expect(over.done == 1 && over.total == 4)
        #expect(over.minutesToday == 30)
        #expect(over.category == "Neuroscience & Development" && over.hue == 4)
        #expect(over.next == [.init(text: "Fig. 2: compare proportions", section: "Fig. 2"),
                              .init(text: "Methods: stats", section: nil)])
        #expect(over.thumb == "thumbs/over.jpg")
        let tldr = try #require(over.tldr)
        #expect(tldr.count == 120 && tldr.hasSuffix("…"))

        let due = try #require(s.papers["due"])
        #expect(due.authors == "Kriegstein AR & Dupont JP")
        #expect(due.thumb == nil && due.category == nil && due.tldr == nil)
        #expect(due.minutesToday == 20)
        #expect(due.atRisk == false)

        #expect(s.papers["plan"]?.minutesToday == 10)
        #expect(s.papers["none"]?.deadline == nil)
        #expect(s.papers["bio"]?.venue == "bioRxiv")
        let done = try #require(s.papers["done"])
        #expect(done.doneAt == Self.d("2026-09-28"))              // local day, not the UTC one
        #expect(done.chip(today: Self.d("2026-09-29"), lang: .zh).text == "✓ 9/28")
        #expect(s.papers["over"]?.chip(today: Self.d("2026-09-29"), lang: .zh).text == "逾期 1 天")
    }

    @Test func roundTripIsLossless() throws {
        let s = Self.build(now: Self.at("2026-09-29", 10, 0).addingTimeInterval(0.75))
        let data = try s.encoded()
        let back = try WidgetSnapshot.decode(data)
        #expect(back == s)
        #expect(try back.encoded() == data)                       // byte-stable (sorted keys)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"doneAt\":null"))                 // explicit nulls, as documented
        #expect(json.contains("\"thumb\":\"thumbs/over.jpg\""))
        #expect(json.contains("\"deadline\":\"2026-09-28\""))
        #expect(json.contains("\"generatedAt\":\"2026-09-29T15:00:00Z\""))
    }

    @Test func rejectsNewerVersions() throws {
        var s = Self.build()
        s.v = 2
        let data = try s.encoded()
        #expect(throws: WidgetSnapshot.SnapshotError.unsupportedVersion(2)) { try WidgetSnapshot.decode(data) }
        s.v = 0
        let zero = try s.encoded()
        #expect(throws: WidgetSnapshot.SnapshotError.unsupportedVersion(0)) { try WidgetSnapshot.decode(zero) }
        #expect(throws: (any Error).self) { try WidgetSnapshot.decode(Data("not json".utf8)) }
        #expect(throws: (any Error).self) { try WidgetSnapshot.decode(Data("{\"v\":1}".utf8)) }
    }

    /// The documented §6.6 example (with concrete values) decodes.
    @Test func decodesDocumentedFormat() throws {
        let json = """
        {"v":1,"generatedAt":"2026-09-29T15:00:00.123Z","lang":"zh","reminder":{"h":11,"m":0},"backlog":{"total":12,"unscheduled":3},
         "days":[{"date":"2026-09-29","count":3,"minutes":70,"overdue":1,"ids":["p1","p2","p3"]},{"date":"2026-09-30","count":2,"minutes":60,"overdue":1,"ids":["p1","p4"]}],
         "recentIds":["p9","p8","p7","p6"],
         "papers":{"p1":{"title":"T","authors":"Wang L … Kriegstein AR","venue":"Nature","year":2024,"deadline":"2026-09-28","pinned":false,
           "provisional":false,"atRisk":false,"doneAt":null,"priority":1,"status":"reading","done":2,"total":6,"minutesToday":40,
           "tldr":"≤120 chars","category":"Neuro","hue":3,"aiState":"done","next":[{"text":"Read Fig. 2","section":"Fig. 2"}],"thumb":"thumbs/p1.jpg"}}}
        """
        let s = try WidgetSnapshot.decode(Data(json.utf8))
        #expect(s.backlog.total == 12)
        #expect(s.day(Self.d("2026-09-30"))?.ids == ["p1", "p4"])
        #expect(s.papers["p1"]?.status == "reading")
        #expect(s.papers["p1"]?.chip(today: Self.d("2026-09-29"), lang: .en).style == .overdue)
        // Missing optional keys are tolerated too.
        let minimal = json.replacingOccurrences(of: "\"doneAt\":null,", with: "").replacingOccurrences(of: ",\"thumb\":\"thumbs/p1.jpg\"", with: "")
        #expect(try WidgetSnapshot.decode(Data(minimal.utf8)).papers["p1"]?.thumb == nil)
    }

    @Test func sameContentIgnoresGeneratedAt() {
        let a = Self.build(now: Self.at("2026-09-29", 10, 0))
        let b = Self.build(now: Self.at("2026-09-29", 10, 1))
        #expect(a != b)
        #expect(a.sameContent(as: b))
        let c = Self.build(now: Self.at("2026-09-29", 10, 1), thumbs: [])
        #expect(!a.sameContent(as: c))
    }

    @Test func staleness() {
        let s = Self.build()
        #expect(!s.isStale(now: Self.at("2026-09-30", 22)))
        #expect(s.isStale(now: Self.at("2026-09-30", 22, 1)))
    }

    @Test func authorLines() {
        #expect(SnapshotBuilder.authorLine([]) == "")
        #expect(SnapshotBuilder.authorLine(["Li Wang"]) == "Wang L")
        #expect(SnapshotBuilder.authorLine(["Li Wang", "Yu Chen"]) == "Wang L & Chen Y")
        #expect(SnapshotBuilder.authorLine(["Madonna"]) == "Madonna")
        #expect(SnapshotBuilder.authorLine(["  ", "Li Wang"]) == "Wang L")
        #expect(SnapshotBuilder.authorLine(["Li Wang", "X Y", "Arnold R. Kriegstein"]) == "Wang L … Kriegstein AR")
    }

    @Test func emptyLibrary() throws {
        let s = SnapshotBuilder.build(papers: [], checklists: [:], categories: [:], settings: Self.settings, lang: .en,
                                      now: Self.at("2026-10-03", 8), calendar: Self.cal)
        #expect(s.backlog == .init(total: 0, unscheduled: 0))
        #expect(s.days.map(\.count) == [0, 0])
        #expect(s.papers.isEmpty && s.recentIds.isEmpty)
        #expect(try WidgetSnapshot.decode(s.encoded()) == s)
    }
}
