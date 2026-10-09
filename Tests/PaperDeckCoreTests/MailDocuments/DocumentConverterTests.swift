import AppKit
import Foundation
import PDFKit
import Testing
@testable import PaperDeckCore

@Suite struct DocumentKindTests {
    @Test func kindFromTheFileNameFirst() {
        #expect(DocumentKind.detect(fileName: "Smith_lab_manuscript_v3.docx", contentType: "application/octet-stream") == .docx)
        #expect(DocumentKind.detect(fileName: "DRAFT.DOCX", contentType: nil) == .docx)
        #expect(DocumentKind.detect(fileName: "old.doc", contentType: nil) == .doc)
        #expect(DocumentKind.detect(fileName: "notes.rtf", contentType: nil) == .rtf)
        #expect(DocumentKind.detect(fileName: "paper.odt", contentType: nil) == .odt)
        #expect(DocumentKind.detect(fileName: "talk.pptx", contentType: nil) == .pptx)
        #expect(DocumentKind.detect(fileName: "talk.ppt", contentType: nil) == .ppt)
        #expect(DocumentKind.detect(fileName: "talk.key", contentType: nil) == .key)
        #expect(DocumentKind.detect(fileName: "draft.pages", contentType: nil) == .pages)
        #expect(DocumentKind.detect(fileName: "talk.odp", contentType: nil) == .odp)
        // Not documents: PDFs (attachments), spreadsheets, macro-enabled files, images.
        for name in ["paper.pdf", "data.xlsx", "data.csv", "macro.docm", "deck.pptm", "fig.png", "a.zip"] {
            #expect(DocumentKind.detect(fileName: name, contentType: DocKit.docxType) == nil, "\(name)")
        }
    }

    @Test func kindFromTheMIMETypeWithoutAnExtension() {
        #expect(DocumentKind.detect(fileName: nil, contentType: DocKit.docxType) == .docx)
        #expect(DocumentKind.detect(fileName: "manuscript", contentType: "application/msword; name=x") == .doc)
        #expect(DocumentKind.detect(fileName: nil, contentType: "text/rtf") == .rtf)
        #expect(DocumentKind.detect(fileName: nil, contentType: DocKit.pptxType) == .pptx)
        #expect(DocumentKind.detect(fileName: nil, contentType: "application/octet-stream") == nil)
        #expect(DocumentKind.detect(fileName: nil, contentType: "application/vnd.ms-excel") == nil)
    }

    @Test func convertibleKindsAndTheirRowStates() {
        #expect(DocumentKind.allCases.filter(\.isConvertible) == [.docx, .doc, .rtf, .odt])
        #expect(DocumentKind.docx.pdfState == .convertible && DocumentKind.pptx.pdfState == .openOnly)
        #expect(DocumentKind.pages.pdfState == .openOnly && DocumentKind.key.pdfState == .openOnly)
    }

    @Test func signaturesEncryptionAndCompleteness() throws {
        let docx = try DocKit.docx(paragraphs: 2)
        #expect(DocumentKind.docx.hasValidSignature(docx))
        #expect(!DocumentKind.doc.hasValidSignature(docx))                // a zip is no Word 97 file
        #expect(DocumentKind.rtf.hasValidSignature(try DocKit.rtf(paragraphs: 1)))
        #expect(!DocumentKind.docx.hasValidSignature(Data("%PDF-1.7".utf8)))
        #expect(DocumentKind.docx.hasValidSignature(DocKit.encryptedDocx()))
        #expect(DocumentKind.docx.isEncryptedPackage(DocKit.encryptedDocx()))
        #expect(!DocumentKind.docx.isEncryptedPackage(docx))
        #expect(!DocumentKind.doc.isEncryptedPackage(DocKit.encryptedDocx()))
        #expect(DocumentKind.docx.isComplete(docx))
        #expect(!DocumentKind.docx.isComplete(docx.prefix(docx.count / 2)))
        #expect(DocumentKind.pptx.isComplete(DocKit.zipStub()))
    }

    @Test func kindOfAURLPath() {
        #expect(DocumentKind.kind(ofPath: "/scl/fi/abc/Draft%20v2.docx") == "docx")
        #expect(DocumentKind.kind(ofPath: "/s/paper.PDF") == "pdf")
        #expect(DocumentKind.kind(ofPath: "/s/data.xlsx") == nil)
        #expect(DocumentKind.kind(ofPath: "/:w:/g/personal/x/Eabc") == nil)
    }
}

@Suite struct DocumentConverterTests {
    private let a4 = DocumentConverter.Options(paper: .a4)

