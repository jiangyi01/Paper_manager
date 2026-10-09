import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct ChecklistMergerTests {
    private static let ticked = Date(timeIntervalSince1970: 1_790_000_000)

    private static func item(_ text: String, ord: Double, minutes: Int = 10, origin: ItemOrigin = .heuristic,
                             edited: Bool = false, done: Bool = false) -> ChecklistItem {
        ChecklistItem(ord: ord, text: text, minutes: minutes, origin: origin, userEdited: edited,
                      doneAt: done ? ticked : nil)
    }

    private static func step(_ task: String, minutes: Int, section: String? = nil, page: Int? = nil,
                             kind: ChecklistKind = .other) -> ReadingCard.Step {
        ReadingCard.Step(task: task, section: section, page: page, minutes: minutes, kind: kind)
    }

    private static let heuristicPlan = ChecklistHeuristics.generate(
        structure: DocumentStructure(sections: [SectionHit(kind: .results, title: "Results", page: 2)],
                                     mainFigureNumbers: [1, 2, 3], mainWordCount: 5000),
        pageCount: 10).items

    private static let agentSteps = [
        step("Abstract + Fig. 1: note the atlas scope and the 4 sampled stages", minutes: 10, section: "Fig. 1", page: 2,
             kind: .overview),
        step("Figure 2 — compare cell-type proportions across stages", minutes: 20, section: "Fig. 2", page: 5,
             kind: .figure),
        step("Methods – Statistics: DEG test and FDR cutoff", minutes: 15, section: "Methods: Statistics", page: 14,
             kind: .stats),
        step("Data availability: note the GEO accession", minutes: 5, section: "Data availability", page: 20,
             kind: .data),
    ]

    @Test func untouchedChecklistIsReplacedWholesale() {
        let merged = ChecklistMerger.merge(existing: Self.heuristicPlan, agentSteps: Self.agentSteps, est: 50)
        #expect(merged.map(\.text) == Self.agentSteps.map(\.task))
        #expect(merged.map(\.section) == Self.agentSteps.map(\.section))
        #expect(merged.map(\.page) == Self.agentSteps.map(\.page))
        #expect(merged.map(\.kind) == Self.agentSteps.map(\.kind))
        #expect(merged.allSatisfy { $0.origin == .agent && !$0.userEdited && $0.doneAt == nil })
        #expect(merged.map(\.ord) == [0, 1, 2, 3])
        #expect(merged.map(\.minutes) == [10, 20, 15, 5])
        #expect(Set(merged.map(\.id)).isDisjoint(with: Self.heuristicPlan.map(\.id)))
    }

    @Test func tickedAndUserItemsKeepTheirPositionAndText() {
        let existing = [
            Self.item("Read abstract; skim all figure titles", ord: 0, minutes: 5, done: true),
            Self.item("Results: Figs 1–3 — one-line takeaway per figure", ord: 1, minutes: 25),
            Self.item("Check how they define radial glia subtypes", ord: 2, minutes: 7, origin: .user),
            Self.item("Methods: look at the clustering resolution", ord: 3, minutes: 10, origin: .agent, edited: true),
            Self.item("Discussion: note stated limitations and future work", ord: 4, minutes: 10),
        ]
        let merged = ChecklistMerger.merge(existing: existing, agentSteps: Self.agentSteps, est: 60)
        let kept = [existing[0], existing[2], existing[3]]
        #expect(Array(merged.prefix(3)).map(\.id) == kept.map(\.id))
        #expect(Array(merged.prefix(3)).map(\.text) == kept.map(\.text))
        #expect(Array(merged.prefix(3)).map(\.minutes) == kept.map(\.minutes))
        #expect(merged[0].doneAt == Self.ticked)
        #expect(merged[1].origin == .user && merged[2].userEdited)
        #expect(merged.dropFirst(3).map(\.text) == Self.agentSteps.map(\.task))
        #expect(!merged.contains { $0.id == existing[1].id || $0.id == existing[4].id })
        #expect(merged.map(\.ord) == merged.indices.map(Double.init))
    }

    @Test func existingOrderIsTakenFromOrdNotArrayOrder() {
        let a = Self.item("User step A", ord: 2.5, origin: .user)
        let b = Self.item("User step B", ord: 0.5, origin: .user)
        let merged = ChecklistMerger.merge(existing: [a, b], agentSteps: [Self.step("Agent step", minutes: 10)], est: 30)
        #expect(merged.map(\.text) == ["User step B", "User step A", "Agent step"])
    }

    @Test func figureSpellingsAreDeduplicated() {
        let existing = [Self.item("Fig. 2: compare cell type proportions across the stages", ord: 0, origin: .user)]
        let merged = ChecklistMerger.merge(existing: existing, agentSteps: Self.agentSteps, est: 60)
        #expect(merged.count == 4)
        #expect(merged[0].id == existing[0].id)
        #expect(!merged.contains { $0.text.hasPrefix("Figure 2") })
    }

    @Test func normalization() {
        for text in ["Figure 2", "fig.2", "Fig. 2", "FIGS 2", "figure  2", "Fig 2"] {
            #expect(ChecklistMerger.norm(text) == "fig2", "\(text)")
        }
        #expect(ChecklistMerger.norm("Supplementary Figure S3") == "supplementary figs3")
        #expect(ChecklistMerger.norm("Extended Data Fig. 4b: the UMAP") == "extended data fig4b umap")
        #expect(ChecklistMerger.norm("Configure 2 things") == "configure 2 things")
        #expect(ChecklistMerger.norm("Read abstract; skim all figure titles") == "read abstract skim figure titles")
        #expect(ChecklistMerger.norm("Fig. 2: compare cell-type proportions")
                == ChecklistMerger.norm("Figure 2 — Compare the cell type proportions."))
    }

    @Test func agentMinutesAreScaledToTheRemainingEstimate() {
        let existing = [
            Self.item("Done step", ord: 0, minutes: 15, done: true),          // ticked → not counted
            Self.item("My own step", ord: 1, minutes: 10, origin: .user),     // unchecked → counted
        ]
        let steps = [Self.step("One", minutes: 10), Self.step("Two", minutes: 20), Self.step("Three", minutes: 30)]
        let merged = ChecklistMerger.merge(existing: existing, agentSteps: steps, est: 60)
        let agent = merged.filter { $0.origin == .agent }
        // target 50 over 10:20:30 → 8.3/16.7/25 → units 1.67/3.33/5 → 2/3/5 by largest remainder.
        #expect(agent.map(\.minutes) == [10, 15, 25])
        let unchecked = merged.filter { !$0.isDone }.reduce(0) { $0 + $1.minutes }
        #expect(unchecked == 60)
    }

    @Test func targetThatIsNotAMultipleOfFiveRoundsToUnits() {
        let existing = [Self.item("Odd user step", ord: 0, minutes: 7, origin: .user)]
        let steps = [Self.step("One", minutes: 30), Self.step("Two", minutes: 30)]
        let merged = ChecklistMerger.merge(existing: existing, agentSteps: steps, est: 60)
        // target 53 → 11 units → 6/5 (tie → earlier index).
        #expect(merged.filter { $0.origin == .agent }.map(\.minutes) == [30, 25])
    }

    @Test func everyAgentItemGetsAtLeastFiveMinutes() {
        let existing = [Self.item("Long user step", ord: 0, minutes: 40, origin: .user)]
        let steps = [Self.step("Tiny", minutes: 2), Self.step("Huge", minutes: 90), Self.step("Mid", minutes: 10)]
        let exhausted = ChecklistMerger.merge(existing: existing, agentSteps: steps, est: 30)
        #expect(exhausted.filter { $0.origin == .agent }.map(\.minutes) == [5, 5, 5])

        let skewed = ChecklistMerger.merge(existing: [], agentSteps: steps, est: 30)
        // 6 units over 2:90:10 → 0/5/1 → floor lifts "Tiny" to 1, paid by "Huge".
        #expect(skewed.map(\.minutes) == [5, 20, 5])
        #expect(skewed.reduce(0) { $0 + $1.minutes } == 30)
    }

    @Test func wholesaleReplacementSumsToEstimate() {
        let steps = [Self.step("A", minutes: 13), Self.step("B", minutes: 27), Self.step("C", minutes: 41),
                     Self.step("D", minutes: 9), Self.step("E", minutes: 22)]
        for est in stride(from: 25, through: 480, by: 5) {
            let merged = ChecklistMerger.merge(existing: Self.heuristicPlan, agentSteps: steps, est: est)
            #expect(merged.reduce(0) { $0 + $1.minutes } == est, "est \(est)")
            #expect(merged.allSatisfy { $0.minutes >= 5 && $0.minutes % 5 == 0 })
        }
    }

    @Test func zeroAgentMinutesSplitEvenly() {
        let steps = [Self.step("A", minutes: 0), Self.step("B", minutes: 0)]
        #expect(ChecklistMerger.merge(existing: [], agentSteps: steps, est: 20).map(\.minutes) == [10, 10])
    }

    @Test func emptyAgentChecklistKeepsExistingItems() {
        let merged = ChecklistMerger.merge(existing: Self.heuristicPlan, agentSteps: [Self.step("  ", minutes: 5)], est: 60)
        #expect(merged.map(\.id) == Self.heuristicPlan.map(\.id))
        #expect(merged.map(\.minutes) == Self.heuristicPlan.map(\.minutes))
    }

    @Test func agentTextIsTrimmed() {
        let merged = ChecklistMerger.merge(existing: [], agentSteps: [Self.step("  Fig. 3: read it \n", minutes: 10)], est: 10)
        #expect(merged.map(\.text) == ["Fig. 3: read it"])
    }

    @Test func statusFlow() {
        let open = [Self.item("a", ord: 0), Self.item("b", ord: 1)]
        let one = [Self.item("a", ord: 0, done: true), Self.item("b", ord: 1)]
        let all = [Self.item("a", ord: 0, done: true), Self.item("b", ord: 1, done: true)]

        #expect(ChecklistMerger.statusAfterToggle(current: .toRead, items: one, autoDone: true) == .reading)
        #expect(ChecklistMerger.statusAfterToggle(current: .toRead, items: open, autoDone: true) == .toRead)
        #expect(ChecklistMerger.statusAfterToggle(current: .reading, items: all, autoDone: true) == .done)
        #expect(ChecklistMerger.statusAfterToggle(current: .toRead, items: all, autoDone: true) == .done)
        #expect(ChecklistMerger.statusAfterToggle(current: .reading, items: all, autoDone: false) == .reading)
        #expect(ChecklistMerger.statusAfterToggle(current: .reading, items: open, autoDone: true) == .reading)
        #expect(ChecklistMerger.statusAfterToggle(current: .done, items: one, autoDone: true) == .reading)
        #expect(ChecklistMerger.statusAfterToggle(current: .done, items: one, autoDone: false) == .reading)
        #expect(ChecklistMerger.statusAfterToggle(current: .done, items: all, autoDone: false) == .done)
        // Marked done by hand, then a leftover item is ticked: stays done.
        #expect(ChecklistMerger.statusAfterToggle(current: .done, items: one, autoDone: true, ticked: true) == .done)
        #expect(ChecklistMerger.statusAfterToggle(current: .done, items: open, autoDone: true, ticked: false) == .reading)
        #expect(ChecklistMerger.statusAfterToggle(current: .done, items: [], autoDone: true) == .done)
    }

    @Test func touchedPredicate() {
        #expect(ChecklistMerger.isTouched(Self.item("x", ord: 0, origin: .user)))
        #expect(ChecklistMerger.isTouched(Self.item("x", ord: 0, edited: true)))
        #expect(ChecklistMerger.isTouched(Self.item("x", ord: 0, done: true)))
        #expect(!ChecklistMerger.isTouched(Self.item("x", ord: 0, origin: .agent)))
    }
}
