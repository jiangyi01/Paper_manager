import Foundation
import Testing
@testable import PaperDeckCore

/// Export ▸ BibTeX / RIS / CSV / Markdown (READING_ASSIST_PLAN §9.1 C "Export": BibTeX keys,
/// escaping, RIS / CSV round trip). Metadata only.
@Suite struct ExportTests {
    typealias E = BatchExport.Entry

    static let wang = E(title: "Molecular and cellular dynamics of the developing human neocortex",
                        authors: ["Li Wang", "Arnold R. Kriegstein"], year: 2024, venue: "Nature",
                        doi: "10.1038/s41586-024-08351-7", abstract: "We map\nthe cortex.",
                        status: .reading, priority: .high, deadline: LocalDate(year: 2026, month: 10, day: 2),
                        category: "Neuro, development", tags: ["single-cell", "cortex"],
                        addedAt: Date(timeIntervalSince1970: 1_790_000_000))
    static let tricky = E(title: "C++ & R: 100% {new} $x_1$ #2 ~ ^ \\ \"quoted\", =SUM(A1)",
                          authors: ["Müller, Jörg", "王力"], year: 2023, arxivID: "2606.24530")

    @Test func bibtexKeysAreReadableAndUnique() {
        #expect(BatchExport.citeKey(Self.wang) == "Wang2024Molecular")
        #expect(BatchExport.citeKey(Self.tricky) == "Muller2023C")
        #expect(BatchExport.citeKey(E(title: "The 3D genome", authors: ["王力"], year: 2020)).hasPrefix("Wang")) // transliterated
        #expect(BatchExport.citeKey(E(title: "", authors: [])) == "paper")
        #expect(BatchExport.citeKey(E(title: "On the origin", authors: ["Darwin"], year: nil)) == "DarwinOrigin")
        let bib = BatchExport.bibtex([Self.wang, Self.wang, Self.wang])
        #expect(bib.contains("@article{Wang2024Molecular,") && bib.contains("@article{Wang2024Moleculara,")
                && bib.contains("@article{Wang2024Molecularb,"))
        #expect(BatchExport.bibtex([]) == "")
    }

    @Test func bibtexEscapesTheLatexSpecials() {
        let bib = BatchExport.bibtex([Self.tricky, Self.wang])
        #expect(bib.contains(##"title = {C++ \& R: 100\% \{new\} \$x\_1\$ \#2 \textasciitilde{} \textasciicircum{} \textbackslash{} "quoted", =SUM(A1)}"##))
        #expect(bib.contains("author = {Müller, Jörg and 王力}"))          // UTF-8 kept
        #expect(bib.contains("@misc{Muller2023C,") && bib.contains("eprint = {2606.24530}") && bib.contains("archiveprefix = {arXiv}"))
        #expect(bib.contains("url = {https://arxiv.org/abs/2606.24530}"))
        #expect(bib.contains("journal = {Nature}") && bib.contains("doi = {10.1038/s41586-024-08351-7}"))
        #expect(bib.contains("url = {https://doi.org/10.1038/s41586-024-08351-7}"))
        // Braces stay balanced, so no field can close the entry early.
        var depth = 0
        var escaped = false
        for ch in bib {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "{" { depth += 1 } else if ch == "}" { depth -= 1 }
            #expect(depth >= 0)
        }
        #expect(depth == 0)
        // Notes, cards and abstracts are never exported to BibTeX.
        #expect(!bib.contains("We map"))
    }

    @Test func risRoundTrips() {
        let text = BatchExport.ris([Self.wang, Self.tricky])
        #expect(text.hasPrefix("TY  - JOUR\r\n") && text.hasSuffix("ER  - \r\n"))
        let records = BatchExport.parseRIS(text)
        #expect(records.count == 2)
        #expect(records[0]["TI"] == [Self.wang.title])
        #expect(records[0]["AU"] == Self.wang.authors)
        #expect(records[0]["PY"] == ["2024"] && records[0]["JO"] == ["Nature"])
        #expect(records[0]["DO"] == [Self.wang.doi!])
        #expect(records[0]["AB"] == ["We map the cortex."])                   // one line
        #expect(records[0]["KW"] == ["single-cell", "cortex"])
        #expect(records[1]["TY"] == ["GEN"] && records[1]["TI"] == [Self.tricky.title])
        #expect(records[1]["AU"] == ["Müller, Jörg", "王力"])
        #expect(records[1]["UR"] == ["https://arxiv.org/abs/2606.24530"])
    }

    @Test func csvRoundTripsAndDefusesFormulas() {
        let text = BatchExport.csv([Self.wang, Self.tricky])
        let rows = BatchExport.parseCSV(text)
        #expect(rows.count == 3)
        #expect(rows[0] == BatchExport.csvHeader)
        #expect(rows[1] == [Self.wang.title, "Li Wang; Arnold R. Kriegstein", "2024", "Nature", "10.1038/s41586-024-08351-7",
                            "", "reading", "high", "2026-10-02", "Neuro, development", "single-cell; cortex",
                            "2026-09-21"])
        #expect(rows[2][0] == Self.tricky.title)                               // quotes and commas survive
        #expect(BatchExport.csvCell("=SUM(A1)") == "'=SUM(A1)")
        #expect(BatchExport.csvCell("+1") == "'+1" && BatchExport.csvCell("@x") == "'@x" && BatchExport.csvCell("-x") == "'-x")
        #expect(BatchExport.csvCell("a,b") == "\"a,b\"" && BatchExport.csvCell("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(BatchExport.csvCell("two\nlines") == "\"two\nlines\"" && BatchExport.csvCell("crlf\r\nx") == "\"crlf\r\nx\"")
        #expect(text.hasSuffix("\r\n"))
    }

    @Test func markdownListEscapesAndLinks() {
        let md = BatchExport.markdown([Self.wang, Self.tricky,
                                       E(title: "Five", authors: ["A A", "B B", "C C", "D D"], year: 2020)])
        let lines = md.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0] == "- **Molecular and cellular dynamics of the developing human neocortex** — Li Wang, Arnold R. Kriegstein (2024). *Nature*. [doi:10.1038/s41586-024-08351-7](https://doi.org/10.1038/s41586-024-08351-7)")
        #expect(lines[1].hasPrefix(##"- **C++ & R: 100% {new} $x\_1$ \#2 ~ ^ \\ "quoted", =SUM(A1)**"##))
        #expect(lines[1].hasSuffix("[arXiv:2606.24530](https://arxiv.org/abs/2606.24530)"))
        #expect(lines[2] == "- **Five** — A A, B B, C C, et al. (2020).")
    }

    @Test func entriesComeFromLibraryRowsWithoutSuppressedTags() {
        var paper = Paper(sha256: "x", fileSize: 1, ids: PaperIDs(doi: "10.1/x"), title: "T", authors: ["A B"], year: 2021,
                          folder: "Papers/x", pdfName: "x.pdf", originalName: "x.pdf", deadline: LocalDate(year: 2026, month: 1, day: 1),
                          scheduleMode: .none, notes: "private notes")
        paper.abstract = "abs"
        let row = PaperRow(paper: paper, checklist: [], tags: [Tag(name: "keep", origin: .user), Tag(name: "gone", origin: .suppressed)],
                           category: PaperCategory(name: "Cat", hue: 1, origin: .user, acknowledged: true, createdAt: Date()),
                           remainingMinutes: 0, doneCount: 0, totalCount: 0, atRisk: false, finish: nil, minutesToday: nil,
                           thumbnailURL: nil, pdfURL: URL(fileURLWithPath: "/tmp/x.pdf"))
        let e = BatchExport.Entry(row)
        #expect(e.tags == ["keep"] && e.category == "Cat" && e.doi == "10.1/x" && e.deadline == nil)
        for f in BatchExport.Format.allCases { #expect(!BatchExport.text([e], format: f).contains("private notes")) }
        #expect(BatchExport.Format.allCases.map(\.fileExtension) == ["bib", "ris", "csv", "md"])
    }
}
