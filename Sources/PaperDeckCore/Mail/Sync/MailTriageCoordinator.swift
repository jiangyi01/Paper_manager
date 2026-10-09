import Foundation

/// Today's AI-triage count against `MailSettings.triageDailyMax` (kv `mail.triage.day`).
package struct MailTriageUsage: Sendable, Equatable {
    package var day: LocalDate
    package var used: Int
    package var limit: Int

    package init(day: LocalDate, used: Int, limit: Int) { self.day = day; self.used = used; self.limit = limit }

    package var remaining: Int { max(0, limit - used) }
    package var isExhausted: Bool { used >= limit }
}

/// Why `requestAI` refused (zh/en text via `message(_:)`; never carries mail content).
package enum MailTriageError: Error, Sendable, Equatable {
    case notFound
    case aiDisabled             // Settings ▸ Mail ▸ AI triage = local rules only
    case senderNever            // the sender rule says "never send to AI"
    case bodyPurged             // retention removed the text; nothing left to analyze
    case cardClosed             // the card was dismissed or merged (reopen it first)

    package func message(_ lang: UILang) -> String {
        let zh = lang == .zh
        switch self {
        case .cardClosed:
            return zh ? "这封邮件已忽略或已处理，请先移回「待处理」" : "This email was dismissed or handled — move it back to Pending first"
        case .notFound: return zh ? "找不到这封邮件" : "This email no longer exists"
        case .aiDisabled:
            return zh ? "邮件 AI 分拣已设为「仅本地规则」" : "Mail AI triage is set to local rules only"
        case .senderNever:
            return zh ? "此发件人设置为「从不发送给 AI」" : "This sender is set to never be sent to AI"
        case .bodyPurged:
            return zh ? "邮件正文已按保留期限清除，无法分析" : "The email text was removed by the retention setting"
        }
    }
}

/// What the current settings allow for one message's AI triage (`MailTriageCoordinator.permission`).
package enum MailTriagePermission: Sendable, Equatable {
    /// It may go to the AI: the sender's policy is `always` (and DMARC/DKIM did not fail), or the
    /// user clicked 「让 AI 分析」 for this email and the provider is still the one they agreed to.
    case allowed
    /// Only with the user's consent (policy `ask`, no / deleted rule, a disabled rule, a failed
    /// DMARC/DKIM check, or a consent given for another provider) → `awaitingConsent`.
    case needsConsent
    /// The sender rule says never → `none`.
    case senderNever
    /// Settings ▸ Mail ▸ AI triage = local rules only → `none`.
    case aiOff
}

