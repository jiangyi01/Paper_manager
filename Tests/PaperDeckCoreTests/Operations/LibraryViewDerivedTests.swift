import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct LibraryViewDerivedTests {
    private typealias Kit = OpsTestKit
    private typealias PDTag = PaperDeckCore.Tag
    private static func d(_ m: Int, _ day: Int) -> LocalDate { OpsTestKit.day(2026, m, day) }

    private struct Library {
        var a: Paper, b: Paper, c: Paper, done: Paper, gone: Paper
        var custom: PaperCategory, fresh: PaperCategory
    }

    /// A and B due today (B can't finish in time), C unscheduled, one done, one deleted.
    private static func build(_ env: OpsTestKit.Env) async throws -> Library {
        let a = try await Kit.addPaper(env, title: "Alpha neocortex atlas", deadline: d(9, 29))
        let b = try await Kit.addPaper(env, title: "Beta", deadline: d(9, 29))
        let c = try await Kit.addPaper(env, title: "Gamma", mode: .none)
        let done = try await Kit.addPaper(env, title: "Delta", deadline: d(9, 30), status: .done)
        let gone = try await Kit.addPaper(env, title: "Epsilon", deadline: d(10, 1))
        _ = try await env.engine.softDelete(paperID: gone.id)
        let custom = try await env.engine.createCategory(name: "Custom Topic")
        let fresh = try await env.db.insertCategory(PaperCategory(name: "Agent Topic", hue: 9, origin: .agent, acknowledged: false))
        _ = try await env.engine.setCategory(paperID: a.id, categoryPK: custom.pk)
        _ = try await env.engine.setCategory(paperID: b.id, categoryPK: custom.pk)
        _ = try await env.engine.setCategory(paperID: c.id, categoryPK: fresh.pk)
        try await env.db.setTags(paperPK: a.pk, [PDTag(name: "atlas", origin: .agent), PDTag(name: "noise", origin: .suppressed)])
        try env.engine.ctx.thumbs.save(cardJPEG: Kit.jpeg(), id: a.id)
        return Library(a: a, b: b, c: c, done: done, gone: gone, custom: custom, fresh: fresh)
    }

    @Test func snapshotRowsTodayAndChips() async throws {
        try await Kit.run { env in
            let lib = try await Self.build(env)
            let items = try await Kit.checklist(env, lib.a.id)
            _ = try await env.engine.toggleChecklistItem(paperID: lib.a.id, itemID: items[0].id)

            let snap = try await env.engine.librarySnapshot()
            #expect(snap.rows.map(\.id) == [lib.a.id, lib.b.id, lib.c.id, lib.done.id])
            #expect(snap.deleted.map(\.id) == [lib.gone.id])
            #expect(snap.totals.count == 4)
            #expect(snap.totals.logicalBytes == [lib.a, lib.b, lib.c, lib.done].reduce(0) { $0 + $1.fileSize })
            #expect(snap.generatedAt == Kit.start)

            let a = try #require(snap.row(id: lib.a.id))
            #expect(a.checklist.map(\.ord) == [0, 1, 2, 3])
            #expect(a.tags == [PDTag(name: "atlas", origin: .agent)])
            #expect(a.category?.name == "Custom Topic")
            #expect(a.doneCount == 1 && a.totalCount == 4 && a.remainingMinutes == 55)
            #expect(a.minutesToday == 55 && !a.atRisk && a.finish == Self.d(9, 29))
            // The card thumbnail's file, versioned (ui-runtime-2: `ThumbnailStore.versioned`).
            #expect(a.thumbnailURL.map(ThumbnailStore.unversioned) == env.engine.ctx.thumbs.cardURL(for: lib.a.id))
            #expect(a.thumbnailURL?.fragment?.hasPrefix("v=") == true)
            #expect(FileManager.default.fileExists(atPath: a.pdfURL.path))
            #expect(a.paper.status == .reading)

            let b = try #require(snap.row(id: lib.b.id))
            #expect(b.atRisk && b.finish == Self.d(9, 30) && b.minutesToday == 60 && b.thumbnailURL == nil)
            let c = try #require(snap.row(id: lib.c.id))
            #expect(c.minutesToday == nil && !c.atRisk && c.category?.name == "Agent Topic")

            #expect(snap.today.dueToday == [lib.a.id, lib.b.id])
            #expect(snap.today.backlogTotal == 3 && snap.today.unscheduled == 1)
            #expect(snap.today.todayMinutes == 115)
            #expect(snap.todayRows.map(\.id) == [lib.a.id, lib.b.id])
            #expect(snap.row(id: lib.gone.id.uppercased())?.paper.isDeleted == true)
            #expect(snap.needsAttention.isEmpty)
            _ = try await env.db.modifyPaper(pk: lib.c.pk) { $0.aiState = .failed }
            #expect(try await env.engine.librarySnapshot().needsAttention.map(\.id) == [lib.c.id])

            let custom = try #require(snap.categories.first { $0.id == lib.custom.pk })
            #expect(custom.paperCount == 2 && !custom.isNew)
            let fresh = try #require(snap.categories.first { $0.id == lib.fresh.pk })
            #expect(fresh.paperCount == 1 && fresh.isNew)
            #expect(snap.categories.count == 9)                              // 7 starters + 2

            #expect(try await env.engine.search("neocortex") == [lib.a.id])
            #expect(try await env.engine.search("epsilon").isEmpty)         // deleted papers never match
        }
    }

    @Test func reminderPlanHas14DaysEndingWithTheBacklogLine() async throws {
        try await Kit.run { env in
            _ = try await Self.build(env)
            let plan = try await env.engine.reminderPlan(from: Kit.start)
            #expect(plan.count == 14)
            #expect(plan.first?.id == "daily-2026-09-29" && plan.last?.id == "daily-2026-10-12")
            let backlog = SharedStrings.backlogLine(total: 3, unscheduled: 1, .zh)
            #expect(plan.allSatisfy { $0.body.split(separator: "\n").last.map(String.init) == backlog })
            #expect(plan.allSatisfy { $0.hour == 11 && $0.minute == 0 })

            let afterEleven = Self.d(9, 29).date(hour: 11, minute: 30, calendar: Kit.calendar)
            #expect(try await env.engine.reminderPlan(from: afterEleven).first?.id == "daily-2026-09-30")

            let today = try #require(try await env.engine.composeReminder(day: Self.d(9, 29)))
            try #require(plan.count > 0)          // no index past a failed expectation (QA-15)
            #expect(today == plan[0])
            let inAnHour = try await env.engine.composeReminder(day: Self.d(9, 29), now: Kit.start.addingTimeInterval(3600))
            #expect(inAnHour?.body.hasSuffix(backlog) == true)

            var off = env.settings.value
            off.reminderEnabled = false
            env.settings.value = off
            #expect(try await env.engine.reminderPlan(from: Kit.start).isEmpty)
        }
    }

    @Test func widgetSnapshotWritesOnlyWhenContentChanges() async throws {
        try await Kit.run { env in
            let lib = try await Self.build(env)
            try FileManager.default.removeItem(at: env.engine.ctx.thumbs.widgetURL(for: lib.a.id))

            #expect(try await env.engine.writeWidgetSnapshot())
            let url = env.engine.widgetSnapshotURL
            #expect(url == env.paths.widget.appendingPathComponent("snapshot.json"))
            let written = try WidgetSnapshot.decode(Data(contentsOf: url))
            #expect(written.days.first?.ids == [lib.a.id, lib.b.id])
            #expect(written.backlog == WidgetSnapshot.Backlog(total: 3, unscheduled: 1))
            #expect(written.papers[lib.a.id]?.thumb == "thumbs/\(lib.a.id).jpg")      // regenerated
            #expect(env.engine.ctx.thumbs.existingWidgetURL(for: lib.a.id) != nil)
            #expect(written.papers[lib.a.id]?.category == "Custom Topic")
            #expect(written == (try await env.engine.widgetSnapshot()))

            env.advance(60)
            #expect(try await !env.engine.writeWidgetSnapshot())                          // only generatedAt differs

            let item = try await Kit.checklist(env, lib.b.id)[0]
            _ = try await env.engine.toggleChecklistItem(paperID: lib.b.id, itemID: item.id)
            #expect(try await env.engine.writeWidgetSnapshot())
            #expect(try WidgetSnapshot.decode(Data(contentsOf: url)).papers[lib.b.id]?.done == 1)
        }
    }
}
