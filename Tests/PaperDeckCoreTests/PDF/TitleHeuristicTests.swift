import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct TitleHeuristicTests {

    private typealias Run = TitleHeuristic.FontRun

    /// LABBench2's page 1: the rotated arXiv stamp is the largest run and must be skipped.
    @Test func skipsArxivStampAndKeepsTitle() {
        let runs = [
            Run(text: "arXiv:2604.09554v2 [cs.AI] 5 May 2026\n", pointSize: 20.0, top: 565),
            Run(text: "LABBench2\nAn Improved Benchmark for AI Systems Performing Biology Research\n", pointSize: 14.3, top: 701),
            Run(text: "Abstract\n", pointSize: 12.0, top: 574),
        ]
        #expect(TitleHeuristic.pick(runs: runs, pageHeight: 792)
                == "LABBench2 An Improved Benchmark for AI Systems Performing Biology Research")
    }

    /// Molecular Cell: the article-type label "Resource" was the largest font (23.9 pt).
    @Test func skipsArticleTypeLabel() {
        let runs = [
            Run(text: "Resource", pointSize: 23.9, top: 740),
            Run(text: "Global Mapping of the Yeast Genetic\nInteraction Network", pointSize: 19.9, top: 700),
        ]
        #expect(TitleHeuristic.pick(runs: runs, pageHeight: 783) == "Global Mapping of the Yeast Genetic Interaction Network")
    }

    @Test func ignoresRunsBelowTheTop65Percent() {
        let runs = [
            Run(text: "A Very Large Figure Caption In The Lower Half", pointSize: 30, top: 250),
            Run(text: "The Real Title of This Synthetic Paper", pointSize: 18, top: 700),
        ]
        #expect(TitleHeuristic.pick(runs: runs, pageHeight: 792) == "The Real Title of This Synthetic Paper")
        // Crop boxes need not start at zero: the cut-off is minY + 35% of the height (377.2 here).
        let title = [Run(text: "The Real Title of This Synthetic Paper", pointSize: 18, top: 370)]
        #expect(TitleHeuristic.pick(runs: title, pageMinY: 100, pageHeight: 792) == nil)
        #expect(TitleHeuristic.pick(runs: title, pageMinY: 0, pageHeight: 792) == "The Real Title of This Synthetic Paper")
    }

    @Test func unlocatedRunsAreSkipped() {
        #expect(TitleHeuristic.pick(runs: [Run(text: "A Title Without A Position", pointSize: 20, top: nil)], pageHeight: 792) == nil)
    }

    @Test func bioRxivLicenceLineIsBoilerplate() {
        let runs = [
            Run(text: "The copyright holder for this preprint this version posted September 28, 2025.", pointSize: 24, top: 780),
            Run(text: "BioML-bench: Evaluation of AI Agents for\nEnd-to-End Biomedical ML", pointSize: 17.2, top: 691),
        ]
        #expect(TitleHeuristic.pick(runs: runs, pageHeight: 792) == "BioML-bench: Evaluation of AI Agents for End-to-End Biomedical ML")
    }

    @Test(arguments: ["Article", "RESOURCE", "Research Article", "Brief Communication", "Open Access", "Letter",
                      "bioRxiv preprint doi: https://doi.org/10.1101/x", "© 2024 The Authors. Published by Elsevier",
                      "Received: 23 January 2025", "Accepted 10 June 2026", "https://example.org/paper", "arXiv:2606.24530v2"])
    func boilerplate(_ s: String) {
        #expect(TitleHeuristic.isBoilerplate(s))
    }

    @Test(arguments: ["Molecular and cellular dynamics of the developing human neocortex",
                      "A doing-it-right approach to review articles", "Reviewing the reports of research letters"])
    func notBoilerplate(_ s: String) {
        #expect(!TitleHeuristic.isBoilerplate(s))
    }

    @Test func plausibilityLimits() {
        #expect(!TitleHeuristic.isPlausibleTitle("Deep Learning"))                    // 2 words
        #expect(!TitleHeuristic.isPlausibleTitle("Too short"))
        #expect(TitleHeuristic.isPlausibleTitle("Deep Learning Works"))
        #expect(!TitleHeuristic.isPlausibleTitle(String(repeating: "word ", count: 61)))  // > 300 chars
        #expect(TitleHeuristic.isPlausibleTitle("单细胞空间转录组学的深度学习方法"))            // ≥ 6 CJK, no spaces
        #expect(!TitleHeuristic.isPlausibleTitle("12 34 56 78 90 11 12"))                // not letters
    }

    @Test func normalizeCollapsesWhitespace() {
        #expect(TitleHeuristic.normalize("  Single-\ncell  atlas\nof the\t brain*† ") == "Single-cell atlas of the brain")
        #expect(TitleHeuristic.normalize("How to build the virtual cell with artificial\nintelligence: Priorities")
                == "How to build the virtual cell with artificial intelligence: Priorities")
    }

    @Test(arguments: ["doi:10.1016/j.molcel.2007.09.027", "Untitled", "untitled document", "Microsoft Word - draft_v3.docx",
                      "Document1", "document", "main.tex", "paper_final.pdf", "manuscript.DOCX", "Short one",
                      "s41586-024-08351-7", "   "])
    func junkAttributeTitles(_ s: String) {
        #expect(TitleHeuristic.cleanAttributeTitle(s) == nil)
    }

    @Test func keepsRealAttributeTitles() {
        #expect(TitleHeuristic.cleanAttributeTitle("Documenting the human cell atlas") == "Documenting the human cell atlas")
        #expect(TitleHeuristic.cleanAttributeTitle("  Molecular and cellular dynamics\nof the developing human neocortex ")
                == "Molecular and cellular dynamics of the developing human neocortex")
        #expect(TitleHeuristic.cleanAttributeTitle(nil) == nil)
    }

    @Test func sameWordsIgnoresPunctuation() {
        #expect(TitleHeuristic.sameWords("LABBench2 An Improved Benchmark", "LABBench2: An improved benchmark"))
        #expect(!TitleHeuristic.sameWords("LABBench2 An Improved Benchmark", "LABBench3: An improved benchmark"))
        #expect(!TitleHeuristic.sameWords("", ""))
    }
}
