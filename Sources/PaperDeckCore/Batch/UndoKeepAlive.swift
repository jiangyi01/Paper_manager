import Foundation

/// Deferred removals of what an undo may still need — a skipped parked file, a replaced paper's
/// earlier file and facts, a merged-away copy's text cache and thumbnail. Each runs `delay`
/// seconds after it was scheduled, later by whatever `extend` added meanwhile: a duplicate
/// batch's one undo token is minted when the last row is done, so the rows applied before it
/// keep their material until that token expires (`DupBatchKeepAlive`). Per engine
/// (`EngineContext.undoCleanups`).
package actor UndoCleanups {
    private var pending: Set<String> = []
    /// Time added to a pending removal since its timer last started (consumed when it fires).
    private var extra: [String: TimeInterval] = [:]

    package init() {}

    /// Keys of the kinds of material (the same id never names two kinds).
    package static func parkedKey(_ pendingID: String) -> String { "parked." + pendingID }
    package static func replacedKey(_ undoID: String) -> String { "replaced." + undoID }
    package static func mergedCopyKey(_ paperID: String) -> String { "merged." + paperID.lowercased() }

    /// Runs `cleanup` after `delay` seconds plus every extension of `key` made before then.
    package func schedule(_ key: String, after delay: TimeInterval, _ cleanup: @escaping @Sendable () async -> Void) {
        pending.insert(key)
        extra[key] = nil
        Task { await self.run(key, delay: delay, cleanup) }
    }

    private func run(_ key: String, delay: TimeInterval, _ cleanup: @escaping @Sendable () async -> Void) async {
        var wait = delay
        while wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
            wait = extra.removeValue(forKey: key) ?? 0
        }
        pending.remove(key)
        await cleanup()
    }

    /// Keeps the pending removal `key` `seconds` longer (unknown or finished keys: nothing).
    package func extend(_ key: String, by seconds: TimeInterval) {
        guard seconds > 0, pending.contains(key) else { return }
        extra[key, default: 0] += seconds
    }

    /// Whether `key`'s removal is still waiting, and the time added to it not yet slept (tests).
    package func state(_ key: String) -> (pending: Bool, extra: TimeInterval) {
        (pending.contains(key), extra[key] ?? 0)
    }
}

/// The keep-alive of a duplicate batch's rows (`Engine.resolveDuplicates`). Every row's own
/// removals were scheduled `UndoToken.lifetime + 5` s after the row started at the latest; the
/// batch's undo token expires `UndoToken.lifetime` after the last row. So each row's removals are
/// extended by the time since the row started — step by step after each later row, so that no
/// removal fires while the batch is still running. Pure (dates in, extensions out).
package struct DupBatchKeepAlive: Sendable, Equatable {
    private struct Row: Sendable, Equatable {
        var keys: [String]
        var startedAt: Date
        var granted: TimeInterval
    }

    private var rows: [Row] = []

    package init() {}

    /// A row was applied: the removals it scheduled (`cleanupKeys`) and when it started.
    package mutating func add(keys: [String], startedAt: Date) {
        guard !keys.isEmpty else { return }
        rows.append(Row(keys: keys, startedAt: startedAt, granted: 0))
    }

    /// The extensions due at `now` (key, seconds to add): afterwards every row's removals wait at
    /// least `now - startedAt` longer than their own window, i.e. until `now + lifetime + 5`.
    package mutating func extensions(at now: Date) -> [(key: String, seconds: TimeInterval)] {
        var out: [(key: String, seconds: TimeInterval)] = []
        for i in rows.indices {
            let due = max(0, now.timeIntervalSince(rows[i].startedAt)) - rows[i].granted
            guard due > 0 else { continue }
            rows[i].granted += due
            out += rows[i].keys.map { (key: $0, seconds: due) }
        }
        return out
    }

    /// The removals a resolution's undo steps rely on (`UndoCleanups` keys).
    package static func cleanupKeys(_ steps: [DupUndoStep]) -> [String] {
        steps.compactMap { step in
            switch step {
            case .intakeRestoreDiscarded(let pendingID): return UndoCleanups.parkedKey(pendingID)
            case .intakeUndoReplace(let id): return UndoCleanups.replacedKey(id)
            case .recreatePaper(let snap, _, _, _, _, _): return UndoCleanups.mergedCopyKey(snap.paper.id)
            default: return nil
            }
        }
    }
}
