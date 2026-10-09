import Foundation
import Testing
@testable import PaperDeckCore

/// Phase 1 fix F5 (mutations L4, Q2, P2 survived):
/// - the card queue resumes as soon as an assist turn ends — through `AgentQueue.assistDidFinish`
///   (its poke) and the lane's idle call (`AssistLane.finished` → `onIdle`). With a long `maxNap`
///   polling can't hide a lost wake: the busy nap is 5 s, the expectation 1.5 s;
/// - an `assistant` line that repeats only the start of what streamed changes nothing (the parser's
///   prefix guard), so a stale snapshot can't truncate the answer.
/// Mock providers and the mock assist backend only.
@Suite(.timeLimit(.minutes(1))) struct P1FAssistWakeAndParserTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on: Bool
        init(_ on: Bool) { self.on = on }
        var value: Bool { lock.withLock { on } }
        func set(_ b: Bool) { lock.withLock { on = b } }
    }

    static func engine(assist: MockAssistBackend = MockAssistBackend(), mock: MockAgentProvider) async throws -> (Engine, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-p1f-wake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var s = EngineSettings(agentMode: .mock, metadataLookup: false)
        s.assist.mode = .mock
        let settings = s
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: Engine.Dependencies(
            loadSettings: { settings }, now: { Self.t0 }, fetcher: nil,
            claude: MockAgentProvider(behavior: .notLoggedIn), codex: MockAgentProvider(behavior: .notLoggedIn),
            mock: mock, sidecarDelay: .milliseconds(10), cliFacts: .inMemory(),
            loadMailSettings: { MailSettings() }, mailSecrets: InMemoryMailSecretStore(), assistBackends: [assist]))
        // Long naps: only a wake (poke) can make the queue claim within a second of the turn's end.
        await engine.agents.configure(AgentQueue.Tuning(jobTimeout: .seconds(5), testTimeout: .seconds(1), maxNap: .seconds(10),
                                                        idleNap: .seconds(10), loginRecheck: .seconds(10),
                                                        shutdownWait: .seconds(1), detectThrottle: .zero))
        return (engine, root)
    }

    static func within(_ timeout: Duration, _ condition: () async throws -> Bool) async -> Bool {
        await AgentQueueAssistHookTests.eventually(timeout, condition)
    }

    @Test func assistDidFinishWakesANappingQueueAtOnce() async throws {
        let mock = MockAgentProvider()
        let (engine, root) = try await Self.engine(mock: mock)
        defer { try? FileManager.default.removeItem(at: root) }
        let busy = Flag(true)
        await engine.agents.setAssistBusy { busy.value }
        let p = try await AgentQueueAssistHookTests.insertReadyPaper(engine)
        await engine.agents.enqueue(paperPK: p.pk, hold: false)
        await engine.agents.start()
        try await Task.sleep(for: .milliseconds(400))                  // the queue is in its busy nap (5 s)
        #expect(await mock.calls == 0)
        busy.set(false)
        await engine.agents.assistDidFinish()
        // 3 s (load-tolerant, ENV-1): a lost wake claims only when the 5 s busy nap ends, ~4.6 s from here.
        #expect(await Self.within(.seconds(3)) { await mock.calls == 1 }, "the queue waited for its nap to end")
        await engine.shutdown()
    }

    @Test func theEndOfARealLaneTurnWakesTheQueue() async throws {
        let mock = MockAgentProvider()
        let assist = MockAssistBackend(behavior: .chunks(["one ", "two ", "three ", "four"]), delay: .milliseconds(300))
        let (engine, root) = try await Self.engine(assist: assist, mock: mock)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = try await AgentQueueAssistHookTests.insertReadyPaper(engine)
        await engine.agents.enqueue(paperPK: p.pk, hold: false)
        let request = AssistRequest(surface: .explain, systemPrompt: "system", turnText: "<selection>x</selection>",
                                    model: "m", limits: AssistLimits.defaults(for: .explain, provider: nil))
        let stream = await engine.assist.submit(request, ticket: .mint(.box, surface: .explain, now: Self.t0))
        #expect(await Self.within(.seconds(2)) { engine.assist.isBusyNow })
        await engine.agents.start()                                     // sees the busy lane: naps
        var events: [AssistEvent] = []
        for await e in stream { events.append(e) }
        #expect(events.last.map { if case .done = $0 { return true }; return false } == true, "\(events)")
        #expect(await mock.calls == 0)                                  // nothing ran during the turn
        // 3 s (load-tolerant, ENV-1): a lost wake claims only when the 5 s busy nap ends, ~3.8 s from here.
        #expect(await Self.within(.seconds(3)) { await mock.calls == 1 }, "the lane's idle call didn't wake the queue")
        await engine.shutdown()
    }

    // MARK: Parser prefix guard

    @Test func anAssistantLineRepeatingOnlyTheStartChangesNothing() throws {
        var parser = ClaudeStreamParser()
        var outputs: [ClaudeStreamParser.Output] = []
        for line in try AssistFixtures.lines("claude-turn-assistant-prefix") { outputs += parser.feed(line) }
        let full = ClaudeStreamParserTests.full
        #expect(ClaudeStreamParserTests.deltas(outputs).joined() == full)
        #expect(!outputs.contains { if case .replace = $0 { return true }; return false }, "\(outputs)")
        #expect(parser.text == full)
        #expect(parser.typeSequence.contains("assistant"))              // the snapshot was read, not skipped
        let env = try #require(ClaudeStreamParserTests.result(outputs))
        #expect(ClaudeEnvelope.classifyTurn(result: env, stderr: Data(), exitCode: nil) == .success(text: full))
    }
}
