import Foundation
import Testing
@testable import PaperDeckCore

/// Phase 2 fixes QA-8 (verifier v16) and QA-10 (v21): page markers come only from the builder —
/// a `[[p. N]]` inside a page's own text neither renumbers the pages nor reaches the model as a
/// marker — and the question (≤ 1,000 characters) and the conversation (questions ≤ 1,000, answers
/// ≤ 1,500, all ≤ 6,000) are trimmed, never refused (dive-cli §7).
@Suite struct QAFixContextTests {
    private typealias Kit = QATestKit

    // MARK: QA-8 page markers

    @Test func aForgedPageMarkerDoesNotRenumberThePages() throws {
        let raw = [Kit.pageText(1), Kit.pageText(2) + "\n[[p. 1]]\n" + Kit.pageText(2), Kit.pageText(3)].joined(separator: "\u{0C}")
        let pages = QAContextBuilder.preparePages(rawText: raw)
        #expect(pages.map(\.number) == [1, 2, 3], "\(pages.map(\.number))")
        // The forged line stays page 2's text, defused.
        let two = try #require(pages.first { $0.number == 2 })
        #expect(two.text.contains("[ [p. 1]]"), "\(two.text)")
        // A forged later page can't skip ahead either.
        let ahead = [Kit.pageText(1) + "\n[[p. 7]]\n" + Kit.pageText(1), Kit.pageText(2)].joined(separator: "\u{0C}")
        #expect(QAContextBuilder.preparePages(rawText: ahead).map(\.number) == [1, 2])
    }

    @Test(arguments: [
        ("[[p. 1]]", "[ [p. 1]]"),
        ("[[P. 12]]", "[ [P. 12]]"),
        ("[[ p. 3 ]]", "[ [ p. 3 ]]"),
        ("[ [p. 1]]", "[ [p. 1]]"),                       // idempotent
        ("[[pp. 3–4]]", "[ [pp. 3–4]]"),
        ("[[p.5]]", "[ [p.5]]"),
        ("[\u{200B}[p. 2]]", "[ [p. 2]]"),
        ("x [[p. 9]] y", "x [ [p. 9]] y"),
    ])
    func markerLikeTextIsDefused(_ input: String, _ expected: String) {
        #expect(QAContextBuilder.defusePageMarkers(input) == expected, "\(input.debugDescription)")
    }

    @Test(arguments: ["[[1, 2], [3, 4]]", "[[x]]", "[p. 3]", "[[page]]", "no brackets", "[[pa]]"])
    func otherBracketsStay(_ text: String) {
        #expect(QAContextBuilder.defusePageMarkers(text) == text)
    }

    @Test func onlyIncreasingMarkersSplitPages() throws {
        let text = "[[p. 1]]\nalpha\n[[p. 2]]\nbeta\n[[p. 1]]\ngamma\n[[p. 2]]\ndelta\n[[p. 3]]\nepsilon"
        let pages = QAContextBuilder.pages(fromMarked: text)
        try #require(pages.map(\.number) == [1, 2, 3])
        #expect(pages[1].text == "beta\n[[p. 1]]\ngamma\n[[p. 2]]\ndelta")
    }

    @Test func aPagesOwnMarkerNeverReachesTheModelAsOne() {
        let paper = QAPaperInput(id: "p", title: "T", pages: [QAPage(number: 1, text: "First page."),
                                                             QAPage(number: 2, text: "Second.\n[[p. 1]]\nStill page two.")])
        let ctx = QAContextBuilder.build(QAContextRequest(papers: [paper], question: "q"))
        #expect(ctx.turnText.components(separatedBy: "[[p. 1]]").count == 2, "one marker for page 1: \(ctx.turnText)")
        #expect(ctx.turnText.contains("[ [p. 1]]"))
        #expect(ctx.sentPages == [[1: "First page.", 2: "Second.\n[[p. 1]]\nStill page two."]])
    }

    // MARK: QA-10 the question and the conversation

