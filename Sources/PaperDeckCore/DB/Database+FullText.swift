import Foundation

extension Database {
    /// Live papers without a full-text row (`paper_fts_text`): a library rebuilt on a Mac whose
    /// text cache is empty, so search finds titles only (`Engine.reindexMissingFullText`).
    package func paperPKsWithoutFullText() throws -> [Int64] {
        try db.query("""
            SELECT pk FROM paper WHERE deleted_at IS NULL
            AND pk NOT IN (SELECT rowid FROM paper_fts_text) ORDER BY pk
            """) { $0.int64(0) }
    }

    /// How many live papers lack a full-text row although their PDF could have one — not locked,
    /// scanned, unreadable or missing (those never get one, re-indexing or not): the Help Center's
    /// "search finds titles only after a move" fact (`Engine.papersMissingFullTextCount`).
    package func countPapersMissingFullText() throws -> Int {
        let never = PaperFlags([.locked, .scanned, .unreadable, .missing]).rawValue
        return Int(try db.scalarInt("""
            SELECT COUNT(*) FROM paper WHERE deleted_at IS NULL AND (flags & ?) = 0
            AND pk NOT IN (SELECT rowid FROM paper_fts_text)
            """, [.integer(Int64(never))]) ?? 0)
    }
}
