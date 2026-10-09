import Foundation
import Testing

/// Source checks: every PDFKit path in Core goes through `PDFKitGate`, and the reader's
/// text calls on its own document do too.
@Suite(.enabled(if: LintRepo.hasSources)) struct PDFKitGateLintTests {
    static func text(_ path: String) throws -> String { try String(contentsOf: LintRepo.url(path), encoding: .utf8) }

    static func body(_ source: String, after signature: String, length: Int) throws -> String {
        let r = try #require(source.range(of: signature), "\(signature)")
        return String(source[r.upperBound...].prefix(length))
    }

    /// Code lines only (comments dropped), so a mention in a doc comment doesn't count.
    static func code(_ source: String) -> String {
        source.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    @Test func coreOpensDocumentsOnlyInsideTheGate() throws {
        let opens = try LintRepo.grep(#"(?<![A-Za-z])PDFDocument\s*\("#, under: "Sources/PaperDeckCore")
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let places = Set(opens.map(\.path))
        #expect(places == ["Sources/PaperDeckCore/PDF/PDFKitGate.swift", "Sources/PaperDeckCore/Reader/ReaderDocumentLoader.swift"],
                "a PDFDocument made outside the gate: \(opens)")
        let loader = try Self.body(try Self.text("Sources/PaperDeckCore/Reader/ReaderDocumentLoader.swift"),
                                   after: "package static func opened(_ data: Data) -> ReaderOpenResult {", length: 120)
        #expect(loader.contains("PDFKitGate.shared.run {\n            guard let document = PDFDocument(data: data)"))
    }

    @Test func everyCoreFileUsingPDFKitGoesThroughTheGate() throws {
        let importers = Set(try LintRepo.grep(#"^\s*(@preconcurrency\s+)?import\s+(PDFKit|Quartz)\b"#, under: "Sources/PaperDeckCore").map(\.path))
        #expect(importers.contains("Sources/PaperDeckCore/PDF/PDFExtractor.swift"))
        for path in importers.sorted() {
            let src = Self.code(try Self.text(path))
            #expect(src.contains("PDFKitGate") || src.contains("GatedPDFDocument"), "\(path) uses PDFKit without the gate")
        }
        // The attributed string (the call PDFKit crashed in) is read in one place, and PDFKit's
        // synchronous whole-document find isn't used in Core.
        let attributed = try LintRepo.grep(#"\.attributedString\b"#, under: "Sources/PaperDeckCore")
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        #expect(Set(attributed.map(\.path)) == ["Sources/PaperDeckCore/PDF/TitleHeuristic.swift"], "\(attributed)")
        #expect(try LintRepo.grep(#"findString\s*\("#, under: "Sources/PaperDeckCore")
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.isEmpty)
    }

    /// Each helper that takes a caller's document or page takes the gate itself (so the main actor's
    /// calls are covered); the extractor reads every page, the title and the thumbnail through its
    /// gated document.
    @Test func theHelpersTakeTheGateThemselves() throws {
        let title = try Self.text("Sources/PaperDeckCore/PDF/TitleHeuristic.swift")
        #expect(try Self.body(title, after: "static func title(of page: PDFPage) -> String? {", length: 80)
            .contains("PDFKitGate.shared.run { fontRunTitle(of: page) }"))
        let extractor = try Self.text("Sources/PaperDeckCore/PDF/PDFExtractor.swift")
        #expect(extractor.contains("guard let doc = GatedPDFDocument(url: url),"))
        #expect(extractor.contains("pageTexts.append(doc.with { $0.page(at: i)?.string ?? \"\" })"))
        #expect(extractor.contains("doc.with { $0.page(at: 0).flatMap(TitleHeuristic.title(of:)) }"))
        #expect(extractor.contains("doc.with { $0.page(at: 0).flatMap(cardThumbnailJPEG(page:)) }"))
        #expect(try Self.body(extractor, after: "static func cardThumbnailJPEG(page: PDFPage) -> Data? {", length: 80)
            .contains("PDFKitGate.shared.run { thumbnailJPEG(page) }"))
        #expect(try Self.body(extractor, after: "static func topLevelOutline(_ doc: PDFDocument) -> [(title: String, page: Int)] {", length: 60)
            .contains("PDFKitGate.shared.run { outline(doc) }"))
        let reader = try Self.text("Sources/PaperDeckCore/Reader/ReaderPDF.swift")
        #expect(try Self.body(reader, after: "package static func labels(of document: PDFDocument) -> [String?] {", length: 60)
            .contains("PDFKitGate.shared.run {"))
        #expect(try Self.body(reader, after: "package static func renderRegion(_ rect: CGRect, of page: PDFPage) -> AssistImage? {", length: 60)
            .contains("PDFKitGate.shared.run {"))
        #expect(reader.contains("PDFKitGate.shared.run { drawRegion(rect, of: ref, cropBox: cropBox, rotation: rotation) }"))
        #expect(reader.contains("let text = PDFKitGate.shared.run { document.page(at: n - 1)?.string ?? \"\" }"))
        let find = try Self.text("Sources/PaperDeckCore/Reader/ReaderFindSearch.swift")
        #expect(find.contains("let document = GatedPDFDocument(data: data)"))
        #expect(find.contains("let text = document.with { $0.page(at: i)?.string }"))
    }

    /// The reader window's own text calls (find matches, the quote, a selection's text, a box's text)
    /// take the gate on the main actor; the find itself stays off it.
    @Test func theReaderWindowsTextCallsTakeTheGate() throws {
        let model = try Self.text("Sources/PaperDeck/Reader/ReaderModel.swift")
        let receive = try Self.body(model, after: "private func receive(_ batch: ReaderFindBatch, in doc: PDFDocument) {", length: 260)
        #expect(receive.contains("PDFKitGate.shared.run {\n            for m in batch.matches where findMatches.count < Self.findLimit {"))
        let go = try Self.body(model, after: "    func go(to page: Int, quote: String? = nil) {", length: 1300)
        #expect(go.contains("let hit = PDFKitGate.shared.run {"))
        #expect(go.contains("guard let m = ReaderQuoteFinder.locate(quote, near: p, in: doc)"))
        #expect(go.contains("return (m, matchPage, sel.bounds(for: matchPage), ReaderHighlight.add(sel, color: Self.quoteColor, in: pdfView))"))
        let settled = try Self.body(model, after: "    func selectionSettled() {", length: 260)
        #expect(settled.contains("let text = PDFKitGate.shared.run({ sel.string })"))
        let box = try Self.body(model, after: "    func boxEnded(at viewPoint: CGPoint) {", length: 700)
        #expect(box.contains("PDFKitGate.shared.run { start.page.selection(for: anchor.rect)?.string }"))
        let run = try Self.body(model, after: "    func runFind() {", length: 900)
        #expect(run.contains("ReaderFindSearch.search(q, data: data, limit: Self.findLimit)"))
    }
}
