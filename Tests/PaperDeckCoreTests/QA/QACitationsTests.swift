import Foundation
import Testing
@testable import PaperDeckCore

/// Citation markers in answers (READING_ASSIST_PLAN §9.1 C "Citations regex and invalid pages"):
/// the forms models write, what is not a citation, validity against the thread's papers, the chip
/// text, notes text, the inline links, and the locally chosen supporting sentence.
@Suite struct QACitationsTests {
    static func cites(_ text: String, _ counts: [Int?] = [12]) -> [QACitation] {
        QACitations.parse(text, pageCounts: counts)
    }

    @Test(arguments: [
        ("The effect holds [p. 7].", [QACitation(page: 7)]),
        ("Holds [[p. 7]].", [QACitation(page: 7)]),
        ("Holds [p.7] and [page 3].", [QACitation(page: 7), QACitation(page: 3)]),
        ("Range [pp. 7–9].", [QACitation(page: 7, endPage: 9)]),
        ("Range [pp. 7-9].", [QACitation(page: 7, endPage: 9)]),
        ("List [pp. 3, 7].", [QACitation(page: 3), QACitation(page: 7)]),
        ("Two [p. 3; p. 9].", [QACitation(page: 3), QACitation(page: 9)]),
        ("中文 [第 7 页]。", [QACitation(page: 7)]),
        ("中文 [第7页]。", [QACitation(page: 7)]),
        ("Pages [P. 4]", [QACitation(page: 4)]),
    ])
    func singlePaperForms(_ text: String, _ expected: [QACitation]) {
        #expect(Self.cites(text) == expected, "\(text)")
    }

    @Test func multiPaperForms() {
        let counts: [Int?] = [10, 20, 5]
        #expect(Self.cites("A [P2 p. 5].", counts) == [QACitation(paper: 2, page: 5)])
        #expect(Self.cites("A [P2 · p. 5].", counts) == [QACitation(paper: 2, page: 5)])
        #expect(Self.cites("A [P2, p. 5].", counts) == [QACitation(paper: 2, page: 5)])
        #expect(Self.cites("A [P3: pp. 2–4].", counts) == [QACitation(paper: 3, page: 2, endPage: 4)])
        #expect(Self.cites("A [P1 p. 3; P2 p. 5].", counts) == [QACitation(paper: 1, page: 3), QACitation(paper: 2, page: 5)])
        #expect(Self.cites("A [P1 p. 3, P2 p. 5].", counts) == [QACitation(paper: 1, page: 3), QACitation(paper: 2, page: 5)])
        #expect(Self.cites("Only the card says so [P2].", counts) == [QACitation(paper: 2, page: nil)])
    }

    @Test(arguments: ["See [1].", "- [x] done", "- [ ] todo", "[see Fig. 2]", "a [link](https://x.org)", "[p.]",
                      "[pp. ]", "[P2 something]", "[page seven]", "[p. 3 and more words]", "[]", "[P2.5]"])
    func notCitations(_ text: String) {
        #expect(Self.cites(text, [12, 12]).isEmpty, "\(text)")
    }

    @Test func validityFollowsThePagesAndPapers() {
        let counts: [Int?] = [12, nil]
        let parsed = Self.cites("[P1 p. 12] [P1 p. 13] [P1 p. 0] [P3 p. 1] [P2 p. 400] [P1 pp. 11–14] [P2]", counts)
        #expect(parsed.map(\.valid) == [true, false, false, false, true, false, true])
        // Among several papers a citation without a label names none of them (Phase 2 fix QA-7).
        #expect(Self.cites("[p. 12]", counts).map(\.problem) == [.ambiguous])
        // A single-paper thread: P1 is the paper, P2 doesn't exist.
        #expect(Self.cites("[P1 p. 2] [P2 p. 2]").map(\.valid) == [true, false])
        // A range written backwards keeps its first page.
        #expect(Self.cites("[pp. 9–7]") == [QACitation(page: 9)])
    }

    @Test func chipsNotesAndLinks() {
        #expect(QACitations.display(QACitation(page: 7), multi: false) == "p. 7")
        #expect(QACitations.display(QACitation(page: 7, endPage: 9), multi: false) == "pp. 7–9")
        #expect(QACitations.display(QACitation(paper: 2, page: 5), multi: true) == "P2 · p. 5")
        #expect(QACitations.display(QACitation(paper: 2, page: nil), multi: true) == "P2")
        let text = "Bigger [p. 3]. Also [[p. 4]] and [P2 p. 1; P1 p. 2]."
        #expect(QACitations.plain(text, multi: false) == "Bigger (p. 3). Also (p. 4) and (p. 1; p. 2).")
        #expect(QACitations.plain("X [P2 p. 1].", multi: true) == "X (P2 · p. 1).")
        let linked = QACitations.linkedMarkdown(text, multi: false)
        #expect(linked == "Bigger [p. 3](paperdeck-cite://0). Also [p. 4](paperdeck-cite://1) and [p. 1; p. 2](paperdeck-cite://2).")
        // The tokens' order is the link index.
        #expect(QACitations.tokens(in: text).count == 3)
    }

    @Test func aMarkerSplitAcrossDeltasParsesOnceTheTextIsWhole() {
        let first = "The model reaches 92.3% accuracy [p"
        #expect(Self.cites(first).isEmpty)
        #expect(Self.cites(first + ". 7].") == [QACitation(page: 7)])
    }

    @Test func theSupportingSentenceIsChosenLocally() {
        let page7 = """
        We trained the network on 40 cohorts.
        The classifier reaches 92.3% accuracy on the held-out cohort of tumour biopsies, outperforming
        pathologists. Training took two days.
        """
        let page8 = "Unrelated text about reagents and suppliers listed in the methods section."
        let answer = "The classifier reaches 92.3% accuracy on held-out tumour biopsies [p. 7]. It also mentions reagents [p. 8]. "
            + "Yes [p. 7]."
        let cites = QACitations.attachQuotes(answer, pageCounts: [12]) { paper, page in
            paper == 1 ? [7: page7, 8: page8][page] : nil
        }
        #expect(cites.count == 3)
        #expect(cites[0].quoteFound == true)
        #expect(cites[0].quote?.hasPrefix("The classifier reaches 92.3% accuracy") == true)
        // Page 8 doesn't support "It also mentions reagents" strongly enough: two words would be
        // needed of a claim this short — "mentions" isn't there, "reagents" is.
        #expect(cites[1].quoteFound == false && cites[1].quote == nil)
        // "Yes [p. 7]." alone has no content words: the sentence before it counts.
        #expect(cites[2].quoteFound != nil)
    }

    @Test func noPageTextOrAnInvalidPageIsNotChecked() {
        let cites = QACitations.attachQuotes("The classifier reaches high accuracy [p. 7]. Wrong [p. 40].",
                                             pageCounts: [12]) { _, _ in nil }
        #expect(cites.map(\.quoteFound) == [nil, nil])
        #expect(cites.map(\.valid) == [true, false])
    }

    @Test func sentencesDoNotSplitInsideNumbers() {
        let s = QACitations.sentences("Accuracy was 92.3 percent overall. The second sentence is here!")
        #expect(s == ["Accuracy was 92.3 percent overall.", "The second sentence is here!"])
    }
}
