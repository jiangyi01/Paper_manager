import Foundation

/// Explanation history as the paper inspector's "Explanations" section and the history window show
/// it (LN §7.6): one entry per panel thread (its first turn, with its follow-ups and chips under
/// it), pinned threads first, then the newest. Pure; owned by the Explain UI lane (A2).
package enum ExplainHistory {
    package struct Thread: Sendable, Equatable, Identifiable {
        package var id: String { threadID }
        package var threadID: String
        /// Turn order (the first explanation first).
        package var turns: [ExplanationRecord]
        package var first: ExplanationRecord { turns[0] }
        package var pinned: Bool { turns.contains(where: \.pinned) }
        package var saved: Bool { turns.contains { $0.savedToNotesAt != nil } }
        package var latest: Date { turns.map(\.createdAt).max() ?? first.createdAt }
        /// The page of the capture (the first turn's; follow-ups share it).
        package var page: Int? { turns.lazy.compactMap(\.page).first }
    }

    /// The default number of threads the inspector lists before "Show all".
    package static let inspectorLimit = 5
    /// Rows loaded for the inspector / the history window.
    package static let loadLimit = 200

    /// `records` grouped by thread: pinned threads first, then by the newest turn (ties: the id).
    package static func threads(_ records: [ExplanationRecord]) -> [Thread] {
        var byThread: [String: [ExplanationRecord]] = [:]
        for r in records { byThread[r.threadID, default: []].append(r) }
        let threads = byThread.map { key, turns in
            Thread(threadID: key, turns: turns.sorted { ($0.turn, $0.createdAt, $0.id) < ($1.turn, $1.createdAt, $1.id) })
        }
        return threads.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            if a.latest != b.latest { return a.latest > b.latest }
            return a.threadID < b.threadID
        }
    }

    /// The first line of a turn's answer, for a collapsed row.
    package static func summary(_ r: ExplanationRecord, limit: Int = 140) -> String {
        let lines = r.answer.components(separatedBy: "\n").map { line in
            line.replacingOccurrences(of: #"^\s*(?:[-*•+]|\d{1,3}[.)])\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"[*_`#>]+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return ClipboardOffer.preview(lines.joined(separator: " · "), limit: limit)
    }
}

/// Where a reader explanation came from (`ReaderAnchor`: page + rect + the PDF's text there), kept
/// next to its `explanation` row so the history can open the reader there and mark it. The anchor
/// lives in the library's `kv` table under `explain.anchor.<explanation id>` (JSON) — additive, no
/// schema change (`explanation.page` already holds the page); rows whose explanation is gone are
/// removed by `pruneExplanationReaderAnchors`. Owned by the Explain UI lane (A4).
package enum ExplainAnchorStore {
    package static let prefix = "explain.anchor."

    package static func key(explanationID: String) -> String { prefix + explanationID.lowercased() }

    package static func encode(_ anchor: ReaderAnchor) -> String? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(anchor)).flatMap { String(data: $0, encoding: .utf8) }
    }

    package static func decode(_ s: String) -> ReaderAnchor? {
        try? JSONDecoder().decode(ReaderAnchor.self, from: Data(s.utf8))
    }
}

extension Engine {
    /// Stores the reader anchor of a saved explanation.
    package func saveExplanationReaderAnchor(_ anchor: ReaderAnchor, explanationID: String) async {
        guard let json = ExplainAnchorStore.encode(anchor) else { return }
        try? await db.setKV(ExplainAnchorStore.key(explanationID: explanationID), json)
    }

    /// The reader anchor of an explanation (nil: not from the reader, or unreadable).
    package func explanationReaderAnchor(id: String) async -> ReaderAnchor? {
        guard let raw = try? await db.kv(ExplainAnchorStore.key(explanationID: id)) else { return nil }
        return ExplainAnchorStore.decode(raw)
    }

    /// Removes the anchors of explanations that no longer exist (pruned, or their library was
    /// rebuilt); returns how many. Maintenance may call it after `pruneExplanationsByRetention`.
    @discardableResult
    package func pruneExplanationReaderAnchors() async -> Int {
        guard let rows = try? await db.kvRows(prefix: ExplainAnchorStore.prefix) else { return 0 }
        var removed = 0
        for key in rows.keys {
            let id = String(key.dropFirst(ExplainAnchorStore.prefix.count))
            if (try? await db.explanation(id: id)) == nil {
                try? await db.removeKV(key)
                removed += 1
            }
        }
        return removed
    }
}