/// Decides and runs the AI triage of captured mail (MAIL_DESIGN Part A §2 step 10, user
/// decision 3): alerts (rule `always`) go to the AI automatically within the daily cap;
/// people (`ask`) wait for 「让 AI 分析」 (`requestAI`); `never` / `heuristicOnly` never leave
/// the machine. Jobs run in `AgentQueue`'s triage lane (shared slot, gates, pauses, budget);
/// this actor owns the durable `triage_*` state on `mail_message` and applies the results.
///
/// One gate (`permission`) decides every send — the hand-off to the lane, the periodic release
/// of held / failed messages, launch recovery and the withdrawal of lane jobs — always against
/// the settings of that moment: a sender switched to `ask` / `never` (or deleted), AI switched
/// off, or another triage provider takes effect for queued, held, failed, limited and
/// needs-login messages too. A consent (`requestAI`) is stored on the message and bound to the
/// provider the card named. The daily count is durable (kv `mail.triage.day`, with the jobs
/// counted today and not answered yet), so a relaunch neither recounts nor skips counting.
///
/// Mail text and model output are untrusted: results pass `MailTriageSanitizer`, model-only
/// papers become rows only after Crossref / arXiv verification, nothing is downloaded from
/// them, and a user action (`userTouched`) is never overridden.
package actor MailTriageCoordinator {
    package static let dayKey = "mail.triage.day"
    /// Attempts of one message before it stays `failed` (the user can still ask again).
    package static let maxAttempts = 3
    /// Model-only papers verified per result.
    package static let maxVerifiedHints = 8
    /// A triage on its way: handed off or waiting to be (not answered, not refused, not skipped).
    package static let pendingStates: Set<MailTriageState> = [.queued, .running, .held, .failed, .limited, .needsLogin]

    private let ctx: EngineContext
    private let agents: AgentQueue
    private let loadMailSettings: @Sendable () -> MailSettings
    private let resolverFactory: @Sendable (EngineSettings) -> MetadataResolver?
    private let files: MailPDFFetcher

    /// Messages handed to (or being handed to) the lane and not answered yet.
    private var inLane: Set<Int64> = []
    /// The provider each lane job was built for (a switch withdraws jobs built for the old one).
    private var laneProvider: [Int64: AIProviderKind] = [:]
    /// Messages inside `handOff` (between the claim and the lane): a withdrawal that arrives
    /// meanwhile is recorded here and applied when the hand-off ends.
    private var handingOff: Set<Int64> = []
    private var withdrawals: [Int64: Withdrawal] = [:]
    private var verifyTasks: [Int64: Task<Void, Never>] = [:]
    private var statusTask: Task<Void, Never>?
    private var laneLabel: MailTriageState = .queued
    private var lastMode: AgentMode?
    private var started = false
    private var stopping = false

    private enum Withdrawal { case cancel, recheck }

    /// Who asked for a hand-off: the user's 「让 AI 分析」 (not held by the cap), the pipeline /
    /// periodic release (cap applies unless the message runs on the user's consent), or launch
    /// recovery of a job that was in the lane at quit (counted again only on a new day).
    private enum Trigger { case user, auto, recovery }

    package init(ctx: EngineContext, agents: AgentQueue, loadMailSettings: @escaping @Sendable () -> MailSettings,
                 resolverFactory: @escaping @Sendable (EngineSettings) -> MetadataResolver?, files: MailPDFFetcher) {
        self.ctx = ctx; self.agents = agents; self.loadMailSettings = loadMailSettings
        self.resolverFactory = resolverFactory; self.files = files
    }

    // MARK: - Policy (pure)

    /// Triage state a freshly captured message starts in.
    /// - `heuristicOnly` or rule `never` → `none` (local result only);
    /// - rule `always` → `queued` (sent once post-processing finishes, within the daily cap);
    ///   confidential mail (`MailHeuristics.isConfidential`: reviewer invitations, manuscript /
    ///   submission system mail, preprint screening — whatever the sender kind) waits for
    ///   consent; an alert without a single candidate is `skipped` (nothing for the AI to rank); a
    ///   message whose DMARC/DKIM check failed, or an alert-rule message that is not mailing-list
    ///   mail (no List-Id / List-Unsubscribe — an editor's or a person's own mail from an alert
    ///   domain), waits for consent instead;
    /// - rule `ask`, a disabled `always` rule, or a manual drop without a rule → `awaitingConsent`.
    /// The defaults of `authState` / `isBulk` / `confidential` reproduce the behaviour without
    /// that information.
    package nonisolated static func initialState(senderKind: SenderKind, rule: SenderRule?, candidates: Int,
                                                 settings: MailSettings, authState: MailAuthState = .unknown,
                                                 isBulk: Bool = true, confidential: Bool = false) -> MailTriageState {
        guard settings.aiMode == .ai else { return .none }
        switch effectivePolicy(rule) {
        case .always:
            if confidential { return .awaitingConsent }
            if senderKind == .alert, candidates == 0 { return .skipped }
            if authState == .fail { return .awaitingConsent }
            if senderKind == .alert, !isBulk { return .awaitingConsent }
            return .queued
        case .never: return .none
        case .ask: return .awaitingConsent
        }
    }

    /// The sender's AI policy as the gate applies it: no rule (deleted, manual drop) → `ask`; a
    /// disabled rule keeps `never` but never sends automatically (`always` → `ask`).
    package nonisolated static func effectivePolicy(_ rule: SenderRule?) -> MailAIPolicy {
        guard let rule else { return .ask }
        if !rule.enabled, rule.aiPolicy == .always { return .ask }
        return rule.aiPolicy
    }

    /// The provider mail triage may use right now: Settings ▸ Mail's triage provider, else the
    /// reading provider (what the consent prompt names).
    package nonisolated static func wantedProvider(_ settings: MailSettings, _ es: EngineSettings) -> AIProviderKind {
        settings.triageProvider ?? es.selectedProvider
    }

    /// The single gate of every send: AI on for mail, the sender not `never`, and either the
    /// sender's policy is `always` (DMARC/DKIM not failed, and the stored email is not
    /// confidential — `MailHeuristics.isConfidential`) or the user consented to this email for
    /// `provider`.
    package nonisolated static func permission(_ m: MailMessage, settings: MailSettings,
                                               provider: AIProviderKind) -> MailTriagePermission {
        guard settings.aiMode == .ai else { return .aiOff }
        let policy = effectivePolicy(settings.rule(id: m.ruleID))
        if policy == .never { return .senderNever }
        if policy == .always, m.authState != .fail, !MailHeuristics.isConfidential(m) { return .allowed }
        if m.triageConsented, m.triageConsentProvider == provider.rawValue { return .allowed }
        return .needsConsent
    }

    /// The triage state a refused message goes to.
    nonisolated static func refusalState(_ p: MailTriagePermission) -> MailTriageState {
        switch p {
        case .allowed: return .queued
        case .needsConsent: return .awaitingConsent
        case .senderNever, .aiOff: return .none
        }
    }

    /// The capture's floor for documents (`MailHeuristics.keepsDocumentPending`) holds for an AI
    /// result too: a person's or an advisor's card with an attached document or a shared-file link
    /// stays in 待处理 whatever kind the model picked (an "other", a low-confidence request, an FYI
    /// the user doesn't keep) — unless the model found no paper at all (`notPaper`).
    package nonisolated static func keepsDocumentPending(_ t: MailTriage, items: [MailItem], senderKind: SenderKind) -> Bool {
        guard senderKind == .advisor || senderKind == .person, t.requestKind != .notPaper else { return false }
        return items.contains { $0.origin == .document || $0.origin == .shareLink }
    }

    /// Whether an AI result keeps the card in 待处理 (else 「无阅读需求」): a kept kind with a
    /// reading request at ≥ `minConfidence`; an FYI share; an alert digest with papers the model
    /// highlighted for the user (`focusPapers` = requested / highlighted hints).
    package nonisolated static func keepsPending(_ t: MailTriage, criteria: ReadingCriteria, focusPapers: Int = 0) -> Bool {
        guard t.requestKind != .notPaper, criteria.keepKinds.contains(t.requestKind) else { return false }
        if t.hasReadingRequest, t.confidence >= criteria.minConfidence { return true }
        switch t.requestKind {
        case .fyi: return true
        case .alertDigest: return focusPapers > 0
        default: return false
        }
    }

    // MARK: - Lifecycle

    /// Launch recovery: `running` → `queued`, then the jobs that were in the lane at quit — rows
    /// `handOff` had written (`triageStdinBytes` set) and still queued / limited / needs-login —
    /// go back into the (in-memory) lane through the gate. Messages captured but never handed off
    /// are not touched here: the sync's post-processing resume hands them over (`messageReady`).
    /// Watches the agent status for pauses, logins and `agent.mode` switches (held messages are
    /// released when the mode can run them).
    package func start() async {
        guard !started, !stopping else { return }
        started = true
        let now = ctx.now()
        _ = try? await ctx.db.resetRunningTriageToQueued(now: now)
        let events = ctx.events.subscribe()
        lastMode = await agents.status().mode       // a later switch releases held messages
        statusTask = Task { [weak self] in
            for await event in events {
                guard case .agentStatus(let status) = event else { continue }
                await self?.agentStatusChanged(status)
            }
        }
        let waiting = (try? await ctx.db.mailMessages(triageStates: [.queued, .limited, .needsLogin], limit: 500)) ?? []
        for m in waiting where m.triageStdinBytes != nil {
            await enqueue(pk: m.pk, trigger: .recovery)
        }
        await tick()
    }

    /// Cancels result verification still in flight (no quota is involved) and stops watching.
    package func shutdown() async {
        stopping = true
        statusTask?.cancel()
        statusTask = nil
        let tasks = Array(verifyTasks.values)
        verifyTasks.removeAll()
        for t in tasks { t.cancel() }
        for t in tasks { await MailSyncActor.join(t, within: .seconds(2)) }
    }

    // MARK: - Entry points

    /// Post-processing of a captured message finished: a `queued` message (rule `always`) goes to the lane.
    package func messageReady(pk: Int64) async {
        guard let m = try? await ctx.db.mailMessage(pk: pk), m.triageState == .queued else { return }
        await enqueue(pk: pk, trigger: .auto)
    }

    /// 「让 AI 分析」: the user's consent for this one email, stored on the message and bound to
    /// the provider the card names (`wantedProvider`). Explicit requests are not held by the daily
    /// cap (they still count). Returns the resulting triage state (`queued`, or `held` when
    /// agent.mode cannot run it right now). Throws `MailTriageError` when AI is not allowed — also
    /// `cardClosed` when the card is dismissed or merged, checked inside the transaction that
    /// stores the consent (a dismiss racing the click leaves no consent and no hand-off).
    @discardableResult
    package func requestAI(messageID: String) async throws -> MailTriageState {
        let settings = loadMailSettings()
        guard settings.aiMode == .ai else { throw MailTriageError.aiDisabled }
        guard let m = try await ctx.db.mailMessage(id: messageID) else { throw MailTriageError.notFound }
        if Self.effectivePolicy(settings.rule(id: m.ruleID)) == .never { throw MailTriageError.senderNever }
        if m.bodyPurged { throw MailTriageError.bodyPurged }
        if Self.isClosed(m) { throw MailTriageError.cardClosed }
        if inLane.contains(m.pk) { return m.triageState }
        let provider = Self.wantedProvider(settings, await ctx.settings())
        try await ctx.db.modifyMailMessage(pk: m.pk, now: ctx.now()) {
            if MailTriageCoordinator.isClosed($0) { throw MailTriageError.cardClosed }
            if $0.bodyPurged { throw MailTriageError.bodyPurged }
            $0.triageConsented = true
            $0.triageConsentProvider = provider.rawValue
        }
        if await enqueue(pk: m.pk, trigger: .user) { return .queued }
        return (try? await ctx.db.mailMessage(pk: m.pk))?.triageState ?? m.triageState
    }

    /// Dismissed (已忽略) or merged (已处理): 「让 AI 分析」 is not offered (`MailCard.canRequestAI`).
    nonisolated static func isClosed(_ m: MailMessage) -> Bool { m.state == .dismissed || m.state == .merged }

    /// What 「让 AI 分析」 would hand to the triage lane for this email right now — the exact stdin,
    /// model and provider (the Mail detail's 「发送给 AI 的内容」 disclosure). Built exactly like a
    /// real job (stored sanitized text, rows, criteria, library context, first pages of stored
    /// attachments) but never enqueued, never counted against the daily cap, never written back.
    /// Nil when the email is gone; throws `MailTriageError` when AI is not allowed for it.
    package func previewJob(messageID: String) async throws -> MailTriageJob? {
        let settings = loadMailSettings()
        guard let m = try await ctx.db.mailMessage(id: messageID) else { return nil }
        guard settings.aiMode == .ai else { throw MailTriageError.aiDisabled }
        if Self.effectivePolicy(settings.rule(id: m.ruleID)) == .never { throw MailTriageError.senderNever }
        if m.bodyPurged { throw MailTriageError.bodyPurged }
        return try await buildJob(m, settings: settings, provider: Self.wantedProvider(settings, await ctx.settings()))
    }

    /// Periodic pass (the sync loop's maintenance tick, `agent.mode` switches, settings changes):
    /// - whatever the settings no longer allow is withdrawn — lane jobs and waiting rows alike
    ///   (`withdrawDisallowed`);
    /// - held by the daily cap → released once the next day starts;
    /// - held because agent.mode could not run it → released when it can;
    /// - failed → retried after its backoff, at most `maxAttempts` times.
    /// Dismissed and merged cards are never released automatically.
    package func tick() async {
        guard !stopping else { return }
        let settings = loadMailSettings()
        await withdrawDisallowed()
        guard settings.aiMode == .ai else { return }
        let es = await ctx.settings()
        let provider = Self.wantedProvider(settings, es)
        let now = ctx.now()
        let routeRuns: Bool
        if case .run = MailTriageRoute.of(provider: provider, settings: es) { routeRuns = true }
        else { routeRuns = false }
        let candidates = (try? await ctx.db.mailMessages(triageStates: [.held, .failed], limit: 500)) ?? []
        for m in candidates where !inLane.contains(m.pk) {
            guard Self.permission(m, settings: settings, provider: provider) == .allowed, !m.bodyPurged,
                  m.state != .dismissed, m.state != .merged else { continue }
            switch m.triageState {
            case .failed:
                guard m.triageAttempt < Self.maxAttempts, let due = m.triageNotBefore, due <= now else { continue }
            case .held:
                if let due = m.triageNotBefore {
                    guard due <= now else { continue }          // daily cap: the next day
                } else {
                    guard routeRuns else { continue }           // agent.mode: when it can run
                }
            default: continue
            }
            await enqueue(pk: m.pk, trigger: .auto)
        }
    }

    /// A message left `queued` without ever being handed to the lane (no stdin size) — captured
    /// before its post-processing marker existed, a 「让 AI 分析」 whose hand-off failed, … — and
    /// not touched since `cutoff` (one sync pass) while no post-processing still owes its
    /// hand-off (no kv marker): it would stay "queued" forever, so it offers 「让 AI 分析」
    /// instead (`awaitingConsent`; `none` when the sender is `never` or AI is off). Never sent.
    package func releaseStrandedQueued(olderThan cutoff: Date) async {
        guard !stopping else { return }
        let marker = (try? await ctx.db.mailCursor(accountID: MailSyncActor.pendingPostKey))?.value
        let owed = Set(MailSyncActor.decodePKs(marker))
        let queued = (try? await ctx.db.mailMessages(triageStates: [.queued], limit: 2000)) ?? []
        for m in queued where m.triageStdinBytes == nil && m.updatedAt < cutoff && !owed.contains(m.pk)
            && !inLane.contains(m.pk) && !handingOff.contains(m.pk) {
            await strand(m.pk)
            Log.agent.info("mail#\(m.pk, privacy: .public): queued triage never handed off — waiting for 让 AI 分析")
        }
    }

    /// The sync gave up retrying this message's hand-off (`MailSyncActor.maxHandOffRetries`):
    /// unless it is in the lane by now, it offers 「让 AI 分析」 like a stranded row.
    package func giveUpHandOff(pk: Int64) async {
        guard !inLane.contains(pk), !handingOff.contains(pk) else { return }
        await strand(pk)
    }

    /// `queued` without a hand-off → `awaitingConsent` (a consent is dropped: asked again), or
    /// `none` when the gate says never / AI off. Any other state is left alone.
    private func strand(_ pk: Int64) async {
        let settings = loadMailSettings()
        let provider = Self.wantedProvider(settings, await ctx.settings())
        await refund(pk)
        await write(pk) { m in
            guard m.triageState == .queued, m.triageStdinBytes == nil else { return }
            let p = MailTriageCoordinator.permission(m, settings: settings, provider: provider)
            m.triageState = p == .senderNever || p == .aiOff ? .none : .awaitingConsent
            m.triageNotBefore = nil
            m.triageError = nil
            m.triageConsented = false
            m.triageConsentProvider = nil
        }
    }

    /// The user dismissed the card (`Engine.dismissMail`): its lane job is cancelled before it is
    /// sent and today's count given back; a hand-off in progress stops when it ends.
    package func withdraw(messagePK pk: Int64) async {
        if handingOff.contains(pk) {
            withdrawals[pk] = .cancel
            return
        }
        if inLane.contains(pk) { await pull([pk]) } else { await refund(pk) }
    }

    package func usage() async -> MailTriageUsage {
        let limit = max(0, loadMailSettings().triageDailyMax)
        let today = LocalDate.today(now: ctx.now(), calendar: ctx.calendar)
        guard let raw = try? await ctx.db.kv(Self.dayKey) else { return MailTriageUsage(day: today, used: 0, limit: limit) }
        return MailTriageUsage(day: today, used: Self.count(raw, day: today), limit: limit)
    }

    /// Messages currently in the lane (tests, snapshot).
    package func laneMessagePKs() -> Set<Int64> { inLane }

    /// 「清除所有邮件数据」: withdraws every lane job (refunded: never sent) and stops result
    /// verification; today's count of answered jobs stays.
    package func clearAll() async {
        for pk in inLane where !handingOff.contains(pk) {
            await agents.cancelTriage(messagePK: pk)
            await refund(pk)
        }
        for pk in handingOff { withdrawals[pk] = .cancel }
        inLane.removeAll()
        laneProvider.removeAll()
        _ = await updateDay { c in
            guard !(c.open ?? []).isEmpty else { return false }
            c.open = []
            return true
        }
        let tasks = Array(verifyTasks.values)
        verifyTasks.removeAll()
        for t in tasks { t.cancel() }
        for t in tasks { await MailSyncActor.join(t, within: .seconds(2)) }
    }

    // MARK: - Enqueue

    /// Claims the message, hands it off (`handOff`) and applies a withdrawal that arrived
    /// meanwhile. True when a job is in the lane.
    @discardableResult
    private func enqueue(pk: Int64, trigger: Trigger) async -> Bool {
        guard !stopping, !inLane.contains(pk) else { return false }
        inLane.insert(pk)                   // claimed: a concurrent tick / ready call backs off
        handingOff.insert(pk)
        var handedOff = await handOff(pk: pk, trigger: trigger)
        handingOff.remove(pk)
        if !handedOff { inLane.remove(pk) }
        switch withdrawals.removeValue(forKey: pk) {
        case .cancel?:
            if handedOff { await pull([pk]) } else { await refund(pk) }
            handedOff = false
        case .recheck?:
            if handedOff {
                await reconcileLaneJob(pk, es: await ctx.settings())
                handedOff = inLane.contains(pk)
            }
        case nil:
            break
        }
        return handedOff
    }

    private struct MovedAway: Error {}

    /// The row changed under a hand-off in a way that ends it: the card was closed (dismissed or
    /// merged — `isClosed`), the body was purged, the consent was withdrawn, or the triage was
    /// refused / answered / skipped.
    nonisolated static func movedAway(_ cur: MailMessage, from start: MailMessage) -> Bool {
        if isClosed(cur), !isClosed(start) { return true }
        if cur.bodyPurged, !start.bodyPurged { return true }
        if start.triageConsented, !cur.triageConsented { return true }
        let ended: Set<MailTriageState> = [.none, .awaitingConsent, .skipped, .done]
        return cur.triageState != start.triageState && ended.contains(cur.triageState)
    }

    private func handOff(pk: Int64, trigger: Trigger) async -> Bool {
        let settings = loadMailSettings()
        guard let m = try? await ctx.db.mailMessage(pk: pk) else { return false }
        let es = await ctx.settings()
        let lang = es.lang
        let provider = Self.wantedProvider(settings, es)
        let permission = Self.permission(m, settings: settings, provider: provider)
        guard permission == .allowed else {
            await refuse(pk, to: Self.refusalState(permission))
            return false
        }
        if Self.isClosed(m) {
            // Never for a dismissed or merged card, whoever asks — automatically, at launch
            // recovery, or the user's 「让 AI 分析」 (which `requestAI` refuses for a closed card too:
            // a dismiss landing between its consent and this read ends here). Reopen it first.
            await refuse(pk, to: .none)
            return false
        }
        guard !m.bodyPurged else {
            await refund(pk)
            _ = await writeIfStill(pk, from: m) { $0.triageState = .skipped; $0.triageError = MailSyncText.bodyPurged(lang) }
            return false
        }
        // The user's own request, or a message that runs on its consent, is not held by the cap.
        let byConsent = Self.effectivePolicy(settings.rule(id: m.ruleID)) != .always || m.authState == .fail
            || MailHeuristics.isConfidential(m)
        let force = trigger == .user || byConsent
        if trigger == .recovery, await countedToday(pk) {
            // In the lane at quit, counted today and never answered: not counted again.
        } else if !(await reserve(pk, limit: settings.triageDailyMax, force: force)) {
            let used = await usage()
            let tomorrow = LocalDate.today(now: ctx.now(), calendar: ctx.calendar).adding(days: 1, calendar: ctx.calendar)
                .startOfDay(calendar: ctx.calendar)
            let note = MailSyncText.dailyCapReached(used: used.used, limit: used.limit, lang)
            if await writeIfStill(pk, from: m, {
                $0.triageState = .held
                $0.triageNotBefore = tomorrow
                $0.triageError = note
            }) {
                Log.agent.info("mail#\(pk, privacy: .public): triage held — daily cap reached")
            }
            return false
        }
        let job: MailTriageJob
        do {
            job = try await buildJob(m, settings: settings, provider: provider)
        } catch {
            await refund(pk)
            Log.agent.error("mail#\(pk, privacy: .public): triage job not built (\(String(describing: type(of: error)), privacy: .public))")
            return false
        }
        guard !stopping else { await refund(pk); return false }
        // Settings may have changed while the job was built: the gate decides once more, on the
        // current row, inside the write that commits the hand-off.
        let freshSettings = loadMailSettings()
        let freshES = await ctx.settings()
        let freshProvider = Self.wantedProvider(freshSettings, freshES)
        let heldNote = MailTriageRoute.of(provider: freshProvider, settings: freshES).heldText(lang)
            ?? MailSyncText.aiUnavailable(lang)
        let stdinBytes = job.request.stdin.count, model = job.request.model
        let saved: MailMessage
        do {
            saved = try await ctx.db.modifyMailMessage(pk: pk, now: ctx.now()) { cur in
                if MailTriageCoordinator.movedAway(cur, from: m) { throw MovedAway() }
                let now = MailTriageCoordinator.permission(cur, settings: freshSettings, provider: freshProvider)
                guard now == .allowed else {
                    cur.triageState = MailTriageCoordinator.refusalState(now)
                    if now == .needsConsent { cur.triageConsented = false; cur.triageConsentProvider = nil }
                    cur.triageNotBefore = nil
                    cur.triageError = nil
                    return
                }
                guard freshProvider == provider else {
                    cur.triageState = .held             // rebuilt for the new provider by the next tick
                    cur.triageNotBefore = nil
                    cur.triageError = heldNote
                    return
                }
                cur.triageState = .queued
                cur.triageNotBefore = nil
                cur.triageError = nil
                cur.triageStdinBytes = stdinBytes
                cur.triageProvider = provider.rawValue
                cur.triageModel = model
            }
        } catch {
            await refund(pk)
            if !(error is MovedAway), !(error is DatabaseError) {
                Log.agent.error("mail#\(pk, privacy: .public): triage state not stored")
            }
            return false
        }
        guard saved.triageState == .queued, saved.triageStdinBytes == stdinBytes else {
            await refund(pk)
            return false
        }
        await agents.enqueueTriage(job)
        laneProvider[pk] = provider
        return true
    }

    /// `MailTriageJob` for one stored message: stdin from the stored (already sanitized) body,
    /// its rows, the user's criteria, library categories / frequent tags and the first page of
    /// stored PDF attachments, for `provider` (`wantedProvider`).
    private func buildJob(_ m: MailMessage, settings: MailSettings, provider: AIProviderKind) async throws -> MailTriageJob {
        let items = try await ctx.db.mailItems(messagePK: m.pk)
        let categories = try await ctx.db.categories().map(\.name)
        let tags = try await ctx.db.frequentTags(limit: MailTriageSchema.maxFrequentTags).map(\.name)
        var attachments: [MailTriageSchema.Attachment] = []
        for item in items where item.origin == .attachment && attachments.count < MailTriageSchema.maxAttachments {
            guard let path = item.pdfPath else { continue }
            let page = await files.firstPage(relativePath: path)
            attachments.append(MailTriageSchema.Attachment(ref: item.cand, title: item.title ?? page?.title,
                                                           abstract: page.flatMap { $0.text.isEmpty ? nil : $0.text }))
        }
        let body = m.bodyText ?? ""
        let forwarded = body.hasPrefix(MailExtractor.forwardedLabel + "\n") || body.contains("\n" + MailExtractor.forwardedLabel + "\n")
        let extraction = MailExtraction(bodyText: body, snippet: m.snippet ?? "", candidates: [], isForwarded: forwarded)
        let stdin = MailTriageSchema.stdin(message: m, extraction: extraction, candidates: items, criteria: settings.criteria,
                                           categories: categories, frequentTags: tags, attachments: attachments,
                                           bodyCap: settings.triageBodyCap, calendar: ctx.calendar)
        let request = MailTriageSchema.request(stdin: stdin, provider: provider, settings: settings)
        return MailTriageJob(messagePK: m.pk, messageID: m.id, request: request, provider: provider)
    }

    // MARK: - Daily cap (kv mail.triage.day = {"day":"YYYY-MM-DD","n":N,"open":[pk…]})
    //
    // `n` is today's count; `open` the messages counted today whose job has not been answered
    // yet — refundable when it is withdrawn, and not counted again when launch recovery puts
    // it back into the lane the same day.

    private struct DayCount: Codable, Sendable {
        var day: String
        var n: Int
        var open: [Int64]?
    }

    private static func decode(_ raw: String?, day: LocalDate) -> DayCount {
        guard let raw, let c = try? JSONDecoder().decode(DayCount.self, from: Data(raw.utf8)), c.day == day.iso else {
            return DayCount(day: day.iso, n: 0, open: [])
        }
        return DayCount(day: c.day, n: max(0, c.n), open: c.open ?? [])
    }

    private static func encode(_ c: DayCount) -> String {
        String(decoding: (try? JSONEncoder().encode(c)) ?? Data(), as: UTF8.self)
    }

    private static func count(_ raw: String, day: LocalDate) -> Int { decode(raw, day: day).n }

    /// Read-modify-write of today's record in one transaction; `change` returns false to leave it.
    private func updateDay(_ change: @escaping @Sendable (inout DayCount) -> Bool) async -> Bool {
        let today = LocalDate.today(now: ctx.now(), calendar: ctx.calendar)
        let key = Self.dayKey
        let result = try? await ctx.db.transaction { db -> Bool in
            var c = MailTriageCoordinator.decode(try db.kv(key), day: today)
            guard change(&c) else { return false }
            try db.setKV(key, MailTriageCoordinator.encode(c))
            return true
        }
        return result ?? false
    }

    /// Atomically counts one triage of `pk` for today; false (nothing counted) when the cap is
    /// reached and `force` is off.
    private func reserve(_ pk: Int64, limit: Int, force: Bool) async -> Bool {
        let cap = max(0, limit)
        return await updateDay { c in
            guard force || c.n < cap else { return false }
            c.n += 1
            var open = c.open ?? []
            if !open.contains(pk) { open.append(pk) }
            c.open = open
            return true
        }
    }

    /// Gives back the count of a job that was never sent (agent.mode off, gate refused, build
    /// error, withdrawn). Only a job counted today and not answered is refunded.
    private func refund(_ pk: Int64) async {
        _ = await updateDay { c in
            guard var open = c.open, let i = open.firstIndex(of: pk) else { return false }
            open.remove(at: i)
            c.open = open
            c.n = max(0, c.n - 1)
            return true
        }
    }

    /// The job was answered (it was sent): it stays counted.
    private func answered(_ pk: Int64) async {
        _ = await updateDay { c in
            guard var open = c.open, let i = open.firstIndex(of: pk) else { return false }
            open.remove(at: i)
            c.open = open
            return true
        }
    }

    private func countedToday(_ pk: Int64) async -> Bool {
        let today = LocalDate.today(now: ctx.now(), calendar: ctx.calendar)
        let raw = try? await ctx.db.kv(Self.dayKey)
        return (Self.decode(raw ?? nil, day: today).open ?? []).contains(pk)
    }

    // MARK: - Lane results

    /// The AgentQueue triage handler (`setTriageHandler`): one call per job that left the lane.
    /// A job withdrawn meanwhile (dismissed card, sender changed) keeps only a real answer — it
    /// was sent; a cancel or failure of it changes nothing.
    package func handle(_ job: MailTriageJob, _ outcome: AgentOutcome) async {
        let pk = job.messagePK
        let current = inLane.remove(pk) != nil
        laneProvider[pk] = nil
        let lang = await ctx.settings().lang
        if outcome == .cancelled { await refund(pk) } else { await answered(pk) }
        if case .success = outcome {} else if !current { return }
        switch outcome {
        case .success(let raw, let meta):
            await applySuccess(job, raw: raw, meta: meta, lang: lang)
        case .cancelled:
            // Nothing was sent: agent.mode is off / names another provider, or a gate refused.
            let es = await ctx.settings()
            let note = MailTriageRoute.of(provider: job.provider, settings: es).heldText(lang) ?? MailSyncText.aiUnavailable(lang)
            await write(pk) {
                guard MailTriageCoordinator.pendingStates.contains($0.triageState) else { return }
                $0.triageState = .held
                $0.triageNotBefore = nil
                $0.triageError = note
            }
        case .usageLimit(let resetsAt):
            // The lane normally keeps these queued itself; handled defensively (retried by tick).
            let retry = resetsAt ?? ctx.now().addingTimeInterval(3600)
            await write(pk) {
                guard MailTriageCoordinator.pendingStates.contains($0.triageState) else { return }
                $0.triageState = .failed
                $0.triageNotBefore = retry
                $0.triageError = MailSyncText.usageLimited(resetsAt, lang)
            }
        case .notLoggedIn, .binaryMissing:
            // Defensive too: parked as held until agent.mode / login changes release it.
            await write(pk) {
                guard MailTriageCoordinator.pendingStates.contains($0.triageState) else { return }
                $0.triageState = .held
                $0.triageNotBefore = nil
                $0.triageError = MailSyncText.needsLogin(lang)
            }
        case .invalidOutput, .maxTurns, .timeout, .overloaded, .generic:
            await fail(pk, outcome: outcome, lang: lang)
        }
    }

    private func fail(_ pk: Int64, outcome: AgentOutcome, lang: UILang) async {
        let now = ctx.now()
        let note = MailSyncText.triageFailed(outcome, lang)
        await write(pk) {
            guard MailTriageCoordinator.pendingStates.contains($0.triageState) else { return }
            $0.triageAttempt += 1
            $0.triageState = .failed
            $0.triageError = note
            if $0.triageAttempt < MailTriageCoordinator.maxAttempts {
                let minutes = $0.triageAttempt == 1 ? 5.0 : 30.0
                $0.triageNotBefore = now.addingTimeInterval(minutes * 60)
            } else {
                $0.triageNotBefore = nil
            }
        }
        Log.agent.info("mail#\(pk, privacy: .public): triage failed (attempt recorded)")
    }

    private func applySuccess(_ job: MailTriageJob, raw: JSONValue, meta: RunMeta, lang: UILang) async {
        let pk = job.messagePK
        let settings = loadMailSettings()
        guard let m = try? await ctx.db.mailMessage(pk: pk) else { return }
        let items = (try? await ctx.db.mailItems(messagePK: pk)) ?? []
        let sanitized: (MailTriage, [MailTriageSanitizer.PaperHint])
        do {
            sanitized = try MailTriageSanitizer.sanitize(raw, message: m, items: items, bodyText: m.bodyText ?? "",
                                                         maxAlertPapers: settings.criteria.maxAlertPapers,
                                                         calendar: ctx.calendar)
        } catch {
            await fail(pk, outcome: .invalidOutput("sanitizer"), lang: lang)
            return
        }
        let (triage, hints) = sanitized
        let focus = hints.filter { $0.relevance != .listed && $0.isGrounded }.count
        let now = ctx.now()
        let criteria = settings.criteria
        let providerName = (await ctx.settings()).agentMode == .mock ? "mock" : (job.provider?.rawValue ?? "")
        let byRef = Dictionary(hints.compactMap { h in h.ref.map { ($0.lowercased(), h) } }, uniquingKeysWith: { a, _ in a })
        let model = meta.model ?? job.request.model
        do {
            try await ctx.db.transaction { db in
                guard var cur = try db.mailMessage(pk: pk) else { return }
                cur.triage = triage
                cur.triageSource = .ai
                cur.triageState = .done
                cur.triageError = nil
                cur.triageNotBefore = nil
                cur.triageProvider = providerName.isEmpty ? cur.triageProvider : providerName
                cur.triageModel = model
                cur.triageMs = meta.durationMs
                cur.triageInputTokens = meta.inputTokens
                cur.triageOutputTokens = meta.outputTokens
                if !cur.userTouched, cur.state == .pending || cur.state == .noRequest {
                    let rows = try db.mailItems(messagePK: pk)
                    let keep = MailTriageCoordinator.keepsPending(triage, criteria: criteria, focusPapers: focus)
                        || MailTriageCoordinator.keepsDocumentPending(triage, items: rows, senderKind: cur.senderKind)
                    let next: MailState = keep ? .pending : .noRequest
                    if next != cur.state {
                        cur.state = next
                        cur.handledAt = next == .noRequest ? now : nil
                    }
                }
                try db.updateMailMessage(cur, now: now)
                for var item in try db.mailItems(messagePK: pk) {
                    guard let hint = byRef[item.cand.lowercased()] else { continue }
                    let before = item
                    item.relevance = hint.relevance
                    if !hint.why.isEmpty { item.why = hint.why }
                    item.confidence = hint.confidence
                    if item != before { try db.upsertMailItem(item, now: now) }
                }
            }
        } catch {
            Log.agent.error("mail#\(pk, privacy: .public): triage result not stored (\(String(describing: type(of: error)), privacy: .public))")
            return
        }
        // Papers only the model named: verify (Crossref / arXiv) before they become rows.
        let unverified = hints.filter { $0.ref == nil }.prefix(Self.maxVerifiedHints)
        guard !unverified.isEmpty, !stopping else { return }
        let hintList = Array(unverified)
        verifyTasks[pk]?.cancel()
        verifyTasks[pk] = Task { [weak self] in
            await self?.verify(hintList, messagePK: pk)
            await self?.verificationFinished(pk)
        }
    }

    private func verificationFinished(_ pk: Int64) { verifyTasks[pk] = nil }

    /// Waits for result verification in flight (tests).
    package func waitForVerification() async {
        while let t = verifyTasks.values.first { await t.value }
    }

    /// A model-only paper becomes a `citation` row (found by AI, no link, needs a PDF) only when
    /// its ids resolve to the same work, or Crossref finds its title at ≥ 0.92 similarity. Ids
    /// and metadata of the row come from the lookup, never from the model; nothing is fetched
    /// from them. Without metadata lookup (off / offline) such hints are dropped.
    private func verify(_ hints: [MailTriageSanitizer.PaperHint], messagePK pk: Int64) async {
        let es = await ctx.settings()
        guard let resolver = resolverFactory(es) else {
            Log.agent.info("mail#\(pk, privacy: .public): \(hints.count, privacy: .public) model-only paper(s) dropped (metadata lookup off)")
            return
        }
        // A title the model named goes to the title search only when the email's titles may
        // (`MailSyncActor.mayLookUpTitles`: never for confidential mail — the manuscript under
        // review is named in it); otherwise only its identifiers are looked up.
        guard let message = try? await ctx.db.mailMessage(pk: pk) else { return }
        let titles = MailSyncActor.mayLookUpTitles(message)
        var accepted: [(MailTriageSanitizer.PaperHint, BiblioMetadata)] = []
        for hint in hints {
            guard !Task.isCancelled else { return }
            let ids = hint.ids.merged(with: hint.unverifiedIDs)
            guard !ids.isEmpty || (titles && hint.title != nil) else { continue }
            guard let meta = await resolver.resolve(ids: ids, titleGuess: titles ? hint.title : nil,
                                                    firstAuthorGuess: nil) else { continue }
            if Self.verifies(meta, hint: hint, ids: ids) { accepted.append((hint, meta)) }
        }
        guard !accepted.isEmpty, !Task.isCancelled else { return }
        let now = ctx.now()
        let matches = await libraryMatches(accepted.map(\.1.ids))
        let list = accepted
        do {
            try await ctx.db.transaction { db in
                guard try db.mailMessage(pk: pk) != nil else { return }
                var items = try db.mailItems(messagePK: pk)
                var nextOrd = (items.map(\.ord).max() ?? 0) + 1
                for (i, (hint, meta)) in list.enumerated() {
                    if let j = items.firstIndex(where: { MailTriageCoordinator.sameWork($0, meta) }) {
                        var existing = items[j]
                        existing.relevance = hint.relevance
                        if !hint.why.isEmpty { existing.why = hint.why }
                        existing.confidence = hint.confidence
                        if existing != items[j] { items[j] = try db.upsertMailItem(existing, now: now) }
                        continue
                    }
                    let inLibrary = matches[i]
                    let item = MailItem(messagePK: pk, ord: nextOrd, cand: "c\(nextOrd)", origin: .citation, foundBy: .ai,
                                        title: meta.title ?? hint.title, authors: meta.authors, venue: meta.venue,
                                        year: meta.year, ids: meta.ids, metaSource: meta.source, relevance: hint.relevance,
                                        why: hint.why.isEmpty ? nil : hint.why, confidence: hint.confidence,
                                        pdfState: inLibrary == nil ? .needsPDF : .inLibrary, paperID: inLibrary,
                                        createdAt: now, updatedAt: now)
                    nextOrd += 1
                    items.append(try db.upsertMailItem(item, now: now))
                }
            }
        } catch {
            Log.agent.error("mail#\(pk, privacy: .public): verified papers not stored")
        }
    }

    /// Same-work ids (DOI incl. both bioRxiv prefixes / arXiv), or the title at ≥ 0.92.
    static func verifies(_ meta: BiblioMetadata, hint: MailTriageSanitizer.PaperHint, ids: PaperIDs) -> Bool {
        let titleOK: Bool = {
            guard let a = hint.title, let b = meta.title else { return false }
            return TitleSimilarity.score(a, b) >= TitleSimilarity.acceptThreshold
        }()
        if titleOK { return true }
        let wanted = Set(Database.sameWorkDOIs(ids.doi))
        let got = Set(Database.sameWorkDOIs(meta.ids.doi) + Database.sameWorkDOIs(meta.ids.publishedDOI))
        let doiOK = !wanted.isEmpty && !wanted.isDisjoint(with: got)
        let arxivOK = ids.arxivID.map { a in meta.ids.arxivID?.lowercased() == a.lowercased() } ?? false
        // An id that resolves to a differently titled work is a hallucinated pairing.
        return (doiOK || arxivOK) && (hint.title == nil || meta.title == nil)
    }

    static func sameWork(_ item: MailItem, _ meta: BiblioMetadata) -> Bool {
        let a = Set(Database.sameWorkDOIs(item.ids.doi) + Database.sameWorkDOIs(item.ids.publishedDOI))
        let b = Set(Database.sameWorkDOIs(meta.ids.doi) + Database.sameWorkDOIs(meta.ids.publishedDOI))
        if !a.isEmpty, !a.isDisjoint(with: b) { return true }
        if let x = item.ids.arxivID, let y = meta.ids.arxivID, x.lowercased() == y.lowercased() { return true }
        if let x = item.title, let y = meta.title { return TitleSimilarity.score(x, y) >= TitleSimilarity.acceptThreshold }
        return false
    }

    private func libraryMatches(_ ids: [PaperIDs]) async -> [String?] {
        var out: [String?] = []
        for i in ids {
            let p = try? await ctx.db.paperMatchingWork(doi: i.doi, arxivID: i.arxivID, publishedDOI: i.publishedDOI)
            out.append(p?.id)
        }
        return out
    }

    // MARK: - Lane status (limited / needs login / held)

    private func agentStatusChanged(_ s: AgentQueueStatus) async {
        guard !stopping else { return }
        let now = ctx.now()
        let label: MailTriageState
        if let until = s.pausedUntil, until > now {
            label = .limited
        } else if s.describesActiveProvider {
            switch s.provider {
            case .notInstalled, .notLoggedIn, .unsupported: label = .needsLogin
            default: label = .queued
            }
        } else {
            label = .queued
        }
        if label != laneLabel {
            laneLabel = label
            let lang = await ctx.settings().lang
            let note: String? = switch label {
            case .limited: MailSyncText.usageLimited(s.pausedUntil, lang)
            case .needsLogin: MailSyncText.needsLogin(lang)
            default: nil
            }
            for pk in inLane {
                guard let m = try? await ctx.db.mailMessage(pk: pk),
                      [.queued, .limited, .needsLogin].contains(m.triageState), m.triageState != label else { continue }
                await write(pk) { m in
                    guard [.queued, .limited, .needsLogin].contains(m.triageState) else { return }
                    m.triageState = label
                    m.triageError = note
                }
            }
        }
        if s.mode != lastMode {
            let previous = lastMode
            lastMode = s.mode
            if previous != nil, s.mode != .off { await tick() }
        }
    }

    /// Withdraws what the settings no longer allow (`permission`): lane jobs (cancelled before
    /// they are sent, count refunded) and messages waiting outside the lane — captured and queued
    /// for post-processing, held by the cap or agent.mode, failed, limited, needs login. AI off
    /// or sender `never` → `none`; consent needed (policy `ask`, rule deleted or disabled, a
    /// consent for another provider) → `awaitingConsent`. A lane job built for a provider the
    /// user no longer allows is withdrawn and held (the release rebuilds it for the new one).
    ///
    /// Every row is judged against mail settings read after the row itself: a snapshot taken
    /// before the read (the tick's own, from before an `await`) can predate the sender rule a row
    /// was just captured or enqueued under — such a row would be refused as "rule unknown → ask"
    /// (a new `never` sender's email offering 「让 AI 分析」, an `always` sender's waiting for a
    /// consent) and no later pass revisits a refused row (the R3PostProcessTests flake).
    private func withdrawDisallowed() async {
        let es = await ctx.settings()
        var decisions: [(pk: Int64, decision: LaneDecision)] = []
        for pk in inLane {
            if handingOff.contains(pk) {
                if withdrawals[pk] == nil { withdrawals[pk] = .recheck }
                continue
            }
            if let d = await laneDecision(pk, es: es) { decisions.append((pk, d)) }
        }
        await apply(decisions, es: es, provider: Self.wantedProvider(loadMailSettings(), es))
        let waiting = (try? await ctx.db.mailMessages(triageStates: Self.pendingStates, limit: 2000)) ?? []
        guard !waiting.isEmpty else { return }
        let settings = loadMailSettings()                   // read after the rows (see above)
        let provider = Self.wantedProvider(settings, es)
        for m in waiting where !inLane.contains(m.pk) {
            let p = Self.permission(m, settings: settings, provider: provider)
            if p != .allowed { await refuse(m.pk, to: Self.refusalState(p)) }
        }
    }

    /// What happens to a lane job the settings no longer allow (nil: it stays).
    private enum LaneDecision {
        case refuse(MailTriageState)        // gate refused → none / awaitingConsent
        case otherProvider                  // built for a provider the user no longer allows → held
        case gone                           // the message was deleted
    }

    /// The settings are read after the row (`withdrawDisallowed`).
    private func laneDecision(_ pk: Int64, es: EngineSettings) async -> LaneDecision? {
        guard let m = try? await ctx.db.mailMessage(pk: pk) else { return .gone }
        let settings = loadMailSettings()
        let provider = Self.wantedProvider(settings, es)
        let p = Self.permission(m, settings: settings, provider: provider)
        if p != .allowed { return .refuse(Self.refusalState(p)) }
        if let built = laneProvider[pk], built != provider { return .otherProvider }
        return nil
    }

    private func reconcileLaneJob(_ pk: Int64, es: EngineSettings) async {
        guard let d = await laneDecision(pk, es: es) else { return }
        await apply([(pk, d)], es: es, provider: Self.wantedProvider(loadMailSettings(), es))
    }

    /// Pulls the decided jobs out of the lane in one step (cancelling the running one can never
    /// start another of them), then records why.
    private func apply(_ decisions: [(pk: Int64, decision: LaneDecision)], es: EngineSettings,
                       provider: AIProviderKind) async {
        guard !decisions.isEmpty else { return }
        await pull(Set(decisions.map(\.pk)))
        let note = MailTriageRoute.of(provider: provider, settings: es).heldText(es.lang)
            ?? MailSyncText.aiUnavailable(es.lang)
        for (pk, decision) in decisions {
            switch decision {
            case .gone:
                continue
            case .refuse(let state):
                await refuse(pk, to: state)
            case .otherProvider:
                await write(pk) {
                    guard MailTriageCoordinator.pendingStates.contains($0.triageState) else { return }
                    $0.triageState = .held
                    $0.triageNotBefore = nil
                    $0.triageError = note
                }
                Log.agent.info("mail#\(pk, privacy: .public): triage withdrawn — the triage provider changed")
            }
        }
    }

    /// Takes jobs out of the lane before they are sent (a running one is terminated without a
    /// handler call) and refunds their count.
    private func pull(_ pks: Set<Int64>) async {
        guard !pks.isEmpty else { return }
        await agents.cancelTriage(messagePKs: pks)
        for pk in pks {
            inLane.remove(pk)
            laneProvider[pk] = nil
            await refund(pk)
        }
    }

    /// A message the gate refused: count refunded, a pending triage state moved to `state`
    /// (`awaitingConsent` drops a consent that no longer applies). Other states are left alone.
    private func refuse(_ pk: Int64, to state: MailTriageState) async {
        await refund(pk)
        await write(pk) { m in
            guard MailTriageCoordinator.pendingStates.contains(m.triageState) else { return }
            m.triageState = state
            m.triageNotBefore = nil
            m.triageError = nil
            if state == .awaitingConsent {
                m.triageConsented = false
                m.triageConsentProvider = nil
            }
        }
    }

    // MARK: - Writes

    /// Read-modify-write of one message (user actions made meanwhile are kept: only triage
    /// fields change here). Errors are logged without content.
    private func write(_ pk: Int64, _ body: @escaping @Sendable (inout MailMessage) -> Void) async {
        let now = ctx.now()
        do {
            _ = try await ctx.db.modifyMailMessage(pk: pk, now: now) { m in body(&m) }
        } catch DatabaseError.notFound {
            inLane.remove(pk)
        } catch {
            Log.agent.error("mail#\(pk, privacy: .public): triage state not stored")
        }
    }

    /// `write`, unless the row moved away from `start` meanwhile (`movedAway`). True when written.
    private func writeIfStill(_ pk: Int64, from start: MailMessage,
                              _ body: @escaping @Sendable (inout MailMessage) -> Void) async -> Bool {
        do {
            _ = try await ctx.db.modifyMailMessage(pk: pk, now: ctx.now()) { m in
                if MailTriageCoordinator.movedAway(m, from: start) { throw MovedAway() }
                body(&m)
            }
            return true
        } catch is MovedAway {
            return false
        } catch DatabaseError.notFound {
            return false
        } catch {
            Log.agent.error("mail#\(pk, privacy: .public): triage state not stored")
            return false
        }
    }
}
