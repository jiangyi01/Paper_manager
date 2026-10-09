import Foundation

// DDL operations (§6.3 table). The Scheduler computes; these persist. Only explicit user
// actions reach this file — priority, estimate and checklist edits never move a DDL.

/// Returned by 今天跳过: show `toast` (its button carries `.undo(token: id)`); `undo(token:)`
/// works until `expiresAt` (30 s).
package struct UndoToken: Sendable, Hashable, Identifiable {
    package static let lifetime: TimeInterval = 30

    package var id: String
    package var day: LocalDate                 // the day that was skipped
    package var movedPaperIDs: [String]
    package var expiresAt: Date
    package var message: String                // zh/en, e.g. 「今天已跳过 · 3 篇顺延一天」
    package var undoTitle: String              // 「撤销」 / "Undo"

    package var toast: Toast {
        Toast(id: "undo-" + id, kind: .success, message: message,
              buttons: [Toast.Button(title: undoTitle, action: .undo(token: id))])
    }
}

extension Engine {
    /// 设定日期…: `deadline = date`, mode pinned, origin user.
    @discardableResult
    package func pinDeadline(paperID: String, date: LocalDate) async throws -> Paper {
        try await applyDeadlineOp(paperID) { s, item, _ in s.pin(item, to: date) }
    }

    /// 恢复自动排期: place() again, origin place.
    @discardableResult
    package func restoreAutoDeadline(paperID: String) async throws -> Paper {
        try await applyDeadlineOp(paperID) { s, item, all in s.restoreAuto(item, among: all) }
    }

    /// 推迟一天 ⇧⌘P: next reading day after max(deadline, today); mode unchanged, origin user.
    @discardableResult
    package func postponeDay(paperID: String) async throws -> Paper {
        try await applyDeadlineOp(paperID) { s, item, _ in s.postponeDay(item) }
    }

    /// 推迟一周: snapToReadingDay(max(deadline, today) + 7); origin user.
    @discardableResult
    package func postponeWeek(paperID: String) async throws -> Paper {
        try await applyDeadlineOp(paperID) { s, item, _ in s.postponeWeek(item) }
    }

    /// 移到未排期.
    @discardableResult
    package func unschedule(paperID: String) async throws -> Paper {
        try await applyDeadlineOp(paperID) { s, item, _ in s.unschedule(item) }
    }

    /// 「按新优先级重新排期此论文」: place() with the paper's current priority.
    @discardableResult
    package func replan(paperID: String) async throws -> Paper {
        try await applyDeadlineOp(paperID) { s, item, all in s.restoreAuto(item, among: all) }
    }

    /// 顺延受影响的 N 篇: at-risk auto papers get deadline = simulated finish (origin user);
    /// pinned ones are only flagged. Returns the ids that moved.
    @discardableResult
    package func shiftAtRisk() async throws -> [String] {
        try await ctx.schedule { inputs in
            let changed = inputs.scheduler.shiftAtRisk(inputs.items)
            return EngineContext.SchedulePlan(changed: changed, result: changed.map(\.id))
        }
    }

