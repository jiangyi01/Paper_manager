import Darwin
import Foundation
import Testing
@testable import PaperDeckCore

/// The Claude assist session and backend against a fake `claude` (a `/bin/sh` script replaying the
/// synthetic stream-json fixtures; FakeCLI.claudeBody). No real CLI is ever started.
@Suite struct ClaudeAssistBackendTests {
    static func backend(_ cli: FakeCLI, sleeper: ManualSleeper? = nil, keepWarm: Duration = .seconds(180),
                        prewarmSpec: ClaudeAssistSession.Spec? = nil, idleSpawn: Bool = false,
                        launcher: FakeLauncher? = nil) -> (ClaudeAssistBackend, FakeLauncher) {
        let l = launcher ?? FakeLauncher(.ready(cli.launch(.claude)))
        let warmFor: @Sendable () -> Duration = { keepWarm }
        let realSleep: @Sendable (Duration) async -> Void = { d in try? await Task.sleep(for: d) }
        let sleep: @Sendable (Duration) async -> Void = sleeper?.sleep ?? realSleep
        var spec: (@Sendable () -> ClaudeAssistSession.Spec?)?
        if let prewarmSpec { spec = { prewarmSpec } }
        let b = ClaudeAssistBackend(launcher: l, keepWarm: warmFor, sleep: sleep, prewarmSpec: spec,
                                    idleSpawnOnPrewarm: idleSpawn)
        return (b, l)
    }

    static func stdinLines(_ cli: FakeCLI) -> [JSONValue] {
        (cli.read("stdin.log") ?? "").split(separator: "\n").compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }

    static func text(of line: JSONValue) -> String? {
        line["message"]?["content"]?.arrayValue?.last?["text"]?.stringValue
    }

    @Test func oneTurnStreamsDeltasAndEndsWithTheResult() async throws {
        let cli = try FakeCLI(FakeCLI.claudeBody)
        try cli.copyFixture("claude-turn-success", as: "turn.jsonl")
        let (backend, _) = Self.backend(cli)
        let png = AssistImage(data: Data([1, 2, 3]), mediaType: "image/png", pixelSize: CGSize(width: 3, height: 1))
        let events = await collectEvents(backend.turn(assistRequest(text: "<selection>x</selection>", image: png,
                                                                    session: .reuse(threadKey: "panel")), turnIndex: 0))
        #expect(events.prefix(3) == [.phase(.starting), .waiting(warm: false), .phase(.waitingForFirstToken)])
        #expect(events.contains(.phase(.streaming)))
        #expect(events.deltas.joined() == ClaudeStreamParserTests.full)
        #expect(events.doneText == ClaudeStreamParserTests.full)
        let meta = try #require(events.doneMeta)
        #expect(meta.provider == "claude" && meta.model == "claude-haiku-4-5" && !meta.warm && meta.turnIndex == 0)
        #expect(meta.ttftMs != nil && meta.costUSD == 0.0012 && meta.outputTokens == 42)
        #expect(events.filter(\.isTerminal).count == 1)
        // The CLI got stream-json flags, no positional prompt and only the launcher's environment.
        let argv = cli.argv
        #expect(argv.starts(with: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]))
        #expect(!argv.contains { $0.contains("<selection>") })
        let env = Set((cli.read("env.txt") ?? "").split(separator: "\n").map { String($0.split(separator: "=").first ?? "") })
        #expect(env.isSubset(of: ["PATH", "PD_FAKE_DIR", "HOME", "PWD", "SHLVL", "_", "OLDPWD"]))
        // One stdin line: the image block first, then the text.
        let lines = Self.stdinLines(cli)
        #expect(lines.count == 1)
        #expect(lines.first?["message"]?["content"]?.arrayValue?.map { $0["type"]?.stringValue } == ["image", "text"])
        #expect(await backend.hasLiveProcess)                       // a reuse session stays warm
        await backend.closeAllSessions()
        #expect(await assistEventually { cli.read("eof.txt") != nil })   // closed by EOF, not killed
    }

