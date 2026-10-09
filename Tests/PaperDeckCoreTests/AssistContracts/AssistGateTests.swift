import Foundation
import Testing
@testable import PaperDeckCore

/// Slice 0 contract (READING_ASSIST_PLAN §9.1): every `AssistGate` verdict, ticket single use and
/// expiry, the shared RunBudget, pauses, burst and daily caps, and independence from `agent.mode`
/// and from `AgentSpawnGate`'s connection-test allowance. Pure: injected settings, clock and pauses.
@Suite struct AssistGateTests {
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var settings: EngineSettings
        private var pauses: [AIProviderKind: Date] = [:]
        init(_ s: EngineSettings) { settings = s }
        var value: EngineSettings { lock.withLock { settings } }
        func update(_ f: (inout EngineSettings) -> Void) { lock.withLock { f(&settings) } }
        func pause(_ kind: AIProviderKind) -> Date? { lock.withLock { pauses[kind] } }
        func setPause(_ kind: AIProviderKind, _ d: Date?) { lock.withLock { pauses[kind] = d } }
    }

    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21

    static func make(mode: AssistMode, agentMode: AgentMode = .off, budget: RunBudget = RunBudget(),
                     soft: Int = 50, hard: Int = 150) -> (AssistGate, Box) {
        var s = EngineSettings(agentMode: agentMode)
        s.assist.mode = mode
        s.assist.dailySoftCap = soft
        s.assist.dailyHardCap = hard
        let box = Box(s)
        let gate = AssistGate(budget: budget, load: { box.value }, pause: { box.pause($0) },
                              counter: AssistDailyCounter(calendar: Calendar(identifier: .gregorian)))
        return (gate, box)
    }

    static func ticket(_ g: ConsentTicket.Gesture = .ask, at t: Date = t0) -> ConsentTicket {
        ConsentTicket.mint(g, surface: .qa, now: t)
    }

    @Test func offRefusesEverythingAndConsumesNothing() {
        let budget = RunBudget(maxRuns: 3)
        let (gate, _) = Self.make(mode: .off, agentMode: .claude, budget: budget)
        let t = Self.ticket()
        #expect(gate.checkTurn(.claude, ticket: t, now: Self.t0) == .disabled)
        #expect(gate.checkTurn(.codex, ticket: t, now: Self.t0) == .disabled)
        #expect(gate.checkTurn(backend: .mock, ticket: t, now: Self.t0) == .disabled)
        #expect(gate.checkTurn(backend: .off, ticket: t, now: Self.t0) == .disabled)
        #expect(budget.consumed == 0 && gate.todayCount(.claude, now: Self.t0) == 0)
        #expect(!gate.checkSpawn(.claude, arming: .arm(now: Self.t0), now: Self.t0))
    }

    @Test func onlyTheModesProviderMayRun() {
        let (gate, _) = Self.make(mode: .claude)
        #expect(gate.checkTurn(.codex, ticket: Self.ticket(), now: Self.t0) == .wrongProvider)
        #expect(gate.checkTurn(backend: .mock, ticket: Self.ticket(), now: Self.t0) == .wrongProvider)
        #expect(gate.checkTurn(backend: .local, ticket: Self.ticket(), now: Self.t0) == .wrongProvider)
        #expect(gate.checkTurn(.claude, ticket: Self.ticket(), now: Self.t0) == .allowed)
        let (codex, _) = Self.make(mode: .codex)
        #expect(codex.checkTurn(.claude, ticket: Self.ticket(), now: Self.t0) == .wrongProvider)
        #expect(codex.checkTurn(.codex, ticket: Self.ticket(), now: Self.t0) == .allowed)
    }

    @Test func aTicketIsRequiredUsedOnceAndExpires() {
        let budget = RunBudget()
        let (gate, _) = Self.make(mode: .claude, budget: budget)
        #expect(gate.checkTurn(.claude, ticket: nil, now: Self.t0) == .consentMissing)
        let t = Self.ticket()
        #expect(gate.checkTurn(.claude, ticket: t, now: Self.t0.addingTimeInterval(1)) == .allowed)
        #expect(gate.checkTurn(.claude, ticket: t, now: Self.t0.addingTimeInterval(2)) == .consentReused)
        // Expired: older than the validity, or from the future (a clock moved backwards).
        let old = Self.ticket(at: Self.t0)
        #expect(gate.checkTurn(.claude, ticket: old, now: Self.t0.addingTimeInterval(ConsentTicket.validity + 1)) == .consentExpired)
        let future = Self.ticket(at: Self.t0.addingTimeInterval(30))
        #expect(gate.checkTurn(.claude, ticket: future, now: Self.t0) == .consentExpired)
        // Only the allowed turn consumed anything.
        #expect(budget.consumed == 1 && gate.todayCount(.claude, now: Self.t0) == 1)
        // A refused ticket is not consumed: after the refusal it still works (here: wrong → right mode).
        let (gate2, box) = Self.make(mode: .codex)
        let t2 = Self.ticket()
        #expect(gate2.checkTurn(.claude, ticket: t2, now: Self.t0) == .wrongProvider)
        box.update { $0.assist.mode = .claude }
        #expect(gate2.checkTurn(.claude, ticket: t2, now: Self.t0) == .allowed)
    }

    @Test func aPausedProviderIsRefusedUntilThePauseEnds() {
        let (gate, box) = Self.make(mode: .claude)
        let until = Self.t0.addingTimeInterval(3600)
        box.setPause(.claude, until)
        #expect(gate.checkTurn(.claude, ticket: Self.ticket(), now: Self.t0) == .paused(until: until))
        #expect(!gate.checkSpawn(.claude, arming: .arm(now: Self.t0), now: Self.t0))
        // Codex's pause doesn't affect Claude, and a past pause is over.
        box.setPause(.claude, Self.t0.addingTimeInterval(-1))
        box.setPause(.codex, until)
        #expect(gate.checkTurn(.claude, ticket: Self.ticket(), now: Self.t0) == .allowed)
    }

    @Test func atMostSixTurnsAMinute() {
        let (gate, _) = Self.make(mode: .claude)
        for i in 0..<AssistGate.burstLimit {
            let t = Self.t0.addingTimeInterval(Double(i))
            #expect(gate.checkTurn(.claude, ticket: Self.ticket(at: t), now: t) == .allowed)
        }
        let seventh = Self.t0.addingTimeInterval(10)
        #expect(gate.checkTurn(.claude, ticket: Self.ticket(at: seventh), now: seventh) == .burst)
        #expect(!gate.checkSpawn(.claude, arming: .arm(now: seventh), now: seventh))
        // A minute after the first turn a slot is free again.
        let later = Self.t0.addingTimeInterval(AssistGate.burstWindow + 0.5)
        #expect(gate.checkTurn(.claude, ticket: Self.ticket(at: later), now: later) == .allowed)
    }

    @Test func softCapNeedsACapOverrideTicketAndTheHardCapHasNone() {
        let (gate, _) = Self.make(mode: .claude, soft: 2, hard: 3)
        var t = Self.t0
        func next() -> Date { t = t.addingTimeInterval(61); return t }   // past the burst window each time
        let a = next(); #expect(gate.checkTurn(.claude, ticket: Self.ticket(at: a), now: a) == .allowed)
        let b = next(); #expect(gate.checkTurn(.claude, ticket: Self.ticket(at: b), now: b) == .allowed)
        let c = next(); #expect(gate.checkTurn(.claude, ticket: Self.ticket(at: c), now: c) == .dailySoftCap(2))
        #expect(gate.checkTurn(.claude, ticket: Self.ticket(.capOverride, at: c), now: c) == .allowed)
        let d = next()
        #expect(gate.checkTurn(.claude, ticket: Self.ticket(.capOverride, at: d), now: d) == .dailyHardCap(3))
        #expect(!gate.checkSpawn(.claude, arming: .arm(now: d), now: d))
        // The other provider has its own count.
        #expect(gate.todayCount(.codex, now: d) == 0 && gate.todayCount(.claude, now: d) == 3)
        // The next day starts at zero.
        let tomorrow = d.addingTimeInterval(86_400)
        #expect(gate.checkTurn(.claude, ticket: Self.ticket(at: tomorrow), now: tomorrow) == .allowed)
    }

    @Test func theSharedRunBudgetIsRespectedAndCounted() {
        let budget = RunBudget(maxRuns: 1)
        let (gate, _) = Self.make(mode: .claude, budget: budget)
        #expect(gate.checkTurn(.claude, ticket: Self.ticket(), now: Self.t0) == .allowed)
        #expect(budget.consumed == 1)
        let t = Self.t0.addingTimeInterval(1)
        let ticket = Self.ticket(at: t)
        #expect(gate.checkTurn(.claude, ticket: ticket, now: t) == .budgetExhausted)
        #expect(!gate.checkSpawn(.claude, arming: .arm(now: t), now: t))
        // The refused ticket wasn't consumed, nor was the day counted.
        #expect(gate.todayCount(.claude, now: t) == 1)
        budget.setLimit(2)
        #expect(gate.checkTurn(.claude, ticket: ticket, now: t) == .allowed)
        // The card spawn gate sees the same budget.
        let spawn = AgentSpawnGate(budget: budget, loadSettings: { EngineSettings(agentMode: .claude) })
        #expect(spawn.check(provider: .claude, summary: "t") == .budgetExhausted)
    }

    @Test func independentOfAgentModeAndOfTheConnectionTestAllowance() {
        // Card reading on, assist off: refused. Card reading off, assist on: allowed.
        let (offGate, _) = Self.make(mode: .off, agentMode: .claude)
        #expect(offGate.checkTurn(.claude, ticket: Self.ticket(), now: Self.t0) == .disabled)
        let budget = RunBudget()
        let (gate, box) = Self.make(mode: .claude, agentMode: .off, budget: budget)
        #expect(gate.checkTurn(.claude, ticket: Self.ticket(), now: Self.t0) == .allowed)
        // A connection test opens AgentSpawnGate's allowance for cards only; the assist gate neither
        // uses nor changes it.
        let spawn = AgentSpawnGate(budget: budget, loadSettings: { box.value })
        spawn.beginConnectionTest(provider: .claude, spawns: 1)
        box.update { $0.assist.mode = .off }
        #expect(gate.checkTurn(.claude, ticket: Self.ticket(), now: Self.t0) == .disabled)
        #expect(spawn.isTestingConnection)
        #expect(spawn.check(provider: .claude, summary: "test") == .allowed)
        #expect(spawn.check(provider: .claude, summary: "test") == .testAllowanceExhausted)
        spawn.endConnectionTest()
        // And card reading still follows agent.mode only (off here).
        #expect(spawn.check(provider: .claude, summary: "card") == .modeNotActive(provider: .claude, mode: .off))
    }

    @Test func mockAndLocalNeedConsentButNoQuota() {
        let budget = RunBudget(maxRuns: 0)
        let (gate, _) = Self.make(mode: .mock, budget: budget)
        #expect(gate.checkTurn(backend: .mock, ticket: nil, now: Self.t0) == .consentMissing)
        let t = Self.ticket()
        #expect(gate.checkTurn(backend: .mock, ticket: t, now: Self.t0) == .allowed)
        #expect(gate.checkTurn(backend: .mock, ticket: t, now: Self.t0) == .consentReused)
        #expect(budget.consumed == 0)
        let (local, _) = Self.make(mode: .local, budget: budget)
        #expect(local.checkTurn(backend: .local, ticket: Self.ticket(), now: Self.t0) == .allowed)
    }

    @Test func spawnNeedsAFreshArmingTokenAndTheMode() {
        let budget = RunBudget(maxRuns: 5)
        let (gate, _) = Self.make(mode: .claude, budget: budget)
        #expect(!gate.checkSpawn(.claude, arming: nil, now: Self.t0))
        #expect(gate.checkSpawn(.claude, arming: .arm(now: Self.t0), now: Self.t0))
        #expect(!gate.checkSpawn(.claude, arming: .arm(now: Self.t0), now: Self.t0.addingTimeInterval(ArmingToken.validity + 1)))
        #expect(!gate.checkSpawn(.codex, arming: .arm(now: Self.t0), now: Self.t0))
        #expect(budget.consumed == 0)                                    // a pre-spawn consumes nothing
    }

    @Test func dailyCounterPersistsAndRestoresPerDayAndProvider() {
        final class Sink: @unchecked Sendable {
            let lock = NSLock(); var rows: [String: Int] = [:]
            func put(_ k: String, _ v: Int) { lock.withLock { rows[k] = v } }
        }
        let sink = Sink()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let counter = AssistDailyCounter(calendar: cal, persist: { sink.put($0, $1) })
        counter.increment(at: Self.t0, provider: "claude")
        counter.increment(at: Self.t0, provider: "claude")
        counter.increment(at: Self.t0, provider: "codex")
        let day = LocalDate.today(now: Self.t0, calendar: cal).iso
        #expect(sink.rows == ["assist.count.\(day).claude": 2, "assist.count.\(day).codex": 1])
        let restored = AssistDailyCounter(calendar: cal)
        restored.restore(sink.rows.mapValues(String.init).merging(["other.key": "9", "assist.count.bad": "x"]) { a, _ in a })
        #expect(restored.count(at: Self.t0, provider: "claude") == 2 && restored.count(at: Self.t0, provider: "codex") == 1)
        #expect(restored.staleKeys(["assist.count.2000-01-01.claude", "assist.count.\(day).claude", "x"], now: Self.t0)
                == ["assist.count.2000-01-01.claude"])
        let judge = AssistDailyCounter(prefix: AssistDailyCounter.dedupeJudgePrefix, calendar: cal)
        #expect(judge.key(day: LocalDate.today(now: Self.t0, calendar: cal), provider: nil) == "dedupe.ai.count.\(day)")
    }
}
