import Foundation
import Testing
@testable import PaperDeckCore

/// Slice 0 contract (READING_ASSIST_PLAN §4, §6.1): the `AssistLane` stub on `MockAssistBackend` —
/// the gate first, one generating turn app-wide (latest wins, the old one ends "stopped" with its
/// partial text), cancel, the busy flag, status, and a mode without a backend failing before
/// anything is consumed. Mock only.
/// `.timeLimit`: several turns here hang on purpose (`MockAssistBackend(.hang)`); a lost timeout or
/// stop must fail the suite, not hang `./test.sh` (Phase 1 fix F6).
@Suite(.timeLimit(.minutes(1))) struct AssistLaneStubTests {
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var settings: EngineSettings
        init(mode: AssistMode) { var s = EngineSettings(); s.assist.mode = mode; settings = s }
        var value: EngineSettings { lock.withLock { settings } }
        func set(_ mode: AssistMode) { lock.withLock { settings.assist.mode = mode } }
    }

    static func lane(_ mode: AssistMode, backend: MockAssistBackend = MockAssistBackend(), budget: RunBudget = RunBudget())
        -> (AssistLane, Box, AssistGate) {
        let box = Box(mode: mode)
        let gate = AssistGate(budget: budget, load: { box.value }, pause: { _ in nil }, counter: AssistDailyCounter())
        return (AssistLane(gate: gate, load: { box.value }, backends: [backend]), box, gate)
    }

    static func request(_ surface: AssistSurface = .explain, session: AssistSessionPolicy = .oneShot,
                        limits: AssistLimits? = nil) -> AssistRequest {
        AssistRequest(surface: surface, systemPrompt: "system", turnText: "<selection>text</selection>", model: "haiku",
                      session: session, limits: limits ?? AssistLimits.defaults(for: surface, provider: .claude))
    }

    static func collect(_ s: AsyncStream<AssistEvent>) async -> [AssistEvent] {
        var out: [AssistEvent] = []
        for await e in s { out.append(e) }
        return out
    }

    @Test func aMockTurnStreamsDeltasAndEndsOnce() async {
        let (lane, _, _) = Self.lane(.mock)
        let events = await Self.collect(await lane.submit(Self.request(), ticket: .mint(.box, surface: .explain)))
        #expect(events.filter(\.isTerminal).count == 1)
        guard case .done(let text, let meta)? = events.last else { Issue.record("no done: \(events)"); return }
        let deltas = events.compactMap { if case .delta(let s) = $0 { return s }; return nil }
        #expect(deltas.count >= 2 && deltas.joined() == text)
        #expect(text == MockAssistBackend.cannedAnswer(for: Self.request()))
        #expect(meta.provider == "mock" && meta.model == "haiku" && meta.turnIndex == 0)
        #expect(await assistEventually { await lane.isBusy == false && !lane.isBusyNow })   // idle just after the stream ends (ENV-1)
    }

    @Test func theGateRefusesBeforeTheBackendRuns() async {
        let backend = MockAssistBackend()
        let (lane, box, _) = Self.lane(.off, backend: backend)
        let off = await Self.collect(await lane.submit(Self.request(), ticket: .mint(.box, surface: .explain)))
        #expect(off == [.failed(.refused(.disabled), partial: nil)])
        box.set(.mock)
        let ticket = ConsentTicket.mint(.ask, surface: .qa)
        _ = await Self.collect(await lane.submit(Self.request(.qa), ticket: ticket))
        let reused = await Self.collect(await lane.submit(Self.request(.qa), ticket: ticket))
        #expect(reused == [.failed(.refused(.consentReused), partial: nil)])
        #expect(await backend.turns == 1)
    }

    @Test func aModeWithoutABackendFailsAndConsumesNothing() async {
        let budget = RunBudget(maxRuns: 5)
        let (lane, _, gate) = Self.lane(.claude, budget: budget)
        let ticket = ConsentTicket.mint(.ask, surface: .qa)
        let events = await Self.collect(await lane.submit(Self.request(.qa), ticket: ticket))
        #expect(events == [.failed(.unsupported(missingFlags: []), partial: nil)])
        #expect(budget.consumed == 0 && gate.todayCount(.claude, now: Date()) == 0)
        #expect(await lane.status().provider == .notInstalled)
    }

    @Test func aNewSubmitStopsTheRunningTurn() async throws {
        let (lane, _, _) = Self.lane(.mock, backend: MockAssistBackend(behavior: .hang))
        let first = await lane.submit(Self.request(), ticket: .mint(.box, surface: .explain))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await lane.isBusy && lane.isBusyNow)
        await lane.register(MockAssistBackend(behavior: .chunks(["second"])))
        let second = await lane.submit(Self.request(), ticket: .mint(.box, surface: .explain))
        let a = await Self.collect(first)
        let b = await Self.collect(second)
        #expect(a.last == .failed(.cancelled, partial: nil))
        #expect(a.filter(\.isTerminal).count == 1)
        if case .done(let text, _)? = b.last { #expect(text == "second") } else { Issue.record("\(b)") }
        #expect(await assistEventually { await lane.isBusy == false && !lane.isBusyNow })   // idle just after the stream ends (ENV-1)
    }

    @Test func cancelStopsOnlyItsSurfaceAndKeepsThePartialText() async throws {
        final class Seen: @unchecked Sendable {
            private let lock = NSLock(); private var events: [AssistEvent] = []
            func add(_ e: AssistEvent) { lock.withLock { events.append(e) } }
            var all: [AssistEvent] { lock.withLock { events } }
        }
        let slow = MockAssistBackend(behavior: .chunks(["one ", "two ", "three"]), delay: .milliseconds(250))
        let (lane, _, _) = Self.lane(.mock, backend: slow)
        let stream = await lane.submit(Self.request(.qa), ticket: .mint(.ask, surface: .qa))
        let seen = Seen()
        let reader = Task { for await e in stream { seen.add(e) } }
        #expect(await AgentQueueAssistHookTests.eventually { seen.all.contains(.delta("one ")) })
        await lane.cancel(surface: .explain)                                  // another surface: no effect
        #expect(await lane.isBusy)
        await lane.cancel(surface: .qa)
        await reader.value
        let events = seen.all
        guard case .failed(.cancelled, let partial)? = events.last else { Issue.record("\(events)"); return }
        #expect(partial?.hasPrefix("one") == true && partial != "one two three")
        #expect(events.filter(\.isTerminal).count == 1)
    }

    @Test func theTurnTimeoutEndsAHangingTurn() async {
        let (lane, _, _) = Self.lane(.mock, backend: MockAssistBackend(behavior: .hang))
        let limits = AssistLimits(firstTokenWatchdog: .milliseconds(30), turnTimeout: .milliseconds(120), maxOutputChars: 100)
        let events = await Self.collect(await lane.submit(Self.request(limits: limits), ticket: .mint(.box, surface: .explain)))
        #expect(events.contains(.phase(.stillWaiting)))
        #expect(events.last == .failed(.timeout, partial: nil))
    }

    @Test func turnIndicesCountPerThreadAndResetOnClose() async {
        let backend = MockAssistBackend()
        let (lane, _, _) = Self.lane(.mock, backend: backend)
        func turn() async -> Int? {
            let events = await Self.collect(await lane.submit(Self.request(.qa, session: .reuse(threadKey: "t1")),
                                                             ticket: .mint(.followUp, surface: .qa)))
            if case .done(_, let meta)? = events.last { return meta.turnIndex }
            return nil
        }
        #expect(await turn() == 0)
        #expect(await turn() == 1)
        await lane.closeSession(threadKey: "t1")
        #expect(await backend.closedSessions == ["t1"])
        #expect(await turn() == 0)
    }

    @Test func prewarmNeedsAFreshArmingToken() async {
        let backend = MockAssistBackend()
        let (lane, _, _) = Self.lane(.mock, backend: backend)
        await lane.prewarm(.arm(now: Date().addingTimeInterval(-ArmingToken.validity - 5)))
        #expect(await backend.prewarms == 0)
        await lane.prewarm(.arm())
        #expect(await backend.prewarms == 1)
    }

    @Test func theEngineRegistersOnlyTheMockAndWiresTheQueuesYieldHook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-assist-lane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let box = Box(mode: .claude)
        // test-engine-lint: built-in-assist-backends — this test checks the factory itself: mock card
        // providers register no CLI backend.
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: Engine.Dependencies(
            loadSettings: { box.value }, fetcher: nil, claude: MockAgentProvider(behavior: .notLoggedIn),
            codex: MockAgentProvider(behavior: .notLoggedIn), cliFacts: .inMemory(),
            loadMailSettings: { MailSettings() }, mailSecrets: InMemoryMailSecretStore()))
        // Injected (mock) card providers register no CLI backend: assist.mode claude can't reach a CLI.
        #expect(await engine.assist.registeredModes.isDisjoint(with: [.claude, .codex]))
        #expect(await engine.assist.registeredModes.contains(.mock))
        let events = await Self.collect(await engine.assist.submit(Self.request(), ticket: .mint(.box, surface: .explain)))
        #expect(events == [.failed(.unsupported(missingFlags: []), partial: nil)])
        #expect(engine.runBudget.consumed == 0)
        box.set(.mock)
        let mock = await Self.collect(await engine.assist.submit(Self.request(), ticket: .mint(.box, surface: .explain)))
        #expect(mock.last?.isTerminal == true)
        #expect(engine.assistGate.budget === engine.runBudget)
        #expect(engine.loadAssistReader() == CardPromptProfile.legacyCompBio.reader)
        await engine.shutdown()
    }
}
