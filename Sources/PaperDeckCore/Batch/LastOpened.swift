import Foundation

/// When each paper was last opened from PaperDeck. `opened_at` is stamped once (the first open)
/// and `RecentOpens` lives in memory (this session only), so after a relaunch Select ▾ ▸ Recently
/// Opened ranked by the *first* open. This keeps the last open per paper in the library's kv
/// (`paper.lastOpened`: a JSON list, newest first, at most `capacity` papers) — no schema change —
/// restored when the engine opens, written by `markOpened`, and forgotten when a paper is
/// removed for good (the 30-day purge, Delete Permanently).
package struct LastOpenedRecord: Codable, Sendable, Equatable {
    package var id: String
    /// Seconds since 1970.
    package var at: Double

    package init(id: String, at: Date) {
        self.id = id.lowercased(); self.at = at.timeIntervalSince1970
    }

    package static let key = "paper.lastOpened"
    package static let capacity = 500
}

extension Database {
    /// The stored list, newest first (empty when none or unreadable).
    package func lastOpenedRecords() throws -> [LastOpenedRecord] {
        guard let raw = try kv(LastOpenedRecord.key) else { return [] }
        return (try? decoder.decode([LastOpenedRecord].self, from: Data(raw.utf8))) ?? []
    }

    /// Moves `paperID` to the front with `at`, keeps the newest `capacity`; returns the new list.
    /// Quiet: not library state (no change notification, so nothing is re-planned).
    @discardableResult
    package func recordOpened(paperID: String, at: Date) throws -> [LastOpenedRecord] {
        try write {
            let entry = LastOpenedRecord(id: paperID, at: at)
            var list = try lastOpenedRecords().filter { $0.id != entry.id }
            list.insert(entry, at: 0)
            if list.count > LastOpenedRecord.capacity { list.removeLast(list.count - LastOpenedRecord.capacity) }
            try storeLastOpened(list)
            return list
        }
    }

    /// Drops `paperIDs` from the list (a paper removed for good).
    package func forgetOpened(paperIDs: Set<String>) throws {
        let ids = Set(paperIDs.map { $0.lowercased() })
        try write {
            let list = try lastOpenedRecords()
            let kept = list.filter { !ids.contains($0.id) }
            if kept.count != list.count { try storeLastOpened(kept) }
        }
    }

    private func storeLastOpened(_ list: [LastOpenedRecord]) throws {
        guard !list.isEmpty else {
            try db.run("DELETE FROM kv WHERE key = ?", [.text(LastOpenedRecord.key)])
            return
        }
        let value = String(decoding: try encoder.encode(list), as: UTF8.self)
        try db.run("INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   [.text(LastOpenedRecord.key), .text(value)])
    }
}

/// The engine's in-memory mirror of `paper.lastOpened` (Select ▾ reads it synchronously).
/// Thread-safe.
package final class LastOpenedTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [String: Date] = [:]

    package init() {}

    /// Paper id → when it was last opened from PaperDeck.
    package func snapshot() -> [String: Date] {
        lock.withLock { times }
    }

    package func replace(with records: [LastOpenedRecord]) {
        var next: [String: Date] = [:]
        for r in records where next[r.id] == nil { next[r.id] = Date(timeIntervalSince1970: r.at) }
        lock.withLock { times = next }
    }

    package func forget(_ paperID: String) {
        _ = lock.withLock { times.removeValue(forKey: paperID.lowercased()) }
    }
}

extension Engine {
    /// Reads `paper.lastOpened` into `lastOpened` (`Engine.open`).
    package func restoreLastOpened() async {
        do {
            lastOpened.replace(with: try await db.lastOpenedRecords())
        } catch {
            Log.db.error("last-opened restore failed: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}
