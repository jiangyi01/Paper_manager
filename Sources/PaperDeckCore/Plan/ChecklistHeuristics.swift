import Foundation

/// The local checklist generated at import time (§6.4), before Claude has read
/// the paper. Pure: the same structure always yields the same texts, minutes
/// and estimate (only item ids are random).
package enum ChecklistHeuristics {
    /// Words per page assumed when extraction produced no word count (scanned or
    /// odd PDFs) but the page count is known — closer to reality than the 15′ floor.
    static let wordsPerPageFallback = 400

    package static func generate(structure: DocumentStructure, pageCount: Int?) -> (items: [ChecklistItem], estMinutes: Int) {
        let figures = Array(Set(structure.mainFigureNumbers.filter { $0 > 0 }).sorted().prefix(12))
        let validPage = { (page: Int?) -> Int? in
            guard let page, page >= 1 else { return nil }
            if let pageCount, page > pageCount { return nil }
            return page
        }

        // Abstracts sit on page 1 even when no "Abstract" heading was detected.
        var rows = [Row(text: "Read abstract; skim all figure titles", section: "Abstract",
                        page: validPage(structure.page(of: .abstract) ?? 1), kind: .overview, fixedMinutes: 5)]

        // Shares are doubled (12→24, 22.5→45 …) so the split Results row stays integral.
        var weighted: [Row] = []
        if let intro = structure.sections.first(where: { $0.kind == .introduction })
            ?? structure.sections.first(where: { $0.kind == .background }) {
            weighted.append(Row(text: "Introduction: note the open question and the main claim",
                                section: intro.kind == .introduction ? "Introduction" : "Background",
                                page: validPage(intro.page), kind: .other, share: 24))
        }
        if !figures.isEmpty {
            let resultsPage = validPage(structure.page(of: .results))
            if structure.benchmarkMentions >= 5 {
                // Benchmark papers are read table-first, so one row rather than per-figure halves.
                weighted.append(Row(text: "Tables/Figs: list tasks, metrics and baselines",
                                    section: "Fig. \(figures[0])", page: resultsPage, kind: .figure, share: 90))
            } else if figures.count >= 5 {
                let half = (figures.count + 1) / 2
                let first = Array(figures[..<half]), second = Array(figures[half...])
                weighted.append(Row(text: resultsText(first), section: "Fig. \(first[0])",
                                    page: resultsPage, kind: .figure, share: 45))
                // Where the later figures start is unknown; a wrong page chip is worse than none.
                weighted.append(Row(text: resultsText(second), section: "Fig. \(second[0])",
                                    page: nil, kind: .figure, share: 45))
            } else {
                weighted.append(Row(text: resultsText(figures), section: "Fig. \(figures[0])",
                                    page: resultsPage, kind: .figure, share: 90))
            }
        }
        if let discussion = structure.sections.first(where: { $0.kind == .discussion })
            ?? structure.sections.first(where: { $0.kind == .conclusion }) {
            weighted.append(Row(text: "Discussion: note stated limitations and future work",
                                section: discussion.kind == .discussion ? "Discussion" : "Conclusion",
                                page: validPage(discussion.page), kind: .discussion, share: 20))
        }
        if let methods = structure.sections.first(where: { $0.kind == .methods }) {
            weighted.append(Row(text: "Methods: data sources, key parameters and statistical tests",
                                section: "Methods", page: validPage(methods.page), kind: .method, share: 44))
        }
        let hasED = structure.hasExtendedData || structure.has(.extendedData)
        if hasED || structure.hasSupplementary || structure.has(.supplementary) {
            weighted.append(Row(text: "Skim Extended Data / Supplementary items cited in Results",
                                section: hasED ? "Extended Data" : "Supplementary",
                                page: validPage(structure.page(of: hasED ? .extendedData : .supplementary)),
                                kind: .supplementary, share: 16))
        }
        if weighted.isEmpty {
            weighted.append(Row(text: "Read the main text end-to-end; note the main claim and key evidence",
                                section: nil, page: nil, kind: .other, share: 200))
        }
        rows += weighted

        if let data = structure.sections.first(where: { $0.kind == .dataAvailability })
            ?? structure.sections.first(where: { $0.kind == .codeAvailability }) {
            rows.append(Row(text: "Note data & code availability (accessions, repo)",
                            section: data.kind == .dataAvailability ? "Data availability" : "Code availability",
                            page: validPage(data.page), kind: .data, fixedMinutes: 5))
        }

        var words = max(0, structure.mainWordCount)
        if words == 0, let pageCount, pageCount > 0 { words = pageCount * wordsPerPageFallback }
        let fixed = rows.reduce(0) { $0 + $1.fixedMinutes }
        let k = weighted.count
        let raw = Double(words) / 130 + 3 * Double(figures.count)
        let est = max(round5(min(max(raw, 15), 240)), fixed + 5 * k)

        // Every weighted row gets one 5′ unit up front; the rest follows the shares.
        var extra = largestRemainder(units: (est - fixed) / 5 - k, weights: weighted.map(\.share)).makeIterator()
        let items = rows.enumerated().map { index, row in
            ChecklistItem(ord: Double(index), text: row.text, section: row.section, page: row.page,
                          minutes: row.share > 0 ? 5 * (1 + (extra.next() ?? 0)) : row.fixedMinutes,
                          kind: row.kind, origin: .heuristic)
        }
        return (items, est)
    }

    // MARK: - Shared arithmetic (also used by ChecklistMerger)

    /// Nearest multiple of 5, halves rounded up.
    static func round5(_ x: Double) -> Int {
        guard x.isFinite else { return 0 }
        return Int((x / 5).rounded(.toNearestOrAwayFromZero)) * 5
    }

    /// Hamilton apportionment: splits `units` proportionally to `weights`; leftovers
    /// go to the largest fractional remainders (ties → larger weight, then earlier
    /// index). Σresult == max(units, 0). All-zero weights split evenly.
    /// Callers keep units·weight far below Int.max (minutes are clamped upstream).
    static func largestRemainder(units: Int, weights: [Int]) -> [Int] {
        guard !weights.isEmpty else { return [] }
        guard units > 0 else { return Array(repeating: 0, count: weights.count) }
        var w = weights.map { max(0, $0) }
        if w.allSatisfy({ $0 == 0 }) { w = Array(repeating: 1, count: w.count) }
        let total = w.reduce(0, +)
        var alloc = w.map { units * $0 / total }
        let leftover = units - alloc.reduce(0, +)
        let order = w.indices.sorted { a, b in
            let ra = units * w[a] % total, rb = units * w[b] % total
            if ra != rb { return ra > rb }
            if w[a] != w[b] { return w[a] > w[b] }
            return a < b
        }
        for i in order.prefix(leftover) { alloc[i] += 1 }
        return alloc
    }

    // MARK: - Private

    private static func resultsText(_ figures: [Int]) -> String {
        let label = figures.count == 1 ? "Fig. \(figures[0])" : "Figs \(figures[0])–\(figures[figures.count - 1])"
        return "Results: \(label) — one-line takeaway per figure"
    }

    /// A template row: fixed rows carry minutes, weighted rows a (doubled) share.
    private struct Row {
        var text: String
        var section: String?
        var page: Int?
        var kind: ChecklistKind
        var fixedMinutes = 0
        var share = 0
    }
}
