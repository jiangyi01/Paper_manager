import Foundation

/// The window-free core: owns the database, stores and pipelines. The app, the
/// CLI self-tests and unit tests all drive the library through this façade.
package final class Engine: Sendable {
    package let ctx: EngineContext
    package let intake: IntakeActor
    package let enrich: EnrichActor
    package let agents: AgentQueue
    package let gate: HostGate
    /// Mail capture: accounts, sync cadence, `.eml` import, post-processing (MAIL_DESIGN Part A §2).
    package let mail: MailSyncActor
    /// Mail AI triage decisions, the daily cap and result handling (AgentQueue triage lane).
    package let mailTriage: MailTriageCoordinator
    /// Fresh Settings ▸ Mail snapshot (UserDefaults in the app, re-read on every use).
    package let loadMailSettings: @Sendable () -> MailSettings
    /// Interactive AI (Explain, Q&A, the duplicate judge): one generating turn at a time, behind
    /// `assistGate` (READING_ASSIST_PLAN §3.2). Backends: `AssistBackendFactory.builtIn` (mock, the real
    /// Claude / Codex providers, on-device) unless `Dependencies.assistBackends` injects a set.
    package let assist: AssistLane
    /// The gate every assist turn passes; shares `runBudget` and the providers' pauses with the queue.
    package let assistGate: AssistGate
    /// Automatic duplicate-judge turns per day (`dedupe.ai.count.<day>`, `dedupe.ai.dailyCap`).
    package let dedupeJudgeCounter: AssistDailyCounter
    /// Paper Q&A (Slice C; a Slice 0 stub that already runs through `assist`).
    package let qa: QAService
    /// Papers opened from PaperDeck recently (Explain's paper locator).
    package let recentOpens = RecentOpens()
    /// The reader the assist prompts are written for (the card profile's `reader`, re-read per request).
    package let loadAssistReader: @Sendable () -> String
    /// Real CLI spawns allowed — `claude -p` and `codex exec` together (CLI `--max-runs N` →
    /// `runBudget.setLimit(N)`; unlimited by default).
    package var runBudget: RunBudget { agents.runBudget }

    package var db: Database { ctx.db }
    package var paths: AppPaths { ctx.paths }
    package var changes: ChangeHub { ctx.db.changes }
    package var events: EventHub<EngineEvent> { ctx.events }

    /// Dependencies that tests/CLI replace.
    package struct Dependencies: Sendable {
        package var loadSettings: @Sendable () -> EngineSettings
        package var now: @Sendable () -> Date
        /// `Calendar.autoupdatingCurrent` by default: follows time-zone changes (travel).
        package var calendar: Calendar
        package var fetcher: (any HTTPFetching)?          // nil → metadata lookup disabled
        package var claude: (any AgentProvider)?          // nil → a ClaudeCodeProvider is built
        package var codex: (any AgentProvider)?           // nil → a CodexProvider is built
        package var mock: any AgentProvider
        package var sidecarDelay: Duration
        /// Machine-wide CLI facts (learned argv variant, §3.1): UserDefaults.standard in the app.
        package var cliFacts: CLIFactStore
        /// Settings ▸ Mail (UserDefaults in the app; the SettingsStore writes the same keys).
        package var loadMailSettings: @Sendable () -> MailSettings
        /// IMAP app passwords: nil → the login-keychain store (`KeychainMailSecretStore`).
        package var mailSecrets: (any MailSecretStore)?
        /// Transport per account: nil → `MailSourceFactory` (folder / IMAP). Tests inject fakes.
        package var mailSources: (@Sendable (MailAccount) -> any MailSource)?
        /// First-page reader of stored mail PDFs: nil → PDFKit (`PDFExtractor`).
        package var mailPDFExtractor: (any PDFExtracting)?
        /// Metadata traffic cop: nil → a fresh `HostGate` (tests pass a virtual clock).
        package var hostGate: HostGate?
        /// The reader the reading-card prompt is written for (`CardSchema.systemPrompt(for:)`),
        /// re-read for every card request: the app resolves it from the user's profile.
        package var loadCardProfile: @Sendable () -> CardPromptProfile
        /// Assist backends by mode: nil → the built-in set (`AssistBackendFactory.builtIn`: the mock,
        /// Claude / Codex only for the real providers, on-device). Tests inject scripted ones.
        package var assistBackends: [any AssistBackend]?

        package init(loadSettings: @escaping @Sendable () -> EngineSettings = { EngineSettings.load() },
                     now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent,
                     fetcher: (any HTTPFetching)? = URLSessionHTTPFetcher(), claude: (any AgentProvider)? = nil,
                     codex: (any AgentProvider)? = nil,
                     mock: any AgentProvider = MockAgentProvider(), sidecarDelay: Duration = .seconds(1),
                     cliFacts: CLIFactStore = .standard,
                     loadMailSettings: @escaping @Sendable () -> MailSettings = { MailSettings.load() },
                     mailSecrets: (any MailSecretStore)? = nil,
                     mailSources: (@Sendable (MailAccount) -> any MailSource)? = nil,
                     mailPDFExtractor: (any PDFExtracting)? = nil, hostGate: HostGate? = nil,
                     loadCardProfile: @escaping @Sendable () -> CardPromptProfile = { .legacyCompBio },
                     assistBackends: [any AssistBackend]? = nil) {
            self.loadSettings = loadSettings; self.now = now; self.calendar = calendar; self.fetcher = fetcher
            self.claude = claude; self.codex = codex; self.mock = mock; self.sidecarDelay = sidecarDelay
            self.cliFacts = cliFacts; self.loadMailSettings = loadMailSettings; self.mailSecrets = mailSecrets
            self.mailSources = mailSources; self.mailPDFExtractor = mailPDFExtractor; self.hostGate = hostGate
            self.loadCardProfile = loadCardProfile; self.assistBackends = assistBackends
        }
    }

    /// The locator of the built-in ClaudeCodeProvider (nil when `Dependencies.claude` was injected).
    package let binaryLocator: BinaryLocator?
    /// The locator of the built-in CodexProvider (nil when `Dependencies.codex` was injected).
    package let codexLocator: CodexLocator?

    private init(ctx: EngineContext, intake: IntakeActor, enrich: EnrichActor, agents: AgentQueue, gate: HostGate,
                 mail: MailSyncActor, mailTriage: MailTriageCoordinator,
                 loadMailSettings: @escaping @Sendable () -> MailSettings,
                 binaryLocator: BinaryLocator?, codexLocator: CodexLocator?,
                 assist: AssistLane, assistGate: AssistGate, dedupeJudgeCounter: AssistDailyCounter,
                 qa: QAService, loadAssistReader: @escaping @Sendable () -> String) {
        self.ctx = ctx; self.intake = intake; self.enrich = enrich; self.agents = agents; self.gate = gate
        self.mail = mail; self.mailTriage = mailTriage; self.loadMailSettings = loadMailSettings
        self.binaryLocator = binaryLocator; self.codexLocator = codexLocator
        self.assist = assist; self.assistGate = assistGate; self.dedupeJudgeCounter = dedupeJudgeCounter
        self.qa = qa; self.loadAssistReader = loadAssistReader
    }

    /// Opens (creating/migrating) the library at `paths`. Throws LibraryError when
    /// the library root is unusable so the app can offer the ~/Papers fallback.
    package static func open(paths: AppPaths, deps: Dependencies = Dependencies()) async throws -> Engine {
        try LibraryPaths.ensureLayout(paths: paths)
        let db: Database
        do {
            db = try await Database.open(url: paths.database, backupsDir: paths.backups)
        } catch DatabaseError.corrupt(let why) {
            Log.db.error("database corrupt (\(why, privacy: .public)); moving aside and rebuilding")
            _ = try Database.moveAsideCorrupt(url: paths.database, backupsDir: paths.backups)
            db = try await Database.open(url: paths.database, backupsDir: paths.backups)
            // Maintenance.rebuildFromSidecars runs in start() when the DB is empty but folders exist.
        }
        let ctx = EngineContext(paths: paths, db: db, sidecars: SidecarWriter(paths: paths, delay: deps.sidecarDelay),
                                texts: TextStore(paths: paths), thumbs: ThumbnailStore(paths: paths),
                                events: EventHub<EngineEvent>(), loadSettings: deps.loadSettings,
                                now: deps.now, calendar: deps.calendar)
        let gate = deps.hostGate ?? HostGate()
        let fetcher = deps.fetcher
        let cache = DBMetadataCache(db: db)
        // One resolver recipe for papers (EnrichActor) and mail rows (MailSyncActor / triage
        // verification): same cache, same HostGate, metadata.lookup + mailto re-read each time.
        let resolverFactory: @Sendable (EngineSettings) -> MetadataResolver? = { settings in
            guard settings.metadataLookup, let fetcher else { return nil }
            return MetadataResolver(fetcher: fetcher, cache: cache, gate: gate, mailto: settings.crossrefMailto)
        }
        // Every real spawn (incl. Claude's variant-B retry) passes this gate: agent.mode must name
        // the provider that asks — claude for Claude, codex for Codex (re-read each time) — and
        // the RunBudget (shared by both) must have a run left.
        let spawnGate = AgentSpawnGate(budget: RunBudget(), loadSettings: deps.loadSettings)
        let loadSettings = deps.loadSettings
        // The CLI path overrides (Settings ▸ AI, UserDefaults agent.cliPath / agent.codexPath) are
        // re-read on every resolve, so changing them needs no relaunch.
        let locator: BinaryLocator?
        let claude: any AgentProvider
        if let injected = deps.claude {
            locator = nil
            claude = injected
        } else {
            let live = BinaryLocator(overrideSource: { loadSettings().cliPathOverride })
            locator = live
            claude = ClaudeCodeProvider(locator: live, agentCwd: paths.agentCwd, spawnGate: spawnGate.claudeSpawnGate,
                                        now: deps.now)
        }
        let codexLocator: CodexLocator?
        let codex: any AgentProvider
        if let injected = deps.codex {
            codexLocator = nil
            codex = injected
        } else {
            let live = CodexLocator(overrideSource: { loadSettings().codexPathOverride })
            codexLocator = live
            codex = CodexProvider(locator: live, agentCwd: paths.agentCwd, spawnGate: spawnGate.codexSpawnGate,
                                  now: deps.now)
        }
        let agents = AgentQueue(ctx: ctx, claude: claude, codex: codex, mock: deps.mock, spawnGate: spawnGate,
                                cliFacts: deps.cliFacts, loadCardProfile: deps.loadCardProfile)
        let enrich = EnrichActor(
            ctx: ctx,
            resolverFactory: resolverFactory,
            onReady: { pk, hold in await agents.enqueue(paperPK: pk, hold: hold) }
        )
        let intake = IntakeActor(ctx: ctx, enrich: enrich)
        // A new card may change the naming basis (agent-extracted title/authors/year).
        await agents.setOnApplied { pk in _ = await enrich.refile(pk: pk) }

        // Mail: transports per account, attachment store, AI triage lane handler.
        let loadMailSettings = deps.loadMailSettings
        let secrets: any MailSecretStore = deps.mailSecrets ?? KeychainMailSecretStore()
        let makeSource: @Sendable (MailAccount) -> any MailSource = deps.mailSources ?? { account in
            MailSourceFactory.make(account, secrets: secrets, lang: loadSettings().lang)
        }
        let mailFiles = MailPDFFetcher(root: paths.mailFiles, extractor: deps.mailPDFExtractor ?? PDFExtractor())
        let mailTriage = MailTriageCoordinator(ctx: ctx, agents: agents, loadMailSettings: loadMailSettings,
                                               resolverFactory: resolverFactory, files: mailFiles)
        await agents.setTriageHandler { [weak mailTriage] job, outcome in await mailTriage?.handle(job, outcome) }
        let mail = MailSyncActor(ctx: ctx, loadMailSettings: loadMailSettings, makeSource: makeSource,
                                 resolverFactory: resolverFactory, files: mailFiles, triage: mailTriage)
        // Interactive assist: its own gate (same RunBudget, same per-provider pauses as the queue),
        // daily counters persisted in kv without change notifications, the lane with its backends.
        let counterSink: @Sendable (String, Int) -> Void = { key, value in
            Task { try? await db.setCounterKV(key, value) }
        }
        let assistCounter = AssistDailyCounter(prefix: AssistDailyCounter.assistPrefix, calendar: deps.calendar,
                                               persist: counterSink)
        let judgeCounter = AssistDailyCounter(prefix: AssistDailyCounter.dedupeJudgePrefix, calendar: deps.calendar,
                                              persist: counterSink)
        let now = deps.now
        let pause: @Sendable (AIProviderKind) -> Date? = { [agents] kind in agents.pause(for: kind, now: now()) }
        let assistGate = AssistGate(budget: spawnGate.budget, load: loadSettings, pause: pause, counter: assistCounter)
        // Claude / Codex backends only for the real providers (an injected test provider yields none);
        // inert while assist.mode is off (the default): every turn also needs a fresh ConsentTicket.
        let assistLane = AssistLane(gate: assistGate, load: loadSettings, now: now, pause: pause,
                                    backends: deps.assistBackends ?? AssistBackendFactory.builtIn(
                                        claude: claude, codex: codex, paths: paths, load: loadSettings, now: now,
                                        reader: { [loadCardProfile = deps.loadCardProfile] in loadCardProfile().reader }))
        // A usage limit on an assist turn pauses the card queue too; status snapshots → .assistStatus.
        await assistLane.wire(agents: agents, events: ctx.events)
        await agents.setAssistBusy { [assistLane] in assistLane.isBusyNow }
        await assistLane.setOnIdle { [agents] in Task { await agents.assistDidFinish() } }
        let loadCardProfile = deps.loadCardProfile
        let engine = Engine(ctx: ctx, intake: intake, enrich: enrich, agents: agents, gate: gate, mail: mail,
                            mailTriage: mailTriage, loadMailSettings: loadMailSettings, binaryLocator: locator,
                            codexLocator: codexLocator, assist: assistLane, assistGate: assistGate,
                            dedupeJudgeCounter: judgeCounter,
                            qa: QAService(lane: assistLane, load: loadSettings, now: now),
                            loadAssistReader: { loadCardProfile().reader })
        // A sender rule's auto-merge (Settings ▸ Mail ▸ Senders) runs once a card is ready.
        await mail.setOnMessageReady { [weak engine] message, rule in
            await engine?.autoMergeMail(message, rule: rule)
        }
        // One housekeeping path for launch and the sync loop (daily retention, snooze wake-up).
        await mail.setHousekeeping(MailSyncActor.Housekeeping(
            dailyRetention: { [weak engine] in
                guard let engine else { return }
                // The assist's daily pass (explanations past their history days, earlier days'
                // counters) never keeps the mail retention from running.
                do { _ = try await engine.maintenance.assistRetention() } catch {
                    Log.storage.error("assist retention failed: \(String(describing: type(of: error)), privacy: .public)")
                }
                _ = try await engine.maintenance.mailRetention()
            },
            unsnooze: { [weak engine] in _ = try await engine?.unsnoozeDue() }))
        return engine
    }

    /// Call after Settings ▸ AI changed the CLI path (UserDefaults `agent.cliPath`): the locator
    /// forgets its binary and the agent re-detects at once (no relaunch, no quota).
    package func cliPathOverrideDidChange() async {
        await binaryLocator?.invalidate()
        await agents.wake(forceDetect: true)
    }

    /// Call after Settings ▸ AI changed the Codex path (UserDefaults `agent.codexPath`).
    package func codexPathOverrideDidChange() async {
        await codexLocator?.invalidate()
        await agents.wake(forceDetect: true)
    }

    /// Call after `agent.provider` or `agent.mode` switched between Claude and ChatGPT: the queue
    /// re-detects the newly selected provider at once (zero quota). A running job finishes on its
    /// provider; queued jobs run with the new one.
    package func agentProviderDidChange() async {
        await agents.wake(forceDetect: true)
    }

    /// Launch maintenance (rebuild an empty index from the sidecars, reconcile files, clean
    /// temporary files, purge 最近删除, daily backup) — before the manifest is rewritten from
    /// the DB — then resume interrupted work. Safe to call once after open().
    ///
    /// First the library identity guard (`checkLibraryIdentity`): when the folder's manifest names
    /// another library than the one the index holds papers of, nothing runs — no maintenance (it
    /// would flag the other library's papers missing and adopt its folders), no manifest write (it
    /// would overwrite the other library's id and categories), no agents, no mail — and the report
    /// carries `libraryMismatch`. Once the user resolved it (`replaceIndexFromLibraryFolder`, or
    /// another library opened), `start()` may be called again.
    @discardableResult
    package func start() async -> MaintenanceReport {
        let identity = await checkLibraryIdentity()
        if case .mismatch = identity {
            var stopped = MaintenanceReport()
            stopped.libraryMismatch = identity
            return stopped
        }
        let report = await maintenance.onLaunch()
        await ctx.writeManifest()
        await enrich.resume()
        await restoreAssistCounters()
        await agents.start()
        await mailTriage.start()
        await mail.retentionDidRun()            // onLaunch ran today's mail retention
        await mail.start()
        return report
    }

    /// Stop enrichment (in-flight lookups are cancelled; papers keep their persisted stage and
    /// resume on the next launch) and the agent (a running job goes back to queued), flush
    /// sidecars, checkpoint. The agent queue stops starting runs first — nothing new is spawned
    /// (on either lane) while mail and enrichment wind down.
    package func shutdown() async {
        await agents.beginShutdown()
        await mail.shutdown()
        await enrich.shutdown()
        await assist.shutdown()                 // closes a warm / live assist process
        await agents.shutdown()                 // delivers in-flight triage results to mailTriage
        await mailTriage.shutdown()
        await ctx.sidecars.flush()
        try? await ctx.db.checkpoint()
    }

    /// Today's assist and judge counts from kv (the gate decides synchronously from memory).
    private func restoreAssistCounters() async {
        for counter in [assistGate.counter, dedupeJudgeCounter] {
            if let rows = try? await db.kvRows(prefix: counter.prefix) { counter.restore(rows) }
        }
    }

    // MARK: - Mail

    /// 「让 AI 分析」 on one card (the user's consent for that email). See `MailTriageCoordinator.requestAI`.
    /// 「让 AI 分析」 (`MailTriageCoordinator.requestAI`). Once the consent is stored, the
    /// title-only metadata lookups the email's post-processing held back for a person's, an
    /// advisor's or a dropped email (`MailSyncActor.mayLookUpTitles`) run too; confidential mail
    /// keeps them held.
    @discardableResult
    package func requestMailAI(messageID: String) async throws -> MailTriageState {
        let state = try await mailTriage.requestAI(messageID: messageID)
        if let m = try? await db.mailMessage(id: messageID), m.triageConsented {
            await mail.consentGiven(messagePK: m.pk)
        }
        return state
    }

    /// The sender rule's auto-merge (Settings ▸ Mail ▸ Senders): the PDF-ready rows of a pending
    /// card are merged without waiting for the user, with the popover's suggested options (the
    /// rule's priority / category, the email's due date only when confident and not past). Not a
    /// user action (`userAction: false`): the card stays open to triage and to the user; people's
    /// unidentified PDFs keep their AI reading held (OperationsMail). Links are downloaded only
    /// when the rule's 「自动下载」 is on, and only from arXiv / bioRxiv / medRxiv over https. A
    /// message whose DMARC/DKIM check failed (a possibly forged From) is never merged automatically,
    /// nor is confidential mail (`MailHeuristics.isConfidential`: a manuscript under review, a
    /// reviewer invitation, the user's own unposted submission) — whatever the sender kind; the
    /// user merges those by hand.
    fileprivate func autoMergeMail(_ message: MailMessage, rule: SenderRule?) async {
        guard let rule, rule.enabled, rule.autoMerge, message.state == .pending, !message.userTouched,
              message.authState != .fail, !MailHeuristics.isConfidential(message) else { return }
        let settings = await ctx.settings()
        let today = LocalDate.today(now: ctx.now(), calendar: ctx.calendar)
        let options = MailMergeOptions.suggested(for: message, rule: rule, settings: settings, today: today)
        do {
            let merged = try await mergeAllMailItems(messageID: message.id, options: options, userAction: false,
                                                     allowDownloads: rule.autoDownload)
            if !merged.isEmpty {
                Log.importer.info("mail#\(message.pk, privacy: .public): auto-merged \(merged.count, privacy: .public) paper(s)")
            }
        } catch {
            Log.importer.error("mail#\(message.pk, privacy: .public): auto-merge failed (\(String(describing: type(of: error)), privacy: .public))")
        }
    }
}
