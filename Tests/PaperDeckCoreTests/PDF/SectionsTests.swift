import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct SectionsTests {

    static func fixturePages(_ name: String) throws -> [String] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/pdf"))
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\u{0C}")
    }

    private static func kinds(_ s: DocumentStructure) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: s.sections.map { ($0.kind.rawValue, $0.page) })
    }

    // MARK: Fixture layouts

    @Test func natureLayout() throws {
        let s = Sections.analyze(pageTexts: try Self.fixturePages("nature_layout"), outline: nil)
        #expect(!s.sectionsFromOutline)
        #expect(Self.kinds(s) == ["discussion": 3, "methods": 4, "data_availability": 5, "code_availability": 5,
                                  "acknowledgements": 5, "extended_data": 6])
        #expect(s.sections.map(\.page) == s.sections.map(\.page).sorted())
        #expect(s.mainFigureNumbers == [1, 2, 3, 4, 5])
        #expect(s.hasExtendedData)
        #expect(s.hasSupplementary)
        #expect(s.benchmarkMentions == 1)
        // Main text = pages 1–3 up to the unheaded reference list.
        let pages = try Self.fixturePages("nature_layout")
        let before = pages[0] + "\n" + pages[1] + "\n" + pages[2].components(separatedBy: "1. 2. 3.")[0]
        #expect(s.mainWordCount == Sections.wordCount(before))
    }

    @Test func arxivLayout() throws {
        let s = Sections.analyze(pageTexts: try Self.fixturePages("arxiv_layout"), outline: nil)
        #expect(Self.kinds(s) == ["abstract": 1, "introduction": 1, "related_work": 2, "methods": 2, "experiments": 3,
                                  "conclusion": 3, "acknowledgements": 3, "references": 4])
        #expect(s.mainFigureNumbers == [1, 2, 3, 4])
        #expect(!s.hasExtendedData)
        #expect(s.benchmarkMentions >= 5)
        let pages = try Self.fixturePages("arxiv_layout")
        #expect(s.mainWordCount == Sections.wordCount(pages[0...2].joined(separator: "\n")))
    }

    @Test func cellLayoutAllCapsHeadings() throws {
        let s = Sections.analyze(pageTexts: try Self.fixturePages("cell_layout"), outline: nil)
        #expect(Self.kinds(s) == ["abstract": 1, "introduction": 1, "results": 2, "discussion": 2, "methods": 2,
                                  "acknowledgements": 3, "supplementary": 3, "references": 3])
        #expect(s.mainFigureNumbers == [1, 2, 3])
    }

    // MARK: Outline

    @Test func outlineWinsWithThreeSectionLikeEntries() throws {
        let pages = try Self.fixturePages("arxiv_layout")
        let outline: [(title: String, page: Int)] = [("1 Introduction", 1), ("NatureGym", 1), ("2 Related Work", 2),
                                                     ("4 Experiments", 3), ("Authors", 3)]
        let s = Sections.analyze(pageTexts: pages, outline: outline)
        #expect(s.sectionsFromOutline)
        // Outline kinds plus text-only kinds (abstract, references…), still in document order.
        #expect(s.sections.first?.kind == .abstract)
        #expect(s.page(of: .experiments) == 3)
        #expect(s.page(of: .references) == 4)
        #expect(s.sections.map(\.page) == s.sections.map(\.page).sorted())
    }

    @Test func outlineIgnoredWithFewSectionEntries() throws {
        let pages = try Self.fixturePages("nature_layout")
        let s = Sections.analyze(pageTexts: pages, outline: [("Synthetic dynamics of the developing test cortex", 1),
                                                            ("Discussion", 3)])
        #expect(!s.sectionsFromOutline)
        #expect(s.page(of: .methods) == 4)
    }

    // MARK: Heading classifier

    @Test(arguments: [
        ("Introduction", SectionKind.introduction), ("1 Introduction", .introduction), ("1. INTRODUCTION", .introduction),
        ("IV. Results and Discussion", .results), ("Materials and Methods", .methods), ("STAR★METHODS", .methods),
        ("Online Methods", .methods), ("Experimental Procedures", .methods), ("3 Method", .methods),
        ("Data and code availability", .dataAvailability), ("Code availability", .codeAvailability),
        ("Supplementary Information", .supplementary), ("Extended Data", .extendedData), ("Related Work", .relatedWork),
        ("Conclusions and Future Work", .conclusion), ("REFERENCES", .references), ("Bibliography", .references),
        ("ACKNOWLEDGMENTS", .acknowledgements), ("Acknowledgments:", .acknowledgements), ("Abstract", .abstract),
    ])
    func headings(line: String, kind: SectionKind) {
        #expect(Sections.classifyLine(line, page: 3)?.sectionKind == kind)
    }

    @Test(arguments: [
        "methods for select molecular species (e.g., immunohistochem-",   // lower-case sentence
        "results.",                                                         // wrapped last word
        "1 Introduction 3",                                                 // table of contents
        "3.2 Evaluation",                                                   // sub-section
        "Method", "Evaluation",                                             // table headers
        "Conclusion:",                                                      // label inside a figure
        "Methods 20, 1759–1768.",                                           // journal name in a reference
        "Data availability is a growing concern for reproducibility.",
    ])
    func notHeadings(line: String) {
        #expect(Sections.classifyLine(line, page: 3)?.sectionKind == nil)
    }

    @Test func summaryIsAbstractOnlyNearTheStart() {
        #expect(Sections.classifyLine("SUMMARY", page: 1) == .section(.abstract))
        #expect(Sections.classifyLine("Summary", page: 7) == nil)
    }

    @Test func runInHeadings() {
        #expect(Sections.classifyLine("Acknowledgements We thank the staff at the NIH NeuroBioBank.", page: 17) == .section(.acknowledgements))
        #expect(Sections.classifyLine("Author contributions Conceptualization: L.W., C.W.", page: 17) == .authorContributions)
        #expect(Sections.classifyLine("Conflicts of Interest: Princeton University has filed patents.", page: 24) == .competingInterests)
        #expect(Sections.classifyLine("Data Availability Statement: All data are in GEO.", page: 20) == .section(.dataAvailability))
        #expect(Sections.classifyLine("Abstract | We introduce NatureBench, a benchmark of 90 tasks", page: 1) == .section(.abstract))
        #expect(Sections.classifyLine("Funding agencies should require data sharing plans.", page: 4) == nil)
    }

    @Test func legendStarts() {
        #expect(Sections.classifyLine("Extended Data Fig. 1 | Filtering of the snMultiome data. a, UMAP", page: 18) == .extendedDataLegend)
        #expect(Sections.classifyLine("Extended Data Fig. 7b and Supplementary Table 7). EN-IT-immature", page: 4) == nil)
        #expect(Sections.classifyLine("Supplementary Figure 1. Split of questions by skills tested.", page: 9) == .supplementaryLegend)
        #expect(Sections.classifyLine("Figure S2: Accuracy by domain.", page: 9) == .supplementaryLegend)
    }

    // MARK: Figures

    @Test func figureNumberFalsePositives() {
        let text = """
            Cells expand (Fig. 1a,b; Figure 2) and migrate (Figs. 3–4). See Extended Data Fig. 7, Extended Data Figs. 8–9,
            Supplementary Fig. 10, Supplementary Figure 11, Fig. S12, SFig. 13 and Figure 2024 of the report.
            An unrelated Fig. 9 of ref. 12 is cited once. FIG. 5 shows panels.
            """
        #expect(Sections.mainFigureNumbers(in: text) == [1, 2, 3, 4, 5])
    }

    @Test func figureNumbersCapAtTwelve() {
        let text = (1...15).map { "Fig. \($0)" }.joined(separator: " ")
        #expect(Sections.mainFigureNumbers(in: text) == Array(1...12))
        #expect(Sections.mainFigureNumbers(in: "no figures here") == [])
        #expect(Sections.mainFigureNumbers(in: "Figure 7 and Figure 8 of another paper") == [])
    }

    @Test func emptyInput() {
        let s = Sections.analyze(pageTexts: [], outline: nil)
        #expect(s == DocumentStructure())
        #expect(Sections.analyze(pageTexts: ["", ""], outline: []).sections.isEmpty)
    }

    @Test func wordCount() {
        #expect(Sections.wordCount("Hello, world — 42 is a number 3.14") == 5)
        #expect(Sections.wordCount("") == 0)
    }
}
