import Foundation
import Testing
@testable import PaperDeckCore

// Provider selection in the engine and the agent queue (Claude ⇄ ChatGPT/Codex).
// Nothing here spawns a real CLI: both providers are scripted fakes that — like the real
// ones — ask the engine's AgentSpawnGate before every pretend process.

// MARK: - Harness (private to this file)

private let qpChicago = LocalDate.gregorian(TimeZone(identifier: "America/Chicago")!)
/// Tuesday 2026-09-29 10:00 America/Chicago.
private let qpStart = qpChicago.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 10))!

private final class QPBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func update(_ f: (inout T) -> Void) { lock.withLock { f(&stored) } }
}

private final class QPRecorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ x: T) { lock.withLock { items.append(x) } }
    var all: [T] { lock.withLock { items } }
}

private extension AgentQueue.Tuning {
    /// Naps are a little longer than the other queue suites': these tests only wait for state
    /// changes, and a lighter loop keeps CPU-sensitive suites elsewhere in the run unaffected.
    static let qpFast = AgentQueue.Tuning(jobTimeout: .milliseconds(150), testTimeout: .milliseconds(300),
                                          maxNap: .milliseconds(50), idleNap: .milliseconds(100),
                                          loginRecheck: .seconds(30), shutdownWait: .seconds(1),
                                          detectThrottle: .zero, codexJobTimeout: .milliseconds(480))
}

/// Polls `condition` every 25 ms for up to `timeout`.
private func qpEventually(_ timeout: Duration = .seconds(5), _ condition: () async throws -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if (try? await condition()) == true { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return (try? await condition()) == true
}

/// Scripted stand-in for ClaudeCodeProvider / CodexProvider. Every pretend spawn asks the
/// spawn gate for its own provider kind first (a refusal → `.cancelled`, as the real ones do).
private actor QPFake: AgentProvider, AgentDryRunning, AgentAuthReporting {
    enum Step: Sendable {
        case card
        case outcome(AgentOutcome)
        /// Gate, then a success after `delay` (a long-running job).
        case delayedCard(Duration)
        /// The user switches agent.mode right before this spawn (then the gate decides).
        case switchModeFirst(AgentMode)
        /// Leaves a Claude-shaped envelope (cost $0.185) in the job dir, then reports `outcome`.
        case claudeEnvelopeThen(AgentOutcome)
    }

    nonisolated let id: String
    private let kind: AIProviderKind
    private var status: ProviderStatus
    private var refusal: ProviderStatus?
    private var gate: AgentSpawnGate?
    private var settings: QPBox<EngineSettings>?
    private var script: [Step] = []
    private let fallback: Step
    private(set) var detectCalls = 0
    private(set) var generateCalls = 0
    private(set) var spawns = 0
    private(set) var requests: [CardRequest] = []

    init(_ kind: AIProviderKind, fallback: Step = .card, status: ProviderStatus? = nil) {
        self.kind = kind
        id = kind.providerID
        self.fallback = fallback
        self.status = status ?? (kind == .codex
            ? .ready(plan: "ChatGPT", version: "0.153.4", path: "/fake/codex")
            : .ready(plan: "max", version: "2.1.284", path: "/fake/claude"))
    }

    func wire(gate: AgentSpawnGate, settings: QPBox<EngineSettings>) {
        self.gate = gate
        self.settings = settings
    }

    func push(_ steps: Step...) { script += steps }
    func setStatus(_ s: ProviderStatus) { status = s }
    func setRefusal(_ s: ProviderStatus?) { refusal = s }

    func detect() async -> ProviderStatus {
        detectCalls += 1
        return status
    }

    func authRefusalStatus() async -> ProviderStatus? { refusal }

    func dryRunSummary(_ r: CardRequest) async -> String {
        "argv: /fake/\(id) exec -m \(r.model) · effort \(r.effort) · stdin: \(r.stdin.count) bytes"
    }

    private func spawnAllowed() -> Bool {
        if let gate, !gate.allowSpawn(provider: kind, summary: "fake \(id)") { return false }
        spawns += 1
        return true
    }

    func generateCard(_ r: CardRequest, jobDir: URL) async -> AgentOutcome {
        generateCalls += 1
        requests.append(r)
        let step = script.isEmpty ? fallback : script.removeFirst()
        switch step {
        case .card:
            guard spawnAllowed() else { return .cancelled }
            return success(r)
        case .outcome(let o):
            guard spawnAllowed() else { return .cancelled }
            return o
        case .delayedCard(let delay):
            guard spawnAllowed() else { return .cancelled }
            do { try await Task.sleep(for: delay) } catch { return .cancelled }
            return success(r)
        case .switchModeFirst(let mode):
            settings?.update { $0.agentMode = mode }
            guard spawnAllowed() else { return .cancelled }
            return success(r)
        case .claudeEnvelopeThen(let o):
            guard spawnAllowed() else { return .cancelled }
            try? FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
            if let url = Bundle.module.url(forResource: "envelope-success", withExtension: "json",
                                           subdirectory: "Fixtures/agent"),
               let data = try? Data(contentsOf: url) {
                try? data.write(to: jobDir.appendingPathComponent("stdout.json"))
            }
            return o
        }
    }

    private func success(_ r: CardRequest) -> AgentOutcome {
        let meta = kind == .codex
            ? RunMeta(model: r.model, durationMs: 42_000, costUSD: nil, inputTokens: 5_000, outputTokens: 900,
                      numTurns: nil, variant: nil)
            : RunMeta(model: "claude-sonnet-test", durationMs: 1_500, costUSD: 0.02, inputTokens: 1_000,
                      outputTokens: 300, numTurns: 1, variant: "A")
        return .success(card: MockAgentProvider.card(for: r), meta: meta)
    }
}

private struct QPHarness {
    let root: URL
    let engine: Engine
    let claude: QPFake
    let codex: QPFake
    let mock: MockAgentProvider
    let clock: QPBox<Date>
    let settings: QPBox<EngineSettings>
    let logs: QPRecorder<String>
    let events: QPRecorder<EngineEvent>
    private let collector: Task<Void, Never>

    var db: Database { engine.db }
    var queue: AgentQueue { engine.agents }
    var ctx: EngineContext { engine.ctx }

    static func make(mode: AgentMode, claude: QPFake = QPFake(.claude), codex: QPFake = QPFake(.codex),
                     tuning: AgentQueue.Tuning = .qpFast,
                     adjust: (inout EngineSettings) -> Void = { _ in }) async throws -> QPHarness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-codexq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var s = EngineSettings(plan: PlanSettings(dailyBudgetMinutes: 60), lang: .zh, agentMode: mode,
                               metadataLookup: false)
        adjust(&s)
        let box = QPBox(s)
        let clock = QPBox(qpStart)
        let mock = MockAgentProvider()
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: Engine.Dependencies(
            loadSettings: { box.value }, now: { clock.value }, calendar: qpChicago, fetcher: nil,
            claude: claude, codex: codex, mock: mock, sidecarDelay: .milliseconds(10), cliFacts: .inMemory(), assistBackends: [MockAssistBackend()]))
        await claude.wire(gate: engine.agents.spawnGate, settings: box)
        await codex.wire(gate: engine.agents.spawnGate, settings: box)
        let logs = QPRecorder<String>()
        let events = QPRecorder<EngineEvent>()
        let stream = engine.events.subscribe()
        let collector = Task { for await e in stream { events.append(e) } }
        await engine.agents.configure(tuning)
        await engine.agents.setLogObserver { logs.append($0) }
        return QPHarness(root: root, engine: engine, claude: claude, codex: codex, mock: mock, clock: clock,
                         settings: box, logs: logs, events: events, collector: collector)
    }

    func start() async { await queue.start() }

    func finish() async {
        await engine.shutdown()
        await engine.db.close()
        collector.cancel()
        try? FileManager.default.removeItem(at: root)
    }

    /// A ready paper with cached text (so the queue can build a request).
    @discardableResult
    func insertPaper(title: String = "cortex-atlas.pdf") async throws -> Paper {
        let id = UUID().uuidString.lowercased()
        let sha = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let folder = "Papers/_Inbox/\(sha.prefix(8))"
        try FileManager.default.createDirectory(at: engine.paths.library.appendingPathComponent(folder),
                                                withIntermediateDirectories: true)
        let paper = Paper(id: id, sha256: sha, fileSize: 1000, title: title, titleRank: .font, pageCount: 3,
                          charCount: 300, folder: folder, pdfName: "paper.pdf", originalName: "paper.pdf",
                          stage: .ready, deadline: LocalDate(year: 2026, month: 9, day: 30), scheduleMode: .auto,
                          deadlineOrigin: .place, placementFloor: LocalDate(year: 2026, month: 9, day: 29),
                          provisional: true, estMinutes: 30, estSource: .heuristic,
                          addedAt: clock.value.addingTimeInterval(-3600), updatedAt: clock.value)
        let saved = try await db.insertPaper(paper, checklist: [])
        try ctx.texts.save("Deep Atlas of Developing Cortex Cells\nAbstract\nWe profile cells.\u{0C}Results\nFig. 1 shows it.",
                           id: id)
        return saved
    }

    func paper(_ pk: Int64) async throws -> Paper { try #require(try await db.paper(pk: pk)) }

    func job(_ paperPK: Int64) async throws -> AgentJob {
        let all = try await db.jobs(states: Set(AgentJobState.allCases))
        return try #require(all.filter { $0.paperPK == paperPK }.max { $0.pk < $1.pk })
    }

    var toasts: [Toast] {
        events.all.compactMap { if case .toast(let t) = $0 { return t }; return nil }
    }
}

