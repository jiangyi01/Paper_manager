import Foundation

// The built-in reader's page memory (kv `reader.page.<paper id>`; READING_ASSIST_PLAN §6.4 C4). Owned
// by Slice C (reader). Written quietly: a page turn is not library state, and a change notification
// would refresh the library snapshot (and the widget) on every page.
extension Database {
    package func readerPage(paperID: String) throws -> Int? {
        ReaderPageMemory.decode(try db.scalarString("SELECT value FROM kv WHERE key = ?",
                                                    [.text(ReaderPageMemory.key(paperID: paperID))]))
    }

    package func setReaderPage(paperID: String, page: Int) throws {
        try db.run("INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   [.text(ReaderPageMemory.key(paperID: paperID)), .text(ReaderPageMemory.encode(page: page))])
    }

    /// Removes the page memory of papers that no longer exist (purged from Recently Deleted); returns
    /// how many rows went. Papers in Recently Deleted keep theirs (a restore reopens where you were).
    /// Keys hold the lowercased id (`ReaderPageMemory.key`), so the ids are compared lowercased.
    @discardableResult
    package func pruneReaderPages() throws -> Int {
        try db.run("""
            DELETE FROM kv WHERE key GLOB ? AND substr(key, ?) NOT IN (SELECT lower(id) FROM paper)
            """, [.text(ReaderPageMemory.prefix + "*"), .int(ReaderPageMemory.prefix.count + 1)])
        return Int(db.changes)
    }
}
