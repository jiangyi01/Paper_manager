import Foundation
import Testing
@testable import PaperDeckCore

/// Status/priority operations and the §6.3 DDL table (B = 60, Mon–Fri, now = Tue 2026-09-29 10:00).
@Suite struct ScheduleOperationsTests {
    private typealias Kit = OpsTestKit
    private static func d(_ m: Int, _ day: Int) -> LocalDate { OpsTestKit.day(2026, m, day) }

    @Test func statusDoneStampsAndClears() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, deadline: Self.d(10, 1))
            let done = try await env.engine.setStatus(paperID: p.id, .done)
            #expect(done.status == .done && done.doneAt == Kit.start)
            #expect(done.deadline == Self.d(10, 1))
            let back = try await env.engine.setStatus(paperID: p.id, .reading)
            #expect(back.status == .reading && back.doneAt == nil)

            // ⌘D: a paper never started goes back to to_read; an opened one to reading.
            let q = try await Kit.addPaper(env)
            #expect(try await env.engine.toggleDone(paperID: q.id).status == .done)
            #expect(try await env.engine.toggleDone(paperID: q.id).status == .toRead)
            env.advance(60)
            let opened = try await env.engine.markOpened(paperID: q.id)
            #expect(opened.status == .reading && opened.openedAt == Kit.start.addingTimeInterval(60))
            env.advance(60)
            #expect(try await env.engine.markOpened(paperID: q.id).openedAt == Kit.start.addingTimeInterval(60))
            #expect(try await env.engine.toggleDone(paperID: q.id).doneAt == Kit.start.addingTimeInterval(120))
            #expect(try await env.engine.toggleDone(paperID: q.id).status == .reading)
        }
    }

    @Test func priorityChangeKeepsDDLAndReplanPlacesAgain() async throws {
        try await Kit.run { env in
            _ = try await Kit.addPaper(env, title: "A", deadline: Self.d(9, 29))
            let b = try await Kit.addPaper(env, title: "B", deadline: Self.d(10, 1), priority: .low)
            let high = try await env.engine.setPriority(paperID: b.id, .high)
            #expect(high.priority == .high)
            #expect(high.deadline == Self.d(10, 1) && high.deadlineOrigin == .place)   // never moves by itself

            let replanned = try await env.engine.replan(paperID: b.id)
            // High competes only with high ∪ pinned → today is feasible.
            #expect(replanned.deadline == Self.d(9, 29))
            #expect(replanned.scheduleMode == .auto && replanned.deadlineOrigin == .place)
            #expect(replanned.placementFloor == Self.d(9, 29))
        }
    }

    @Test func deadlineOperationsFollowTheTable() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, deadline: Self.d(10, 2))

            let later = try await env.engine.postponeDay(paperID: p.id)             // Fri → Mon
            #expect(later.deadline == Self.d(10, 5) && later.scheduleMode == .auto && later.deadlineOrigin == .user)

            let pinned = try await env.engine.pinDeadline(paperID: p.id, date: Self.d(9, 30))
            #expect(pinned.deadline == Self.d(9, 30) && pinned.scheduleMode == .pinned && pinned.deadlineOrigin == .user)

            let week = try await env.engine.postponeWeek(paperID: p.id)             // 9/30 + 7 = Wed 10/7
            #expect(week.deadline == Self.d(10, 7) && week.scheduleMode == .pinned && week.deadlineOrigin == .user)

            let none = try await env.engine.unschedule(paperID: p.id)
            #expect(none.deadline == nil && none.scheduleMode == .none && none.deadlineOrigin == .user)
            #expect(try await env.engine.postponeDay(paperID: p.id).deadline == nil)   // unscheduled: no-op

            let auto = try await env.engine.restoreAutoDeadline(paperID: p.id)
            #expect(auto.deadline == Self.d(9, 29) && auto.scheduleMode == .auto && auto.deadlineOrigin == .place)
            #expect(auto.placementFloor == Self.d(9, 29))

            await env.engine.ctx.sidecars.flush()
            let card = try CardSidecar.decoded(from: Data(contentsOf: env.engine.ctx.folderURL(auto)
                .appendingPathComponent(CardSidecar.fileName)))
            #expect(card.reading.deadline == Self.d(9, 29) && card.reading.deadlineOrigin == .place)
        }
    }

    @Test func shiftAtRiskMovesOnlyAutoPapers() async throws {
        try await Kit.run { env in
            let a = try await Kit.addPaper(env, title: "A", deadline: Self.d(9, 29))
            let b = try await Kit.addPaper(env, title: "B", deadline: Self.d(9, 29))
            let c = try await Kit.addPaper(env, title: "C", deadline: Self.d(9, 29), mode: .pinned, origin: .user)
            let moved = try await env.engine.shiftAtRisk()
            #expect(moved == [b.id])
            #expect(try await Kit.paper(env, a.id).deadline == Self.d(9, 29))
            let shifted = try await Kit.paper(env, b.id)
            #expect(shifted.deadline == Self.d(9, 30) && shifted.deadlineOrigin == .user)
            #expect(try await Kit.paper(env, c.id).deadline == Self.d(9, 29))    // pinned: flagged, not moved
            #expect(try await env.engine.librarySnapshot().row(id: c.id)?.atRisk == true)
        }
    }

    @Test func skipTodayMovesAutoPapersAndUndoRestores() async throws {
        try await Kit.run { env in
            let a = try await Kit.addPaper(env, title: "A", deadline: Self.d(9, 29))
            let b = try await Kit.addPaper(env, title: "B", deadline: Self.d(10, 1))
            let c = try await Kit.addPaper(env, title: "C", deadline: Self.d(9, 30), mode: .pinned, origin: .user)
            let overdue = try await Kit.addPaper(env, title: "D", deadline: Self.d(9, 28))
            let done = try await Kit.addPaper(env, title: "E", deadline: Self.d(10, 1), status: .done)

            let token = try await env.engine.skipToday()
            #expect(token.day == Self.d(9, 29))
            #expect(Set(token.movedPaperIDs) == [a.id, b.id])
            #expect(token.message == "今天已跳过 · 2 篇顺延一天")
            #expect(token.toast.buttons.first?.action == .undo(token: token.id))
            #expect(token.expiresAt == Kit.start.addingTimeInterval(30))
            #expect(await env.engine.ctx.skipDays() == [Self.d(9, 29)])
            let movedA = try await Kit.paper(env, a.id)
            #expect(movedA.deadline == Self.d(9, 30) && movedA.deadlineOrigin == .user)
            #expect(try await Kit.paper(env, b.id).deadline == Self.d(10, 2))
            #expect(try await Kit.paper(env, c.id).deadline == Self.d(9, 30))
            #expect(try await Kit.paper(env, overdue.id).deadline == Self.d(9, 28))
            #expect(try await Kit.paper(env, done.id).deadline == Self.d(10, 1))

            await env.engine.ctx.sidecars.flush()
            #expect(try SidecarWriter.readManifest(at: env.paths.libraryManifest)?.skipDays == [Self.d(9, 29)])

            env.advance(20)
            #expect(try await env.engine.undo(token: token))
            let restoredA = try await Kit.paper(env, a.id)
            #expect(restoredA.deadline == Self.d(9, 29) && restoredA.deadlineOrigin == .place)
            #expect(try await Kit.paper(env, b.id).deadline == Self.d(10, 1))
            #expect(await env.engine.ctx.skipDays().isEmpty)
            #expect(try await !env.engine.undo(token: token))                  // single use
        }
    }

    @Test func skipTodayUndoExpiresAfterThirtySeconds() async throws {
        try await Kit.run(Kit.settings(lang: .en)) { env in
            let a = try await Kit.addPaper(env, deadline: Self.d(9, 29))
            let token = try await env.engine.skipToday()
            #expect(token.message == "Skipped today · 1 paper moved to the next reading day")
            #expect(token.undoTitle == "Undo")
            env.advance(31)
            #expect(try await !env.engine.undo(token: token.id))
            #expect(try await Kit.paper(env, a.id).deadline == Self.d(9, 30))
            #expect(await env.engine.ctx.skipDays() == [Self.d(9, 29)])
        }
    }

    @Test func undoLeavesPapersChangedMeanwhileAndIsPerEngine() async throws {
        try await Kit.run { env in
            try await Kit.run { other in
                let a = try await Kit.addPaper(env, title: "A", deadline: Self.d(9, 29))
                let b = try await Kit.addPaper(env, title: "B", deadline: Self.d(10, 1))
                let token = try await env.engine.skipToday()
                _ = try await env.engine.pinDeadline(paperID: b.id, date: Self.d(10, 9))
                #expect(try await !other.engine.undo(token: token.id))        // another engine's token
                #expect(try await env.engine.undo(token: token.id))
                #expect(try await Kit.paper(env, a.id).deadline == Self.d(9, 29))
                let pinned = try await Kit.paper(env, b.id)
                #expect(pinned.deadline == Self.d(10, 9) && pinned.scheduleMode == .pinned)
            }
        }
    }

    @Test func deletedPapersAreRefused() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, deadline: Self.d(10, 1))
            _ = try await env.engine.softDelete(paperID: p.id)
            await #expect(throws: PaperOperationError.paperDeleted(p.id)) {
                try await env.engine.postponeDay(paperID: p.id)
            }
            await #expect(throws: PaperOperationError.paperDeleted(p.id)) {
                try await env.engine.setPriority(paperID: p.id, .high)
            }
            #expect(PaperOperationError.paperDeleted(p.id).message(.en).contains("Recently Deleted"))
        }
    }
}
