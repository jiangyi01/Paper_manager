import Foundation
import Testing
@testable import PaperDeckCore

// MARK: - Harness (private to this file)

private let tqChicago = LocalDate.gregorian(TimeZone(identifier: "America/Chicago")!)
/// Tuesday 2026-09-29 10:00 America/Chicago.
private let tqStart = tqChicago.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 10))!

private final class TQClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date) { self.t = t }
    var now: Date { lock.withLock { t } }
    func advance(minutes: Double) { lock.withLock { t = t.addingTimeInterval(minutes * 60) } }
}

private final class TQSettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var s: EngineSettings
    init(_ s: EngineSettings) { self.s = s }
    var value: EngineSettings { lock.withLock { s } }
    func update(_ f: (inout EngineSettings) -> Void) { lock.withLock { f(&s) } }
}

private final class TQRecorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ x: T) { lock.withLock { items.append(x) } }
    var all: [T] { lock.withLock { items } }
}

private struct TQDelivery: Sendable {
    var messagePK: Int64
    var outcome: AgentOutcome
}

private extension AgentQueue.Tuning {
    static let triageFast = AgentQueue.Tuning(jobTimeout: .milliseconds(300), testTimeout: .milliseconds(300),
                                              maxNap: .milliseconds(20), idleNap: .milliseconds(50),
                                              loginRecheck: .milliseconds(100), shutdownWait: .seconds(1),
                                              detectThrottle: .zero)
}

private let tqPaperText = [
    "Deep Atlas of Developing Cortex Cells\nAbstract\nWe profile 50,000 single cells from the developing cortex.",
    "Results\nFig. 1 shows the atlas. Fig. 2 compares proportions across four stages.",
    "Methods\nSingle-cell RNA-seq with 10x Genomics; clustering with Leiden.",
].joined(separator: "\u{0C}")

/// Body text that must never appear in any log line.
private let tqSecretBody = "SECRET-BODY-7f3a: please read the attached draft before Friday [c1]"

/// Scripted provider for both lanes. Asks the spawn gate (like the real providers) before each
/// pretend spawn and records the run order: "C" for a card, the request's model for a triage.
private actor TQProvider: AgentProvider, AgentDryRunning {
    nonisolated let id: String
    private let kind: AIProviderKind
    private var status: ProviderStatus
    private var gate: AgentSpawnGate?
    private var triageScript: [AgentOutcome] = []
    private var cardScript: [AgentOutcome] = []
    private let triageDelay: Duration
    private(set) var order: [String] = []
    private(set) var generateCalls = 0
    private(set) var spawns = 0

    init(kind: AIProviderKind = .claude, triageDelay: Duration = .zero) {
        self.kind = kind
        self.id = kind.providerID
        self.status = .ready(plan: "max", version: "9.9.9", path: "/fake/\(kind.rawValue)")
        self.triageDelay = triageDelay
    }

    func setGate(_ g: AgentSpawnGate) { gate = g }
    func pushTriage(_ o: AgentOutcome...) { triageScript += o }
    func pushCard(_ o: AgentOutcome...) { cardScript += o }

    func detect() async -> ProviderStatus { status }

    func generateCard(_ r: CardRequest, jobDir: URL) async -> AgentOutcome {
        generateCalls += 1
        if let gate, !gate.allowSpawn(provider: kind, summary: "fake \(id)") { return .cancelled }
        spawns += 1
        let triage = MailTriageSchema.isTriageRequest(r)
        order.append(triage ? r.model : "C")
        if triage {
            if triageDelay > .zero {
                do { try await Task.sleep(for: triageDelay) } catch { return .cancelled }
            }
            if !triageScript.isEmpty { return triageScript.removeFirst() }
            return .success(card: MockAgentProvider.triage(for: r), meta: RunMeta(
                model: "claude-haiku-test", durationMs: 900, costUSD: 0.001, inputTokens: 800, outputTokens: 120,
                numTurns: 1, variant: "A"))
        }
        if !cardScript.isEmpty { return cardScript.removeFirst() }
        return .success(card: MockAgentProvider.card(for: r), meta: RunMeta(
            model: "claude-sonnet-test", durationMs: 1500, costUSD: 0.02, inputTokens: 1000, outputTokens: 300,
            numTurns: 1, variant: "A"))
    }

    func dryRunSummary(_ r: CardRequest) async -> String {
        "argv: /fake/\(id) -p … --model \(r.model) · stdin: \(r.stdin.count) bytes"
    }
}

