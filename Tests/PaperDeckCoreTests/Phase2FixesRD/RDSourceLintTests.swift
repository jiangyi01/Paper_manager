import Foundation
import Testing

/// The App side of the Phase 2 reader / dedupe fixes, checked in the sources (the test target
/// doesn't link the app; `LintRepo`): the sheets keep an explicit pick across [Ask AI] (B3-2), the
/// judge's ticket is minted in exactly one button action (T-1, V14), the reader's find and open run
/// off the main actor (RD-1, RD-3), and their new strings exist in both languages.
@Suite("Phase 2 fixes RD: App sources", .enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
struct RDSourceLintTests {
    static func text(_ path: String) throws -> String { try String(contentsOf: LintRepo.url(path), encoding: .utf8) }
    static let batch = "Sources/PaperDeck/Views/Dedupe/DuplicateBatchSheet.swift"
    static let sheet = "Sources/PaperDeck/Views/Dedupe/DuplicateSheet.swift"
    static let model = "Sources/PaperDeck/Reader/ReaderModel.swift"

    /// The body of `signature` (up to `length` characters after it).
    static func body(_ source: String, after signature: String, length: Int = 900) throws -> String {
        let r = try #require(source.range(of: signature), "\(signature)")
        return String(source[r.upperBound...].prefix(length))
    }

    @Test func theBatchSheetKeepsAnExplicitPick() throws {
        let src = try Self.text(Self.batch)
        let set = try Self.body(src, after: "func set(_ kind: DupChoiceKind, for id: String) {", length: 260)
        #expect(set.contains("rows[i].override = kind\n"), "a pick equal to the suggestion must stay explicit")
        #expect(!set.contains("== rows[i].suggested ? nil"))
        let ask = try Self.body(src, after: "func askJudge(_ id: String, ticket: ConsentTicket) async {", length: 700)
        #expect(ask.contains("rows[i] = rows[i].refreshed(with: fresh)"))
        #expect(!src.contains("if rows[i].override == rows[i].suggested { rows[i].override = nil }"))
    }

    @Test func theDecisionSheetKeepsAnExplicitPick() throws {
        let src = try Self.text(Self.sheet)
        #expect(src.contains("model.pick(kind)") && !src.contains("model.choice = kind"))
        let pick = try Self.body(src, after: "func pick(_ kind: DupChoiceKind) {", length: 120)
        #expect(pick.contains("choicePicked = true"))
        let show = try Self.body(src, after: "private func show(_ d: DupReviewDetail) {", length: 200)
        #expect(show.contains("choicePicked = false"))
        let ask = try Self.body(src, after: "func askJudge(_ ticket: ConsentTicket) async {", length: 900)
        #expect(ask.contains("let picked = choicePicked ? choice : nil"))
        #expect(ask.contains("if let kept = DupBatch.carry(picked, into: fresh) { pick(kept) }"))
        #expect(!ask.contains("choice != d.defaultChoice ? choice : nil"))
    }

    /// V14: the duplicate judge's ticket is minted once in the whole app — in `DupAskAIButton`'s
    /// Button action — and nowhere else in the dedupe views (the per-file allowlist alone let a
    /// second, unattended mint in DuplicateSheet.swift pass).
    @Test func theJudgeTicketIsMintedOnlyInTheButtonAction() throws {
        let mints = try LintRepo.grep(#"\bmint\b|ConsentTicket\s*\.\s*mint"#, under: "Sources/PaperDeck")
        let judge = mints.filter { $0.text.contains(".judge") || $0.text.contains(".dupJudge") }
        #expect(judge.count == 1 && judge.first?.path == Self.sheet, "\(judge)")
        let dedupeViews = mints.filter { $0.path.hasPrefix("Sources/PaperDeck/Views/Dedupe/") }
        #expect(dedupeViews.count == 1, "mint in the dedupe views: \(dedupeViews)")
        let src = try Self.text(Self.sheet)
        let button = try Self.body(src, after: "struct DupAskAIButton: View {", length: 400)
        #expect(button.contains("Button {\n            ask(ConsentTicket.mint(.judge, surface: .dupJudge))\n        } label: {"))
        // The batch rows pass the button's ticket through; they mint none of their own.
        #expect(!(try Self.text(Self.batch)).contains("mint"))
    }

    @Test func theReaderFindsOffTheMainActorAndCapsSelections() throws {
        let src = try Self.text(Self.model)
        #expect(!src.contains("findString("), "PDFKit's synchronous find is back on the main actor")
        let run = try Self.body(src, after: "    func runFind() {", length: 900)
        #expect(run.contains("ReaderFindSearch.search(q, data: data, limit: Self.findLimit)"))
        let receive = try Self.body(src, after: "private func receive(_ batch: ReaderFindBatch, in doc: PDFDocument) {", length: 500)
        #expect(receive.contains("for m in batch.matches where findMatches.count < Self.findLimit {"))
        // A new query, Done and closing stop the running search.
        let reset = try Self.body(src, after: "private func resetFind() {", length: 200)
        #expect(reset.contains("findTask?.cancel()"))
        let close = try Self.body(src, after: "    func close() {", length: 300)
        #expect(close.contains("findTask?.cancel()") && close.contains("loadTask?.cancel()"))
    }

    @Test func theReaderOpensOffTheMainActor() throws {
        let src = try Self.text(Self.model)
        #expect(!src.contains("PDFDocument(url:"), "the reader builds its document on the main actor again")
        let load = try Self.body(src, after: "    private func performLoad() async {", length: 800)
        #expect(load.contains("await ReaderDocumentLoader.open(url)"))
        #expect(load.contains("case .timedOut: phase = .timedOut"))
        let view = try Self.text("Sources/PaperDeck/Reader/ReaderView.swift")
        #expect(view.contains("Button(L.Reader.cancelOpening) { model.cancelLoading() }"))
        #expect(view.contains("Button(L.Reader.tryAgain) { model.retryLoad() }"))
        let window = try Self.text("Sources/PaperDeck/Reader/ReaderWindowController.swift")
        #expect(window.contains("model.closeWindow = { [weak w] in w?.performClose(nil) }"))
        // The renders and the probe wait for the (asynchronous) find.
        let renders = try Self.text("Sources/PaperDeck/CLI/ReaderRenders.swift")
        #expect(renders.components(separatedBy: "m.runFind()\n").count - 1 == renders.components(separatedBy: "await m.findSettled()").count - 1)
    }

    @Test func theNewReaderStringsHaveBothLanguages() throws {
        let src = try Self.text("Sources/PaperDeck/App/L10n+reader.swift")
        for name in ["findSearching", "findFound", "loadingSlowHint", "cancelOpening", "timedOut", "timedOutHint", "tryAgain"] {
            let line = try Self.body(src, after: name, length: 220)
            #expect(line.contains("zh ?"), "\(name)")
        }
    }
}
