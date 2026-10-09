import Foundation
import Testing
@testable import PaperDeckCore

/// The selection-assist verifier's gate and lane probes (V6–V8), kept as regression tests: the
/// soft-cap override ticket is single-use and still counts against the hard cap; a ticket from the
/// future (clock skew) is refused and one exactly at its validity accepted; a refused submit never
/// marks the lane busy. Pure gates and the mock lane only.
@Suite struct P1FAssistGateProbeTests {
    @Test func theCapOverrideTicketIsSingleUseAndCountsAgainstTheHardCap() {
        var s = EngineSettings()
        s.assist.mode = .claude
        s.assist.dailySoftCap = 1
        s.assist.dailyHardCap = 3
        let settings = s
        let gate = AssistGate(budget: RunBudget(), load: { settings }, pause: { _ in nil }, counter: AssistDailyCounter())
        let now = Date()
        #expect(gate.checkTurn(.claude, ticket: .mint(.box, surface: .explain, now: now), now: now) == .allowed)
        #expect(gate.checkTurn(.claude, ticket: .mint(.box, surface: .explain, now: now), now: now) == .dailySoftCap(1))
        let over = ConsentTicket.mint(.capOverride, surface: .explain, now: now)
        #expect(gate.checkTurn(.claude, ticket: over, now: now) == .allowed)
        #expect(gate.checkTurn(.claude, ticket: over, now: now) == .consentReused)
        #expect(gate.checkTurn(.claude, ticket: .mint(.capOverride, surface: .explain, now: now), now: now) == .allowed)
        #expect(gate.checkTurn(.claude, ticket: .mint(.capOverride, surface: .explain, now: now), now: now) == .dailyHardCap(3))
    }

    @Test func ticketTimeEdges() {
        var s = EngineSettings()
        s.assist.mode = .mock
        let settings = s
        let gate = AssistGate(budget: RunBudget(), load: { settings }, pause: { _ in nil }, counter: AssistDailyCounter())
        let now = Date()
        #expect(gate.checkTurn(backend: .mock, ticket: .mint(.box, surface: .explain, now: now.addingTimeInterval(5)), now: now)
                == .consentExpired)
        #expect(gate.checkTurn(backend: .mock, ticket: .mint(.box, surface: .explain, now: now.addingTimeInterval(-60)), now: now)
                == .allowed)
        #expect(gate.checkTurn(backend: .mock, ticket: .mint(.box, surface: .explain, now: now.addingTimeInterval(-60.5)), now: now)
                == .consentExpired)
    }

    @Test(.timeLimit(.minutes(1))) func aRefusedSubmitNeverMarksTheLaneBusy() async {
        let s = EngineSettings()                                        // assist.mode off
        let gate = AssistGate(budget: RunBudget(), load: { s }, pause: { _ in nil }, counter: AssistDailyCounter())
        let lane = AssistLane(gate: gate, load: { s }, backends: [MockAssistBackend()])
        let r = AssistRequest(surface: .explain, systemPrompt: "x", turnText: "y", model: "m",
                              limits: AssistLimits.defaults(for: .explain, provider: nil))
        var events: [AssistEvent] = []
        for await e in await lane.submit(r, ticket: .mint(.box, surface: .explain)) { events.append(e) }
        #expect(events == [.failed(.refused(.disabled), partial: nil)])
        #expect(!lane.isBusyNow)
        #expect(await !lane.isBusy)
    }
}
