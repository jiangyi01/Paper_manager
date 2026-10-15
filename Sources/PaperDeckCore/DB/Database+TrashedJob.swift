import Foundation

/// The reading a paper was waiting for when Move to Recently Deleted cancelled its job (kv
/// `trash.job.<paper id>`): Restore — or the batch toast's Undo — creates it again, so a held,
/// queued or running reading is not silently dropped. Written in the deleting transaction, read
/// and removed in the restoring one; a purge removes it with the row.
package struct TrashedJob: Codable, Sendable, Equatable {
    /// held, queued or running (a running one comes back queued).
    package var state: AgentJobState
    package var priority: Int
    package var provider: String
    /// The paper's note before the cancel (`AgentQueue.modeOffNote` keeps a mode-off hold one).
    package var note: String?

    package init(state: AgentJobState, priority: Int, provider: String, note: String?) {
        self.state = state; self.priority = priority; self.provider = provider; self.note = note
    }

    package init(_ job: AgentJob, note: String?) {
        self.init(state: job.state, priority: job.priority, provider: job.provider, note: note)
    }

    package static let prefix = "trash.job."
    package static func key(paperID: String) -> String { prefix + paperID.lowercased() }
}

extension Database {
    package func trashedJob(paperID: String) throws -> TrashedJob? {
        guard let raw = try db.scalarString("SELECT value FROM kv WHERE key = ?", [.text(TrashedJob.key(paperID: paperID))])
        else { return nil }
        return try? decoder.decode(TrashedJob.self, from: Data(raw.utf8))
    }

    /// Records (or, with nil, forgets) the paper's cancelled reading. Quiet: not library state.
    package func setTrashedJob(_ job: TrashedJob?, paperID: String) throws {
        try write {
            let key = TrashedJob.key(paperID: paperID)
            guard let job else {
                try db.run("DELETE FROM kv WHERE key = ?", [.text(key)])
                return
            }
            let value = String(decoding: try encoder.encode(job), as: UTF8.self)
            try db.run("INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       [.text(key), .text(value)])
        }
    }

    /// Reads and forgets the paper's cancelled reading (Restore).
    package func takeTrashedJob(paperID: String) throws -> TrashedJob? {
        try write {
            let job = try trashedJob(paperID: paperID)
            try setTrashedJob(nil, paperID: paperID)
            return job
        }
    }
}