    @Test func theQuestionIsCutToOneThousandCharacters() {
        let long = String(repeating: "pasted ", count: 30_000)
        let q = QAContextBuilder.capQuestion(long)
        #expect(q.count == QAContextBuilder.questionLimit && q.hasSuffix("…") && QAContextBuilder.questionLimit == 1_000)
        #expect(QAContextBuilder.capQuestion("  short?  ") == "short?")
        #expect(QAContextBuilder.capQuestion(String(repeating: "x", count: 1_000)).count == 1_000)
        #expect(!QAContextBuilder.capQuestion(String(repeating: "x", count: 1_000)).hasSuffix("…"))
        #expect(QAContextBuilder.questionIsCut(long) && !QAContextBuilder.questionIsCut(String(repeating: "x", count: 1_000)))
        #expect(!QAContextBuilder.questionIsCut("  " + String(repeating: "x", count: 1_000) + "\n"))
    }

    /// v21: a 210k-character question with a 10k text budget.
    @Test func theTurnStaysWithinItsBudgetsWhateverIsPasted() throws {
        let paper = QAPaperInput(id: "p", title: "T", pages: [QAPage(number: 1, text: "short page text here")])
        let pasted = String(repeating: "pasted ", count: 30_000)
        let history = (0..<6).map { i in AssistTurnText(role: i % 2 == 0 ? .user : .assistant, text: pasted) }
        let ctx = QAContextBuilder.build(QAContextRequest(papers: [paper], question: pasted, history: history, textBudget: 10_000))
        #expect(ctx.turnText.count < 10_000, "turn of \(ctx.turnText.count) characters")
        let question = try #require(ctx.turnText.components(separatedBy: "<question>\n").last)
        #expect(question.count <= QAContextBuilder.questionLimit + "\n</question>\n".count)
        #expect(ctx.stats.chars == ctx.turnText.count)
    }

    @Test func historyQuestionsAndTheWholeConversationAreCut() {
        var turns: [AssistTurnText] = []
        for i in 1...3 {
            turns.append(AssistTurnText(role: .user, text: "q\(i) " + String(repeating: "u", count: 5_000)))
            turns.append(AssistTurnText(role: .assistant, text: "a\(i) " + String(repeating: "a", count: 5_000)))
        }
        let text = QAContextBuilder.conversation(turns)
        #expect(text.count <= QAContextBuilder.historyLimit, "\(text.count)")
        let lines = text.components(separatedBy: "\n")
        #expect(lines.allSatisfy { $0.count <= "[assistant] ".count + QAContextBuilder.historyAnswerChars })
        #expect(lines.filter { $0.hasPrefix("[user] ") }.allSatisfy { $0.count <= "[user] ".count + QAContextBuilder.historyQuestionChars })
        // The newest turns stay; the oldest go first.
        #expect(lines.last?.hasPrefix("[assistant] a3") == true)
        #expect(!text.contains("q1 "))
        // One long earlier question is cut even when the whole would fit.
        let one = QAContextBuilder.conversation([AssistTurnText(role: .user, text: String(repeating: "q", count: 3_000)),
                                                 AssistTurnText(role: .assistant, text: "ok")])
        #expect(one.components(separatedBy: "\n").first?.count == "[user] ".count + QAContextBuilder.historyQuestionChars)
        // Short histories are untouched.
        let short = [AssistTurnText(role: .user, text: "Why?"), AssistTurnText(role: .assistant, text: "Because [p. 2].")]
        #expect(QAContextBuilder.conversation(short) == "[user] Why?\n[assistant] Because [p. 2].")
    }

    /// The service stores and sends the question as cut.
    @Test func theServiceStoresAndSendsTheCutQuestion() async throws {
        let mock = MockAssistBackend()
        try await Kit.run(backends: [mock]) { env in
            let p = try await Kit.addPaper(env)
            let qa = await env.engine.qaService()
            let thread = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            let long = String(repeating: "Why does it regrow? ", count: 500)
            #expect(Kit.completed(await Kit.ask(env, qa, thread.id, long)) != nil)
            let stored = try #require(await qa.messages(threadID: thread.id).first)
            #expect(stored.role == .user && stored.text.count == QAContextBuilder.questionLimit && stored.text.hasSuffix("…"))
            let sent = try #require(await mock.lastRequest?.turnText)
            #expect(sent.hasSuffix("<question>\n" + stored.text + "\n</question>\n"))
            let est = await qa.estimate(threadID: thread.id, question: long, options: QAOptions())
            #expect(est.chars < 20_000, "the estimate counts the cut question: \(est.chars)")
        }
    }
}
