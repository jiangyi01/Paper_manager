import Foundation
import os

/// Sync state of one configured account, for Settings ▸ Mail ▸ Accounts.
package struct MailAccountSyncInfo: Sendable, Equatable, Identifiable {
    package var id: String                      // MailAccount.id
    package var displayName: String
    package var kind: MailAccount.Kind
    package var enabled: Bool                   // account switch (and the global mail switch)
    package var status: MailSourceStatus?       // nil = not checked yet
    package var lastAttemptAt: Date?
    package var lastSuccessAt: Date?
    package var lastCaptured: Int               // emails captured by the last successful sync
    package var totalCaptured: Int              // since launch
    package var consecutiveFailures: Int
    package var nextRetryAt: Date?              // backoff after errors
    /// Sign-in / setup problem: no automatic retry until the account settings change or 立即同步.
    package var waitingForSettings: Bool
    package var isSyncing: Bool
    /// Folder accounts: files in the watched folder that are not complete emails (never become
    /// cards, never retried; the number drops once they are deleted — at the next sync).
    package var notEmailFiles: Int
    /// Ready-to-show fix for `notEmailFiles` (UI language), nil when there are none.
    package var notEmailHint: String?
    /// Allowlisted emails that could not be downloaded for more than a day. They are still
    /// retried on a long backoff; 「立即同步」 retries them at once. The account's status says so.
    package var undownloadable: Int
    /// Allowlisted emails that kept failing and could not stay on the retry list (its cap was
    /// reached): no longer retried by themselves. 「立即同步」 lists the account's look-back again
    /// (headers only) to pick them up; the status and `skippedHint` say so.
    package var skipped: Int
    /// Ready-to-show text for `skipped` (UI language), nil when there are none.
    package var skippedHint: String?

    package init(id: String, displayName: String, kind: MailAccount.Kind, enabled: Bool,
                 status: MailSourceStatus? = nil, lastAttemptAt: Date? = nil, lastSuccessAt: Date? = nil,
                 lastCaptured: Int = 0, totalCaptured: Int = 0, consecutiveFailures: Int = 0,
                 nextRetryAt: Date? = nil, waitingForSettings: Bool = false, isSyncing: Bool = false,
                 notEmailFiles: Int = 0, notEmailHint: String? = nil, undownloadable: Int = 0,
                 skipped: Int = 0, skippedHint: String? = nil) {
        self.id = id; self.displayName = displayName; self.kind = kind; self.enabled = enabled
        self.status = status; self.lastAttemptAt = lastAttemptAt; self.lastSuccessAt = lastSuccessAt
        self.lastCaptured = lastCaptured; self.totalCaptured = totalCaptured
        self.consecutiveFailures = consecutiveFailures; self.nextRetryAt = nextRetryAt
        self.waitingForSettings = waitingForSettings; self.isSyncing = isSyncing
        self.notEmailFiles = notEmailFiles; self.notEmailHint = notEmailHint
        self.undownloadable = undownloadable
        self.skipped = skipped; self.skippedHint = skippedHint
    }
}

