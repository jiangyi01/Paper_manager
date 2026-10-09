import Foundation
import Testing
@testable import PaperDeckCore

// MARK: - Harness (private to this file)

private typealias PDTag = PaperDeckCore.Tag

private let chicago = LocalDate.gregorian(TimeZone(identifier: "America/Chicago")!)
/// Tuesday 2026-09-29 10:00 America/Chicago.
private let fixedStart = chicago.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 10))!

private final class AQClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date) { self.t = t }
    var now: Date { lock.withLock { t } }
    func advance(minutes: Double) { lock.withLock { t = t.addingTimeInterval(minutes * 60) } }
}

private final class AQSettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var s: EngineSettings
    init(_ s: EngineSettings) { self.s = s }
    var value: EngineSettings { lock.withLock { s } }
    func update(_ f: (inout EngineSettings) -> Void) { lock.withLock { f(&s) } }
}

private final class AQRecorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ x: T) { lock.withLock { items.append(x) } }
    var all: [T] { lock.withLock { items } }
}

private extension AgentQueue.Tuning {
    static let fast = AgentQueue.Tuning(jobTimeout: .milliseconds(150), testTimeout: .milliseconds(150),
                                        maxNap: .milliseconds(20), idleNap: .milliseconds(50),
                                        loginRecheck: .milliseconds(100), shutdownWait: .seconds(1),
                                        detectThrottle: .zero)
}

private let sampleText = [
    """
    Deep Atlas of Developing Cortex Cells
    Abstract
    We profile 50,000 single cells from the developing cortex and identify new progenitor states.
    Introduction
    Cortical development involves many progenitor types whose transitions remain unclear.
    """,
    """
    Results
    Fig. 1 shows the atlas. Fig. 2 compares proportions across four stages; outer radial glia expand.
    Fig. 3 traces lineages with a new trajectory method.
    """,
    """
    Methods
    Single-cell RNA-seq with 10x Genomics; clustering with Leiden; differential expression with pseudobulk DESeq2.
    Discussion
    Limitations include a single cohort and no spatial validation.
    """,
].joined(separator: "\u{0C}")

private struct AQHarness {
    let root: URL
    let engine: Engine
    let clock: AQClock
    let settings: AQSettingsBox
    let logs: AQRecorder<String>
    let events: AQRecorder<EngineEvent>
    let applied: AQRecorder<Int64>
    /// CLI facts (learned argv variant) — in memory, never the test runner's UserDefaults.
    let cliFacts: CLIFactStore
    private let collector: Task<Void, Never>

    var db: Database { engine.db }
    var queue: AgentQueue { engine.agents }
    var ctx: EngineContext { engine.ctx }

