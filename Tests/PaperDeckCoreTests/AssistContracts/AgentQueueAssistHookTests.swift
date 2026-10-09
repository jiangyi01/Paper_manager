import Foundation
import Testing
@testable import PaperDeckCore

/// Slice 0's AgentQueue edits (READING_ASSIST_PLAN §6.1): the yield hook (no new job is claimed
/// while an assist turn generates; the lane's idle call resumes the queue), and the per-provider
/// pause shared with the assist gate (`pause(for:)`, `recordUsageLimit(kind:resetsAt:)`). Mock only.
@Suite struct AgentQueueAssistHookTests {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on: Bool
        init(_ on: Bool) { self.on = on }
        var value: Bool { lock.withLock { on } }
        func set(_ b: Bool) { lock.withLock { on = b } }
    }

    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func engine(agentMode: AgentMode, mock: MockAgentProvider, assist: AssistMode = .off) async throws -> (Engine, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-assist-hook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var s = EngineSettings(agentMode: agentMode, metadataLookup: false)
        s.assist.mode = assist
        let settings = s
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: Engine.Dependencies(
            loadSettings: { settings }, now: { Self.t0 }, fetcher: nil,
            claude: MockAgentProvider(behavior: .notLoggedIn), codex: MockAgentProvider(behavior: .notLoggedIn),
            mock: mock, sidecarDelay: .milliseconds(10), cliFacts: .inMemory(),
            loadMailSettings: { MailSettings() }, mailSecrets: InMemoryMailSecretStore(), assistBackends: [MockAssistBackend()]))
        await engine.agents.configure(AgentQueue.Tuning(jobTimeout: .seconds(5), testTimeout: .seconds(1), maxNap: .milliseconds(40),
                                                        idleNap: .milliseconds(40), loginRecheck: .milliseconds(100),
                                                        shutdownWait: .seconds(1), detectThrottle: .zero))
        return (engine, root)
    }

    static func insertReadyPaper(_ engine: Engine) async throws -> Paper {
        let id = UUID().uuidString.lowercased()
        let sha = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let folder = "Papers/_Inbox/\(sha.prefix(8))"
        try FileManager.default.createDirectory(at: engine.paths.library.appendingPathComponent(folder), withIntermediateDirectories: true)
        let text = "A Paper Title\nAbstract\nWe study things.\nResults\nFig. 1 shows it.\nMethods\nWe did it."
        let paper = Paper(id: id, sha256: sha, fileSize: 1000, title: "a.pdf", titleRank: .font, pageCount: 3,
                          charCount: text.count, folder: folder, pdfName: "paper.pdf", originalName: "paper.pdf", stage: .ready,
                          addedAt: Self.t0, updatedAt: Self.t0)
        let saved = try await engine.db.insertPaper(paper)
        try engine.ctx.texts.save(text, id: id)
        return saved
    }

    static func eventually(_ timeout: Duration = .seconds(20), _ condition: () async throws -> Bool) async -> Bool {      // generous on a loaded machine (ENV-1)
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if (try? await condition()) == true { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return (try? await condition()) == true
    }

    @Test func noJobIsClaimedWhileAnAssistTurnGenerates() async throws {
        let mock = MockAgentProvider()
        let (engine, root) = try await Self.engine(agentMode: .mock, mock: mock)
        defer { try? FileManager.default.removeItem(at: root) }
        let busy = Flag(true)
        await engine.agents.setAssistBusy { busy.value }
        let p = try await Self.insertReadyPaper(engine)
        await engine.agents.enqueue(paperPK: p.pk, hold: false)
        await engine.agents.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await mock.calls == 0)
        #expect(try await engine.db.paper(pk: p.pk)?.aiState == .queued)
        busy.set(false)
        await engine.agents.assistDidFinish()
        #expect(await Self.eventually { await mock.calls == 1 })
        #expect(await Self.eventually { try await engine.db.paper(pk: p.pk)?.aiState == .done })
        await engine.shutdown()
    }

    @Test func theEngineWiresTheLanesBusyFlag() async throws {
        // Default wiring: an idle lane never holds the queue back.
        let mock = MockAgentProvider()
        let (engine, root) = try await Self.engine(agentMode: .mock, mock: mock)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!engine.assist.isBusyNow)
        let p = try await Self.insertReadyPaper(engine)
        await engine.agents.enqueue(paperPK: p.pk, hold: false)
        await engine.agents.start()
        #expect(await Self.eventually { await mock.calls == 1 })
        await engine.shutdown()
    }

    @Test func anAssistUsageLimitPausesTheProviderForCardsAndTheGate() async throws {
        let (engine, root) = try await Self.engine(agentMode: .off, mock: MockAgentProvider(), assist: .claude)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(engine.agents.pause(for: .claude, now: Self.t0) == nil)
        let resets = Self.t0.addingTimeInterval(1800)
        await engine.agents.recordUsageLimit(kind: .claude, resetsAt: resets)
        let until = try #require(engine.agents.pause(for: .claude, now: Self.t0))
        #expect(until == resets.addingTimeInterval(120))
        #expect(engine.agents.pause(for: .codex, now: Self.t0) == nil)
        #expect(engine.agents.pause(for: .claude, now: until.addingTimeInterval(1)) == nil)
        // Persisted under the card queue's keys, so a relaunch keeps waiting.
        #expect(try await engine.db.kv(AgentQueue.pausedUntilKey(for: .claude)) == Database.timestamp(until))
        // The assist gate refuses Claude while the pause lasts.
        let verdict = engine.assistGate.checkTurn(.claude, ticket: .mint(.ask, surface: .qa, now: Self.t0), now: Self.t0)
        #expect(verdict == .paused(until: until))
        // An earlier reset never shortens a longer pause.
        await engine.agents.recordUsageLimit(kind: .claude, resetsAt: Self.t0)
        #expect(engine.agents.pause(for: .claude, now: Self.t0) == until)
        await engine.shutdown()
    }
}
