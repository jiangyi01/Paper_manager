import Foundation

/// The reading assist's rows that hang off a paper's pk but are not in its card.json: the Q&A
/// threads it is part of (`qa_thread_paper`), its Explain history (`explanation.paper_pk`), the
/// duplicate reviews that name it (`dup_review`) and the identifiers it took over from merged
/// copies (`paper_key` other than its own `local` ones). A hard delete cascades them away (or
/// unlinks them), so an index rebuild — every paper row deleted and inserted again with a new
/// pk — reads them by paper id first and links them back to the new pks afterwards, in the same
/// transaction (`Engine.rebuildFromSidecars`).
package struct PaperAssistLinks: Sendable {
    package struct ThreadLink: Sendable, Equatable {
        package var threadPK: Int64
        package var paperID: String
        package var ord: Int64
    }

    package struct ExplanationLink: Sendable, Equatable {
        package var explanationID: String
        package var paperID: String
    }

    package var threads: [ThreadLink] = []
    package var explanations: [ExplanationLink] = []
    /// Every review with a paper side, as stored (`newPaperID` / `existingPaperID` name the papers).
    package var reviews: [DupReview] = []
    /// Non-local `paper_key` rows by paper id (the local ones are derived from the row again).
    package var keys: [(paperID: String, key: DupKey)] = []

    package init() {}

    package var isEmpty: Bool { threads.isEmpty && explanations.isEmpty && reviews.isEmpty && keys.isEmpty }
}

/// What `relinkPaperAssistLinks` linked back.
package struct PaperAssistRelink: Sendable, Equatable {
    package var threads = 0
    package var explanations = 0
    package var reviews = 0
    package var keys = 0
    /// Rows whose paper did not come back (a card that was skipped): left as the delete left them.
    package var unmatched = 0

    package init() {}
}

extension Database {
    /// The assist rows of every paper, keyed by paper id (call before the papers are hard-deleted).
    package func paperAssistLinks() throws -> PaperAssistLinks {
        var links = PaperAssistLinks()
        links.threads = try db.query("""
            SELECT tp.thread_pk, p.id, tp.ord FROM qa_thread_paper tp JOIN paper p ON p.pk = tp.paper_pk
             ORDER BY tp.thread_pk, tp.ord
            """) { PaperAssistLinks.ThreadLink(threadPK: $0.int64(0), paperID: $0.string(1), ord: $0.int64(2)) }
        links.explanations = try db.query("""
            SELECT e.id, p.id FROM explanation e JOIN paper p ON p.pk = e.paper_pk ORDER BY e.pk
            """) { PaperAssistLinks.ExplanationLink(explanationID: $0.string(0), paperID: $0.string(1)) }
        links.reviews = try dupReviewsNamingPapers()
        links.keys = try db.query("""
            SELECT p.id, k.kind, k.value, k.source FROM paper_key k JOIN paper p ON p.pk = k.paper_pk
             WHERE k.source <> 'local' ORDER BY p.id, k.kind, k.value
            """) { s in
            (paperID: s.string(0), key: DupKey(kind: DupKey.Kind(rawValue: s.string(1)) ?? .doi, value: s.string(2),
                                               source: DupKey.Source(rawValue: s.string(3)) ?? .crossref))
        }
        return links
    }