    @Test func docxBecomesAPaginatedPDFWithItsText() throws {
        let out = try DocumentConverter.convert(try DocKit.docx(paragraphs: 120), kind: .docx, options: a4)
        let text = PDFTextProbe.text(out.pdf)
        #expect(text.contains(DocKit.manuscriptTitle))
        #expect(text.contains(DocKit.lastLine))
        #expect(text.contains("Paragraph 60."))
        #expect(out.pageCount > 1 && PDFTextProbe.pageCount(out.pdf) == out.pageCount)
        let box = PDFTextProbe.mediaBox(out.pdf)
        #expect(abs(box.width - 595.28) < 0.5 && abs(box.height - 841.89) < 0.5)
        // Reading order: the title comes before the last line.
        let t = try #require(text.range(of: DocKit.manuscriptTitle)), e = try #require(text.range(of: DocKit.lastLine))
        #expect(t.lowerBound < e.lowerBound)
    }

    @Test func letterPagesForLetterRegions() throws {
        let out = try DocumentConverter.convert(try DocKit.docx(paragraphs: 3), kind: .docx,
                                                options: DocumentConverter.Options(paper: .letter))
        let box = PDFTextProbe.mediaBox(out.pdf)
        #expect(box.width == 612 && box.height == 792)
        #expect(PaperSize.forRegion("US") == .letter && PaperSize.forRegion("ca") == .letter)
        #expect(PaperSize.forRegion("PH") == .letter && PaperSize.forRegion("MX") == .letter)
        #expect(PaperSize.forRegion("DE") == .a4 && PaperSize.forRegion("CN") == .a4 && PaperSize.forRegion("GB") == .a4)
        #expect(PaperSize.forRegion(nil) == .a4)
    }

    @Test func rtfOdtAndWord97Convert() throws {
        for (data, kind) in [(try DocKit.rtf(), DocumentKind.rtf), (try DocKit.odt(), .odt), (try DocKit.doc(), .doc)] {
            let out = try DocumentConverter.convert(data, kind: kind, options: a4)
            let text = PDFTextProbe.text(out.pdf)
            #expect(text.contains(DocKit.manuscriptTitle), "\(kind)")
            #expect(text.contains(DocKit.lastLine), "\(kind)")
        }
    }

    @Test func runsOffTheMainThreadFromAFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-docconv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("m.docx")
        try DocKit.docx(paragraphs: 5).write(to: url)
        let out = try await DocumentConverter.convert(fileAt: url, kind: .docx, options: a4)
        #expect(PDFTextProbe.text(out.pdf).contains(DocKit.lastLine))
        await #expect(throws: DocumentConversionError.unreadable) {
            try await DocumentConverter.convert(fileAt: dir.appendingPathComponent("missing.docx"), kind: .docx)
        }
    }

    @Test func clearErrorsForWhatCannotBeConverted() throws {
        #expect(throws: DocumentConversionError.unsupported) {
            try DocumentConverter.convert(DocKit.zipStub(), kind: .pptx)
        }
        #expect(throws: DocumentConversionError.encrypted) {
            try DocumentConverter.convert(DocKit.encryptedDocx(), kind: .docx)
        }
        #expect(throws: DocumentConversionError.encrypted) {
            try DocumentConverter.convert(DocKit.wordBinary(encrypted: true), kind: .doc)
        }
        #expect(throws: DocumentConversionError.unreadable) {                 // a zip that isn't a Word package
            try DocumentConverter.convert(DocKit.zipStub(), kind: .docx)
        }
        #expect(throws: DocumentConversionError.unreadable) {                 // a PDF named .docx
            try DocumentConverter.convert(Data("%PDF-1.7 not a docx".utf8), kind: .docx)
        }
        #expect(throws: DocumentConversionError.unreadable) {
            try DocumentConverter.convert(Data(), kind: .rtf)
        }
        let empty = try DocKit.write(NSAttributedString(string: "   \n\n"), .rtf)
        #expect(throws: DocumentConversionError.empty) { try DocumentConverter.convert(empty, kind: .rtf) }
        #expect(throws: DocumentConversionError.tooLarge) {
            try DocumentConverter.convert(try DocKit.docx(paragraphs: 2), kind: .docx,
                                          options: DocumentConverter.Options(paper: .a4, maxBytes: 100))
        }
        #expect(throws: DocumentConversionError.tooLarge) {
            try DocumentConverter.convert(try DocKit.docx(paragraphs: 200), kind: .docx,
                                          options: DocumentConverter.Options(paper: .a4, maxPages: 2))
        }
    }

    @Test func encryptedWord97FlagIsReadFromTheFIB() {
        #expect(DocumentConverter.isEncryptedWordBinary(DocKit.wordBinary(encrypted: true)))
        #expect(!DocumentConverter.isEncryptedWordBinary(DocKit.wordBinary(encrypted: false)))
        #expect(!DocumentConverter.isEncryptedWordBinary(DocKit.encryptedDocx()))       // no WordDocument stream
        #expect(!DocumentConverter.isEncryptedWordBinary(Data("{\\rtf1}".utf8)))
    }

    /// An image wider and taller than a page is scaled to fit inside the margins (unscaled it would
    /// spill over several pages and over the margins).
    @Test func oversizedImagesAreScaledToThePage() throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4000, pixelsHigh: 6000, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        let paint = try #require(NSGraphicsContext(bitmapImageRep: rep))
        paint.cgContext.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        paint.cgContext.fill(CGRect(x: 0, y: 0, width: 4000, height: 6000))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let wrapper = FileWrapper(regularFileWithContents: png)
        wrapper.preferredFilename = "figure.png"
        let s = NSMutableAttributedString(string: "Before the figure.\n")
        s.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        s.append(NSAttributedString(string: "\nAfter the figure.\n"))
        let out = try DocumentConverter.render(s, options: a4, images: 1)
        #expect(out.pageCount == 1)
        #expect(PDFTextProbe.text(out.pdf).contains("After the figure."))
        // The right margin stays white; the figure is drawn in the text column.
        let page = try #require(PDFDocument(data: out.pdf)?.page(at: 0))
        let thumb = page.thumbnail(of: NSSize(width: 119, height: 168), for: .mediaBox)
        let bitmap = try #require(thumb.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        func blue(_ x: Int, _ y: Int) -> Bool {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return c.blueComponent > 0.8 && c.redComponent < 0.2
        }
        let margin = stride(from: 0, to: bitmap.pixelsHigh, by: 2).filter { blue(bitmap.pixelsWide - 3, $0) }
        let column = stride(from: 0, to: bitmap.pixelsHigh, by: 2).filter { blue(bitmap.pixelsWide / 2, $0) }
        #expect(margin.isEmpty && !column.isEmpty)
    }

    @Test func errorMessagesInBothLanguages() {
        let all: [DocumentConversionError] = [.unsupported, .encrypted, .unreadable, .empty, .tooLarge, .renderFailed]
        for e in all {
            let en = e.message(.en), zh = e.message(.zh)
            #expect(!en.isEmpty && !zh.isEmpty && en != zh, "\(e)")
            #expect(zh.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, "\(e)")
        }
        #expect(Set(all.map { $0.message(.en) }).count == all.count)
    }
}

