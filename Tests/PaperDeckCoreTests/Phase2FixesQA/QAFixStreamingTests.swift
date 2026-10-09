import Foundation
import Testing
@testable import PaperDeckCore

/// Phase 2 fixes QA-11 (verifier v22) and QA-4's crash-recovery survivor Q5 (v23): an answer over
/// the output cap that arrives whole (`replace` / `done`, as Codex sends it) keeps its first
/// `maxOutputChars` characters — the lane ends it `.failed(.invalidOutput("output_cap"), partial:)`
/// and Q&A stores that text as a stopped answer marked cut off; a streaming answer's text is in the
/// database before it is shown, so a crash keeps it. Deterministic: no timing thresholds.
@Suite(.timeLimit(.minutes(2))) struct QAFixStreamingTests {
    private typealias Kit = QATestKit

    static func lane(_ backend: ScriptedBackend) -> AssistLane {
        let settings = SettingsBox(.mock)
        let gate = AssistGate(budget: RunBudget(), load: { settings.value }, pause: { _ in nil }, counter: AssistDailyCounter())
        return AssistLane(gate: gate, load: { settings.value }, backends: [backend])
    }

    static let limits = AssistLimits(firstTokenWatchdog: .seconds(30), turnTimeout: .seconds(60), maxOutputChars: 100)

    // MARK: QA-11 the lane

    @Test func aWholeReplaceOverTheCapKeepsItsFirstCharacters() async {
        let long = String(repeating: "abcde", count: 60)                   // 300 > 100
        let backend = ScriptedBackend(mode: .mock, scripts: [[.event(.waiting(warm: false)), .event(.replace(long)), .hang]])
        let lane = Self.lane(backend)                                     // held: the turn's task refers to it weakly
        let events = await collectEvents(await lane.submit(assistRequest(.qa, limits: Self.limits), ticket: .mint(.ask, surface: .qa)))
        #expect(events.last == .failed(.invalidOutput("output_cap"), partial: String(long.prefix(100))), "\(events)")
        #expect(events.replaces.isEmpty)                                  // nothing over the cap is shown
    }

    @Test func aWholeDoneOverTheCapKeepsItsFirstCharacters() async {
        let long = "Start \u{200B}" + String(repeating: "x", count: 500)
        let backend = ScriptedBackend(mode: .mock, scripts: [[.event(.waiting(warm: false)),
                                                              .event(.done(text: long, meta: AssistMeta(provider: "mock", model: "m")))]])
        let lane = Self.lane(backend)                                     // held: the turn's task refers to it weakly
        let events = await collectEvents(await lane.submit(assistRequest(.qa, limits: Self.limits), ticket: .mint(.ask, surface: .qa)))
        guard case .failed(.invalidOutput("output_cap"), let partial)? = events.last else { Issue.record("\(events)"); return }
        #expect(partial?.count == 100 && partial?.hasPrefix("Start x") == true, "sanitized, then cut: \(partial ?? "nil")")
        #expect(events.filter(\.isTerminal).count == 1)
    }

    @Test func aDeltaOverTheCapKeepsTheTextUpToTheCap() async {
        let backend = ScriptedBackend(mode: .mock, scripts: [[.event(.delta(String(repeating: "a", count: 60))),
                                                              .event(.delta(String(repeating: "b", count: 60))), .hang]])
        let lane = Self.lane(backend)                                     // held: the turn's task refers to it weakly
        let events = await collectEvents(await lane.submit(assistRequest(.qa, limits: Self.limits), ticket: .mint(.ask, surface: .qa)))
        #expect(events.last == .failed(.invalidOutput("output_cap"),
                                       partial: String(repeating: "a", count: 60) + String(repeating: "b", count: 40)))
        #expect(events.deltas.joined().count == 60)
    }

    @Test func anAnswerWithinTheCapIsUnchanged() async {
        let backend = ScriptedBackend(mode: .mock, scripts: [[.event(.replace("Short.")),
                                                              .event(.done(text: "Short.", meta: AssistMeta(provider: "mock", model: "m")))]])
        let lane = Self.lane(backend)                                     // held: the turn's task refers to it weakly
        let events = await collectEvents(await lane.submit(assistRequest(.qa, limits: Self.limits), ticket: .mint(.ask, surface: .qa)))
        #expect(events.doneText == "Short." && events.replaces == ["Short."])
    }

    // MARK: QA-11 Q&A keeps the cut answer

    /// v22: a 25,000-character whole answer (Q&A's cap is 20,000).
    @Test func qaKeepsAnOverlongWholeAnswerCutAndMarked() async throws {
        let long = String(repeating: "word ", count: 5_000)
        let scripted = ScriptedBackend(mode: .mock, scripts: [[.event(.waiting(warm: false)),
                                                               .event(.done(text: long, meta: AssistMeta(provider: "mock", model: "m")))]])
        try await Kit.run(backends: [scripted]) { env in
            let p = try await Kit.addPaper(env)
            let qa = await env.engine.qaService()
            let t = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            let events = await Kit.ask(env, qa, t.id, "Q?")
            let cap = AssistLimits.defaults(for: .qa, provider: nil).maxOutputChars
            #expect(events.last == .failed(.invalidOutput(QAService.outputCapKind), partial: String(long.prefix(cap))))
            let stored = try #require(await qa.messages(threadID: t.id).last)
            #expect(stored.role == .assistant && stored.text.count == cap)
            #expect(stored.state == .cancelled && stored.errorKind == QAService.outputCapKind)
            // Kept like a stopped answer: it can go to the notes.
            #expect(try await qa.saveToNotes(messageID: stored.id, paperIDs: [p.id]) == 1)
        }
    }

    // MARK: QA-4 Q5 crash recovery of a streaming answer

    /// v23, made deterministic: the text is saved before each delta is handed on (the interval set
    /// to zero), so when the consumer sees a delta the database already has it.
    @Test func aStreamingAnswersTextIsSavedBeforeItIsShownAndRecovered() async throws {
        let scripted = ScriptedBackend(mode: .mock, scripts: [[.event(.waiting(warm: false)), .event(.delta("First part ")),
                                                               .event(.delta("second part ")), .hang]])
        try await Kit.run(backends: [scripted]) { env in
            let p = try await Kit.addPaper(env)
            let qa = await env.engine.qaService()
            await qa.setPartialSaveInterval(.zero)
            let t = await qa.newThread(paperIDs: [p.id], mode: .fullText)
            let stream = await qa.ask(threadID: t.id, question: "Q?", options: QAOptions(), ticket: Kit.ticket(env))
            var seen = ""
            var checked = 0
            for await e in stream {
                guard case .delta(let s) = e else { continue }
                seen += s
                let row = try #require(try await env.db.qaMessages(threadID: t.id).last)
                // At least what was shown (the turn may already be a delta ahead).
                #expect(row.role == .assistant && row.state == .streaming && row.text.hasPrefix(seen), "\(row.text)")
                checked += 1
                if checked == 2 {
                    // A crash now: the next launch's recovery keeps the text, as stopped.
                    _ = try await env.db.recoverQA()
                    let recovered = try #require(try await env.db.qaMessages(threadID: t.id).last)
                    #expect(recovered.state == .cancelled && recovered.text == "First part second part ")
                    await qa.cancel(threadID: t.id)
                }
            }
            #expect(checked == 2)
        }
    }

    @Test func theDefaultSaveIntervalIsTwoSeconds() {
        #expect(QAService.partialSaveInterval == .seconds(2))
    }
}