    /// Links `links` back to the papers that now carry those ids (after they were inserted again
    /// with new pks). A thread link or an Explain record already in place is left alone; a review
    /// is written back only when it is gone and every paper it named is back. Call inside the
    /// transaction that deleted and re-inserted the papers.
    @discardableResult
    package func relinkPaperAssistLinks(_ links: PaperAssistLinks) throws -> PaperAssistRelink {
        try write {
            var out = PaperAssistRelink()
            var pks: [String: Int64?] = [:]
            func pk(_ id: String) throws -> Int64? {
                let key = id.lowercased()
                if let known = pks[key] { return known }
                let found = try db.scalarInt("SELECT pk FROM paper WHERE id = ?", [.text(key)])
                pks[key] = found
                return found
            }
            for link in links.threads {
                guard let paperPK = try pk(link.paperID) else { out.unmatched += 1; continue }
                try db.run("""
                    INSERT OR IGNORE INTO qa_thread_paper(thread_pk, paper_pk, ord)
                    SELECT pk, ?, ? FROM qa_thread WHERE pk = ?
                    """, [.integer(paperPK), .integer(link.ord), .integer(link.threadPK)])
                out.threads += db.changes
            }
            for link in links.explanations {
                guard let paperPK = try pk(link.paperID) else { out.unmatched += 1; continue }
                try db.run("UPDATE explanation SET paper_pk = ? WHERE id = ? AND paper_pk IS NULL",
                           [.integer(paperPK), .text(link.explanationID)])
                out.explanations += db.changes
            }
            for var r in links.reviews {
                guard try dupReview(id: r.id) == nil else { continue }
                if r.newPaperPK != nil {
                    guard let id = r.newPaperID, let mapped = try pk(id) else { out.unmatched += 1; continue }
                    r.newPaperPK = mapped
                }
                if r.existingPaperPK != nil {
                    guard let id = r.existingPaperID, let mapped = try pk(id) else { out.unmatched += 1; continue }
                    r.existingPaperPK = mapped
                }
                if let h = r.historyPK, try db.scalarInt("SELECT pk FROM paper_history WHERE pk = ?", [.integer(h)]) == nil {
                    r.historyPK = nil
                }
                try insertDupReview(r)
                out.reviews += 1
            }
            for entry in links.keys {
                guard let paperPK = try pk(entry.paperID) else { out.unmatched += 1; continue }
                try db.run("INSERT OR IGNORE INTO paper_key(paper_pk, kind, value, source) VALUES(?, ?, ?, ?)",
                           [.integer(paperPK), .text(entry.key.kind.rawValue), .text(entry.key.value),
                            .text(entry.key.source.rawValue)])
                out.keys += db.changes
            }
            return out
        }
    }
}

/// What a duplicate merge moved from the removed copy to the kept paper (`moveMergedLinks`), so
/// its undo can move it back onto the re-created copy (`restoreMergedLinks`): the copy's Q&A
/// thread links and its "not the same work" / "related" decisions (`dup_pair`), which its hard
/// delete would otherwise cascade away.
package struct DupMergedLinks: Sendable, Equatable {
    package struct Thread: Sendable, Equatable {
        package var threadID: String
        package var ord: Int64
        /// The kept paper joined the thread with the merge (it wasn't in it before).
        package var addedToKept: Bool
    }

    package struct Pair: Sendable, Equatable {
        package var partnerID: String
        package var decision: String
        package var relation: String?
        package var decidedBy: String
        package var decidedAt: String
        /// The kept paper got this decision with the merge (it had none with the partner).
        package var addedToKept: Bool
    }

    package var threads: [Thread] = []
    package var pairs: [Pair] = []

    package init() {}

    package var isEmpty: Bool { threads.isEmpty && pairs.isEmpty }
}

