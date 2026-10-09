import Foundation
import Testing
@testable import PaperDeckCore

/// The on-device backend with a fake model (the system model is never asked to generate in tests).
@Suite struct LocalAssistBackendTests {
    struct FakeModel: LocalLanguageModel {
        var snapshots: [String]
        var error: LocalModelError?
        var status: AgentQueueStatus.Provider = .ready(plan: nil, version: "on-device")
        let seen = Seen()

        final class Seen: @unchecked Sendable {
            let lock = NSLock(); var prompts: [(String, String)] = []
        }

        func availability() async -> AgentQueueStatus.Provider { status }

        func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, any Error> {
            seen.lock.withLock { seen.prompts.append((instructions, prompt)) }
            let snapshots = self.snapshots, error = self.error
            return AsyncThrowingStream { c in
                for s in snapshots { c.yield(s) }
                if let error { c.finish(throwing: error) } else { c.finish() }
            }
        }
    }

    @Test func snapshotsBecomeReplacesAndTheLastIsTheAnswer() async {
        let model = FakeModel(snapshots: ["B", "B is", "B is", "B is tallest."])
        let backend = LocalAssistBackend(model: model)
        let history = [AssistTurnText(role: .user, text: "<selection>x</selection>")]
        let events = await collectEvents(backend.turn(assistRequest(text: "<question>q</question>", history: history), turnIndex: 2))
        #expect(events.replaces == ["B", "B is", "B is tallest."])
        #expect(events.doneText == "B is tallest.")
        #expect(events.doneMeta?.provider == "local" && events.doneMeta?.turnIndex == 2)
        let prompt = model.seen.lock.withLock { model.seen.prompts.first }
        #expect(prompt?.0 == "system" && prompt?.1.hasPrefix("<history>") == true && prompt?.1.hasSuffix("<question>q</question>") == true)
    }

    @Test func imagesErrorsAndEmptyAnswersFail() async {
        let png = AssistImage(data: Data([1]), mediaType: "image/png", pixelSize: CGSize(width: 1, height: 1))
        let backend = LocalAssistBackend(model: FakeModel(snapshots: ["x"]))
        #expect(await collectEvents(backend.turn(assistRequest(image: png), turnIndex: 0)).last
                == .failed(.unsupported(missingFlags: ["image"]), partial: nil))
        let ctx = LocalAssistBackend(model: FakeModel(snapshots: ["par"], error: .contextWindow))
        #expect(await collectEvents(ctx.turn(assistRequest(), turnIndex: 0)).last == .failed(.invalidOutput("context_window"), partial: "par"))
        let guardrail = LocalAssistBackend(model: FakeModel(snapshots: [], error: .guardrail))
        #expect(await collectEvents(guardrail.turn(assistRequest(), turnIndex: 0)).last == .failed(.generic("guardrail"), partial: nil))
        let empty = LocalAssistBackend(model: FakeModel(snapshots: ["  "]))
        #expect(await collectEvents(empty.turn(assistRequest(), turnIndex: 0)).last == .failed(.invalidOutput("empty_answer"), partial: nil))
        let off = LocalAssistBackend(model: FakeModel(snapshots: [], status: .notLoggedIn("apple_intelligence_off")))
        #expect(await off.detect() == .notLoggedIn("apple_intelligence_off"))
    }

    @Test func theLaneRunsItWithConsentButNoQuota() async {
        let budget = RunBudget(maxRuns: 0)                       // no real CLI run allowed at all
        var s = EngineSettings()
        s.assist.mode = .local
        let settings = s
        let gate = AssistGate(budget: budget, load: { settings }, pause: { _ in nil }, counter: AssistDailyCounter())
        let lane = AssistLane(gate: gate, load: { settings }, backends: [LocalAssistBackend(model: FakeModel(snapshots: ["ok"]))])
        let ticket = ConsentTicket.mint(.box, surface: .explain)
        #expect(await collectEvents(await lane.submit(assistRequest(), ticket: ticket)).doneText == "ok")
        #expect(await collectEvents(await lane.submit(assistRequest(), ticket: ticket)).last
                == .failed(.refused(.consentReused), partial: nil))
        #expect(budget.consumed == 0)
    }
}