private struct TQHarness {
    let root: URL
    let engine: Engine
    let clock: TQClock
    let settings: TQSettingsBox
    let logs: TQRecorder<String>
    let delivered: TQRecorder<TQDelivery>

    var db: Database { engine.db }
    var queue: AgentQueue { engine.agents }

    static func make(mode: AgentMode, claude: any AgentProvider = TQProvider(),
                     codex: any AgentProvider = TQProvider(kind: .codex),
                     mock: any AgentProvider = MockAgentProvider(), tuning: AgentQueue.Tuning = .triageFast,
                     handler: Bool = true) async throws -> TQHarness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-triageq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let box = TQSettingsBox(EngineSettings(plan: PlanSettings(dailyBudgetMinutes: 60), lang: .en, agentMode: mode,
                                               metadataLookup: false))
        let clock = TQClock(tqStart)
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: Engine.Dependencies(
            loadSettings: { box.value }, now: { clock.now }, calendar: tqChicago, fetcher: nil,
            claude: claude, codex: codex, mock: mock, sidecarDelay: .milliseconds(10), cliFacts: .inMemory(), assistBackends: [MockAssistBackend()]))
        let logs = TQRecorder<String>()
        let delivered = TQRecorder<TQDelivery>()
        await engine.agents.configure(tuning)
        await engine.agents.setLogObserver { logs.append($0) }
        if handler {
            await engine.agents.setTriageHandler { job, outcome in
                delivered.append(TQDelivery(messagePK: job.messagePK, outcome: outcome))
            }
        } else {
            await engine.agents.setTriageHandler(nil)       // Engine.open wires MailTriageCoordinator
        }
        return TQHarness(root: root, engine: engine, clock: clock, settings: box, logs: logs, delivered: delivered)
    }

    func finish() async {
        await engine.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    /// A triage job for message `pk`; the request's model names it ("t<pk>") so runs can be told apart.
    func triageJob(_ pk: Int64, provider: AIProviderKind? = nil, timeout: Duration = .seconds(5)) -> MailTriageJob {
        let message = MailMessage(pk: pk, accountID: "acct", internetMessageID: "<m\(pk)@wustl.edu>",
                                  fromAddress: "prof.x@wustl.edu", fromName: "Prof. X", senderKind: .advisor,
                                  subject: "Mail #\(pk)", receivedAt: tqStart)
        let item = MailItem(messagePK: pk, ord: 0, cand: "c1", origin: .attachment, title: "Draft \(pk)", pdfState: .hasPDF)
        let stdin = MailTriageSchema.stdin(message: message,
                                           extraction: MailExtraction(bodyText: tqSecretBody, snippet: "", candidates: []),
                                           candidates: [item], criteria: ReadingCriteria(), categories: [],
                                           frequentTags: [], calendar: tqChicago)
        return MailTriageJob(messagePK: pk, messageID: message.id,
                             request: MailTriageSchema.request(stdin: stdin, model: "t\(pk)", timeout: timeout),
                             provider: provider)
    }

    /// A ready paper with cached text (a card job can run for it).
    @discardableResult
    func insertPaper(_ name: String = "cortex.pdf") async throws -> Paper {
        let id = UUID().uuidString.lowercased()
        let sha = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let folder = "Papers/_Inbox/\(sha.prefix(8))"
        try FileManager.default.createDirectory(at: engine.paths.library.appendingPathComponent(folder),
                                                withIntermediateDirectories: true)
        let paper = Paper(id: id, sha256: sha, fileSize: 1000, title: name, titleRank: .font, metaSource: .none,
                          pageCount: 3, charCount: tqPaperText.count, folder: folder, pdfName: "paper.pdf",
                          originalName: "paper.pdf", stage: .ready, deadline: nil, scheduleMode: .none,
                          deadlineOrigin: .place, provisional: true, estMinutes: 30, estSource: .heuristic,
                          addedAt: clock.now.addingTimeInterval(-3600), updatedAt: clock.now)
        let saved = try await db.insertPaper(paper, checklist: [])
        try engine.ctx.texts.save(tqPaperText, id: id)
        return saved
    }

    func paper(_ pk: Int64) async throws -> Paper { try #require(try await db.paper(pk: pk)) }

    var triageDirs: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: engine.paths.jobs.path)) ?? []).filter { $0.hasPrefix("triage-") }
    }
}