    @Test func aFollowUpUsesTheSameProcessAndAnotherConversationAFreshOne() async throws {
        let cli = try FakeCLI(FakeCLI.claudeBody)
        try cli.copyFixture("claude-turn-success", as: "turn1.jsonl")
        try cli.copyFixture("claude-turn-followup", as: "turn2.jsonl")
        try cli.copyFixture("claude-turn-success", as: "turn.jsonl")
        let (backend, launcher) = Self.backend(cli)
        let first = await collectEvents(backend.turn(assistRequest(session: .reuse(threadKey: "t1")), turnIndex: 0))
        #expect(first.doneText != nil)
        let history = [AssistTurnText(role: .user, text: "<selection>text</selection>"),
                       AssistTurnText(role: .assistant, text: first.doneText ?? "")]
        let second = await collectEvents(backend.turn(assistRequest(text: "<question>which?</question>", history: history,
                                                                    session: .reuse(threadKey: "t1")), turnIndex: 1))
        #expect(second.doneText == "B is the tallest bar.")
        #expect(second.doneMeta?.warm == true && second.doneMeta?.turnIndex == 1)
        #expect(!second.contains(.phase(.starting)))                // no cold start
        #expect(await backend.spawns == 1)
        #expect(launcher.launchCount == 1)
        // The follow-up line is just the question: the live process has the conversation.
        let lines = Self.stdinLines(cli)
        #expect(lines.count == 2 && Self.text(of: lines[1]) == "<question>which?</question>")
        // Another conversation: the first process is closed, a fresh one gets the history resent.
        try? FileManager.default.removeItem(at: cli.dir.appendingPathComponent("stdin.log"))
        let other = await collectEvents(backend.turn(assistRequest(text: "<question>again?</question>", history: history,
                                                                   session: .reuse(threadKey: "t2")), turnIndex: 1))
        #expect(other.doneText != nil && other.contains(.phase(.starting)))
        #expect(await backend.spawns == 2)
        let firstLine = try #require(Self.stdinLines(cli).first)
        let resent = try #require(Self.text(of: firstLine))
        #expect(resent.hasPrefix("<history>\n[user] <selection>text</selection>\n[assistant] ") && resent.hasSuffix("<question>again?</question>"))
        #expect(await assistEventually { (cli.read("eof.txt") ?? "").split(separator: "\n").count == 1 })
        await backend.closeAllSessions()
    }

    @Test func aOneShotTurnClosesItsProcess() async throws {
        let cli = try FakeCLI(FakeCLI.claudeBody)
        try cli.copyFixture("claude-turn-success", as: "turn.jsonl")
        let (backend, _) = Self.backend(cli)
        let events = await collectEvents(backend.turn(assistRequest(.dupJudge), turnIndex: 0))
        #expect(events.doneText != nil)
        #expect(await !backend.hasLiveProcess)
        #expect(await assistEventually { cli.read("eof.txt") != nil })
    }

    @Test func aCrashMidTurnFailsWithThePartialTextAndTheNextTurnStartsFresh() async throws {
        let cli = try FakeCLI(FakeCLI.claudeBody)
        // Turn 1 streams a delta and the process dies before any result line.
        try cli.put("turn1.jsonl", String(decoding: try AssistFixtures.data("claude-turn-overloaded"), as: UTF8.self)
            .components(separatedBy: "\n").prefix(4).joined(separator: "\n") + "\n")
        try cli.put("exit-after-1", "")
        try cli.put("stderr-1", "fatal: something broke\n")
        try cli.copyFixture("claude-turn-success", as: "turn.jsonl")
        let (backend, _) = Self.backend(cli)
        let crashed = await collectEvents(backend.turn(assistRequest(session: .reuse(threadKey: "t")), turnIndex: 0))
        let (failure, partial) = try #require(crashed.failure)
        #expect(partial == "The chart")
        guard case .generic(let message) = failure else { Issue.record("\(failure)"); return }
        #expect(message.contains("exit 3") && message.contains("something broke"))
        #expect(await !backend.hasLiveProcess)
        try? FileManager.default.removeItem(at: cli.dir.appendingPathComponent("exit-after-1"))
        try? FileManager.default.removeItem(at: cli.dir.appendingPathComponent("turn1.jsonl"))
        let again = await collectEvents(backend.turn(assistRequest(session: .reuse(threadKey: "t")), turnIndex: 1))
        #expect(again.doneText == ClaudeStreamParserTests.full && again.contains(.phase(.starting)))
        #expect(await backend.spawns == 2)
        await backend.closeAllSessions()
    }