    /// 今天跳过 (also the reminder's POSTPONE_DAY): today joins skipDays and every auto paper
    /// due today or later moves to the next reading day after its deadline (origin user);
    /// overdue and pinned papers stay. Undo within 30 s with `undo(token:)`.
    /// Skip days and moves are computed and written in one transaction (`ctx.schedule`).
    package func skipToday() async throws -> UndoToken {
        let outcome = try await ctx.schedule { inputs -> EngineContext.SchedulePlan<SkipOutcome> in
            let result = inputs.scheduler.skipToday(inputs.items)
            let before = Dictionary(inputs.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let pkByID = Dictionary(inputs.papers.map { ($0.id, $0.pk) }, uniquingKeysWith: { a, _ in a })
            let moves = result.changed.compactMap { item -> SkipUndoLedger.Move? in
                guard let pk = pkByID[item.id], let old = before[item.id] else { return nil }
                return SkipUndoLedger.Move(pk: pk, previous: old.deadline, previousOrigin: old.deadlineOrigin,
                                           applied: item.deadline)
            }
            let today = inputs.scheduler.today
            let added = inputs.settings.plan.skipDays.contains(today) ? nil : today
            return EngineContext.SchedulePlan(
                changed: result.changed, skipDays: result.skipDays,
                result: SkipOutcome(today: today, addedSkipDay: added, moves: moves, movedIDs: result.changed.map(\.id)))
        }
        let now = ctx.now()
        let token = UUID().uuidString.lowercased()
        let expiresAt = now.addingTimeInterval(UndoToken.lifetime)
        await skipUndoLedger.put(token, SkipUndoLedger.Entry(owner: ObjectIdentifier(self), expiresAt: expiresAt,
                                                             addedSkipDay: outcome.addedSkipDay, moves: outcome.moves),
                                 now: now)
        let lang = (await ctx.settings()).lang
        return UndoToken(id: token, day: outcome.today, movedPaperIDs: outcome.movedIDs,
                         expiresAt: expiresAt, message: PaperOpsText.skippedToday(moved: outcome.moves.count, lang),
                         undoTitle: PaperOpsText.undo(lang))
    }

    /// Reverts a 今天跳过 within its 30 s window: removes the skip day it added and restores the
    /// moved papers' deadline + origin (papers the user changed since are left alone), in one
    /// transaction. False when the token is unknown, already used or expired.
    @discardableResult
    package func undo(token: String) async throws -> Bool {
        guard let entry = await skipUndoLedger.take(token, owner: ObjectIdentifier(self), now: ctx.now()) else {
            // A token the skip ledger doesn't know: a multi-select batch (Slice C), then a duplicate decision (Slice B).
            if try await undoBatch(token: token) { return true }
            return try await undoDuplicateResolution(token: token)
        }
        let now = ctx.now()
        let moves = entry.moves
        let ctx = self.ctx
        let restored = try await db.transaction { db -> [Int64] in
            if let day = entry.addedSkipDay {
                var days = EngineContext.skipDays(in: db)
                if days.remove(day) != nil { try ctx.writeSkipDays(days, in: db) }
            }
            var touched: [Int64] = []
            for m in moves {
                guard let p = try db.paper(pk: m.pk), p.isLive, p.scheduleMode == .auto, p.deadline == m.applied else { continue }
                try db.modifyPaper(pk: m.pk, now: now) { row in
                    row.deadline = m.previous
                    row.deadlineOrigin = m.previousOrigin
                }
                touched.append(m.pk)
            }
            return touched
        }
        for pk in restored { await ctx.syncSidecar(pk: pk) }
        if entry.addedSkipDay != nil { await ctx.writeManifest() }
        return true
    }

    @discardableResult
    package func undo(token: UndoToken) async throws -> Bool { try await undo(token: token.id) }

    // MARK: Private

    /// One paper's DDL operation as a serializable read-modify-write (`ctx.schedule`).
    private func applyDeadlineOp(_ paperID: String,
                                 _ op: @escaping @Sendable (Scheduler, SchedItem, [SchedItem]) -> SchedItem) async throws -> Paper {
        let id = paperID.lowercased()
        let found = try await ctx.schedule { inputs -> EngineContext.SchedulePlan<Bool> in
            guard let item = inputs.item(id: id) else { return EngineContext.SchedulePlan(changed: [], result: false) }
            let updated = op(inputs.scheduler, item, inputs.items)
            return EngineContext.SchedulePlan(changed: updated == item ? [] : [updated], result: true)
        }
        guard found else {
            _ = try await PaperOpsSupport.livePaper(db, id)        // throws the precise error (deleted / not found)
            throw PaperOperationError.paperNotFound(paperID)
        }
        guard let saved = try await db.paper(id: id) else { throw PaperOperationError.paperNotFound(paperID) }
        return saved
    }
}

/// What `skipToday` computed inside its transaction.
private struct SkipOutcome: Sendable {
    var today: LocalDate
    var addedSkipDay: LocalDate?          // nil when today was already a skip day
    var moves: [SkipUndoLedger.Move]
    var movedIDs: [String]
}

// MARK: - Undo records (in memory, per engine, 30 s)

/// Tokens are random UUIDs; each record remembers the engine that created it, and expiry
/// is judged by that engine's clock, so engines (tests) never see each other's records.
actor SkipUndoLedger {
    struct Move: Sendable {
        var pk: Int64
        var previous: LocalDate?
        var previousOrigin: DeadlineOrigin
        var applied: LocalDate?
    }

    struct Entry: Sendable {
        var owner: ObjectIdentifier
        var expiresAt: Date
        /// The skip day the 今天跳过 added (nil when it was already skipped); undo removes only it,
        /// so skip days changed meanwhile survive.
        var addedSkipDay: LocalDate?
        var moves: [Move]
    }

    private static let maxEntries = 64
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    func put(_ token: String, _ entry: Entry, now: Date) {
        prune(owner: entry.owner, now: now)
        entries[token] = entry
        order.append(token)
        while order.count > Self.maxEntries { entries[order.removeFirst()] = nil }
    }

    /// Removes and returns a live record of `owner`; nil when missing or expired.
    func take(_ token: String, owner: ObjectIdentifier, now: Date) -> Entry? {
        prune(owner: owner, now: now)
        guard let entry = entries[token], entry.owner == owner else { return nil }
        entries[token] = nil
        order.removeAll { $0 == token }
        return entry
    }

    private func prune(owner: ObjectIdentifier, now: Date) {
        let expired = entries.filter { $0.value.owner == owner && $0.value.expiresAt < now }.map(\.key)
        guard !expired.isEmpty else { return }
        for key in expired { entries[key] = nil }
        order.removeAll { expired.contains($0) }
    }
}

private let skipUndoLedger = SkipUndoLedger()
