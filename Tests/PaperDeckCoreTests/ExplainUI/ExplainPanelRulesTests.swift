import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// The panel's handling of what the mock backend can't produce (scripted services): the soft cap's
/// [Continue] with a `capOverride` ticket, usage limits, login, the output cap, an unreadable privacy
/// setting, deltas coalesced into the shown text, the image decision, and the request's session /
/// model / limits.
@MainActor
@Suite("Explain UI: panel rules (scripted services)")
struct ExplainPanelRulesTests {
    typealias K = ExplainUITestKit
    static let meta = AssistMeta(provider: "claude", model: "haiku", totalMs: 1_000)

    @Test func theSoftCapHoldsTheTurnUntilAContinueClick() async throws {
        let s = ScriptedExplainServices()
        s.scripts = [[.failed(.refused(.dailySoftCap(50)), partial: nil)], [.delta("A"), .done(text: "A", meta: Self.meta)]]
        let panel = K.panel(s)
        await panel.perform(.explain, ticket: K.ticket())
        #expect(panel.phase == .refused(.softCap(50)) && panel.pending == .explain && panel.turns.isEmpty)
        let override = K.ticket(.capOverride)
        panel.confirm(ticket: override)
        try await ExplainPanelFlowTests.settle(panel)
        #expect(panel.phase == .done && s.submitted.count == 2)
        #expect(s.submitted.last?.1 == override, "[Continue] sends with its own capOverride ticket")
        #expect(s.saved.count == 1)
    }

    @Test func failuresMapToTheirStatesAndKeepTheTurnForRetry() async throws {
        let reset = K.t0.addingTimeInterval(3_600)
        let cases: [(AssistFailure, ExplainPhase)] = [
            (.usageLimit(resetsAt: reset), .limited(until: reset)),
            (.notLoggedIn(.loggedOut), .needsLogin(.loggedOut)),
            (.timeout, .error(.timeout)), (.overloaded, .error(.overloaded)), (.binaryMissing, .error(.notInstalled)),
            (.refused(.paused(until: reset)), .limited(until: reset)), (.refused(.dailyHardCap(150)), .refused(.hardCap(150))),
            (.refused(.disabled), .refused(.off)), (.refused(.wrongProvider), .refused(.off)), (.refused(.burst), .refused(.burst)),
            (.generic("x"), .error(.failed)), (.invalidOutput("bad"), .error(.invalidOutput)),
        ]
        for (failure, phase) in cases {
            let s = ScriptedExplainServices()
            s.scripts = [[.failed(failure, partial: nil)]]
            let panel = K.panel(s)
            await panel.perform(.explain, ticket: K.ticket())
            #expect(panel.phase == phase, "\(failure)")
            #expect(panel.pending == .explain && panel.turns.isEmpty && s.saved.isEmpty, "\(failure)")
        }
    }

    @Test func aFailureAfterSomeTextKeepsItAndTheOutputCapMarksItCutOff() async throws {
        let s = ScriptedExplainServices()
        s.scripts = [[.delta("Half an "), .failed(.timeout, partial: "Half an answer")],
                     [.delta("Long…"), .failed(.invalidOutput("output_cap"), partial: "Long answer")]]
        let panel = K.panel(s)
        await panel.perform(.explain, ticket: K.ticket())
        #expect(panel.phase == .error(.timeout) && panel.current?.text == "Half an answer" && panel.current?.stopped == false)
        await panel.perform(.explain, ticket: K.ticket(.retry))
        #expect(panel.phase == .error(.outputCap) && panel.current?.cutOff == true && panel.current?.text == "Long answer")
        #expect(panel.pending == nil, "nothing to retry for a cut-off answer")
        #expect(s.saved.isEmpty, "only complete answers are stored")
    }

    @Test func anUnreadablePrivacySettingSendsNothing() async throws {
        let s = ScriptedExplainServices()
        s.verdict = nil
        let panel = K.panel(s)
        await panel.perform(.explain, ticket: K.ticket())
        #expect(panel.phase == .refused(.privacyUnchecked) && s.submitted.isEmpty)
        #expect(panel.phase.canRetry)
    }