// MARK: - Routing by agent.mode

// The queue suites run their tests one at a time (each spins up an engine and its loop).
@Suite(.serialized) struct CodexQueueRoutingTests {
    @Test func codexModeRunsEveryJobOnCodexAndRecordsIt() async throws {
        let h = try await QPHarness.make(mode: .codex)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        #expect(try await h.job(p.pk).provider == "codex")            // pending job names the selected provider
        await h.start()
        #expect(await qpEventually { try await h.paper(p.pk).aiState == .done })

        #expect(await h.codex.generateCalls == 1)
        #expect(await h.codex.spawns == 1)
        #expect(await h.claude.generateCalls == 0)
        #expect(await h.claude.detectCalls == 0)                     // Claude is never even probed
        #expect(h.queue.runBudget.consumed == 1)

        let job = try await h.job(p.pk)
        #expect(job.state == .succeeded && job.provider == "codex" && job.model == "gpt-5.6-terra")
        #expect(job.costUSD == nil)                                   // ChatGPT plan: no per-run cost
        #expect(job.inputTokens == 5_000 && job.outputTokens == 900 && job.durationMs == 42_000)

        let r = try #require(await h.codex.requests.first)
        #expect(r.model == "gpt-5.6-terra" && r.effort == "medium")
        #expect(r.timeout == AgentQueue.Tuning.qpFast.codexJobTimeout)
        #expect(r.systemPrompt == CardSchema.systemPrompt)

        #expect(await qpEventually { h.toasts.contains { $0.id == AgentQueue.finishedToastID(paperID: p.id) } })
        let toast = try #require(h.toasts.first { $0.id == AgentQueue.finishedToastID(paperID: p.id) })
        #expect(toast.message.hasPrefix("ChatGPT 已读完："))

        await h.ctx.sidecars.flush()
        let done = try await h.paper(p.pk)
        let sidecar = try CardSidecar.decoded(from: Data(contentsOf: h.ctx.folderURL(done)
            .appendingPathComponent("card.json")))
        #expect(sidecar.ai.provider == "codex" && sidecar.ai.model == "gpt-5.6-terra")

        let status = await h.queue.status()
        #expect(status.mode == .codex && status.providerKind == .codex && status.describesActiveProvider)
        #expect(status.provider == .ready(plan: "ChatGPT", version: "0.153.4"))
        #expect(status.providerText(.zh) == "已登录（ChatGPT） · Codex CLI 0.153.4")
        await h.finish()
    }