    /// `codex` defaults to a ready scripted fake: nothing here may build the real CodexProvider.
    static func make(mode: AgentMode, claude: any AgentProvider = MockAgentProvider(),
                     codex: any AgentProvider = AQScriptedProvider(id: "codex", status: .ready(
                         plan: "ChatGPT", version: "0.153.4", path: "/fake/codex")),
                     mock: any AgentProvider = MockAgentProvider(), tuning: AgentQueue.Tuning = .fast,
                     adjust: (inout EngineSettings) -> Void = { _ in }) async throws -> AQHarness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-agentq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var s = EngineSettings(plan: PlanSettings(dailyBudgetMinutes: 60), lang: .zh, agentMode: mode,
                               metadataLookup: false)
        adjust(&s)
        let box = AQSettingsBox(s)
        let clock = AQClock(fixedStart)
        let facts = CLIFactStore.inMemory()
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: Engine.Dependencies(
            loadSettings: { box.value }, now: { clock.now }, calendar: chicago, fetcher: nil,
            claude: claude, codex: codex, mock: mock, sidecarDelay: .milliseconds(10), cliFacts: facts, assistBackends: [MockAssistBackend()]))
        let logs = AQRecorder<String>()
        let events = AQRecorder<EngineEvent>()
        let applied = AQRecorder<Int64>()
        let stream = engine.events.subscribe()
        let collector = Task { for await e in stream { events.append(e) } }
        await engine.agents.configure(tuning)
        await engine.agents.setLogObserver { logs.append($0) }
        await engine.agents.setOnApplied { applied.append($0) }
        return AQHarness(root: root, engine: engine, clock: clock, settings: box, logs: logs, events: events,
                         applied: applied, cliFacts: facts, collector: collector)
    }

    func start() async { await queue.start() }

    /// Stops the loop but keeps the engine usable for direct queue calls.
    func shutdownQueueOnly() async { await queue.shutdown() }

    func finish() async {
        await engine.shutdown()
        collector.cancel()
        try? FileManager.default.removeItem(at: root)
    }

    /// A ready paper with a 3-item heuristic checklist (first item ticked) and cached text.
    @discardableResult
    func insertPaper(title: String = "cortex-atlas.pdf", titleRank: TitleRank = .font, text: String? = sampleText,
                     pageCount: Int = 12, estMinutes: Int = 30, estSource: EstSource = .heuristic,
                     checklist: [ChecklistItem]? = nil, deadline: LocalDate? = LocalDate(year: 2026, month: 9, day: 29),
                     provisional: Bool = true, metaSource: MetaSource = .none,
                     addedAt: Date? = nil) async throws -> Paper {
        let id = UUID().uuidString.lowercased()
        let sha = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let folder = "Papers/_Inbox/\(sha.prefix(8))"
        try FileManager.default.createDirectory(at: engine.paths.library.appendingPathComponent(folder),
                                                withIntermediateDirectories: true)
        let items = checklist ?? [
            ChecklistItem(ord: 0, text: "Read abstract; skim all figure titles", section: "Abstract", minutes: 5,
                          kind: .overview, origin: .heuristic, doneAt: clock.now.addingTimeInterval(-600)),
            ChecklistItem(ord: 1, text: "Results: Figs 1–3 — one-line takeaway per figure", section: "Results",
                          minutes: 15, kind: .figure, origin: .heuristic),
            ChecklistItem(ord: 2, text: "Discussion: note stated limitations and future work", section: "Discussion",
                          minutes: 10, kind: .discussion, origin: .heuristic),
        ]
        let paper = Paper(id: id, sha256: sha, fileSize: 1000, title: title, titleRank: titleRank,
                          metaSource: metaSource, pageCount: pageCount, charCount: text?.count, folder: folder,
                          pdfName: "paper.pdf", originalName: "paper.pdf", stage: .ready, deadline: deadline,
                          scheduleMode: deadline == nil ? .none : .auto, deadlineOrigin: .place,
                          placementFloor: deadline, provisional: provisional, estMinutes: estMinutes,
                          estSource: estSource, addedAt: addedAt ?? clock.now.addingTimeInterval(-3600),
                          updatedAt: clock.now)
        let saved = try await db.insertPaper(paper, checklist: items)
        if let text { try ctx.texts.save(text, id: id) }
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

/// Polls `condition` every 10 ms for up to `timeout`.
private func eventually(_ timeout: Duration = .seconds(20), _ condition: () async throws -> Bool) async -> Bool {      // generous on a loaded machine (ENV-1)
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if (try? await condition()) == true { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return (try? await condition()) == true
}

/// Test double that scripts outcomes and — like ClaudeCodeProvider — asks the spawn
/// gate before each (pretend) process, including a variant-B retry.
private actor AQScriptedProvider: AgentProvider, AgentVariantLearning, AgentDryRunning {
    enum Step: Sendable {
        case outcome(AgentOutcome)
        /// Success built from the mock card, with category overrides.
        case card(category: String?, newCategory: ReadingCard.NewCategory?, tags: [String]?)
        /// Variant A "succeeds" without structured output → B retry (each spawn gated).
        case gatedAB
    }

    nonisolated let id: String
    private var script: [Step]
    private let fallback: Step
    private var status: ProviderStatus
    private var gate: AgentSpawnGate?
    private var variant = "A"
    private(set) var restored: (String, String?)?
    private(set) var generateCalls = 0
    private(set) var spawns = 0
    private(set) var requests: [CardRequest] = []

    init(id: String = "claude", script: [Step] = [], fallback: Step = .card(category: nil, newCategory: nil, tags: nil),
         status: ProviderStatus = .ready(plan: "max", version: "9.9.9", path: "/fake/claude")) {
        self.id = id; self.script = script; self.fallback = fallback; self.status = status
    }

    func setGate(_ g: AgentSpawnGate) { gate = g }
    func setStatus(_ s: ProviderStatus) { status = s }
    func push(_ steps: Step...) { script += steps }

    func detect() async -> ProviderStatus { status }

    private func spawnAllowed(_ label: String) -> Bool {
        guard let gate else { spawns += 1; return true }
        guard gate.allowSpawn(summary: "fake \(label)") else { return false }
        spawns += 1
        return true
    }

    func generateCard(_ r: CardRequest, jobDir: URL) async -> AgentOutcome {
        generateCalls += 1
        requests.append(r)
        let step = script.isEmpty ? fallback : script.removeFirst()
        switch step {
        case .outcome(let o):
            guard spawnAllowed("A") else { return .cancelled }
            return o
        case .card(let category, let newCategory, let tags):
            guard spawnAllowed("A") else { return .cancelled }
            guard case .object(var o) = MockAgentProvider.card(for: r) else { return .generic("mock card") }
            if let category { o["category"] = .string(category) }
            if let n = newCategory {
                o["new_category"] = .object(["name": .string(n.name), "description": .string(n.description)])
            }
            if let tags { o["tags"] = .array(tags.map { .string($0) }) }
            return .success(card: .object(o), meta: RunMeta(model: "claude-sonnet-test", durationMs: 1500,
                                                            costUSD: 0.02, inputTokens: 1000, outputTokens: 300,
                                                            numTurns: 1, variant: variant))
        case .gatedAB:
            guard spawnAllowed("A") else { return .cancelled }
            guard spawnAllowed("B") else { return .invalidOutput("structured_output is null") }
            variant = "B"
            return .success(card: MockAgentProvider.card(for: r), meta: RunMeta(
                model: "claude-sonnet-test", durationMs: 1234, costUSD: 0.0123, inputTokens: 100, outputTokens: 50,
                numTurns: 1, variant: "B"))
        }
    }

    func restoreLearnedVariant(_ variant: String, cliVersion: String?) async {
        restored = (variant, cliVersion)
        self.variant = variant
    }

    func learnedVariantForPersistence() async -> (variant: String, cliVersion: String?) { (variant, "9.9.9") }

    func dryRunSummary(_ r: CardRequest) async -> String {
        "argv: /fake/claude -p … --model \(r.model) · stdin: \(r.stdin.count) bytes · variant: \(variant)"
    }
}

// MARK: - Queue behaviour

@Suite struct AgentQueueTests {
    @Test func successAppliesCardMergesChecklistAndDeletesJobDir() async throws {
        let claude = MockAgentProvider()
        let h = try await AQHarness.make(mode: .claude, claude: claude)
        let p = try await h.insertPaper()
        let before = try await h.db.checklist(paperPK: p.pk)
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        #expect(try await h.paper(p.pk).aiState == .queued)
        await h.start()

        #expect(await eventually { try await h.paper(p.pk).aiState == .done })
        let done = try await h.paper(p.pk)
        let card = try #require(done.card)
        #expect(done.tldr == card.tldr && card.tldr.hasPrefix("MOCK card"))
        #expect(done.cardVersion == 1)
        #expect(!done.aiSeen && done.aiNote == nil)
        #expect(done.textQuality == .good)
        // metaSource none → extracted metadata applies (title rank font < agent).
        #expect(done.title == "Deep Atlas of Developing Cortex Cells")
        #expect(done.titleRank == .agent && done.metaSource == .agent)
        // Category: the mock picks the first enum value (an existing starter).
        let categoryPK = try #require(done.categoryPK)
        let category = try #require(try await h.db.category(pk: categoryPK))
        #expect(category.name == "AI Agents for Science")
        #expect(!done.needsReview)
        // Tags
        let tags = try await h.db.tags(paperPK: p.pk)
        #expect(Set(tags.map(\.name)) == ["mock", "demo", "paperdeck"])
        #expect(tags.allSatisfy { $0.origin == .agent })
        // Estimate: mock = 4 × 12 pages.
        #expect(done.estMinutes == 48 && done.estSource == .agent)
        #expect(!done.provisional)
        // Checklist: the ticked heuristic item survives in place, untouched ones are replaced.
        let items = try await h.db.checklist(paperPK: p.pk)
        #expect(items.first?.id == before[0].id && items.first?.isDone == true)
        #expect(!items.contains { $0.id == before[1].id || $0.id == before[2].id })
        #expect(items.dropFirst().allSatisfy { $0.origin == .agent })
        // The mock's "Read abstract…" step duplicates the ticked item and is not added again.
        #expect(items.count == 1 + 4)
        #expect(items.dropFirst().reduce(0) { $0 + $1.minutes } == 50)       // round5(48)
        // Job bookkeeping.
        let job = try await h.job(p.pk)
        #expect(job.state == .succeeded && job.provider == "mock" && job.model == "mock")
        #expect(job.costUSD == 0 && job.finishedAt != nil)
        #expect(await eventually {
            !FileManager.default.fileExists(atPath: h.engine.paths.jobs.appendingPathComponent(job.id).path)
        })
        #expect(await claude.calls == 1)
        // Request: model/effort from settings; metadata "none" + page_count.
        let request = try #require(await claude.lastRequest)
        #expect(request.model == "sonnet" && request.effort == "medium" && request.timeout == .milliseconds(150))
        let stdin = String(decoding: request.stdin, as: UTF8.self)
        #expect(stdin.contains("<metadata>{\"source\":\"none\",\"page_count\":12}</metadata>"))
        #expect(stdin.contains("[[p. 2]]") && stdin.contains("\"name\":\"AI Agents for Science\""))
        // Hook, toast, status event, card.json.
        #expect(h.applied.all == [p.pk])
        #expect(await eventually { h.toasts.contains { $0.id == AgentQueue.finishedToastID(paperID: p.id) } })
        #expect(h.events.all.contains { if case .agentStatus = $0 { return true }; return false })
        await h.ctx.sidecars.flush()
        let cardURL = h.ctx.folderURL(done).appendingPathComponent("card.json")
        let sidecar = try CardSidecar.decoded(from: Data(contentsOf: cardURL))
        #expect(sidecar.state.aiState == .done)
        #expect(sidecar.ai.provider == "mock")
        await h.finish()
    }

    @Test func agentEstimateRePlacesProvisionalDeadlineOnce() async throws {
        let h = try await AQHarness.make(mode: .claude)
        let today = LocalDate(year: 2026, month: 9, day: 29)
        // Another paper already fills 30 of today's 60 minutes.
        let other = try await h.insertPaper(title: "other.pdf", estMinutes: 30, checklist: [], provisional: false)
        let p = try await h.insertPaper(estMinutes: 30)
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        #expect(await eventually { try await h.paper(p.pk).aiState == .done })
        let done = try await h.paper(p.pk)
        // |48 − 30| ≥ 15, imported 1 h ago, place()'s DDL → re-placed from its floor: 50′ no longer fit today.
        #expect(done.deadline == LocalDate(year: 2026, month: 9, day: 30))
        #expect(done.deadlineOrigin == .place && done.scheduleMode == .auto && !done.provisional)
        #expect(done.placementFloor == today)
        #expect(try await h.paper(other.pk).deadline == today)            // other papers never move
        await h.finish()
    }

    @Test func userEstimateWinsAndBlocksReplacement() async throws {
        let h = try await AQHarness.make(mode: .claude)
        let today = LocalDate(year: 2026, month: 9, day: 29)
        try await h.insertPaper(title: "other.pdf", estMinutes: 30, checklist: [], provisional: false)
        let p = try await h.insertPaper(estMinutes: 20, estSource: .user)
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        #expect(await eventually { try await h.paper(p.pk).aiState == .done })
        let done = try await h.paper(p.pk)
        #expect(done.estMinutes == 20 && done.estSource == .user)
        #expect(done.deadline == today && !done.provisional)
        let open = try await h.db.checklist(paperPK: p.pk).filter { !$0.isDone }
        #expect(open.reduce(0) { $0 + $1.minutes } == 20)
        await h.finish()
    }

    @Test func modeOffNeverSpawnsAndHoldsWithWouldRun() async throws {
        let claude = MockAgentProvider()
        let mock = MockAgentProvider()
        let h = try await AQHarness.make(mode: .off, claude: claude, mock: mock)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()

        #expect(await eventually { try await h.job(p.pk).state == .held })
        let held = try await h.paper(p.pk)
        #expect(held.aiState == .held && held.aiNote == AgentQueue.modeOffNote)
        #expect(try await h.job(p.pk).errorKind == AgentQueue.modeOffNote)
        #expect(h.logs.all.filter { $0.hasPrefix("WOULD RUN") }.count == 1)
        #expect(h.logs.all.contains { $0.hasPrefix("WOULD RUN") && $0.contains("stdin") })
        #expect(await h.queue.status().mode == .off)
        #expect(await h.queue.status().held == 1)

        // Turning Claude on does not start mode_off-held jobs by itself.
        h.settings.update { $0.agentMode = .claude }
        await h.queue.wake()
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await h.job(p.pk).state == .held)
        #expect(await claude.calls == 0)
        #expect(await mock.calls == 0)
        #expect(await h.queue.status().mode == .claude)

        // 「为现有论文排队解读」
        await h.queue.releaseHeld(paperPKs: nil)
        #expect(await eventually { try await h.paper(p.pk).aiState == .done })
        #expect(await claude.calls == 1)
        #expect(await mock.calls == 0)
        #expect(h.logs.all.filter { $0.hasPrefix("WOULD RUN") }.count == 1)
        await h.finish()
    }

    @Test func wouldRunUsesTheProviderDryRunAndQueuedJobsCanBeCancelled() async throws {
        let fake = AQScriptedProvider()
        let h = try await AQHarness.make(mode: .off, claude: fake)
        let a = try await h.insertPaper()
        let b = try await h.insertPaper()
        let c = try await h.insertPaper()
        await h.queue.enqueue(paperPK: a.pk, hold: false)
        await h.start()
        #expect(await eventually { h.logs.all.contains { $0.hasPrefix("WOULD RUN") } })
        let line = try #require(h.logs.all.first { $0.hasPrefix("WOULD RUN") })
        #expect(line.contains("argv: /fake/claude") && line.contains("--model sonnet") && line.contains("bytes"))
        #expect(await fake.generateCalls == 0)
        await h.shutdownQueueOnly()

        // Queue order and cancelling waiting jobs (no loop running now).
        await h.queue.enqueue(paperPK: b.pk, hold: false)
        await h.queue.enqueue(paperPK: c.pk, hold: false, priority: 1)
        let positions = await h.queue.queuePositions()
        #expect(positions[c.pk] == 1 && positions[b.pk] == 2 && positions[a.pk] == nil)
        await h.queue.cancel(paperPK: b.pk)
        #expect(try await h.job(b.pk).state == .cancelled)
        #expect(try await h.paper(b.pk).aiState == AIState.none)
        await h.queue.cancel(paperPK: a.pk)                                  // held (mode_off) → cancelled
        #expect(try await h.job(a.pk).state == .cancelled)
        let status = await h.queue.status()
        #expect(status.held == 0 && status.queued == 1)
        await h.finish()
    }

    @Test func mockModeUsesTheMockProvider() async throws {
        let claude = MockAgentProvider()
        let mock = MockAgentProvider()
        let h = try await AQHarness.make(mode: .mock, claude: claude, mock: mock)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        #expect(await eventually { try await h.paper(p.pk).aiState == .done })
        #expect(await mock.calls == 1)
        #expect(await claude.calls == 0)
        #expect(try await h.job(p.pk).provider == "mock")
        #expect(h.queue.runBudget.consumed == 0)
        await h.finish()
    }

    @Test func heldJobRunsOnlyAfterRelease() async throws {
        let claude = MockAgentProvider()
        let h = try await AQHarness.make(mode: .claude, claude: claude)
        let a = try await h.insertPaper()
        let b = try await h.insertPaper()
        await h.queue.enqueue(paperPK: a.pk, hold: true)
        await h.queue.enqueue(paperPK: b.pk, hold: true)
        await h.start()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await claude.calls == 0)
        #expect(try await h.paper(a.pk).aiState == .held)
        #expect(try await h.paper(a.pk).aiNote == nil)
        #expect(await h.queue.status().held == 2)

        await h.queue.releaseHeld(paperPKs: [a.pk])
        #expect(await eventually { try await h.paper(a.pk).aiState == .done })
        #expect(try await h.job(b.pk).state == .held)
        #expect(await claude.calls == 1)
        await h.finish()
    }

    @Test func usageLimitPausesPersistsAndResumesAfterTheClockPassesIt() async throws {
        let resets = fixedStart.addingTimeInterval(30 * 60)
        let claude = MockAgentProvider(script: [.usageLimit(resetsAt: resets)])
        let h = try await AQHarness.make(mode: .claude, claude: claude)
        let a = try await h.insertPaper()
        let b = try await h.insertPaper()
        await h.queue.enqueue(paperPK: a.pk, hold: false)
        await h.queue.enqueue(paperPK: b.pk, hold: false)
        await h.start()

        let expected = resets.addingTimeInterval(120)
        #expect(await eventually { try await h.db.kv(AgentQueue.pausedUntilKey) != nil })
        #expect(try await h.db.kv(AgentQueue.pausedUntilKey) == Database.timestamp(expected))
        #expect(try await h.db.kv(AgentQueue.pauseReasonKey) == AgentQueue.usageLimitReason)
        #expect(await eventually { try await h.paper(b.pk).aiState == .limited })
        #expect(try await h.paper(a.pk).aiState == .limited)
        let jobA = try await h.job(a.pk)
        #expect(jobA.state == .queued && jobA.attempt == 0)
        #expect(try await h.job(b.pk).state == .queued)
        let status = await h.queue.status()
        #expect(status.pausedUntil == expected && status.pauseReason == AgentQueue.usageLimitReason)
        // Exactly one toast for the limit event, in the UI language. Events arrive
        // asynchronously, so wait for it before counting.
        #expect(await eventually { h.toasts.contains { $0.id.hasPrefix(AgentQueue.usageLimitToastPrefix) } })
        let limitToasts = h.toasts.filter { $0.id.hasPrefix(AgentQueue.usageLimitToastPrefix) }
        #expect(limitToasts.count == 1)
        #expect(limitToasts.first?.message == "Claude 额度已用尽 · 10:32 自动继续")

        try await Task.sleep(for: .milliseconds(150))
        #expect(await claude.calls == 1)                                   // nothing runs while paused

        h.clock.advance(minutes: 33)
        #expect(await eventually { try await h.paper(b.pk).aiState == .done })
        #expect(try await h.paper(a.pk).aiState == .done)
        #expect(await claude.calls == 3)
        #expect(try await h.db.kv(AgentQueue.pausedUntilKey) == nil)
        #expect(await h.queue.status().pausedUntil == nil)
        #expect(h.toasts.filter { $0.id.hasPrefix(AgentQueue.usageLimitToastPrefix) }.count == 1)
        await h.finish()
    }

    @Test func persistedPauseSurvivesARestart() async throws {
        let h = try await AQHarness.make(mode: .claude)
        let until = fixedStart.addingTimeInterval(600)
        try await h.db.setKV(AgentQueue.pausedUntilKey, Database.timestamp(until))
        try await h.db.setKV(AgentQueue.pauseReasonKey, AgentQueue.usageLimitReason)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        #expect(await eventually { try await h.paper(p.pk).aiState == .limited })
        #expect(await h.queue.status().pausedUntil == until)
        h.clock.advance(minutes: 11)
        #expect(await eventually { try await h.paper(p.pk).aiState == .done })
        await h.finish()
    }

    @Test(.timeLimit(.minutes(1))) func hangTimesOutRetriesWithHalfBudgetAndLowEffortThenFails() async throws {
        let claude = MockAgentProvider(behavior: .hang)
        let h = try await AQHarness.make(mode: .claude, claude: claude)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()

        #expect(await eventually { try await h.paper(p.pk).aiState == .failed })
        #expect(await claude.calls == 2)
        let last = try #require(await claude.lastRequest)
        #expect(last.effort == "low")
        let job = try await h.job(p.pk)
        #expect(job.state == .failed && job.errorKind == "timeout" && job.attempt == 2)
        #expect(job.textBudget == 60_000 && job.effort == "low")
        #expect(try await h.paper(p.pk).aiNote == "超时")
        // Failed job output is kept for post-mortems.
        #expect(FileManager.default.fileExists(atPath: h.engine.paths.jobs.appendingPathComponent(job.id).path))
        await h.finish()
    }

    @Test func invalidOutputRetriesOnceThenFails() async throws {
        let claude = MockAgentProvider(behavior: .invalidOutput)
        let h = try await AQHarness.make(mode: .claude, claude: claude) { $0.lang = .en }
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        #expect(await eventually { try await h.paper(p.pk).aiState == .failed })
        #expect(await claude.calls == 2)
        let job = try await h.job(p.pk)
        #expect(job.errorKind == "invalid_output" && job.textBudget == 60_000)
        #expect(try await h.paper(p.pk).aiNote == "Invalid output")

        // retry → queued at attempt 0 → runs again (a fresh job row).
        await claude.setBehavior(.success)
        await h.queue.retry(paperPK: p.pk)
        #expect(await eventually { try await h.paper(p.pk).aiState == .done })
        let again = try await h.job(p.pk)
        #expect(again.pk != job.pk && again.state == .succeeded && again.attempt == 0 && again.textBudget == nil)
        await h.finish()
    }

    @Test func notLoggedInAtDetectionWaitsWithNeedsLogin() async throws {
        let claude = MockAgentProvider(behavior: .notLoggedIn)
        let h = try await AQHarness.make(mode: .claude, claude: claude)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        #expect(await eventually { try await h.paper(p.pk).aiState == .needsLogin })
        #expect(try await h.job(p.pk).state == .queued)
        #expect(try await h.paper(p.pk).aiNote == "需登录 Claude")
        if case .notLoggedIn = await h.queue.status().provider {} else { Issue.record("provider should be notLoggedIn") }
        #expect(await claude.calls == 0)

        await claude.setBehavior(.success)
        await h.queue.wake()                                          // 「我已登录」
        #expect(await eventually { try await h.paper(p.pk).aiState == .done })
        if case .ready = await h.queue.status().provider {} else { Issue.record("provider should be ready") }
        await h.finish()
    }

    @Test func notLoggedInOutcomeRequeuesAndWaitsForWake() async throws {
        let fake = AQScriptedProvider(script: [.outcome(.notLoggedIn)])
        var tuning = AgentQueue.Tuning.fast
        tuning.loginRecheck = .seconds(30)
        let h = try await AQHarness.make(mode: .claude, claude: fake, tuning: tuning)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        #expect(await eventually { try await h.paper(p.pk).aiState == .needsLogin })
        let job = try await h.job(p.pk)
        #expect(job.state == .queued && job.attempt == 0)
        if case .notLoggedIn = await h.queue.status().provider {} else { Issue.record("provider should be notLoggedIn") }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await fake.generateCalls == 1)

        await h.queue.wake()
        #expect(await eventually { try await h.paper(p.pk).aiState == .done })
        #expect(await fake.generateCalls == 2)
        await h.finish()
    }

    @Test func binaryMissingMarksNotInstalled() async throws {
        let fake = AQScriptedProvider(script: [.outcome(.binaryMissing)])
        var tuning = AgentQueue.Tuning.fast
        tuning.loginRecheck = .seconds(30)
        let h = try await AQHarness.make(mode: .claude, claude: fake, tuning: tuning)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        #expect(await eventually { try await h.paper(p.pk).aiState == .needsLogin })
        #expect(await h.queue.status().provider == .notInstalled)
        #expect(try await h.paper(p.pk).aiNote == "未找到 Claude Code")
        #expect(try await h.job(p.pk).state == .queued)
        await h.finish()
    }

    @Test func overloadedBacksOffOneTwoFourEightTenMinutesThenFails() async throws {
        let fake = AQScriptedProvider(fallback: .outcome(.overloaded))
        let h = try await AQHarness.make(mode: .claude, claude: fake)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        for (n, minutes) in [1.0, 2, 4, 8, 10].enumerated().map({ ($0.offset + 1, $0.element) }) {
            #expect(await eventually { let j = try await h.job(p.pk); return j.attempt == n && j.state == .queued })
            let job = try await h.job(p.pk)
            let delay = try #require(job.notBefore).timeIntervalSince(h.clock.now) / 60
            #expect(delay >= minutes * 0.9 - 0.01 && delay <= minutes * 1.1 + 0.01, "attempt \(n): \(delay) min")
            #expect(job.errorKind == "overloaded")
            #expect(try await h.paper(p.pk).aiState == .queued)
            // Nothing runs before the backoff expires.
            try await Task.sleep(for: .milliseconds(60))
            #expect(await fake.generateCalls == n)
            h.clock.advance(minutes: minutes * 1.1 + 0.1)
        }
        #expect(await eventually { try await h.paper(p.pk).aiState == .failed })
        #expect(await fake.generateCalls == 6)
        let job = try await h.job(p.pk)
        #expect(job.state == .failed && job.attempt == 6)
        #expect(try await h.paper(p.pk).aiNote == "Claude 服务繁忙")
        await h.finish()
    }

    @Test func genericErrorsBackOffTwoThenTenMinutesThenFail() async throws {
        let fake = AQScriptedProvider(fallback: .outcome(.generic("boom")))
        let h = try await AQHarness.make(mode: .claude, claude: fake)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        for (n, minutes) in [(1, 2.0), (2, 10.0)] {
            #expect(await eventually { let j = try await h.job(p.pk); return j.attempt == n && j.state == .queued })
            let notBefore = try await h.job(p.pk).notBefore
            let delay = try #require(notBefore).timeIntervalSince(h.clock.now) / 60
            #expect(abs(delay - minutes) < 0.01)
            h.clock.advance(minutes: minutes + 0.1)
        }
        #expect(await eventually { try await h.paper(p.pk).aiState == .failed })
        #expect(await fake.generateCalls == 3)
        #expect(try await h.job(p.pk).errorMessage == "boom")
        await h.finish()
    }

    @Test func cancellingARunningJobTerminatesItWithoutRetry() async throws {
        let claude = MockAgentProvider(delay: .seconds(20))
        let h = try await AQHarness.make(mode: .claude, claude: claude)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        #expect(await eventually { await claude.calls == 1 })
        #expect(try await h.paper(p.pk).aiState == .running)
        #expect(await h.queue.status().runningPaperID == p.id)
        #expect(await h.queue.status().runningSince == fixedStart)

        await h.queue.cancel(paperPK: p.pk)
        #expect(try await h.job(p.pk).state == .cancelled)
        #expect(try await h.paper(p.pk).aiState == AIState.none)
        #expect(await eventually { await h.queue.status().runningPaperID == nil })
        try await Task.sleep(for: .milliseconds(150))
        #expect(await claude.calls == 1)
        #expect(try await h.job(p.pk).state == .cancelled)
        await h.finish()
    }

    @Test func shutdownMidRunLeavesTheJobQueued() async throws {
        let claude = MockAgentProvider(delay: .seconds(20))
        let h = try await AQHarness.make(mode: .claude, claude: claude)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        #expect(await eventually { await claude.calls == 1 })
        #expect(try await h.paper(p.pk).aiState == .running)
        let clock = ContinuousClock()
        let t0 = clock.now
        await h.engine.shutdown()
        #expect(t0.duration(to: clock.now) < .seconds(15))      // load-tolerant (ENV-1); the run would take 20 s
        let job = try await h.job(p.pk)
        #expect(job.state == .queued && job.attempt == 0 && job.startedAt == nil)
        #expect(try await h.paper(p.pk).aiState == .queued)
        await h.finish()
    }

    @Test func startRecoversRunningJobsAndRestoresTheLearnedVariant() async throws {
        let fake = AQScriptedProvider()
        let h = try await AQHarness.make(mode: .claude, claude: fake)
        h.cliFacts.set("B", forKey: AgentQueue.variantKey)
        h.cliFacts.set("2.1.284", forKey: AgentQueue.variantCLIVersionKey)
        let p = try await h.insertPaper()
        try await h.db.insertJob(AgentJob(paperPK: p.pk, provider: "claude", state: .running, createdAt: fixedStart,
                                          startedAt: fixedStart))
        _ = try await h.db.modifyPaper(pk: p.pk) { $0.aiState = .running }
        await h.start()
        #expect(await eventually { try await h.paper(p.pk).aiState == .done })
        let restored = await fake.restored
        #expect(restored?.0 == "B" && restored?.1 == "2.1.284")
        let job = try await h.job(p.pk)
        #expect(job.state == .succeeded && job.costUSD == 0.02 && job.model == "claude-sonnet-test")
        #expect(job.inputTokens == 1000 && job.outputTokens == 300 && job.durationMs == 1500)
        await h.finish()
    }

    @Test func createsANewAgentCategoryAndWritesTheManifest() async throws {
        let fake = AQScriptedProvider(script: [.card(category: ReadingCard.newCategoryToken,
                                                     newCategory: .init(name: "plant immunity signalling",
                                                                        description: "Plant immune receptors and signalling"),
                                                     tags: ["plant-immunity", "nlr"])])
        let h = try await AQHarness.make(mode: .claude, claude: fake)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        #expect(await eventually { try await h.paper(p.pk).aiState == .done })
        let done = try await h.paper(p.pk)
        let categoryPK = try #require(done.categoryPK)
        let c = try #require(try await h.db.category(pk: categoryPK))
        #expect(c.name == "Plant Immunity Signalling")
        #expect(c.origin == .agent && !c.acknowledged && c.hue == 7)        // starters use hues 0…6
        #expect(c.description == "Plant immune receptors and signalling")
        #expect(await eventually {
            guard let data = try? Data(contentsOf: h.engine.paths.libraryManifest) else { return false }
            return String(decoding: data, as: UTF8.self).contains("Plant Immunity Signalling")
        })
        await h.finish()
    }

    @Test func runBudgetCountsTheVariantBRetryAndStopsTheQueue() async throws {
        let fake = AQScriptedProvider(fallback: .gatedAB)
        let h = try await AQHarness.make(mode: .claude, claude: fake)
        await fake.setGate(h.queue.spawnGate)
        h.queue.runBudget.setLimit(1)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        #expect(await eventually { h.logs.all.contains { $0.hasPrefix("RUN BUDGET EXHAUSTED") } })
        // A took the only run; the B retry was refused, so the queue saw A's invalid output.
        #expect(h.queue.runBudget.consumed == 1)
        #expect(await fake.spawns == 1)
        #expect(await fake.generateCalls == 1)
        let job = try await h.job(p.pk)
        #expect(job.state == .queued && job.errorKind == "invalid_output" && job.textBudget == 60_000)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await fake.generateCalls == 1)                      // stopped: the shrunk retry never spawned
        #expect(h.logs.all.filter { $0.hasPrefix("RUN BUDGET EXHAUSTED") }.count == 1)
        await h.finish()
    }

    @Test func variantBSuccessIsPersistedAndTheBudgetStopsTheNextJob() async throws {
        let fake = AQScriptedProvider(fallback: .gatedAB)
        let h = try await AQHarness.make(mode: .claude, claude: fake)
        await fake.setGate(h.queue.spawnGate)
        h.queue.runBudget.setLimit(2)
        let a = try await h.insertPaper()
        let b = try await h.insertPaper()
        await h.queue.enqueue(paperPK: a.pk, hold: false)
        await h.queue.enqueue(paperPK: b.pk, hold: false)
        await h.start()
        #expect(await eventually { try await h.paper(a.pk).aiState == .done })
        #expect(await eventually { h.logs.all.contains { $0.hasPrefix("RUN BUDGET EXHAUSTED") } })
        #expect(h.queue.runBudget.consumed == 2 && h.queue.runBudget.isExhausted)
        #expect(await fake.spawns == 2)
        #expect(await fake.generateCalls == 1)
        #expect(h.cliFacts.string(forKey: AgentQueue.variantKey) == "B")
        #expect(h.cliFacts.string(forKey: AgentQueue.variantCLIVersionKey) == "9.9.9")
        #expect(try await h.db.kv(AgentQueue.variantKey) == nil)            // a CLI fact, not library state
        let jobA = try await h.job(a.pk)
        #expect(jobA.costUSD == 0.0123)
        #expect(try await h.job(b.pk).state == .queued)
        #expect(try await h.paper(b.pk).aiState == .queued)
        await h.finish()
    }

    @Test func connectionTestNeverWritesTheLibrary() async throws {
        let claude = MockAgentProvider()
        let h = try await AQHarness.make(mode: .off, claude: claude)
        let p = try await h.insertPaper()
        await h.start()
        let papersBefore = try await h.db.allPapers()
        let categoriesBefore = try await h.db.categories()
        let tagsBefore = try await h.db.tags(paperPK: p.pk)
        let checklistBefore = try await h.db.checklist(paperPK: p.pk)

        let outcome = await h.queue.testConnection()
        guard case .success = outcome else { Issue.record("expected success, got \(outcome)"); return }
        #expect(await claude.calls == 1)
        let r = try #require(await claude.lastRequest)
        #expect(r.model == "haiku" && r.effort == "low")
        let paperBlock = String(decoding: r.stdin, as: UTF8.self)
        #expect(paperBlock.contains("PaperDeck Connection Test"))

        #expect(try await h.db.allPapers() == papersBefore)
        #expect(try await h.db.categories() == categoriesBefore)
        #expect(try await h.db.tags(paperPK: p.pk) == tagsBefore)
        #expect(try await h.db.checklist(paperPK: p.pk) == checklistBefore)
        #expect(try await h.db.jobs(states: Set(AgentJobState.allCases)).isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: h.engine.paths.jobs.path)) ?? []
        #expect(leftovers.isEmpty)
        await h.finish()
    }

    @Test func connectionTestIgnoresModeButHasATwoSpawnAllowance() async throws {
        let fake = AQScriptedProvider(fallback: .gatedAB)
        let h = try await AQHarness.make(mode: .off, claude: fake)
        await fake.setGate(h.queue.spawnGate)
        let outcome = await h.queue.testConnection()
        guard case .success(_, let meta) = outcome else { Issue.record("expected success, got \(outcome)"); return }
        #expect(meta.variant == "B")
        #expect(await fake.spawns == 2)
        #expect(h.cliFacts.string(forKey: AgentQueue.variantKey) == "B")
        #expect(!h.queue.spawnGate.isTestingConnection)
        // Outside the test the gate enforces agent.mode again.
        #expect(!h.queue.spawnGate.allowSpawn(summary: "after test"))
        #expect(h.queue.runBudget.consumed == 2)
        await h.finish()
    }

    @Test func reExtractsTextFromThePDFWhenTheCacheIsMissing() async throws {
        let fixture = SharedPaths.realHome.appendingPathComponent(
            "Library/Caches/PaperDeck-dev/fixtures/2025.09.01.673319.full.pdf")
        guard FileManager.default.fileExists(atPath: fixture.path) else { return }       // fixtures not installed
        let claude = MockAgentProvider()
        let h = try await AQHarness.make(mode: .claude, claude: claude)
        let p = try await h.insertPaper(text: nil)
        try FileManager.default.copyItem(at: fixture, to: h.ctx.pdfURL(p))
        #expect(!h.ctx.texts.exists(id: p.id))
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        #expect(await eventually(.seconds(20)) { try await h.paper(p.pk).aiState == .done })
        #expect(h.ctx.texts.exists(id: p.id))
        let stdin = String(decoding: try #require(await claude.lastRequest).stdin, as: UTF8.self)
        #expect(stdin.contains("[[p. 1]]") && stdin.contains("[[p. 5]]"))
        #expect(stdin.utf8.count < 200_000)
        await h.finish()
    }

    @Test func noTextFailsWithoutSpawning() async throws {
        let claude = MockAgentProvider()
        let h = try await AQHarness.make(mode: .claude, claude: claude)
        let p = try await h.insertPaper(text: nil)          // no cache and no PDF on disk
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.start()
        #expect(await eventually { try await h.paper(p.pk).aiState == .failed })
        #expect(await claude.calls == 0)
        #expect(try await h.job(p.pk).errorKind == "no_text")
        #expect(try await h.paper(p.pk).aiNote == "没有可用文本")
        await h.finish()
    }
}

