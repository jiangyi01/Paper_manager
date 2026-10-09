import Foundation
import Testing
@testable import PaperDeckCore
@testable import PaperDeckConfig

/// Phase-3 fixes, privacy & consent lane: the warm Claude process (F6 a prewarm never arms the idle
/// timer on a busy process, F8 the spawn flag is what allows the idle process) and the keep-warm
/// time (F7 an import or a hand-edited value never keeps it past the approved 3 minutes). A fake
/// `claude` script only (`FakeCLI.claudeBody`); no real CLI.
@Suite("Phase 3 fixes: the warm process and keep-warm", .serialized, .timeLimit(.minutes(1)))
struct P3FWarmProcessTests {
    /// The shortcut pressed while a turn streams: the busy process gets no idle timer, so it can't
    /// be closed under the turn (the verifier's probe, made strict).
    @Test func aPrewarmDuringATurnLeavesTheBusyProcessAlone() async throws {
        let cli = try FakeCLI(FakeCLI.claudeBody)
        try cli.put("sleep-1", "")                                  // the first turn hangs (30 s)
        try cli.copyFixture("claude-turn-success", as: "turn.jsonl")
        let sleeper = ManualSleeper()
        let (backend, _) = ClaudeAssistBackendTests.backend(cli, sleeper: sleeper, keepWarm: .seconds(30))
        let stream = backend.turn(assistRequest(session: .reuse(threadKey: "t")), turnIndex: 0)
        let reader = Task { await collectEvents(stream) }
        #expect(await assistEventually { cli.read("stdin.log") != nil })      // the turn is running
        await backend.prewarm()                                                  // ⌃⌥E pressed meanwhile
        try await Task.sleep(for: .milliseconds(200))
        #expect(sleeper.pending == 0, "no idle timer while a turn runs")
        sleeper.fire()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await backend.hasLiveProcess, "the busy process is still there")
        reader.cancel()
        _ = await reader.value
        await backend.closeAllSessions()
    }

    /// An idle warm process: the shortcut gives it its keep-warm time again (and the timer closes it).
    @Test func aPrewarmOfAnIdleProcessRestartsItsTimer() async throws {
        let cli = try FakeCLI(FakeCLI.claudeBody)
        try cli.copyFixture("claude-turn-success", as: "turn.jsonl")
        let sleeper = ManualSleeper()
        let (backend, _) = ClaudeAssistBackendTests.backend(cli, sleeper: sleeper, keepWarm: .seconds(30))
        _ = await collectEvents(backend.turn(assistRequest(session: .reuse(threadKey: "t")), turnIndex: 0))
        #expect(await assistEventually { sleeper.pending == 1 })                 // idle after the turn
        await backend.prewarm()
        #expect(await assistEventually { sleeper.pending == 1 && sleeper.requested.count == 2 })
        sleeper.fire()
        #expect(await assistEventually { !(await backend.hasLiveProcess) }, "idle: closed after keep-warm")
    }

    /// F8: a known spec alone doesn't start an idle process — the factory's flag must allow it.
    @Test func aSpecWithoutTheSpawnFlagStartsNothing() async throws {
        let cli = try FakeCLI(FakeCLI.claudeBody)
        try cli.copyFixture("claude-turn-success", as: "turn.jsonl")
        let spec = ClaudeAssistSession.Spec(assistRequest(session: .reuse(threadKey: "p")))
        let (backend, launcher) = ClaudeAssistBackendTests.backend(cli, prewarmSpec: spec, idleSpawn: false)
        await backend.prewarm()
        #expect(launcher.launchCount == 1, "the login is still re-checked (zero quota)")
        #expect(await backend.spawns == 0)
        #expect(!(await backend.hasLiveProcess))
        #expect(cli.read("argv.txt") == nil, "no process was started")
    }

    /// F7: "Keep Claude ready" is a switch: 0 or 180 s. An import accepts only those; the backend
    /// never keeps a process longer than 180 s whatever the stored value says.
    @Test func keepWarmIsTheSwitchsTwoValues() throws {
        let rule = try #require(SettingsRegistry.valueRules[AssistSettings.Keys.keepWarm])
        #expect(rule.validated(.number(0)) == .number(0) && rule.validated(.number(180)) == .number(180))
        for bad: JSONValue in [.number(30), .number(181), .number(3_600), .number(99_999), .number(-1), .number(180.5),
                               .string("180"), .bool(true), .null] {
            #expect(rule.validated(bad) == nil, "\(bad)")
        }
        #expect(ClaudeAssistBackend.maxKeepWarmSeconds == 180)
        #expect(ClaudeAssistBackend.keepWarm(seconds: 3_600) == .seconds(180))
        #expect(ClaudeAssistBackend.keepWarm(seconds: 180) == .seconds(180) && ClaudeAssistBackend.keepWarm(seconds: 60) == .seconds(60))
        #expect(ClaudeAssistBackend.keepWarm(seconds: 0) == .zero && ClaudeAssistBackend.keepWarm(seconds: -5) == .zero)
        // The factory hands the backend the clamped value.
        let factory = try String(contentsOf: LintRepo.url("Sources/PaperDeckCore/Assist/AssistBackendFactory.swift"), encoding: .utf8)
        #expect(factory.contains("keepWarm: { ClaudeAssistBackend.keepWarm(seconds: load().assist.keepWarmSeconds) },"))
    }
}