    @Test func claudeModeNeverTouchesCodex() async throws {
        let h = try await QPHarness.make(mode: .claude) { $0.codexModel = "gpt-5.6-sol" }
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        #expect(await qpEventually { try await h.paper(p.pk).aiState == .done })
        #expect(await h.claude.generateCalls == 1)
        #expect(await h.codex.generateCalls == 0)
        #expect(await h.codex.detectCalls == 0)
        #expect(await h.codex.spawns == 0)
        let job = try await h.job(p.pk)
        #expect(job.provider == "claude" && job.model == "claude-sonnet-test" && job.costUSD == 0.02)
        let r = try #require(await h.claude.requests.first)
        #expect(r.model == "sonnet" && r.timeout == AgentQueue.Tuning.qpFast.jobTimeout)
        #expect(await qpEventually { h.toasts.contains { $0.message.hasPrefix("Claude 已读完：") } })
        #expect(await h.queue.status().providerKind == .claude)
        await h.finish()
    }

    @Test func mockModeSpawnsNeitherRealProvider() async throws {
        let h = try await QPHarness.make(mode: .mock) { $0.agentProvider = .codex }
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        #expect(await qpEventually { try await h.paper(p.pk).aiState == .done })
        #expect(await h.mock.calls == 1)
        #expect(await h.codex.generateCalls == 0)
        #expect(await h.claude.generateCalls == 0)
        #expect(try await h.job(p.pk).provider == "mock")
        #expect(h.queue.runBudget.consumed == 0)
        let status = await h.queue.status()
        #expect(status.mode == .mock && status.providerKind == .codex && !status.describesActiveProvider)
        await h.finish()
    }

    @Test func offSpawnsNothingHoldsModeOffAndDetectsTheChosenProvider() async throws {
        let h = try await QPHarness.make(mode: .off) { $0.agentProvider = .codex }
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        #expect(try await h.job(p.pk).provider == "codex")
        await h.start()

        #expect(await qpEventually { try await h.job(p.pk).state == .held })
        #expect(try await h.paper(p.pk).aiNote == AgentQueue.modeOffNote)
        #expect(try await h.job(p.pk).errorKind == AgentQueue.modeOffNote)
        let wouldRun = h.logs.all.filter { $0.hasPrefix("WOULD RUN") }
        #expect(wouldRun.count == 1)
        #expect(wouldRun.first?.contains("/fake/codex exec -m gpt-5.6-terra") == true)
        // Detection (zero quota) describes the chosen provider, so the UI can show its login state.
        #expect(await qpEventually { await h.queue.status().provider == .ready(plan: "ChatGPT", version: "0.153.4") })
        var status = await h.queue.status()
        #expect(status.mode == .off && status.providerKind == .codex)
        #expect(await h.claude.detectCalls == 0)

        // Choosing Claude while still off re-describes Claude.
        h.settings.update { $0.agentProvider = .claude }
        await h.engine.agentProviderDidChange()
        #expect(await qpEventually {
            let s = await h.queue.status()
            return s.providerKind == .claude && s.provider == .ready(plan: "max", version: "2.1.284")
        })
        #expect(await h.claude.detectCalls >= 1)

        // Enabling ChatGPT does not start mode_off-held jobs by itself…
        h.settings.update { $0.agentMode = .codex }
        await h.engine.agentProviderDidChange()
        #expect(await qpEventually { await h.queue.status().providerKind == .codex })
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await h.job(p.pk).state == .held)
        #expect(await h.codex.generateCalls == 0)
        #expect(await h.claude.generateCalls == 0)
        #expect(h.queue.runBudget.consumed == 0)

        // …「为现有论文排队解读」 does, on the provider that is active now.
        await h.queue.releaseHeld(paperPKs: nil)
        #expect(await qpEventually { try await h.paper(p.pk).aiState == .done })
        #expect(await h.codex.generateCalls == 1)
        #expect(await h.claude.generateCalls == 0)
        #expect(try await h.job(p.pk).provider == "codex")
        status = await h.queue.status()
        #expect(status.describesActiveProvider)
        await h.finish()
    }

    @Test func budgetExhaustionStopsTheCodexQueue() async throws {
        let h = try await QPHarness.make(mode: .codex)
        h.queue.runBudget.setLimit(1)
        let a = try await h.insertPaper()
        let b = try await h.insertPaper()
        await h.queue.enqueue(paperPK: a.pk, hold: false, priority: 1)
        await h.queue.enqueue(paperPK: b.pk, hold: false)
        await h.start()
        #expect(await qpEventually { try await h.paper(a.pk).aiState == .done })
        #expect(await qpEventually { h.logs.all.contains { $0.hasPrefix("RUN BUDGET EXHAUSTED") } })
        try await Task.sleep(for: .milliseconds(150))
        #expect(await h.codex.spawns == 1)
        #expect(await h.codex.generateCalls == 1)
        #expect(try await h.job(b.pk).state == .queued)
        #expect(!h.queue.spawnGate.allowSpawn(provider: .codex, summary: "over budget"))
        await h.finish()
    }

    @Test func codexRetriesKeepTheCodexModelWithEffortLow() async throws {
        let codex = QPFake(.codex, fallback: .outcome(.invalidOutput("schema mismatch")))
        let h = try await QPHarness.make(mode: .codex, codex: codex) { $0.codexModel = "gpt-5.6-sol" }
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        #expect(await qpEventually { try await h.paper(p.pk).aiState == .failed })
        let requests = await codex.requests
        #expect(requests.count == 2)
        #expect(requests.map(\.model) == ["gpt-5.6-sol", "gpt-5.6-sol"])
        #expect(requests.map(\.effort) == ["medium", "low"])
        #expect(try await h.job(p.pk).textBudget == 60_000)
        #expect(try await h.paper(p.pk).aiNote == "输出无效")
        #expect(await h.claude.generateCalls == 0)
        await h.finish()
    }

    /// Codex output files are never parsed as Claude envelopes: a codex job's cost stays nil.
    @Test func codexFailuresNeverBillClaudeEnvelopes() async throws {
        let codex = QPFake(.codex)
        await codex.push(.claudeEnvelopeThen(.generic("boom")))
        let h = try await QPHarness.make(mode: .codex, codex: codex)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        #expect(await qpEventually { try await h.job(p.pk).errorKind == "generic" })
        let job = try await h.job(p.pk)
        #expect(job.state == .queued && job.attempt == 1 && job.notBefore != nil)
        #expect(job.costUSD == nil && job.inputTokens == nil)
        await h.finish()

        // The same leftover on a Claude run still counts (its envelopes are Claude's).
        let claude = QPFake(.claude)
        await claude.push(.claudeEnvelopeThen(.generic("boom")))
        let c = try await QPHarness.make(mode: .claude, claude: claude)
        let q = try await c.insertPaper()
        await c.queue.enqueue(paperPK: q.pk, hold: false)
        await c.start()
        #expect(await qpEventually { try await c.job(q.pk).errorKind == "generic" })
        #expect(try await c.job(q.pk).costUSD == 0.185031)
        await c.finish()
    }
}

