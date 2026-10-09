import Foundation
import Testing

/// Source checks for the app target (R-PDFKIT-1): PagePeek opens, labels and searches its document
/// inside `PDFKitGate` on the main actor, like the reader's text calls, and the headless renders
/// open theirs inside it too. (The app target can't be imported by the tests, hence source checks.)
@Suite(.enabled(if: LintRepo.hasSources)) struct PDFKitGateAppLintTests {
    static func codeHits(_ pattern: String) throws -> [LintRepo.Hit] {
        try LintRepo.grep(pattern, under: "Sources/PaperDeck").filter { !$0.text.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    @Test func theAppOpensDocumentsOnlyInsideTheGate() throws {
        let opens = try Self.codeHits(#"(?<![A-Za-z])PDFDocument\s*\((url|data):"#)
        #expect(opens.count == 3, "\(opens)")
        // PagePeekSnapshot.draw opens its document inside image(url:page:highlight:), and PagePeek in
        // its task's gated turn (checked below).
        let ungated = opens.filter { !$0.text.contains("PDFKitGate.shared.run") }
        #expect(ungated.map(\.path).sorted() == ["Sources/PaperDeck/CLI/AskRenders.swift", "Sources/PaperDeck/Views/Ask/PagePeek.swift"], "\(ungated)")
        let ask = try PDFKitGateLintTests.text("Sources/PaperDeck/CLI/AskRenders.swift")
        #expect(ask.contains("PDFKitGate.shared.run { draw(url: url, page: page, highlight: highlight) }"))
    }

    @Test func pagePeeksTextCallsTakeTheGate() throws {
        let peek = try PDFKitGateLintTests.text("Sources/PaperDeck/Views/Ask/PagePeek.swift")
        // Opened and labelled in one turn, in the view's task: never a gate wait in `body`.
        #expect(peek.contains("""
            let opened = PDFKitGate.shared.run { () -> (document: PDFDocument?, label: String?) in
                            let document = PDFDocument(url: row.pdfURL)
                            return (document, document?.page(at: page - 1)?.label)
            """))
        #expect(peek.contains("@State private var printedLabel: String?"))
        let body = try PDFKitGateLintTests.body(peek, after: "    var body: some View {", length: 2000)
        let render = try #require(body.components(separatedBy: ".task(id:").first)
        let header = try PDFKitGateLintTests.body(peek, after: "    private var header: some View {", length: 900)
        for part in [render, header] {
            #expect(!part.contains("PDFKitGate") && !part.contains(".label"), "a gated PDFKit call while PagePeekView draws: \(part)")
        }
        #expect(peek.contains("let hit = PDFKitGate.shared.run {\n                doc.findString(c, withOptions:"))
        // PDFKit's whole-document find is used in that one place only.
        let finds = try Self.codeHits(#"findString\s*\("#)
        #expect(finds.map(\.path) == ["Sources/PaperDeck/Views/Ask/PagePeek.swift"], "\(finds)")
        // The headless reader renders read text and draw the page inside the gate too.
        let renders = try PDFKitGateLintTests.text("Sources/PaperDeck/CLI/ReaderRenders.swift")
        #expect(renders.contains("let text = PDFKitGate.shared.run({ page.string })"))
        #expect(renders.contains("let sel = PDFKitGate.shared.run({ page.selection(for: r) })"))
        #expect(renders.contains("PDFKitGate.shared.run({ page.thumbnail(of: NSSize(width: 1224, height: 1584), for: .mediaBox) })"))
    }
}
