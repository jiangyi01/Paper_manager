import Darwin
import Foundation
import Testing
@testable import PaperDeckCore

/// The real `AssistLane` (Slice A, behind Slice 0's API): the surface check before the gate, the
/// gate's budget/pause/burst on real turns, the usage-limit write-through, the output cap, the
/// sanitizer, status snapshots without detection, closing processes on a mode switch, and
/// latest-wins with the Claude backend on a fake CLI. Mock / scripted / fake only.
/// `.timeLimit`: some scripts hang on purpose; a lost stop fails instead of hanging (Phase 1 fix F6).
@Suite(.timeLimit(.minutes(1))) struct AssistLaneTests {
    static func lane(_ mode: AssistMode, backends: [any AssistBackend], budget: RunBudget = RunBudget(),
                     pause: PauseBox = PauseBox(), box: SettingsBox? = nil) -> (AssistLane, SettingsBox, AssistGate) {
        let settings = box ?? SettingsBox(mode)
        let gate = AssistGate(budget: budget, load: { settings.value }, pause: { pause.get($0) }, counter: AssistDailyCounter())
        return (AssistLane(gate: gate, load: { settings.value }, pause: { pause.get($0) }, backends: backends), settings, gate)
    }

    @Test func aTicketForAnotherSurfaceIsRefusedBeforeTheGate() async {
        let backend = ScriptedBackend(mode: .claude)
        let budget = RunBudget(maxRuns: 3)
        let (lane, _, gate) = Self.lane(.claude, backends: [backend], budget: budget)
        let ticket = ConsentTicket.mint(.box, surface: .explain)
        let events = await collectEvents(await lane.submit(assistRequest(.qa), ticket: ticket))
        #expect(events == [.failed(.refused(.consentMissing), partial: nil)])
        #expect(budget.consumed == 0 && gate.todayCount(.claude, now: Date()) == 0)
        #expect(await backend.turns == 0)
        // The same ticket still works for its own surface (it was not consumed).
        let ok = await collectEvents(await lane.submit(assistRequest(.explain), ticket: ticket))
        #expect(ok.doneText == "ok" && budget.consumed == 1)
    }

    @Test func everyRealTurnTakesOneRunAndTheBudgetEndsThem() async {
        let backend = ScriptedBackend(mode: .codex)
        let budget = RunBudget(maxRuns: 2)
        let (lane, _, gate) = Self.lane(.codex, backends: [backend], budget: budget)
        for _ in 0..<2 {
            let e = await collectEvents(await lane.submit(assistRequest(), ticket: .mint(.box, surface: .explain)))
            #expect(e.doneText == "ok")
        }
        let third = await collectEvents(await lane.submit(assistRequest(), ticket: .mint(.box, surface: .explain)))
        #expect(third == [.failed(.refused(.budgetExhausted), partial: nil)])
        #expect(await backend.turns == 2)
        #expect(gate.todayCount(.codex, now: Date()) == 2)
        // A pre-spawn needs a run left and consumes none.
        await lane.prewarm(.arm())
        #expect(await backend.prewarms == 0)
    }

    @Test func burstAndDailyCapsReachTheCallerAsRefusals() async {
        let backend = ScriptedBackend(mode: .claude)
        let box = SettingsBox(.claude)
        box.update { $0.assist.dailySoftCap = 7; $0.assist.dailyHardCap = 8 }
        let (lane, _, _) = Self.lane(.claude, backends: [backend], box: box)
        for _ in 0..<AssistGate.burstLimit {
            #expect(await collectEvents(await lane.submit(assistRequest(), ticket: .mint(.box, surface: .explain))).doneText == "ok")
        }
        #expect(await collectEvents(await lane.submit(assistRequest(), ticket: .mint(.box, surface: .explain)))
                == [.failed(.refused(.burst), partial: nil)])
        #expect(await backend.turns == AssistGate.burstLimit)
    }

    @Test func theSoftCapNeedsACapOverrideTicketAndTheHardCapNone() async {
        let backend = ScriptedBackend(mode: .codex)
        let box = SettingsBox(.codex)
        box.update { $0.assist.dailySoftCap = 1; $0.assist.dailyHardCap = 2 }
        let (lane, _, _) = Self.lane(.codex, backends: [backend], box: box)
        #expect(await collectEvents(await lane.submit(assistRequest(), ticket: .mint(.box, surface: .explain))).doneText == "ok")
        #expect(await collectEvents(await lane.submit(assistRequest(), ticket: .mint(.box, surface: .explain)))
                == [.failed(.refused(.dailySoftCap(1)), partial: nil)])
        #expect(await collectEvents(await lane.submit(assistRequest(), ticket: .mint(.capOverride, surface: .explain))).doneText == "ok")
        #expect(await collectEvents(await lane.submit(assistRequest(), ticket: .mint(.capOverride, surface: .explain)))
                == [.failed(.refused(.dailyHardCap(2)), partial: nil)])
        #expect(await backend.turns == 2)
    }

    @Test func aUsageLimitPausesTheProviderAndTheGateThenRefuses() async {
        let resets = Date().addingTimeInterval(1800)
        let backend = ScriptedBackend(mode: .claude, scripts: [[.event(.delta("par")), .event(.failed(.usageLimit(resetsAt: resets), partial: "par"))]])
        let pause = PauseBox()
        let (lane, _, _) = Self.lane(.claude, backends: [backend], pause: pause)
        final class Recorded: @unchecked Sendable {
            let lock = NSLock(); var calls: [(AIProviderKind, Date?)] = []
            func add(_ k: AIProviderKind, _ d: Date?) { lock.withLock { calls.append((k, d)) } }
        }
        let recorded = Recorded()
        await lane.setOnUsageLimit { kind, date in
            recorded.add(kind, date)
            pause.set(kind, date)                                    // what AgentQueue.recordUsageLimit does
        }
        var events: [AssistEvent] = []
        var pausedWhenSeen: Date?
        for await e in await lane.submit(assistRequest(), ticket: .mint(.box, surface: .explain)) {
            events.append(e)
            if case .failed = e { pausedWhenSeen = pause.get(.claude) }
        }
        #expect(events.last == .failed(.usageLimit(resetsAt: resets), partial: "par"))
        #expect(pausedWhenSeen == resets)                            // paused before the failure was shown
        #expect(recorded.lock.withLock { recorded.calls.count == 1 })
        #expect(recorded.lock.withLock { recorded.calls.first?.0 == .claude && recorded.calls.first?.1 == resets })
        let next = await collectEvents(await lane.submit(assistRequest(), ticket: .mint(.retry, surface: .explain)))
        #expect(next == [.failed(.refused(.paused(until: resets)), partial: nil)])
        #expect(await lane.status().pausedUntil == resets)
    }

    @Test func localAndMockFailuresNeverPauseAProvider() async {
        let backend = ScriptedBackend(mode: .local, scripts: [[.event(.failed(.usageLimit(resetsAt: nil), partial: nil))]])
        let (lane, _, _) = Self.lane(.local, backends: [backend])
        final class Flag: @unchecked Sendable { let lock = NSLock(); var hit = false }
        let flag = Flag()
        await lane.setOnUsageLimit { _, _ in flag.lock.withLock { flag.hit = true } }
        _ = await collectEvents(await lane.submit(assistRequest(), ticket: .mint(.box, surface: .explain)))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!flag.lock.withLock { flag.hit })
    }

    @Test func theOutputCapStopsARunawayAnswer() async {
        let chunk = String(repeating: "x", count: 40)
        let backend = ScriptedBackend(mode: .mock, scripts: [Array(repeating: ScriptedBackend.Step.event(.delta(chunk)), count: 10)
                                                             + [.hang]])
        let (lane, _, _) = Self.lane(.mock, backends: [backend])
        let limits = AssistLimits(firstTokenWatchdog: .seconds(5), turnTimeout: .seconds(5), maxOutputChars: 100)
        let events = await collectEvents(await lane.submit(assistRequest(limits: limits), ticket: .mint(.box, surface: .explain)))
        guard case .failed(.invalidOutput("output_cap"), let partial)? = events.last else { Issue.record("\(events)"); return }
        #expect((partial?.count ?? 0) <= 100 && partial?.hasPrefix(chunk) == true)
        #expect(events.deltas.joined().count <= 100)
        #expect(await assistEventually { await backend.terminations == 1 })     // the backend's stream was dropped
        #expect(await assistEventually { await lane.isBusy == false })      // the lane goes idle just after the stream ends (ENV-1: no race)
    }

    @Test func fragmentsAndTheAnswerAreSanitized() async {
        let bidi = "safe\u{202E}txt.exe\u{200B}"
        let answer = "**Gist.** See [the code](https://evil.example/x) and ![logo](https://evil.example/i.png)\r\n\r\n\r\n\r\nEnd \u{0007}"
        let backend = ScriptedBackend(mode: .mock, scripts: [[.event(.delta(bidi)), .event(.replace(bidi + "\u{0000}")),
                                                              .event(.done(text: answer, meta: AssistMeta(provider: "mock", model: "m")))]])
        let (lane, _, _) = Self.lane(.mock, backends: [backend])
        let events = await collectEvents(await lane.submit(assistRequest(), ticket: .mint(.box, surface: .explain)))
        #expect(events.deltas == ["safetxt.exe"] && events.replaces == ["safetxt.exe"])
        #expect(events.doneText == "**Gist.** See the code (https://evil.example/x) and logo\n\nEnd")
    }

    @Test func statusSnapshotsGoOutWithoutDetection() async {
        let backend = ScriptedBackend(mode: .claude, scripts: [[.sleep(.milliseconds(80))] + ScriptedBackend.answer("ok")])
        let (lane, _, _) = Self.lane(.claude, backends: [backend])
        final class Sink: @unchecked Sendable {
            let lock = NSLock(); var all: [AssistStatus] = []
            func add(_ s: AssistStatus) { lock.withLock { all.append(s) } }
        }
        let sink = Sink()
        await lane.setStatusSink { sink.add($0) }
        _ = await collectEvents(await lane.submit(assistRequest(), ticket: .mint(.box, surface: .explain)))
        #expect(await assistEventually { sink.lock.withLock { sink.all.count >= 2 } })
        let seen = sink.lock.withLock { sink.all }
        #expect(seen.first?.busy == true && seen.last?.busy == false)
        #expect(seen.last?.todayCount == 1 && seen.last?.provider == .unknown)
        #expect(await backend.detections == 0)
        // status() detects once and later snapshots reuse it.
        #expect(await lane.status().provider == .ready(plan: "test", version: "1"))
        #expect(await backend.detections == 1)
    }

    @Test func switchingModesClosesTheOtherBackendsProcesses() async {
        let claude = ScriptedBackend(mode: .claude)
        let codex = ScriptedBackend(mode: .codex)
        let (lane, box, _) = Self.lane(.claude, backends: [claude, codex])
        _ = await collectEvents(await lane.submit(assistRequest(), ticket: .mint(.box, surface: .explain)))
        #expect(await claude.closedAll == 0)
        #expect(await codex.closedAll == 0)
        box.update { $0.assist.mode = .codex }
        _ = await collectEvents(await lane.submit(assistRequest(), ticket: .mint(.box, surface: .explain)))
        #expect(await assistEventually { await claude.closedAll == 1 })
        #expect(await codex.closedAll == 0)
        await lane.closeAllSessions()
        #expect(await claude.closedAll == 2)
        #expect(await codex.closedAll == 1)
    }

    @Test func closingAThreadStopsItsRunningTurn() async {
        let backend = ScriptedBackend(mode: .mock, scripts: [[.event(.delta("a")), .hang]])
        let (lane, _, _) = Self.lane(.mock, backends: [backend])
        let stream = await lane.submit(assistRequest(.qa, session: .reuse(threadKey: "t9")), ticket: .mint(.ask, surface: .qa))
        let seen = SeenEvents()
        let reader = Task { () -> [AssistEvent] in
            for await e in stream { seen.append(e) }
            return seen.all
        }
        let timer = Task { try? await Task.sleep(for: .seconds(60)); reader.cancel() }
        // The delta has reached the reader — so the lane holds "a" as the partial text — before the
        // close. A fixed 30 ms sleep after `isBusy` sometimes closed first on a loaded machine
        // (partial nil; Phase 2 fix round, ENV-1).
        #expect(await assistEventually { seen.all.contains(.delta("a")) })
        await lane.closeSession(threadKey: "t9")
        let events = await reader.value
        timer.cancel()
        #expect(events.last == .failed(.cancelled, partial: "a"))
        #expect(await backend.closedSessions == ["t9"])
    }

    /// Latest wins for every backend, not only Claude's shared process: the lane itself stops the
    /// running turn (its stream is dropped) before the new one starts — one generating turn app-wide.
    @Test func aNewSubmitStopsTheRunningTurnOfAnyBackend() async {
        let backend = ScriptedBackend(mode: .codex, scripts: [[.event(.delta("first")), .hang], ScriptedBackend.answer("second")])
        let (lane, _, _) = Self.lane(.codex, backends: [backend])
        let limits = AssistLimits(firstTokenWatchdog: .seconds(5), turnTimeout: .seconds(20), maxOutputChars: 1_000)
        let first = await lane.submit(assistRequest(limits: limits), ticket: .mint(.box, surface: .explain))
        let reader = Task { await collectEvents(first) }
        #expect(await assistEventually { await backend.turns == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        let second = await collectEvents(await lane.submit(assistRequest(limits: limits), ticket: .mint(.lens, surface: .explain)))
        let a = await reader.value
        guard case .failed(.cancelled, let partial)? = a.last else { Issue.record("\(a)"); return }
        #expect(partial == nil || partial == "first")
        #expect(a.filter(\.isTerminal).count == 1)
        #expect(second.doneText == "second")
        #expect(await assistEventually { await backend.terminations == 1 })   // the first turn's stream was dropped
        #expect(await backend.turns == 2)
        #expect(await assistEventually { !lane.isBusyNow })      // the lane goes idle just after the stream ends (ENV-1: no race)
    }

    @Test func latestWinsWithTheClaudeBackendOnAFakeCLI() async throws {
        let cli = try FakeCLI(FakeCLI.claudeBody)
        try cli.put("sleep-1", "")
        try cli.copyFixture("claude-turn-success", as: "turn.jsonl")
        let claude = ClaudeAssistBackend(launcher: FakeLauncher(.ready(cli.launch(.claude))))
        let budget = RunBudget(maxRuns: 6)
        let (lane, _, _) = Self.lane(.claude, backends: [claude], budget: budget)
        let first = await lane.submit(assistRequest(session: .reuse(threadKey: "panel")), ticket: .mint(.box, surface: .explain))
        let reader = Task { await collectEvents(first) }
        #expect(await assistEventually { cli.read("stdin.log") != nil })
        let pid = try #require(Int32((cli.read("pids.txt") ?? "").split(separator: "\n").first ?? ""))
        #expect(lane.isBusyNow)
        let second = await collectEvents(await lane.submit(assistRequest(session: .reuse(threadKey: "panel")),
                                                           ticket: .mint(.lens, surface: .explain)))
        let a = await reader.value
        #expect(a.last == .failed(.cancelled, partial: nil) && a.filter(\.isTerminal).count == 1)
        #expect(second.doneText == ClaudeStreamParserTests.full)
        #expect(await assistEventually(.seconds(20)) { kill(pid, 0) != 0 })      // the stopped turn's process is gone
        #expect(budget.consumed == 2)
        #expect(await assistEventually { !lane.isBusyNow })      // the lane goes idle just after the stream ends (ENV-1: no race)
        await lane.closeAllSessions()
        #expect(await assistEventually { await !claude.hasLiveProcess })
    }

    @Test func theEngineWiringPausesTheQueueAndPublishesStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-assist-wire-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resets = Date().addingTimeInterval(3600)
        let scripted = ScriptedBackend(mode: .claude, scripts: [[.event(.failed(.usageLimit(resetsAt: resets), partial: nil))]])
        var s = EngineSettings(agentMode: .off, metadataLookup: false)
        s.assist.mode = .claude
        let settings = s
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: Engine.Dependencies(
            loadSettings: { settings }, fetcher: nil, claude: MockAgentProvider(behavior: .notLoggedIn),
            codex: MockAgentProvider(behavior: .notLoggedIn), cliFacts: .inMemory(),
            loadMailSettings: { MailSettings() }, mailSecrets: InMemoryMailSecretStore(), assistBackends: [scripted]))
        await engine.assist.wire(agents: engine.agents, events: engine.events)
        let events = engine.events.subscribe()
        let watcher = Task { () -> [AssistStatus] in
            var seen: [AssistStatus] = []
            for await e in events { if case .assistStatus(let st) = e { seen.append(st); if !st.busy { break } } }
            return seen
        }
        let turn = await collectEvents(await engine.assist.submit(assistRequest(), ticket: .mint(.box, surface: .explain)))
        #expect(turn.last == .failed(.usageLimit(resetsAt: resets), partial: nil))
        #expect(await assistEventually { engine.agents.pause(for: .claude) != nil })
        let until = try #require(engine.agents.pause(for: .claude))
        #expect(until >= resets)                                     // the card queue waits too (kv agent.claude.pausedUntil)
        #expect(try await engine.db.kv(AgentQueue.pausedUntilKey(for: .claude)) == Database.timestamp(until))
        let statuses = await watcher.value
        #expect(statuses.first?.busy == true && statuses.last?.busy == false)
        #expect(engine.runBudget.consumed == 1)
        await engine.shutdown()
    }

    @Test func theFactoryRegistersRealBackendsOnlyForRealProviders() throws {
        let paths = AppPaths.rooted(at: FileManager.default.temporaryDirectory.appendingPathComponent("pd-factory-\(UUID().uuidString)"))
        let load: @Sendable () -> EngineSettings = { EngineSettings() }
        let mocks = AssistBackendFactory.builtIn(claude: MockAgentProvider(), codex: MockAgentProvider(), paths: paths, load: load,
                                                 includeLocal: false)
        #expect(mocks.map(\.mode) == [.mock])
        // Real provider objects (built, never asked to do anything here): their assist backends join.
        let claude = ClaudeCodeProvider(locator: BinaryLocator(override: "/nonexistent/claude"), agentCwd: paths.agentCwd)
        let codex = CodexProvider(locator: CodexLocator(overrideSource: { "/nonexistent/codex" }), agentCwd: paths.agentCwd)
        let real = AssistBackendFactory.builtIn(claude: claude, codex: codex, paths: paths, load: load, includeLocal: false)
        #expect(real.map(\.mode) == [.mock, .claude, .codex])
    }
}

/// The events a test's reader has seen so far (read from another task while the stream runs).
private final class SeenEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AssistEvent] = []
    func append(_ e: AssistEvent) { lock.withLock { events.append(e) } }
    var all: [AssistEvent] { lock.withLock { events } }
}