/// Word's inline figures (dropped by Cocoa's importer) come back after the text.
@Suite struct DocxFigureTests {
    @Test func picturesAreReadInDocumentOrder() throws {
        let red = DocKit.png(width: 40, height: 30, red: 1, blue: 0), green = DocKit.png(width: 50, height: 20, green: 1, blue: 0)
        let docx = DocKit.docxWithFigures([red, green])
        let images = DocxMedia.images(docx)
        #expect(images == [red, green])                     // document order, each once, external / EMF skipped
        #expect(DocxMedia.images(docx, maxImages: 1) == [red])
        #expect(DocxMedia.images(Data("not a zip".utf8)).isEmpty)
        #expect(DocxMedia.images(DocKit.zipStub()).isEmpty)
        #expect(DocxMedia.resolve("media/image1.png") == "word/media/image1.png")
        #expect(DocxMedia.resolve("/word/media/a.png") == "word/media/a.png")
        #expect(DocxMedia.resolve("../../../etc/passwd") == "etc/passwd")      // never above the package root
        // Deflated entries (as Word writes them) are read too.
        #expect(DocxMedia.images(DocKit.docxWithFigures([red, green], deflated: true)) == [red, green])
    }

    @Test func aConvertedManuscriptKeepsItsFigures() throws {
        let blue = DocKit.png(width: 600, height: 400)
        let docx = DocKit.docxWithFigures([blue, DocKit.png(width: 300, height: 300, red: 1, blue: 0)])
        let out = try DocumentConverter.convert(docx, kind: .docx,
                                                options: DocumentConverter.Options(paper: .a4, figuresHeading: "Figures from the original document"))
        #expect(out.images == 2)
        let text = PDFTextProbe.text(out.pdf)
        #expect(text.contains(DocKit.manuscriptTitle) && text.contains(DocKit.lastLine))
        #expect(text.contains("Figures from the original document"))
        #expect(out.pageCount >= 2)                                              // the figures start on a new page
        let firstPage = PDFDocument(data: out.pdf)?.page(at: 0)?.string ?? ""
        #expect(!firstPage.contains("Figures from the original document"))
        #expect(MailDocumentText.figuresHeading(.zh) == "原文档中的图片")
    }
}
