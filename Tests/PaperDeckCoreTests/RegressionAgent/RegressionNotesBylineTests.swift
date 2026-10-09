import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct RegressionNotesBylineTests {
    private static func sidecar(doi: String?, venue: String?) -> CardSidecar {
        var paper = Paper(sha256: "ab", fileSize: 1, title: "BioML-bench", folder: "Papers/x", pdfName: "x.pdf", originalName: "x.pdf")
        paper.ids = PaperIDs(doi: doi)
        paper.venue = venue
        paper.year = 2025
        paper.authors = ["H. E. Miller"]
        return CardSidecar(paper: paper, checklist: [], categoryName: nil, tags: [], aiProvider: nil, aiModel: nil)
    }

    @Test func doiInTheBylineIsNotEscaped() {
        let md = SidecarWriter.notesMarkdown(for: Self.sidecar(doi: "10.1101/2025.09.01.673319", venue: "bioRxiv"))
        #expect(md.contains("H. E. Miller · bioRxiv · 2025 · doi:10.1101/2025.09.01.673319"))
        #expect(!md.contains("10\\.1101"))
    }

    @Test func bylineStartingLikeAListIsStillNeutralized() {
        let md = SidecarWriter.notesMarkdown(for: CardSidecar(
            paper: Paper(sha256: "cd", fileSize: 1, title: "T", authors: ["1. Evil"], folder: "Papers/y", pdfName: "y.pdf", originalName: "y.pdf"),
            checklist: [], categoryName: nil, tags: [], aiProvider: nil, aiModel: nil))
        #expect(md.contains("1\\. Evil"))
    }
}
