import Foundation
import Testing
@testable import PaperDeckCore

/// Assist-surfaces fixes on the Explain panel (hunt wave 2): [Continue] past the soft cap with "Ask
/// before every send" on (assist-surfaces-1), closing a panel that is still reading its capture
/// (assist-surfaces-5), and where a ⇧-click term's match correction is remembered
/// (assist-surfaces-6). Engines run only the scripted or the mock assist backend — no CLI, no quota.
@Suite(.timeLimit(.minutes(2))) struct ASExplainPanelFixTests {
    private typealias K = ExplainUITestKit

    /// The panel's debounce clock: every gesture a little later than the last.
    final class Clock: @unchecked Sendable {
        private var t = Date(timeIntervalSince1970: 1_000_000)
        func next() -> Date { t = t.addingTimeInterval(2); return t }
    }

    // MARK: assist-surfaces-1

    /// Soft cap 1 and "Ask before every send" on: [Send] is refused at the cap, [Continue] sends that
    /// held turn (it used to be held for [Send] again, forever), and the next send still asks first.
    @MainActor
    @Test func continuePastTheSoftCapSendsTheHeldTurnWithAskBeforeEverySend() async throws {
        let backend = ScriptedBackend(mode: .claude)
        let env = try await QATestKit.make(mode: .claude, backends: [backend])
        do {
            var s = env.settings.value
            s.assist.dailySoftCap = 1
            s.assist.dailyHardCap = 50
            s.assist.explainAskBeforeSend = true
            env.settings.value = s
            let services = ExplainEngineServices(engine: env.engine, prepare: { capture, _ in
                ExplainPrepared(selection: capture.text, image: nil, content: .text, match: nil)
            }, build: { K.prompt($0) })
            let panel = ExplainPanelState(capture: ExplainCapture(source: .clipboard, text: K.excerpt), services: services,
                                          language: .en, depth: .quick)
            let clock = Clock()
            panel.clock = { clock.next() }
            func t(_ g: ConsentTicket.Gesture) -> ConsentTicket { .mint(g, surface: .explain, now: env.clock.value) }

            await panel.perform(.explain, ticket: t(.clipboard))
            #expect(panel.phase == .refused(.askBeforeSend))
            panel.confirm(ticket: t(.action)); await panel.settled()
            #expect(panel.phase == .done, "the first turn (today = 1 = the soft cap)")

            panel.run(.simpler, ticket: t(.action)); await panel.settled()
            #expect(panel.phase == .refused(.askBeforeSend), "every send asks")
            panel.confirm(ticket: t(.action)); await panel.settled()                    // [Send]
            #expect(panel.phase == .refused(.softCap(1)))
            panel.confirm(ticket: t(.capOverride)); await panel.settled()               // [Continue]
            #expect(panel.phase == .done, "[Continue] sent the held turn: \(panel.phase)")
            #expect(await backend.turns == 2)
            #expect(panel.current?.kind == .simpler)

            // [Continue] covered that one send: the next one asks again, and passes the cap the same way.
            panel.run(.technical, ticket: t(.action)); await panel.settled()
            #expect(panel.phase == .refused(.askBeforeSend))
            #expect(await backend.turns == 2)
            panel.confirm(ticket: t(.action)); await panel.settled()
            #expect(panel.phase == .refused(.softCap(1)))
            panel.confirm(ticket: t(.capOverride)); await panel.settled()
            #expect(panel.phase == .done && panel.current?.kind == .technical)
            #expect(await backend.turns == 3)
        }
        await env.cleanup()
    }

    /// A [Send] given for a held turn that then stopped at another hold is not left over for a
    /// different, later chip: that chip asks for its own [Send].
    @MainActor
    @Test func aSendConfirmationCoversOnlyItsHeldTurn() async throws {
        let s = ScriptedExplainServices()
        s.settings.explainAskBeforeSend = true
        let panel = K.panel(s)
        let clock = Clock()
        panel.clock = { clock.next() }
        await panel.perform(.explain, ticket: K.ticket())
        #expect(panel.phase == .refused(.askBeforeSend))
        // Meanwhile the paper's policy changed: [Send] stops at the privacy confirmation.
        s.verdict = .confirm([.markedConfidential])
        panel.confirm(ticket: K.ticket(.action)); await panel.settled()
        #expect(panel.phase == .refused(.confirmPrivacy([.markedConfidential])))
        // The user clicks another chip instead, then confirms the paper: that chip asks for [Send].
        panel.run(.simpler, ticket: K.ticket(.action)); await panel.settled()
        #expect(panel.phase == .refused(.confirmPrivacy([.markedConfidential])))
        panel.confirm(ticket: K.ticket(.action)); await panel.settled()
        #expect(panel.phase == .refused(.askBeforeSend), "the earlier [Send] was for another turn")
        #expect(s.submitted.isEmpty)
        panel.confirm(ticket: K.ticket(.action)); await panel.settled()
        #expect(panel.phase == .done && s.submitted.count == 1 && panel.current?.kind == .simpler)
    }

    // MARK: assist-surfaces-5

    /// Esc on a panel still reading its capture (`.locating`) leaves a pinned panel's streaming
    /// answer alone; closing the pinned panel itself still stops its own turn.
    @MainActor
    @Test func closingAPanelThatIsStillLocatingLeavesAPinnedAnswerRunning() async throws {
        let w = try await K.world(mode: .mock, behavior: .hang)
        defer { Task { await w.close() } }
        let fast = K.services(w)
        let slow = ExplainEngineServices(engine: w.engine, prepare: { capture, _ in
            try? await Task.sleep(for: .seconds(5))                               // OCR + the locator still running
            return ExplainPrepared(selection: capture.text, image: nil, content: .text, match: nil)
        }, build: { K.prompt($0) })
        let a = K.panel(fast)
        await a.setPinned(true)
        a.run(.explain, ticket: K.ticket(.box))
        for _ in 0..<300 where !(a.phase == .sending(.waiting) || a.phase == .streaming) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(a.isRunning, "A is answering: \(a.phase)")
        #expect(await w.engine.assist.isBusy)

        let b = K.panel(slow)
        b.run(.explain, ticket: K.ticket(.lens))
        for _ in 0..<100 where b.phase != .locating { try await Task.sleep(for: .milliseconds(10)) }
        #expect(b.phase == .locating)
        await b.close()                                                           // Esc on B
        try await Task.sleep(for: .milliseconds(300))
        #expect(a.isRunning, "closing B stopped A's answer: \(a.phase)")
        #expect(a.current?.stopped == false)
        #expect(await w.engine.assist.isBusy, "A's turn is still the lane's")

        await a.close()                                                           // A's own close stops A's own turn
        var idle = false
        for _ in 0..<500 {
            if !(await w.engine.assist.isBusy) { idle = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(idle, "closing A stops A's turn")
        #expect(await w.mock.closedSessions.contains(a.threadKey))
        #expect(await w.mock.closedSessions.contains(b.threadKey))
    }

    // MARK: assist-surfaces-6

    static let term = "softmax"
    static let paragraph = "We regularize the attention weights by a temperature-scaled softmax over the keys of each head."

    /// A ⇧-click term in a window with a generic title: the correction is remembered under the
    /// paragraph the locator matched (what it looks the correction up by when explaining again), and
    /// under the term too.
    @MainActor
    @Test func aTermCorrectionIsFoundUnderTheParagraphTheLocatorUses() async throws {
        let s = ScriptedExplainServices()
        s.prepared = ExplainPrepared(selection: Self.term, image: nil, content: .text,
                                     match: PaperMatch(paperID: "paper-x", page: 3, via: .text, score: 0.6),
                                     selectionIsExact: false, locatedText: Self.paragraph)
        let panel = K.panel(s, capture: ExplainCapture(source: .lens, windowTitle: "paper.pdf"))
        await panel.perform(.explain, ticket: K.ticket(.lens))
        #expect(panel.phase == .done)
        #expect(panel.excerpt == Self.term, "the panel shows the term")
        #expect(panel.correctionExcerpts == [Self.paragraph, Self.term])

        let c = PaperMatchCorrections()
        let scope = ObjectIdentifier(c)
        let now = Date()
        // The window title is generic and the term short: under the term alone nothing is remembered.
        #expect(PaperMatchCorrections.keys(windowTitle: "paper.pdf", excerpt: panel.excerpt).isEmpty)

        c.reject("paper-x", windowTitle: "paper.pdf", excerpts: panel.correctionExcerpts, scope: scope, now: now)
        // The locator asks with `around ?? selection` — the paragraph.
        var said = c.decisions(windowTitle: "paper.pdf", excerpt: Self.paragraph, scope: scope, now: now)
        #expect(said.rejected == ["paper-x"] && said.chosen == nil)

        c.choose("paper-y", windowTitle: "paper.pdf", excerpts: panel.correctionExcerpts, scope: scope,
                 now: now.addingTimeInterval(1))
        said = c.decisions(windowTitle: "paper.pdf", excerpt: Self.paragraph, scope: scope, now: now.addingTimeInterval(2))
        #expect(said.chosen == "paper-y")
        // A long term is remembered under itself too (robust if the locator ever asks with it).
        let long = "backpropagation through time"
        c.choose("paper-z", windowTitle: nil, excerpts: [Self.paragraph, long], scope: scope, now: now.addingTimeInterval(3))
        #expect(c.decisions(windowTitle: nil, excerpt: long, scope: scope, now: now.addingTimeInterval(4)).chosen == "paper-z")
    }

    /// A selection that is itself what the locator used (a box, the clipboard): one excerpt, the
    /// window's key once.
    @MainActor
    @Test func aPlainSelectionIsRememberedOnce() async throws {
        let s = ScriptedExplainServices()
        s.prepared = ExplainPrepared(selection: Self.paragraph, image: nil, content: .text, match: nil, locatedText: Self.paragraph)
        let panel = K.panel(s, capture: ExplainCapture(source: .region, windowTitle: "Attention heads — Preview"))
        await panel.perform(.explain, ticket: K.ticket(.box))
        #expect(panel.correctionExcerpts == [Self.paragraph])
        let keys = PaperMatchCorrections.keys(windowTitle: "Attention heads — Preview", excerpts: panel.correctionExcerpts)
        #expect(keys.count == 2 && Set(keys).count == 2, "\(keys)")
        // Nothing prepared yet (an old fixture without `locatedText`): the excerpt alone.
        let fresh = K.panel(ScriptedExplainServices())
        #expect(fresh.correctionExcerpts == [K.excerpt])
    }
}
