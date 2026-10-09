import Foundation
import ImageIO
import Testing
@testable import PaperDeckCore

/// `--assist-smoke`'s rules (refused without `--yes`, never more than 6 real turns, turns ≤ runs)
/// and its run loop on a scripted backend standing in for the provider — the real one is only
/// ever run by the lead. Also the synthetic figure and the raw-line recorder.
@Suite struct AssistSmokeTests {
    @Test func refusalsComeBeforeAnythingRuns() {
        #expect(AssistSmoke.plan(yes: false, provider: nil, maxRuns: 1, turns: 1) == .failure(.needsYes(.claude)))
        #expect(AssistSmoke.plan(yes: false, provider: "codex", maxRuns: nil, turns: nil) == .failure(.needsYes(.codex)))
        #expect(AssistSmoke.plan(yes: true, provider: "gemini", maxRuns: 1, turns: 1) == .failure(.unknownProvider("gemini")))
        #expect(AssistSmoke.plan(yes: true, provider: nil, maxRuns: 7, turns: 1) == .failure(.maxRunsTooHigh(7)))
        #expect(AssistSmoke.plan(yes: true, provider: nil, maxRuns: 1_000, turns: 1) == .failure(.maxRunsTooHigh(1_000)))
        #expect(AssistSmoke.plan(yes: true, provider: nil, maxRuns: 0, turns: nil) == .failure(.maxRunsTooLow(0)))
        #expect(AssistSmoke.plan(yes: true, provider: nil, maxRuns: -3, turns: nil) == .failure(.maxRunsTooLow(-3)))
        #expect(AssistSmoke.plan(yes: true, provider: nil, maxRuns: 2, turns: 3) == .failure(.turnsExceedRuns(turns: 3, maxRuns: 2)))
        #expect(AssistSmoke.plan(yes: true, provider: nil, maxRuns: 2, turns: 0) == .failure(.turnsTooLow(0)))
        #expect(AssistSmoke.plan(yes: true, provider: "codex", maxRuns: 2, turns: 1, prewarmIdle: 30) == .failure(.idleNeedsClaude))
        #expect(AssistSmoke.plan(yes: true, provider: nil, maxRuns: 2, turns: 1, prewarmIdle: 600) == .failure(.idleOutOfRange(600)))
        // Every refusal says what to do, and none mentions an institution or a person.
        for r in [AssistSmoke.Refusal.needsYes(.claude), .maxRunsTooHigh(9), .turnsExceedRuns(turns: 3, maxRuns: 1)] {
            #expect(r.description.contains("--"))
        }
        #expect(AssistSmoke.Refusal.needsYes(.claude).description.contains("REAL"))
    }