// MARK: - Spawn gate and RunBudget

@Suite struct AgentSpawnGateTests {
    @Test func budgetCountsAndStops() {
        let b = RunBudget(maxRuns: 2)
        #expect(b.consume() && b.consume())
        #expect(!b.consume())
        #expect(b.consumed == 2 && b.isExhausted && b.remaining == 0)
        let unlimited = RunBudget()
        for _ in 0..<50 { #expect(unlimited.consume()) }
        #expect(!unlimited.isExhausted && unlimited.remaining == nil)
    }

    @Test func gateRefusesUnlessModeIsClaude() {
        let box = AQSettingsBox(EngineSettings(agentMode: .mock))
        let gate = AgentSpawnGate(budget: RunBudget(maxRuns: 3), loadSettings: { box.value })
        #expect(gate.check(summary: "x") == .modeNotClaude(.mock))
        box.update { $0.agentMode = .off }
        #expect(gate.check(summary: "x") == .modeNotClaude(.off))
        #expect(gate.budget.consumed == 0)
        box.update { $0.agentMode = .claude }
        #expect(gate.allowSpawn(summary: "x"))
        #expect(gate.budget.consumed == 1)
    }

    @Test func connectionTestAllowanceBypassesModeButNotTheBudget() {
        let box = AQSettingsBox(EngineSettings(agentMode: .off))
        let gate = AgentSpawnGate(budget: RunBudget(maxRuns: 5), loadSettings: { box.value })
        gate.beginConnectionTest(spawns: 2)
        #expect(gate.allowSpawn(summary: "A") && gate.allowSpawn(summary: "B"))
        #expect(gate.check(summary: "C") == .testAllowanceExhausted)
        gate.endConnectionTest()
        #expect(gate.check(summary: "D") == .modeNotClaude(.off))

        let tight = AgentSpawnGate(budget: RunBudget(maxRuns: 1), loadSettings: { box.value })
        tight.beginConnectionTest(spawns: 2)
        #expect(tight.allowSpawn(summary: "A"))
        #expect(tight.check(summary: "B") == .budgetExhausted)
    }
}

// MARK: - CardApplier rules

@Suite struct CardApplierTests {
    private static func card(category: String = "Neuroscience & Development", newCategory: ReadingCard.NewCategory? = nil,
                             tags: [String] = ["single-cell", "cortex"], est: Int = 60,
                             extracted: ReadingCard.ExtractedMetadata? = nil) -> ReadingCard {
        ReadingCard(extractedMetadata: extracted, tldr: "Outer radial glia expand during mid-gestation.",
                    summary: "A single-cell atlas of the developing cortex.", contributions: ["Builds an atlas"],
                    method: "scRNA-seq", results: ["oRG expand"], limitations: [], keyTerms: [], resources: [],
                    paperType: .research, category: category, newCategory: newCategory, tags: tags,
                    difficulty: .medium, estimatedMinutes: est,
                    checklist: [
                        .init(task: "Fig. 1: atlas overview", section: "Fig. 1", page: 2, minutes: 20, kind: .figure),
                        .init(task: "Fig. 2: proportions across stages", section: "Fig. 2", page: 3, minutes: 20, kind: .figure),
                        .init(task: "Methods: clustering and DE tests", section: "Methods", page: 3, minutes: 20, kind: .method),
                    ],
                    textQuality: .good)
    }