/// Polls `condition` every 10 ms for up to `timeout`.
private func tqEventually(_ timeout: Duration = .seconds(20), _ condition: () async throws -> Bool) async -> Bool {      // generous on a loaded machine (ENV-1)
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if (try? await condition()) == true { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return (try? await condition()) == true
}

// MARK: - Triage lane

@Suite struct AgentQueueTriageTests {
    @Test func modeOffNeverSpawnsAndHandsBackCancelled() async throws {
        let claude = TQProvider()
        let mock = MockAgentProvider()
        let h = try await TQHarness.make(mode: .off, claude: claude, mock: mock)
        await h.queue.enqueueTriage(h.triageJob(1))
        await h.queue.enqueueTriage(h.triageJob(2))
        await h.queue.start()

        #expect(await tqEventually { h.delivered.all.count == 2 })
        #expect(h.delivered.all.map(\.messagePK) == [1, 2])
        #expect(h.delivered.all.allSatisfy { $0.outcome == .cancelled })
        #expect(await claude.generateCalls == 0)
        #expect(await mock.calls == 0)
        let wouldRun = h.logs.all.filter { $0.hasPrefix("WOULD RUN triage") }
        #expect(wouldRun.count == 2)
        #expect(wouldRun[0].contains("mail#1 (agent.mode off)") && wouldRun[0].contains("--model t1"))
        #expect(await h.queue.triageStatus().queued == 0)
        // Nothing about the email body is ever logged.
        #expect(!h.logs.all.contains { $0.contains("SECRET-BODY") })
        #expect(MailTriageRoute.of(provider: nil, settings: h.settings.value).heldText(.en)
                == "AI is off · the email was not sent to AI")
        await h.finish()
    }

    @Test func mockModeDeliversTheTriageJSONAndRemovesTheJobDir() async throws {
        let mock = MockAgentProvider()
        let h = try await TQHarness.make(mode: .mock, mock: mock)
        await h.queue.enqueueTriage(h.triageJob(5))
        await h.queue.start()

        #expect(await tqEventually { h.delivered.all.count == 1 })
        let d = try #require(h.delivered.all.first)
        #expect(d.messagePK == 5)
        guard case .success(let raw, let meta) = d.outcome else {
            Issue.record("expected success, got \(d.outcome)")
            await h.finish()
            return
        }
        #expect(meta.model == "mock")
        #expect(raw["has_reading_request"] == .bool(true) && raw["request_kind"] == .string("advisor_request"))
        #expect(raw["papers"]?.arrayValue?.first?["ref"] == .string("c1"))
        #expect(await mock.calls == 1)
        let request = try #require(await mock.lastRequest)
        #expect(request.userPrompt == MailTriageSchema.userPrompt() && request.model == "t5")
        #expect(await tqEventually { h.triageDirs.isEmpty })
        let status = await h.queue.triageStatus()
        #expect(status.queued == 0 && status.runningMessagePK == nil)
        #expect(!h.logs.all.contains { $0.contains("SECRET-BODY") })
        await h.finish()
    }

    @Test func triageGoesFirstButAtMostThreeInARowWhileCardsWait() async throws {
        let claude = TQProvider()
        let h = try await TQHarness.make(mode: .claude, claude: claude)
        let a = try await h.insertPaper("a.pdf")
        let b = try await h.insertPaper("b.pdf")
        await h.queue.enqueue(paperPK: a.pk, hold: false)
        await h.queue.enqueue(paperPK: b.pk, hold: false)
        for pk in 1...5 { await h.queue.enqueueTriage(h.triageJob(Int64(pk))) }
        await h.queue.start()

        #expect(await tqEventually { await claude.order.count == 7 })
        #expect(await claude.order == ["t1", "t2", "t3", "C", "t4", "t5", "C"])
        #expect(await tqEventually { h.delivered.all.count == 5 })
        #expect(h.delivered.all.map(\.messagePK) == [1, 2, 3, 4, 5])
        #expect(await tqEventually { try await h.paper(a.pk).aiState == .done })
        #expect(await tqEventually { try await h.paper(b.pk).aiState == .done })
        await h.finish()
    }

    @Test func aTriageUsageLimitPausesBothLanesAndResumes() async throws {
        let claude = TQProvider()
        let h = try await TQHarness.make(mode: .claude, claude: claude)
        await claude.pushTriage(.usageLimit(resetsAt: tqStart.addingTimeInterval(3600)))
        await h.queue.enqueueTriage(h.triageJob(1))
        await h.queue.start()

        #expect(await tqEventually { await h.queue.status().pausedUntil != nil })
        let until = try #require(await h.queue.status().pausedUntil)
        #expect(until == tqStart.addingTimeInterval(3600 + 120))
        #expect(try await h.db.kv(AgentQueue.pausedUntilKey) == Database.timestamp(until))
        // Paused: neither a new card nor a new triage runs; the limited job waits at the front.
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.queue.enqueueTriage(h.triageJob(2))
        try await Task.sleep(for: .milliseconds(250))
        #expect(await claude.order == ["t1"])
        #expect(h.delivered.all.isEmpty)                                    // a limit is not a result
        #expect(await h.queue.queuedTriageMessagePKs() == [1, 2])
        #expect(try await h.paper(p.pk).aiState == .limited)

        h.clock.advance(minutes: 120)
        await h.queue.wake()
        #expect(await tqEventually { await claude.order.count == 4 })
        #expect(await claude.order == ["t1", "t1", "t2", "C"])
        #expect(await tqEventually { h.delivered.all.count == 2 })
        #expect(h.delivered.all.map(\.messagePK) == [1, 2])
        #expect(try await h.db.kv(AgentQueue.pausedUntilKey) == nil)
        await h.finish()
    }

    @Test func aCardUsageLimitAlsoHoldsTriage() async throws {
        let claude = TQProvider()
        let h = try await TQHarness.make(mode: .claude, claude: claude)
        await claude.pushCard(.usageLimit(resetsAt: tqStart.addingTimeInterval(1800)))
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.queue.start()
        #expect(await tqEventually { await h.queue.status().pausedUntil != nil })

        await h.queue.enqueueTriage(h.triageJob(9))
        try await Task.sleep(for: .milliseconds(250))
        #expect(await claude.order == ["C"])
        #expect(await h.queue.triageStatus().queued == 1)

        h.clock.advance(minutes: 60)
        await h.queue.wake()
        #expect(await tqEventually { await claude.order.count == 3 })
        #expect(await claude.order == ["C", "t9", "C"])                    // triage first after the pause
        await h.finish()
    }

    @Test func theRunBudgetCountsTriageSpawns() async throws {
        let claude = TQProvider()
        let h = try await TQHarness.make(mode: .claude, claude: claude)
        await claude.setGate(h.queue.spawnGate)
        h.queue.runBudget.setLimit(2)
        for pk in 1...3 { await h.queue.enqueueTriage(h.triageJob(Int64(pk))) }
        await h.queue.start()

        #expect(await tqEventually { h.logs.all.contains { $0.hasPrefix("RUN BUDGET EXHAUSTED") } })
        #expect(h.queue.runBudget.consumed == 2)
        #expect(await claude.spawns == 2)
        #expect(await tqEventually { h.delivered.all.count == 2 })
        #expect(await h.queue.triageStatus().queued == 1)                   // the third waits, never spawned
        #expect(await h.queue.queuedTriageMessagePKs() == [3])
        await h.finish()
    }

    @Test(.timeLimit(.minutes(1))) func cancelTriageDropsQueuedAndTerminatesRunningWithoutAHandlerCall() async throws {
        let mock = MockAgentProvider(behavior: .hang)
        let h = try await TQHarness.make(mode: .mock, mock: mock)
        // Queued (loop not started yet): dropped, order kept; re-enqueueing replaces in place.
        await h.queue.enqueueTriage(h.triageJob(1))
        await h.queue.enqueueTriage(h.triageJob(2))
        await h.queue.enqueueTriage(h.triageJob(3))
        await h.queue.enqueueTriage(h.triageJob(1, timeout: .seconds(30)))
        #expect(await h.queue.queuedTriageMessagePKs() == [1, 2, 3])
        await h.queue.cancelTriage(messagePK: 2)
        await h.queue.cancelTriage(messagePK: 3)
        #expect(await h.queue.triageStatus().queued == 1)

        // Running: the hanging child is cancelled; the handler never hears about it.
        await h.queue.start()
        #expect(await tqEventually { await h.queue.triageStatus().runningMessagePK == 1 })
        #expect(await tqEventually { await mock.lastRequest?.timeout == .seconds(30) })   // the replacement ran
        await h.queue.enqueueTriage(h.triageJob(1))                         // already running → ignored
        #expect(await h.queue.triageStatus().queued == 0)
        await h.queue.cancelTriage(messagePK: 1)
        #expect(await tqEventually { await h.queue.triageStatus().runningMessagePK == nil })
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.delivered.all.isEmpty)
        #expect(await mock.calls == 1)
        #expect(h.logs.all.contains("triage mail#1: cancelled"))
        #expect(await tqEventually { h.triageDirs.isEmpty })
        await h.finish()
    }

    @Test func aProviderTheModeDoesNotRunNeverGetsTheEmail() async throws {
        let claude = TQProvider()
        let codex = TQProvider(kind: .codex)
        let h = try await TQHarness.make(mode: .claude, claude: claude, codex: codex)
        await h.queue.enqueueTriage(h.triageJob(4, provider: .codex))
        await h.queue.enqueueTriage(h.triageJob(5, provider: .claude))
        await h.queue.enqueueTriage(h.triageJob(6))                         // nil → the selected provider (claude)
        await h.queue.start()

        #expect(await tqEventually { h.delivered.all.count == 3 })
        let byPK = Dictionary(uniqueKeysWithValues: h.delivered.all.map { ($0.messagePK, $0.outcome) })
        #expect(byPK[4] == .cancelled)
        if case .success = byPK[5] {} else { Issue.record("claude job did not succeed: \(String(describing: byPK[5]))") }
        if case .success = byPK[6] {} else { Issue.record("default job did not succeed: \(String(describing: byPK[6]))") }
        #expect(await codex.generateCalls == 0)
        #expect(await claude.order == ["t5", "t6"])
        #expect(h.logs.all.contains { $0.hasPrefix("WOULD RUN triage mail#4 (agent.mode claude does not run codex)") })
        let route = MailTriageRoute.of(provider: .codex, settings: h.settings.value)
        #expect(route == .providerNotActive(wanted: .codex, mode: .claude))
        #expect(route.heldText(.zh) == "邮件分拣只允许使用 ChatGPT，当前 AI 模式是 Claude")
        #expect(MailTriageRoute.of(provider: .codex, settings: EngineSettings(agentMode: .mock)) == .run(nil))
        await h.finish()
    }

    @Test func failuresAreHandedOverOnceWithoutLoggingTheirText() async throws {
        let claude = TQProvider()
        let h = try await TQHarness.make(mode: .claude, claude: claude)
        await claude.pushTriage(.invalidOutput("model said: SECRET-BODY-7f3a"), .timeout, .generic("stderr SECRET-BODY"))
        for pk in 1...3 { await h.queue.enqueueTriage(h.triageJob(Int64(pk))) }
        await h.queue.start()

        #expect(await tqEventually { h.delivered.all.count == 3 })
        #expect(h.delivered.all.map(\.outcome) == [.invalidOutput("model said: SECRET-BODY-7f3a"), .timeout,
                                                   .generic("stderr SECRET-BODY")])
        try await Task.sleep(for: .milliseconds(100))
        #expect(await claude.order == ["t1", "t2", "t3"])                  // no retries inside the lane
        #expect(!h.logs.all.contains { $0.contains("SECRET-BODY") })
        #expect(h.logs.all.contains("triage mail#1 (claude): invalid output"))
        await h.finish()
    }

    @Test func aLoginProblemKeepsTheTriageQueuedUntilWake() async throws {
        let claude = TQProvider()
        var tuning = AgentQueue.Tuning.triageFast
        tuning.loginRecheck = .seconds(60)
        let h = try await TQHarness.make(mode: .claude, claude: claude, tuning: tuning)
        await claude.pushTriage(.notLoggedIn)
        await h.queue.enqueueTriage(h.triageJob(1))
        await h.queue.start()

        #expect(await tqEventually { await h.queue.status().provider == .notLoggedIn(ProviderReason.loggedOut.code) })
        #expect(h.delivered.all.isEmpty)
        #expect(await h.queue.queuedTriageMessagePKs() == [1])
        await h.queue.wake()
        #expect(await tqEventually { h.delivered.all.count == 1 })
        #expect(await claude.order == ["t1", "t1"])
        await h.finish()
    }

    @Test func turningTheModeOffBeforeTheSpawnHoldsInsteadOfRunning() async throws {
        let claude = TQProvider()
        let h = try await TQHarness.make(mode: .claude, claude: claude)
        await h.queue.enqueueTriage(h.triageJob(1))
        h.settings.update { $0.agentMode = .off }
        await h.queue.start()
        #expect(await tqEventually { h.delivered.all.count == 1 })
        #expect(h.delivered.all.first?.outcome == .cancelled)
        #expect(await claude.generateCalls == 0)
        await h.finish()
    }

    @Test func resultsWithoutAHandlerAreDroppedSafely() async throws {
        let mock = MockAgentProvider()
        let h = try await TQHarness.make(mode: .mock, mock: mock, handler: false)
        await h.queue.enqueueTriage(h.triageJob(1))
        await h.queue.start()
        #expect(await tqEventually { h.logs.all.contains("triage mail#1: no triage handler — result dropped") })
        #expect(await mock.calls == 1)
        await h.finish()
    }
}