// MARK: - Switching providers

@Suite(.serialized) struct CodexProviderSwitchTests {
    @Test func switchingMidQueueFinishesTheRunningJobAndRunsTheRestOnTheNewProvider() async throws {
        let claude = QPFake(.claude, fallback: .delayedCard(.milliseconds(400)))
        let h = try await QPHarness.make(mode: .claude, claude: claude)
        let a = try await h.insertPaper(title: "a.pdf")
        let b = try await h.insertPaper(title: "b.pdf")
        await h.queue.enqueue(paperPK: a.pk, hold: false, priority: 1)
        await h.queue.enqueue(paperPK: b.pk, hold: false)
        await h.start()
        #expect(await qpEventually { await claude.generateCalls == 1 })
        #expect(try await h.job(a.pk).state == .running)

        h.settings.update { $0.agentMode = .codex }
        await h.engine.agentProviderDidChange()

        #expect(await qpEventually { try await h.paper(a.pk).aiState == .done })
        #expect(await qpEventually { try await h.paper(b.pk).aiState == .done })
        let jobA = try await h.job(a.pk), jobB = try await h.job(b.pk)
        #expect(jobA.provider == "claude" && jobA.model == "claude-sonnet-test")   // not interrupted
        #expect(jobB.provider == "codex" && jobB.model == "gpt-5.6-terra")
        #expect(await claude.generateCalls == 1)
        #expect(await h.codex.generateCalls == 1)
        #expect(await h.codex.detectCalls >= 1)
        #expect(h.logs.all.contains("agent.mode claude → codex"))
        let status = await h.queue.status()
        #expect(status.providerKind == .codex && status.provider == .ready(plan: "ChatGPT", version: "0.153.4"))
        await h.finish()
    }

    /// The user switches to ChatGPT after the job was claimed but before Claude spawned: Claude's
    /// gate refuses, the job goes back to the queue and runs on Codex — nothing counted twice.
    @Test func switchRightBeforeTheSpawnHandsTheJobToTheNewProvider() async throws {
        let claude = QPFake(.claude)
        await claude.push(.switchModeFirst(.codex))
        let h = try await QPHarness.make(mode: .claude, claude: claude)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        #expect(await qpEventually { try await h.paper(p.pk).aiState == .done })
        #expect(await claude.generateCalls == 1)
        #expect(await claude.spawns == 0)
        #expect(await h.codex.generateCalls == 1)
        let job = try await h.job(p.pk)
        #expect(job.provider == "codex" && job.attempt == 0 && job.state == .succeeded)
        #expect(h.queue.runBudget.consumed == 1)
        await h.finish()
    }

