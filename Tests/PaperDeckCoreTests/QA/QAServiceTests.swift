import Foundation
import Testing
@testable import PaperDeckCore

/// `QAService` bound to a library (READING_ASSIST_PLAN §6.4 C2/C3, §9.1 C "QA persistence (streaming
/// → done / cancelled; crash recovery)"): the turn through the lane with the mock backend, follow-ups
/// that resend the context, privacy before anything is stored or sent, `qa.json`, notes, deletion,
/// rebuild, several papers. Mock or scripted backends only; no CLI.
@Suite(.timeLimit(.minutes(1))) struct QAServiceTests {
    private typealias Kit = QATestKit

    // MARK: One question

    @Test func aQuestionIsStoredSentWithThePaperAndAnswered() async throws {
        let mock = MockAssistBackend()
        try await Kit.run(backends: [mock]) { env in
            let p = try await Kit.addPaper(env, title: "Zebrafish fins")
            let qa = await env.engine.qaService()
            let thread = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            #expect(await qa.threads(paperID: p.id).map(\.id) == [thread.id])     // listed before its first question
            let events = await Kit.ask(env, qa, thread.id, "What is shown?")
            guard case .started(let estimate)? = events.first else { Issue.record("\(events)"); return }
            #expect(estimate.pages == Array(1...12) && estimate.fullText && estimate.model == "mock")
            #expect(events.contains { if case .delta = $0 { return true }; return false })
            let answer = try #require(Kit.completed(events))
            #expect(answer.state == .done && answer.role == .assistant)
            #expect(answer.citations == [QACitation(page: 1, valid: true, quoteFound: false)])
            #expect(answer.language == "en" && answer.depth == .quick && answer.context?.fullText == true)

            let stored = await qa.messages(threadID: thread.id)
            #expect(stored.map(\.role) == [.user, .assistant] && stored.map(\.ord) == [0, 1])
            // Stored as completed (the time to first token isn't kept).
            var expected = answer
            expected.meta?.ttftMs = nil
            try #require(stored.count > 1)          // no index past a failed expectation (QA-15)
            #expect(stored[1] == expected)
            let saved = try #require(await qa.thread(id: thread.id))
            #expect(saved.persisted && saved.title == "What is shown?" && saved.scope == .paper)

            let request = try #require(await mock.lastRequest)
            #expect(request.surface == .qa && request.session == .oneShot && request.history.isEmpty)
            #expect(request.model == "mock" && request.effort == "low")
            #expect(request.systemPrompt.contains("untrusted DATA"))
            #expect(request.turnText.contains("<paper>\n[[p. 1]]\nMeasurements reported on page 1 describe"))
            #expect(request.turnText.contains("[[p. 12]]"))
            #expect(request.turnText.hasSuffix("<question>\nWhat is shown?\n</question>\n"))
            #expect(request.turnText.contains("Zebrafish fins"))
        }
    }

    @Test func followUpsResendTheContextWithTheConversation() async throws {
        let mock = MockAssistBackend()
        try await Kit.run(backends: [mock]) { env in
            let p = try await Kit.addPaper(env)
            let qa = await env.engine.qaService()
            let thread = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            _ = await Kit.ask(env, qa, thread.id, "First question?")
            let first = try #require(await mock.lastRequest)
            _ = await Kit.ask(env, qa, thread.id, "Second question?", gesture: .followUp)
            let second = try #require(await mock.lastRequest)
            let firstPrefix = try #require(first.turnText.components(separatedBy: "<task>").first)
            let secondPrefix = try #require(second.turnText.components(separatedBy: "<conversation>").first)
            #expect(firstPrefix == secondPrefix)                       // byte-identical paper blocks
            #expect(second.turnText.contains("<conversation>\n[user] First question?\n[assistant] Mock answer."))
            #expect(second.session == .oneShot && second.history.isEmpty)
            #expect(await qa.messages(threadID: thread.id).map(\.role) == [.user, .assistant, .user, .assistant])
            #expect(await mock.turns == 2)
        }
    }

    @Test func aRefusedQuestionStoresNoAnswerAndItsRetryReusesTheQuestion() async throws {
        let mock = MockAssistBackend()
        try await Kit.run(mode: .off, backends: [mock]) { env in
            let p = try await Kit.addPaper(env)
            let qa = await env.engine.qaService()
            let thread = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            let refused = await Kit.ask(env, qa, thread.id, "Why?")
            #expect(refused.last == .failed(.refused(.disabled), partial: nil))
            #expect(await qa.messages(threadID: thread.id).map(\.role) == [.user])
            #expect(await mock.turns == 0)
            env.settings.value.assist.mode = .mock
            let answered = await Kit.ask(env, qa, thread.id, "Why?", gesture: .retry)
            #expect(Kit.completed(answered) != nil)
            let stored = await qa.messages(threadID: thread.id)
            #expect(stored.map(\.role) == [.user, .assistant] && stored.map(\.text).first == "Why?")
        }
    }

    // MARK: Privacy

    @Test func neverUseAIRefusesBeforeAnythingIsStoredOrSent() async throws {
        let mock = MockAssistBackend()
        try await Kit.run(backends: [mock]) { env in
            let p = try await Kit.addPaper(env)
            try await env.engine.setPaperPolicy(paperID: p.id, confidential: false, neverAI: true)
            let qa = await env.engine.qaService()
            let thread = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            #expect(await qa.privacy(threadID: thread.id) == .blocked)
            let events = await Kit.ask(env, qa, thread.id, "Anything?", options: QAOptions(privacyAcknowledged: true))
            #expect(events == [.failed(.refused(.policyBlocked), partial: nil)])
            #expect(await qa.messages(threadID: thread.id).isEmpty)
            #expect(await qa.thread(id: thread.id)?.persisted == false)
            #expect(await mock.turns == 0)
            #expect(try await env.db.qaThreads(paperID: p.id).isEmpty)
        }
    }

    @Test func aConfidentialPaperAsksFirstAndKeepsItsThreadsOutOfQaJson() async throws {
        let mock = MockAssistBackend()
        try await Kit.run(backends: [mock]) { env in
            let p = try await Kit.addPaper(env)
            try await env.engine.setPaperPolicy(paperID: p.id, confidential: true, neverAI: false)
            let qa = await env.engine.qaService()
            let thread = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            let first = await Kit.ask(env, qa, thread.id, "Main result?")
            #expect(first == [.needsConfirmation([.markedConfidential])])
            #expect(await qa.messages(threadID: thread.id).isEmpty)
            #expect(await mock.turns == 0)
            // Confirmed (a fresh ticket from the confirmation click): it runs, stays in the DB only.
            let confirmed = await Kit.ask(env, qa, thread.id, "Main result?", options: QAOptions(privacyAcknowledged: true),
                                          gesture: .action)
            #expect(Kit.completed(confirmed) != nil)
            await qa.flushSidecars()
            #expect(!FileManager.default.fileExists(atPath: Kit.qaJSON(env, p).path))
            // Unmarked: qa.json appears; marked again: it goes.
            try await env.engine.setPaperPolicy(paperID: p.id, confidential: false, neverAI: false)
            await env.engine.syncQASidecar(paperID: p.id)
            #expect(FileManager.default.fileExists(atPath: Kit.qaJSON(env, p).path))
            try await env.engine.setPaperPolicy(paperID: p.id, confidential: true, neverAI: false)
            await env.engine.syncQASidecar(paperID: p.id)
            #expect(!FileManager.default.fileExists(atPath: Kit.qaJSON(env, p).path))
        }
    }

    @Test func aPapersMailOriginNeedsConfirmationToo() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env)
            _ = try await env.db.modifyPaper(pk: p.pk) { $0.aiNote = ImportAnnotation.unpublishedHoldNote }
            let qa = await env.engine.qaService()
            let thread = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            #expect(await Kit.ask(env, qa, thread.id, "Q?") == [.needsConfirmation([.mailUnpublished])])
        }
    }

    // MARK: Stopping

    @Test func cancelStopsTheTurnAndKeepsThePartialAnswer() async throws {
        let scripted = ScriptedBackend(mode: .mock, scripts: [[.event(.waiting(warm: false)), .event(.phase(.streaming)),
                                                               .event(.delta("Partial answer ")), .hang]])
        try await Kit.run(backends: [scripted]) { env in
            let p = try await Kit.addPaper(env)
            let qa = await env.engine.qaService()
            let thread = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            let stream = await qa.ask(threadID: thread.id, question: "Long?", options: QAOptions(), ticket: Kit.ticket(env))
            var events: [QAEvent] = []
            for await e in stream {
                events.append(e)
                if case .delta = e { await qa.cancel(threadID: thread.id) }
            }
            #expect(events.last == .failed(.cancelled, partial: "Partial answer "))
            let answer = try #require(await qa.messages(threadID: thread.id).last)
            #expect(answer.role == .assistant && answer.state == .cancelled && answer.text == "Partial answer ")
            #expect(answer.errorKind == "cancelled")
            #expect(await qa.isRunning(threadID: thread.id) == false)
        }
    }

    @Test func aNewerQuestionStopsTheOlderOne() async throws {
        let scripted = ScriptedBackend(mode: .mock, scripts: [
            [.event(.waiting(warm: false)), .event(.delta("Old ")), .hang],
            ScriptedBackend.answer("New answer [p. 2]."),
        ])
        try await Kit.run(backends: [scripted]) { env in
            let p = try await Kit.addPaper(env)
            let qa = await env.engine.qaService()
            let a = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            let b = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            let old = await qa.ask(threadID: a.id, question: "Old?", options: QAOptions(), ticket: Kit.ticket(env))
            var oldEvents: [QAEvent] = []
            var newEvents: [QAEvent] = []
            for await e in old {
                oldEvents.append(e)
                if case .delta = e { newEvents = await Kit.ask(env, qa, b.id, "New?") }
            }
            #expect(oldEvents.last == .failed(.cancelled, partial: "Old "))
            #expect(Kit.completed(newEvents)?.text == "New answer [p. 2].")
            #expect(await qa.messages(threadID: a.id).last?.state == .cancelled)
        }
    }

    // MARK: Failures and replace

    @Test func aUsageLimitIsStoredAsAFailedAnswerWithItsPartialText() async throws {
        let mock = MockAssistBackend()
        let resets = Date(timeIntervalSince1970: 1_800_000_000)
        await mock.enqueue(.fail(.usageLimit(resetsAt: resets), after: ["Part"]))
        try await Kit.run(backends: [mock]) { env in
            let p = try await Kit.addPaper(env)
            let qa = await env.engine.qaService()
            let thread = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            let events = await Kit.ask(env, qa, thread.id, "Q?")
            #expect(events.last == .failed(.usageLimit(resetsAt: resets), partial: "Part"))
            let answer = try #require(await qa.messages(threadID: thread.id).last)
            #expect(answer.state == .failed && answer.errorKind == "usage_limit" && answer.text == "Part")
            // A failed answer isn't part of the next question's conversation.
            _ = await Kit.ask(env, qa, thread.id, "Again?")
            #expect(await mock.lastRequest?.turnText.contains("<conversation>") == false)
        }
    }

    @Test func aWholeAnswerReplaceIsForwarded() async throws {
        let meta = AssistMeta(provider: "mock", model: "mock", totalMs: 4_000)
        let scripted = ScriptedBackend(mode: .mock, scripts: [[.event(.waiting(warm: false)),
                                                               .event(.replace("Whole answer [p. 2].")),
                                                               .event(.done(text: "Whole answer [p. 2].", meta: meta))]])
        try await Kit.run(backends: [scripted]) { env in
            let p = try await Kit.addPaper(env)
            let qa = await env.engine.qaService()
            let thread = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            let events = await Kit.ask(env, qa, thread.id, "Q?")
            #expect(events.contains(.replace("Whole answer [p. 2].")))
            let answer = try #require(Kit.completed(events))
            #expect(answer.meta?.totalMs == 4_000 && answer.citations.map(\.page) == [2])
            // The recent duration feeds the next estimate.
            let est = await qa.estimate(threadID: thread.id, question: "x", options: QAOptions())
            #expect(est.latency == 1...2)           // one sample: the mock default
        }
    }

    // MARK: Recovery

    @Test func bindingRecoversAnswersACrashLeftStreaming() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env)
            let gone = try await Kit.addPaper(env, title: "Gone")
            let t = try await env.db.insertQAThread(QAThread(paperIDs: [p.id], title: "t", mode: .fullText, createdAt: env.clock.value))
            try await env.db.insertQAMessage(QAMessage(threadID: t.id, role: .user, text: "q", createdAt: env.clock.value))
            let streaming = try await env.db.insertQAMessage(QAMessage(threadID: t.id, role: .assistant, text: "half",
                                                                       state: .streaming, createdAt: env.clock.value))
            let orphan = try await env.db.insertQAThread(QAThread(paperIDs: [gone.id], title: "o", mode: .fullText,
                                                                  createdAt: env.clock.value))
            try await env.db.hardDelete(pk: gone.pk)
            let qa = await env.engine.qaService()                   // first use binds and recovers
            let recovered = try #require(await qa.messages(threadID: t.id).last)
            #expect(recovered.id == streaming.id && recovered.state == .cancelled && recovered.text == "half")
            #expect(recovered.errorKind == "interrupted")
            #expect(try await env.db.qaThread(id: orphan.id) == nil)
            // Idempotent.
            await env.engine.recoverQA()
            #expect(await qa.messages(threadID: t.id).count == 2)
        }
    }

    // MARK: Notes

    @Test func saveToNotesAppendsTheAnswerOnce() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env)
            _ = try await env.engine.setNotes(paperID: p.id, "My own notes.")
            let qa = await env.engine.qaService()
            let thread = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            let answer = try #require(Kit.completed(await Kit.ask(env, qa, thread.id, "What is shown?")))
            try await qa.saveToNotes(messageID: answer.id)
            let notes = try await OpsTestKit.paper(env, p.id).notes
            #expect(notes == """
                My own notes.

                — 提问 · 2026-09-29 10:00 · Mock mock
                > 问：What is shown?
                Mock answer. The paper reports this in the Results section (p. 1).

                """)
            try await qa.saveToNotes(messageID: answer.id)
            #expect(try await OpsTestKit.paper(env, p.id).notes == notes)
            let question = try #require(await qa.messages(threadID: thread.id).first)
            await #expect(throws: QAError.notAnAnswer(question.id)) { try await qa.saveToNotes(messageID: question.id) }
            await #expect(throws: QAError.unknownMessage("nope")) { try await qa.saveToNotes(messageID: "nope") }
        }
    }

    // MARK: qa.json

    @Test func qaJsonFollowsTheThreadsAndRebuildsThem() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env)
            let qa = await env.engine.qaService()
            let thread = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            let answer = try #require(Kit.completed(await Kit.ask(env, qa, thread.id, "What is shown?")))
            await qa.flushSidecars()
            let url = Kit.qaJSON(env, p)
            let file = try QASidecar.decode(try Data(contentsOf: url))
            #expect(file.schema == "paperdeck.qa/1" && file.paperID == p.id)
            #expect(file.threads.map(\.id) == [thread.id] && file.threads[0].messages.map(\.role) == ["user", "assistant"])
            try #require(file.threads.count > 0 && file.threads[0].messages.count > 1)   // no index past a failed expectation (QA-15)
            #expect(file.threads[0].messages[1].citations == answer.citations)
            let bytes = try Data(contentsOf: url)
            #expect(String(decoding: bytes, as: UTF8.self).contains("\"schema\" : \"paperdeck.qa/1\""))

            // Rebuild: the database forgets the thread, qa.json brings it back.
            try await env.db.deleteQAThread(id: thread.id)
            #expect(await env.engine.restoreQASidecars(paperIDs: [p.id]) == 1)
            let restored = await qa.messages(threadID: thread.id)
            #expect(restored.map(\.id) == [restored[0].id, answer.id] && restored[1].text == answer.text)
            try #require(restored.count > 1)          // no index past a failed expectation (QA-15)
            #expect(restored[1].citations == answer.citations && restored[1].state == .done)
            #expect(await env.engine.restoreQASidecars(paperIDs: [p.id]) == 0)       // nothing twice

            // Deleting the answer, then the question (the thread goes with it), rewrites / removes it.
            try await qa.deleteMessage(id: answer.id)
            await qa.flushSidecars()
            #expect(try QASidecar.decode(try Data(contentsOf: url)).threads[0].messages.count == 1)
            try await qa.deleteMessage(id: restored[0].id)
            await qa.flushSidecars()
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(await qa.thread(id: thread.id) == nil)
            await #expect(throws: QAError.unknownMessage(answer.id)) { try await qa.deleteMessage(id: answer.id) }
        }
    }

    @Test func aMissingFolderIsNeverCreated() async throws {
        try await Kit.run { env in
            let p = try await Kit.addPaper(env)
            let folder = env.engine.ctx.folderURL(p)
            try FileManager.default.removeItem(at: folder)
            let qa = await env.engine.qaService()
            let thread = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            #expect(Kit.completed(await Kit.ask(env, qa, thread.id, "Q?")) != nil)
            await qa.flushSidecars()
            #expect(!FileManager.default.fileExists(atPath: folder.path))
        }
    }

    // MARK: Several papers

    @Test func aMultiPaperThreadLabelsThePapersAndValidatesTheirPages() async throws {
        let mock = MockAssistBackend()
        await mock.enqueue(.chunks(["A measures X [P1 p. 2] ", "while B measures Y [P2 p. 30] [P3 p. 1]."]))
        try await Kit.run(backends: [mock]) { env in
            let a = try await Kit.addPaper(env, title: "Paper A")
            let b = try await Kit.addPaper(env, title: "Paper B")
            let qa = await env.engine.qaService()
            let thread = await qa.newThread(paperIDs: [a.id, b.id], mode: .fullText)
            #expect(thread.scope == .multi)
            let answer = try #require(Kit.completed(await Kit.ask(env, qa, thread.id, "How do they differ?")))
            #expect(answer.citations.map(\.paper) == [1, 2, 3] && answer.citations.map(\.valid) == [true, false, false])
            let request = try #require(await mock.lastRequest)
            #expect(request.turnText.contains("<paper id=\"P1\">") && request.turnText.contains("<paper id=\"P2\">"))
            #expect(request.turnText.contains("P1 · Paper A") && request.turnText.contains("P2 · Paper B"))
            #expect(await qa.threads(paperID: b.id, scope: .multi).map(\.id) == [thread.id])
            #expect(await qa.threads(paperID: b.id, scope: .paper).isEmpty)
            // Multi-paper threads stay out of qa.json; notes go to the chosen paper only.
            await qa.flushSidecars()
            #expect(!FileManager.default.fileExists(atPath: Kit.qaJSON(env, a).path))
            #expect(try await qa.saveToNotes(messageID: answer.id, paperIDs: [b.id]) == 1)
            #expect(try await OpsTestKit.paper(env, a.id).notes.isEmpty)
            let notes = try await OpsTestKit.paper(env, b.id).notes
            #expect(notes.contains("> P1 = Paper A; P2 = Paper B") && notes.contains("(P1 · p. 2)"))
        }
    }

    @Test func theContextModeIsLimitedByTheNumberOfPapers() async throws {
        try await Kit.run { env in
            var ids: [String] = []
            for i in 1...4 { ids.append(try await Kit.addPaper(env, title: "P\(i)").id) }
            let qa = await env.engine.qaService()
            let four = await qa.newThread(paperIDs: ids, mode: .excerpts)
            await qa.setMode(threadID: four.id, .fullText)
            #expect(await qa.thread(id: four.id)?.mode == .excerpts)
            await qa.setMode(threadID: four.id, .cards)
            #expect(await qa.thread(id: four.id)?.mode == .cards)
            let est = await qa.estimate(threadID: four.id, question: "q", options: QAOptions())
            #expect(est.mode == .cards && est.pages.isEmpty && est.papers == 4)
            let one = await qa.newThread(paperIDs: [ids[0]], mode: .cards)
            #expect(one.mode == .fullText)
            await qa.setLanguage(threadID: one.id, .zh)
            #expect(await qa.thread(id: one.id)?.language == .zh)
        }
    }

    // MARK: Estimates and page selection

    @Test func anOversizedPaperSendsItsFirstPageAndTheMatchingOnes() async throws {
        let mock = MockAssistBackend()
        try await Kit.run(backends: [mock]) { env in
            env.settings.value.assist.qaTextBudget = 1_000
            let p = try await Kit.addPaper(env, pages: 30) { $0 == 22 ? "Zebrafish regeneration was striking." : "" }
            let qa = await env.engine.qaService()
            let thread = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            let est = await qa.estimate(threadID: thread.id, question: "zebrafish regeneration", options: QAOptions())
            #expect(!est.fullText && est.omitted > 0 && est.pages.first == 1 && est.pages.contains(22))
            #expect(est.estimatedTokens > 0 && est.provider == "mock")
            _ = await Kit.ask(env, qa, thread.id, "zebrafish regeneration")
            let text = try #require(await mock.lastRequest?.turnText)
            #expect(text.contains("[[p. 1]]") && text.contains("[[p. 22]]") && text.contains("omitted …]"))
        }
    }
}
