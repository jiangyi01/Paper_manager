import Foundation

/// Toolbar ▸ Select ▾ (DQ §5.2; READING_ASSIST_PLAN §6.4 C1): pure picks over the papers in the
/// current view. The App turns the ids into a selection with `SelectionLogic.select`. Owned by
/// Slice C.
package enum SelectN {
    package enum Kind: String, Sendable, CaseIterable {
        /// The N papers added last.
        case mostRecentlyAdded
        /// The N unread (To Read) papers that are due first: earliest DDL, unscheduled last,
        /// then the longest waiting.
        case oldestUnread
        /// The N papers opened most recently: this session's opens from PaperDeck first (newest
        /// first), then the others by when they were first opened.
        case recentlyOpened
    }

    /// The menu's counts.
    package static let counts = [5, 10, 20]

    /// Up to `n` ids (nil: every match), best first. `recentOpens`: ids opened from PaperDeck in
    /// this session, newest first (`RecentOpens`). Deleted papers never count as unread.
    package static func pick(_ kind: Kind, n: Int?, from papers: [Paper], recentOpens: [String] = []) -> [String] {
        let ranked: [Paper]
        switch kind {
        case .mostRecentlyAdded:
            ranked = papers.sorted { a, b in
                a.addedAt != b.addedAt ? a.addedAt > b.addedAt : a.id < b.id
            }
        case .oldestUnread:
            ranked = papers.filter { $0.isLive && $0.status == .toRead }.sorted { a, b in
                switch (a.deadline, b.deadline) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.addedAt != b.addedAt ? a.addedAt < b.addedAt : a.id < b.id
                }
            }
        case .recentlyOpened:
            let byID = Dictionary(papers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var seen = Set<String>()
            var out: [Paper] = []
            for id in recentOpens {
                if let p = byID[id], seen.insert(id).inserted { out.append(p) }
            }
            let rest = papers.filter { $0.openedAt != nil && !seen.contains($0.id) }.sorted { a, b in
                a.openedAt! != b.openedAt! ? a.openedAt! > b.openedAt! : a.id < b.id
            }
            ranked = out + rest
        }
        let ids = ranked.map(\.id)
        guard let n else { return ids }
        return Array(ids.prefix(max(0, n)))
    }

    /// How many papers `kind` can pick at most (0: the menu entry is disabled).
    package static func available(_ kind: Kind, from papers: [Paper], recentOpens: [String] = []) -> Int {
        pick(kind, n: nil, from: papers, recentOpens: recentOpens).count
    }
}
