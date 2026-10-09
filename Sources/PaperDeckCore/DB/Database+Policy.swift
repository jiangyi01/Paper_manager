import Foundation

// `paper_policy` (the assist feature, SchemaAssist.swift): the user's "Unpublished / confidential"
// and "Never use AI" flags per paper. A paper with neither flag has no row. Lead-owned (Slice 0).
extension Database {
    /// The policy of one paper; nil when it has none.
    package func paperPolicy(paperPK: Int64) throws -> PaperPolicy? {
        try db.query("SELECT confidential, never_ai, set_by, set_at FROM paper_policy WHERE paper_pk = ?",
                     [.integer(paperPK)]) { s in
            var c = Columns(s)
            return PaperPolicy(confidential: c.bool(), neverAI: c.bool(), setBy: c.raw(PaperPolicy.SetBy.user),
                               setAt: c.date())
        }.first
    }

    /// Policies of several papers (missing keys: none).
    package func paperPolicies(paperPKs: [Int64]) throws -> [Int64: PaperPolicy] {
        guard !paperPKs.isEmpty else { return [:] }
        var out: [Int64: PaperPolicy] = [:]
        for chunk in stride(from: 0, to: paperPKs.count, by: 500).map({ Array(paperPKs[$0..<min($0 + 500, paperPKs.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let rows = try db.query("SELECT paper_pk, confidential, never_ai, set_by, set_at FROM paper_policy WHERE paper_pk IN (\(marks))",
                                    chunk.map { .integer($0) }) { s -> (Int64, PaperPolicy) in
                var c = Columns(s)
                let pk = c.int64()
                return (pk, PaperPolicy(confidential: c.bool(), neverAI: c.bool(), setBy: c.raw(PaperPolicy.SetBy.user),
                                        setAt: c.date()))
            }
            for (pk, p) in rows { out[pk] = p }
        }
        return out
    }

    /// Stores `policy` (an empty one removes the row). Emits `.paper(pk:)` when something changed;
    /// throws `notFound` for an unknown paper.
    package func setPaperPolicy(paperPK: Int64, _ policy: PaperPolicy) throws {
        try write {
            guard (try db.scalarInt("SELECT count(*) FROM paper WHERE pk = ?", [.integer(paperPK)]) ?? 0) > 0 else {
                throw DatabaseError.notFound("paper pk \(paperPK)")
            }
            if policy.isEmpty {
                try db.run("DELETE FROM paper_policy WHERE paper_pk = ?", [.integer(paperPK)])
            } else {
                try db.run("""
                    INSERT INTO paper_policy(paper_pk, confidential, never_ai, set_by, set_at) VALUES(?, ?, ?, ?, ?)
                    ON CONFLICT(paper_pk) DO UPDATE SET confidential = excluded.confidential, never_ai = excluded.never_ai,
                      set_by = excluded.set_by, set_at = excluded.set_at
                    """, [.integer(paperPK), .bool(policy.confidential), .bool(policy.neverAI),
                          .text(policy.setBy.rawValue), .text(Database.timestamp(policy.setAt))])
            }
            if db.changes > 0 { note(.paper(pk: paperPK)) }
        }
    }

    // MARK: - Assist counters (kv `assist.count.<day>.<provider>`, `dedupe.ai.count.<day>`)

    /// The kv rows under `prefix` (`AssistDailyCounter.restore`).
    package func kvRows(prefix: String) throws -> [String: String] {
        let rows = try db.query("SELECT key, value FROM kv WHERE key >= ? AND key < ?",
                                [.text(prefix), .text(prefix + "\u{10FFFF}")]) { ($0.string(0), $0.string(1)) }
        return Dictionary(rows, uniquingKeysWith: { _, last in last })
    }

    /// Stores one counter row without a change notification (a count is not library state; a
    /// notification would refresh the library snapshot after every assist turn).
    package func setCounterKV(_ key: String, _ value: Int) throws {
        try db.run("INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   [.text(key), .text(String(value))])
    }

    /// Removes counter rows of earlier days (Maintenance), quietly.
    package func removeCounterKVs(_ keys: [String]) throws {
        for key in keys { try db.run("DELETE FROM kv WHERE key = ?", [.text(key)]) }
    }
}