    /// Each provider has its own quota: a ChatGPT usage limit pauses Codex only.
    @Test func usageLimitPausesOnlyTheProviderThatHitIt() async throws {
        let resets = qpStart.addingTimeInterval(30 * 60)
        let codex = QPFake(.codex)
        await codex.push(.outcome(.usageLimit(resetsAt: resets)))
        let h = try await QPHarness.make(mode: .codex, codex: codex)
        let a = try await h.insertPaper()
        let b = try await h.insertPaper()
        await h.queue.enqueue(paperPK: a.pk, hold: false, priority: 1)
        await h.queue.enqueue(paperPK: b.pk, hold: false)
        await h.start()

        let expected = resets.addingTimeInterval(120)
        #expect(await qpEventually { try await h.db.kv(AgentQueue.codexPausedUntilKey) != nil })
        #expect(try await h.db.kv(AgentQueue.codexPausedUntilKey) == Database.timestamp(expected))
        #expect(try await h.db.kv(AgentQueue.codexPauseReasonKey) == AgentQueue.usageLimitReason)
        #expect(try await h.db.kv(AgentQueue.pausedUntilKey) == nil)       // Claude is not paused
        #expect(await qpEventually { try await h.paper(b.pk).aiState == .limited })
        #expect(await qpEventually { h.toasts.contains { $0.id.hasPrefix(AgentQueue.usageLimitToastPrefix) } })
        #expect(h.toasts.first { $0.id.hasPrefix(AgentQueue.usageLimitToastPrefix) }?.message
                == "ChatGPT 额度已用尽 · 10:32 自动继续")
        var status = await h.queue.status()
        #expect(status.pausedUntil == expected && status.providerKind == .codex)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await codex.generateCalls == 1)

        // Switching to Claude keeps reading at once.
        h.settings.update { $0.agentMode = .claude }
        await h.engine.agentProviderDidChange()
        #expect(await qpEventually { try await h.paper(a.pk).aiState == .done })
        #expect(await qpEventually { try await h.paper(b.pk).aiState == .done })
        #expect(await h.claude.generateCalls == 2)
        #expect(await codex.generateCalls == 1)
        #expect(try await h.job(a.pk).provider == "claude")
        status = await h.queue.status()
        #expect(status.providerKind == .claude && status.pausedUntil == nil)
        #expect(try await h.db.kv(AgentQueue.codexPausedUntilKey) == Database.timestamp(expected))

        // Back on ChatGPT the pause still applies; it ends when the clock passes it.
        let c = try await h.insertPaper(title: "c.pdf")
        h.settings.update { $0.agentMode = .codex }
        await h.engine.agentProviderDidChange()
        await h.queue.enqueue(paperPK: c.pk, hold: false)
        #expect(await qpEventually { try await h.paper(c.pk).aiState == .limited })
        #expect(await h.queue.status().pausedUntil == expected)
        h.clock.update { $0 = $0.addingTimeInterval(33 * 60) }
        #expect(await qpEventually { try await h.paper(c.pk).aiState == .done })
        #expect(try await h.job(c.pk).provider == "codex")
        #expect(try await h.db.kv(AgentQueue.codexPausedUntilKey) == nil)
        await h.finish()
    }

    @Test func codexLoginProblemsWaitWithCodexWording() async throws {
        let codex = QPFake(.codex, status: .notLoggedIn("logged_out"))
        let h = try await QPHarness.make(mode: .codex, codex: codex)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        #expect(await qpEventually { try await h.paper(p.pk).aiState == .needsLogin })
        #expect(try await h.paper(p.pk).aiNote == "需登录 ChatGPT：运行 codex login → Sign in with ChatGPT")
        #expect(await codex.generateCalls == 0)
        #expect(await h.claude.detectCalls == 0)
        let status = await h.queue.status()
        #expect(status.providerKind == .codex && status.provider == .notLoggedIn("logged_out"))

        // 「我已登录」 → wake: detected again, the job runs on Codex.
        await codex.setStatus(.ready(plan: "ChatGPT", version: "0.153.4", path: "/fake/codex"))
        await h.queue.wake()
        #expect(await qpEventually { try await h.paper(p.pk).aiState == .done })
        #expect(try await h.job(p.pk).provider == "codex")
        await h.finish()

        // An API-key login is refused with the subscription wording (en).
        let apiKey = QPFake(.codex, status: .notLoggedIn("non_subscription:api_key"))
        let e = try await QPHarness.make(mode: .codex, codex: apiKey) { $0.lang = .en }
        let q = try await e.insertPaper()
        await e.queue.enqueue(paperPK: q.pk, hold: false)
        await e.start()
        #expect(await qpEventually { try await e.paper(q.pk).aiState == .needsLogin })
        #expect(try await e.paper(q.pk).aiNote == "PaperDeck only uses subscription login (current: API key)")
        #expect(await apiKey.generateCalls == 0)
        await e.finish()
    }
}

// MARK: - Connection test per provider

@Suite(.serialized) struct CodexConnectionTestTests {
    @Test func testConnectionForCodexUsesCodexOnly() async throws {
        let h = try await QPHarness.make(mode: .off)                        // chosen provider: Claude
        let p = try await h.insertPaper()
        await h.start()
        let papersBefore = try await h.db.allPapers()

        let outcome = await h.queue.testConnection(provider: .codex)
        guard case .success(_, let meta) = outcome else { Issue.record("expected success, got \(outcome)"); return }
        #expect(meta.model == "gpt-5.6-luna" && meta.costUSD == nil)
        #expect(await h.codex.generateCalls == 1)
        #expect(await h.claude.generateCalls == 0)
        let r = try #require(await h.codex.requests.first)
        #expect(r.model == "gpt-5.6-luna" && r.effort == "low")
        #expect(String(decoding: r.stdin, as: UTF8.self).contains("PaperDeck Connection Test"))
        #expect(!h.queue.spawnGate.isTestingConnection)
        #expect(h.queue.runBudget.consumed == 1)
        #expect(!h.queue.spawnGate.allowSpawn(provider: .codex, summary: "after the test"))   // mode off again
        #expect(try await h.db.allPapers() == papersBefore)
        #expect(try await h.db.jobs(states: Set(AgentJobState.allCases)).isEmpty)
        #expect(try await h.paper(p.pk).aiState == AIState.none)

        // No argument: the selected provider (agent.provider while off, the mode's otherwise).
        h.settings.update { $0.agentProvider = .codex }
        _ = await h.queue.testConnection()
        #expect(await h.codex.generateCalls == 2)
        #expect(await h.claude.generateCalls == 0)
        h.settings.update { $0.agentProvider = .claude }
        _ = await h.queue.testConnection()
        #expect(await h.claude.generateCalls == 1)
        let rc = try #require(await h.claude.requests.first)
        #expect(rc.model == "haiku" && rc.effort == "low")
        h.settings.update { $0.agentMode = .codex }                         // mode wins over agent.provider
        #expect(h.settings.value.agentProvider == .codex)
        _ = await h.queue.testConnection()
        #expect(await h.codex.generateCalls == 3)
        #expect(await h.claude.generateCalls == 1)
        await h.finish()
    }