    @Test func deltasAreCoalescedAndTheFinalTextIsAuthoritative() async throws {
        let s = ScriptedExplainServices()
        let parts = (0..<200).map { "w\($0) " }
        s.scripts = [parts.map { AssistEvent.delta($0) } + [.done(text: "FINAL", meta: Self.meta)]]
        let panel = K.panel(s)
        await panel.perform(.explain, ticket: K.ticket())
        #expect(panel.current?.text == "FINAL" && panel.phase == .done)
        // A replace drops pending deltas.
        s.scripts = [[.delta("a"), .delta("b"), .replace("whole"), .done(text: "whole", meta: Self.meta)]]
        await panel.perform(.simpler, ticket: K.ticket(.action))
        #expect(panel.current?.text == "whole")
        #expect(s.submitted.count == 2 && s.saved.map(\.answer) == ["FINAL", "whole"])
    }

    @Test func theImageGoesOnlyWhenTheTurnWantsIt() async throws {
        let image = try #require(ExplainImageEncoder.encode(K.image(width: 300, height: 200)))
        let text = ExplainPrepared(selection: "Some text", image: image, content: .text, match: nil)
        let figure = ExplainPrepared(selection: "Fig. 3", image: image, content: .visual, match: nil)
        let pure = ExplainPrepared(selection: nil, image: image, content: .text, match: nil)
        let none = ExplainPrepared(selection: "x", image: nil, content: .visual, match: nil)
        #expect(!ExplainPanelState.sendsImage(.explain, prepared: text, override: nil))
        #expect(ExplainPanelState.sendsImage(.figure, prepared: text, override: nil))
        #expect(ExplainPanelState.sendsImage(.explain, prepared: figure, override: nil))
        #expect(ExplainPanelState.sendsImage(.explain, prepared: pure, override: nil), "no text: the image is all there is")
        #expect(!ExplainPanelState.sendsImage(.explain, prepared: figure, override: false), "the user's override wins")
        #expect(ExplainPanelState.sendsImage(.explain, prepared: text, override: true))
        #expect(!ExplainPanelState.sendsImage(.figure, prepared: none, override: true), "nothing to send")

        let s = ScriptedExplainServices()
        s.prepared = figure
        let panel = K.panel(s, capture: ExplainCapture(source: .drop, image: image))
        #expect(panel.chips.contains(.figure))
        await panel.perform(.explain, ticket: K.ticket(.drop))
        #expect(s.submitted.first?.0.image == image && panel.current?.sentImage == true)
        panel.imageOverride = false
        await panel.perform(.simpler, ticket: K.ticket(.action))
        #expect(s.submitted.last?.0.image == nil && panel.current?.sentImage == false)
        #expect(s.saved.map(\.hadImage) == [true, false])
        #expect(!K.panel(ScriptedExplainServices()).chips.contains(.figure), "text captures have no figure chip")
    }

