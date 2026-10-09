import AppKit
import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import PaperDeckCore

/// Serialized so the 35 MB timing check doesn't compete with the other extractions.
@Suite(.serialized) struct PDFExtractorTests {

    // MARK: Real papers (read-only dev fixtures; skipped when absent)

    static let fixtureDir = NSHomeDirectory() + "/Library/Caches/PaperDeck-dev/fixtures"
    static func fixture(_ name: String) -> URL { URL(fileURLWithPath: fixtureDir + "/" + name) }
    static func hasFixture(_ name: String) -> Bool { FileManager.default.fileExists(atPath: fixtureDir + "/" + name) }
    static let natureFile = "s41586-024-08351-7.pdf"
    static let preprintsFile = "Agentic_Laboratories_of_the_Future_Towards_World_Models_for_Scientific_Discoverypreprints202608.0213.v1.pdf"

    struct Expectation: Sendable, CustomTestStringConvertible {
        let file: String
        let pages: Int
        let ids: PaperIDs
        let title: String
        var testDescription: String { file }
    }

    static let expectations: [Expectation] = [
        .init(file: "1-s2.0-S0092867424013321-main.pdf", pages: 19,
              ids: PaperIDs(doi: "10.1016/j.cell.2024.11.015", pii: "S0092867424013321"),
              title: "How to build the virtual cell with artificial intelligence: Priorities and opportunities"),
        .init(file: "2025.09.01.673319.full.pdf", pages: 12, ids: PaperIDs(doi: "10.1101/2025.09.01.673319"),
              title: "BioML-bench: Evaluation of AI Agents for End-to-End Biomedical ML"),
        .init(file: "2026.02.27.708412.full.pdf", pages: 69, ids: PaperIDs(doi: "10.64898/2026.02.27.708412"),
              title: "Eubiota: Modular Agentic AI for Autonomous Discovery in the Gut Microbiome"),
        .init(file: "2026.04.06.716850.full.pdf", pages: 17, ids: PaperIDs(doi: "10.64898/2026.04.06.716850"),
              title: "Agentic systems are adept at solving well-scoped, verifiable problems in computational biology"),
        .init(file: "2604.09554v2.pdf", pages: 13, ids: PaperIDs(arxivID: "2604.09554", arxivVersion: 2),
              title: "LABBench2: An Improved Benchmark for AI Systems Performing Biology Research"),
        .init(file: "2606.24530v2.pdf", pages: 35, ids: PaperIDs(arxivID: "2606.24530", arxivVersion: 2),
              title: "NatureBench: Can Coding Agents Match the Published SOTA of Nature-Family Papers?"),
        .init(file: preprintsFile, pages: 28, ids: PaperIDs(doi: "10.20944/preprints202608.0213.v1"),
              title: "Agentic Laboratories of the Future: Towards World Models for Scientific Discovery"),
        // No id in the file name, but the publisher XMP carries the DOI.
        .init(file: "SpatialFormer.pdf", pages: 25, ids: PaperIDs(doi: "10.1038/s43588-026-01016-7"),
              title: "SpatialFormer: universal spatial representation learning from subcellular molecular to multicellular landscapes"),
        .init(file: natureFile, pages: 49, ids: PaperIDs(doi: "10.1038/s41586-024-08351-7"),
              title: "Molecular and cellular dynamics of the developing human neocortex"),
    ]

    /// Only the fixtures present on this machine; the test is skipped when there are none.
    static var presentExpectations: [Expectation] { expectations.filter { hasFixture($0.file) } }

    @Test(.enabled(if: !PDFExtractorTests.presentExpectations.isEmpty), arguments: presentExpectations)
    func realPaper(_ e: Expectation) async throws {
        let x = try await PDFExtractor().extract(url: Self.fixture(e.file), fileName: e.file)
        #expect(x.pageCount == e.pages)
        #expect(x.pageTexts.count == x.pageCount)
        #expect(x.charCount == x.pageTexts.reduce(0) { $0 + $1.count })
        #expect(!x.isScanned && !x.isLocked)
        #expect(x.ids == e.ids)
        #expect(x.fontTitle == e.title)
        #expect(x.bestLocalTitle?.1 == .font)
        let jpeg = try #require(x.cardThumbnailJPEG)
        #expect(jpeg.starts(with: [0xFF, 0xD8]))
        let rep = try #require(NSBitmapImageRep(data: jpeg))
        #expect(rep.pixelsWide == 560 && rep.pixelsHigh == 240)
    }