    /// A Codex test while the status describes Claude must not relabel Claude's state.
    @Test func codexTestResultOnlyUpdatesTheStatusThatDescribesCodex() async throws {
        let codex = QPFake(.codex, fallback: .outcome(.notLoggedIn))
        await codex.setRefusal(.notLoggedIn("non_subscription:api_key"))
        let h = try await QPHarness.make(mode: .claude, codex: codex)
        await h.start()
        #expect(await qpEventually { await h.queue.status().provider == .ready(plan: "max", version: "2.1.284") })
        #expect(await h.queue.testConnection(provider: .codex) == .notLoggedIn)
        var status = await h.queue.status()
        #expect(status.providerKind == .claude && status.provider == .ready(plan: "max", version: "2.1.284"))

        // Off with ChatGPT chosen: the status describes Codex, so the refusal shows there.
        h.settings.update { $0.agentMode = .off; $0.agentProvider = .codex }
        await h.engine.agentProviderDidChange()
        #expect(await qpEventually { await h.queue.status().providerKind == .codex })
        #expect(await h.queue.testConnection() == .notLoggedIn)
        #expect(await qpEventually { await h.queue.status().provider == .notLoggedIn("non_subscription:api_key") })
        status = await h.queue.status()
        #expect(status.providerText(.zh) == "PaperDeck 只使用订阅登录（当前：API key）")
        #expect(await h.claude.generateCalls == 0)
        await h.finish()
    }
}

// MARK: - Spawn gate per provider

@Suite struct CodexSpawnGateTests {
    @Test func aSpawnIsAllowedOnlyWhileTheModeNamesItsProvider() {
        let box = QPBox(EngineSettings(agentMode: .claude))
        let gate = AgentSpawnGate(budget: RunBudget(maxRuns: 3), loadSettings: { box.value })
        #expect(gate.check(provider: .codex, summary: "x") == .modeNotActive(provider: .codex, mode: .claude))
        #expect(gate.allowSpawn(provider: .claude, summary: "x"))
        box.update { $0.agentMode = .codex }
        #expect(gate.check(provider: .claude, summary: "x") == .modeNotActive(provider: .claude, mode: .codex))
        #expect(gate.check(summary: "x") == .modeNotClaude(.codex))            // default provider: Claude
        #expect(gate.allowSpawn(provider: .codex, summary: "x"))
        for mode in [AgentMode.off, .mock] {
            box.update { $0.agentMode = mode }
            #expect(gate.check(provider: .codex, summary: "x") == .modeNotActive(provider: .codex, mode: mode))
            #expect(gate.check(provider: .claude, summary: "x") == .modeNotActive(provider: .claude, mode: mode))
        }
        #expect(gate.budget.consumed == 2)
        box.update { $0.agentMode = .codex }
        #expect(gate.allowSpawn(provider: .codex, summary: "third"))
        #expect(gate.check(provider: .codex, summary: "fourth") == .budgetExhausted)
        #expect(gate.budget.consumed == 3)
        #expect(AgentSpawnGate.Verdict.modeNotClaude(.off) == .modeNotActive(provider: .claude, mode: .off))
    }

    @Test func connectionTestAllowanceBelongsToOneProvider() {
        let box = QPBox(EngineSettings(agentMode: .off))
        let gate = AgentSpawnGate(budget: RunBudget(maxRuns: 5), loadSettings: { box.value })
        gate.beginConnectionTest(provider: .codex, spawns: 2)
        #expect(gate.isTestingConnection && gate.connectionTestProvider == .codex)
        // Claude keeps its normal mode check during a Codex test.
        #expect(gate.check(provider: .claude, summary: "c") == .modeNotActive(provider: .claude, mode: .off))
        #expect(gate.allowSpawn(provider: .codex, summary: "1"))
        #expect(gate.allowSpawn(provider: .codex, summary: "2"))
        #expect(gate.check(provider: .codex, summary: "3") == .testAllowanceExhausted)
        gate.endConnectionTest()
        #expect(gate.connectionTestProvider == nil)
        #expect(gate.check(provider: .codex, summary: "4") == .modeNotActive(provider: .codex, mode: .off))
        #expect(gate.budget.consumed == 2)

        let tight = AgentSpawnGate(budget: RunBudget(maxRuns: 1), loadSettings: { box.value })
        tight.beginConnectionTest(provider: .codex, spawns: 2)
        #expect(tight.allowSpawn(provider: .codex, summary: "A"))
        #expect(tight.check(provider: .codex, summary: "B") == .budgetExhausted)
    }

