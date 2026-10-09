import Foundation
import Testing

/// The reader's App wiring, checked in the sources (the test target doesn't link the app; `LintRepo`):
/// strings in both languages, the opener option and routing, the Ask / Explain gates and the one
/// ticket site, a read-only PDF, the page memory, and the render-only override.
@Suite("Reader: App sources", .enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
struct ReaderSourceLintTests {
    static func text(_ path: String) throws -> String { try String(contentsOf: LintRepo.url(path), encoding: .utf8) }
    static let strings = "Sources/PaperDeck/App/L10n+reader.swift"
    static let reader = "Sources/PaperDeck/Reader"

    /// Every `zh ? "…" : "…"` pair (single-line string literals).
    static func pairs(_ source: String) -> [(zh: String, en: String)] {
        let pattern = #"zh \? "((?:[^"\\]|\\.)*)" : "((?:[^"\\]|\\.)*)""#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = source as NSString
        return re.matches(in: source, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)))
        }
    }

    @Test func everyReaderStringHasDistinctEnglishAndChinese() throws {
        let source = try Self.text(Self.strings)
        let pairs = Self.pairs(source)
        #expect(pairs.count >= 45, "found \(pairs.count) pairs: is the scan still seeing them?")
        for p in pairs {
            #expect(!p.zh.isEmpty && !p.en.isEmpty, "\(p)")
            #expect(p.zh != p.en, "en = zh: \(p.en)")
            // CJK punctuation, kana-free ideographs or full-width forms: the zh string is Chinese.
            #expect(p.zh.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) },
                    "no Chinese in the zh string: \(p.zh)")
        }
        // Every accessor answers per language (no English-only line slipped in).
        let accessors = source.components(separatedBy: "\n").filter { $0.contains("static var ") || $0.contains("static func ") }
            .filter { !$0.contains("private static var zh") }
        for line in accessors where !line.contains("zh ?") {
            // A multi-line accessor: its body follows on the next lines.
            let start = try #require(source.range(of: line))
            let body = source[start.upperBound...].prefix(400)
            #expect(body.contains("zh ?"), "\(line)")
        }
        // No institution literal.
        #expect(source.range(of: InstitutionLintTests.pattern, options: [.regularExpression, .caseInsensitive]) == nil)
    }

    @Test func theOpenerOptionIsTheReaderAndPreviewStaysTheDefault() throws {
        let option = try Self.text("\(Self.reader)/ReaderOpenerOption.swift")
        #expect(option.contains("if ReaderRouter.isAvailable {"))
        #expect(option.contains("Text(L.Reader.openerOption).tag(ReaderRoute.Opener.paperDeck)"))
        // The default stays Preview (SettingsStore is the Lead's; the reader never writes pdf.opener).
        let store = try Self.text("Sources/PaperDeck/App/SettingsStore.swift")
        #expect(store.contains("Keys.pdfOpener: \"preview\""))
        #expect(try LintRepo.grep(#"pdfOpener\s*="#, under: Self.reader).isEmpty, "the reader never changes the opener")
    }

    @Test func aPageOpensTheReaderAndNoPageKeepsTheUsersOpener() throws {
        let router = try Self.text("\(Self.reader)/ReaderRouter.swift")
        let open = try #require(router.range(of: "func openPDF(_ row: PaperRow, page: Int?, quote: String? = nil) {"))
        let body = String(router[open.upperBound...].prefix(500))
        #expect(body.contains("ReaderRoute.decide(opener: settings.pdfOpener, page: page, quote: quote, readerAvailable: ReaderRouter.isAvailable)"))
        #expect(body.contains("case .reader(let page, let quote): ReaderRouter(state: self).openReader(row, page: page, quote: quote)"))
        #expect(body.contains("case .preview, .defaultApp: openPDF(row)"), "no page: exactly today's openPDF(row)")
        // Opening in the reader counts as opening the paper, like openPDF.
        let reader = try #require(router.range(of: "func openReader(_ row: PaperRow, page: Int?, quote: String?) {"))
        let readerBody = String(router[reader.upperBound...].prefix(800))
        for needle in ["L.pdfMissing", "ReaderWindowController.show(state: state, row: row, page: page, quote: quote)",
                       "state.engine.recentOpens.push(paperID: row.id)", "guard !row.paper.isDeleted else { return }",
                       "engine.markOpened(paperID: row.id)"] {
            #expect(readerBody.contains(needle), "\(needle)")
        }
        #expect(router.contains("typealias PDFOpenerRouter = ReaderRouter"))
    }

    @Test func askAndExplainStayHiddenUntilTheyShipAndOnlyAClickMintsATicket() throws {
        let toolbar = try Self.text("\(Self.reader)/SelectionToolbar.swift")
        #expect(toolbar.contains("private var showsAsk: Bool { AssistRollout.ask || Self.previewShowsAssist }"))
        #expect(toolbar.contains("private var showsExplain: Bool { AssistRollout.explain || Self.previewShowsAssist }"))
        #expect(toolbar.contains("guard AssistRollout.explain, let coordinator = ExplainBootstrap.coordinator else { return }"))
        // The one ticket: inside the Explain buttons' action, for the explain surface, gesture `.reader`.
        let mints = try LintRepo.grep(AssistContractGrepTests.mintPattern, under: Self.reader)
        #expect(mints.count == 1 && mints.first?.path == "\(Self.reader)/SelectionToolbar.swift", "\(mints)")
        #expect(mints.first?.text.contains("let ticket = ConsentTicket.mint(.reader, surface: .explain)") == true)
        let explainLoop = try #require(toolbar.range(of: "if showsExplain {"))
        let mint = try #require(toolbar.range(of: "ConsentTicket.mint("))
        #expect(explainLoop.lowerBound < mint.lowerBound)
        // The render override is set by the renders only.
        let sets = try LintRepo.grep(#"previewShowsAssist\s*=\s*"#, under: "Sources").filter { !$0.text.contains("static var") }
        #expect(sets.allSatisfy { $0.path == "Sources/PaperDeck/CLI/ReaderRenders.swift" }, "\(sets)")
        // The window's Ask button too.
        let view = try Self.text("\(Self.reader)/ReaderView.swift")
        #expect(view.contains("if AssistRollout.ask {"))
        // No AI anywhere else in the reader: no lane, no QA service, no backend.
        let ai = try LintRepo.grep(#"\.assist\.submit|AssistLane|engine\.qa\b|QAService|AssistBackend"#, under: Self.reader)
        #expect(ai.isEmpty, "\(ai)")
    }

    @Test func theReaderNeverWritesThePDF() throws {
        let writes = try LintRepo.grep(#"\.write\(to:|\.write\(toFile:|dataRepresentation|removeItem|moveItem|replaceItem|FileHandle\(forWriting"#,
                                       under: Self.reader)
        #expect(writes.isEmpty, "\(writes)")
        // Highlights live in the in-memory document only and are removed again.
        let model = try Self.text("\(Self.reader)/ReaderModel.swift")
        #expect(model.contains("ReaderHighlight.remove(quoteMarks, in: pdfView)"))
        let close = try #require(model.range(of: "    func close() {"))
        #expect(String(model[close.upperBound...].prefix(300)).contains("ReaderHighlight.remove(quoteMarks, in: pdfView)"))
    }

    @Test func thePageIsRememberedDebouncedAndOnClose() throws {
        let model = try Self.text("\(Self.reader)/ReaderModel.swift")
        let changed = try #require(model.range(of: "    private func pageChanged() {"))
        let body = String(model[changed.upperBound...].prefix(600))
        #expect(body.contains("try? await Task.sleep(for: .seconds(1))") && body.contains("engine.setReaderPage(paperID: id, page: n)"))
        let close = try #require(model.range(of: "    func close() {"))
        #expect(String(model[close.upperBound...].prefix(700)).contains("await engine.setReaderPage(paperID: id, page: page)"))
        // Opening restores the remembered page unless a page was asked for (ReaderPageMemory.startPage)
        // — once the document was read off the main actor (`performLoad`, RD-3).
        #expect(model.contains("    func load(page: Int?, quote: String?) async {"))
        let load = try #require(model.range(of: "    private func performLoad() async {"))
        let loadBody = String(model[load.upperBound...].prefix(1800))
        #expect(loadBody.contains("let remembered = await state?.engine.readerPage(paperID: paperID)"))
        #expect(loadBody.contains("ReaderPageMemory.startPage(requested: wanted.page, remembered: remembered, pageCount: doc.pageCount)"))
        let window = try Self.text("\(Self.reader)/ReaderWindowController.swift")
        let willClose = try #require(window.range(of: "func windowWillClose(_ notification: Notification) {"))
        let closeBody = String(window[willClose.upperBound...].prefix(300))
        #expect(closeBody.contains("model.close()") && closeBody.contains("ActivationPolicy.update(closing: window)"))
    }

    @Test func theWindowIsHostedLikeTheLibrary() throws {
        let window = try Self.text("\(Self.reader)/ReaderWindowController.swift")
        #expect(window.contains("hosting.sceneBridgingOptions = [.toolbars, .title]"))
        #expect(window.contains("hosting.sizingOptions = []"))
        #expect(window.contains("static let windowIdentifier = NSUserInterfaceItemIdentifier(\"PaperDeckReaderWindow\")"))
        #expect(window.contains("ActivationPolicy.becomeRegular()") && window.contains("LibraryMainMenu.installIfNeeded(state: state)"))
        // One window per paper, reused.
        #expect(window.contains("if let existing = open[id], let w = existing.window {"))
    }
}
