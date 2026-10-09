import Foundation
import Testing
@testable import PaperDeckCore

/// The answer's Markdown blocks the Ask views draw (paragraphs, lists, quotes), also for a partial
/// streamed text, and the Ask surfaces' source contracts: a question reaches `QAService.ask` only
/// from `AskSession`, with the ticket the hosting view minted in its action handler.
@Suite struct QAAnswerFormatTests {
    @Test func blocksOfAnAnswer() {
        let text = """
            # Main result
            The fins regrow [p. 3].
            It takes two weeks.

            - Proliferation peaks [p. 2]
              and then falls
            * Blocking stops it
            1. First step
            2) Second step
            > A quoted line
            > continued
            ```
            code
            ```
            """
        #expect(QAAnswerFormat.blocks(text) == [
            .paragraph("**Main result**"),
            .paragraph("The fins regrow [p. 3].\nIt takes two weeks."),
            .bullet("Proliferation peaks [p. 2] and then falls"),
            .bullet("Blocking stops it"),
            .numbered(1, "First step"),
            .numbered(2, "Second step"),
            .quote("A quoted line\ncontinued"),
            .paragraph("code"),
        ])
    }

    @Test func partialTextIsDrawnAsItArrives() {
        #expect(QAAnswerFormat.blocks("").isEmpty)
        #expect(QAAnswerFormat.blocks("The fins reg") == [.paragraph("The fins reg")])
        #expect(QAAnswerFormat.blocks("A.\n\n- one\n- tw") == [.paragraph("A."), .bullet("one"), .bullet("tw")])
        #expect(QAAnswerFormat.blocks("- ") == [.bullet("")])            // a list item on its way
        #expect(QAAnswerFormat.blocks("**bold") == [.paragraph("**bold")])
    }

    // MARK: Source contracts (read from the sources the tests were compiled from)

    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func questionsReachTheServiceOnlyThroughTheSessionWithTheViewsTicket() throws {
        let asks = try LintRepo.grep(#"\.ask\(threadID:"#, under: "Sources/PaperDeck")
        #expect(Set(asks.map(\.path)) == ["Sources/PaperDeck/Views/Ask/AskSession.swift"], "\(asks)")
        let mint = "session.perform(intent, ticket: ConsentTicket.mint(session.gesture(for: intent), surface: .qa))"
        for file in ["Sources/PaperDeck/Views/Detail/AskTab.swift", "Sources/PaperDeck/Views/Ask/AskWindowView.swift"] {
            let text = try String(contentsOf: LintRepo.url(file), encoding: .utf8)
            #expect(text.components(separatedBy: "ConsentTicket.mint(").count == 2, "\(file): one mint")
            #expect(text.contains(mint), "\(file)")
        }
        // The session performs with a ticket it is given; it never makes one.
        let session = try String(contentsOf: LintRepo.url("Sources/PaperDeck/Views/Ask/AskSession.swift"), encoding: .utf8)
        #expect(session.contains("func perform(_ intent: AskIntent, ticket: ConsentTicket)"))
        #expect(!session.contains("mint("))
        // Renders and self-tests never perform a question.
        for file in ["Sources/PaperDeck/CLI/AskRenders.swift", "Sources/PaperDeck/CLI/SelfTestQA.swift"] {
            let text = try String(contentsOf: LintRepo.url(file), encoding: .utf8)
            #expect(!text.contains(".perform(") && !text.contains("qa.ask("), "\(file)")
        }
        // Citation clicks go through `ReaderRouting`: the built-in reader when it ships, PagePeek otherwise.
        let views = try String(contentsOf: LintRepo.url("Sources/PaperDeck/Views/Ask/AskAnswerViews.swift"), encoding: .utf8)
        #expect(views.contains("ReaderRouter.isAvailable ? state.reader : PagePeekRouter(state: state)"))
        // Q&A follow-ups resend the context as one-shot turns: never a resumed CLI session.
        let service = try String(contentsOf: LintRepo.url("Sources/PaperDeckCore/QA/QAService.swift"), encoding: .utf8)
        #expect(service.contains("session: .oneShot"))
        #expect(!service.contains(".reuse(threadKey"))
    }
}