    @Test func resultErrorsEndTheSession() async throws {
        let cases: [(String, (AssistFailure) -> Bool)] = [
            ("claude-turn-429", { if case .usageLimit(let d) = $0 { return d != nil }; return false }),
            ("claude-turn-not-logged-in", { $0 == .notLoggedIn(.loggedOut) }),
            ("claude-turn-overloaded", { $0 == .overloaded }),
            ("claude-turn-tools-on", { $0 == .generic("tools_not_off") }),
        ]
        for (fixture, check) in cases {
            let cli = try FakeCLI(FakeCLI.claudeBody)
            try cli.copyFixture(fixture, as: "turn.jsonl")
            let (backend, _) = Self.backend(cli)
            let events = await collectEvents(backend.turn(assistRequest(session: .reuse(threadKey: "t")), turnIndex: 0))
            let (failure, _) = try #require(events.failure, "\(fixture)")
            #expect(check(failure), "\(fixture): \(failure)")
            #expect(events.filter(\.isTerminal).count == 1)
            #expect(await !backend.hasLiveProcess, "\(fixture)")
        }
    }

    @Test func dropTheStreamAndTheProcessGroupIsInterrupted() async throws {
        let cli = try FakeCLI(FakeCLI.claudeBody)
        try cli.put("sleep-1", "")
        try cli.copyFixture("claude-turn-success", as: "turn.jsonl")
        let (backend, _) = Self.backend(cli)
        let stream = backend.turn(assistRequest(session: .reuse(threadKey: "t")), turnIndex: 0)
        let reader = Task { await collectEvents(stream) }
        #expect(await assistEventually { cli.read("stdin.log") != nil })
        let pid = try #require(Int32((cli.read("pids.txt") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
        reader.cancel()
        _ = await reader.value
        #expect(await assistEventually(.seconds(20)) { kill(pid, 0) != 0 })     // load-tolerant (ENV-1)
        #expect(await assistEventually { await !backend.hasLiveProcess })
    }

    @Test func anIdleProcessIsClosedWhenKeepWarmRunsOut() async throws {
        let cli = try FakeCLI(FakeCLI.claudeBody)
        try cli.copyFixture("claude-turn-success", as: "turn.jsonl")
        let sleeper = ManualSleeper()
        let (backend, _) = Self.backend(cli, sleeper: sleeper, keepWarm: .seconds(42))
        _ = await collectEvents(backend.turn(assistRequest(session: .reuse(threadKey: "t")), turnIndex: 0))
        #expect(await assistEventually { sleeper.pending == 1 })
        #expect(sleeper.requested.last == .seconds(42))
        #expect(await backend.hasLiveProcess)
        sleeper.fire()
        #expect(await assistEventually { await !backend.hasLiveProcess })
        #expect(await assistEventually { cli.read("eof.txt") != nil })
        // A turn cancels the pending timer: firing an old timer later closes nothing.
        _ = await collectEvents(backend.turn(assistRequest(session: .reuse(threadKey: "t")), turnIndex: 1))
        #expect(await assistEventually { sleeper.pending == 1 })
        _ = await collectEvents(backend.turn(assistRequest(session: .reuse(threadKey: "t")), turnIndex: 2))
        #expect(await backend.hasLiveProcess)
        #expect(await backend.spawns == 2)
        await backend.closeAllSessions()
    }