extension Database {
    /// A merge (inside its transaction, before the copy's row goes): the copy's Q&A thread links
    /// move to the kept paper (a thread both were in keeps the kept paper's place), and so do its
    /// `dup_pair` decisions (min/max order; a decision the kept paper already has with that
    /// partner wins; one between the two merged papers is dropped). Returns what moved.
    package func moveMergedLinks(from copyPK: Int64, to keptPK: Int64) throws -> DupMergedLinks {
        try write {
            var out = DupMergedLinks()
            let threads = try db.query("""
                SELECT t.pk, t.id, tp.ord FROM qa_thread_paper tp JOIN qa_thread t ON t.pk = tp.thread_pk
                 WHERE tp.paper_pk = ? ORDER BY t.pk
                """, [.integer(copyPK)]) { (pk: $0.int64(0), id: $0.string(1), ord: $0.int64(2)) }
            for t in threads {
                try db.run("INSERT OR IGNORE INTO qa_thread_paper(thread_pk, paper_pk, ord) VALUES(?, ?, ?)",
                           [.integer(t.pk), .integer(keptPK), .integer(t.ord)])
                let added = db.changes > 0
                try db.run("DELETE FROM qa_thread_paper WHERE thread_pk = ? AND paper_pk = ?", [.integer(t.pk), .integer(copyPK)])
                out.threads.append(.init(threadID: t.id, ord: t.ord, addedToKept: added))
            }
            let pairs = try db.query("""
                SELECT p.id, d.decision, d.relation, d.decided_by, d.decided_at,
                       (CASE WHEN d.a_pk = ?1 THEN d.b_pk ELSE d.a_pk END)
                  FROM dup_pair d JOIN paper p ON p.pk = (CASE WHEN d.a_pk = ?1 THEN d.b_pk ELSE d.a_pk END)
                 WHERE d.a_pk = ?1 OR d.b_pk = ?1 ORDER BY p.id
                """, [.integer(copyPK)]) {
                (id: $0.string(0), decision: $0.string(1), relation: $0.optionalString(2), by: $0.string(3),
                 at: $0.string(4), partnerPK: $0.int64(5))
            }
            for pair in pairs {
                var added = false
                if pair.partnerPK != keptPK {
                    let (lo, hi) = pair.partnerPK < keptPK ? (pair.partnerPK, keptPK) : (keptPK, pair.partnerPK)
                    try db.run("""
                        INSERT OR IGNORE INTO dup_pair(a_pk, b_pk, decision, relation, decided_by, decided_at)
                        VALUES(?, ?, ?, ?, ?, ?)
                        """, [.integer(lo), .integer(hi), .text(pair.decision), .string(pair.relation), .text(pair.by),
                              .text(pair.at)])
                    added = db.changes > 0
                }
                out.pairs.append(.init(partnerID: pair.id, decision: pair.decision, relation: pair.relation,
                                       decidedBy: pair.by, decidedAt: pair.at, addedToKept: added))
            }
            try db.run("DELETE FROM dup_pair WHERE a_pk = ?1 OR b_pk = ?1", [.integer(copyPK)])
            return out
        }
    }

    /// A merge undone: `links` back on the re-created copy (`copyPK`), and what the merge added to
    /// the kept paper taken off it again. A thread or a partner that is gone since is skipped.
    package func restoreMergedLinks(_ links: DupMergedLinks, copyPK: Int64, keptPaperID: String) throws {
        guard !links.isEmpty else { return }
        try write {
            let keptPK = try db.scalarInt("SELECT pk FROM paper WHERE id = ?", [.text(keptPaperID.lowercased())])
            for t in links.threads {
                guard let threadPK = try db.scalarInt("SELECT pk FROM qa_thread WHERE id = ?", [.text(t.threadID)]) else { continue }
                try db.run("INSERT OR IGNORE INTO qa_thread_paper(thread_pk, paper_pk, ord) VALUES(?, ?, ?)",
                           [.integer(threadPK), .integer(copyPK), .integer(t.ord)])
                if t.addedToKept, let keptPK {
                    try db.run("DELETE FROM qa_thread_paper WHERE thread_pk = ? AND paper_pk = ?", [.integer(threadPK), .integer(keptPK)])
                }
            }
            for pair in links.pairs {
                guard let partnerPK = try db.scalarInt("SELECT pk FROM paper WHERE id = ?", [.text(pair.partnerID.lowercased())])
                else { continue }
                if pair.addedToKept, let keptPK, partnerPK != keptPK {
                    let (lo, hi) = partnerPK < keptPK ? (partnerPK, keptPK) : (keptPK, partnerPK)
                    try db.run("DELETE FROM dup_pair WHERE a_pk = ? AND b_pk = ?", [.integer(lo), .integer(hi)])
                }
                guard partnerPK != copyPK else { continue }
                let (lo, hi) = partnerPK < copyPK ? (partnerPK, copyPK) : (copyPK, partnerPK)
                try db.run("""
                    INSERT INTO dup_pair(a_pk, b_pk, decision, relation, decided_by, decided_at) VALUES(?, ?, ?, ?, ?, ?)
                    ON CONFLICT(a_pk, b_pk) DO UPDATE SET decision = excluded.decision, relation = excluded.relation,
                      decided_by = excluded.decided_by, decided_at = excluded.decided_at
                    """, [.integer(lo), .integer(hi), .text(pair.decision), .string(pair.relation), .text(pair.decidedBy),
                          .text(pair.decidedAt)])
            }
        }
    }
}
