import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import PaperDeckCore

/// The reader's PDFKit side on the synthetic fixture (six pages: "i", "ii", then printed 1201–1204;
/// the sample quote broken across two lines on page 3; a grey figure on page 4).
@Suite("Reader: PDF fixture, labels, quote finder, region render")
struct ReaderPDFTests {
    static func sample() throws -> PDFDocument {
        try #require(PDFDocument(data: ReaderFixturePDF.sample()))
    }

    /// The red channel of the image's centre pixel.
    static func centerRed(_ cg: CGImage) -> UInt8? {
        var px = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: -cg.width / 2, y: -cg.height / 2, width: cg.width, height: cg.height))
            return true
        }
        return drawn ? px[0] : nil
    }

    @Test func theFixtureHasSixPagesWithPrintedLabels() throws {
        let doc = try Self.sample()
        #expect(doc.pageCount == 6)
        let labels = ReaderPDF.labels(of: doc)
        #expect(labels == ["i", "ii", "1201", "1202", "1203", "1204"])
        #expect(ReaderPages.hasPrintedLabels(labels))
        #expect(ReaderPages.printedLabel(physical: 5, label: labels[4]) == "1203")
        // The page field: "1203" is the 5th page of the file, "5" is the 5th page too, "ii" the 2nd.
        #expect(ReaderPages.resolve("1203", labels: labels, pageCount: doc.pageCount) == 5)
        #expect(ReaderPages.resolve("ii", labels: labels, pageCount: doc.pageCount) == 2)
        #expect(doc.page(at: 0)?.string?.contains("A Synthetic Paper for the PaperDeck Reader") == true)
        // Without /PageLabels a page's label is its number (or nothing): no printed label is shown.
        let plain = try #require(PDFDocument(data: ReaderFixturePDF.make(pages: [.init(lines: [("One", 12)]),
                                                                                  .init(lines: [("Two", 12)])])))
        #expect(plain.pageCount == 2)
        #expect(!ReaderPages.hasPrintedLabels(ReaderPDF.labels(of: plain)))
    }

    @Test func labelRangesSupportPrefixesAndLetters() throws {
        let pages = (1...4).map { ReaderFixturePDF.Page(lines: [("Page \($0)", 12)]) }
        let doc = try #require(PDFDocument(data: ReaderFixturePDF.make(pages: pages, labels: [
            .init(from: 1, style: "D"), .init(from: 3, style: "D", start: 1, prefix: "S"),
        ])))
        #expect(ReaderPDF.labels(of: doc) == ["1", "2", "S1", "S2"])
        #expect(ReaderPages.resolve("s2", labels: ReaderPDF.labels(of: doc), pageCount: 4) == 4)
    }

    @Test func theQuoteIsFoundOnItsPageAcrossTheLineBreak() throws {
        let doc = try Self.sample()
        let m = try #require(ReaderQuoteFinder.locate(ReaderFixturePDF.sampleQuote, near: ReaderFixturePDF.sampleQuotePage, in: doc))
        #expect(m.page == 3 && m.exact)
        let page = try #require(doc.page(at: m.page - 1))
        let selection = try #require(page.selection(for: m.range))
        let text = (selection.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(text == "we regularize the atten- tion weights by a sparsity prior", "\(text)")
        // A citation one page off still lands on the quote; three pages off doesn't (just the page).
        #expect(ReaderQuoteFinder.locate(ReaderFixturePDF.sampleQuote, near: 4, in: doc)?.page == 3)
        #expect(ReaderQuoteFinder.locate(ReaderFixturePDF.sampleQuote, near: 6, in: doc) == nil)
        // No page: the first match anywhere.
        #expect(ReaderQuoteFinder.locate(ReaderFixturePDF.sampleQuote, near: nil, in: doc)?.page == 3)
    }

    @Test func aTrimmedOrParaphrasedQuoteStillFindsItsWords() throws {
        let doc = try Self.sample()
        // The model's quote has a different ending: the first 6 words carry it (not exact).
        let fuzzy = try #require(ReaderQuoteFinder.locate("we regularize the attention weights by an L1 penalty on every head",
                                                          near: 3, in: doc))
        #expect(fuzzy.page == 3 && !fuzzy.exact)
        // Curly quotes and an ellipsis around it.
        let curly = try #require(ReaderQuoteFinder.locate("“…the attention maps agree with the annotations…”", near: 5, in: doc))
        #expect(curly.page == 5 && curly.exact)
        #expect(ReaderQuoteFinder.locate("a sentence that is nowhere in this paper at all", near: 3, in: doc) == nil)
        #expect(ReaderQuoteFinder.locate("ab", near: 3, in: doc) == nil, "too short to search")
    }

    @Test func pdfKitFindsEveryWholeOccurrenceForTheFindBar() throws {
        let doc = try Self.sample()
        let matches = doc.findString("attention", withOptions: [.caseInsensitive])
        let pages = matches.compactMap { $0.pages.first.map { doc.index(for: $0) + 1 } }
        #expect(Set(pages).isSuperset(of: [1, 2, 5, 6]), "\(pages)")
        let cursor = ReaderFindCursor(matchPages: pages, startingAt: 4)
        #expect(cursor.index.map { pages[$0] } == 5, "the search starts at the page being read")
    }

    @Test func aRegionRendersFromThePDFWithinTheImageCap() throws {
        let doc = try Self.sample()
        let page = try #require(doc.page(at: 3))
        let figure = ReaderFixturePDF.sampleFigure
        let image = try #require(ReaderPDF.renderRegion(figure, of: page))
        #expect(image.mediaType == "image/png" && image.isAcceptable)
        #expect(image.pixelSize == CGSize(width: 900, height: 540), "300 × 180 pt at 3×")
        let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        let cg = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(cg.width == 900 && cg.height == 540)
        // The middle of the box is the figure's grey (0.85), not the page's white.
        let mid = try #require(Self.centerRed(cg))
        #expect(mid < 240 && mid > 180, "\(mid)")
        // A whole page: the long edge is capped.
        let whole = try #require(ReaderPDF.renderRegion(page.bounds(for: .mediaBox), of: page))
        #expect(max(whole.pixelSize.width, whole.pixelSize.height) == AssistImage.maxLongEdge)
        #expect(ReaderPDF.renderRegion(.zero, of: page) == nil)
    }
}