    @Test func userChoicesSurviveAndTagsRespectSuppression() async throws {
        let h = try await AQHarness.make(mode: .off)
        let p = try await h.insertPaper(metaSource: .crossref)
        let userCategory = try await h.db.category(named: "Microbiome & Metabolism")
        _ = try await h.db.modifyPaper(pk: p.pk) { $0.categoryPK = userCategory?.pk; $0.categoryUserSet = true }
        try await h.db.setTags(paperPK: p.pk, [PDTag(name: "my-tag", origin: .user),
                                              PDTag(name: "cortex", origin: .suppressed),
                                              PDTag(name: "old-agent-tag", origin: .agent)])
        let settings = await h.ctx.settings()
        let result = try await CardApplier.apply(Self.card(extracted: .init(title: "Other Title", authors: ["X Y"],
                                                                            year: 2020, venue: "V", doi: nil)),
                                                 to: p.pk, ctx: h.ctx, settings: settings)
        #expect(result.paper.categoryPK == userCategory?.pk)             // user-set category untouched
        #expect(result.paper.title == p.title && result.paper.metaSource == .crossref && !result.metadataChanged)
        let tags = try await h.db.tags(paperPK: p.pk)
        #expect(tags.contains(PDTag(name: "my-tag", origin: .user)))
        #expect(tags.contains(PDTag(name: "cortex", origin: .suppressed)))
        #expect(tags.contains(PDTag(name: "single-cell", origin: .agent)))
        #expect(!tags.contains { $0.name == "old-agent-tag" })
        #expect(!tags.contains { $0.name == "cortex" && $0.origin == .agent })
        #expect(result.paper.cardVersion == 1 && result.paper.aiState == .done)
        let again = try await CardApplier.apply(Self.card(), to: p.pk, ctx: h.ctx, settings: settings)
        #expect(again.paper.cardVersion == 2)
        await h.finish()
    }

