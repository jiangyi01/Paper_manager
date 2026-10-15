import Foundation
import Testing
@testable import PaperDeckCore

/// Assist-surfaces fixes on Ask (hunt wave 2): Continue past the soft cap after "Send Anyway"
/// (assist-surfaces-2), Save to Notes only for an answer it can save and a readable error
/// (assist-surfaces-8), the typed question back after cancelling a confirmation (assist-surfaces-9).
/// The engines run only the scripted or the mock assist backend — no CLI, no quota.
@Suite(.timeLimit(.minutes(2))) struct ASAskFixTests {
    private typealias Kit = QATestKit
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func user(_ id: String, _ text: String, thread: String = "A") -> QAMessage {
        QAMessage(id: id, threadID: thread, role: .user, text: text, createdAt: t0)
    }

    // MARK: assist-surfaces-2

    /// The soft cap reached and a paper that needs confirmation: "Send Anyway" is refused at the
    /// cap, and [Continue] then sends that same question (it used to ask for the confirmation again,
    /// forever). The click sequence is AskSession's: `QASendPlan.send` for the click, `QASendPlan.sent`
    /// for what the surface remembers, the click's own gesture.
    @Test func continuePastTheSoftCapSendsTheConfirmedQuestion() async throws {
        let backend = ScriptedBackend(mode: .claude)
        try await Kit.run(mode: .claude, backends: [backend]) { env in
            var s = env.settings.value
            s.assist.dailySoftCap = 1
            s.assist.dailyHardCap = 50
            env.settings.value = s
            let p = try await Kit.addPaper(env)
            _ = try await env.db.modifyPaper(pk: p.pk) { $0.aiNote = ImportAnnotation.unpublishedHoldNote }
            let qa = await env.engine.qaService()
            let thread = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            #expect(await qa.privacy(paperIDs: [p.id]) != .ok)
            let first = await Kit.ask(env, qa, thread.id, "First?", options: QAOptions(privacyAcknowledged: true), gesture: .action)
            #expect(Kit.completed(first) != nil, "today = 1 = the soft cap")

            let q = "Second question?"
            var last: QASentQuestion? = QASendPlan.sent(.ask(q), .init(question: q, options: QAOptions()), threadID: thread.id)
            var confirming: (question: String, options: QAOptions)?
            var events = await Kit.ask(env, qa, thread.id, q, options: QAOptions(), gesture: .followUp)
            var trace: [String] = []
            for _ in 0..<4 {
                let intent: QAIntent
                if case .needsConfirmation? = events.last {
                    trace.append("confirm")
                    confirming = (q, QAOptions())
                    intent = .confirmPrivacy
                } else if case .failed(.refused(.dailySoftCap), _)? = events.last {
                    trace.append("softCap")
                    confirming = nil
                    intent = .continuePastCap
                } else {
                    trace.append(Kit.completed(events) != nil ? "answered" : "other: \(String(describing: events.last))")
                    break
                }
                let msgs = await qa.messages(threadID: thread.id)
                let send = try #require(QASendPlan.send(intent, current: QAOptions(), last: last, threadID: thread.id,
                                                        messages: msgs, confirming: confirming))
                last = QASendPlan.sent(intent, send, threadID: thread.id)
                events = await Kit.ask(env, qa, thread.id, send.question, options: send.options,
                                       gesture: intent.gesture(firstQuestion: false))
            }
            #expect(trace == ["confirm", "softCap", "answered"], "\(trace)")
            #expect(await backend.turns == 2, "the second question reached the backend once")
            // That send used the confirmation: what is remembered of it carries none.
            #expect(last?.acknowledged == false)
            let answered = await qa.messages(threadID: thread.id).filter { $0.role == .user }.map(\.text)
            #expect(answered == ["First?", q], "the refused question was stored once")
        }
    }

    @Test func onlySendAnywaysOwnSendIsRememberedAsAcknowledged() {
        let acked = QAOptions(depth: .thorough, privacyAcknowledged: true)
        let send = QASendPlan.Send(question: "Q", options: acked)
        let confirmed = QASendPlan.sent(.confirmPrivacy, send, threadID: "A")
        #expect(confirmed.acknowledged && !confirmed.options.privacyAcknowledged && confirmed.options.depth == .thorough)
        for intent: QAIntent in [.ask("Q"), .retry, .continuePastCap, .thorough(messageID: "a"), .translate(.zh, messageID: "a")] {
            #expect(!QASendPlan.sent(intent, send, threadID: "A").acknowledged, "\(intent)")
        }
        #expect(!QASendPlan.sent(.confirmPrivacy, .init(question: "Q", options: QAOptions()), threadID: "A").acknowledged)
        #expect(!QASentQuestion(threadID: "A", question: "Q", options: acked).acknowledged, "the default stays strict")
    }

    @Test func onlyContinueCarriesAnUnusedConfirmationOfTheSameQuestionAndThread() {
        let last = QASendPlan.sent(.confirmPrivacy, .init(question: "Q", options: QAOptions(privacyAcknowledged: true)),
                                   threadID: "A")
        let refused = [Self.user("q1", "Q")]                                   // stored, unanswered (refused at the cap)
        func send(_ intent: QAIntent, thread: String = "A", messages: [QAMessage] = refused) -> QASendPlan.Send? {
            QASendPlan.send(intent, current: QAOptions(), last: last, threadID: thread, messages: messages, confirming: nil)
        }
        #expect(send(.continuePastCap)?.options.privacyAcknowledged == true)
        #expect(send(.continuePastCap)?.question == "Q")
        #expect(send(.retry)?.options.privacyAcknowledged == false, "Try Again asks again")
        #expect(send(.continuePastCap, thread: "B", messages: [Self.user("b1", "Q", thread: "B")])?
            .options.privacyAcknowledged == false, "another thread")
        #expect(send(.continuePastCap, messages: [Self.user("q1", "Other")])?.options.privacyAcknowledged == false,
                "another question")
        // A Continue whose last send carried no confirmation stays without one.
        let plain = QASendPlan.sent(.ask("Q"), .init(question: "Q", options: QAOptions()), threadID: "A")
        #expect(QASendPlan.send(.continuePastCap, current: QAOptions(), last: plain, threadID: "A", messages: refused,
                                confirming: nil)?.options.privacyAcknowledged == false)
    }

    // MARK: assist-surfaces-8

    @Test func saveToNotesIsOfferedOnlyForWhatItCanSave() {
        func answer(_ state: QAMessage.State, _ text: String, role: AssistTurnText.Role = .assistant) -> QAMessage {
            QAMessage(threadID: "A", role: role, text: text, state: state, createdAt: Self.t0)
        }
        #expect(answer(.done, "Answer.").canSaveToNotes)
        #expect(answer(.cancelled, "Stopped part.").canSaveToNotes)
        #expect(!answer(.failed, "Partial answer").canSaveToNotes, "a timed-out answer's partial text")
        #expect(!answer(.streaming, "Partial").canSaveToNotes)
        #expect(!answer(.done, "  \n").canSaveToNotes)
        #expect(!answer(.done, "Question?", role: .user).canSaveToNotes)
    }

    /// A failed answer with partial text: Save to Notes isn't offered (`canSaveToNotes`), and the
    /// engine's refusal reads as a sentence in either language — never `notAnAnswer("…id…")`.
    @Test func aFailedAnswerIsNotSavedAndTheRefusalIsReadable() async throws {
        let backend = MockAssistBackend(behavior: .fail(.timeout, after: ["Partial ", "answer"]))
        try await Kit.run(backends: [backend]) { env in
            let p = try await Kit.addPaper(env)
            let qa = await env.engine.qaService()
            let t = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            _ = await Kit.ask(env, qa, t.id, "What?")
            let answer = try #require(await qa.messages(threadID: t.id).last)
            #expect(answer.state == .failed && !answer.text.isEmpty)
            #expect(!answer.canSaveToNotes)
            do {
                _ = try await qa.saveToNotes(messageID: answer.id, paperIDs: [p.id])
                Issue.record("expected a refusal")
            } catch let e as QAError {
                #expect(e == .notAnAnswer(answer.id))
                for lang in [UILang.en, .zh] {
                    let text = e.message(lang)
                    #expect(!text.contains("notAnAnswer") && !text.contains(answer.id) && !text.isEmpty, "\(text)")
                }
            }
        }
    }

    @Test func qaAndExplainErrorsHaveSentencesInBothLanguages() {
        let qa: [QAError] = [.unknownThread("t-1"), .unknownMessage("m-1"), .notAnAnswer("m-2"), .unsupportedSidecar("x/9")]
        let explain: [ExplainOperationError] = [.explanationNotFound("e-1"), .notMatched("e-2")]
        let texts = qa.flatMap { [$0.message(.en), $0.message(.zh)] } + explain.flatMap { [$0.message(.en), $0.message(.zh)] }
        for (i, text) in texts.enumerated() {
            #expect(!text.isEmpty)
            for raw in ["t-1", "m-1", "m-2", "x/9", "e-1", "e-2", "unknown", "notAn", "unsupported", "explanationNotFound", "notMatched"] {
                #expect(!text.contains(raw), "\(i): \(text)")
            }
        }
        // English and Chinese differ (a zh string is Chinese).
        for e in qa { #expect(e.message(.en) != e.message(.zh)) }
        for e in explain { #expect(e.message(.en) != e.message(.zh)) }
        #expect(qa.allSatisfy { $0.message(.zh).unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } })
    }

    // MARK: assist-surfaces-9

    @Test func cancellingAConfirmationPutsTheQuestionBack() {
        let q = "What does figure 3 show about the knockout?"
        // The composer was cleared when the question was sent; nothing was stored.
        #expect(QASendPlan.draftAfterDismissing(confirming: q, draft: "", messages: []) == q)
        #expect(QASendPlan.draftAfterDismissing(confirming: q, draft: "  ", messages: [Self.user("q0", "Earlier?")]) == q)
        // Something typed since stays.
        #expect(QASendPlan.draftAfterDismissing(confirming: q, draft: "A new one", messages: []) == "A new one")
        // A resend of the thread's own unanswered question: it is still there with [Try Again].
        #expect(QASendPlan.draftAfterDismissing(confirming: q, draft: "", messages: [Self.user("q1", q)]) == "")
        // Another notice: nothing to put back.
        #expect(QASendPlan.draftAfterDismissing(confirming: nil, draft: "", messages: []) == "")
    }
}