/// The mail pipeline (MAIL_DESIGN Part A §2): per enabled account, on a cadence —
///
/// 1. `status()` (a source that is not ready costs nothing more);
/// 2. `listHeaders(since: cursor)` — headers only;
/// 3. `SenderMatcher` drops every non-allowlisted header **in memory** (never stored, never
///    logged, its body never requested); allowlisted Message-IDs already stored are skipped;
/// 4. `fetchMessage` for the rest (read-only transports, size-capped);
/// 5. `MailExtractor` + `MailHeuristics` (instant local triage with the user's criteria) on
///    BlockingIO; PDF attachments — and a person's Word / slides documents — stored under
///    `mail/files/<message-id>/`, library matches by SHA-256 and identifiers; shared-file links
///    become rows that wait for the user's PDF (never downloaded);
/// 6. one DB transaction per message (message + rows + its post-processing marker) — the card is
///    visible at once; the account's cursor is saved only after the page's messages committed;
///    `didCapture`;
/// 7. post-processing off the sync path: first page of stored PDFs, metadata (the engine's
///    resolver, 4 at a time, HostGate), library matching, PDF availability by the rules;
///    messages committed but not post-processed when the app quit are finished at the next start;
/// 8. AI triage decision (`MailTriageCoordinator`).
///
/// Cadence: every `syncMinutes` (0 = manual), `syncNow()`, app activation; per-account
/// exponential backoff on errors (sign-in / setup problems wait for new settings or 立即同步).
/// The cursor is valid for one account configuration and the sender list it was listed with:
/// a sender rule added, enabled or broadened re-lists the look-back (headers only). An
/// allowlisted message whose fetch keeps failing stays listable and is retried on a long
/// backoff; after a day the account's status says so. One a retry-list cap could not keep is
/// counted (`skipped`) and 「立即同步」 lists the look-back again. Once per library, after the
/// upgrade that taught the extractor documents and shared-file links, mail captured before it is
/// read again from its account and re-classified locally (`reevaluateDocumentsIfNeeded`). Manual `.eml` drops
/// (`importEML`) always run the same pipeline (explicit user intent) and are serialized with
/// 「清除所有邮件数据」. Account statuses are worded at display time (`MailLocalizedStatus`): a
/// language switch never rebuilds a source or signs in again.
///
/// Privacy: bodies of non-allowlisted mail are never read; log lines carry counts and pks
/// only — never addresses, subjects, bodies, file names or credentials.
package actor MailSyncActor {
    package typealias SourceFactory = @Sendable (MailAccount) -> any MailSource

    /// The engine's mail housekeeping, so the loop and launch share one code path:
    /// `Maintenance.mailRetention()` once per local day (snooze wake-up, body purge, attachment
    /// copies), `Engine.unsnoozeDue()` on every other tick.
    package struct Housekeeping: Sendable {
        package var dailyRetention: @Sendable () async throws -> Void
        package var unsnooze: @Sendable () async throws -> Void
        package init(dailyRetention: @escaping @Sendable () async throws -> Void,
                     unsnooze: @escaping @Sendable () async throws -> Void) {
            self.dailyRetention = dailyRetention; self.unsnooze = unsnooze
        }
    }

    package struct Tuning: Sendable, Equatable {
        package var pageLimit: Int
        package var maxPagesPerSync: Int
        package var minBackoff: TimeInterval
        package var maxBackoff: TimeInterval
        /// The loop wakes at least this often (snooze wake-up, retention, triage release).
        package var maintenanceInterval: Duration
        /// App activation syncs only when the last attempt is older than this.
        package var activationThrottle: TimeInterval
        package var metadataConcurrency: Int
        /// Quick fetch attempts of one message (the page waits for it, on the account's backoff);
        /// after that the message is retried on the long backoff below while the cursor moves on.
        package var maxFetchAttempts: Int
        package var metadataTimeout: TimeInterval
        /// Pause between two passes of a long backfill (`maxPagesPerSync` reached with pages left).
        package var backfillPause: TimeInterval
        /// Long backoff of a message that keeps failing: first retry after this, doubling…
        package var deferredRetryMin: TimeInterval
        /// …up to this. It is never given up while it is still there.
        package var deferredRetryMax: TimeInterval
        /// A message failing for this long shows on its account (status + `undownloadable`).
        package var undownloadableAfter: TimeInterval

        package init(pageLimit: Int = 50, maxPagesPerSync: Int = 20, minBackoff: TimeInterval = 60,
                     maxBackoff: TimeInterval = 6 * 3600, maintenanceInterval: Duration = .seconds(300),
                     activationThrottle: TimeInterval = 120, metadataConcurrency: Int = EnrichActor.maxConcurrent,
                     maxFetchAttempts: Int = 3, metadataTimeout: TimeInterval = MetadataResolver.defaultTotalTimeout,
                     backfillPause: TimeInterval = 1, deferredRetryMin: TimeInterval = 3600,
                     deferredRetryMax: TimeInterval = 6 * 3600, undownloadableAfter: TimeInterval = 86_400) {
            self.pageLimit = pageLimit; self.maxPagesPerSync = maxPagesPerSync; self.minBackoff = minBackoff
            self.maxBackoff = maxBackoff; self.maintenanceInterval = maintenanceInterval
            self.activationThrottle = activationThrottle; self.metadataConcurrency = max(1, metadataConcurrency)
            self.maxFetchAttempts = max(1, maxFetchAttempts); self.metadataTimeout = metadataTimeout
            self.backfillPause = max(0, backfillPause)
            self.deferredRetryMin = max(1, deferredRetryMin)
            self.deferredRetryMax = max(self.deferredRetryMin, deferredRetryMax)
            self.undownloadableAfter = max(0, undownloadableAfter)
        }
    }

    /// Account id of manually imported `.eml` files.
    package static let manualAccountID = "manual"
    /// Metadata lookups per message (alert digests list many papers).
    package static let maxLookupsPerMessage = 30
    package static let maxTitleLookupsPerMessage = 10

    static let log = Logger(subsystem: Log.subsystem, category: "mail")

    private let ctx: EngineContext
    private let loadMailSettings: @Sendable () -> MailSettings
    private let makeSource: SourceFactory
    private let resolverFactory: @Sendable (EngineSettings) -> MetadataResolver?
    private let files: MailPDFFetcher
    private let triage: MailTriageCoordinator
    private var tuning = Tuning()
    private var onMessageReady: (@Sendable (MailMessage, SenderRule?) async -> Void)?
    private var housekeeping: Housekeeping?
    /// UI language of the last pass (the default of `accountSyncInfo()` / `accountStatuses()`).
    /// Statuses are worded at display time (`MailLocalizedStatus`): a language switch never rebuilds a
    /// source or signs in again.
    private var lang: UILang = .en

    private struct AccountState {
        var account: MailAccount
        var source: any MailSource
        var status: MailLocalizedStatus?
        var lastAttemptAt: Date?
        var lastSuccessAt: Date?
        var lastCaptured = 0
        var totalCaptured = 0
        var failures = 0
        var nextRetryAt: Date?
        var waitingForSettings = false
        var syncing = false
        var moreWaiting = false          // stopped at maxPagesPerSync with pages left: continue soon
        var notEmailFiles: Int?          // nil = not known yet (seeded from the stored ledger)
        var undownloadable = 0
        var skipped: Int?                // nil = not known yet (seeded from kv `<id>.skipped`)
    }

    private var accounts: [String: AccountState] = [:]
    private var accountOrder: [String] = []
    private var lastPurgeDay: LocalDate?

    // Loop
    private var loopTask: Task<Void, Never>?
    private var stopping = false
    private var cycleRunning = false
    private var forcePending = false
    private var activationPending = false
    private var wakePending = false
    private var napContinuation: CheckedContinuation<Void, Never>?
    private var napTimer: Task<Void, Never>?
    private var napToken = 0
    private var cycleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Resumed when the pass in progress ends (「清除所有邮件数据」 waits for it).
    private var cycleEndWaiters: [CheckedContinuation<Void, Never>] = []
    /// 「清除所有邮件数据」 in progress: syncs stop at the next message, no pass starts, imports wait.
    private var clearing = false
    private var clearWaiters: [CheckedContinuation<Void, Never>] = []

    // Post-processing worker
    private var postQueue: [Int64] = []
    private var postTask: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Messages whose triage hand-off is still owed after post-processing (queued, never handed
    /// off): retried — hand-off only — at the next passes, `maxHandOffRetries` times.
    private var handOffRetries: [Int64: Int] = [:]
    /// Queued for the hand-off retry only (enrichment already ran).
    private var handOffOnly: Set<Int64> = []
    /// Queued for the title-only metadata lookups its post-processing held back, once the user
    /// asked for 「让 AI 分析」 (`consentGiven`).
    private var titlesOnly: Set<Int64> = []
    private var postCurrent: Int64?

    /// The one-time documents re-evaluation finished (or gave up) — `reevaluateDocumentsIfNeeded`.
    private var reevaluationSettled = false

    // Manual imports in progress (「清除所有邮件数据」 waits for them).
    private var importsRunning = 0
    private var importWaiters: [CheckedContinuation<Void, Never>] = []

    package init(ctx: EngineContext, loadMailSettings: @escaping @Sendable () -> MailSettings,
                 makeSource: @escaping SourceFactory,
                 resolverFactory: @escaping @Sendable (EngineSettings) -> MetadataResolver?,
                 files: MailPDFFetcher, triage: MailTriageCoordinator) {
        self.ctx = ctx; self.loadMailSettings = loadMailSettings; self.makeSource = makeSource
        self.resolverFactory = resolverFactory; self.files = files; self.triage = triage
    }

    package func configure(_ tuning: Tuning) { self.tuning = tuning }

    /// Called once per captured message after post-processing (the engine wires the sender
    /// rule's auto-merge here). Never called for messages the user already handled.
    package func setOnMessageReady(_ handler: (@Sendable (MailMessage, SenderRule?) async -> Void)?) {
        onMessageReady = handler
    }

    /// Wired by `Engine.open` (see `Housekeeping`). Without it the loop only ticks triage.
    package func setHousekeeping(_ h: Housekeeping?) { housekeeping = h }

    /// Launch maintenance already ran the retention today (`Engine.start`): the loop's first
    /// pass only wakes snoozed cards.
    package func retentionDidRun() {
        lastPurgeDay = LocalDate.today(now: ctx.now(), calendar: ctx.calendar)
    }

    // MARK: - Lifecycle

    /// Starts the loop: messages committed but not post-processed before the last quit are
    /// post-processed again (enrichment, verification, `messageReady` → triage, auto-merge),
    /// then a first pass runs at once (accounts sync when due), then every `syncMinutes` /
    /// maintenance interval, `syncNow()` and app activation.
    package func start() {
        guard !stopping, loopTask == nil else { return }
        loopTask = Task { await self.runLoop() }
    }

    /// Stops the loop and the post-processing worker and closes IMAP sessions. Bounded: IMAP
    /// sessions are closed at once (LOGOUT gets at most a second, so a sync waiting on an
    /// unresponsive server fails now), and the loop / worker get `wait` in total (then they are
    /// cancelled and no longer waited for). Captured messages are already committed; the ones
    /// not post-processed yet are finished at the next start.
    package func shutdown(wait: Duration = .seconds(3)) async {
        guard !stopping else { return }
        stopping = true
        poke()
        let loop = loopTask
        loopTask = nil
        let post = postTask
        post?.cancel()
        postQueue.removeAll()
        let sources = accounts.values.map(\.source)
        async let closed: Void = Self.shutDownSources(sources)
        await Self.joinAll([loop, post].compactMap { $0 }, within: wait)
        await closed
        postTask = nil
        resumeCycleWaiters()
        resumeCycleEndWaiters()
        resumeIdleWaiters()
        resumeClearWaiters()
        resumeImportWaiters()
    }

    // MARK: - Triggers

    /// 「立即同步」: syncs every enabled account now (ignoring backoff; parked accounts get a new
    /// attempt; messages waiting on their long retry backoff are retried; an account that had to
    /// skip messages — `MailAccountSyncInfo.skipped` — lists its look-back again) and returns
    /// when done.
    package func syncNow() async {
        forcePending = true                     // the forced pass un-parks every account first
        await awaitCycle()
    }

    /// App became active: accounts whose last attempt is older than the activation throttle
    /// sync now (not in manual-only mode; backoff still applies).
    package func appDidBecomeActive() {
        activationPending = true
        poke()
    }

    /// Settings ▸ Mail changed: re-read at once (accounts reconciled — a changed account gets a
    /// fresh state and source), held triage released, the loop poked. Accounts parked on a
    /// rejected app password or a setup problem stay parked — every keystroke in Settings must
    /// not sign in again with a rejected password. `unpark: true` gives parked accounts a new
    /// attempt: only `accountIDs` (Test & Save / an account added or edited passes that
    /// account's id), every account when nil (立即同步).
    package func settingsDidChange(unpark: Bool = false, accountIDs: Set<String>? = nil) async {
        if !stopping {
            let settings = loadMailSettings()
            let current = await ctx.settings().lang
            lang = current
            reconcileAccounts(settings)
        }
        if unpark { unparkAll(only: accountIDs) }
        await triage.tick()
        poke()
    }

    private func unparkAll(only ids: Set<String>? = nil) {
        for id in accountOrder where accounts[id]?.waitingForSettings == true && (ids?.contains(id) ?? true) {
            accounts[id]?.waitingForSettings = false
            accounts[id]?.nextRetryAt = nil
        }
    }

    // MARK: - Status

    /// Last known status per account id (accounts not checked yet are absent), worded in `lang`
    /// (default: the language of the last pass).
    package func accountStatuses(lang: UILang? = nil) -> [String: MailSourceStatus] {
        let l = lang ?? self.lang
        var out: [String: MailSourceStatus] = [:]
        for (id, st) in accounts { if let s = st.status { out[id] = s.render(l) } }
        return out
    }

    /// Settings rows, in the order of `MailSettings.accounts` (unsynced accounts included), with
    /// every text in `lang` (default: the language of the last pass): the status and its detail
    /// — the transport's ("Signed in as …", "Watching …") and the pipeline's (fetch / sync
    /// failures, the undownloadable and skipped suffixes) — and the hints. Worded now, from the
    /// facts of the last check: a language switch needs no new sign-in.
    package func accountSyncInfo(lang: UILang? = nil) -> [MailAccountSyncInfo] {
        let settings = loadMailSettings()
        let hintLang = lang ?? self.lang
        return settings.accounts.map { a in
            let st = accounts[a.id]
            let notEmail = a.kind == .folder ? (st?.notEmailFiles ?? 0) : 0
            let skipped = st?.skipped ?? 0
            return MailAccountSyncInfo(
                id: a.id, displayName: a.displayName, kind: a.kind, enabled: settings.enabled && a.enabled,
                status: st?.status?.render(hintLang), lastAttemptAt: st?.lastAttemptAt, lastSuccessAt: st?.lastSuccessAt,
                lastCaptured: st?.lastCaptured ?? 0, totalCaptured: st?.totalCaptured ?? 0,
                consecutiveFailures: st?.failures ?? 0, nextRetryAt: st?.nextRetryAt,
                waitingForSettings: st?.waitingForSettings ?? false, isSyncing: st?.syncing ?? false,
                notEmailFiles: notEmail, notEmailHint: notEmail > 0 ? MailSyncText.notEmailFiles(notEmail, hintLang) : nil,
                undownloadable: st?.undownloadable ?? 0, skipped: skipped,
                skippedHint: skipped > 0 ? MailSyncText.skippedByCap(skipped, lookbackDays: a.lookbackDays, hintLang) : nil)
        }
    }

    /// Waits until the post-processing queue is empty (tests, CLI self-test).
    package func waitUntilIdle() async {
        guard postTask != nil || !postQueue.isEmpty else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: - Manual .eml import

    /// Imports dropped / chosen `.eml` files (explicit intent: no allowlist; the sender rule
    /// still applies when the From address matches one, else kind `manual`). Returns the
    /// message id per file that is a message (already captured ones return their existing id).
    /// Serialized with 「清除所有邮件数据」: an import waits while a clear runs, and a clear that
    /// starts during an import stops it at the next file and waits for the email being captured
    /// (so no row outlives the wipe without its attachment files).
    package func importEML(_ urls: [URL]) async -> [String] {
        await waitWhileClearing()
        importsRunning += 1
        defer {
            importsRunning -= 1
            if importsRunning == 0 { resumeImportWaiters() }
        }
        let settings = loadMailSettings()
        let maxBytes = Self.fetchLimit(settings)
        var ids: [String] = []
        var captured: [Int64] = []
        for url in urls {
            guard !clearing, !stopping else { break }       // 清除所有邮件数据 started: the rest is not imported
            let data: Data
            do {
                data = try await FileOps.coordinatedRead(source: url, timeout: .seconds(60)) { u in
                    try FileOps.readHead(u, bytes: maxBytes)
                }
            } catch {
                Self.log.info("mail import: a file could not be read (\(Self.logText(error), privacy: .public))")
                continue
            }
            let attachmentCap = Self.attachmentCap(settings)
            guard let content = try? await BlockingIO.run({ try MIMEParser.parse(data, maxAttachmentBytes: attachmentCap) }),
                  !content.header.fromAddress.isEmpty || !content.header.subject.isEmpty else {
                Self.log.info("mail import: a file is not an email — skipped")
                continue
            }
            let rule = SenderMatcher.match(address: content.header.fromAddress, rules: settings.senders)
            let truncated = data.count >= maxBytes
            if let outcome = await capture(content, ref: url.lastPathComponent, account: nil, rule: rule,
                                           manual: true, truncated: truncated, settings: settings) {
                ids.append(outcome.id)
                if let pk = outcome.newPK { captured.append(pk) }
            }
        }
        for pk in captured { enqueuePost(pk) }
        if !captured.isEmpty { Self.log.info("mail import: \(captured.count, privacy: .public) email(s) captured") }
        return ids
    }

    /// 「清除所有邮件数据」: every message, row and cursor, plus the stored attachments. Library
    /// papers and their provenance stay. Serialized with the sync loop and with `.eml` imports: a
    /// sync in progress stops at its next message and is waited for, an import stops at its next
    /// file and is waited for, post-processing is stopped, then everything is wiped and every
    /// account starts over (with its look-back) at its next sync.
    package func deleteAllMailData() async throws {
        await waitWhileClearing()
        clearing = true
        defer {
            clearing = false
            resumeClearWaiters()
            poke()
        }
        postQueue.removeAll()
        if let post = postTask {
            post.cancel()
            await Self.join(post, within: .seconds(5))
        }
        while cycleRunning, !stopping {
            await withCheckedContinuation { cycleEndWaiters.append($0) }
        }
        while importsRunning > 0, !stopping {
            await withCheckedContinuation { importWaiters.append($0) }
        }
        handOffRetries.removeAll()
        handOffOnly.removeAll()
        titlesOnly.removeAll()
        await triage.clearAll()
        try await ctx.db.deleteAllMailData()
        await files.removeAll()
        // Fresh transports (folder: read-failure / not-an-email memory; IMAP: its session) and
        // backoff; the status and a parked sign-in problem stay.
        for id in accountOrder {
            guard var st = accounts[id] else { continue }
            let old = st.source
            Task { await Self.close(old) }
            st.source = makeSource(st.account)
            st.failures = 0
            st.nextRetryAt = nil
            st.moreWaiting = false
            st.notEmailFiles = nil
            st.undownloadable = 0
            st.skipped = 0
            accounts[id] = st
        }
    }

    private func resumeImportWaiters() {
        let waiters = importWaiters
        importWaiters = []
        for w in waiters { w.resume() }
    }

    private func waitWhileClearing() async {
        while clearing, !stopping {
            await withCheckedContinuation { clearWaiters.append($0) }
        }
    }

    // MARK: - Loop

    private func runLoop() async {
        await recoverPostProcessing()
        while !stopping {
            let waiters = cycleWaiters
            cycleWaiters = []
            await runCycle()
            for w in waiters { w.resume() }
            guard !stopping else { break }
            await nap(nextNap())
        }
        resumeCycleWaiters()
    }

    /// One pass. Serialized: a call during a pass waits for the next one.
    private func awaitCycle() async {
        if loopTask != nil, !stopping {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                cycleWaiters.append(c)
                poke()
            }
            return
        }
        guard !stopping else { return }
        if cycleRunning {
            await withCheckedContinuation { cycleWaiters.append($0) }
            return
        }
        let waiters = cycleWaiters
        cycleWaiters = []
        await runCycle()
        for w in waiters { w.resume() }
    }

    private func runCycle() async {
        guard !clearing else { return }           // the pass after the clear syncs
        cycleRunning = true
        defer {
            cycleRunning = false
            resumeCycleEndWaiters()
        }
        let force = forcePending
        let activation = activationPending
        forcePending = false
        activationPending = false
        if force { unparkAll() }                  // 立即同步: parked accounts get a new attempt
        let settings = loadMailSettings()
        lang = await ctx.settings().lang
        await maintenance(settings)
        reconcileAccounts(settings)
        await seedAccountCounts()
        guard settings.enabled else { return }
        let now = ctx.now()
        for id in accountOrder {
            guard !stopping, !clearing, let st = accounts[id], st.account.enabled else { continue }
            guard force || isDue(st, settings: settings, now: now, activation: activation) else { continue }
            await syncAccount(id, settings: settings, force: force)
        }
        await reevaluateDocumentsIfNeeded(settings)
    }

    private func isDue(_ st: AccountState, settings: MailSettings, now: Date, activation: Bool) -> Bool {
        if st.waitingForSettings { return false }
        if let retry = st.nextRetryAt, retry > now { return false }
        if st.failures > 0 || st.moreWaiting { return true }     // backoff elapsed / backfill continues
        guard settings.syncMinutes > 0 else { return false }
        guard let last = st.lastAttemptAt else { return true }
        let interval = activation ? min(tuning.activationThrottle, Double(settings.syncMinutes) * 60)
                                  : Double(settings.syncMinutes) * 60
        return now.timeIntervalSince(last) >= interval - 1
    }

    private func nextNap() -> Duration {
        let settings = loadMailSettings()
        var seconds = Double(tuning.maintenanceInterval.components.seconds)
            + Double(tuning.maintenanceInterval.components.attoseconds) / 1e18
        guard settings.enabled else { return .seconds(max(0.01, seconds)) }
        let now = ctx.now()
        for id in accountOrder {
            guard let st = accounts[id], st.account.enabled, !st.waitingForSettings else { continue }
            if st.moreWaiting {
                seconds = min(seconds, tuning.backfillPause)
            } else if let retry = st.nextRetryAt {
                seconds = min(seconds, retry.timeIntervalSince(now))
            } else if settings.syncMinutes > 0 {
                let due = (st.lastAttemptAt ?? now).addingTimeInterval(Double(settings.syncMinutes) * 60)
                seconds = min(seconds, due.timeIntervalSince(now))
            }
        }
        return .milliseconds(Int(max(0.05, seconds) * 1000))
    }

    /// Once per local day the engine's mail retention (`Maintenance.mailRetention`: snooze
    /// wake-up, bodies and attachment copies of cards handled longer than `retentionDays` ago;
    /// ≤ 0 keeps everything), on every other tick the snooze wake-up; then held / failed triage
    /// is released when it may run, owed hand-offs are retried, and a message left `queued`
    /// without a hand-off for longer than a pass offers 「让 AI 分析」 instead.
    private func maintenance(_ settings: MailSettings) async {
        if let h = housekeeping {
            let today = LocalDate.today(now: ctx.now(), calendar: ctx.calendar)
            if lastPurgeDay != today {
                lastPurgeDay = today
                do { try await h.dailyRetention() } catch {
                    Self.log.error("mail retention failed (\(String(describing: type(of: error)), privacy: .public))")
                }
            } else {
                do { try await h.unsnooze() } catch {
                    Self.log.error("mail snooze wake-up failed (\(String(describing: type(of: error)), privacy: .public))")
                }
            }
        }
        await triage.tick()
        guard !stopping, !clearing else { return }
        await retryOwedHandOffs()
        let cycle = max(Double(tuning.maintenanceInterval.components.seconds), Double(settings.syncMinutes) * 60)
        await triage.releaseStrandedQueued(olderThan: ctx.now().addingTimeInterval(-cycle))
    }

    /// Counts unknown since launch / a new source, from the store: a folder account's
    /// not-an-email files (its ledger), every account's skipped messages (kv `<id>.skipped`) —
    /// so Settings shows the hints before a sync.
    private func seedAccountCounts() async {
        for id in accountOrder {
            guard let st = accounts[id] else { continue }
            if st.skipped == nil {
                let n = Int((try? await ctx.db.mailCursor(accountID: Self.skippedKey(id)))?.value ?? "") ?? 0
                if accounts[id]?.account == st.account, accounts[id]?.skipped == nil { accounts[id]?.skipped = n }
            }
            guard st.account.kind == .folder, st.notEmailFiles == nil else { continue }
            var count = 0
            if (try? await ctx.db.mailCursor(accountID: Self.fingerprintKey(id)))?.value == Self.fingerprint(st.account),
               let ledger = FolderLedger(try? await ctx.db.mailCursor(accountID: id)) {
                count = ledger.notMailCount
            }
            if accounts[id]?.account == st.account, accounts[id]?.notEmailFiles == nil { accounts[id]?.notEmailFiles = count }
        }
    }

    /// Keeps one source per configured account; a changed account gets a fresh source (and a
    /// fresh start of its backoff), a removed one is closed. A language switch changes nothing
    /// here: statuses are worded at display time (`MailLocalizedStatus`), so no source is rebuilt —
    /// none is closed under a running sync, and no extra IMAP sign-in happens.
    private func reconcileAccounts(_ settings: MailSettings) {
        var seen = Set<String>()
        var order: [String] = []
        for a in settings.accounts where seen.insert(a.id).inserted {
            order.append(a.id)
            if let st = accounts[a.id], st.account == a { continue }
            if let old = accounts[a.id] { let s = old.source; Task { await Self.close(s) } }
            accounts[a.id] = AccountState(account: a, source: makeSource(a))
        }
        for (id, st) in accounts where !seen.contains(id) {
            let s = st.source
            Task { await Self.close(s) }
            accounts[id] = nil
        }
        accountOrder = order
    }

    /// Waits for `task`; when it outlives `limit` it is cancelled and given a short grace, then
    /// no longer waited for (a task that ignores cancellation cannot hold the caller).
    static func join(_ task: Task<Void, Never>, within limit: Duration) async {
        await joinAll([task], within: limit)
    }

    /// `join` for several tasks sharing one deadline (the total wait is at most `limit`).
    static func joinAll(_ tasks: [Task<Void, Never>], within limit: Duration) async {
        guard !tasks.isEmpty else { return }
        let grace = min(.milliseconds(250), limit / 4)
        if await waitAll(tasks, upTo: limit - grace) { return }
        for t in tasks { t.cancel() }
        _ = await waitAll(tasks, upTo: grace)
    }

    /// True when every task finished within `limit`; false at the deadline otherwise.
    private static func waitAll(_ tasks: [Task<Void, Never>], upTo limit: Duration) async -> Bool {
        let once = JoinOnce()
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            once.install(c)
            let timer = Task {
                try? await Task.sleep(for: limit)
                once.finish(false)
            }
            Task {
                for t in tasks { await t.value }
                once.finish(true)
                timer.cancel()
            }
        }
    }

    /// Log-safe error text (an I/O message could quote a file name, i.e. a subject).
    static func logText(_ error: any Error) -> String { MailTransportLog.reason(error) }

    private static func close(_ source: any MailSource) async {
        if let imap = source as? IMAPMailSource { await imap.close() }
    }

    /// App quitting: every IMAP session closes concurrently, LOGOUT bounded.
    private static func shutDownSources(_ sources: [any MailSource]) async {
        await withTaskGroup(of: Void.self) { group in
            for case let imap as IMAPMailSource in sources {
                group.addTask { await imap.shutdown(logoutWithin: .seconds(1)) }
            }
        }
    }

    // MARK: - One account

    private func syncAccount(_ id: String, settings: MailSettings, force: Bool) async {
        guard var st = accounts[id] else { return }
        let account = st.account
        let source = st.source
        let lang = await ctx.settings().lang
        let started = ctx.now()
        st.syncing = true
        st.lastAttemptAt = started
        accounts[id] = st
        // A watched folder that is offline is retried at least at the sync cadence.
        let backoffCap: TimeInterval? = account.kind == .folder && settings.syncMinutes > 0
            ? max(tuning.minBackoff, Double(settings.syncMinutes) * 60) : nil

        // The stored resume point is valid for this account configuration and for the sender
        // list it was listed with: a rule added, enabled or broadened since then re-lists the
        // look-back (headers only; Message-ID dedupe skips what is already captured). Without a
        // look-back there is nothing earlier to re-list.
        let fingerprint = Self.fingerprint(account)
        let senders = Self.sendersFingerprint(settings.senders)
        // 立即同步 on an account that had to skip messages (retry list full): its look-back is
        // listed again from the start (headers only; captured mail is skipped by Message-ID) —
        // keeping the cursor's retry list (`MailSource.relisting`), so a deferred message older
        // than the look-back is not forgotten. Without a look-back there is nothing earlier to
        // list: the stored cursor stays and its retry list is retried now (`force`).
        let rescan = force && (st.skipped ?? 0) > 0
        var cursor: MailCursor?
        var stored = false
        var relist = false
        var configChanged = false
        do {
            cursor = try await ctx.db.mailCursor(accountID: id)
            stored = cursor != nil
            if cursor != nil, try await ctx.db.mailCursor(accountID: Self.fingerprintKey(id))?.value != fingerprint {
                cursor = nil
                configChanged = true
            }
            if cursor != nil, account.lookbackDays > 0,
               !Self.sendersCovered(saved: try await ctx.db.mailCursor(accountID: Self.sendersKey(id))?.value, current: senders) {
                relist = true
                Self.log.info("mail sync: the sender list grew — re-listing the look-back (headers only)")
            }
            if rescan, cursor != nil, account.lookbackDays > 0, !relist {
                relist = true
                Self.log.info("mail sync: skipped messages — re-listing the look-back (headers only)")
            }
        } catch {
            finish(id, account: account, status: MailLocalizedStatus { .unavailable(MailSyncText.syncFailed($0)) }, error: true,
                   captured: 0, backoffCap: backoffCap)
            return
        }
        // nil: the transport keeps no retry list in its cursor — the look-back starts from scratch.
        if relist, let old = cursor { cursor = await source.relisting(old) }

        // The look-back is listed again from its start (rescan, new senders, a changed account).
        let relisting = stored && (relist || cursor == nil)
        // The skipped messages (`<id>.skipped`, `<id>.skipped.refs`): a ref listed again in this
        // pass leaves the count (it is captured now, deferred again, or dropped and counted again).
        let skippedBefore = accounts[id]?.skipped ?? st.skipped ?? 0
        let refsBefore = configChanged ? [] : await loadSkippedRefs(id)
        var skippedRefs = refsBefore
        let watched = Set(refsBefore)
        var listedAgain = Set<String>()
        await source.prime(cursor: cursor)
        let status = await source.localizedStatus()
        guard case .ready = status.render(lang) else {
            finish(id, account: account, status: status, error: true, captured: 0, backoffCap: backoffCap)
            return
        }
        var retry = await loadRetry(id)
        let retryBefore = retry
        var deferred: [String] = []
        /// Allowlisted messages that kept failing and could not stay listable (cap / transport).
        var dropped = Set<String>()
        var captured = 0
        var failure: MailLocalizedStatus?
        var more = false
        var interrupted = false
        do {
            var pages = 0
            while true {
                guard !stopping, !clearing else { interrupted = true; break }
                let page = try await source.listHeaders(since: cursor, limit: tuning.pageLimit)
                if let n = page.notEmailFiles, accounts[id]?.account == account { accounts[id]?.notEmailFiles = n }
                let result = await processPage(page.headers, account: account, source: source, settings: settings,
                                               retry: &retry, force: force, watched: watched)
                listedAgain.formUnion(result.listedAgain)
                captured += result.captured.count
                // Committed messages are captured whatever happens to the rest of the page.
                for pk in result.captured { enqueuePost(pk) }
                guard result.complete else {
                    for h in result.didCapture { await source.didCapture(h) }
                    if stopping || clearing {
                        interrupted = true
                    } else if let e = result.error, e is IMAPError {
                        failure = Self.localizedStatus(for: e, account: account)
                    } else {
                        failure = MailLocalizedStatus { .unavailable(MailSyncText.fetchFailed($0)) }
                    }
                    break
                }
                deferred += result.deferred
                if let next = page.nextCursor {
                    var toSave = next
                    if !deferred.isEmpty {
                        if let kept = await source.deferral(deferred, in: next) {
                            toSave = kept.cursor
                            // Over the cursor's retry cap: no longer listable — counted, never silent.
                            dropped.formUnion(kept.dropped)
                        } else {
                            // The transport can't list them again: given up (poison-message guard),
                            // and counted on the account like the ones over a retry cap.
                            dropped.formUnion(deferred)
                            Self.log.error("mail sync: \(deferred.count, privacy: .public) allowlisted message(s) kept failing — given up")
                            deferred.removeAll()
                        }
                    }
                    let save = toSave
                    try await ctx.db.transaction { db in
                        try db.setMailCursor(accountID: id, save)
                        try db.setMailCursor(accountID: MailSyncActor.fingerprintKey(id), MailCursor(fingerprint))
                        try db.setMailCursor(accountID: MailSyncActor.sendersKey(id), MailCursor(senders))
                    }
                    cursor = next
                }
                for h in result.didCapture { await source.didCapture(h) }
                pages += 1
                guard page.hasMore else { break }
                guard pages < tuning.maxPagesPerSync else { more = true; break }
            }
        } catch {
            if stopping || clearing { interrupted = true } else { failure = Self.localizedStatus(for: error, account: account) }
        }

        // Retry records: forgotten once unseen for a while (gone, captured elsewhere, no longer
        // allowlisted); the ones failing for over a day show on the account. Dropped ones are
        // counted on the account instead (they are not listed again by themselves).
        for ref in dropped { retry[Self.refKey(ref)] = nil }
        let nowMs = Self.ms(ctx.now())
        retry = retry.filter { nowMs - $0.value.last < Int64(Self.forgetRetryAfter * 1000) }
        if retry != retryBefore { await saveRetry(id, retry) }
        let undownloadable = retry.values.filter {
            $0.n >= tuning.maxFetchAttempts && nowMs - $0.first >= Int64(tuning.undownloadableAfter * 1000)
                && nowMs - $0.last < Int64(max(tuning.undownloadableAfter, 3600) * 1000)
        }.count
        if captured > 0 {
            Self.log.info("mail sync: \(captured, privacy: .public) email(s) captured")
        }
        // Skipped: the messages a cap dropped and not listed since. Only what was actually listed
        // again leaves the count — a look-back that does not reach a dropped message, or no
        // look-back at all, keeps it counted. A count stored without its refs (an earlier build,
        // or past `maxSkippedRefs`) clears once a re-listed look-back got through; a changed
        // account (another server / mailbox / folder) starts over.
        var legacy = configChanged ? 0 : max(0, skippedBefore - refsBefore.count)
        if relisting, account.lookbackDays > 0, !interrupted, failure == nil { legacy = 0 }
        skippedRefs.removeAll { listedAgain.contains($0) }
        for ref in dropped {
            let key = Self.refKey(ref)
            skippedRefs.removeAll { $0 == key }
            skippedRefs.append(key)
        }
        if skippedRefs.count > Self.maxSkippedRefs {
            legacy += skippedRefs.count - Self.maxSkippedRefs
            skippedRefs.removeFirst(skippedRefs.count - Self.maxSkippedRefs)
        }
        let skipped = legacy + skippedRefs.count
        if !dropped.isEmpty {
            Self.log.error("mail sync: \(dropped.count, privacy: .public) allowlisted message(s) skipped — retry list full")
        }
        if skipped != skippedBefore || skippedRefs != refsBefore {
            await saveSkipped(id, skipped, refs: skippedRefs)
            if accounts[id]?.account == account { accounts[id]?.skipped = skipped }
        }
        if interrupted {
            if accounts[id]?.account == account { accounts[id]?.syncing = false }
            return
        }
        var listed = status
        if failure == nil, account.kind == .folder {
            // A local scan: the count now knows what this pass learned (files that aren't emails).
            let again = await source.localizedStatus()
            if case .ready = again.render(lang) { listed = again }
        }
        var final = failure ?? listed
        if failure == nil, undownloadable > 0 || skipped > 0 {
            let base = listed, lookback = account.lookbackDays, skipped = skipped
            final = MailLocalizedStatus { l in
                let status = base.render(l)
                guard case .ready(let detail) = status else { return status }
                var parts = [detail]
                if undownloadable > 0 { parts.append(MailSyncText.undownloadable(undownloadable, l)) }
                if skipped > 0 { parts.append(MailSyncText.skippedByCap(skipped, lookbackDays: lookback, l)) }
                return .unavailable(parts.joined(separator: " · "))
            }
        }
        finish(id, account: account, status: final, error: failure != nil, captured: captured, backoffCap: backoffCap)
        if accounts[id]?.account == account {
            accounts[id]?.moreWaiting = failure == nil && more
            accounts[id]?.undownloadable = undownloadable
        }
        if failure == nil { try? await ctx.db.setKV("mail.lastSyncAt", Database.timestamp(ctx.now())) }
    }

    private func finish(_ id: String, account: MailAccount, status: MailLocalizedStatus, error: Bool, captured: Int,
                        backoffCap: TimeInterval? = nil) {
        guard var st = accounts[id], st.account == account else { return }
        let now = ctx.now()
        st.syncing = false
        st.status = status
        st.totalCaptured += captured
        if error {
            st.failures += 1
            switch status.render(lang) {
            case .authFailed, .needsSetup:
                // Retrying a rejected app password would only risk a provider lock-out.
                st.waitingForSettings = true
                st.nextRetryAt = nil
            default:
                var delay = min(tuning.maxBackoff, tuning.minBackoff * pow(2, Double(max(0, st.failures - 1))))
                if let cap = backoffCap { delay = min(delay, cap) }
                st.nextRetryAt = now.addingTimeInterval(delay)
            }
        } else {
            st.failures = 0
            st.nextRetryAt = nil
            st.waitingForSettings = false
            st.lastSuccessAt = now
            st.lastCaptured = captured
        }
        accounts[id] = st
    }

    private struct PageResult {
        var captured: [Int64] = []
        /// `refKey`s of skipped messages (`watched`) this page listed again.
        var listedAgain: [String] = []
        var didCapture: [MailHeader] = []
        /// Refs of allowlisted messages that keep failing: the saved cursor keeps them listable.
        var deferred: [String] = []
        var complete = true
        var error: (any Error)?
    }

    /// Fetch errors that will not go away by retrying (the message is gone or unreadable).
    static func isPermanentFetchError(_ error: any Error) -> Bool {
        if error is MIMEParser.ParseError { return true }
        if let e = error as? IMAPError {
            switch e {
            case .messageNotFound, .invalidReference, .uidValidityChanged: return true
            default: return false
            }
        }
        if let e = error as? FolderMailSourceError, e == .invalidReference { return true }
        if let e = error as? FileOpsError, e == .sourceMissing || e == .notPDF { return true }
        return false
    }

    /// Steps 3–6 for one page of headers. `complete` is false when a message could not be
    /// fetched within its quick attempts (the cursor then stays put and the page is listed again
    /// after the account's backoff). A message that keeps failing is deferred instead: retried
    /// on its long backoff (`force`: now) while the cursor moves on.
    private func processPage(_ headers: [MailHeader], account: MailAccount, source: any MailSource,
                             settings: MailSettings, retry: inout [String: RetryRecord],
                             force: Bool, watched: Set<String> = []) async -> PageResult {
        var result = PageResult()
        let maxBytes = Self.fetchLimit(settings)
        for header in headers {
            guard !stopping, !clearing else { result.complete = false; break }
            // A skipped message listed again (allowlisted or not any more): it leaves the count.
            if !watched.isEmpty {
                let key = Self.refKey(header.ref)
                if watched.contains(key) { result.listedAgain.append(key) }
            }
            // Allowlist (address part only). Anything else is forgotten right here.
            guard SenderMatcher.match(address: header.fromAddress, rules: settings.senders) != nil else { continue }
            let key = Self.refKey(header.ref)
            if let mid = header.internetMessageID, (try? await ctx.db.mailMessage(internetMessageID: mid)) != nil {
                retry[key] = nil
                result.didCapture.append(header)            // captured before (another source / earlier run)
                continue
            }
            let nowMs = Self.ms(ctx.now())
            if var rec = retry[key] {
                rec.last = nowMs
                retry[key] = rec
                if !force, let next = rec.next, next > nowMs {
                    result.deferred.append(header.ref)     // waiting for its long backoff
                    continue
                }
            }
            let content: MailContent
            do {
                content = try await source.fetchMessage(header, maxBytes: maxBytes)
            } catch where Self.isPermanentFetchError(error) {
                retry[key] = nil
                Self.log.info("mail sync: an allowlisted message is gone or unreadable — skipped")
                continue
            } catch {
                // Our own shutdown / clear interrupted it: not an attempt.
                if stopping || clearing { result.complete = false; break }
                result.error = error
                var rec = retry[key] ?? RetryRecord(n: 0, first: nowMs, next: nil, last: nowMs)
                rec.n += 1
                rec.last = nowMs
                if rec.n < tuning.maxFetchAttempts {
                    rec.next = nil
                    retry[key] = rec
                    result.complete = false
                    break
                }
                let delay = min(tuning.deferredRetryMax,
                                tuning.deferredRetryMin * pow(2, Double(min(16, rec.n - tuning.maxFetchAttempts))))
                rec.next = nowMs + Int64(delay * 1000)
                retry[key] = rec
                result.deferred.append(header.ref)
                Self.log.error("mail sync: an allowlisted message failed \(rec.n, privacy: .public) times — retried later")
                continue
            }
            retry[key] = nil
            // The full message must still come from an allowlisted address (defence in depth).
            guard let confirmed = SenderMatcher.match(address: content.header.fromAddress, rules: settings.senders) else {
                continue
            }
            let truncated = (header.sizeBytes ?? content.header.sizeBytes ?? 0) > maxBytes
            if let outcome = await capture(content, ref: header.ref, account: account, rule: confirmed,
                                           manual: false, truncated: truncated, settings: settings) {
                if let pk = outcome.newPK { result.captured.append(pk) }
                result.didCapture.append(header)
            } else {
                result.complete = false
                break
            }
        }
        return result
    }

    // MARK: - Fetch retry records (kv mail.cursor.<account>.retry)

    /// One allowlisted message whose fetch failed. Keyed by a hash of its transport ref (the
    /// folder ref is the file name, often the subject — never stored).
    struct RetryRecord: Codable, Sendable, Equatable {
        var n: Int                  // failed attempts
        var first: Int64            // first failure (ms)
        var next: Int64?            // next attempt not before (ms); nil = with the page
        var last: Int64             // last listed (ms)
    }

    /// Records unseen for this long are forgotten (the message is gone or no longer allowlisted).
    static let forgetRetryAfter: TimeInterval = 3 * 86_400

    static func retryKey(_ accountID: String) -> String { accountID + ".retry" }

    static func refKey(_ ref: String) -> String {
        String(FileOps.sha256(of: Data(ref.precomposedStringWithCanonicalMapping.utf8)).prefix(16))
    }

    private func loadRetry(_ id: String) async -> [String: RetryRecord] {
        guard let raw = try? await ctx.db.mailCursor(accountID: Self.retryKey(id))?.value,
              let map = try? JSONDecoder().decode([String: RetryRecord].self, from: Data(raw.utf8)) else { return [:] }
        return map
    }

    private func saveRetry(_ id: String, _ map: [String: RetryRecord]) async {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let value = map.isEmpty ? nil : (try? enc.encode(map)).map { MailCursor(String(decoding: $0, as: UTF8.self)) }
        do {
            try await ctx.db.setMailCursor(accountID: Self.retryKey(id), value)
        } catch {
            Self.log.error("mail sync: retry state not stored (\(String(describing: type(of: error)), privacy: .public))")
        }
    }

    static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

    /// kv `mail.cursor.<account>.skipped`: allowlisted messages dropped by a retry-list cap (a count).
    static func skippedKey(_ accountID: String) -> String { accountID + ".skipped" }
    /// kv `mail.cursor.<account>.skipped.refs`: the counted messages' `refKey`s (hashes — a folder
    /// ref is the file name, often the subject), oldest first, at most `maxSkippedRefs`.
    static func skippedRefsKey(_ accountID: String) -> String { accountID + ".skipped.refs" }
    static let maxSkippedRefs = 5000

    private func loadSkippedRefs(_ id: String) async -> [String] {
        guard let raw = try? await ctx.db.mailCursor(accountID: Self.skippedRefsKey(id))?.value,
              let list = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) else { return [] }
        return list
    }

    private func saveSkipped(_ id: String, _ n: Int, refs: [String]) async {
        let encoded = refs.isEmpty ? nil : (try? JSONEncoder().encode(refs)).map { MailCursor(String(decoding: $0, as: UTF8.self)) }
        do {
            try await ctx.db.transaction { db in
                try db.setMailCursor(accountID: MailSyncActor.skippedKey(id), n > 0 ? MailCursor(String(n)) : nil)
                try db.setMailCursor(accountID: MailSyncActor.skippedRefsKey(id), encoded)
            }
        } catch {
            Self.log.error("mail sync: skipped count not stored (\(String(describing: type(of: error)), privacy: .public))")
        }
    }

    // MARK: - Capture (steps 5–6)

    private struct CaptureOutcome {
        var id: String
        var newPK: Int64?          // nil = already captured (duplicate)
    }

    /// Extracts, triages locally, stores attachments and inserts the message + rows (and its
    /// post-processing marker) in one transaction. Nil only when the insert failed for another
    /// reason than a duplicate.
    private func capture(_ content: MailContent, ref: String, account: MailAccount?, rule: SenderRule?,
                         manual: Bool, truncated: Bool, settings: MailSettings) async -> CaptureOutcome? {
        let es = await ctx.settings()
        let lang = es.lang
        let now = ctx.now()
        let calendar = ctx.calendar
        let kind: SenderKind = rule.map { $0.kind == .manual ? .person : $0.kind } ?? .manual
        let messageKey = content.header.internetMessageID
            ?? MIMEParser.fallbackMessageID(from: content.header.fromAddress, date: "", subject: content.header.subject)
        if let existing = try? await ctx.db.mailMessage(internetMessageID: messageKey) {
            return CaptureOutcome(id: existing.id, newPK: nil)
        }
        let criteria = settings.criteria
        let dateOrder = settings.dateOrder
        let (extraction, heuristic, relevance) = await BlockingIO.run { () -> (MailExtraction, MailTriage, [String: MailItemRelevance]) in
            let x = MailExtractor.extract(content, senderKind: kind, bodyCap: MailExtractor.defaultBodyCap)
            let (t, r) = MailHeuristics.triage(content: content, extraction: x, senderKind: kind, criteria: criteria,
                                               now: now, calendar: calendar, lang: lang, dateOrder: dateOrder)
            return (x, t, r)
        }
        let messageID = UUID().uuidString.lowercased()
        let storeAttachments = manual || (rule?.autoDownload ?? true)

        let numbered = extraction.candidates.enumerated().map { (ord: $0.offset + 1, candidate: $0.element) }
        var items = await makeItems(numbered, content: content, messageID: messageID, relevance: relevance,
                                    store: storeAttachments, truncated: truncated, settings: settings, lang: lang, now: now)
        await matchLibrary(&items)

        let state = Self.capturedState(manual: manual, heuristic: heuristic, candidates: extraction.candidates,
                                       senderKind: kind, criteria: criteria)
        let authState = MIMEParser.authState(content.header.authResults ?? content.headers["authentication-results"])
        let bulk = Self.isBulk(content.headers)
        let triageState = MailTriageCoordinator.initialState(
            senderKind: kind, rule: rule, candidates: extraction.candidates.count, settings: settings,
            authState: authState, isBulk: bulk,
            confidential: MailHeuristics.isConfidential(content, bodyText: extraction.bodyText))
        let message = MailMessage(
            id: messageID, accountID: account?.id ?? Self.manualAccountID, sourceRef: ref.isEmpty ? nil : ref,
            internetMessageID: messageKey, fromAddress: content.header.fromAddress.lowercased(),
            fromName: content.header.fromName, ruleID: rule?.id, senderKind: kind,
            authState: authState,
            subject: content.header.subject, receivedAt: content.header.receivedAt,
            webLink: account.flatMap { Self.webLink($0, messageID: messageKey) },
            snippet: extraction.snippet.isEmpty ? nil : extraction.snippet,
            bodyText: extraction.bodyText, state: state, triageState: triageState, triageSource: .heuristic,
            triage: heuristic, createdAt: now, updatedAt: now, handledAt: state == .noRequest ? now : nil,
            isBulk: bulk)
        let rows = items
        do {
            // The message, its rows and its post-processing marker commit together: a quit before
            // post-processing finished is picked up at the next start (`recoverPostProcessing`).
            let saved = try await ctx.db.transaction { db -> MailMessage in
                let (saved, _) = try db.insertMailMessage(message, items: rows)
                var pending = MailSyncActor.decodePKs(try db.mailCursor(accountID: MailSyncActor.pendingPostKey)?.value)
                pending.append(saved.pk)
                try db.setMailCursor(accountID: MailSyncActor.pendingPostKey, MailCursor(MailSyncActor.encodePKs(pending)))
                return saved
            }
            return CaptureOutcome(id: saved.id, newPK: saved.pk)
        } catch DatabaseError.duplicate {
            await files.removeFiles(messageID: messageID)
            let existing = try? await ctx.db.mailMessage(internetMessageID: messageKey)
            return existing.map { CaptureOutcome(id: $0.id, newPK: nil) }
        } catch {
            await files.removeFiles(messageID: messageID)
            Self.log.error("mail capture: insert failed (\(String(describing: type(of: error)), privacy: .public))")
            return nil
        }
    }

    /// Where a freshly captured card goes: a dropped `.eml` always to 待处理; else 「无阅读需求」 when
    /// the local triage found no paper-reading need (`notPaper`, or a kind the user doesn't keep) —
    /// except a person's or an advisor's email with a document or a shared-file link
    /// (`MailHeuristics.keepsDocumentPending`), which stays in 待处理.
    package static func capturedState(manual: Bool, heuristic: MailTriage, candidates: [MailCandidate],
                              senderKind: SenderKind, criteria: ReadingCriteria) -> MailState {
        if manual { return .pending }
        if MailHeuristics.keepsDocumentPending(heuristic, candidates: candidates, senderKind: senderKind) { return .pending }
        if heuristic.requestKind == .notPaper || !criteria.keepKinds.contains(heuristic.requestKind) { return .noRequest }
        return .pending
    }

    /// The rows of a message's candidates (`ord`, candidate): PDF attachments and document
    /// originals stored under `mail/files/<messageID>/` (when `store` — the sender rule's
    /// 「自动保存附件」 or a manual drop), links' PDF availability by the local rules. Shared-file
    /// links wait for the user's PDF (they need a sign-in and are never downloaded).
    private func makeItems(_ numbered: [(ord: Int, candidate: MailCandidate)], content: MailContent, messageID: String,
                           relevance: [String: MailItemRelevance], store: Bool, truncated: Bool,
                           settings: MailSettings, lang: UILang, now: Date) async -> [MailItem] {
        let capMB = max(1, settings.maxAttachmentMB)
        var items: [MailItem] = []
        for (ord, c) in numbered {
            var item = MailItem(ord: ord, cand: c.cand, origin: c.origin, foundBy: .local, title: c.title,
                                authors: c.authors, venue: c.venue, year: c.year, ids: c.ids, url: c.url,
                                urlOriginal: c.urlOriginal, host: c.host,
                                relevance: relevance[c.cand] ?? .listed, pdfState: c.pdfState,
                                createdAt: now, updatedAt: now, documentFileName: c.documentFileName,
                                documentKind: c.documentKind, shareHost: c.shareHost)
            if c.origin == .attachment, let index = c.attachmentIndex, content.attachments.indices.contains(index) {
                let attachment = content.attachments[index]
                if store {
                    switch await files.save(attachment, index: index, messageID: messageID,
                                            maxBytes: Self.attachmentCap(settings), truncated: truncated) {
                    case .success(let saved):
                        item.pdfState = .hasPDF
                        item.pdfPath = saved.relativePath
                        item.pdfSHA256 = saved.sha256
                        item.pdfBytes = saved.bytes
                    case .failure(let why):
                        item.pdfState = .needsPDF
                        item.pdfBytes = Int64(attachment.sizeBytes)
                        item.downloadError = why.message(lang, capMB: capMB)
                    }
                } else {
                    item.pdfState = .needsPDF
                    item.pdfBytes = Int64(attachment.sizeBytes)
                    item.downloadError = MailSyncText.attachmentNotStored(lang)
                }
                if item.title == nil { item.title = Self.attachmentTitle(attachment.filename) }
            } else if c.origin == .document, let index = c.attachmentIndex, content.attachments.indices.contains(index) {
                await storeDocument(&item, content.attachments[index], index: index, messageID: messageID, store: store,
                                    truncated: truncated, settings: settings, lang: lang)
            } else if c.origin == .shareLink || c.origin == .document {
                item.pdfState = .needsPDF
            } else if item.pdfState == .unknown {
                item.pdfState = MailPDFFetcher.availability(ids: item.ids, url: item.url, host: item.host)
            }
            items.append(item)
        }
        return items
    }

    /// A document attachment's row: the original stored (`convertible` for Word / RTF / ODT,
    /// `openOnly` for slides / Pages and password-protected files) or why it was not (`needsPDF`).
    private func storeDocument(_ item: inout MailItem, _ attachment: MailAttachment, index: Int, messageID: String,
                               store: Bool, truncated: Bool, settings: MailSettings, lang: UILang) async {
        item.pdfBytes = Int64(attachment.sizeBytes)
        guard let kind = item.documentKind.flatMap(DocumentKind.init(rawValue:)) else {
            item.pdfState = .needsPDF
            return
        }
        guard store else {
            item.pdfState = .needsPDF
            item.downloadError = MailSyncText.documentNotStored(lang)
            return
        }
        switch await files.saveDocument(attachment, kind: kind, index: index, messageID: messageID,
                                        maxBytes: Self.attachmentCap(settings), truncated: truncated) {
        case .success(let saved):
            item.documentPath = saved.relativePath
            item.documentSHA256 = saved.sha256
            item.pdfBytes = saved.bytes
            item.pdfState = saved.encrypted ? .openOnly : kind.pdfState
            item.downloadError = saved.encrypted ? DocumentConversionError.encrypted.message(lang) : nil
        case .failure(let why):
            item.pdfState = .needsPDF
            item.downloadError = why.documentMessage(lang, capMB: max(1, settings.maxAttachmentMB))
        }
    }

    /// Mailing-list mail (an alert service's digest): `List-Id` or `List-Unsubscribe` present.
    /// An alert sender's AI-always rule triages only such mail automatically. `Precedence` and
    /// `Auto-Submitted` alone no longer count — manuscript systems and submission desks send
    /// automated, confidential mail with them (round 3, safety-7); that mail is also caught by
    /// `MailHeuristics.isConfidential`. Also used by the Settings ▸ Mail triage preview so both
    /// apply the same rule.
    package static func isBulk(_ headers: [String: String]) -> Bool {
        func present(_ name: String) -> Bool {
            !(headers[name]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        return present("list-id") || present("list-unsubscribe")
    }

    /// Exact bytes (SHA-256) or the same work (DOI incl. bioRxiv prefixes / arXiv / published DOI)
    /// already in the library → `inLibrary` + the paper's id.
    private func matchLibrary(_ items: inout [MailItem]) async {
        for i in items.indices where items[i].status == .pending && items[i].paperID == nil {
            var match: Paper?
            if let sha = items[i].pdfSHA256, let p = try? await ctx.db.paper(sha256: sha), p.isLive { match = p }
            if match == nil {
                let ids = items[i].ids
                if !ids.isEmpty || ids.publishedDOI != nil {
                    match = try? await ctx.db.paperMatchingWork(doi: ids.doi, arxivID: ids.arxivID,
                                                                publishedDOI: ids.publishedDOI)
                }
            }
            if let p = match {
                items[i].pdfState = .inLibrary
                items[i].paperID = p.id
            }
        }
    }

    // MARK: - One-time re-evaluation: documents and shared files (kv `mail.reevaluate.documents.v1`)

    /// kv key of the one-time re-evaluation after the upgrade that taught the extractor documents
    /// and shared-file links: "done", or "tries=<n>" while sources were not reachable.
    package static let reevaluateDocumentsKey = "mail.reevaluate.documents.v1"
    /// Passes with unreachable sources before the job gives up.
    static let reevaluateMaxTries = 5
    /// Newest eligible messages looked at (one pass).
    static let reevaluateLimit = 300

    /// What one re-evaluation pass did (counts only — logged, never content).
    package struct ReevaluationReport: Sendable, Equatable {
        package var examined = 0        // eligible messages fetched (or tried)
        package var updated = 0         // gained document / shared-file rows
        package var unchanged = 0       // nothing new in the original
        package var gone = 0            // the source no longer has it (skipped for good)
        package var failed = 0          // the source was not reachable (retried at a later pass)
        package var notYet = 0          // its account has not been checked since launch (waits, no attempt)
        package init() {}
    }

    /// Runs the re-evaluation once per library (after the accounts synced in a pass); a pass whose
    /// sources were not reachable is retried at the next pass, up to `reevaluateMaxTries`. Messages
    /// of accounts not checked since launch (manual-only sync, nothing synced yet) wait without
    /// counting as an attempt.
    private func reevaluateDocumentsIfNeeded(_ settings: MailSettings) async {
        guard !reevaluationSettled, !stopping, !clearing else { return }
        let stored = (try? await ctx.db.kv(Self.reevaluateDocumentsKey)) ?? nil
        if stored == "done" {
            reevaluationSettled = true
            return
        }
        let tries = stored.flatMap { $0.hasPrefix("tries=") ? Int($0.dropFirst(6)) : nil } ?? 0
        let report = await reevaluateDocuments(settings)
        guard !stopping, !clearing else { return }                   // interrupted: the next pass starts over
        if report.failed == 0, report.notYet > 0 { return }          // waits for its accounts' first sync
        let finished = report.failed == 0 || tries + 1 >= Self.reevaluateMaxTries
        do {
            try await ctx.db.setKV(Self.reevaluateDocumentsKey, finished ? "done" : "tries=\(tries + 1)")
        } catch {
            Self.log.error("mail re-evaluation: state not stored (\(String(describing: type(of: error)), privacy: .public))")
        }
        reevaluationSettled = finished
        Self.log.info("mail re-evaluation (documents): \(report.examined, privacy: .public) examined, \(report.updated, privacy: .public) updated, \(report.unchanged, privacy: .public) unchanged, \(report.gone, privacy: .public) gone, \(report.failed, privacy: .public) unreachable, \(report.notYet, privacy: .public) waiting")
    }

    /// Whether a stored message is re-evaluated: from a person or an advisor still on the sender
    /// list, captured from a mail account (a dropped `.eml` has no source to read again), never
    /// touched by the user, and either in 「无阅读需求」 or in 待处理 without any row — and without
    /// document / shared-file rows already (the job is idempotent).
    static func isReevaluationCandidate(_ m: MailMessage, items: [MailItem], settings: MailSettings) -> Bool {
        guard !m.userTouched, m.senderKind == .advisor || m.senderKind == .person,
              m.accountID != manualAccountID, let ref = m.sourceRef, !ref.isEmpty,
              SenderMatcher.match(address: m.fromAddress, rules: settings.senders) != nil else { return false }
        guard m.state == .noRequest || (m.state == .pending && items.isEmpty) else { return false }
        return !items.contains { $0.origin == .document || $0.origin == .shareLink }
    }

    /// One pass: every eligible message (`isReevaluationCandidate`, newest first, at most
    /// `reevaluateLimit`) is read again from its account — a folder account's `.eml` by its stored
    /// file name, an IMAP message by its UID (read-only) — when the source still has it, and its
    /// local extraction runs again. Messages gaining document / shared-file rows get them (originals
    /// stored like at capture), a fresh local triage (an AI triage stays) and — a person's or an
    /// advisor's document — go back to 待处理. Nothing is sent to AI (at most 「让 AI 分析」 is
    /// offered); a card the user touched meanwhile is left alone.
    package func reevaluateDocuments(_ settings: MailSettings) async -> ReevaluationReport {
        var report = ReevaluationReport()
        guard settings.enabled, !stopping, !clearing else { return report }
        reconcileAccounts(settings)                         // the sources of the current account list
        let heads: [MailMessage]
        do {
            heads = try await ctx.db.mailMessageHeads(states: [.noRequest, .pending], limit: 100_000).map(\.message)
        } catch {
            report.failed += 1
            return report
        }
        let pre = heads.filter { !$0.userTouched && ($0.senderKind == .advisor || $0.senderKind == .person)
            && $0.accountID != Self.manualAccountID && $0.sourceRef != nil }
        guard !pre.isEmpty else { return report }
        let rows = (try? await ctx.db.mailItems(messagePKs: pre.map(\.pk))) ?? [:]
        let eligible = pre.filter { Self.isReevaluationCandidate($0, items: rows[$0.pk] ?? [], settings: settings) }
            .prefix(Self.reevaluateLimit)
        for m in eligible {
            guard !stopping, !clearing else { break }
            let outcome = await reevaluate(m, settings: settings)
            if outcome != .notYet { report.examined += 1 }
            switch outcome {
            case .updated: report.updated += 1
            case .unchanged: report.unchanged += 1
            case .gone: report.gone += 1
            case .unreachable: report.failed += 1
            case .notYet: report.notYet += 1
            }
        }
        return report
    }

    private enum ReevaluationOutcome { case updated, unchanged, gone, unreachable, notYet }

    private func reevaluate(_ m: MailMessage, settings: MailSettings) async -> ReevaluationOutcome {
        guard let ref = m.sourceRef, let st = accounts[m.accountID] else { return .gone }       // account removed
        // A disabled account or one waiting for new sign-in details is not asked (never retry a
        // rejected password); a source that isn't ready is not reachable now.
        guard st.account.enabled else { return .gone }
        guard let status = st.status else { return .notYet }
        guard !st.waitingForSettings, case .ready = status.render(lang) else { return .unreachable }
        let maxBytes = Self.fetchLimit(settings)
        let header = MailHeader(ref: ref, internetMessageID: m.internetMessageID, fromAddress: m.fromAddress,
                                fromName: m.fromName, subject: m.subject, receivedAt: m.receivedAt)
        let content: MailContent
        do {
            content = try await st.source.fetchMessage(header, maxBytes: maxBytes)
        } catch where Self.isPermanentFetchError(error) {
            return .gone
        } catch {
            return .unreachable
        }
        // Still the same, still allowlisted message (a folder file may have been replaced).
        let parsedID = content.header.internetMessageID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard parsedID == m.internetMessageID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              SenderMatcher.match(address: content.header.fromAddress, rules: settings.senders) != nil else {
            return .gone
        }
        let uiLang = await ctx.settings().lang
        let now = ctx.now(), calendar = ctx.calendar
        let kind = m.senderKind, criteria = settings.criteria, dateOrder = settings.dateOrder
        let (extraction, heuristic, relevance) = await BlockingIO.run { () -> (MailExtraction, MailTriage, [String: MailItemRelevance]) in
            let x = MailExtractor.extract(content, senderKind: kind, bodyCap: MailExtractor.defaultBodyCap)
            let (t, r) = MailHeuristics.triage(content: content, extraction: x, senderKind: kind, criteria: criteria,
                                               now: now, calendar: calendar, lang: uiLang, dateOrder: dateOrder)
            return (x, t, r)
        }
        let fresh = extraction.candidates.filter { $0.origin == .document || $0.origin == .shareLink }
        guard !fresh.isEmpty, !stopping, !clearing else { return .unchanged }

        let existing = (try? await ctx.db.mailItems(messagePK: m.pk)) ?? []
        // A card without rows takes the extraction's numbering (its body markers name them); rows
        // added to a card that has some continue its numbering.
        let renumber = existing.isEmpty
        let lastOrd = existing.map(\.ord).max() ?? 0
        let numbered: [(ord: Int, candidate: MailCandidate)]
        if renumber {
            numbered = extraction.candidates.enumerated().map { (ord: $0.offset + 1, candidate: $0.element) }
        } else {
            let used = Set(existing.map { $0.cand.lowercased() })
            var next = existing.count + 1
            numbered = fresh.enumerated().map { k, c in
                var c = c
                while used.contains("c\(next)") { next += 1 }
                c.cand = "c\(next)"
                next += 1
                return (ord: lastOrd + k + 1, candidate: c)
            }
        }
        let freshRelevance = renumber ? relevance
            : Dictionary(uniqueKeysWithValues: zip(numbered.map(\.candidate.cand), fresh.map { relevance[$0.cand] ?? .listed }))
        let rule = settings.rule(id: m.ruleID)
        // The transports read at most `maxBytes`: a message that filled it may have been cut.
        let truncated = (content.header.sizeBytes ?? 0) >= maxBytes
        let items = await makeItems(numbered, content: content, messageID: m.id, relevance: freshRelevance,
                                    store: rule?.autoDownload ?? true, truncated: truncated, settings: settings,
                                    lang: uiLang, now: now)
        let keep = MailHeuristics.keepsDocumentPending(heuristic, candidates: extraction.candidates, senderKind: kind)
        let confidential = MailHeuristics.isConfidential(content, bodyText: extraction.bodyText)
        let offer = MailTriageCoordinator.initialState(senderKind: kind, rule: rule, candidates: extraction.candidates.count,
                                                       settings: settings, authState: m.authState, isBulk: m.isBulk ?? false,
                                                       confidential: confidential) == .awaitingConsent
        let stored: Bool
        do {
            stored = try await ctx.db.transaction { db -> Bool in
                // Re-checked on the current rows: the user may have acted meanwhile.
                guard var cur = try db.mailMessage(pk: m.pk),
                      MailSyncActor.isReevaluationCandidate(cur, items: try db.mailItems(messagePK: m.pk), settings: settings),
                      try db.mailItems(messagePK: m.pk).count == existing.count else { return false }
                for item in items {
                    var row = item
                    row.messagePK = m.pk
                    try db.upsertMailItem(row, now: now)
                }
                if cur.triageSource != .ai {
                    cur.triage = heuristic
                    cur.triageSource = .heuristic
                }
                if renumber, !cur.bodyPurged {
                    cur.bodyText = extraction.bodyText
                    cur.snippet = extraction.snippet.isEmpty ? nil : extraction.snippet
                }
                if keep, cur.state == .noRequest {
                    cur.state = .pending
                    cur.handledAt = nil
                }
                // Never queued here: at most the card offers 「让 AI 分析」 now that it has something to analyse.
                if offer, cur.triageState == .none || cur.triageState == .skipped { cur.triageState = .awaitingConsent }
                try db.updateMailMessage(cur, now: now)
                return true
            }
        } catch {
            Self.log.error("mail#\(m.pk, privacy: .public): re-evaluation not stored")
            stored = false
        }
        if !stored {
            // Rows that were not inserted leave no stored originals behind.
            let paths = items.compactMap(\.documentPath) + items.compactMap(\.pdfPath)
            let root = files.root
            if !paths.isEmpty { await BlockingIO.run { MailAttachmentFiles.remove(paths, root: root) } }
            return .unchanged
        }
        return .updated
    }

    // MARK: - Post-processing (step 7)

    /// kv `mail.cursor.~postprocess`: pks of captured messages whose post-processing has not
    /// finished (written in the capture transaction, cleared after `messageReady` and the ready
    /// hook — and only once the triage hand-off happened or the row left `queued`). Under the
    /// cursor prefix, so 「清除所有邮件数据」 clears it with the rest. The only such key.
    static let pendingPostKey = "~postprocess"
    /// Passes an owed hand-off is retried in (hand-off only) before the message offers
    /// 「让 AI 分析」 instead (`MailTriageCoordinator.giveUpHandOff`).
    static let maxHandOffRetries = 3

    static func encodePKs(_ pks: [Int64]) -> String { pks.map(String.init).joined(separator: ",") }

    static func decodePKs(_ raw: String?) -> [Int64] {
        guard let raw else { return [] }
        var seen = Set<Int64>()
        return raw.split(separator: ",").compactMap { Int64($0) }.filter { seen.insert($0).inserted }
    }

    /// Launch: messages committed but not post-processed before the last quit (or crash) run
    /// the normal post-processing again — enrichment, library matching, `messageReady` (the
    /// triage hand-off, which counts toward the daily cap) and the sender rule's auto-merge.
    private func recoverPostProcessing() async {
        let pks = Self.decodePKs((try? await ctx.db.mailCursor(accountID: Self.pendingPostKey))?.value)
        guard !pks.isEmpty, !stopping else { return }
        Self.log.info("mail: \(pks.count, privacy: .public) captured email(s) resume post-processing")
        for pk in pks where !postQueue.contains(pk) { enqueuePost(pk) }
    }

    private func postProcessed(_ pk: Int64) async {
        do {
            try await ctx.db.transaction { db in
                let pending = MailSyncActor.decodePKs(try db.mailCursor(accountID: MailSyncActor.pendingPostKey)?.value)
                guard pending.contains(pk) else { return }
                let rest = pending.filter { $0 != pk }
                try db.setMailCursor(accountID: MailSyncActor.pendingPostKey,
                                     rest.isEmpty ? nil : MailCursor(MailSyncActor.encodePKs(rest)))
            }
        } catch {
            Self.log.error("mail#\(pk, privacy: .public): post-processing marker not cleared")
        }
    }

    private func enqueuePost(_ pk: Int64) {
        guard !stopping, !clearing else { return }
        postQueue.append(pk)
        guard postTask == nil else { return }
        postTask = Task { await self.drainPost() }
    }

    private func drainPost() async {
        while !stopping, !clearing, !Task.isCancelled, !postQueue.isEmpty {
            let pk = postQueue.removeFirst()
            postCurrent = pk
            await postProcess(pk, handOffOnly: handOffOnly.remove(pk) != nil, titlesOnly: titlesOnly.remove(pk) != nil)
            postCurrent = nil
        }
        postTask = nil
        if !stopping, !clearing, !postQueue.isEmpty {
            postTask = Task { await self.drainPost() }        // queued while a cancelled worker wound down
            return
        }
        resumeIdleWaiters()
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters = []
        for w in waiters { w.resume() }
    }

    /// The triage hand-off of a post-processed message is still owed: the row is `queued` and
    /// was never handed to the lane (no stdin size) — `buildJob` threw, the DB write failed, or
    /// the coordinator stopped at quit. A read error counts as owed (retried, never lost).
    private func handOffOwed(_ pk: Int64) async -> Bool {
        do {
            guard let m = try await ctx.db.mailMessage(pk: pk) else { return false }
            return m.triageState == .queued && m.triageStdinBytes == nil
        } catch {
            return true
        }
    }

    /// Owed hand-offs (see `handOffOwed`) get another try at each pass — hand-off only, the
    /// enrichment already ran — up to `maxHandOffRetries`; then the message offers 「让 AI 分析」
    /// and its marker goes. At quit the marker stays and the next launch post-processes it again.
    private func retryOwedHandOffs() async {
        for (pk, n) in handOffRetries.sorted(by: { $0.key < $1.key }) {
            guard !stopping, !clearing, !postQueue.contains(pk), postCurrent != pk else { continue }
            if n >= Self.maxHandOffRetries {
                handOffRetries[pk] = nil
                await triage.giveUpHandOff(pk: pk)
                if !(await handOffOwed(pk)) { await postProcessed(pk) }
                Self.log.error("mail#\(pk, privacy: .public): triage hand-off kept failing — waiting for 让 AI 分析")
            } else {
                handOffOnly.insert(pk)
                enqueuePost(pk)
            }
        }
    }

    private func postProcess(_ pk: Int64, handOffOnly retry: Bool = false, titlesOnly: Bool = false) async {
        if titlesOnly { await lookUpHeldTitles(pk) }
        if retry {
            guard !stopping, !clearing, !Task.isCancelled else { return }
            await finishPostProcessing(pk, ruleID: nil, runHook: false)
            return
        }
        if titlesOnly { return }
        let message: MailMessage
        do {
            guard let m = try await ctx.db.mailMessage(pk: pk) else {
                await postProcessed(pk)                     // gone (cleared): nothing left to do
                return
            }
            message = m
        } catch {
            return                                          // retried at the next start
        }
        let items = (try? await ctx.db.mailItems(messagePK: pk)) ?? []
        var updated: [String: MailItem] = [:]
        // First page of stored PDFs: identifiers + a local title.
        for item in items where item.pdfPath != nil && item.status == .pending {
            guard let path = item.pdfPath, let page = await files.firstPage(relativePath: path) else { continue }
            var u = updated[item.id] ?? item
            u.ids = u.ids.merged(with: page.ids)
            if let t = page.title, u.metaSource == .none { u.title = t; u.metaSource = .pdf }
            updated[item.id] = u
        }
        // Metadata (bounded concurrency; the shared HostGate spaces requests per host). Titles go
        // out only when `mayLookUpTitles` says so: identifier lookups (a DOI / arXiv id from the
        // mail) always may, a title search not for confidential mail, nor — before 「让 AI 分析」 —
        // for a person's, an advisor's or a dropped email (the title may be unpublished work).
        let es = await ctx.settings()
        if let resolver = resolverFactory(es), !stopping, !clearing {
            let titles = Self.mayLookUpTitles(message)
            let current = items.map { updated[$0.id] ?? $0 }
            let lookups = Self.lookupTargets(current, titles: titles)
            let results = await Self.resolveAll(lookups, resolver: resolver, width: tuning.metadataConcurrency,
                                                timeout: tuning.metadataTimeout, titles: titles)
            Self.apply(results, to: &updated, items: items)
            if !titles, lookups.count < Self.lookupTargets(current).count {
                Self.log.info("mail#\(pk, privacy: .public): title-only metadata lookups held (confidential, or no 让 AI 分析 yet)")
            }
        }
        await storeLookedUp(updated, messagePK: pk)
        guard !stopping, !clearing, !Task.isCancelled else { return }      // finished at the next start
        await finishPostProcessing(pk, ruleID: message.ruleID, runHook: true)
    }

    /// Whether a message's titles may go to the metadata services (Crossref / OpenAlex title
    /// search — also the fallback of an identifier lookup that finds nothing). Never for
    /// confidential mail (`MailHeuristics.isConfidential`: a manuscript under review, a reviewer
    /// invitation, the user's own unposted or accepted-but-unpublished paper); for a person's, an
    /// advisor's or a dropped (`manual`) email only once the user asked for 「让 AI 分析」 on it —
    /// an attachment's title may be unpublished work. Alert digests list published papers — but
    /// only mailing-list mail is a digest (`isBulk`): a message an alert rule matched that isn't
    /// (an editor's or a person's own mail from a journal's domain, an attachment and all) waits
    /// for 「让 AI 分析」 like a person's. Messages captured before `isBulk` was recorded count as
    /// digests, as they always did. Identifier lookups (a DOI / arXiv id already in the mail) are
    /// always allowed.
    package static func mayLookUpTitles(_ m: MailMessage) -> Bool {
        if MailHeuristics.isConfidential(m) { return false }
        switch m.senderKind {
        case .alert: return m.isBulk != false || m.triageConsented
        case .advisor, .person, .manual: return m.triageConsented
        }
    }

    /// Whether post-processing already ran the message's title lookups (a published digest), so
    /// a later consent has nothing held to release.
    static func titlesRanWithPostProcessing(_ m: MailMessage) -> Bool {
        m.senderKind == .alert && m.isBulk != false
    }

    /// 「让 AI 分析」 was accepted for this email (`Engine.requestMailAI`): the title-only lookups its
    /// post-processing held back (`mayLookUpTitles`) run now — queued like post-processing, so
    /// nothing runs during 「清除所有邮件数据」. Confidential mail stays held. A message whose
    /// post-processing is still queued does them there (it reads the consent itself).
    package func consentGiven(messagePK pk: Int64) {
        guard !stopping, !clearing else { return }
        if postQueue.contains(pk) {
            if handOffOnly.contains(pk) { titlesOnly.insert(pk) }     // a hand-off retry: add the lookups
            return
        }
        titlesOnly.insert(pk)
        enqueuePost(pk)
    }

    /// The held title-only lookups of one message (`consentGiven`), when they may run now (a
    /// published digest's ran with its post-processing; an alert rule's non-list mail was held).
    private func lookUpHeldTitles(_ pk: Int64) async {
        guard !stopping, !clearing, !Task.isCancelled,
              let message = try? await ctx.db.mailMessage(pk: pk), !Self.titlesRanWithPostProcessing(message),
              Self.mayLookUpTitles(message), let resolver = resolverFactory(await ctx.settings()) else { return }
        let items = (try? await ctx.db.mailItems(messagePK: pk)) ?? []
        let lookups = Self.lookupTargets(items).filter { $0.ids.isEmpty }    // identifier rows ran already
        guard !lookups.isEmpty else { return }
        let results = await Self.resolveAll(lookups, resolver: resolver, width: tuning.metadataConcurrency,
                                            timeout: tuning.metadataTimeout, titles: true)
        var updated: [String: MailItem] = [:]
        Self.apply(results, to: &updated, items: items)
        guard !stopping, !clearing else { return }
        await storeLookedUp(updated, messagePK: pk)
    }

    /// Lookup results onto the rows (`updated` wins over the stored `items`).
    private static func apply(_ results: [String: BiblioMetadata], to updated: inout [String: MailItem], items: [MailItem]) {
        for (id, meta) in results {
            guard var u = updated[id] ?? items.first(where: { $0.id == id }) else { continue }
            if let t = meta.title { u.title = t }
            if !meta.authors.isEmpty { u.authors = meta.authors }
            u.venue = meta.venue ?? u.venue
            u.year = meta.year ?? u.year
            u.ids = u.ids.merged(with: meta.ids)
            u.metaSource = meta.source
            updated[id] = u
        }
    }

    /// Library matches and PDF availability with the new identifiers, then stored.
    private func storeLookedUp(_ updated: [String: MailItem], messagePK pk: Int64) async {
        var changed = Array(updated.values)
        await matchLibrary(&changed)
        for i in changed.indices where changed[i].pdfState == .needsPDF || changed[i].pdfState == .unknown {
            guard changed[i].origin != .attachment, changed[i].origin != .citation, changed[i].origin != .document,
                  changed[i].origin != .shareLink else { continue }
            changed[i].pdfState = MailPDFFetcher.availability(ids: changed[i].ids, url: changed[i].url, host: changed[i].host)
        }
        if !changed.isEmpty { await storeEnrichment(changed, messagePK: pk) }
    }

    /// `messageReady` (the triage hand-off) and the ready hook (auto-merge); the marker is
    /// cleared only when no hand-off is owed any more (`handOffOwed`) — otherwise the message is
    /// retried at the next pass (and, after a quit, at the next launch).
    private func finishPostProcessing(_ pk: Int64, ruleID: String?, runHook: Bool) async {
        await triage.messageReady(pk: pk)
        if runHook, let handler = onMessageReady,
           let fresh = try? await ctx.db.mailMessage(pk: pk), fresh.state == .pending, !fresh.userTouched {
            await handler(fresh, loadMailSettings().rule(id: ruleID))
        }
        if await handOffOwed(pk) {
            guard !stopping, !clearing else { return }                    // quit: the next launch retries
            handOffRetries[pk, default: 0] += 1
            Self.log.info("mail#\(pk, privacy: .public): triage hand-off owed — retried at the next pass")
            return
        }
        handOffRetries[pk] = nil
        await postProcessed(pk)
    }

    /// Which rows get a metadata lookup: rows with identifiers first, then (a few) title-only
    /// rows that matter (attachments, requested / highlighted entries) — only when `titles`
    /// (`mayLookUpTitles`). Documents and shared-file links never: their "titles" are file names
    /// or link texts of possibly unpublished work.
    static func lookupTargets(_ items: [MailItem], titles: Bool = true) -> [MailItem] {
        let open = items.filter { $0.status == .pending && $0.metaSource != .crossref && $0.metaSource != .arxiv
            && $0.metaSource != .biorxiv && $0.metaSource != .openalex
            && $0.origin != .document && $0.origin != .shareLink }
        let withIDs = open.filter { !$0.ids.isEmpty }
        let titleOnly = !titles ? [] : open.filter {
            $0.ids.isEmpty && ($0.title?.count ?? 0) >= 12
                && ($0.origin == .attachment || $0.relevance == .requested || $0.relevance == .highlighted)
        }
        return Array((withIDs + titleOnly.prefix(maxTitleLookupsPerMessage)).prefix(maxLookupsPerMessage))
    }

    /// `titles: false`: identifiers only — no title is sent, not even as the fallback search.
    private static func resolveAll(_ items: [MailItem], resolver: MetadataResolver, width: Int,
                                   timeout: TimeInterval, titles: Bool) async -> [String: BiblioMetadata] {
        guard !items.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, BiblioMetadata?).self) { group in
            var out: [String: BiblioMetadata] = [:]
            var next = 0
            func add() {
                let item = items[next]
                next += 1
                group.addTask {
                    (item.id, await resolver.resolve(ids: item.ids, titleGuess: titles ? item.title : nil,
                                                     firstAuthorGuess: titles ? item.authors.first : nil,
                                                     timeout: timeout))
                }
            }
            while next < min(width, items.count) { add() }
            while let (id, meta) = await group.next() {
                if let meta { out[id] = meta }
                if next < items.count, !Task.isCancelled { add() }
            }
            return out
        }
    }

    /// Writes enrichment onto the current rows (read-modify-write in one transaction): a row the
    /// user acted on meanwhile (merged / linked / skipped) keeps everything.
    private func storeEnrichment(_ rows: [MailItem], messagePK: Int64) async {
        let now = ctx.now()
        do {
            try await ctx.db.transaction { db in
                for row in rows {
                    guard var cur = try db.mailItem(id: row.id), cur.status == .pending else { continue }
                    let before = cur
                    cur.title = row.title ?? cur.title
                    cur.authors = row.authors.isEmpty ? cur.authors : row.authors
                    cur.venue = row.venue ?? cur.venue
                    cur.year = row.year ?? cur.year
                    cur.ids = row.ids.merged(with: cur.ids)
                    if row.metaSource != .none { cur.metaSource = row.metaSource }
                    if cur.pdfState != .downloading, cur.pdfState != .hasPDF || row.pdfState == .inLibrary {
                        cur.pdfState = row.pdfState
                    }
                    if cur.paperID == nil { cur.paperID = row.paperID }
                    if cur != before { try db.upsertMailItem(cur, now: now) }
                }
            }
        } catch {
            Self.log.error("mail#\(messagePK, privacy: .public): enrichment not stored")
        }
    }

    // MARK: - Nap / poke

    private func nap(_ duration: Duration) async {
        if wakePending || stopping {
            wakePending = false
            return
        }
        napToken &+= 1
        let token = napToken
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            napContinuation = c
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

    private func resumeCycleWaiters() {
        let waiters = cycleWaiters
        cycleWaiters = []
        for w in waiters { w.resume() }
    }

    private func resumeCycleEndWaiters() {
        let waiters = cycleEndWaiters
        cycleEndWaiters = []
        for w in waiters { w.resume() }
    }

    private func resumeClearWaiters() {
        let waiters = clearWaiters
        clearWaiters = []
        for w in waiters { w.resume() }
    }

    // MARK: - Helpers

    /// Attachment cap from Settings (MB → bytes).
    static func attachmentCap(_ s: MailSettings) -> Int { max(1, s.maxAttachmentMB) << 20 }

    /// Whole-message fetch limit: the attachment cap in base64 plus room for the text parts.
    static func fetchLimit(_ s: MailSettings) -> Int { attachmentCap(s) / 3 * 4 + (2 << 20) }

    static func fingerprintKey(_ accountID: String) -> String { accountID + ".config" }

    /// What the cursor is valid for: a new folder, server, user or mailbox starts over (with the lookback).
    static func fingerprint(_ a: MailAccount) -> String {
        switch a.kind {
        case .folder:
            return "folder|" + (a.folderPath ?? "")
        case .imap:
            let host = a.host?.lowercased() ?? a.imapPreset?.host ?? ""
            return "imap|\(host)|\(a.port ?? a.imapPreset?.port ?? 993)|\(a.username?.lowercased() ?? "")|\(a.mailbox ?? "INBOX")"
        }
    }

    static func sendersKey(_ accountID: String) -> String { accountID + ".senders" }

    /// The enabled sender patterns the cursor was listed with, canonical and sorted, one per
    /// line ("a:prof@x.edu", "d:biorxiv.org", "w:nature.com"). Patterns only — the addresses
    /// the user typed into Settings, never anything from mail.
    static func sendersFingerprint(_ rules: [SenderRule]) -> String {
        Set(rules.filter(\.enabled).compactMap { SenderMatcher.Pattern($0.pattern) }.map(patternKey))
            .sorted().joined(separator: "\n")
    }

    private static func patternKey(_ p: SenderMatcher.Pattern) -> String {
        switch p {
        case .address(let a): return "a:" + a
        case .domain(let d): return "d:" + d
        case .wildcard(let w): return "w:" + w
        }
    }

    /// Whether mail listed with the `saved` sender set already went through every sender that
    /// `current` allows (each current pattern is matched by a saved one at least as broad). Nil
    /// `saved` (an older cursor): unknown, so no.
    static func sendersCovered(saved: String?, current: String) -> Bool {
        guard let saved else { return false }
        func parse(_ s: String) -> [(kind: Character, value: String)] {
            s.split(separator: "\n").compactMap { line in
                guard line.count > 2, line.dropFirst().first == ":" else { return nil }
                return (line.first!, String(line.dropFirst(2)))
            }
        }
        let have = parse(saved)
        func within(_ domain: String, wildcard w: String) -> Bool { domain == w || domain.hasSuffix("." + w) }
        return parse(current).allSatisfy { cur in
            have.contains { old in
                switch (cur.kind, old.kind) {
                case (_, _) where cur.kind == old.kind && cur.value == old.value: return true
                case ("a", "d"):
                    return cur.value.split(separator: "@").last.map(String.init) == old.value
                case ("a", "w"):
                    return cur.value.split(separator: "@").last.map { within(String($0), wildcard: old.value) } ?? false
                case ("d", "w"), ("w", "w"):
                    return within(cur.value, wildcard: old.value)
                default:
                    return false
                }
            }
        }
    }

    /// "Open in Gmail" for IMAP presets that support a Message-ID search.
    static func webLink(_ account: MailAccount, messageID: String) -> String? {
        guard account.kind == .imap, let base = account.imapPreset?.webMailBase else { return nil }
        let bare = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        guard !bare.isEmpty, !bare.hasSuffix("@paperdeck.invalid") else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~@")
        return bare.addingPercentEncoding(withAllowedCharacters: allowed).map { base + $0 }
    }

    /// "Smith2026_neocortex.pdf" → "Smith2026 neocortex" (shown until the PDF's own title is read).
    static func attachmentTitle(_ filename: String?) -> String? {
        guard var name = filename?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        if name.lowercased().hasSuffix(".pdf") { name = String(name.dropLast(4)) }
        name = name.replacingOccurrences(of: "_", with: " ")
        name = CardSanitizer.clean(name)
        return name.isEmpty ? nil : String(name.prefix(200))
    }

    /// `status(for:account:lang:)`, worded at display time.
    static func localizedStatus(for error: any Error, account: MailAccount) -> MailLocalizedStatus {
        if let e = error as? FolderMailSourceError { return MailLocalizedStatus { FolderMailSource.status(for: e, lang: $0) } }
        if error is IMAPError { return IMAPMailSource.localizedStatus(for: error, account: account) }
        if error is FileOpsError {
            let why = logText(error)
            return MailLocalizedStatus { .unavailable(MailSyncText.readFailed(why, $0)) }
        }
        return MailLocalizedStatus { .unavailable(MailSyncText.syncFailed($0)) }
    }

    /// Settings-facing status for a transport error.
    static func status(for error: any Error, account: MailAccount, lang: UILang) -> MailSourceStatus {
        if let e = error as? FolderMailSourceError { return FolderMailSource.status(for: e, lang: lang) }
        if error is IMAPError {
            let host = account.host ?? account.imapPreset?.host ?? ""
            return IMAPMailSource.status(for: error, host: host, lang: lang)
        }
        if error is FileOpsError { return .unavailable(MailSyncText.readFailed(logText(error), lang)) }
        return .unavailable(MailSyncText.syncFailed(lang))
    }
}

