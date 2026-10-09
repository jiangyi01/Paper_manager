import Foundation
import Testing
@testable import PaperDeckCore

/// Phase 2 fixes QA-6 and QA-12, and QA-4's App survivors U2 / U3 (the Ask views' rules now live in
/// Core's `QASendPlan` / `QAIntent`, which `AskSession.perform` calls — a source lint pins that):
/// Try Again / Continue resend this thread's question and never a stale privacy confirmation (it
/// covers one send); "Send Anyway" is the only send with the acknowledgement; "Answer in 中文" re-asks
/// the clicked answer's question in that language, once, without changing the thread's language;
/// each click's ticket is made with its own gesture.
@Suite(.timeLimit(.minutes(1))) struct QAFixSendPlanTests {
    private typealias Kit = QATestKit
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func user(_ id: String, _ text: String, thread: String = "A") -> QAMessage {
        QAMessage(id: id, threadID: thread, role: .user, text: text, createdAt: t0)
    }
    static func answer(_ id: String, _ text: String = "Answer [p. 2].", state: QAMessage.State = .done, lang: String = "en",
                       thread: String = "A") -> QAMessage {
        QAMessage(id: id, threadID: thread, role: .assistant, text: text, state: state, createdAt: t0, language: lang)
    }
    static let current = QAOptions(depth: .quick, language: .auto)

    static func send(_ intent: QAIntent, last: QASentQuestion? = nil, thread: String? = "A", messages: [QAMessage] = [],
                     confirming: (question: String, options: QAOptions)? = nil, current: QAOptions = current) -> QASendPlan.Send? {
        QASendPlan.send(intent, current: current, last: last, threadID: thread, messages: messages, confirming: confirming)
    }

    // MARK: QA-6 a confirmation covers one send

    @Test func aSentQuestionNeverKeepsThePrivacyAcknowledgement() {
        let s = QASentQuestion(threadID: "A", question: "X", options: QAOptions(depth: .thorough, privacyAcknowledged: true))
        #expect(!s.options.privacyAcknowledged && s.options.depth == .thorough && s.question == "X" && s.threadID == "A")
    }

    @Test func sendAnywayIsTheOnlySendWithTheAcknowledgement() throws {
        let confirm = try #require(Self.send(.confirmPrivacy, confirming: ("Main result?", QAOptions(depth: .thorough))))
        #expect(confirm.question == "Main result?" && confirm.options.privacyAcknowledged && confirm.options.depth == .thorough)
        #expect(Self.send(.confirmPrivacy) == nil)                                        // no confirmation on screen
        #expect(Self.send(.confirmPrivacy, confirming: ("  ", QAOptions())) == nil)
        // Every other click goes without it, even when the toggles' options somehow carried it.
        let acked = QAOptions(privacyAcknowledged: true)
        let messages = [Self.user("q1", "Q1"), Self.answer("a1"), Self.user("q2", "Q2")]
        for intent: QAIntent in [.ask("Again?"), .retry, .continuePastCap, .thorough(messageID: "a1"), .translate(.zh, messageID: "a1")] {
            let s = Self.send(intent, last: QASentQuestion(threadID: "A", question: "Q2", options: acked), messages: messages,
                              confirming: ("Q2", acked), current: acked)
            #expect(s != nil && s?.options.privacyAcknowledged == false, "\(intent)")
        }
    }

    /// The verifier's scenario: X refused in thread A; thread B ends with an unanswered Y; Try Again in B sends Y.
    @Test func tryAgainResendsTheQuestionOfTheThreadOnScreen() {
        let lastX = QASentQuestion(threadID: "A", question: "X", options: QAOptions(depth: .thorough, language: .zh))
        let threadB = [Self.user("b1", "Y", thread: "B")]
        #expect(Self.send(.retry, last: lastX, thread: "B", messages: threadB) == .init(question: "Y", options: Self.current))
        #expect(Self.send(.continuePastCap, last: lastX, thread: "B", messages: threadB)?.question == "Y")
        // In its own thread the last question goes again with its own options (a failed answer after it).
        let threadA = [Self.user("a1", "X"), Self.answer("a2", "", state: .failed)]
        #expect(Self.send(.retry, last: lastX, thread: "A", messages: threadA) == .init(question: "X", options: lastX.options))
        // Its own thread, refused (the question stored unanswered): the same.
        #expect(Self.send(.retry, last: lastX, thread: "A", messages: [Self.user("a1", "X")])?.options.depth == .thorough)
        // The thread's own unanswered question wins over a different last one.
        #expect(Self.send(.retry, last: lastX, thread: "A", messages: [Self.user("a1", "Z")])?.question == "Z")
        // Nothing to resend.
        #expect(Self.send(.retry, last: nil, thread: "B", messages: [Self.user("b1", "Y"), Self.answer("b2")]) == nil)
        #expect(Self.send(.retry, last: lastX, thread: nil, messages: []) == nil)
    }

    // MARK: QA-12 "Answer in 中文 / English"

    @Test func answerInAnotherLanguageReAsksThatAnswersQuestion() {
        let messages = [Self.user("q1", "What is shown?"), Self.answer("a1"), Self.user("q2", "And the method?"), Self.answer("a2"),
                        Self.user("q3", "Limits?"), Self.answer("a3", "", state: .failed)]
        let zh = Self.send(.translate(.zh, messageID: "a1"), messages: messages)
        #expect(zh == .init(question: "What is shown?", options: QAOptions(depth: .quick, language: .zh)))
        #expect(Self.send(.translate(.en, messageID: "a2"), messages: messages)?.question == "And the method?")
        #expect(Self.send(.translate(.en, messageID: "a2"), messages: messages)?.options.language == .en)
        // A failed row's question too (its answer is the one clicked).
        #expect(Self.send(.translate(.zh, messageID: "a3"), messages: messages)?.question == "Limits?")
        // No message id: the latest finished answer's question.
        #expect(Self.send(.translate(.zh), messages: messages)?.question == "And the method?")
        // A question's id, or an unknown one: nothing.
        #expect(Self.send(.translate(.zh, messageID: "q1"), messages: messages) == nil)
        #expect(Self.send(.translate(.zh, messageID: "nope"), messages: messages) == nil)
        // Thorough re-asks that answer's question with the Thorough model.
        #expect(Self.send(.thorough(messageID: "a2"), messages: messages) == .init(question: "And the method?",
                                                                                     options: QAOptions(depth: .thorough)))
    }

    /// A one-off answer in another language doesn't change the thread's language (the toggle's).
    @Test func aOneOffLanguageLeavesTheThreadsLanguage() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env)
            let qa = await env.engine.qaService()
            let thread = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            await qa.setLanguage(threadID: thread.id, .en)
            let first = try #require(Kit.completed(await Kit.ask(env, qa, thread.id, "What is shown?",
                                                                options: QAOptions(language: .en))))
            #expect(await qa.thread(id: thread.id)?.language == .en)
            let messages = await qa.messages(threadID: thread.id)
            let send = try #require(QASendPlan.send(.translate(.zh, messageID: first.id), current: QAOptions(language: .en),
                                                     last: nil, threadID: thread.id, messages: messages, confirming: nil))
            let zh = try #require(Kit.completed(await Kit.ask(env, qa, thread.id, send.question, options: send.options,
                                                             gesture: .action)))
            #expect(zh.language == "zh")
            #expect(await qa.thread(id: thread.id)?.language == .en, "the toggle's language stays")
            #expect(await qa.messages(threadID: thread.id).map(\.text).filter { $0 == "What is shown?" }.count == 2)
        }
    }

    // MARK: QA-4 U2 the gesture of each click

    @Test func eachClickHasItsOwnGesture() {
        let table: [(QAIntent, Bool, ConsentTicket.Gesture)] = [
            (.ask("q"), true, .ask), (.ask("q"), false, .followUp), (.retry, false, .retry), (.retry, true, .retry),
            (.continuePastCap, false, .capOverride), (.confirmPrivacy, true, .action), (.confirmPrivacy, false, .action),
            (.thorough(messageID: "m"), false, .action), (.translate(.zh), false, .action), (.translate(.en, messageID: "m"), false, .action),
        ]
        for (intent, first, gesture) in table {
            #expect(intent.gesture(firstQuestion: first) == gesture, "\(intent) first=\(first)")
        }
    }

    @Test func theComposersQuestionIsTrimmedAndAnEmptyOneSendsNothing() {
        #expect(Self.send(.ask("  Why?\n")) == .init(question: "Why?", options: Self.current))
        #expect(Self.send(.ask(" \n ")) == nil)
    }
}
