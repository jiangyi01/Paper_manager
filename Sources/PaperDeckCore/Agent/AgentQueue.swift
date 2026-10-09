import Foundation

/// Persistent AI job queue (§6.2): at most one agent run at a time, jobs are
/// rows of `agent_job` (one active — held/queued/running — per paper).
///
/// Quota safety (§3.1): `agent.mode` is re-read before every spawn. `off` never
/// spawns (queued jobs become held with `ai_note = "mode_off"` and a `WOULD RUN`
/// log line); `mock` uses the mock provider; `claude` the Claude Code provider and
/// `codex` the Codex CLI provider — only ever the one the mode names. Each real
/// provider's own spawn gate (`AgentSpawnGate.claudeSpawnGate` / `.codexSpawnGate`)
/// re-checks that the mode still names it and the RunBudget before every process,
/// including Claude's variant-B retry. A queued job runs with the provider active at
/// spawn time (the job row records it); switching providers never interrupts a
/// running job — its further spawns are simply refused by its gate.
///
/// Outcomes follow the §6.2 table: success → `CardApplier`; usage limit → pause of
/// that provider persisted in kv (the other provider keeps reading); not logged in /
/// binary missing → wait for `wake()` or
/// 30 min; overloaded / generic → backoff; invalid output / max turns / timeout →
/// one retry with half the text and effort low; then failed. Whatever the classes,
/// a job fails after `maxTotalFailures` failures in total (persisted in kv).
package actor AgentQueue {
    /// Timing knobs; tests shrink them. The injected clock (`ctx.now`) drives pauses
    /// and backoffs, and no single sleep exceeds `maxNap`, so a moved clock is noticed.
    package struct Tuning: Sendable, Equatable {
        package var jobTimeout: Duration
        package var testTimeout: Duration
        package var maxNap: Duration
        package var idleNap: Duration
        package var loginRecheck: Duration
        package var shutdownWait: Duration
        package var detectThrottle: Duration
        /// Watchdog of one Codex card (`codex exec` answers in 30–120 s); `jobTimeout` is Claude's / the mock's.
        package var codexJobTimeout: Duration

        package init(jobTimeout: Duration = .seconds(360), testTimeout: Duration = .seconds(180),
                     maxNap: Duration = .seconds(60), idleNap: Duration = .seconds(60),
                     loginRecheck: Duration = .seconds(30 * 60), shutdownWait: Duration = .seconds(3),
                     detectThrottle: Duration = .seconds(5), codexJobTimeout: Duration = AIProviderKind.codex.jobTimeout) {
            self.jobTimeout = jobTimeout; self.testTimeout = testTimeout; self.maxNap = maxNap
            self.idleNap = idleNap; self.loginRecheck = loginRecheck; self.shutdownWait = shutdownWait
            self.detectThrottle = detectThrottle; self.codexJobTimeout = codexJobTimeout
        }
    }

    // kv keys (library DB). Each provider has its own quota, so its own pause.
    package static let pausedUntilKey = "agent.claude.pausedUntil"
    package static let pauseReasonKey = "agent.claude.pauseReason"
    package static let codexPausedUntilKey = "agent.codex.pausedUntil"
    package static let codexPauseReasonKey = "agent.codex.pauseReason"

    package static func pausedUntilKey(for kind: AIProviderKind) -> String {
        kind == .codex ? codexPausedUntilKey : pausedUntilKey
    }

    package static func pauseReasonKey(for kind: AIProviderKind) -> String {
        kind == .codex ? codexPauseReasonKey : pauseReasonKey
    }
    /// JSON `{job id: failures so far}` of jobs that are retrying (pruned as jobs end).
    package static let failureTotalsKey = "agent.failureTotals"
    // CLIFactStore (UserDefaults) keys — CLI facts, not library state (§3.1). Older builds kept
    // them in the library kv; `start()` migrates them once.
    package static let variantKey = "agent.claude.argvVariant"
    package static let variantCLIVersionKey = "agent.claude.argvVariantCLIVersion"

    /// `paper.ai_note` / `agent_job.error_kind` of jobs held because agent.mode is off
    /// (AgentBadge: 「Claude 解读已关闭」). Held jobs without it await batch confirmation.
    /// A mode-off hold is provider-neutral: enabling either provider can release it.
    package static let modeOffNote = "mode_off"
    package static let usageLimitReason = "usage_limit"
    package static let testConnectionSpawns = 2
    package static let maxOverloadedRetries = 5
    /// Total failures (any class) after which a job fails — alternating classes cannot respawn forever.
    package static let maxTotalFailures = 7
    /// Retried text budgets never shrink below this many characters.
    package static let minTextBudget = 5_000
    /// Triage runs before card jobs, but at most this many in a row while a card job waits.
    package static let maxConsecutiveTriages = 3

    let ctx: EngineContext
    let claude: any AgentProvider
    let codex: any AgentProvider
    let mock: any AgentProvider
    let cliFacts: CLIFactStore
    /// The reading-card prompt's reader (`Engine.Dependencies.loadCardProfile`), re-read per request.
    let loadCardProfile: @Sendable () -> CardPromptProfile
    /// Shared with `ClaudeCodeProvider(spawnGate:)` / `CodexProvider(spawnGate:)`; also reachable by test fakes.
    package nonisolated let spawnGate: AgentSpawnGate
    package nonisolated var runBudget: RunBudget { spawnGate.budget }

    private var tuning = Tuning()
    private var onApplied: (@Sendable (Int64) async -> Void)?
    private var logObserver: (@Sendable (String) -> Void)?

    // Loop plumbing
    private var loopTask: Task<Void, Never>?
    private var loopRunning = false
    private var stopping = false
    /// `beginShutdown()`: no new spawn on either lane; runs in flight continue until `shutdown()`.
    private var spawnsClosed = false
    private var napContinuation: CheckedContinuation<Void, Never>?
    private var napTimer: Task<Void, Never>?
    private var napToken = 0
    private var wakePending = false
    private var exitWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiterID = 0
    private var slotBusy = false
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    // Queue state
    private struct Running {
        var jobPK: Int64
        var paperPK: Int64
        var paperID: String
        var since: Date
        var task: Task<AgentOutcome, Never>?
        var cancelRequested = false
    }
    private struct Pause: Sendable, Equatable {
        var until: Date
        var reason: String
    }
    /// Which provider a run / detection is about. `mock` is the zero-quota stand-in.
    private enum Slot: Sendable, Equatable {
        case claude, codex, mock

        init(_ kind: AIProviderKind) {
            switch kind {
            case .claude: self = .claude
            case .codex: self = .codex
            }
        }

        /// The provider `mode` runs; nil while off.
        init?(mode: AgentMode) {
            switch mode {
            case .off: return nil
            case .mock: self = .mock
            case .claude: self = .claude
            case .codex: self = .codex
            }
        }

        var kind: AIProviderKind? {
            switch self {
            case .claude: return .claude
            case .codex: return .codex
            case .mock: return nil
            }
        }

        /// Whose quota pause applies: the mock shares Claude's, as it always did.
        var pauseKind: AIProviderKind { kind ?? .claude }
    }

    private var running: Running?
    private var testTask: Task<AgentOutcome, Never>?

    // Mail triage lane (in memory — the durable state lives on mail_message, written by the
    // integration layer from `triageHandler`). Shares the slot, gates, pauses and budget.
    private struct RunningTriage {
        var job: MailTriageJob
        var since: Date
        var task: Task<AgentOutcome, Never>?
        var cancelRequested = false
    }
    private var triageQueue: [MailTriageJob] = []
    private var runningTriage: RunningTriage?
    private var triageHandler: (@Sendable (MailTriageJob, AgentOutcome) async -> Void)?
    /// Triage runs since the last card job (fairness: at most `maxConsecutiveTriages` while cards wait).
    private var consecutiveTriages = 0
    /// Handler calls run one after another, off the queue's slot.
    private var deliveryTail: Task<Void, Never>?
    private var deliveryWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    /// Detection result of `detectedSlot`'s provider.
    private var providerStatus: AgentQueueStatus.Provider = .unknown
    private var providerReady = false
    private var detectedSlot: Slot?
    private var lastDetect: ContinuousClock.Instant?
    private var detectRequested = true
    private var forceDetect = false
    /// Set while the provider is not usable; re-detect after `wake()` or `loginRecheck`.
    private var notReadySince: ContinuousClock.Instant?
    private var lastMode: AgentMode?
    private var lastCLIPathOverride: String??
    private var lastCodexPathOverride: String??
    /// Usage-limit pauses by provider (kv `agent.<provider>.pausedUntil`). Mirrored for synchronous
    /// readers (`pause(for:)`, the assist gate).
    private var pauses: [AIProviderKind: Pause] = [:] {
        didSet { pauseMirror.set(pauses.mapValues(\.until)) }
    }
    private nonisolated let pauseMirror = PauseMirror()
    /// The assist lane is generating a turn (READING_ASSIST_PLAN §2: at most one card + one assist
    /// process). While it says so, no new job is claimed; a running one is never cancelled.
    private var assistBusy: @Sendable () -> Bool = { false }
    private var budgetStopLogged = false
    private var wouldRunLogged: Set<String> = []
    private var lastPublished: AgentQueueStatus?

    /// - Parameters:
    ///   - claude / codex: the real providers (`agent.mode` claude / codex); `mock` for mode mock.
    ///   - spawnGate: the gate the real providers were built with (their `claudeSpawnGate` /
    ///     `codexSpawnGate`), so connection tests can open their allowance on it.
    package init(ctx: EngineContext, claude: any AgentProvider, codex: any AgentProvider, mock: any AgentProvider,
                 spawnGate: AgentSpawnGate? = nil, cliFacts: CLIFactStore = .standard,
                 loadCardProfile: @escaping @Sendable () -> CardPromptProfile = { .legacyCompBio }) {
        self.ctx = ctx; self.claude = claude; self.codex = codex; self.mock = mock; self.cliFacts = cliFacts
        self.loadCardProfile = loadCardProfile
        self.spawnGate = spawnGate ?? AgentSpawnGate(loadSettings: ctx.loadSettings)
    }

    private func provider(for slot: Slot) -> any AgentProvider {
        switch slot {
        case .claude: return claude
        case .codex: return codex
        case .mock: return mock
        }
    }

    /// The provider the status describes: the one the mode runs, or — while off — the one the
    /// user chose (so the settings UI can show its login state before enabling it).
    private static func describedSlot(_ settings: EngineSettings) -> Slot {
        Slot(mode: settings.agentMode) ?? Slot(settings.selectedProvider)
    }

    /// `agent_job.provider` of a job that has not run yet (a run records its actual provider).
    private func pendingProviderID(_ settings: EngineSettings) -> String {
        settings.agentMode == .mock ? mock.id : provider(for: Slot(settings.selectedProvider)).id
    }

    // MARK: - Configuration

    /// Call before `start()`.
    package func configure(_ tuning: Tuning) { self.tuning = tuning }

    /// Called after a card was applied and synced (the engine wires it to refiling).
    package func setOnApplied(_ hook: (@Sendable (Int64) async -> Void)?) { onApplied = hook }

    /// Mirrors every queue log line (os_log category `agent` always gets them) — the CLI
    /// prints `RUN BUDGET EXHAUSTED` / `WOULD RUN …` through this, tests assert on it.
    package func setLogObserver(_ observer: (@Sendable (String) -> Void)?) { logObserver = observer }

    /// The assist lane's busy flag (synchronous; the engine wires `AssistLane.isBusyNow`).
    package func setAssistBusy(_ hook: @escaping @Sendable () -> Bool) { assistBusy = hook }

    /// The assist lane went idle: a job that waited for it may be claimed now (no re-detection).
    package func assistDidFinish() { poke() }

    // MARK: - Lifecycle

    /// Recovers interrupted jobs, gives waiting papers without a job their job back, restores
    /// the learned Claude argv variant and the persisted pauses, then runs the loop (detection happens
    /// on its first pass). Returns quickly. Calling it again restarts a loop that stopped on an
    /// exhausted RunBudget.
    package func start() async {
        guard !stopping, !spawnsClosed, loopTask == nil else { return }
        do {
            let n = try await ctx.db.resetRunningJobsToQueued()
            if n > 0 { log("recovered \(n) interrupted job(s) as queued") }
        } catch {
            log("resetRunningJobsToQueued failed: \(error)", isError: true)
        }
        await reconcileWaitingPapers()
        await restoreLearnedVariant()
        await loadPauses()
        budgetStopLogged = false
        loopRunning = true
        loopTask = Task { await self.runLoop() }
        await publish()
    }

    /// Quit, first step (`Engine.shutdown` calls it before anything else winds down): from now
    /// on nothing new is spawned on either lane — no card job, no triage, no connection test.
    /// A run already in flight continues until `shutdown()`; queued jobs stay queued (cards in
    /// the database, triage on its message) for the next launch.
    package func beginShutdown() async {
        guard !spawnsClosed else { return }
        spawnsClosed = true
        log("shutting down — no new runs")
        poke()
    }

    /// Cancels the running child (its job goes back to queued, never failed), stops the
    /// loop and waits up to `shutdownWait` for it to finish.
    package func shutdown() async {
        guard !stopping else { return }
        stopping = true
        testTask?.cancel()
        runningTriage?.task?.cancel()           // the triage goes back to the (in-memory) lane, never failed
        if let r = running {
            running?.task?.cancel()
            await transition(jobPK: r.jobPK, from: [.running],
                             job: { $0.state = .queued; $0.startedAt = nil },
                             paper: { $0.aiState = .queued; $0.aiNote = nil })
        }
        poke()
        await waitForLoopExit(timeout: tuning.shutdownWait)
        await drainTriageDeliveries(timeout: tuning.shutdownWait)
        await publish()
    }

    // MARK: - Public operations

    /// Creates (or re-arms) the paper's job: state held (`hold`) or queued, attempt 0,
    /// no backoff; paper ai_state held/queued. A running job is left alone.
    package func enqueue(paperPK: Int64, hold: Bool, priority: Int = 0) async {
        let now = ctx.now()
        let providerID = pendingProviderID(ctx.loadSettings())
        do {
            let changed = try await ctx.db.transaction { db -> Bool in
                guard let p = try db.paper(pk: paperPK), p.isLive else { return false }
                let state: AgentJobState = hold ? .held : .queued
                if var j = try db.activeJob(paperPK: paperPK) {
                    guard j.state != .running else { return false }
                    j.state = state
                    j.priority = priority
                    j.attempt = 0
                    j.notBefore = nil
                    j.textBudget = nil
                    j.effort = nil
                    j.errorKind = nil
                    j.errorMessage = nil
                    j.startedAt = nil
                    j.finishedAt = nil
                    try db.updateJob(j)
                    try AgentQueue.updateFailureTotals(db) { $0[j.id] = nil }
                } else {
                    try db.insertJob(AgentJob(paperPK: paperPK, provider: providerID, state: state,
                                              priority: priority, createdAt: now))
                }
                try db.modifyPaper(pk: paperPK, now: now) {
                    $0.aiState = hold ? .held : .queued
                    $0.aiNote = nil
                }
                return true
            }
            if changed { await ctx.syncSidecar(pk: paperPK) }
        } catch {
            log("enqueue(\(paperPK)) failed: \(error)", isError: true)
        }
        poke()
        await publish()
    }

    /// Held → queued (nil = every held job, including those held because the mode was off).
    package func releaseHeld(paperPKs: [Int64]?) async {
        let held = (try? await ctx.db.jobs(states: [.held])) ?? []
        let wanted = paperPKs.map(Set.init)
        let pks = held.filter { wanted?.contains($0.paperPK) ?? true }.map(\.pk)
        await transitionAll(jobPKs: pks, from: [.held],
                            job: { j in
                                j.state = .queued
                                j.notBefore = nil
                                if j.errorKind == AgentQueue.modeOffNote { j.errorKind = nil }
                            },
                            paper: { $0.aiState = .queued; $0.aiNote = nil })
        poke()
        await publish()
    }

    /// Held/queued/running → cancelled. A running child is terminated; the paper
    /// goes back to `none` (or `done` if it still has an earlier card).
    package func cancel(paperPK: Int64) async {
        guard let job = try? await ctx.db.activeJob(paperPK: paperPK) else { return }
        if running?.jobPK == job.pk {
            running?.cancelRequested = true
            running?.task?.cancel()
        }
        let now = ctx.now()
        await transition(jobPK: job.pk, from: [.held, .queued, .running],
                         job: { j in
                             j.state = .cancelled
                             j.finishedAt = now
                             j.notBefore = nil
                         },
                         paper: { p in
                             p.aiState = p.card == nil ? .none : .done
                             p.aiNote = nil
                         })
        poke()
        await publish()
    }

    /// Failed / cancelled / backing-off paper → queued again (attempt 0, no backoff).
    package func retry(paperPK: Int64) async {
        let priority = (try? await ctx.db.activeJob(paperPK: paperPK))?.priority ?? 0
        await enqueue(paperPK: paperPK, hold: false, priority: priority)
    }

    /// Re-read agent.mode and the login state now (app activated, 「我已登录」, settings changed).
    /// `forceDetect` skips the detect throttle even when the provider looked ready (e.g. the CLI
    /// path changed).
    package func wake(forceDetect force: Bool = false) {
        // A ready provider is re-checked at most every `detectThrottle`; a missing login immediately.
        if !providerReady || force { forceDetect = true }
        detectRequested = true
        poke()
    }

    package func status() async -> AgentQueueStatus { await currentStatus() }

    /// 1-based run order of every queued job, by paper pk (AgentBadge 「排队中 · 第 N」).
    /// Jobs waiting out a backoff keep their place.
    package func queuePositions() async -> [Int64: Int] {
        let queued = (try? await ctx.db.jobs(states: [.queued])) ?? []
        return Dictionary(queued.enumerated().map { ($0.element.paperPK, $0.offset + 1) }, uniquingKeysWith: { a, _ in a })
    }

    /// User-initiated connectivity test: a tiny synthetic paper through one real provider
    /// (`provider`, default: the selected one — the mode's, else `agent.provider`) regardless
    /// of agent.mode, at most two spawns of that provider (Claude: variant A → B; Codex: one
    /// run). Claude uses haiku, Codex gpt-5.6-luna (or `model`), both effort low. Never touches papers, jobs
    /// or categories; only a learned Claude variant B is remembered (a CLI fact). The result
    /// updates the queue status only when the status describes the tested provider.
    package func testConnection(provider requested: AIProviderKind? = nil, model: String? = nil) async -> AgentOutcome {
        await acquireSlot()
        defer { releaseSlot() }
        guard !stopping, !spawnsClosed else { return .cancelled }
        let settings = await ctx.settings()
        let kind = requested ?? settings.selectedProvider
        let slot = Slot(kind)
        spawnGate.beginConnectionTest(provider: kind, spawns: Self.testConnectionSpawns)
        defer { spawnGate.endConnectionTest() }

        let request = Self.connectionTestRequest(model: model ?? kind.connectionTestModel, timeout: tuning.testTimeout)
        let dir = ctx.paths.jobs.appendingPathComponent("test-\(UUID().uuidString.lowercased())", isDirectory: true)
        let provider = provider(for: slot)
        let task = Task { await provider.generateCard(request, jobDir: dir) }
        testTask = task
        let outcome = await task.value
        testTask = nil
        log("connection test (\(kind.rawValue)): \(Self.describe(outcome))")

        // A Codex test while the status describes Claude (or the reverse) must not relabel it.
        let describesTested = (detectedSlot ?? Self.describedSlot(settings)) == slot
        switch outcome {
        case .success(_, let meta):
            await Self.removeDirectory(dir)
            if slot == .claude, meta.variant == "B" { await persistLearnedVariant(from: provider) }
            detectRequested = true
        case .notLoggedIn:
            let status = await (provider as? any AgentAuthReporting)?.authRefusalStatus()
                ?? .notLoggedIn(ProviderReason.loggedOut.code)
            if describesTested { applyProviderStatus(status, of: slot) } else { detectRequested = true }
        case .binaryMissing:
            if describesTested { applyProviderStatus(.notInstalled, of: slot) } else { detectRequested = true }
        default:
            break
        }
        poke()
        await publish()
        return outcome
    }

    // MARK: - Mail triage lane (public)

    /// Receives the result of every triage job that leaves the lane — once per job, in order,
    /// off the queue's slot (the next run does not wait for the handler's own network work):
    /// - `.success(card:meta:)`: `card` is the raw triage JSON (run `MailTriageSanitizer`); for
    ///   Claude, `meta` includes a variant-A attempt's cost when variant B produced the answer.
    /// - `.cancelled`: nothing was sent — agent.mode is off or does not name the job's provider
    ///   (a `WOULD RUN` line was logged), or a spawn gate refused → mark the message held.
    /// - `.invalidOutput`, `.maxTurns`, `.timeout`, `.overloaded`, `.generic`: the lane does not
    ///   retry; the integration decides (triage_attempt / triage_not_before).
    /// Usage limits (the provider's pause — both lanes), login / binary problems (wait for
    /// `wake()`) and a shutdown keep the job queued instead; `cancelTriage` never calls it.
    package func setTriageHandler(_ h: (@Sendable (MailTriageJob, AgentOutcome) async -> Void)?) {
        triageHandler = h
    }

    /// Queues one triage call (FIFO). A job already queued for the same message is replaced in
    /// place (same position); one already running is left alone (the new request is dropped).
    package func enqueueTriage(_ job: MailTriageJob) async {
        guard !stopping else {
            log("triage mail#\(job.messagePK): queue is shutting down — not queued")
            return
        }
        if runningTriage?.job.messagePK == job.messagePK {
            log("triage mail#\(job.messagePK): already running — not queued again")
            return
        }
        if let i = triageQueue.firstIndex(where: { $0.messagePK == job.messagePK }) {
            triageQueue[i] = job
        } else {
            triageQueue.append(job)
        }
        poke()
        await publish()
    }

    /// Drops the message's queued triage and terminates a running one (no handler call).
    package func cancelTriage(messagePK: Int64) async {
        await cancelTriage(messagePKs: [messagePK])
    }

    /// `cancelTriage(messagePK:)` for several messages at once — atomically, so terminating the
    /// running one can never let another of them start in between.
    package func cancelTriage(messagePKs: Set<Int64>) async {
        guard !messagePKs.isEmpty else { return }
        triageQueue.removeAll { messagePKs.contains($0.messagePK) }
        if let running = runningTriage?.job.messagePK, messagePKs.contains(running) {
            runningTriage?.cancelRequested = true
            runningTriage?.task?.cancel()
        }
        poke()
        await publish()
    }

    package func triageStatus() async -> (queued: Int, runningMessagePK: Int64?) {
        (triageQueue.count, runningTriage?.job.messagePK)
    }

    /// Message pks of the queued triage jobs in run order (the running one excluded).
    package func queuedTriageMessagePKs() async -> [Int64] { triageQueue.map(\.messagePK) }

    // MARK: - Loop

    private enum Next {
        case again
        case nap(Duration)
        case stop
    }

    private func runLoop() async {
        while !stopping {
            await acquireSlot()
            let next: Next = stopping ? .stop : await step()
            releaseSlot()
            if case .stop = next { break }
            if case .nap(let d) = next { await nap(d) }
        }
        loopDidExit()
    }

    private func step() async -> Next {
        // Pokes that arrived before this pass are covered by the fresh reads below.
        wakePending = false
        if spawnsClosed { return .stop }            // quitting: nothing new starts
        let settings = await ctx.settings()
        let mode = settings.agentMode
        if mode != lastMode {
            if let old = lastMode { log("agent.mode \(old.rawValue) → \(mode.rawValue)") }
            lastMode = mode
            detectRequested = true
            forceDetect = true
        }
        // Settings ▸ AI changed a CLI path: the locators re-read it by themselves; re-detect now.
        if let last = lastCLIPathOverride, last != settings.cliPathOverride {
            log("CLI path override changed")
            detectRequested = true
            forceDetect = true
        }
        lastCLIPathOverride = .some(settings.cliPathOverride)
        if let last = lastCodexPathOverride, last != settings.codexPathOverride {
            log("Codex CLI path override changed")
            detectRequested = true
            forceDetect = true
        }
        lastCodexPathOverride = .some(settings.codexPathOverride)

        guard let slot = Slot(mode: mode) else {
            // Off: never spawn. Detect the chosen provider (zero quota) for the settings UI.
            let chosen = Slot(settings.selectedProvider)
            if detectRequested || detectedSlot != chosen { await detect(chosen) }
            await holdQueuedJobsForModeOff(settings: settings)
            await dropUnroutableTriage(settings: settings)
            await publish()
            return .nap(tuning.idleNap)
        }
        let provider = provider(for: slot)
        // Triage jobs whose provider the mode does not run are never sent anywhere else.
        await dropUnroutableTriage(settings: settings)
        // Just switched provider (or first pass): describe it at once (zero quota), even while
        // it is paused — the status must never show the previous provider under the new mode.
        if detectedSlot != slot { await detect(slot) }

        let now = ctx.now()
        if let p = pauses[slot.pauseKind] {
            if p.until > now {
                await markQueuedPapers(.limited, note: nil)
                await publish()
                return .nap(Self.napDuration(until: p.until, now: now, cap: tuning.maxNap))
            }
            await clearPause(slot.pauseKind)
            detectRequested = true
        }

        let clock = ContinuousClock()
        if detectRequested || detectedSlot != slot {
            await detect(slot)
        } else if !providerReady, let since = notReadySince, since.duration(to: clock.now) >= tuning.loginRecheck {
            forceDetect = true
            await detect(slot)
        }
        let agent = slot.kind ?? settings.selectedProvider
        guard providerReady else {
            // Not installed / not logged in: keep the jobs queued and wait for wake() or loginRecheck.
            let since = notReadySince ?? clock.now
            notReadySince = since
            await markQueuedPapers(.needsLogin, note: AgentQueueText.needsLoginNote(providerStatus, agent, settings.lang))
            await publish()
            let waited = since.duration(to: clock.now)
            return .nap(max(.milliseconds(1), min(tuning.loginRecheck - waited, tuning.loginRecheck)))
        }
        notReadySince = nil
        await markQueuedPapers(.queued, note: nil)

        let job: AgentJob?
        do { job = try await ctx.db.nextRunnableJob(now: now) } catch {
            log("nextRunnableJob failed: \(error)", isError: true)
            guard !triageQueue.isEmpty else { return .nap(tuning.maxNap) }
            job = nil
        }
        // Lane choice: triage first (short, user-facing), at most `maxConsecutiveTriages` in a row
        // while a card job is waiting, so a flood of alerts cannot starve reading.
        let triageTurn = !triageQueue.isEmpty && (job == nil || consecutiveTriages < Self.maxConsecutiveTriages)
        if !triageTurn, job == nil {
            await publish()
            if let next = try? await ctx.db.earliestNotBefore() {
                return .nap(Self.napDuration(until: next, now: now, cap: tuning.maxNap))
            }
            return .nap(tuning.idleNap)
        }
        if slot.kind != nil, runBudget.isExhausted {
            if !budgetStopLogged {
                budgetStopLogged = true
                log("RUN BUDGET EXHAUSTED — \(runBudget.consumed) run(s) used; the agent queue stops")
            }
            await publish()
            return .stop
        }
        // An interactive assist turn is generating: claim nothing new until the lane is idle (it
        // calls `assistDidFinish`); the nap is capped in case that call is missed.
        if assistBusy() {
            await publish()
            return .nap(min(tuning.maxNap, .seconds(5)))
        }
        if triageTurn {
            await runTriage(slot: slot, provider: provider, mode: mode, settings: settings)
            return .again
        }
        guard let job else { return .again }
        consecutiveTriages = 0
        await run(job, slot: slot, provider: provider, mode: mode, settings: settings)
        return .again
    }

    // MARK: - Running one job

    private struct Claimed: Sendable {
        var job: AgentJob
        var paper: Paper
    }

    private struct PreparedRequest: Sendable {
        var request: CardRequest
        var pageCount: Int?
    }

    private func run(_ picked: AgentJob, slot: Slot, provider: any AgentProvider, mode: AgentMode,
                     settings: EngineSettings) async {
        let startedAt = ctx.now()
        guard let claimed = await claim(jobPK: picked.pk, providerID: provider.id, at: startedAt) else {
            await publish()
            return
        }
        let job = claimed.job, paper = claimed.paper
        running = Running(jobPK: job.pk, paperPK: paper.pk, paperID: paper.id, since: startedAt)
        await ctx.syncSidecar(pk: paper.pk)
        await publish()

        let jobDir = ctx.paths.jobs.appendingPathComponent(job.id, isDirectory: true)
        let agent = slot.kind ?? settings.selectedProvider
        let prepared: PreparedRequest
        do {
            prepared = try await prepareRequest(paper: paper, job: job, settings: settings, slot: slot)
        } catch {
            if running?.cancelRequested != true, !stopping {
                if error is PrepareError {
                    await fail(job, kind: "no_text", message: String(describing: error), jobDir: nil,
                               note: AgentQueueText.failureNote(kind: "no_text", agent: agent, lang: settings.lang))
                } else {
                    await retryOrFail(job, kind: "generic", message: "preparing the request failed: \(error)",
                                      costsIn: nil, settings: settings, agent: agent)
                }
            }
            running = nil
            await publish()
            return
        }
        await Self.resetDirectory(jobDir)

        // agent.mode is read again right before the spawn (the provider's gate checks it once more):
        // a switch to the other provider sends the job back to wait for it.
        let modeNow = await ctx.settings().agentMode
        if running?.cancelRequested == true || stopping || spawnsClosed || modeNow != mode
            || (slot.kind != nil && runBudget.isExhausted) {
            if running?.cancelRequested != true, !stopping { await requeue(job, jobDir: nil) }
            running = nil
            await publish()
            return
        }

        // A cancel that landed between the claim and `running` being set only reached the DB.
        guard (try? await ctx.db.job(pk: job.pk))?.state == .running, running?.cancelRequested != true, !stopping,
              !spawnsClosed else {
            if running?.cancelRequested != true, !stopping { await requeue(job, jobDir: nil) }
            running = nil
            await publish()
            return
        }
        let request = prepared.request
        let task = Task { await provider.generateCard(request, jobDir: jobDir) }
        running?.task = task
        let outcome = await task.value
        let cancelled = running?.cancelRequested == true
        if !cancelled, !stopping {
            await handle(outcome, job: job, paper: paper, prepared: prepared, settings: settings,
                         jobDir: jobDir, slot: slot, provider: provider, mode: mode)
        }
        running = nil
        await publish()
    }

    /// queued → running (inside one transaction, so a concurrent cancel wins cleanly).
    private func claim(jobPK: Int64, providerID: String, at now: Date) async -> Claimed? {
        do {
            let claimed = try await ctx.db.transaction { db -> Claimed? in
                guard var j = try db.job(pk: jobPK), j.state == .queued else { return nil }
                guard let p = try db.paper(pk: j.paperPK), p.isLive else {
                    j.state = .cancelled
                    j.finishedAt = now
                    try db.updateJob(j)
                    return nil
                }
                j.state = .running
                j.startedAt = now
                j.finishedAt = nil
                j.provider = providerID
                try db.updateJob(j)
                let paper = try db.modifyPaper(pk: p.pk, now: now) {
                    $0.aiState = .running
                    $0.aiNote = nil
                }
                return Claimed(job: j, paper: paper)
            }
            return claimed
        } catch {
            log("claim(job \(jobPK)) failed: \(error)", isError: true)
            return nil
        }
    }

    private func handle(_ outcome: AgentOutcome, job: AgentJob, paper: Paper, prepared: PreparedRequest,
                        settings: EngineSettings, jobDir: URL, slot: Slot, provider: any AgentProvider,
                        mode: AgentMode) async {
        let lang = settings.lang
        let agent = slot.kind ?? settings.selectedProvider
        // Claude runs leave `claude -p` envelopes (cost, tokens) in the job dir; other providers
        // report through RunMeta only, so their files are never parsed as Claude envelopes.
        let costs: URL? = slot == .claude ? jobDir : nil
        log("job \(job.id) (\(provider.id)): \(Self.describe(outcome))")
        switch outcome {
        case .success(let raw, let meta):
            await succeed(raw, meta: meta, job: job, paper: paper, prepared: prepared, settings: settings,
                          jobDir: jobDir, slot: slot, provider: provider)
        case .usageLimit(let resetsAt):
            await usageLimitReached(resetsAt: resetsAt, job: job, costsIn: costs, slot: slot, lang: lang)
        case .notLoggedIn:
            // The provider may know why it refused to spawn (e.g. auth switched to an API key).
            let status = await (provider as? any AgentAuthReporting)?.authRefusalStatus()
                ?? .notLoggedIn(ProviderReason.loggedOut.code)
            applyProviderStatus(status, of: slot)
            await requeue(job, jobDir: costs, paperState: .needsLogin,
                          note: AgentQueueText.needsLoginNote(providerStatus, agent, lang))
        case .binaryMissing:
            applyProviderStatus(.notInstalled, of: slot)
            await requeue(job, jobDir: costs, paperState: .needsLogin,
                          note: AgentQueueText.needsLoginNote(providerStatus, agent, lang))
        case .overloaded:
            await retryOrFail(job, kind: "overloaded", message: nil, costsIn: costs, settings: settings, agent: agent)
        case .invalidOutput(let message):
            await retryOrFail(job, kind: "invalid_output", message: message, costsIn: costs, settings: settings,
                              agent: agent)
        case .maxTurns:
            await retryOrFail(job, kind: "max_turns", message: nil, costsIn: costs, settings: settings, agent: agent)
        case .timeout:
            await retryOrFail(job, kind: "timeout", message: nil, costsIn: costs, settings: settings, agent: agent)
        case .generic(let message):
            await retryOrFail(job, kind: "generic", message: message, costsIn: costs, settings: settings, agent: agent)
        case .cancelled:
            // Not a user cancel or shutdown (those never get here): the spawn gate refused.
            // A mode change (off, or the other provider) or a spent budget is picked up by the
            // next pass; anything else (unexplained refusal) waits 30 s so a misbehaving provider
            // can't spin the loop.
            let modeNow = await ctx.settings().agentMode
            if modeNow != mode || (slot.kind != nil && runBudget.isExhausted) {
                await requeue(job, jobDir: costs)
            } else {
                let retryAt = ctx.now().addingTimeInterval(30)
                await transition(jobPK: job.pk, from: [.running],
                                 job: { $0.state = .queued; $0.startedAt = nil; $0.notBefore = retryAt },
                                 paper: { $0.aiState = .queued; $0.aiNote = nil })
            }
        }
    }

    private func succeed(_ raw: JSONValue, meta: RunMeta, job: AgentJob, paper: Paper, prepared: PreparedRequest,
                         settings: EngineSettings, jobDir: URL, slot: Slot, provider: any AgentProvider) async {
        let agent = slot.kind ?? settings.selectedProvider
        let costs: URL? = slot == .claude ? jobDir : nil
        let card: ReadingCard
        do {
            card = try CardSanitizer.sanitize(raw, pageCount: prepared.pageCount)
        } catch {
            await retryOrFail(job, kind: "invalid_output", message: "sanitizer rejected the card: \(error)",
                              costsIn: costs, settings: settings, agent: agent)
            return
        }
        // A Claude variant-B success leaves variant A's envelope beside it; count its cost too.
        // Codex reports tokens (no cost) in RunMeta only.
        let first = slot == .claude ? await Self.envelopeCosts(in: jobDir, files: ["stdout-A.json"]) : RunCosts()
        let finishedAt = ctx.now()
        let jobPK = job.pk
        let result: CardApplier.Result
        do {
            result = try await CardApplier.apply(card, to: paper.pk, ctx: ctx, settings: settings, onApplied: onApplied,
                                                 within: { db in
                guard var j = try db.job(pk: jobPK), j.state == .running else { throw CardApplier.ApplyError.aborted }
                j.state = .succeeded
                j.finishedAt = finishedAt
                j.notBefore = nil
                j.errorKind = nil
                j.errorMessage = nil
                j.model = meta.model ?? j.model
                j.durationMs = AgentQueue.sum(meta.durationMs, first.durationMs)
                j.costUSD = AgentQueue.sum(j.costUSD, AgentQueue.sum(meta.costUSD, first.cost))
                j.inputTokens = AgentQueue.sum(j.inputTokens, AgentQueue.sum(meta.inputTokens, first.inputTokens))
                j.outputTokens = AgentQueue.sum(j.outputTokens, AgentQueue.sum(meta.outputTokens, first.outputTokens))
                try db.updateJob(j)
            })
        } catch CardApplier.ApplyError.aborted {
            return                                  // cancelled or shut down while the card was on its way
        } catch {
            await retryOrFail(job, kind: "generic", message: "applying the card failed: \(error)",
                              costsIn: costs, settings: settings, agent: agent)
            return
        }
        await Self.removeDirectory(jobDir)
        if slot == .claude, meta.variant == "B" { await persistLearnedVariant(from: provider) }
        let title = result.paper.title
        log("card applied to paper \(result.paper.id) (card v\(result.paper.cardVersion ?? 0), \(provider.id))")
        ctx.events.send(.toast(Toast(id: Self.finishedToastID(paperID: result.paper.id), kind: .success,
                                     message: AgentQueueText.finished(title, mock: provider.id == "mock",
                                                                      agent: agent, settings.lang))))
    }

    /// Pauses only the provider that hit its limit: switching to the other one keeps reading.
    private func usageLimitReached(resetsAt: Date?, job: AgentJob, costsIn costs: URL?, slot: Slot,
                                   lang: UILang) async {
        let now = ctx.now()
        let until = max(resetsAt ?? now.addingTimeInterval(3600), now).addingTimeInterval(120)
        let kind = slot.pauseKind
        await setPause(Pause(until: until, reason: Self.usageLimitReason), for: kind)
        // Attempt unchanged: hitting the limit says nothing about this paper.
        await requeue(job, jobDir: costs, paperState: .limited, note: nil)
        await markQueuedPapers(.limited, note: nil)
        log("usage limit (\(kind.rawValue)) — pausing until \(Database.timestamp(until))")
        ctx.events.send(.toast(Toast(id: Self.usageLimitToastPrefix + Database.timestamp(until), kind: .warning,
                                     message: AgentQueueText.usageLimit(until: until, now: now,
                                                                        calendar: ctx.calendar,
                                                                        agent: kind, lang))))
    }

    private enum FailureClass {
        case overloaded, shrinkable, generic
    }

    private static func failureClass(of kind: String?) -> FailureClass? {
        switch kind {
        case "overloaded": return .overloaded
        case "invalid_output", "max_turns", "timeout": return .shrinkable
        case "generic": return .generic
        default: return nil
        }
    }

    /// Retry policy by failure class; `attempt` counts consecutive failures of the class, and
    /// every failure also counts toward the job's persisted total (`maxTotalFailures`).
    /// `costsIn`: the job dir when it holds Claude envelopes whose cost / tokens count toward the job.
    private func retryOrFail(_ job: AgentJob, kind: String, message: String?, costsIn jobDir: URL?,
                             settings: EngineSettings, agent: AIProviderKind) async {
        let cls = Self.failureClass(of: kind) ?? .generic
        let n = Self.failureClass(of: job.errorKind) == cls ? job.attempt + 1 : 1
        let now = ctx.now()
        let note = AgentQueueText.failureNote(kind: kind, agent: agent, lang: settings.lang)
        let total = await recordFailure(job)
        guard total < Self.maxTotalFailures else {
            log("job \(job.id): \(total) failures in total — giving up")
            await fail(job, kind: kind, message: message, jobDir: jobDir, note: note, attempt: n)
            return
        }
        switch cls {
        case .overloaded:
            guard n <= Self.maxOverloadedRetries else {
                await fail(job, kind: kind, message: message, jobDir: jobDir, note: note, attempt: n)
                return
            }
            let minutes = min(10, pow(2, Double(n - 1))) * Double.random(in: 0.9...1.1)
            await requeueWithBackoff(job, kind: kind, message: message, attempt: n,
                                     notBefore: now.addingTimeInterval(minutes * 60), shrink: nil, jobDir: jobDir)
        case .shrinkable:
            // One retry with half the text and effort low (variant A→B already happened inside the provider).
            guard job.textBudget == nil else {
                await fail(job, kind: kind, message: message, jobDir: jobDir, note: note, attempt: n)
                return
            }
            let budget = max(Self.minTextBudget, settings.textBudget / 2)
            await requeueWithBackoff(job, kind: kind, message: message, attempt: n, notBefore: nil,
                                     shrink: budget, jobDir: jobDir)
        case .generic:
            let delays: [TimeInterval] = [120, 600]
            guard n <= delays.count else {
                await fail(job, kind: kind, message: message, jobDir: jobDir, note: note, attempt: n)
                return
            }
            await requeueWithBackoff(job, kind: kind, message: message, attempt: n,
                                     notBefore: now.addingTimeInterval(delays[n - 1]), shrink: nil, jobDir: jobDir)
        }
    }

    private func requeueWithBackoff(_ job: AgentJob, kind: String, message: String?, attempt: Int, notBefore: Date?,
                                    shrink budget: Int?, jobDir: URL?) async {
        let costs = await jobDir.asyncMap { await Self.envelopeCosts(in: $0) } ?? RunCosts()
        let message = message.map { String($0.prefix(2000)) }
        await transition(jobPK: job.pk, from: [.running],
                         job: { j in
                             j.state = .queued
                             j.startedAt = nil
                             j.attempt = attempt
                             j.notBefore = notBefore
                             j.errorKind = kind
                             j.errorMessage = message
                             if let budget {
                                 j.textBudget = budget
                                 j.effort = "low"
                             }
                             AgentQueue.add(costs, to: &j)
                         },
                         paper: { $0.aiState = .queued; $0.aiNote = nil })
    }

    /// Back to queued without counting an attempt (limit, login, gate refusal).
    private func requeue(_ job: AgentJob, jobDir: URL?, paperState: AIState = .queued, note: String? = nil) async {
        let costs = await jobDir.asyncMap { await Self.envelopeCosts(in: $0) }
        await transition(jobPK: job.pk, from: [.running],
                         job: { j in
                             j.state = .queued
                             j.startedAt = nil
                             if let costs { AgentQueue.add(costs, to: &j) }
                         },
                         paper: { $0.aiState = paperState; $0.aiNote = note })
    }

    /// Terminal failure; the job directory is kept for post-mortems (maintenance prunes it).
    private func fail(_ job: AgentJob, kind: String, message: String?, jobDir: URL?, note: String,
                      attempt: Int? = nil) async {
        let costs = await jobDir.asyncMap { await Self.envelopeCosts(in: $0) }
        let now = ctx.now()
        let message = message.map { String($0.prefix(2000)) }
        await transition(jobPK: job.pk, from: [.running],
                         job: { j in
                             j.state = .failed
                             j.finishedAt = now
                             j.notBefore = nil
                             j.errorKind = kind
                             j.errorMessage = message
                             if let attempt { j.attempt = attempt }
                             if let costs { AgentQueue.add(costs, to: &j) }
                         },
                         paper: { $0.aiState = .failed; $0.aiNote = note })
        log("job \(job.id) failed (\(kind))\(message.map { ": " + $0 } ?? "")", isError: true)
    }

    // MARK: - Request building

    private enum PrepareError: Error, CustomStringConvertible {
        case noText(String)
        var description: String {
            switch self { case .noText(let why): return "no usable paper text (\(why))" }
        }
    }

    private struct BuiltInput: Sendable {
        var stdin: Data
        var pageCount: Int
        var isEmpty: Bool
    }

    private struct CategoryInput: Sendable {
        var name: String
        var description: String?
        var count: Int
    }

    /// The request for `slot`'s provider: Claude (and the mock) use `agentModel` and `jobTimeout`,
    /// Codex `codexModel` and `codexJobTimeout`; both use `agentEffort` (a retry's `low` wins).
    private func prepareRequest(paper: Paper, job: AgentJob, settings: EngineSettings,
                                slot: Slot) async throws -> PreparedRequest {
        let fullText = try await paperText(for: paper)
        let db = ctx.db
        let categories = try await db.categories()
        let counts = try await db.categoryCounts()
        let tags = try await db.frequentTags(limit: CardSchema.maxFrequentTags).map(\.name)
        // A description the model wrote (origin agent) is untrusted until the user acknowledged
        // the category; until then only its name goes back into <library>.
        let catInput = categories.map {
            CategoryInput(name: $0.name, description: $0.origin == .agent && !$0.acknowledged ? nil : $0.description,
                          count: counts[$0.pk] ?? 0)
        }
        let budget = max(Self.minTextBudget, job.textBudget ?? settings.textBudget)
        let metadata = Self.canonicalMetadata(paper)
        let declaredPages = paper.pageCount
        let built = await BlockingIO.run { () -> BuiltInput in
            let pages = fullText.split(separator: "\u{0C}", omittingEmptySubsequences: false).map(String.init)
            let structure = Sections.analyze(pageTexts: pages, outline: nil)
            let prepared = TextPreparer.prepare(pageTexts: pages, structure: structure, budget: budget)
            let pageCount = declaredPages ?? pages.count
            let stdin = CardSchema.stdin(metadata: metadata, pageCount: pageCount,
                                         categories: catInput.map { ($0.name, $0.description, $0.count) },
                                         frequentTags: tags, paperText: prepared.text)
            return BuiltInput(stdin: stdin, pageCount: pageCount,
                              isEmpty: prepared.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        guard !built.isEmpty else { throw PrepareError.noText("empty after preparation") }
        let model = slot == .codex ? settings.codexModel : settings.agentModel
        let timeout = slot == .codex ? tuning.codexJobTimeout : tuning.jobTimeout
        let request = CardRequest(systemPrompt: CardSchema.systemPrompt(for: loadCardProfile()),
                                  schema: CardSchema.schema(categories: categories.map(\.name)), stdin: built.stdin,
                                  model: model, effort: job.effort ?? settings.agentEffort,
                                  timeout: timeout)
        return PreparedRequest(request: request, pageCount: built.pageCount)
    }

    /// Cached text (form feeds between pages); re-extracted from the PDF when missing.
    private func paperText(for paper: Paper) async throws -> String {
        let texts = ctx.texts
        let id = paper.id
        let cached = try? await BlockingIO.run { try texts.load(id: id) }
        if let cached, !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return cached }
        guard !paper.flags.contains(.locked) else { throw PrepareError.noText("the PDF is locked") }
        let extracted: ExtractedPDF
        do {
            extracted = try await PDFExtractor().extract(url: ctx.pdfURL(paper), fileName: paper.originalName)
        } catch {
            throw PrepareError.noText("re-extraction failed: \(error)")
        }
        let full = extracted.fullText
        guard !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PrepareError.noText(extracted.isLocked ? "the PDF is locked" : "the PDF has no text layer")
        }
        do { try await BlockingIO.run { try texts.save(full, id: id) } } catch {
            log("could not re-cache text for \(id): \(error)", isError: true)
        }
        return full
    }

    /// API / user metadata is sent in full; otherwise the model extracts it from page 1.
    private static func canonicalMetadata(_ p: Paper) -> BiblioMetadata? {
        let source: MetaSource
        switch p.metaSource {
        case .crossref, .arxiv, .biorxiv, .openalex, .user: source = p.metaSource
        case .none, .pdf, .agent:
            guard p.metaUserEdited else { return nil }
            source = .user
        }
        return BiblioMetadata(title: p.title, authors: p.authors, year: p.year, venue: p.venue,
                              abstract: p.abstract, ids: p.ids, source: source)
    }

    private static let connectionTestText = """
    [[p. 1]]
    PaperDeck Connection Test: A Synthetic Single-Cell Atlas of Imaginary Tissue
    Abstract
    This synthetic mini-paper exists only to check that PaperDeck can reach its AI reader. We describe a \
    hypothetical single-cell RNA-seq atlas of 12,000 cells from an imaginary tissue, identify five cell \
    populations and report one marker gene per population.
    Introduction
    Cell atlases help compare tissues across conditions. The open question here is purely illustrative: \
    can a short text be summarized into a structured reading card?
    Results
    Fig. 1 shows a UMAP of the five populations. Fig. 2 compares population proportions between two \
    conditions; population C expands from 8% to 15%. Table 1 lists the marker genes.
    Methods
    Reads were aligned with a standard pipeline, cells were clustered with the Leiden algorithm and \
    differential expression used a Wilcoxon test with FDR < 0.05.
    Discussion
    The data are synthetic, so no biological conclusion follows; the only limitation that matters is \
    that nothing here is real.
    """

    private static func connectionTestRequest(model: String, timeout: Duration) -> CardRequest {
        let names = PaperCategory.starters.map(\.name)
        let stdin = CardSchema.stdin(metadata: nil, pageCount: 1,
                                     categories: PaperCategory.starters.map { ($0.name, $0.description, 0) },
                                     frequentTags: [], paperText: connectionTestText)
        return CardRequest(schema: CardSchema.schema(categories: names), stdin: stdin, model: model,
                           effort: "low", timeout: timeout)
    }

    // MARK: - Running one triage job

    /// One triage call on the mode's provider. Same slot, gates and budget as a card; the job
    /// directory (the CLI's raw output about the email) is removed whatever the outcome.
    private func runTriage(slot: Slot, provider: any AgentProvider, mode: AgentMode, settings: EngineSettings) async {
        guard !triageQueue.isEmpty else { return }
        let job = triageQueue.removeFirst()
        consecutiveTriages += 1
        runningTriage = RunningTriage(job: job, since: ctx.now())
        let jobDir = ctx.paths.jobs.appendingPathComponent("triage-" + UUID().uuidString.lowercased(), isDirectory: true)
        await Self.resetDirectory(jobDir)

        // agent.mode is read again right before the spawn (the provider's gate checks it once more).
        let modeNow = await ctx.settings().agentMode
        if runningTriage?.cancelRequested == true || stopping || spawnsClosed || modeNow != mode
            || (slot.kind != nil && runBudget.isExhausted) {
            // The next pass decides: mode off / other provider → held, spent budget → stop.
            if runningTriage?.cancelRequested != true { triageQueue.insert(job, at: 0) }
            runningTriage = nil
            await Self.removeDirectory(jobDir)
            await publish()
            return
        }
        log("triage mail#\(job.messagePK) → \(provider.id) (model \(job.request.model), stdin \(job.request.stdin.count) bytes)")
        let request = job.request
        let task = Task { await provider.generateCard(request, jobDir: jobDir) }
        runningTriage?.task = task
        await publish()                         // the triage lane shows as running ("Analyzing email…")
        var outcome = await task.value
        if case .success(let raw, let meta) = outcome, slot == .claude {
            // A variant-B answer leaves variant A's envelope beside it; its cost counts too.
            let first = await Self.envelopeCosts(in: jobDir, files: ["stdout-A.json"])
            outcome = .success(card: raw, meta: RunMeta(
                model: meta.model, durationMs: Self.sum(meta.durationMs, first.durationMs),
                costUSD: Self.sum(meta.costUSD, first.cost), inputTokens: Self.sum(meta.inputTokens, first.inputTokens),
                outputTokens: Self.sum(meta.outputTokens, first.outputTokens), numTurns: meta.numTurns,
                variant: meta.variant))
            if meta.variant == "B" { await persistLearnedVariant(from: provider) }
        }
        await Self.removeDirectory(jobDir)
        let cancelled = runningTriage?.cancelRequested == true
        runningTriage = nil
        if cancelled {
            log("triage mail#\(job.messagePK): cancelled")
        } else if stopping {
            triageQueue.insert(job, at: 0)
        } else {
            await handleTriage(outcome, job: job, slot: slot, provider: provider, mode: mode, settings: settings)
        }
        await publish()
    }

    private func handleTriage(_ outcome: AgentOutcome, job: MailTriageJob, slot: Slot, provider: any AgentProvider,
                              mode: AgentMode, settings: EngineSettings) async {
        // Outcome kind only: provider messages can quote model output about the email.
        log("triage mail#\(job.messagePK) (\(provider.id)): \(Self.describeTriage(outcome))")
        switch outcome {
        case .usageLimit(let resetsAt):
            // The provider's pause holds both lanes; this job runs first once it is over.
            triageQueue.insert(job, at: 0)
            await triageUsageLimitReached(resetsAt: resetsAt, slot: slot, lang: settings.lang)
        case .notLoggedIn:
            let status = await (provider as? any AgentAuthReporting)?.authRefusalStatus()
                ?? .notLoggedIn(ProviderReason.loggedOut.code)
            applyProviderStatus(status, of: slot)
            triageQueue.insert(job, at: 0)
        case .binaryMissing:
            applyProviderStatus(.notInstalled, of: slot)
            triageQueue.insert(job, at: 0)
        case .cancelled:
            // Not a user cancel or shutdown (those never get here): the spawn gate refused.
            let modeNow = await ctx.settings().agentMode
            if modeNow != mode || (slot.kind != nil && runBudget.isExhausted) {
                triageQueue.insert(job, at: 0)          // the next pass holds it or stops
            } else {
                deliver(job, .cancelled)
            }
        case .success, .invalidOutput, .maxTurns, .timeout, .overloaded, .generic:
            deliver(job, outcome)
        }
    }

    /// Same pause as a card's usage limit (kv `agent.<provider>.pausedUntil`), so both lanes wait.
    private func triageUsageLimitReached(resetsAt: Date?, slot: Slot, lang: UILang) async {
        let now = ctx.now()
        let until = max(resetsAt ?? now.addingTimeInterval(3600), now).addingTimeInterval(120)
        let kind = slot.pauseKind
        await setPause(Pause(until: until, reason: Self.usageLimitReason), for: kind)
        await markQueuedPapers(.limited, note: nil)
        log("usage limit (\(kind.rawValue)) during mail triage — pausing until \(Database.timestamp(until))")
        ctx.events.send(.toast(Toast(id: Self.usageLimitToastPrefix + Database.timestamp(until), kind: .warning,
                                     message: AgentQueueText.usageLimit(until: until, now: now,
                                                                        calendar: ctx.calendar,
                                                                        agent: kind, lang))))
    }

    /// Queued triage jobs that may not run under the current mode (off, or it names another
    /// provider) leave the lane: one `WOULD RUN` line each, then the handler gets `.cancelled`.
    private func dropUnroutableTriage(settings: EngineSettings) async {
        guard !triageQueue.isEmpty else { return }
        var dropped: [(MailTriageJob, MailTriageRoute)] = []
        triageQueue.removeAll { job in
            let route = MailTriageRoute.of(provider: job.provider, settings: settings)
            if case .run = route { return false }
            dropped.append((job, route))
            return true
        }
        for (job, route) in dropped {
            log("WOULD RUN " + (await triageWouldRunSummary(job, route: route, settings: settings)))
            deliver(job, .cancelled)
        }
        if !dropped.isEmpty { await publish() }
    }

    /// What enabling the job's provider would run (its dry run when it has one). Never the stdin.
    private func triageWouldRunSummary(_ job: MailTriageJob, route: MailTriageRoute,
                                       settings: EngineSettings) async -> String {
        let kind: AIProviderKind
        let why: String
        switch route {
        case .modeOff(let wanted):
            kind = wanted; why = "agent.mode off"
        case .providerNotActive(let wanted, let mode):
            kind = wanted; why = "agent.mode \(mode.rawValue) does not run \(wanted.rawValue)"
        case .run(let k):
            kind = k ?? settings.selectedProvider; why = "runnable"
        }
        let head = "triage mail#\(job.messagePK) (\(why))"
        let provider = provider(for: Slot(kind))
        let r = job.request
        if let dry = provider as? any AgentDryRunning {
            return head + " · " + (await dry.dryRunSummary(r))
        }
        return head + " · provider \(provider.id) model \(r.model) effort \(r.effort) stdin: \(r.stdin.count) bytes"
    }

    /// Hands a result to the handler: serialized in order, never on the queue's slot.
    private func deliver(_ job: MailTriageJob, _ outcome: AgentOutcome) {
        guard let handler = triageHandler else {
            log("triage mail#\(job.messagePK): no triage handler — result dropped")
            return
        }
        let previous = deliveryTail
        deliveryTail = Task.detached {
            await previous?.value
            await handler(job, outcome)
        }
    }

    /// Waits (at most `timeout`) for handler calls still in flight.
    private func drainTriageDeliveries(timeout: Duration) async {
        guard let tail = deliveryTail else { return }
        let id = nextWaiterID
        nextWaiterID += 1
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            deliveryWaiters[id] = cont
            Task { [weak self] in
                await tail.value
                await self?.resumeDeliveryWaiter(id)
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.resumeDeliveryWaiter(id)
            }
        }
    }

    private func resumeDeliveryWaiter(_ id: Int) {
        deliveryWaiters.removeValue(forKey: id)?.resume()
    }

    private static func describeTriage(_ o: AgentOutcome) -> String {
        switch o {
        case .success(_, let meta):
            let cost = meta.costUSD.map { String(format: "$%.4f", $0) } ?? "?"
            return "success (model \(meta.model ?? "?"), \(meta.durationMs ?? 0) ms, cost \(cost), variant \(meta.variant ?? "-"))"
        case .usageLimit(let at): return "usage limit (resets \(at.map(Database.timestamp) ?? "unknown"))"
        case .notLoggedIn: return "not logged in"
        case .overloaded: return "overloaded"
        case .invalidOutput: return "invalid output"
        case .maxTurns: return "max turns"
        case .timeout: return "timeout"
        case .binaryMissing: return "binary missing"
        case .cancelled: return "cancelled"
        case .generic: return "error"
        }
    }

    // MARK: - Mode off

    private func holdQueuedJobsForModeOff(settings: EngineSettings) async {
        guard let queued = try? await ctx.db.jobs(states: [.queued]), !queued.isEmpty else { return }
        for job in queued where wouldRunLogged.insert(job.id).inserted {
            let summary = await wouldRunSummary(job, settings: settings)
            log("WOULD RUN \(summary)")
        }
        await transitionAll(jobPKs: queued.map(\.pk), from: [.queued],
                            job: { $0.state = .held; $0.errorKind = AgentQueue.modeOffNote },
                            paper: { $0.aiState = .held; $0.aiNote = AgentQueue.modeOffNote })
    }

    /// What enabling the chosen provider would run for `job` (its dry run when it has one).
    private func wouldRunSummary(_ job: AgentJob, settings: EngineSettings) async -> String {
        let head = "job \(job.id) paper#\(job.paperPK)"
        guard let paper = try? await ctx.db.paper(pk: job.paperPK) else { return head + " · paper missing" }
        let slot = Slot(settings.selectedProvider)
        let provider = provider(for: slot)
        do {
            let r = try await prepareRequest(paper: paper, job: job, settings: settings, slot: slot).request
            if let dry = provider as? any AgentDryRunning {
                return head + " · " + (await dry.dryRunSummary(r))
            }
            return head + " · provider \(provider.id) model \(r.model) effort \(r.effort) stdin: \(r.stdin.count) bytes"
        } catch {
            return head + " · request unavailable: \(error)"
        }
    }

    // MARK: - Provider state

    private func detect(_ slot: Slot) async {
        let clock = ContinuousClock()
        if !forceDetect, detectedSlot == slot, let last = lastDetect,
           last.duration(to: clock.now) < tuning.detectThrottle {
            detectRequested = false
            return
        }
        forceDetect = false
        detectRequested = false
        if detectedSlot != slot {
            // Another provider now: never show the previous one's login state under its name.
            detectedSlot = slot
            providerStatus = .unknown
            providerReady = false
            notReadySince = nil
            await publish()
        }
        let status = await provider(for: slot).detect()
        lastDetect = clock.now
        applyProviderStatus(status, of: slot)
    }

    private func applyProviderStatus(_ status: ProviderStatus, of slot: Slot) {
        if detectedSlot != slot {
            detectedSlot = slot
            notReadySince = nil
        }
        switch status {
        case .ready(let plan, let version, _):
            providerStatus = .ready(plan: plan, version: version)
            providerReady = true
        case .notInstalled:
            providerStatus = .notInstalled
            providerReady = false
        case .notLoggedIn(let why):
            providerStatus = .notLoggedIn(why)
            providerReady = false
        case .unsupported(let why):
            providerStatus = .unsupported(why)
            providerReady = false
        }
    }

    // MARK: - Pauses (kv agent.<claude|codex>.pausedUntil / pauseReason)

    private func loadPauses() async {
        pauses = [:]
        for kind in AIProviderKind.allCases {
            guard let raw = try? await ctx.db.kv(Self.pausedUntilKey(for: kind)),
                  let until = Database.date(fromTimestamp: raw) else { continue }
            let reason = (try? await ctx.db.kv(Self.pauseReasonKey(for: kind))) ?? Self.usageLimitReason
            pauses[kind] = Pause(until: until, reason: reason)
        }
    }

    /// Both keys change in one transaction, so a reader never sees an until without its reason.
    private func setPause(_ p: Pause, for kind: AIProviderKind) async {
        pauses[kind] = p
        let untilKey = Self.pausedUntilKey(for: kind), reasonKey = Self.pauseReasonKey(for: kind)
        let until = Database.timestamp(p.until), reason = p.reason
        do {
            try await ctx.db.transaction { db in
                try db.setKV(reasonKey, reason)
                try db.setKV(untilKey, until)
            }
        } catch {
            log("cannot persist the pause: \(error)", isError: true)
        }
    }

    /// The usage-limit pause of `kind` in force at `now` (nil: none). Synchronous: the assist gate
    /// reads it before every turn; card jobs, triage and assist share each provider's pause.
    package nonisolated func pause(for kind: AIProviderKind, now: Date = Date()) -> Date? {
        pauseMirror.until(kind).flatMap { $0 > now ? $0 : nil }
    }

    /// An assist turn hit `kind`'s usage limit: the same pause a card's limit sets (kv
    /// `agent.<provider>.pausedUntil`), so the card queue waits too. No toast: the assist surface
    /// shows its own banner.
    package func recordUsageLimit(kind: AIProviderKind, resetsAt: Date?) async {
        let now = ctx.now()
        let until = max(resetsAt ?? now.addingTimeInterval(3600), now).addingTimeInterval(120)
        if let current = pauses[kind], current.until >= until { return }
        await setPause(Pause(until: until, reason: Self.usageLimitReason), for: kind)
        log("usage limit (\(kind.rawValue)) during an assist turn — pausing until \(Database.timestamp(until))")
        poke()
    }

    private func clearPause(_ kind: AIProviderKind) async {
        pauses[kind] = nil
        let untilKey = Self.pausedUntilKey(for: kind), reasonKey = Self.pauseReasonKey(for: kind)
        try? await ctx.db.transaction { db in
            try db.removeKV(untilKey)
            try db.removeKV(reasonKey)
        }
        log("pause over (\(kind.rawValue)) — resuming")
    }

    // MARK: - Learned argv variant (CLIFactStore / UserDefaults)

    private func restoreLearnedVariant() async {
        await migrateVariantFromLibraryKV()
        guard let learner = claude as? any AgentVariantLearning,
              let variant = cliFacts.string(forKey: Self.variantKey) else { return }
        let version = cliFacts.string(forKey: Self.variantCLIVersionKey)
        await learner.restoreLearnedVariant(variant, cliVersion: version)
    }

    /// Older builds stored the variant in the library kv; move it to the CLI facts once.
    private func migrateVariantFromLibraryKV() async {
        guard let stored = try? await ctx.db.kv(Self.variantKey) else { return }
        if cliFacts.string(forKey: Self.variantKey) == nil {
            cliFacts.set(stored, forKey: Self.variantKey)
            cliFacts.set(try? await ctx.db.kv(Self.variantCLIVersionKey), forKey: Self.variantCLIVersionKey)
            log("moved the learned argv variant \(stored) from the library to UserDefaults")
        }
        try? await ctx.db.removeKV(Self.variantKey)
        try? await ctx.db.removeKV(Self.variantCLIVersionKey)
    }

    private func persistLearnedVariant(from provider: any AgentProvider) async {
        guard let learner = provider as? any AgentVariantLearning else { return }
        let learned = await learner.learnedVariantForPersistence()
        cliFacts.set(learned.variant, forKey: Self.variantKey)
        cliFacts.set(learned.cliVersion, forKey: Self.variantCLIVersionKey)
        log("learned argv variant \(learned.variant) for CLI \(learned.cliVersion ?? "?")")
    }

    // MARK: - Failure totals (kv agent.failureTotals)

    /// Adds one failure to the job's persisted total and returns it. Entries of jobs that are no
    /// longer active are pruned on the way.
    private func recordFailure(_ job: AgentJob) async -> Int {
        let id = job.id
        do {
            return try await ctx.db.transaction { db -> Int in
                var total = 0
                try AgentQueue.updateFailureTotals(db) { totals in
                    total = (totals[id] ?? 0) + 1
                    totals[id] = total
                }
                return total
            }
        } catch {
            log("cannot record the failure count of job \(id): \(error)", isError: true)
            return 1
        }
    }

    /// Read-modify-write of the totals map inside the caller's transaction; drops entries whose
    /// job is gone or no longer held/queued/running.
    static func updateFailureTotals(_ db: isolated Database, _ change: (inout [String: Int]) -> Void) throws {
        let raw = try db.kv(failureTotalsKey)
        var totals = raw.flatMap { try? JSONDecoder().decode([String: Int].self, from: Data($0.utf8)) } ?? [:]
        let before = totals
        change(&totals)
        for id in Array(totals.keys) {
            if let j = try db.job(id: id), [.held, .queued, .running].contains(j.state) { continue }
            totals[id] = nil
        }
        guard totals != before else { return }
        if totals.isEmpty {
            try db.removeKV(failureTotalsKey)
        } else {
            let enc = JSONEncoder()
            enc.outputFormatting = .sortedKeys
            try db.setKV(failureTotalsKey, String(decoding: try enc.encode(totals), as: UTF8.self))
        }
    }

    // MARK: - Waiting papers without a job (rebuild, adoption, older builds)

    /// A paper whose ai_state says it waits for the agent but that has no active job would stay
    /// stuck forever; give it back the job it lost (see `recreateLostJob`).
    private func reconcileWaitingPapers() async {
        let now = ctx.now()
        let providerID = pendingProviderID(ctx.loadSettings())
        do {
            // Cheap pre-filter outside the write transaction; each candidate is re-read inside it.
            let candidates = try await ctx.db.allPapers().filter { AgentQueue.waitingStates.contains($0.aiState) }.map(\.pk)
            guard !candidates.isEmpty else { return }
            let fixed = try await ctx.db.transaction { db -> [Int64] in
                var fixed: [Int64] = []
                for pk in candidates {
                    guard let p = try db.paper(pk: pk) else { continue }
                    if try AgentQueue.recreateLostJob(for: p, db: db, providerID: providerID, now: now) {
                        fixed.append(p.pk)
                    }
                }
                return fixed
            }
            if !fixed.isEmpty { log("gave \(fixed.count) waiting paper(s) their lost job back") }
            for pk in fixed { await ctx.syncSidecar(pk: pk) }
        } catch {
            log("reconciling waiting papers failed: \(error)", isError: true)
        }
    }

    /// ai_state values that mean "an active job exists for this paper".
    package static let waitingStates: Set<AIState> = [.held, .queued, .running, .limited, .needsLogin]

    /// For a paper in a waiting ai_state without an active job: held → a held job (a mode-off
    /// hold keeps `mode_off`, a batch hold still awaits confirmation); queued / limited /
    /// needs_login → a queued job (the queue re-derives the badge); running (a crash mid-run) →
    /// queued. Nothing is spawned here; `agent.mode` still gates every run. Returns true when a
    /// job was created (the paper row may have changed too).
    @discardableResult
    package static func recreateLostJob(for paper: Paper, db: isolated Database, providerID: String,
                                        now: Date) throws -> Bool {
        guard waitingStates.contains(paper.aiState), try db.activeJob(paperPK: paper.pk) == nil else { return false }
        let hold = paper.aiState == .held
        try db.insertJob(AgentJob(paperPK: paper.pk, provider: providerID, state: hold ? .held : .queued,
                                  errorKind: hold && paper.aiNote == modeOffNote ? modeOffNote : nil,
                                  createdAt: now))
        if paper.aiState == .running {
            var p = paper
            p.aiState = .queued
            p.aiNote = nil
            _ = try db.updatePaper(p, now: paper.updatedAt)
        }
        return true
    }

    // MARK: - DB transitions

    /// Changes one job (only if it is still in `states`) and its paper atomically, then syncs card.json.
    @discardableResult
    private func transition(jobPK: Int64, from states: Set<AgentJobState>,
                            job jobChange: @escaping @Sendable (inout AgentJob) -> Void,
                            paper paperChange: @escaping @Sendable (inout Paper) -> Void) async -> AgentJob? {
        let now = ctx.now()
        do {
            let updated = try await ctx.db.transaction { db -> AgentJob? in
                guard var j = try db.job(pk: jobPK), states.contains(j.state) else { return nil }
                jobChange(&j)
                try db.updateJob(j)
                if try db.paper(pk: j.paperPK) != nil {
                    try db.modifyPaper(pk: j.paperPK, now: now) { paperChange(&$0) }
                }
                return j
            }
            if let updated { await ctx.syncSidecar(pk: updated.paperPK) }
            return updated
        } catch {
            log("job \(jobPK): state change failed: \(error)", isError: true)
            return nil
        }
    }

    /// Batch form of `transition` (one transaction).
    private func transitionAll(jobPKs: [Int64], from states: Set<AgentJobState>,
                               job jobChange: @escaping @Sendable (inout AgentJob) -> Void,
                               paper paperChange: @escaping @Sendable (inout Paper) -> Void) async {
        guard !jobPKs.isEmpty else { return }
        let now = ctx.now()
        do {
            let papers = try await ctx.db.transaction { db -> [Int64] in
                var touched: [Int64] = []
                for pk in jobPKs {
                    guard var j = try db.job(pk: pk), states.contains(j.state) else { continue }
                    jobChange(&j)
                    try db.updateJob(j)
                    if try db.paper(pk: j.paperPK) != nil {
                        try db.modifyPaper(pk: j.paperPK, now: now) { paperChange(&$0) }
                        touched.append(j.paperPK)
                    }
                }
                return touched
            }
            for pk in papers { await ctx.syncSidecar(pk: pk) }
        } catch {
            log("batch job state change failed: \(error)", isError: true)
        }
    }

    /// Keeps the badge of every waiting paper in line with the queue condition
    /// (queued / limited / needs_login). Writes only rows that differ.
    private func markQueuedPapers(_ state: AIState, note: String?) async {
        let db = ctx.db
        guard let queued = try? await db.jobs(states: [.queued]), !queued.isEmpty,
              let papers = try? await db.papers(pks: queued.map(\.paperPK)) else { return }
        let stale = papers.filter { $0.aiState != state || $0.aiNote != note }.map(\.pk)
        guard !stale.isEmpty else { return }
        let now = ctx.now()
        do {
            let changed = try await db.transaction { db -> [Int64] in
                var changed: [Int64] = []
                for pk in stale {
                    // Re-check inside the transaction: the job may have started or been cancelled.
                    guard let j = try db.activeJob(paperPK: pk), j.state == .queued else { continue }
                    try db.modifyPaper(pk: pk, now: now) { $0.aiState = state; $0.aiNote = note }
                    changed.append(pk)
                }
                return changed
            }
            for pk in changed { await ctx.syncSidecar(pk: pk) }
        } catch {
            log("markQueuedPapers(\(state.rawValue)) failed: \(error)", isError: true)
        }
    }

    // MARK: - Status

    private func currentStatus() async -> AgentQueueStatus {
        let queued = (try? await ctx.db.jobs(states: [.queued]).count) ?? 0
        let held = (try? await ctx.db.jobs(states: [.held]).count) ?? 0
        let settings = ctx.loadSettings()
        // `providerStatus` belongs to `detectedSlot` (before any detection: the one it will describe).
        let slot = detectedSlot ?? Self.describedSlot(settings)
        let pause = pauses[slot.pauseKind]
        return AgentQueueStatus(provider: providerStatus, providerKind: slot.kind ?? settings.selectedProvider,
                                mode: settings.agentMode, runningPaperID: running?.paperID,
                                runningSince: running?.since, queued: queued, held: held,
                                pausedUntil: pause?.until, pauseReason: pause?.reason,
                                triageQueued: triageQueue.count,
                                runningTriageMessagePK: runningTriage?.task == nil ? nil : runningTriage?.job.messagePK,
                                triageRunningSince: runningTriage?.task == nil ? nil : runningTriage?.since)
    }

    /// Emits `EngineEvent.agentStatus` when anything visible changed.
    private func publish() async {
        let s = await currentStatus()
        guard s != lastPublished else { return }
        lastPublished = s
        ctx.events.send(.agentStatus(s))
    }

    // MARK: - Sleeping, waking, exclusivity

    /// Sleeps for `duration` or until `poke()` / `wake()` / shutdown, whichever comes first.
    private func nap(_ duration: Duration) async {
        if wakePending || stopping {
            wakePending = false
            return
        }
        napToken &+= 1
        let token = napToken
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            napContinuation = cont
            napTimer = Task { [weak self] in
                try? await Task.sleep(for: duration)
                await self?.endNap(token)
            }
        }
    }

    private func endNap(_ token: Int) {
        guard token == napToken, let c = napContinuation else { return }
        napContinuation = nil
        napTimer = nil
        c.resume()
    }

    /// Interrupts the loop's nap (or makes the next one return at once).
    private func poke() {
        if let c = napContinuation {
            napContinuation = nil
            napTimer?.cancel()
            napTimer = nil
            c.resume()
        } else {
            wakePending = true
        }
    }

    /// One agent run at a time: the loop holds the slot while it works, a connection test waits for it.
    private func acquireSlot() async {
        guard slotBusy else {
            slotBusy = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in slotWaiters.append(cont) }
    }

    private func releaseSlot() {
        if slotWaiters.isEmpty { slotBusy = false } else { slotWaiters.removeFirst().resume() }
    }

    private func waitForLoopExit(timeout: Duration) async {
        guard loopRunning else { return }
        let id = nextWaiterID
        nextWaiterID += 1
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            exitWaiters[id] = cont
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.resumeExitWaiter(id)
            }
        }
    }

    private func resumeExitWaiter(_ id: Int) {
        exitWaiters.removeValue(forKey: id)?.resume()
    }

    private func loopDidExit() {
        loopRunning = false
        loopTask = nil
        let waiters = exitWaiters.values
        exitWaiters.removeAll()
        for c in waiters { c.resume() }
    }

    // MARK: - Helpers

    private func log(_ message: String, isError: Bool = false) {
        if isError {
            Log.agent.error("\(message, privacy: .public)")
        } else {
            Log.agent.notice("\(message, privacy: .public)")
        }
        logObserver?(message)
    }

    /// Time to `until` on the injected clock, at least 1 ms and at most `cap`.
    private static func napDuration(until: Date, now: Date, cap: Duration) -> Duration {
        let seconds = max(0.001, until.timeIntervalSince(now))
        let d = Duration.milliseconds(Int64(min(seconds, 86_400 * 365) * 1000))
        return min(d, cap)
    }

    package static func finishedToastID(paperID: String) -> String { finishedToastPrefix + paperID }
    /// `Toast.id` of 「Claude 已读完：…」 is this prefix + paper id (the app decides whether to notify).
    package static let finishedToastPrefix = "agent.finished."
    /// `Toast.id` of the one-per-event 「Claude 额度已用尽 · HH:MM 自动继续」 toast.
    package static let usageLimitToastPrefix = "agent.usage-limit."

    package static func paperID(fromFinishedToastID id: String) -> String? {
        id.hasPrefix(finishedToastPrefix) ? String(id.dropFirst(finishedToastPrefix.count)) : nil
    }

    private static func describe(_ o: AgentOutcome) -> String {
        switch o {
        case .success(_, let meta):
            let cost = meta.costUSD.map { String(format: "$%.4f", $0) } ?? "?"
            return "success (model \(meta.model ?? "?"), \(meta.durationMs ?? 0) ms, cost \(cost), variant \(meta.variant ?? "-"))"
        case .usageLimit(let at): return "usage limit (resets \(at.map(Database.timestamp) ?? "unknown"))"
        case .notLoggedIn: return "not logged in"
        case .overloaded: return "overloaded"
        case .invalidOutput(let m): return "invalid output: \(m)"
        case .maxTurns: return "max turns"
        case .timeout: return "timeout"
        case .binaryMissing: return "binary missing"
        case .cancelled: return "cancelled"
        case .generic(let m): return "error: \(m)"
        }
    }

    // Costs / tokens recorded from the envelopes a real run left in its job directory.
    private struct RunCosts: Sendable {
        var cost: Double?
        var inputTokens: Int?
        var outputTokens: Int?
        var model: String?
        var durationMs: Int?
    }

    private static func envelopeCosts(in dir: URL, files: [String] = ["stdout-A.json", "stdout.json"]) async -> RunCosts {
        await BlockingIO.run {
            var out = RunCosts()
            for name in files {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                      let env = ClaudeEnvelope.parse(data) else { continue }
                out.cost = sum(out.cost, env.totalCostUSD)
                out.inputTokens = sum(out.inputTokens, env.inputTokens)
                out.outputTokens = sum(out.outputTokens, env.outputTokens)
                out.durationMs = sum(out.durationMs, env.durationMs)
                out.model = env.model ?? out.model
            }
            return out
        }
    }

    private static func add(_ c: RunCosts, to j: inout AgentJob) {
        j.costUSD = sum(j.costUSD, c.cost)
        j.inputTokens = sum(j.inputTokens, c.inputTokens)
        j.outputTokens = sum(j.outputTokens, c.outputTokens)
        if let d = c.durationMs { j.durationMs = d }
        if let m = c.model { j.model = m }
    }

    fileprivate static func sum<T: AdditiveArithmetic>(_ a: T?, _ b: T?) -> T? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let x?, nil): return x
        case (nil, let y?): return y
        case (let x?, let y?): return x + y
        }
    }

    /// Empties the job directory before a spawn, so costs are never read from a stale attempt.
    private static func resetDirectory(_ dir: URL) async {
        await BlockingIO.run {
            let fm = FileManager.default
            try? fm.removeItem(at: dir)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private static func removeDirectory(_ dir: URL) async {
        await BlockingIO.run { try? FileManager.default.removeItem(at: dir) }
    }
}

private extension Optional {
    func asyncMap<U: Sendable>(_ f: (Wrapped) async -> U) async -> U? {
        guard let w = self else { return nil }
        return await f(w)
    }
}

/// zh/en strings the queue produces (toasts, ai_note reasons), named after the provider
/// (「Claude 已读完：…」 / 「ChatGPT 已读完：…」).
private enum AgentQueueText {
    static func finished(_ title: String, mock: Bool, agent: AIProviderKind, _ lang: UILang) -> String {
        let t = title.count > 60 ? String(title.prefix(59)) + "…" : title
        let name = agent.shortName
        switch lang {
        case .zh: return (mock ? "MOCK 卡片已生成：" : "\(name) 已读完：") + t
        case .en: return (mock ? "MOCK card ready: " : "\(name) finished reading: ") + t
        }
    }

    static func usageLimit(until: Date, now: Date, calendar: Calendar, agent: AIProviderKind, _ lang: UILang) -> String {
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: until)
        let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        let when = calendar.isDate(until, inSameDayAs: now) ? time : "\(c.month ?? 0)/\(c.day ?? 0) \(time)"
        let name = agent.shortName
        switch lang {
        case .zh: return "\(name) 额度已用尽 · \(when) 自动继续"
        case .en: return "\(name) usage limit reached · resumes at \(when)"
        }
    }

    static func failureNote(kind: String, agent: AIProviderKind, lang: UILang) -> String {
        let zh = lang == .zh
        switch kind {
        case "invalid_output": return zh ? "输出无效" : "Invalid output"
        case "max_turns": return zh ? "超出轮次上限" : "Too many turns"
        case "timeout": return zh ? "超时" : "Timed out"
        case "overloaded": return zh ? "\(agent.shortName) 服务繁忙" : "\(agent.shortName) is overloaded"
        case "no_text": return zh ? "没有可用文本" : "No usable text"
        default: return zh ? "解读出错" : "Reading failed"
        }
    }

    /// ai_note of papers waiting because the provider is unusable, e.g. 「需登录 Claude」 or
    /// 「PaperDeck 只使用订阅登录（当前：api_key）」 (`AgentQueueStatus.Provider.reasonText`).
    static func needsLoginNote(_ status: AgentQueueStatus.Provider, _ agent: AIProviderKind, _ lang: UILang) -> String {
        switch status {
        case .notInstalled, .notLoggedIn, .unsupported: return status.reasonText(lang, provider: agent)
        default: return ProviderReason.loggedOut.text(lang, loginProblem: true, provider: agent)
        }
    }
}

/// The queue's pauses for synchronous readers (`AgentQueue.pause(for:)`).
private final class PauseMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var untils: [AIProviderKind: Date] = [:]
    func set(_ u: [AIProviderKind: Date]) { lock.withLock { untils = u } }
    func until(_ kind: AIProviderKind) -> Date? { lock.withLock { untils[kind] } }
}