    @Test func defaultsAreOneRunOneTurnAndTheCapIsSix() {
        #expect(AssistSmoke.hardCap == 6)
        #expect(AssistSmoke.plan(yes: true, provider: nil, maxRuns: nil, turns: nil)
                == .success(.init(provider: .claude, maxRuns: 1, turns: 1, prewarmIdleSeconds: nil)))
        #expect(AssistSmoke.plan(yes: true, provider: "CODEX", maxRuns: 6, turns: 6)
                == .success(.init(provider: .codex, maxRuns: 6, turns: 6, prewarmIdleSeconds: nil)))
        #expect(AssistSmoke.plan(yes: true, provider: "claude", maxRuns: 2, turns: 1, prewarmIdle: 60)
                == .success(.init(provider: .claude, maxRuns: 2, turns: 1, prewarmIdleSeconds: 60)))
    }

    @Test func theRunStaysWithinItsBudgetAndStopsAtTheFirstFailure() async throws {
        let plan = try AssistSmoke.plan(yes: true, provider: "claude", maxRuns: 3, turns: 3).get()
        let backend = ScriptedBackend(mode: .claude, scripts: [ScriptedBackend.answer("Bars."), ScriptedBackend.answer("B.")],
                                      fallback: [.event(.failed(.overloaded, partial: nil))])
        let (lane, budget) = AssistSmoke.lane(plan, backend: backend)
        let reports = await AssistSmoke.run(plan, lane: lane, image: AssistSmoke.syntheticFigure(),
                                            ticket: { ConsentTicket.mint($0, surface: .explain) })
        #expect(reports.map(\.outcome) == ["success", "success", "overloaded"])
        #expect(budget.consumed == 3 && budget.isExhausted)
        let requests = await backend.requests
        #expect(requests.count == 3)
        #expect(requests[0].image != nil && requests[0].turnText == AssistSmoke.firstTurnText && requests[0].history.isEmpty)
        #expect(requests[1].image == nil && requests[1].turnText == AssistSmoke.followUpText)
        #expect(requests[1].history.map(\.text) == [AssistSmoke.firstTurnText, "Bars."])
        #expect(requests.allSatisfy { $0.model == "haiku" && $0.effort == "low" && $0.session == .reuse(threadKey: AssistSmoke.threadKey) })
        #expect(await backend.closedAll == 1)                          // processes closed at the end
        // The lane refuses a turn past the budget even if asked directly.
        try #require(requests.count > 0)          // no index past a failed expectation (QA-15)
        let extra = await collectEvents(await lane.submit(requests[0], ticket: .mint(.box, surface: .explain)))
        #expect(extra == [.failed(.refused(.budgetExhausted), partial: nil)])
        #expect(await backend.turns == 3)
    }

    @Test func theSmokeLaneRunsOnlyItsProviderOnSyntheticSettings() async throws {
        let plan = try AssistSmoke.plan(yes: true, provider: "codex", maxRuns: 1, turns: 1).get()
        let s = AssistSmoke.settings(for: .codex)
        #expect(s.assist.mode == .codex && s.agentMode == EngineSettings().agentMode)
        // A backend of another mode is never reached.
        let wrong = ScriptedBackend(mode: .claude)
        let (lane, budget) = AssistSmoke.lane(plan, backend: wrong)
        let reports = await AssistSmoke.run(plan, lane: lane, image: nil, ticket: { ConsentTicket.mint($0, surface: .explain) })
        #expect(reports.first?.outcome == "unsupported:")
        #expect(await wrong.turns == 0)
        #expect(budget.consumed == 0)
        // Codex requests use the quick Codex model.
        #expect(AssistSmoke.request(plan, index: 0, history: [], image: nil).model == "gpt-5.6-luna")
    }

    @Test func aPrewarmRequestGoesThroughTheGateFirst() async throws {
        let plan = try AssistSmoke.plan(yes: true, provider: "claude", maxRuns: 1, turns: 1, prewarmIdle: 1).get()
        let backend = ScriptedBackend(mode: .claude)
        let (lane, budget) = AssistSmoke.lane(plan, backend: backend)
        _ = await AssistSmoke.run(plan, lane: lane, image: nil, ticket: { ConsentTicket.mint($0, surface: .explain) },
                                  prewarm: .arm(), idle: .milliseconds(10))
        #expect(await backend.prewarms == 1)
        #expect(await backend.turns == 1)
        #expect(budget.consumed == 1)
        // An expired arming token pre-spawns nothing.
        let (lane2, _) = AssistSmoke.lane(plan, backend: backend)
        await lane2.prewarm(.arm(now: Date().addingTimeInterval(-60)))
        #expect(await backend.prewarms == 1)
    }

    @Test func theSyntheticFigureIsAnAcceptablePNG() throws {
        let image = try #require(AssistSmoke.syntheticFigure())
        #expect(image.isAcceptable && image.mediaType == "image/png" && image.pixelSize == CGSize(width: 240, height: 160))
        let src = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        #expect(CGImageSourceGetCount(src) == 1)
        #expect(Array(image.data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
    }

    @Test func theRecorderWritesOneFilePerTurn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-smoke-rec-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = try AssistSmoke.Recorder(dir: dir)
        rec.tap(.claude, 0, Data(#"{"type":"system"}"#.utf8))
        rec.tap(.claude, 0, Data(#"{"type":"result"}"#.utf8))
        rec.tap(.claude, -1, Data(#"{"type":"system"}"#.utf8))
        rec.tap(.codex, 1, Data(#"{"type":"turn.started"}"#.utf8))
        rec.close()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["claude-turn0.jsonl", "claude-turnidle.jsonl", "codex-turn1.jsonl"])
        let text = try String(contentsOf: dir.appendingPathComponent("claude-turn0.jsonl"), encoding: .utf8)
        #expect(text == "{\"type\":\"system\"}\n{\"type\":\"result\"}\n")
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("codex-turn1.jsonl").path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    /// The smoke command mints its tickets in the CLI's own handler (the allowlisted file), right
    /// before each turn, and never runs without the plan's `--yes` check.
    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func theCLIHandlerChecksThePlanBeforeAnything() throws {
        let cli = try String(contentsOf: LintRepo.url("Sources/PaperDeck/CLI/CLIRunner.swift"), encoding: .utf8)
        let handler = try #require(cli.range(of: "static func assistSmoke("))
        let body = String(cli[handler.lowerBound...])
        let plan = try #require(body.range(of: "AssistSmoke.plan(yes: args.has(\"--yes\")"))
        let backend = try #require(body.range(of: "AssistCLI.smokeBackend("))
        let mint = try #require(body.range(of: "ConsentTicket.mint("))
        #expect(plan.lowerBound < backend.lowerBound && backend.lowerBound < mint.lowerBound)
        // The dry run never builds a provider or a locator (nothing can be spawned).
        let argv = try String(contentsOf: LintRepo.url("Sources/PaperDeck/CLI/AssistCLI.swift"), encoding: .utf8)
        let start = try #require(argv.range(of: "static func argv("))
        let end = try #require(argv.range(of: "static func smokeBackend("))
        let dryRun = String(argv[start.lowerBound..<end.lowerBound])
        for banned in ["Locator(", "Provider(", "StreamingProcess", "ProcessRunner", "detect(", "UserDefaults", "createDirectory"] {
            #expect(!dryRun.contains(banned), "\(banned)")
        }
    }
}