    /// The closures handed to the real providers check their own provider. Neither provider can
    /// find a binary here (fake probe) and their runner is a fake, so nothing is spawned.
    @Test func providerClosuresCheckTheirOwnProvider() async throws {
        let box = QPBox(EngineSettings(agentMode: .claude))
        let gate = AgentSpawnGate(budget: RunBudget(), loadSettings: { box.value })
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("pd-codexq-cwd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cwd) }
        let probe = BinaryLocator.Probe(isExecutable: { _ in false }, versionOutput: { _ in nil },
                                        loginShellLookup: { nil }, listDirectory: { _ in [] })
        let noSpawn: ClaudeCodeProvider.Runner = { _ in ProcessRunner.Result(exitCode: 1) }
        let request = CardRequest(schema: CardSchema.schema(categories: ["Genomics"]), stdin: Data("<paper>x</paper>".utf8),
                                  model: "gpt-5.6-terra", effort: "medium")
        let codex = CodexProvider(locator: CodexLocator(home: "/nonexistent-home", probe: probe), agentCwd: cwd,
                                  runner: noSpawn, parentEnvironment: { [:] })
        let claude = ClaudeCodeProvider(locator: BinaryLocator(home: "/nonexistent-home", probe: probe), agentCwd: cwd,
                                        runner: noSpawn, parentEnvironment: { [:] })
        let codexPlan = await codex.dryRun(request)
        let claudePlan = await claude.dryRun(request)

        #expect(await gate.codexSpawnGate(codexPlan) == false)
        #expect(await gate.claudeSpawnGate(claudePlan) == true)
        box.update { $0.agentMode = .codex }
        #expect(await gate.claudeSpawnGate(claudePlan) == false)
        #expect(await gate.codexSpawnGate(codexPlan) == true)
        box.update { $0.agentMode = .off }
        #expect(await gate.codexSpawnGate(codexPlan) == false)
        #expect(await gate.claudeSpawnGate(claudePlan) == false)
        #expect(gate.budget.consumed == 2)
    }
}

// MARK: - Settings, kinds, wording, engine wiring

@Suite struct CodexProviderSettingsTests {
    @Test func settingsLoadTheProviderChoiceAndTheModeWins() {
        let scratch = ScratchDefaults("codex-settings")
        defer { scratch.drop() }
        let d = scratch.defaults
        var s = EngineSettings.load(from: d)
        #expect(s.agentMode == .off && s.agentProvider == .claude && s.selectedProvider == .claude)
        #expect(s.codexModel == "gpt-5.6-terra" && s.codexPathOverride == nil)

        d.set("codex", forKey: "agent.provider")
        d.set("gpt-5.6-sol", forKey: "agent.codexModel")
        d.set("/Applications/ChatGPT.app/Contents/Resources/codex", forKey: "agent.codexPath")
        s = EngineSettings.load(from: d)
        #expect(s.agentMode == .off && s.agentProvider == .codex && s.selectedProvider == .codex)
        #expect(s.codexModel == "gpt-5.6-sol")
        #expect(s.codexPathOverride == "/Applications/ChatGPT.app/Contents/Resources/codex")
        #expect(s.model(for: .codex) == "gpt-5.6-sol" && s.model(for: .claude) == "sonnet")

        d.set("claude", forKey: "agent.mode")                                  // a real mode wins
        s = EngineSettings.load(from: d)
        #expect(s.agentMode == .claude && s.agentProvider == .claude)
        d.set("codex", forKey: "agent.mode")
        d.set("claude", forKey: "agent.provider")
        s = EngineSettings.load(from: d)
        #expect(s.agentMode == .codex && s.agentProvider == .codex && s.selectedProvider == .codex)

        d.set("mock", forKey: "agent.mode")
        d.set("bogus", forKey: "agent.provider")
        d.set("", forKey: "agent.codexPath")
        s = EngineSettings.load(from: d)
        #expect(s.agentMode == .mock && s.agentProvider == .claude && s.codexPathOverride == nil)
    }

    @Test func settingARealModeRemembersItsProvider() {
        var s = EngineSettings(agentMode: .off, agentProvider: .claude)
        s.agentMode = .codex
        #expect(s.agentProvider == .codex)
        s.agentMode = .off                                                      // off keeps the choice
        #expect(s.agentProvider == .codex && s.selectedProvider == .codex)
        s.agentMode = .mock
        #expect(s.selectedProvider == .codex)
        s.agentMode = .claude
        #expect(s.agentProvider == .claude)
        #expect(EngineSettings(agentMode: .codex, agentProvider: .claude).agentProvider == .codex)
    }

    @Test func providerKinds() throws {
        #expect(AgentMode(rawValue: "codex") == .codex && AgentMode.codex.rawValue == "codex")
        #expect(AIProviderKind.allCases == [.claude, .codex])
        for kind in AIProviderKind.allCases {
            #expect(kind.mode.providerKind == kind)
            #expect(kind.providerID == kind.rawValue)
        }
        #expect(AgentMode.off.providerKind == nil && AgentMode.mock.providerKind == nil)
        #expect(AIProviderKind.claude.displayName(.zh) == "Claude")
        #expect(AIProviderKind.codex.displayName(.en) == "ChatGPT (Codex)")
        #expect(AIProviderKind.codex.shortName == "ChatGPT" && AIProviderKind.claude.shortName == "Claude")
        #expect(AIProviderKind.codex.connectionTestModel == "gpt-5.6-luna")
        #expect(AIProviderKind.claude.connectionTestModel == "haiku")
        #expect(AIProviderKind.codex.jobTimeout == .seconds(480) && AIProviderKind.claude.jobTimeout == .seconds(360))
        #expect(AgentQueue.Tuning().codexJobTimeout == .seconds(480))
        #expect(AIProviderKind.codexModelChoices.map(\.id) == ["gpt-5.6-terra", "gpt-5.6-sol", "gpt-5.6-luna"])
        #expect(AIProviderKind.codexModelChoices.first?.id == AIProviderKind.defaultCodexModel)
        try #require(AIProviderKind.codexModelChoices.count > 1)          // no index past a failed expectation (QA-15)
        #expect(AIProviderKind.codexModelChoices[1].detail(.zh) == "更深入，消耗更多额度")
        let encoded = try JSONEncoder().encode(AIProviderKind.codex)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"codex\"")
        #expect(try JSONDecoder().decode(AIProviderKind.self, from: encoded) == .codex)
    }