/// Exactly-once resumption of a join (the task finishing vs. the deadline).
private final class JoinOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func install(_ c: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let r = result {
            lock.unlock()
            c.resume(returning: r)
            return
        }
        continuation = c
        lock.unlock()
    }

    func finish(_ value: Bool) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

// MARK: - Text

/// zh/en strings of the mail pipeline (UI default: English). Stored copies of these texts
/// (download errors, triage notes) are shown in the current language by `MailMachineText`.
package enum MailSyncText {
    package static func fetchFailed(_ lang: UILang) -> String {
        lang == .zh ? "部分邮件暂时无法读取，稍后重试" : "Some emails couldn't be read yet — retrying later"
    }
    package static func syncFailed(_ lang: UILang) -> String {
        lang == .zh ? "同步失败，稍后重试" : "Sync failed — retrying later"
    }
    package static func readFailed(_ why: String, _ lang: UILang) -> String {
        lang == .zh ? "无法读取邮件文件（\(why)）" : "Couldn't read the mail file (\(why))"
    }
    /// Allowlisted emails that kept failing to download for over a day (account status suffix).
    package static func undownloadable(_ n: Int, _ lang: UILang) -> String {
        if lang == .zh {
            return "\(n) 封白名单邮件一天多仍无法下载，会继续自动重试；点「立即同步」可马上重试"
        }
        let head = n == 1 ? "1 allowlisted email couldn't be downloaded for over a day"
                          : "\(n) allowlisted emails couldn't be downloaded for over a day"
        return head + " — still retrying; choose Sync Now to retry now"
    }
    /// Allowlisted emails dropped because the account's retry list was full (account status
    /// suffix and `MailAccountSyncInfo.skippedHint`). 「立即同步」 lists the look-back again.
    package static func skippedByCap(_ n: Int, lookbackDays: Int, _ lang: UILang) -> String {
        if lang == .zh {
            let head = "\(n) 封白名单邮件因重试队列已满被跳过"
            return lookbackDays > 0
                ? head + "；点「立即同步」会重新列出最近 \(lookbackDays) 天的邮件（仅邮件头）并补上它们"
                : head + "；请在账户设置中设置回溯天数，再点「立即同步」重新列出"
        }
        let head = n == 1 ? "1 allowlisted email was skipped because the retry list was full"
                          : "\(n) allowlisted emails were skipped because the retry list was full"
        return lookbackDays > 0
            ? head + " — choose Sync Now to list the last \(lookbackDays) day\(lookbackDays == 1 ? "" : "s") again (headers only) and pick them up"
            : head + " — set a look-back period for this account, then choose Sync Now to list it again"
    }
    /// Settings ▸ Mail hint for a folder account with files that are not complete emails (the
    /// Power Automate flow's Create file got the trigger's Body instead of Export email's).
    package static func notEmailFiles(_ n: Int, _ lang: UILang) -> String {
        if lang == .zh {
            return "此文件夹中有 \(n) 个文件不是完整的邮件。请在 Power Automate ▸ Create file 中把 File Content 设为 "
                + "body('Export_email_(V2)')——即 Export email (V2) 的 Body，而不是触发器的 Body。"
        }
        let head = n == 1 ? "1 file in this folder isn't a complete email."
                          : "\(n) files in this folder aren't complete emails."
        return head + " In Power Automate ▸ Create file, set File Content to body('Export_email_(V2)')"
            + " — the Body of Export email (V2), not the trigger's Body."
    }
    package static func attachmentNotStored(_ lang: UILang) -> String {
        lang == .zh ? "此发件人设置为不自动保存附件，请从邮件中下载后拖到这里"
                    : "Attachments from this sender aren't saved automatically. Download the PDF from the email and drop it here."
    }
    package static func documentNotStored(_ lang: UILang) -> String {
        lang == .zh ? "此发件人设置为不自动保存附件：请在邮件中打开文档，导出 PDF 后拖到这里"
                    : "Attachments from this sender aren't saved automatically. Open the document from the email, export a PDF and drop it here."
    }
    package static func bodyPurged(_ lang: UILang) -> String {
        lang == .zh ? "邮件正文已清除，未发送给 AI" : "The email text was removed; nothing was sent to AI"
    }
    package static func dailyCapReached(used: Int, limit: Int, _ lang: UILang) -> String {
        lang == .zh ? "今日 AI 分拣已达上限（\(used)/\(limit)），明天继续"
                    : "Today's AI triage limit is reached (\(used)/\(limit)) — continues tomorrow"
    }
    package static func aiUnavailable(_ lang: UILang) -> String {
        lang == .zh ? "AI 暂不可用 · 邮件未发送给 AI" : "AI isn't available right now · the email was not sent to AI"
    }
    package static func usageLimited(_ until: Date?, _ lang: UILang) -> String {
        lang == .zh ? "AI 用量已达上限，恢复后自动分拣" : "The AI usage limit is reached — triage resumes automatically"
    }
    package static func needsLogin(_ lang: UILang) -> String {
        lang == .zh ? "AI 未登录 · 登录后自动分拣" : "The AI isn't signed in — triage resumes after you sign in"
    }
    package static func triageFailed(_ outcome: AgentOutcome, _ lang: UILang) -> String {
        let zh = lang == .zh
        switch outcome {
        case .timeout: return zh ? "AI 分拣超时" : "AI triage timed out"
        case .overloaded: return zh ? "AI 服务繁忙" : "The AI service is busy"
        case .invalidOutput, .maxTurns: return zh ? "AI 返回的结果无效" : "The AI returned an invalid result"
        default: return zh ? "AI 分拣失败" : "AI triage failed"
        }
    }
}