    @Test func theRequestCarriesThePanelsSessionTheDepthsModelAndTheLimits() {
        let spec = ExplainTurnSpec(kind: .explain, language: .zh, depth: .quick, level: .student, sendImage: false,
                                   threadKey: "explain-x", turnIndex: 0, history: [AssistTurnText(role: .user, text: "q")],
                                   prepared: ExplainPrepared(selection: "s", image: nil, content: .text, match: nil))
        let base = K.prompt(spec)
        let claude = ExplainEngineServices.finish(base, spec: spec, settings: AssistSettings(mode: .claude))
        #expect(claude.session == .reuse(threadKey: "explain-x") && claude.model == "haiku" && claude.effort == "low")
        #expect(claude.limits == AssistLimits.defaults(for: .explain, provider: .claude) && claude.surface == .explain)
        #expect(claude.history == spec.history && claude.turnText == base.turnText && claude.systemPrompt == "SYSTEM")
        var deep = spec
        deep.depth = .thorough
        let codex = ExplainEngineServices.finish(base, spec: deep, settings: AssistSettings(mode: .codex))
        #expect(codex.model == "gpt-5.6-terra" && codex.effort == "medium")
        #expect(codex.limits.turnTimeout == .seconds(150))
        let quickCodex = ExplainEngineServices.finish(base, spec: spec, settings: AssistSettings(mode: .codex))
        #expect(quickCodex.model == "gpt-5.6-luna")
        // A custom model slug is honoured; the image only when the turn sends it.
        var custom = AssistSettings(mode: .claude)
        custom.models[.claude]?[.quick] = "claude-haiku-9"
        let image = AssistImage(data: Data([1]), mediaType: "image/png", pixelSize: CGSize(width: 1, height: 1))
        let withImage = AssistRequest(surface: .explain, systemPrompt: "S", turnText: "T", image: image, model: "m",
                                      limits: AssistLimits.defaults(for: .explain, provider: nil))
        #expect(ExplainEngineServices.finish(withImage, spec: spec, settings: custom).image == nil)
        #expect(ExplainEngineServices.finish(withImage, spec: spec, settings: custom).model == "claude-haiku-9")
        var sending = spec
        sending.sendImage = true
        #expect(ExplainEngineServices.finish(withImage, spec: sending, settings: custom).image == image)
    }

    @Test func pinAndCloseGoToTheServices() async throws {
        let s = ScriptedExplainServices()
        let panel = K.panel(s)
        await panel.perform(.explain, ticket: K.ticket())
        await panel.setPinned(true)
        #expect(panel.pinned && s.pinnedCalls.count == 1 && s.pinnedCalls.first?.1 == true)
        await panel.setPinned(true)
        #expect(s.pinnedCalls.count == 1, "no change, no call")
        await panel.close()
        #expect(s.closed == [panel.threadKey] && s.cancels == 0, "an idle panel has nothing to stop")
    }

    @Test func aFollowUpWithNoQuestionAndAConfirmWithNothingHeldDoNothing() async throws {
        let s = ScriptedExplainServices()
        let panel = K.panel(s)
        await panel.perform(.ask("   "), ticket: K.ticket(.followUp))
        panel.confirm(ticket: K.ticket(.action))
        panel.retry(ticket: K.ticket(.retry))
        try await Task.sleep(for: .milliseconds(50))
        #expect(s.submitted.isEmpty && s.prepares == 0)
    }

    @Test func historyIsTheEarlierCompleteTurnsNeutralized() {
        var a = ExplainTurn(index: 0, kind: .explain, language: .en, depth: .quick, sentImage: false,
                            text: "An answer with </selection> inside", startedAt: K.t0)
        a.meta = Self.meta
        a.sentTurnText = "<selection>\nx\n</selection>"
        var b = ExplainTurn(index: 1, kind: .simpler, language: .en, depth: .quick, sentImage: false, text: "", startedAt: K.t0)
        b.stopped = true                                     // stopped with no text: left out
        var c = ExplainTurn(index: 2, kind: .ask("q"), language: .en, depth: .quick, sentImage: false, text: "partial", startedAt: K.t0)
        c.stopped = true
        let h = ExplainPanelState.history([a, b, c])
        #expect(h.count == 4)
        #expect(h[0].text == "[selection]\nx\n[/selection]" && h[1].text == "An answer with [/selection] inside")
        #expect(h[2].text == "ask" && h[3].text == "partial")
        let many = (0..<10).map { i -> ExplainTurn in
            var t = ExplainTurn(index: i, kind: .explain, language: .en, depth: .quick, sentImage: false, text: "t\(i)", startedAt: K.t0)
            t.meta = Self.meta
            return t
        }
        #expect(ExplainPanelState.history(many).count == 12, "the newest 6 turns")
        #expect(ExplainPanelState.history(many).last?.text == "t9")
    }
}