    @Test func theTwelveTurnCapMovesToAFreshProcessWithHistory() async throws {
        let cli = try FakeCLI(FakeCLI.claudeBody)
        try cli.copyFixture("claude-turn-followup", as: "turn.jsonl")
        let (backend, _) = Self.backend(cli)
        var history: [AssistTurnText] = []
        for i in 0..<13 {
            let r = assistRequest(.qa, text: "<question>q\(i)</question>", history: history, session: .reuse(threadKey: "thread"))
            let events = await collectEvents(backend.turn(r, turnIndex: i))
            #expect(events.doneText != nil, "turn \(i)")
            history += [AssistTurnText(role: .user, text: "<question>q\(i)</question>"),
                        AssistTurnText(role: .assistant, text: events.doneText ?? "")]
        }
        #expect(await backend.spawns == 2)
        let lines = Self.stdinLines(cli)
        #expect(lines.count == 13)
        #expect(Self.text(of: lines[11]) == "<question>q11</question>")
        #expect(Self.text(of: lines[12])?.hasPrefix("<history>") == true)
        await backend.closeAllSessions()
    }

    @Test func prewarmChecksTheLoginAndSpawnsOnlyWhenAllowed() async throws {
        let cli = try FakeCLI(FakeCLI.claudeBody)
        try cli.copyFixture("claude-turn-success", as: "turn.jsonl")
        // Default: the login check only (zero quota), no process.
        let (plain, launcher) = Self.backend(cli)
        await plain.prewarm()
        #expect(launcher.launchCount == 1 && cli.read("argv.txt") == nil)
        #expect(await plain.spawns == 0)
        // Allowed and a spec known: an idle process waits; the first turn adopts it (warm).
        let spec = ClaudeAssistSession.Spec(assistRequest(session: .reuse(threadKey: "p")))
        let (warm, _) = Self.backend(cli, prewarmSpec: spec, idleSpawn: true)
        await warm.prewarm()
        #expect(await warm.spawns == 1)
        #expect(await warm.hasLiveProcess)
        #expect(cli.read("stdin.log") == nil)                       // nothing written: no turn
        let events = await collectEvents(warm.turn(assistRequest(session: .reuse(threadKey: "p")), turnIndex: 0))
        #expect(events.doneMeta?.warm == true && !events.contains(.phase(.starting)))
        #expect(await warm.spawns == 1)
        // A different model can't use the warm process.
        let other = await collectEvents(warm.turn(assistRequest(model: "sonnet", session: .reuse(threadKey: "p")), turnIndex: 1))
        #expect(other.contains(.phase(.starting)))
        #expect(await warm.spawns == 2)
        await warm.closeAllSessions()
    }

    @Test func aRefusedLaunchFailsWithoutSpawning() async throws {
        let cli = try FakeCLI(FakeCLI.claudeBody)
        let launcher = FakeLauncher(.failed(.notLoggedIn(.nonSubscription(method: "api_key"))))
        let (backend, _) = Self.backend(cli, launcher: launcher)
        let events = await collectEvents(backend.turn(assistRequest(), turnIndex: 0))
        #expect(events.last == .failed(.notLoggedIn(.nonSubscription(method: "api_key")), partial: nil))
        #expect(await backend.spawns == 0)
        #expect(cli.read("argv.txt") == nil)
        #expect(await backend.detect() == .ready(plan: "fake", version: "0") && launcher.detectCount == 1)
    }

    @Test func refusedStatusesMapToAssistFailures() {
        #expect(AssistLaunchResult.failure(for: .notInstalled) == .binaryMissing)
        #expect(AssistLaunchResult.failure(for: .notLoggedIn("logged_out")) == .notLoggedIn(.loggedOut))
        #expect(AssistLaunchResult.failure(for: .unsupported("missing_flags:--input-format")) == .unsupported(missingFlags: ["--input-format"]))
        #expect(AssistLaunchResult.failure(for: .unsupported("timeout")) == .notLoggedIn(.timeout))
        #expect(AssistLaunchResult.provider(.ready(plan: "max", version: "2", path: "/p")) == .ready(plan: "max", version: "2"))
    }
}
