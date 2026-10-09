import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct ChecklistOperationsTests {
    private typealias Kit = OpsTestKit

    @Test func toggleFlowReadingDoneAndBack() async throws {
        try await Kit.run { env in
            let ddl = Kit.day(2026, 10, 2)
            let p = try await Kit.addPaper(env, deadline: ddl, checklist: Kit.heuristicChecklist([30, 30]))
            let items = try await Kit.checklist(env, p.id)

            let first = try await env.engine.toggleChecklistItem(paperID: p.id, itemID: items[0].id)
            #expect(first.paper.status == .reading)
            #expect(first.paper.openedAt == Kit.start)
            #expect(!first.becameDone)
            #expect(first.paper.deadline == ddl)

            env.advance(600)
            let second = try await env.engine.toggleChecklistItem(paperID: p.id, itemID: items[1].id)
            #expect(second.paper.status == .done)
            #expect(second.becameDone)
            #expect(second.paper.doneAt == Kit.start.addingTimeInterval(600))
            #expect(second.paper.openedAt == Kit.start)              // first tick only
            #expect(second.paper.deadline == ddl && second.paper.deadlineOrigin == .place)

            let untick = try await env.engine.toggleChecklistItem(paperID: p.id, itemID: items[1].id)
            #expect(untick.paper.status == .reading)
            #expect(untick.paper.doneAt == nil)
            #expect(!untick.becameDone)
            let now = try await Kit.checklist(env, p.id)
            #expect(now[0].doneAt == Kit.start && now[1].doneAt == nil)

            // card.json follows the DB.
            await env.engine.ctx.sidecars.flush()
            let card = try CardSidecar.decoded(from: Data(contentsOf: env.engine.ctx.folderURL(untick.paper)
                .appendingPathComponent(CardSidecar.fileName)))
            #expect(card.reading.status == .reading)
            #expect(card.checklist.map { $0.doneAt != nil } == [true, false])
        }
    }

    @Test func autoDoneOffKeepsReading() async throws {
        try await Kit.run(Kit.settings(autoDone: false)) { env in
            let p = try await Kit.addPaper(env, checklist: Kit.heuristicChecklist([10]))
            let item = try await Kit.checklist(env, p.id)[0]
            let r = try await env.engine.toggleChecklistItem(paperID: p.id, itemID: item.id)
            #expect(r.paper.status == .reading && !r.becameDone)
            await #expect(throws: PaperOperationError.checklistItemNotFound("nope")) {
                try await env.engine.toggleChecklistItem(paperID: p.id, itemID: "nope")
            }
        }
    }

    @Test func addEditMoveDelete() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env)                      // 4 heuristic items, ord 0…3

            let added = try await env.engine.addChecklistItem(paperID: p.id, text: "  Fig. 4:\n compare  panels ",
                                                              section: "Fig. 4", minutes: 15)
            #expect(added.origin == .user && added.text == "Fig. 4: compare panels" && added.ord == 4 && added.minutes == 15)
            var items = try await Kit.checklist(env, p.id)
            #expect(items.last?.id == added.id && items.count == 5)

            let edited = try await env.engine.editChecklistItem(paperID: p.id, itemID: items[1].id, text: "Intro: main claim",
                                                                section: "Introduction", minutes: 12)
            #expect(edited.userEdited && edited.text == "Intro: main claim" && edited.minutes == 12 && edited.page == nil)
            #expect(edited.origin == .heuristic)

            let moved = try await env.engine.moveChecklistItem(paperID: p.id, itemID: items[0].id, toIndex: 2)
            #expect(moved.map(\.id) == [items[1].id, items[2].id, items[0].id, items[3].id, added.id])
            #expect(moved.map(\.ord) == [0, 1, 2, 3, 4])
            try #require(moved.count > 2)          // no index past a failed expectation (QA-15)
            #expect(moved[2].userEdited)
            items = try await Kit.checklist(env, p.id)
            #expect(items.map(\.id) == moved.map(\.id))

            try await env.engine.deleteChecklistItem(paperID: p.id, itemID: added.id)
            #expect(try await Kit.checklist(env, p.id).count == 4)

            await #expect(throws: PaperOperationError.emptyText) {
                try await env.engine.addChecklistItem(paperID: p.id, text: "   ")
            }
            await #expect(throws: PaperOperationError.checklistItemNotFound(added.id)) {
                try await env.engine.deleteChecklistItem(paperID: p.id, itemID: added.id)
            }
            await #expect(throws: PaperOperationError.paperNotFound("00000000-0000-0000-0000-000000000000")) {
                try await env.engine.addChecklistItem(paperID: "00000000-0000-0000-0000-000000000000", text: "x")
            }
        }
    }

    @Test func setEstimateRescalesUntouchedHeuristicChecklist() async throws {
        try await Kit.run { env in
            let ddl = Kit.day(2026, 10, 1)
            let p = try await Kit.addPaper(env, deadline: ddl, est: 60)          // [5, 30, 20, 5]

            let saved = try await env.engine.setEstimate(paperID: p.id, minutes: 90)
            #expect(saved.estMinutes == 90 && saved.estSource == .user)
            #expect(saved.deadline == ddl && saved.deadlineOrigin == .place)    // DDL never moves
            let scaled = try await Kit.checklist(env, p.id)
            #expect(scaled.map(\.minutes) == [10, 45, 30, 5])
            #expect(scaled.reduce(0) { $0 + $1.minutes } == 90)

            // Not a multiple of 5 → whole minutes, still Σ == est.
            _ = try await env.engine.setEstimate(paperID: p.id, minutes: 47)
            let odd = try await Kit.checklist(env, p.id)
            #expect(odd.reduce(0) { $0 + $1.minutes } == 47)
            #expect(odd.allSatisfy { $0.minutes >= 1 })
        }
    }

    @Test func setEstimateLeavesTouchedChecklistAlone() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env, est: 60)
            let items = try await Kit.checklist(env, p.id)
            _ = try await env.engine.toggleChecklistItem(paperID: p.id, itemID: items[0].id)
            _ = try await env.engine.setEstimate(paperID: p.id, minutes: 120)
            #expect(try await Kit.checklist(env, p.id).map(\.minutes) == [5, 30, 20, 5])
            #expect(try await Kit.paper(env, p.id).estMinutes == 120)
        }
    }
}
