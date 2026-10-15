import Foundation
import Testing
@testable import PaperDeckCore

/// Export fixes: the CSV `added` day is local, not UTC (dedupe-batch-5); BibTeX writes `doi` and
/// `eprint` verbatim like `url` (dedupe-batch-6); a saved CSV file starts with a UTF-8 BOM, nothing
/// else does (dedupe-batch-8).
@Suite struct ExportFixesTests {
    static func zone(_ id: String) -> Calendar { LocalDate.gregorian(TimeZone(identifier: id)!) }

    static func addedCell(_ entry: BatchExport.Entry, _ calendar: Calendar) throws -> String {
        let rows = BatchExport.parseCSV(BatchExport.text([entry], format: .csv, calendar: calendar))
        let i = try #require(BatchExport.csvHeader.firstIndex(of: "added"))
        return try #require(rows.dropFirst().first)[i]
    }

    @Test func csvAddedIsTheLocalDayNearMidnight() throws {
        let shanghai = Self.zone("Asia/Shanghai"), chicago = Self.zone("America/Chicago")
        // 07:30 on 22 Sep in Shanghai is still 21 Sep in UTC.
        let morning = LocalDate(year: 2026, month: 9, day: 22).date(hour: 7, minute: 30, calendar: shanghai)
        #expect(try Self.addedCell(BatchExport.Entry(title: "T", addedAt: morning), shanghai) == "2026-09-22")
        // 20:00 on 21 Sep in Chicago is already 22 Sep in UTC.
        let evening = LocalDate(year: 2026, month: 9, day: 21).date(hour: 20, minute: 0, calendar: chicago)
        #expect(try Self.addedCell(BatchExport.Entry(title: "T", addedAt: evening), chicago) == "2026-09-21")
        // The deadline column is the same kind of day.
        let row = BatchExport.csv([BatchExport.Entry(title: "T", deadline: LocalDate(year: 2026, month: 9, day: 21),
                                                     addedAt: evening)], calendar: chicago)
        #expect(row.contains(",2026-09-21,,,2026-09-21\r\n"))
    }

    @Test func bibtexKeepsDOIAndEprintVerbatim() {
        let e = BatchExport.Entry(title: "U-Net: Convolutional Networks for Biomedical Image Segmentation",
                                  authors: ["Jane Doe"], year: 2015, venue: "MICCAI",
                                  doi: "10.1007/978-3-319-24574-4_28", arxivID: "1505.04597")
        let bib = BatchExport.bibtex([e])
        #expect(bib.contains("doi = {10.1007/978-3-319-24574-4_28}"))
        #expect(!bib.contains("4\\_28"))
        #expect(bib.contains("eprint = {1505.04597}"))
        #expect(bib.contains("url = {https://doi.org/10.1007/978-3-319-24574-4_28}"))
        // Braces still can't break the field.
        let odd = BatchExport.bibtex([BatchExport.Entry(title: "T", doi: "10.1/a{b}")])
        #expect(odd.contains("doi = {10.1/a%7Bb%7D}"))
        // Titles keep their LaTeX escaping.
        #expect(BatchExport.bibtex([BatchExport.Entry(title: "A_B")]).contains("title = {A\\_B}"))
    }

    @Test func onlyASavedCSVFileGetsAByteOrderMark() {
        let text = "title\r\n王力\r\n"
        let csv = BatchExport.fileData(text, format: .csv)
        #expect(Array(csv.prefix(3)) == [0xEF, 0xBB, 0xBF])
        #expect(csv.dropFirst(3) == Data(text.utf8))
        for f in [BatchExport.Format.bibtex, .ris, .markdown] {
            #expect(BatchExport.fileData(text, format: f) == Data(text.utf8), "\(f)")
        }
        // The clipboard copy is the text itself (no BOM in `text`).
        #expect(!BatchExport.text([BatchExport.Entry(title: "王力")], format: .csv).hasPrefix("\u{FEFF}"))
    }
}