    @Test func newCategoriesFallBackWhenNotAllowed() async throws {
        let h = try await AQHarness.make(mode: .off) { $0.allowNewCategories = false }
        let p = try await h.insertPaper()
        let settings = await h.ctx.settings()
        let result = try await CardApplier.apply(
            Self.card(category: ReadingCard.newCategoryToken,
                      newCategory: .init(name: "Cortical Development", description: "x"), tags: ["neurogenesis"]),
            to: p.pk, ctx: h.ctx, settings: settings)
        #expect(result.createdCategory == nil)
        #expect(result.paper.categoryPK != nil && result.paper.needsReview)
        #expect(try await h.db.categories().count == PaperCategory.starters.count)
        await h.finish()
    }

    @Test func extractedMetadataFillsAnUndescribedPaperButNeverStealsADOI() async throws {
        let h = try await AQHarness.make(mode: .off)
        let holder = try await h.insertPaper(title: "holder.pdf")
        _ = try await h.db.modifyPaper(pk: holder.pk) { $0.ids.doi = "10.1101/2025.09.01.673319" }
        let p = try await h.insertPaper(title: "s1.pdf", titleRank: .filename)
        let settings = await h.ctx.settings()
        let em = ReadingCard.ExtractedMetadata(title: "A Real Title", authors: ["Ada Lovelace", "Alan Turing"],
                                               year: 2025, venue: "bioRxiv", doi: "10.1101/2025.09.01.673319")
        let result = try await CardApplier.apply(Self.card(extracted: em), to: p.pk, ctx: h.ctx, settings: settings)
        #expect(result.metadataChanged)
        #expect(result.paper.title == "A Real Title" && result.paper.titleRank == .agent)
        #expect(result.paper.authors == ["Ada Lovelace", "Alan Turing"] && result.paper.year == 2025)
        #expect(result.paper.venue == "bioRxiv" && result.paper.metaSource == .agent)
        #expect(result.paper.ids.doi == nil)                             // held by another live paper
        // The category the card names exists → used; tags on a fresh paper are all agent tags.
        let categoryPK = try #require(result.paper.categoryPK)
        let c = try await h.db.category(pk: categoryPK)
        #expect(c?.name == "Neuroscience & Development")
        await h.finish()
    }

    @Test func abortingInsideTheTransactionWritesNothing() async throws {
        let h = try await AQHarness.make(mode: .off)
        let p = try await h.insertPaper()
        let before = try await h.paper(p.pk)
        let settings = await h.ctx.settings()
        await #expect(throws: CardApplier.ApplyError.aborted) {
            try await CardApplier.apply(Self.card(), to: p.pk, ctx: h.ctx, settings: settings,
                                        within: { _ in throw CardApplier.ApplyError.aborted })
        }
        #expect(try await h.paper(p.pk) == before)
        #expect(try await h.db.tags(paperPK: p.pk).isEmpty)
        await h.finish()
    }
}
