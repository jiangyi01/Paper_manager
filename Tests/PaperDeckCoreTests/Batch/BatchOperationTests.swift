import Foundation
import Testing
@testable import PaperDeckCore

/// `Engine.applyBatch` (READING_ASSIST_PLAN §9.1 C "BatchOperation": one transaction, undo restores,
/// user changes respected on undo) plus the batch re-read. Temp libraries, agent mode off or mock.
@Suite struct BatchOperationTests {
    private typealias Kit = OpsTestKit
    static func d(_ m: Int, _ day: Int) -> LocalDate { LocalDate(year: 2026, month: m, day: day) }

    /// Collects a stream in the background (events are buffered at `send`, so a short settle suffices).
    final class Sink<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        private var task: Task<Void, Never>?
        init(_ stream: AsyncStream<T>) {
            task = Task { [weak self] in for await x in stream { self?.append(x) } }
        }
        private func append(_ x: T) { lock.withLock { items.append(x) } }
        func settle() async -> [T] {
            try? await Task.sleep(for: .milliseconds(200))
            return lock.withLock { items }
        }
        deinit { task?.cancel() }
    }

    static func notices(_ events: [EngineEvent]) -> [BatchNotice] {
        events.compactMap { if case .batchApplied(let n) = $0 { return n }; return nil }
    }

    // MARK: Fields

    @Test func statusChangesEveryPaperOnceAndUndoRestoresOnlyUntouchedOnes() async throws {
        try await Kit.run { env in
            let a = try await Kit.addPaper(env, title: "A")
            let b = try await Kit.addPaper(env, title: "B", status: .reading)
            let c = try await Kit.addPaper(env, title: "C")
            let events = Sink(env.engine.events.subscribe())
            env.advance(5)
            let out = try await env.engine.applyBatch(.setStatus(.done), paperIDs: [a.id, b.id, c.id, "missing", a.id.uppercased()])
            #expect(out.applied == [a.id, b.id, c.id] && out.skipped == ["missing"])
            let token = try #require(out.undoToken)
            for id in [a.id, b.id, c.id] {
                let p = try await Kit.paper(env, id)
                #expect(p.status == .done && p.doneAt == Kit.start.addingTimeInterval(5))
            }
            let notices = Self.notices(await events.settle())
            #expect(notices == [BatchNotice(operation: "setStatus.done", paperIDs: [a.id, b.id, c.id], undoToken: token)])
            // The user changes B meanwhile: undo leaves it.
            _ = try await env.engine.setStatus(paperID: b.id, .toRead)
            env.advance(10)
            #expect(try await env.engine.undoBatch(token: token))
            let undoneA = try await Kit.paper(env, a.id)
            #expect(undoneA.status == .toRead && undoneA.doneAt == nil)
            #expect(try await Kit.paper(env, b.id).status == .toRead)          // the user's choice
            #expect(try await Kit.paper(env, c.id).status == .toRead)
            #expect(try await !env.engine.undoBatch(token: token))             // single use
        }
    }

    @Test func aBatchIsOneTransaction() async throws {
        try await Kit.run { env in
            var ids: [String] = []
            for i in 0..<40 { ids.append(try await Kit.addPaper(env, title: "P\(i)").id) }
            let changes = Sink(env.engine.changes.subscribe())
            let out = try await env.engine.applyBatch(.setPriority(.high), paperIDs: ids)
            #expect(out.applied.count == 40 && out.undoToken != nil)
            // One COMMIT: ChangeHub collapses the burst into one `.papersBulk` (separate writes
            // would send 40 `.paper` changes).
            let seen = await changes.settle()
            #expect(seen == [.papersBulk], "\(seen)")
            #expect(try await env.db.livePapers().allSatisfy { $0.priority == .high })
        }
    }

    @Test func anInvalidBatchChangesNothing() async throws {
        try await Kit.run { env in
            let a = try await Kit.addPaper(env, title: "A")
            let events = Sink(env.engine.events.subscribe())
            await #expect(throws: PaperOperationError.categoryNotFound(999)) {
                _ = try await env.engine.applyBatch(.setCategory(999), paperIDs: [a.id])
            }
            await #expect(throws: PaperOperationError.invalidTag("!")) {
                _ = try await env.engine.applyBatch(.addTags(["ok-tag", "!"]), paperIDs: [a.id])
            }
            #expect(try await env.db.tags(paperPK: a.pk).isEmpty)
            #expect(Self.notices(await events.settle()).isEmpty)
            // Nothing to change: applied, but no undo token.
            let same = try await env.engine.applyBatch(.setPriority(.normal), paperIDs: [a.id])
            #expect(same.applied == [a.id] && same.undoToken == nil)
            // Unknown papers only: no notice (the Slice 0 contract).
            #expect(try await env.engine.applyBatch(.setPriority(.high), paperIDs: ["x", "y"]) == BatchOutcome(skipped: ["x", "y"]))
        }
    }

    @Test func categoryIsTheUsersChoiceAndUndoGivesTheOldOneBack() async throws {
        try await Kit.run { env in
            let cat = try await env.engine.createCategory(name: "Neuro")
            let a = try await Kit.addPaper(env, title: "A")
            _ = try await env.db.modifyPaper(pk: a.pk) { $0.needsReview = true }
            let b = try await Kit.addPaper(env, title: "B")
            let token = try #require(try await env.engine.applyBatch(.setCategory(cat.pk), paperIDs: [a.id, b.id]).undoToken)
            for id in [a.id, b.id] {
                let p = try await Kit.paper(env, id)
                #expect(p.categoryPK == cat.pk && p.categoryUserSet && !p.needsReview)
            }
            #expect(try await env.engine.undoBatch(token: token))
            let back = try await Kit.paper(env, a.id)
            #expect(back.categoryPK == nil && !back.categoryUserSet && back.needsReview)
        }
    }

    @Test func tagsFollowTheSinglePaperRulesAndUndo() async throws {
        try await Kit.run { env in
            let a = try await Kit.addPaper(env, title: "A")
            let b = try await Kit.addPaper(env, title: "B")
            let c = try await Kit.addPaper(env, title: "C")
            try await env.db.setTags(paperPK: a.pk, [Tag(name: "single-cell", origin: .agent)])
            try await env.db.setTags(paperPK: c.pk, [Tag(name: "keep", origin: .user)])
            let add = try await env.engine.applyBatch(.addTags(["Single Cell"]), paperIDs: [a.id, b.id, c.id])
            #expect(try await env.db.tags(paperPK: a.pk) == [Tag(name: "single-cell", origin: .user)])   // the agent's became the user's
            #expect(try await env.db.tags(paperPK: b.pk) == [Tag(name: "single-cell", origin: .user)])
            #expect(Set(try await env.db.tags(paperPK: c.pk).map(\.name)) == ["keep", "single-cell"])
            // The user changes C's tags meanwhile: undo leaves C as the user left it.
            _ = try await env.engine.removeTag(paperID: c.id, "single-cell")
            _ = try await env.engine.addTag(paperID: c.id, "extra")
            #expect(try await env.engine.undoBatch(token: try #require(add.undoToken)))
            #expect(try await env.db.tags(paperPK: a.pk) == [Tag(name: "single-cell", origin: .agent)])
            #expect(try await env.db.tags(paperPK: b.pk).isEmpty)
            #expect(Set(try await env.db.tags(paperPK: c.pk).map(\.name)) == ["keep", "extra"])

            // Remove: an agent tag is kept as suppressed (a re-read won't bring it back), a user tag goes.
            try await env.db.setTags(paperPK: b.pk, [Tag(name: "single-cell", origin: .user)])
            let remove = try await env.engine.applyBatch(.removeTags(["single-cell"]), paperIDs: [a.id, b.id, c.id])
            #expect(try await env.db.tags(paperPK: a.pk) == [Tag(name: "single-cell", origin: .suppressed)])
            #expect(try await env.db.tags(paperPK: b.pk).isEmpty)
            #expect(remove.applied.count == 3)
            #expect(try await env.engine.undoBatch(token: try #require(remove.undoToken)))
            #expect(try await env.db.tags(paperPK: a.pk) == [Tag(name: "single-cell", origin: .agent)])
            #expect(try await env.db.tags(paperPK: b.pk) == [Tag(name: "single-cell", origin: .user)])
        }
    }

    // MARK: DDL

    @Test func deadlineOperationsRunInOneSchedulePassAndSkipDonePapers() async throws {
        try await Kit.run { env in
            let a = try await Kit.addPaper(env, title: "A", deadline: Self.d(9, 30))
            let b = try await Kit.addPaper(env, title: "B", deadline: Self.d(10, 1))
            let done = try await Kit.addPaper(env, title: "Done", deadline: Self.d(10, 2), status: .done)
            let pin = try await env.engine.applyBatch(.pinDeadline(Self.d(10, 9)), paperIDs: [a.id, b.id, done.id])
            #expect(pin.applied == [a.id, b.id] && pin.skipped == [done.id])
            for id in [a.id, b.id] {
                let p = try await Kit.paper(env, id)
                #expect(p.deadline == Self.d(10, 9) && p.scheduleMode == .pinned && p.deadlineOrigin == .user)
            }
            #expect(try await Kit.paper(env, done.id).deadline == Self.d(10, 2))
            // The user re-pins B meanwhile: undo restores A only.
            _ = try await env.engine.pinDeadline(paperID: b.id, date: Self.d(10, 15))
            #expect(try await env.engine.undoBatch(token: try #require(pin.undoToken)))
            let backA = try await Kit.paper(env, a.id)
            #expect(backA.deadline == Self.d(9, 30) && backA.scheduleMode == .auto && backA.deadlineOrigin == .place)
            #expect(try await Kit.paper(env, b.id).deadline == Self.d(10, 15))

            let postponed = try await env.engine.applyBatch(.postponeDay, paperIDs: [a.id])
            #expect(try await Kit.paper(env, a.id).deadline == Self.d(10, 1))
            #expect(try await env.engine.undoBatch(token: try #require(postponed.undoToken)))
            #expect(try await Kit.paper(env, a.id).deadline == Self.d(9, 30))

            let week = try await env.engine.applyBatch(.postponeWeek, paperIDs: [a.id])
            #expect(try await Kit.paper(env, a.id).deadline == Self.d(10, 7))
            #expect(week.undoToken != nil)

            _ = try await env.engine.applyBatch(.unschedule, paperIDs: [a.id, b.id])
            for id in [a.id, b.id] {
                let p = try await Kit.paper(env, id)
                #expect(p.scheduleMode == .none && p.deadline == nil)
            }
            // Restore Automatic Scheduling places them one after another (each sees the previous one).
            let auto = try await env.engine.applyBatch(.restoreAuto, paperIDs: [a.id, b.id])
            let pa = try await Kit.paper(env, a.id), pb = try await Kit.paper(env, b.id)
            #expect(pa.scheduleMode == .auto && pb.scheduleMode == .auto && pa.deadlineOrigin == .place)
            let da = try #require(pa.deadline), db = try #require(pb.deadline)
            #expect(da <= db && da != db)                                       // 60 min each, 60 min a day
            #expect(try await env.engine.undoBatch(token: try #require(auto.undoToken)))
            let unplaced = try await Kit.paper(env, a.id)
            #expect(unplaced.scheduleMode == .none && unplaced.deadline == nil)
        }
    }

    // MARK: Recently Deleted

    @Test func moveToTrashIsUndoable() async throws {
        try await Kit.run { env in
            let a = try await Kit.addPaper(env, title: "A", folder: "2024_A")
            let b = try await Kit.addPaper(env, title: "B", folder: "2024_B")
            await env.engine.agents.enqueue(paperPK: a.pk, hold: true)
            let events = Sink(env.engine.events.subscribe())
            let out = try await env.engine.applyBatch(.moveToTrash, paperIDs: [a.id, b.id])
            #expect(out.applied == [a.id, b.id])
            for id in [a.id, b.id] {
                let p = try await Kit.paper(env, id)
                #expect(p.isDeleted && p.folder.hasPrefix(".recently-deleted/"))
                #expect(FileManager.default.fileExists(atPath: env.engine.ctx.pdfURL(p).path))
            }
            #expect(try await env.db.activeJob(paperPK: a.pk) == nil)        // its AI job is cancelled
            #expect(Self.notices(await events.settle()).map(\.operation) == ["moveToTrash"])
            // The user restores A by hand meanwhile; undo restores B and leaves A alone.
            _ = try await env.engine.restore(paperID: a.id)
            #expect(try await env.engine.undoBatch(token: try #require(out.undoToken)))
            for id in [a.id, b.id] {
                let p = try await Kit.paper(env, id)
                #expect(p.isLive && p.folder.hasPrefix("Papers/"))
                #expect(FileManager.default.fileExists(atPath: env.engine.ctx.pdfURL(p).path))
            }
        }
    }

    @Test func aFailedMoveToTrashPutsTheFoldersBack() async throws {
        try await Kit.run { env in
            let a = try await Kit.addPaper(env, title: "A", folder: "2024_A")
            let b = try await Kit.addPaper(env, title: "B", folder: "inbox-b", stage: .committed, inInbox: true)
            let inbox = env.paths.inbox
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: inbox.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inbox.path) }
            await #expect(throws: PaperOperationError.self) {
                _ = try await env.engine.applyBatch(.moveToTrash, paperIDs: [a.id, b.id])
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inbox.path)
            let pa = try await Kit.paper(env, a.id), pb = try await Kit.paper(env, b.id)
            #expect(pa.isLive && pa.folder == "Papers/2024_A" && pb.isLive)
            #expect(FileManager.default.fileExists(atPath: env.engine.ctx.pdfURL(pa).path))   // A moved back
            #expect(FileManager.default.fileExists(atPath: env.engine.ctx.pdfURL(pb).path))
            let bin = (try? FileManager.default.contentsOfDirectory(atPath: env.paths.recentlyDeleted.path)) ?? []
            #expect(bin.isEmpty, "\(bin)")
        }
    }

    @Test func restoreBringsBackWhatItCanAndHasNoUndo() async throws {
        try await Kit.run { env in
            let a = try await Kit.addPaper(env, title: "A")
            let b = try await Kit.addPaper(env, title: "B", doi: "10.1101/2024.01.16.575956")
            _ = try await env.engine.applyBatch(.moveToTrash, paperIDs: [a.id, b.id])
            let twin = try await Kit.addPaper(env, title: "B again", doi: "10.1101/2024.01.16.575956")
            let out = try await env.engine.applyBatch(.restore, paperIDs: [a.id, b.id, twin.id])
            #expect(out.applied == [a.id] && out.skipped == [b.id, twin.id] && out.undoToken == nil)
            #expect(try await Kit.paper(env, a.id).isLive)
            #expect(try await Kit.paper(env, b.id).isDeleted)
            // Live papers can't be batch-edited from Recently Deleted's menu and vice versa.
            #expect(try await env.engine.applyBatch(.setPriority(.high), paperIDs: [b.id]).skipped == [b.id])
            // When nothing could be restored, the reason is thrown.
            await #expect(throws: PaperOperationError.restoreConflict(paperID: twin.id, title: "B again")) {
                _ = try await env.engine.applyBatch(.restore, paperIDs: [b.id])
            }
        }
    }

    // MARK: Undo window

    @Test func undoExpiresAfterThirtySecondsAndIsPerEngine() async throws {
        try await Kit.run { env in
            try await Kit.run { other in
                let a = try await Kit.addPaper(env, title: "A")
                let first = try #require(try await env.engine.applyBatch(.setPriority(.high), paperIDs: [a.id]).undoToken)
                #expect(try await !other.engine.undoBatch(token: first))          // another engine's token
                env.advance(31)
                #expect(try await !env.engine.undoBatch(token: first))
                #expect(try await Kit.paper(env, a.id).priority == .high)
                // The skip-today ledger is separate: a batch token means nothing to `undo(token:)` there.
                let second = try #require(try await env.engine.applyBatch(.setPriority(.low), paperIDs: [a.id]).undoToken)
                #expect(try await env.engine.undoBatch(token: second))
                #expect(try await Kit.paper(env, a.id).priority == .high)
            }
        }
    }

    // MARK: Re-read with AI

    @Test func rereadQueuesOrdinaryCardJobsOnlyWhenAIReadingIsOn() async throws {
        try await Kit.run { env in
            let a = try await Kit.addPaper(env, title: "A")
            let b = try await Kit.addPaper(env, title: "B")
            let events = Sink(env.engine.events.subscribe())
            // agent.mode off (the kit's default): nothing is queued.
            let off = try await env.engine.requestReread(paperIDs: [a.id, b.id])
            #expect(off.applied.isEmpty && off.skipped == [a.id, b.id])
            #expect(try await env.db.activeJob(paperPK: a.pk) == nil)
            var s = env.settings.value
            s.agentMode = .mock
            env.settings.value = s
            _ = try await env.engine.softDelete(paperID: b.id)
            let on = try await env.engine.requestReread(paperIDs: [a.id, b.id])
            #expect(on.applied == [a.id] && on.skipped == [b.id] && on.undoToken == nil)
            let job = try #require(try await env.db.activeJob(paperPK: a.pk))
            #expect(job.state == .queued && job.priority == 0)                  // not held, behind single re-reads
            #expect(Self.notices(await events.settle()) == [BatchNotice(operation: BatchOperation.rereadCode, paperIDs: [a.id])])
        }
    }

    @Test func operationCodesAreStable() {
        #expect(BatchOperation.setStatus(.toRead).code == "setStatus.to_read")
        #expect(BatchOperation.setStatus(.done).code == "setStatus.done")
        #expect(BatchOperation.setPriority(.low).code == "setPriority.low")
        #expect(BatchOperation.moveToTrash.code == "moveToTrash")
        #expect(BatchOperation.pinDeadline(Self.d(1, 1)).code == "pinDeadline")
        #expect(BatchOperation.postponeDay.isSchedule && !BatchOperation.moveToTrash.isSchedule)
        #expect(BatchOperation.restore.targetsDeleted && !BatchOperation.moveToTrash.targetsDeleted)
    }
}