    @Test(.enabled(if: PDFExtractorTests.hasFixture(PDFExtractorTests.natureFile)))
    func nature35MBIsFastAndStructured() async throws {
        let start = ContinuousClock.now
        let x = try await PDFExtractor().extract(url: Self.fixture(Self.natureFile), fileName: Self.natureFile)
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(12), "took \(elapsed)")          // load-tolerant (ENV-1)
        let s = x.structure
        #expect(s.page(of: .discussion) == 9)
        #expect(s.page(of: .methods) == 11)
        #expect(s.page(of: .dataAvailability) == 17)
        #expect(s.page(of: .extendedData) == 18)
        #expect(s.mainFigureNumbers == [1, 2, 3, 4, 5])
        #expect(s.hasExtendedData && s.hasSupplementary)
        #expect((5_000...9_000).contains(s.mainWordCount))

        // The Nature layout: refs sit between main text and Methods and carry no heading.
        let p = TextPreparer.prepare(pageTexts: x.pageTexts, structure: s, budget: 120_000)
        #expect(p.text.contains("\nMethods\nBrain tissue samples\n"))
        #expect(p.text.contains("Data availability"))
        #expect(!p.text.contains("Molnár, Z. et al."))
        #expect(!p.text.contains("Wolock, S. L., Lopez, R."))
        #expect(!p.text.contains("We thank the staff at the NIH NeuroBioBank"))
        #expect(p.text.count <= 120_000)
    }

    @Test(.enabled(if: PDFExtractorTests.hasFixture("2025.09.01.673319.full.pdf")))
    func biorxivOutlineAndStampRemoval() async throws {
        let x = try await PDFExtractor().extract(url: Self.fixture("2025.09.01.673319.full.pdf"), fileName: "2025.09.01.673319.full.pdf")
        #expect(x.structure.sectionsFromOutline)
        #expect(x.structure.page(of: .methods) == 3)
        #expect(x.structure.page(of: .references) == 8)
        let p = TextPreparer.prepare(pageTexts: x.pageTexts, structure: x.structure, budget: 120_000)
        #expect(!p.text.contains("copyright holder for this preprint"))
        #expect(p.text.hasPrefix("[[p. 1]]\nBioML-bench: Evaluation of AI Agents for"))
        #expect(p.droppedSections.contains("references"))
    }

    @Test(.enabled(if: PDFExtractorTests.hasFixture("bad/fake.pdf")))
    func fakePDFIsRejected() async throws {
        await #expect(throws: PDFExtractor.ExtractError.notPDF) {
            try await PDFExtractor().extract(url: Self.fixture("bad/fake.pdf"), fileName: "fake.pdf")
        }
    }

    // MARK: Header sniffing and failures

    @Test func isPDFLooksAtTheFirstKilobyte() {
        #expect(PDFExtractor.isPDF(fileHead: Data("%PDF-1.7\n%âãÏÓ".utf8)))
        #expect(PDFExtractor.isPDF(fileHead: Data(repeating: 0x20, count: 500) + Data("%PDF-1.4".utf8)))
        #expect(!PDFExtractor.isPDF(fileHead: Data(repeating: 0x20, count: 1100) + Data("%PDF-1.4".utf8)))
        #expect(!PDFExtractor.isPDF(fileHead: Data("This is plain text pretending to be a PDF.\n".utf8)))
        #expect(!PDFExtractor.isPDF(fileHead: Data()))
    }

    @Test func missingAndBrokenFiles() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: PDFExtractor.ExtractError.self) {
            try await PDFExtractor().extract(url: dir.appendingPathComponent("nope.pdf"), fileName: "nope.pdf")
        }
        let broken = dir.appendingPathComponent("broken.pdf")
        try Data("%PDF-1.4\nthis is not really a pdf body\n%%EOF\n".utf8).write(to: broken)
        await #expect(throws: PDFExtractor.ExtractError.unreadable) {
            try await PDFExtractor().extract(url: broken, fileName: "broken.pdf")
        }
        let empty = dir.appendingPathComponent("empty.pdf")
        try Data().write(to: empty)
        await #expect(throws: PDFExtractor.ExtractError.notPDF) {
            try await PDFExtractor().extract(url: empty, fileName: "empty.pdf")
        }
    }

    // MARK: Generated PDFs (always run)

    private static let body = String(repeating: "Cortical progenitors divide and differentiate into neurons over development. ", count: 4)

    private static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-pdf-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Draws (text, point size) lines top-down on US-Letter pages with CoreText.
    private static func makePDF(_ url: URL, pages: [[(String, CGFloat)]], auxiliary: [CFString: Any] = [:]) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, auxiliary as CFDictionary))
        for page in pages {
            ctx.beginPDFPage(nil)
            var y: CGFloat = 730
            for (text, size) in page {
                let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
                ctx.textPosition = CGPoint(x: 54, y: y)
                CTLineDraw(line, ctx)
                y -= size * 1.8
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private static let paperPages: [[(String, CGFloat)]] = [
        [("A Generated Paper About Cortical Development", 24), ("Ada Lovelace and Grace Hopper", 11),
         ("arXiv:2606.24530v2 [cs.CL] 6 Jul 2026", 9), ("Abstract", 12)]
            + (0..<4).map { _ in (body.prefix(90).description, 10) },
        [("1 Introduction", 12)] + (0..<4).map { _ in (body.prefix(90).description, 10) } + [("As shown in Figure 1 and Figure 2.", 10)],
        [("2 Results", 12)] + (0..<4).map { _ in (body.prefix(90).description, 10) } + [("References", 12)],
    ]

    @Test func generatedPaper() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("generated.pdf")
        try Self.makePDF(url, pages: Self.paperPages)
        let x = try await PDFExtractor().extract(url: url, fileName: "generated.pdf")
        #expect(x.pageCount == 3)
        #expect(x.fontTitle == "A Generated Paper About Cortical Development")
        #expect(x.ids == PaperIDs(arxivID: "2606.24530", arxivVersion: 2))
        #expect(!x.isEncrypted && !x.isLocked && !x.isScanned)
        #expect(x.structure.page(of: .abstract) == 1)
        #expect(x.structure.page(of: .introduction) == 2)
        #expect(x.structure.page(of: .results) == 3)
        #expect(x.structure.mainFigureNumbers == [1, 2])
        let jpeg = try #require(x.cardThumbnailJPEG)
        let rep = try #require(NSBitmapImageRep(data: jpeg))
        #expect(rep.pixelsWide == 560 && rep.pixelsHigh == 240)
    }

    @Test func fileNameIdentifiersWin() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s41586-024-08351-7.pdf")
        try Self.makePDF(url, pages: [[("Molecular and cellular dynamics of the developing human neocortex", 20), (Self.body, 9)]])
        let x = try await PDFExtractor().extract(url: url, fileName: "s41586-024-08351-7.pdf")
        #expect(x.ids.doi == "10.1038/s41586-024-08351-7")
    }

    @Test func passwordProtectedPDFComesBackLocked() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("2604.09554v2.pdf")
        try Self.makePDF(url, pages: Self.paperPages,
                         auxiliary: [kCGPDFContextUserPassword: "secret", kCGPDFContextOwnerPassword: "owner"])
        let x = try await PDFExtractor().extract(url: url, fileName: "2604.09554v2.pdf")
        #expect(x.isEncrypted && x.isLocked)
        #expect(x.pageTexts.isEmpty && x.charCount == 0 && x.fontTitle == nil && x.cardThumbnailJPEG == nil)
        #expect(x.ids == PaperIDs(arxivID: "2604.09554", arxivVersion: 2))     // the file name still identifies it
    }

    /// Owner-password-only files open with the empty user password: encrypted but readable.
    @Test func ownerPasswordOnlyIsReadable() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("owner.pdf")
        try Self.makePDF(url, pages: Self.paperPages, auxiliary: [kCGPDFContextOwnerPassword: "owner", kCGPDFContextUserPassword: ""])
        let x = try await PDFExtractor().extract(url: url, fileName: "owner.pdf")
        #expect(x.isEncrypted)
        #expect(!x.isLocked)
        #expect(x.fontTitle == "A Generated Paper About Cortical Development")
    }

    @Test func sparseTextIsScanned() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("scan.pdf")
        try Self.makePDF(url, pages: [[("Scan 1", 10)], [("Scan 2", 10)]])
        let x = try await PDFExtractor().extract(url: url, fileName: "scan.pdf")
        #expect(x.pageCount == 2)
        #expect(x.isScanned)
        #expect(x.fontTitle == nil)
    }

    @Test func junkTitleAttributeIsFiltered() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let junk = dir.appendingPathComponent("junk.pdf")
        try Self.makePDF(junk, pages: Self.paperPages, auxiliary: [kCGPDFContextTitle: "Microsoft Word - draft_v3.docx"])
        #expect(try await PDFExtractor().extract(url: junk, fileName: "junk.pdf").attributeTitle == nil)
        let doiTitle = dir.appendingPathComponent("doi.pdf")
        try Self.makePDF(doiTitle, pages: [[("Short", 10)]], auxiliary: [kCGPDFContextTitle: "doi:10.1016/j.molcel.2007.09.027"])
        let x = try await PDFExtractor().extract(url: doiTitle, fileName: "doi.pdf")
        #expect(x.attributeTitle == nil)
        #expect(x.ids.doi == "10.1016/j.molcel.2007.09.027")
    }
}
