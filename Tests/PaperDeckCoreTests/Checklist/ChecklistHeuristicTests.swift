import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct ChecklistHeuristicTests {
    private static func structure(_ kinds: [SectionKind], figures: [Int] = [], words: Int = 0, ed: Bool = false,
                                  supp: Bool = false, benchmark: Int = 0) -> DocumentStructure {
        DocumentStructure(sections: kinds.enumerated().map { SectionHit(kind: $1, title: $1.rawValue, page: $0 + 1) },
                          mainFigureNumbers: figures, hasExtendedData: ed, hasSupplementary: supp,
                          mainWordCount: words, benchmarkMentions: benchmark)
    }

    private static func assertWellFormed(_ items: [ChecklistItem], est: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(items.reduce(0) { $0 + $1.minutes } == est, sourceLocation: sourceLocation)
        #expect(items.allSatisfy { $0.minutes >= 5 && $0.minutes % 5 == 0 }, sourceLocation: sourceLocation)
        #expect(items.allSatisfy { $0.origin == .heuristic && !$0.userEdited && $0.doneAt == nil },
                sourceLocation: sourceLocation)
        #expect(items.map(\.ord) == items.indices.map(Double.init), sourceLocation: sourceLocation)
        #expect(Set(items.map(\.id)).count == items.count, sourceLocation: sourceLocation)
        #expect(est % 5 == 0 && est >= 15, sourceLocation: sourceLocation)
    }

    @Test func allSectionsFollowTheTemplateAndSumToEstimate() {
        // abstract p1, intro p2, results p3, discussion p4, methods p5, ED p6, data availability p7
        let s = Self.structure([.abstract, .introduction, .results, .discussion, .methods, .extendedData, .dataAvailability],
                               figures: [3, 1, 2, 4, 2], words: 6500)
        let (items, est) = ChecklistHeuristics.generate(structure: s, pageCount: 20)
        // 6500/130 + 3·4 = 62 → 60; fixed 10 + 5·5 = 35 → est 60.
        #expect(est == 60)
        Self.assertWellFormed(items, est: est)
        #expect(items.map(\.text) == [
            "Read abstract; skim all figure titles",
            "Introduction: note the open question and the main claim",
            "Results: Figs 1–4 — one-line takeaway per figure",
            "Discussion: note stated limitations and future work",
            "Methods: data sources, key parameters and statistical tests",
            "Skim Extended Data / Supplementary items cited in Results",
            "Note data & code availability (accessions, repo)",
        ])
        #expect(items.map(\.kind) == [.overview, .other, .figure, .discussion, .method, .supplementary, .data])
        #expect(items.map(\.section) == ["Abstract", "Introduction", "Fig. 1", "Discussion", "Methods",
                                         "Extended Data", "Data availability"])
        #expect(items.map(\.page) == [1, 2, 3, 4, 5, 6, 7])
        // U = 10, R = 5 split 12:45:10:22:8 by largest remainder → +1 intro, +2 results, +1 disc, +1 methods.
        #expect(items.map(\.minutes) == [5, 10, 15, 10, 10, 5, 5])
    }

    @Test func onlyResultsRow() {
        let s = Self.structure([.results], figures: [1, 2, 3], words: 3000)
        let (items, est) = ChecklistHeuristics.generate(structure: s, pageCount: 8)
        // 3000/130 + 9 = 32.1 → 30.
        #expect(est == 30)
        Self.assertWellFormed(items, est: est)
        #expect(items.count == 2)
        #expect(items[1].text == "Results: Figs 1–3 — one-line takeaway per figure")
        #expect(items[1].section == "Fig. 1")
        #expect(items[1].page == 1)
        #expect(items[1].minutes == 25)
    }

    @Test func resultsSectionWithoutFiguresFallsBackToMainText() {
        let s = Self.structure([.results], words: 2600)
        let (items, est) = ChecklistHeuristics.generate(structure: s, pageCount: nil)
        #expect(est == 20)
        Self.assertWellFormed(items, est: est)
        #expect(items.map(\.text) == ["Read abstract; skim all figure titles",
                                      "Read the main text end-to-end; note the main claim and key evidence"])
    }

    @Test func noSectionsAtAll() {
        let (items, est) = ChecklistHeuristics.generate(structure: DocumentStructure(), pageCount: nil)
        #expect(est == 15)
        Self.assertWellFormed(items, est: est)
        #expect(items.count == 2)
        #expect(items[0].minutes == 5 && items[0].page == 1 && items[0].kind == .overview)
        #expect(items[1].text == "Read the main text end-to-end; note the main claim and key evidence")
        #expect(items[1].section == nil && items[1].page == nil && items[1].kind == .other)
        #expect(items[1].minutes == 10)
    }

    @Test func fiveOrMoreFiguresSplitTheResultsRow() throws {
        let s = Self.structure([.results, .methods], figures: [1, 2, 3, 4, 5, 6, 7], words: 9100)
        let (items, est) = ChecklistHeuristics.generate(structure: s, pageCount: 30)
        // 9100/130 + 21 = 91 → 90.
        #expect(est == 90)
        Self.assertWellFormed(items, est: est)
        let figureRows = items.filter { $0.kind == .figure }
        #expect(figureRows.map(\.text) == ["Results: Figs 1–4 — one-line takeaway per figure",
                                           "Results: Figs 5–7 — one-line takeaway per figure"])
        #expect(figureRows.map(\.section) == ["Fig. 1", "Fig. 5"])
        #expect(figureRows.map(\.page) == [1, nil])
        // Equal 22.5 shares → equal minutes.
        try #require(figureRows.count > 1)          // no index past a failed expectation (QA-15)
        #expect(figureRows[0].minutes == figureRows[1].minutes)
    }

    @Test func exactlyFiveFiguresSplitAndFourDoNot() {
        let five = ChecklistHeuristics.generate(structure: Self.structure([], figures: [1, 2, 3, 4, 5]), pageCount: nil)
        #expect(five.items.filter { $0.kind == .figure }.count == 2)
        let four = ChecklistHeuristics.generate(structure: Self.structure([], figures: [1, 2, 3, 4]), pageCount: nil)
        #expect(four.items.filter { $0.kind == .figure }.count == 1)
    }

    @Test func singleFigureLabel() {
        let (items, _) = ChecklistHeuristics.generate(structure: Self.structure([], figures: [2]), pageCount: nil)
        #expect(items.contains { $0.text == "Results: Fig. 2 — one-line takeaway per figure" && $0.section == "Fig. 2" })
    }

    @Test func benchmarkVariantReplacesTheFigureRow() {
        let s = Self.structure([.introduction, .results], figures: [1, 2, 3, 4, 5, 6], words: 5000, benchmark: 5)
        let (items, est) = ChecklistHeuristics.generate(structure: s, pageCount: 12)
        Self.assertWellFormed(items, est: est)
        let figureRows = items.filter { $0.kind == .figure }
        #expect(figureRows.map(\.text) == ["Tables/Figs: list tasks, metrics and baselines"])
        #expect(figureRows.first?.section == "Fig. 1")

        let four = Self.structure([.results], figures: [1, 2], benchmark: 4)
        #expect(ChecklistHeuristics.generate(structure: four, pageCount: nil).items
            .contains { $0.text.hasPrefix("Results: Figs 1–2") })
    }

    @Test func estimateClampsToUpperBound() {
        let s = Self.structure([.introduction, .results, .methods], figures: Array(1...12), words: 60_000)
        let (items, est) = ChecklistHeuristics.generate(structure: s, pageCount: 49)
        #expect(est == 240)
        Self.assertWellFormed(items, est: est)
    }

    @Test func estimateClampsToLowerBoundAndRowFloor() {
        let lower = ChecklistHeuristics.generate(structure: Self.structure([.introduction], words: 200), pageCount: 3)
        #expect(lower.estMinutes == 15)
        Self.assertWellFormed(lower.items, est: lower.estMinutes)

        // Six weighted rows + two fixed rows need 40′ even though the text is tiny.
        let crowded = Self.structure([.introduction, .results, .discussion, .methods, .dataAvailability],
                                     figures: [1, 2, 3, 4, 5, 6], words: 100, ed: true)
        let (items, est) = ChecklistHeuristics.generate(structure: crowded, pageCount: 10)
        #expect(est == 40)
        Self.assertWellFormed(items, est: est)
        #expect(items.allSatisfy { $0.minutes == 5 })
    }

    @Test func figuresAreDedupedCappedAndSanitized() {
        let s = Self.structure([], figures: [0, -1, 3, 3, 1] + Array(20...40))
        let (items, est) = ChecklistHeuristics.generate(structure: s, pageCount: nil)
        // distinct positive, sorted, ≤12 → 1, 3, 20…29 → 12 figures → 36′ → 35.
        #expect(est == 35)
        Self.assertWellFormed(items, est: est)
        #expect(items.filter { $0.kind == .figure }.map(\.text) == [
            "Results: Figs 1–23 — one-line takeaway per figure",
            "Results: Figs 24–29 — one-line takeaway per figure",
        ])
    }

    @Test func pageCountFallbackWhenNoWordsExtracted() {
        let (_, scanned) = ChecklistHeuristics.generate(structure: DocumentStructure(), pageCount: 12)
        // 12 pages × 400 words / 130 = 36.9 → 35.
        #expect(scanned == 35)
        let (_, withWords) = ChecklistHeuristics.generate(structure: DocumentStructure(mainWordCount: 1300), pageCount: 12)
        #expect(withWords == 15)
    }

    @Test func pagesBeyondThePageCountAreDropped() {
        let s = DocumentStructure(sections: [SectionHit(kind: .methods, title: "Methods", page: 9),
                                             SectionHit(kind: .discussion, title: "Discussion", page: 0)])
        let (items, _) = ChecklistHeuristics.generate(structure: s, pageCount: 5)
        #expect(items.first { $0.kind == .method }?.page == nil)
        #expect(items.first { $0.kind == .discussion }?.page == nil)
        let (unreadable, _) = ChecklistHeuristics.generate(structure: DocumentStructure(), pageCount: 0)
        #expect(unreadable[0].page == nil)
    }

    @Test func alternativeSectionNames() {
        let s = Self.structure([.background, .conclusion, .codeAvailability], supp: true)
        let (items, est) = ChecklistHeuristics.generate(structure: s, pageCount: nil)
        Self.assertWellFormed(items, est: est)
        #expect(items.map(\.section) == ["Abstract", "Background", "Conclusion", "Supplementary", "Code availability"])
        #expect(items.map(\.page) == [1, 1, 2, nil, 3])
    }

    @Test func sumEqualsEstimateAcrossManyStructures() {
        var rng = SplitMix(seed: 0x5EED)
        let optional: [SectionKind] = [.introduction, .background, .results, .discussion, .conclusion, .methods,
                                       .extendedData, .supplementary, .dataAvailability, .codeAvailability]
        for _ in 0..<500 {
            let kinds = optional.filter { _ in rng.next() % 2 == 0 }
            let figures = (0..<Int(rng.next() % 15)).map { _ in Int(rng.next() % 16) }
            let s = Self.structure(kinds, figures: figures, words: Int(rng.next() % 40_000),
                                   ed: rng.next() % 4 == 0, supp: rng.next() % 4 == 0, benchmark: Int(rng.next() % 8))
            let pageCount: Int? = rng.next() % 3 == 0 ? nil : Int(rng.next() % 60)
            let (items, est) = ChecklistHeuristics.generate(structure: s, pageCount: pageCount)
            Self.assertWellFormed(items, est: est)
            #expect(est <= 240)
        }
    }

    @Test func largestRemainderHelper() {
        #expect(ChecklistHeuristics.largestRemainder(units: 5, weights: [24, 90, 20, 44, 16]) == [1, 2, 1, 1, 0])
        #expect(ChecklistHeuristics.largestRemainder(units: 3, weights: [0, 0, 0]) == [1, 1, 1])
        #expect(ChecklistHeuristics.largestRemainder(units: 0, weights: [1, 2]) == [0, 0])
        #expect(ChecklistHeuristics.largestRemainder(units: 7, weights: []) == [])
        #expect(ChecklistHeuristics.round5(62) == 60)
        #expect(ChecklistHeuristics.round5(62.5) == 65)
        #expect(ChecklistHeuristics.round5(.nan) == 0)
    }

    /// Deterministic generator so the property test never flakes.
    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
