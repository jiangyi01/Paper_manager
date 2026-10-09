import Foundation
import Testing
@testable import PaperDeckCore

/// Finding 1: schedule operations were read-modify-write across awaits (planInputs snapshot →
/// Scheduler → applySchedule), so a concurrent edit could be reverted or a pin lost.
@Suite(.serialized) struct RegressionScheduleRaceTests {
    private typealias Kit = OpsTestKit

    /// Ported: applySchedule wrote priority/provisional from a stale SchedItem snapshot.
    @Test func applyScheduleRevertsConcurrentPriorityChange() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, title: "Stale", deadline: Kit.day(2026, 9, 30))
            let inputs = try await env.engine.ctx.planInputs()           // e.g. skipToday / shiftAtRisk snapshot
            _ = try await env.engine.setPriority(paperID: p.id, .high)    // user edit lands meanwhile
            var moved = try #require(inputs.item(id: p.id))
            moved.deadline = Kit.day(2026, 10, 1)
            try await env.engine.ctx.applySchedule([moved])
            let after = try await Kit.paper(env, p.id)
            #expect(after.priority == .high, "priority reverted to \(after.priority) by a stale applySchedule")
            #expect(after.deadline == Kit.day(2026, 10, 1))
        }
    }

    /// A stale snapshot must not flip `provisional` back on after the agent cleared it.
    @Test func staleApplyScheduleDoesNotRestoreProvisional() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, title: "Provisional", deadline: Kit.day(2026, 9, 30), provisional: true)
            let inputs = try await env.engine.ctx.planInputs()
            _ = try await env.db.modifyPaper(pk: p.pk, now: env.clock.value) { $0.provisional = false }   // card applied
            var moved = try #require(inputs.item(id: p.id))
            #expect(moved.provisional)
            moved.deadline = Kit.day(2026, 10, 2)
            try await env.engine.ctx.applySchedule([moved])
            let after = try await Kit.paper(env, p.id)
            #expect(!after.provisional, "a stale applySchedule turned provisional back on")
            #expect(after.deadline == Kit.day(2026, 10, 2))
        }
    }

    /// Ported: 今天跳过 racing 设定日期… — in either serial order the paper ends pinned.
    @Test func skipTodayRacingPinLosesThePin() async throws {
        try await Kit.run(Kit.settings(weekdays: Set(1...7))) { env in
            var lost = 0
            for round in 0..<60 {
                env.advance(86_400)
                let today = LocalDate(env.clock.value, calendar: Kit.calendar)
                let p = try await Kit.addPaper(env, title: "Pin race \(round)", deadline: today)
                let target = today.adding(days: 20, calendar: Kit.calendar)
                let delay = UInt64(round % 12) * 100_000
                async let skip = try? env.engine.skipToday()
                async let pin = { try? await Task.sleep(nanoseconds: delay); return try? await env.engine.pinDeadline(paperID: p.id, date: target) }()
                _ = await skip; _ = await pin
                let row = try await Kit.paper(env, p.id)
                if row.scheduleMode != .pinned || row.deadline != target { lost += 1 }
            }
            #expect(lost == 0, "\(lost)/60 user pins were overwritten by a concurrent 今天跳过")
        }
    }

    /// 今天跳过 racing a priority change: the priority always survives, the paper still moves.
    @Test func skipTodayRacingSetPriorityKeepsThePriority() async throws {
        try await Kit.run(Kit.settings(weekdays: Set(1...7))) { env in
            var reverted = 0
            for round in 0..<40 {
                env.advance(86_400)
                let today = LocalDate(env.clock.value, calendar: Kit.calendar)
                let p = try await Kit.addPaper(env, title: "Prio race \(round)", deadline: today)
                let delay = UInt64(round % 10) * 100_000
                async let skip = try? env.engine.skipToday()
                async let prio = { try? await Task.sleep(nanoseconds: delay); return try? await env.engine.setPriority(paperID: p.id, .high) }()
                _ = await skip; _ = await prio
                let row = try await Kit.paper(env, p.id)
                if row.priority != .high { reverted += 1 }
                #expect(row.deadline == today.adding(days: 1, calendar: Kit.calendar))
            }
            #expect(reverted == 0, "\(reverted)/40 priority changes were reverted by a concurrent 今天跳过")
        }
    }

    /// shiftAtRisk racing a pin: the user's pin wins in either order.
    @Test func shiftAtRiskRacingPinKeepsThePin() async throws {
        try await Kit.run { env in
            var lost = 0
            for round in 0..<30 {
                // Two 60′ papers due today with a 60′ budget: the second one is at risk.
                let a = try await Kit.addPaper(env, title: "Risk A \(round)", deadline: Kit.day(2026, 9, 29))
                let b = try await Kit.addPaper(env, title: "Risk B \(round)", deadline: Kit.day(2026, 9, 29))
                let target = Kit.day(2026, 12, 1)
                let delay = UInt64(round % 10) * 100_000
                async let shift = try? env.engine.shiftAtRisk()
                async let pin = { try? await Task.sleep(nanoseconds: delay); return try? await env.engine.pinDeadline(paperID: b.id, date: target) }()
                _ = await shift; _ = await pin
                let row = try await Kit.paper(env, b.id)
                if row.scheduleMode != .pinned || row.deadline != target { lost += 1 }
                _ = try await env.engine.softDelete(paperID: a.id)
                _ = try await env.engine.softDelete(paperID: b.id)
            }
            #expect(lost == 0, "\(lost)/30 pins were overwritten by a concurrent 顺延")
        }
    }

    /// Undo after 今天跳过 restores the skip days and the moved paper; a paper the user pinned
    /// meanwhile is left alone.
    @Test func undoRestoresSkipDaysAndLeavesLaterEditsAlone() async throws {
        try await Kit.run(Kit.settings(weekdays: Set(1...7))) { env in
            let today = LocalDate(env.clock.value, calendar: Kit.calendar)
            let a = try await Kit.addPaper(env, title: "Moved", deadline: today)
            let b = try await Kit.addPaper(env, title: "Pinned later", deadline: today)
            let token = try await env.engine.skipToday()
            #expect(Set(token.movedPaperIDs) == [a.id, b.id])
            #expect(await env.engine.ctx.skipDays().contains(today))
            _ = try await env.engine.pinDeadline(paperID: b.id, date: today.adding(days: 9, calendar: Kit.calendar))
            #expect(try await env.engine.undo(token: token))
            #expect(await env.engine.ctx.skipDays().contains(today) == false)
            let ra = try await Kit.paper(env, a.id), rb = try await Kit.paper(env, b.id)
            #expect(ra.deadline == today && ra.deadlineOrigin == .place)
            #expect(rb.scheduleMode == .pinned && rb.deadline == today.adding(days: 9, calendar: Kit.calendar))
        }
    }

    /// CardApplier's one-time re-place reads the skip days inside its transaction: a 今天跳过
    /// that landed after the caller took its settings snapshot is respected.
    @Test func cardApplierRePlaceUsesFreshSkipDays() async throws {
        try await Kit.run(Kit.settings(weekdays: Set(1...7))) { env in
            let today = LocalDate(env.clock.value, calendar: Kit.calendar)
            let p = try await Kit.addPaper(env, title: "Provisional replace", deadline: today, est: 20,
                                          checklist: [], provisional: true, addedAt: env.clock.value.addingTimeInterval(-600))
            _ = try await env.db.modifyPaper(pk: p.pk, now: env.clock.value) {
                $0.estSource = .heuristic; $0.placementFloor = today
            }
            let stale = await env.engine.ctx.settings()                  // snapshot without today's skip
            try await env.engine.ctx.setSkipDays([today])                // 今天跳过 lands meanwhile
            var raw = try #require(MockAgentProvider.card(for: CardRequest(
                schema: CardSchema.schema(categories: PaperCategory.starters.map(\.name)),
                stdin: CardSchema.stdin(metadata: nil, pageCount: 12, categories: [], frequentTags: [],
                                        paperText: "[[p. 1]]\nA paper")
            )).objectValue)
            raw["estimated_minutes"] = .number(50)                       // |50 − 20| ≥ 15 → re-place
            let card = try CardSanitizer.sanitize(.object(raw), pageCount: 12)
            let result = try await CardApplier.apply(card, to: p.pk, ctx: env.engine.ctx, settings: stale)
            #expect(result.paper.deadline != today, "re-placed onto a day the user just skipped")
            #expect(result.paper.deadline == today.adding(days: 1, calendar: Kit.calendar))
            #expect(!result.paper.provisional)
        }
    }
}
