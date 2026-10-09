import Foundation

/// Folds a fresh agent checklist into the existing one (§6.4). Used for the first
/// reading and every re-read, so it must never lose what the user did: ticked
/// items stay ticked, user-written or edited items keep their text and order.
package enum ChecklistMerger {
    /// Items the user has put effort into; everything else is disposable.
    package static func isTouched(_ item: ChecklistItem) -> Bool {
        item.origin == .user || item.userEdited || item.doneAt != nil
    }

    /// - Parameter est: the paper's estimate the unchecked items should add up to
    ///   (agent estimate, or the user's own when `est_source = user`).
    package static func merge(existing: [ChecklistItem], agentSteps: [ReadingCard.Step], est: Int) -> [ChecklistItem] {
        let ordered = existing.enumerated()
            .sorted { ($0.element.ord, $0.offset) < ($1.element.ord, $1.offset) }
            .map(\.element)
        let steps = agentSteps.filter { !$0.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // An empty agent list (degenerate output) must not wipe the heuristic plan.
        guard !steps.isEmpty else { return renumbered(ordered) }

        let touched = ordered.filter(isTouched)
        let touchedKeys = Set(touched.map { norm($0.text) })
        let fresh = touched.isEmpty ? steps : steps.filter { !touchedKeys.contains(norm($0.task)) }

        let committed = touched.filter { !$0.isDone }.reduce(0) { $0 + clampMinutes($1.minutes) }
        let target = clampMinutes(est) - committed
        let units = max(fresh.count, target > 0 ? ChecklistHeuristics.round5(Double(target)) / 5 : 0)
        let minutes = apportion(units: units, weights: fresh.map { clampMinutes($0.minutes) }).map { $0 * 5 }

        let agentItems = zip(fresh, minutes).map { step, m in
            ChecklistItem(ord: 0, text: step.task.trimmingCharacters(in: .whitespacesAndNewlines),
                          section: step.section, page: step.page, minutes: m, kind: step.kind, origin: .agent)
        }
        return renumbered(touched + agentItems)
    }

    /// Status after the user ticks/unticks an item; `items` is the state *after* the toggle.
    /// First tick → reading; all ticked → done (when auto-done is on); unticking on a
    /// done paper → reading. Pass `ticked` when known so ticking a leftover item on a
    /// paper the user already marked done by hand keeps it done.
    package static func statusAfterToggle(current: PaperStatus, items: [ChecklistItem], autoDone: Bool,
                                          ticked: Bool? = nil) -> PaperStatus {
        guard !items.isEmpty else { return current }
        let doneCount = items.count(where: \.isDone)
        let allDone = doneCount == items.count
        if allDone && autoDone { return .done }
        switch current {
        case .done:
            if ticked == true || allDone { return .done }
            return .reading
        case .reading:
            return .reading
        case .toRead:
            return doneCount > 0 ? .reading : .toRead
        }
    }

    /// Dedupe key: lowercase, "Figure 2"/"fig.2"/"Figs. 2" → "fig2", punctuation and
    /// stopwords dropped, so the agent's rephrasing of a user item isn't added twice.
    static func norm(_ text: String) -> String {
        let lowered = text.lowercased()
            .replacing(/\bfig(?:ure)?s?\.?\s*(s?\d+)/) { "fig" + $0.output.1 }
        let spaced = String(lowered.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return spaced.split(separator: " ")
            .filter { !stopwords.contains(String($0)) }
            .joined(separator: " ")
    }

    // MARK: - Private

    private static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "in", "on", "at", "to", "for", "from", "by", "with",
        "as", "into", "onto", "over", "per", "via", "vs", "versus", "than", "is", "are", "was", "were",
        "be", "been", "it", "its", "this", "that", "these", "those", "their", "there", "each", "any",
        "all", "which", "what", "how", "whether", "if", "so", "do", "does", "e", "g", "i", "ie", "eg",
    ]

    /// Bounds untrusted minute values so the unit arithmetic can't overflow.
    private static func clampMinutes(_ m: Int) -> Int { min(max(m, 0), 10_000) }

    /// Proportional split with a floor of one unit per item (the "each ≥ 5′" rule);
    /// the floor is paid for by the currently largest allocations. `units ≥ weights.count`.
    private static func apportion(units: Int, weights: [Int]) -> [Int] {
        var alloc = ChecklistHeuristics.largestRemainder(units: units, weights: weights)
        var deficit = 0
        for i in alloc.indices where alloc[i] < 1 { deficit += 1 - alloc[i]; alloc[i] = 1 }
        while deficit > 0, let j = alloc.indices.filter({ alloc[$0] > 1 }).max(by: { alloc[$0] < alloc[$1] }) {
            alloc[j] -= 1
            deficit -= 1
        }
        return alloc
    }

    private static func renumbered(_ items: [ChecklistItem]) -> [ChecklistItem] {
        items.enumerated().map { index, item in
            var copy = item
            copy.ord = Double(index)
            return copy
        }
    }
}