    @Test func reasonTextsNameTheProvider() {
        typealias S = ProviderStatus
        #expect(S.notLoggedIn("logged_out").reasonText(.zh, provider: .codex)
                == "需登录 ChatGPT：运行 codex login → Sign in with ChatGPT")
        #expect(S.notLoggedIn("logged_out").reasonText(.en, provider: .codex)
                == "Sign in to ChatGPT: run codex login → Sign in with ChatGPT")
        #expect(S.notLoggedIn("non_subscription:api_key").reasonText(.zh, provider: .codex)
                == "PaperDeck 只使用订阅登录（当前：API key）")
        #expect(S.notLoggedIn("non_subscription:api_key").reasonText(.en, provider: .codex)
                == "PaperDeck only uses subscription login (current: API key)")
        #expect(S.ready(plan: "ChatGPT", version: "0.153.4", path: "/x").reasonText(.zh, provider: .codex)
                == "已登录（ChatGPT） · Codex CLI 0.153.4")
        #expect(S.ready(plan: "ChatGPT", version: "0.153.4", path: "/x").reasonText(.en, provider: .codex)
                == "Signed in (ChatGPT) · Codex CLI 0.153.4")
        #expect(S.notInstalled.reasonText(.zh, provider: .codex) == "未找到 Codex CLI")
        #expect(S.notInstalled.reasonText(.en, provider: .codex) == "Codex CLI not found")
        #expect(S.unsupported("timeout").reasonText(.en, provider: .codex)
                == "Codex CLI did not respond (codex login status timed out)")
        #expect(S.unsupported("missing_flags:--output-schema").reasonText(.zh, provider: .codex).contains("--output-schema"))
        #expect(S.unsupported("weird").reasonText(.en, provider: .codex) == "Unsupported Codex CLI version")
        #expect(S.notLoggedIn("weird").reasonText(.zh, provider: .codex)
                == "需登录 ChatGPT：运行 codex login → Sign in with ChatGPT")
        // Claude's wording is unchanged (and stays the default).
        #expect(S.notLoggedIn("non_subscription:api_key").reasonText(.zh) == "PaperDeck 只使用订阅登录（当前：api_key）")
        #expect(S.notLoggedIn("logged_out").reasonText(.zh, provider: .claude) == "需登录 Claude")
        #expect(S.unsupported("timeout").reasonText(.zh) == "Claude Code 没有响应（claude auth status 超时）")

        typealias P = AgentQueueStatus.Provider
        #expect(P.unknown.reasonText(.zh, provider: .codex) == "正在检查 Codex CLI…")
        #expect(P.unknown.reasonText(.zh) == "正在检查 Claude Code…")
        #expect(P.disabled.reasonText(.zh, provider: .codex) == "ChatGPT 解读已关闭")
        #expect(P.disabled.reasonText(.en) == "Claude reading is off")
        #expect(P.notLoggedIn("non_subscription:api_key").reasonText(.en, provider: .codex)
                == "PaperDeck only uses subscription login (current: API key)")
        #expect(P.ready(plan: "ChatGPT", version: "0.153.4").reasonText(.en, provider: .codex)
                == "Signed in (ChatGPT) · Codex CLI 0.153.4")
        #expect(P.notInstalled.reasonText(.zh, provider: .codex) == "未找到 Codex CLI")

        let status = AgentQueueStatus(provider: .notLoggedIn("logged_out"), providerKind: .codex, mode: .codex)
        #expect(status.providerText(.en) == "Sign in to ChatGPT: run codex login → Sign in with ChatGPT")
        #expect(status.describesActiveProvider)
        #expect(!AgentQueueStatus(providerKind: .codex, mode: .claude).describesActiveProvider)
        #expect(!AgentQueueStatus(providerKind: .codex, mode: .off).describesActiveProvider)
        #expect(AgentQueueStatus().providerKind == .claude)
    }

    /// Engine.open builds the real CodexProvider (with its own locator) unless one is injected.
    /// Nothing is resolved or spawned: the queue never starts and the mode is off.
    @Test func engineBuildsTheCodexProviderUnlessInjected() async throws {
        #expect(Engine.Dependencies(fetcher: nil).codex == nil)
        let settings = EngineSettings(agentMode: .off, metadataLookup: false)
        for inject in [false, true] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pd-codexq-engine-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            // test-engine-lint: real-card-provider — the real CodexProvider is built on purpose (agent.mode
            // off, the queue never starts); the assist lane gets the mock only.
            let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: Engine.Dependencies(
                loadSettings: { settings }, fetcher: nil, claude: QPFake(.claude),
                codex: inject ? QPFake(.codex) : nil, mock: MockAgentProvider(), cliFacts: .inMemory(), assistBackends: [MockAssistBackend()]))
            #expect((engine.codexLocator == nil) == inject)
            #expect(engine.binaryLocator == nil)                            // Claude was injected
            await engine.codexPathOverrideDidChange()                       // invalidate + wake: no spawn
            await engine.shutdown()
            await engine.db.close()
        }
    }
}
