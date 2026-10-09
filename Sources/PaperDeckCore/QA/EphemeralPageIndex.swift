import Foundation

/// Question-aware page ranking for Q&A (DQ §6.2): an in-memory SQLite FTS5 table over one paper's
/// pages, ranked by bm25 against the question's terms. Built per question in a few milliseconds and
/// thrown away; nothing is persisted, no background indexing (READING_ASSIST_PLAN §3.3). Pure as far
/// as callers can tell: the same pages and question always give the same order.
package enum EphemeralPageIndex {
    package struct Hit: Sendable, Equatable {
        package var page: Int
        /// Higher is more relevant (−bm25).
        package var score: Double
    }

    /// At most this many terms reach the MATCH expression.
    package static let maxTerms = 32

    /// Pages that match at least one term of `question`, best first (ties: earlier page first).
    /// Pages without a match are left out. An empty question (or one with only stop words) matches
    /// nothing.
    package static func rank(pages: [QAPage], question: String) -> [Hit] {
        let terms = terms(question)
        guard !terms.isEmpty, !pages.isEmpty else { return [] }
        if let hits = try? fts(pages: pages, terms: terms) { return hits }
        return counting(pages: pages, terms: terms)            // FTS5 unavailable: term counts
    }

    /// The question's search terms: lowercased letter / digit runs of at least 2 characters (digits
    /// of any length — "Fig. 3"), minus English stop words, deduplicated in order. Runs of CJK
    /// characters are left out (the tokenizer can't split them, and papers are mostly English);
    /// Latin terms inside a Chinese question still count.
    package static func terms(_ question: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var current = ""
        func flush() {
            defer { current = "" }
            guard !current.isEmpty else { return }
            let t = current.lowercased()
            let digits = t.allSatisfy(\.isNumber)
            guard digits || t.count >= 2, !stopWords.contains(t), !FTSQuery.containsCJK(t) else { return }
            if seen.insert(t).inserted { out.append(t) }
        }
        for ch in question {
            if ch.isLetter || ch.isNumber, !FTSQuery.containsCJK(String(ch)) {
                current.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return Array(out.prefix(maxTerms))
    }

    private static func fts(pages: [QAPage], terms: [String]) throws -> [Hit] {
        let db = try SQLiteConnection(path: ":memory:")
        defer { db.close() }
        try db.exec("CREATE VIRTUAL TABLE pages USING fts5(body, tokenize='unicode61 remove_diacritics 2')")
        let insert = try db.prepare("INSERT INTO pages(rowid, body) VALUES(?, ?)")
        for p in pages { try insert.run([.integer(Int64(p.number)), .text(p.text)]) }
        // Each term quoted (FTS5 string), so nothing in the question is query syntax.
        let match = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " OR ")
        let rows = try db.query("SELECT rowid, bm25(pages) FROM pages WHERE pages MATCH ? ORDER BY bm25(pages), rowid",
                                [.text(match)]) { s in Hit(page: s.int(0), score: -s.double(1)) }
        return rows
    }

    /// Fallback: total occurrences of the terms per page (case-insensitive), best first.
    private static func counting(pages: [QAPage], terms: [String]) -> [Hit] {
        var hits: [Hit] = []
        for p in pages {
            let words = tokens(p.text)
            let score = terms.reduce(0) { $0 + (words[$1] ?? 0) }
            if score > 0 { hits.append(Hit(page: p.number, score: Double(score))) }
        }
        return hits.sorted { $0.score != $1.score ? $0.score > $1.score : $0.page < $1.page }
    }

    private static func tokens(_ s: String) -> [String: Int] {
        var out: [String: Int] = [:]
        var current = ""
        for ch in s {
            if ch.isLetter || ch.isNumber { current.append(ch) } else if !current.isEmpty {
                out[current.lowercased(), default: 0] += 1
                current = ""
            }
        }
        if !current.isEmpty { out[current.lowercased(), default: 0] += 1 }
        return out
    }

    /// Common English function words (they would match every page).
    package static let stopWords: Set<String> = [
        "a", "about", "above", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at", "be",
        "because", "been", "before", "being", "between", "both", "but", "by", "can", "could", "did", "do", "does",
        "doing", "during", "each", "few", "for", "from", "further", "had", "has", "have", "having", "he", "her",
        "here", "hers", "him", "his", "how", "i", "if", "in", "into", "is", "it", "its", "itself", "just", "me",
        "more", "most", "my", "no", "nor", "not", "now", "of", "off", "on", "once", "only", "or", "other", "our",
        "out", "over", "own", "paper", "same", "she", "should", "so", "some", "such", "than", "that", "the",
        "their", "them", "then", "there", "these", "they", "this", "those", "through", "to", "too", "under",
        "until", "up", "us", "very", "was", "we", "were", "what", "when", "where", "which", "while", "who",
        "whom", "why", "will", "with", "would", "you", "your", "authors", "author", "study", "explain", "tell",
        "show", "shows", "shown", "describe", "please",
    ]
}
