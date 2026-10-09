import Foundation
import Testing
@testable import PaperDeckCore

/// Phase 1 fix F2: Q&A's default model is the quick one (decision 6 of the approved proposal:
/// Haiku / Luna, "Thorough" on request) — in `AssistSettings` (init and load), `QAOptions`, the
/// dry run, a turn through `QAService`, and the plan's tables. Probe V3, inverted. No CLI runs: the
/// Q&A turn goes to a scripted backend.
@Suite struct P1FQADefaultDepthTests {
    @Test func theQADefaultIsQuickEverywhere() {
        #expect(AssistSettings().qaDepth == .quick)
        #expect(QAOptions().depth == .quick)
        #expect(AssistSettings().model(.claude, AssistSettings().qaDepth) == "haiku")
        #expect(AssistSettings().model(.codex, QAOptions().depth) == "gpt-5.6-luna")
    }

    @Test func anAbsentKeyLoadsQuickAndAChosenThoroughIsKept() {
        let scratch = ScratchDefaults("p1f-qa-depth")
        defer { scratch.drop() }
        #expect(AssistSettings.load(from: scratch.defaults).qaDepth == .quick)
        scratch.defaults.set("thorough", forKey: AssistSettings.Keys.qaDepth)
        #expect(AssistSettings.load(from: scratch.defaults).qaDepth == .thorough)
        scratch.defaults.set("deepest", forKey: AssistSettings.Keys.qaDepth)       // unknown → the default
        #expect(AssistSettings.load(from: scratch.defaults).qaDepth == .quick)
    }

    @Test func theDryRunShowsTheQuickModelForQA() {
        for (provider, slug) in [(AIProviderKind.claude, "haiku"), (.codex, "gpt-5.6-luna")] {
            let dry = AssistSmoke.dryRun(surface: .qa, provider: provider, agentCwd: "/tmp/agent-cwd", parentEnvironment: [:])
            #expect(dry.argv.contains(slug), "\(provider): \(dry.argv)")
            #expect(!dry.argv.contains("sonnet") && !dry.argv.contains("gpt-5.6-terra"))
        }
    }

    @Test func aQATurnWithDefaultOptionsAsksForTheQuickModel() async {
        let backend = ScriptedBackend(mode: .claude)
        let box = SettingsBox(.claude)
        let gate = AssistGate(budget: RunBudget(maxRuns: 2), load: { box.value }, pause: { _ in nil }, counter: AssistDailyCounter())
        let lane = AssistLane(gate: gate, load: { box.value }, backends: [backend])
        let qa = QAService(lane: lane, load: { box.value })
        let thread = await qa.newThread(paperIDs: ["p1"], mode: .excerpts)
        var events: [QAEvent] = []
        for await e in await qa.ask(threadID: thread.id, question: "What is shown?", options: QAOptions(),
                                    ticket: .mint(.ask, surface: .qa)) { events.append(e) }
        #expect(await backend.requests.map(\.model) == ["haiku"], "\(events)")
    }

    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func thePlanSaysQuickForQA() throws {
        let plan = try String(contentsOf: LintRepo.url("docs/proposals/READING_ASSIST_PLAN_en.md"), encoding: .utf8)
        let lines = plan.components(separatedBy: "\n")
        let d6 = try #require(lines.first { $0.hasPrefix("| D6 ") })
        #expect(d6.contains("Q&A = quick") && !d6.contains("Q&A = thorough"), "\(d6)")
        let keys = try #require(lines.first { $0.contains("`assist.explain.depth` / `assist.qa.depth`") })
        #expect(keys.contains("| quick / quick |"), "\(keys)")
        let turn = try #require(lines.first { $0.hasPrefix("| qa | ") })
        #expect(turn.hasPrefix("| qa | haiku / gpt-5.6-luna"), "\(turn)")
    }
}
