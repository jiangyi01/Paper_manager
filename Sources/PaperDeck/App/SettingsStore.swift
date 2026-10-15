import Foundation
import Observation
import ServiceManagement
import PaperDeckCore
import PaperDeckConfig

/// UserDefaults-backed settings (keys are stable; the build script and the CLI
/// read some of them, e.g. `agent.mode`).
@Observable
final class SettingsStore {
    @ObservationIgnored private let d: UserDefaults
    /// The defaults domain `d` persists to (nil: the app's own, `BuildIdentity.current.bundleID`);
    /// renders and self-tests pass their scratch suite.
    @ObservationIgnored let domainName: String?
    /// Institution, research field, reader and date order (the configuration layer; same defaults).
    let config: ConfigStore

    // General
    var language: UILang { didSet { d.set(language.rawValue, forKey: Keys.language); LangStore.shared.lang = language } }
    var showMenuBarCount: Bool { didSet { d.set(showMenuBarCount, forKey: Keys.showMenuBarCount) } }
    var pdfOpener: String { didSet { d.set(pdfOpener, forKey: Keys.pdfOpener) } }       // "preview" | "default"

    // Reading plan & reminders
    var dailyBudgetMinutes: Int { didSet { d.set(dailyBudgetMinutes, forKey: Keys.dailyBudget) } }
    var readingWeekdays: Set<Int> { didSet { d.set(Array(readingWeekdays).sorted(), forKey: Keys.readingWeekdays) } }
    var cutoffHour: Int { didSet { d.set(cutoffHour, forKey: Keys.cutoffHour) } }
    var reminderEnabled: Bool { didSet { d.set(reminderEnabled, forKey: Keys.reminderEnabled) } }
    var reminderHour: Int { didSet { d.set(reminderHour, forKey: Keys.reminderHour) } }
    var reminderMinute: Int { didSet { d.set(reminderMinute, forKey: Keys.reminderMinute) } }
    var remindWhenEmpty: Bool { didSet { d.set(remindWhenEmpty, forKey: Keys.remindWhenEmpty) } }
    var autoMarkDone: Bool { didSet { d.set(autoMarkDone, forKey: Keys.autoMarkDone) } }
    var notifyOnAgentDone: Bool { didSet { d.set(notifyOnAgentDone, forKey: Keys.notifyOnAgentDone) } }

    // AI (Claude / ChatGPT via Codex)
    /// off | mock | claude | codex. Writing claude / codex also makes it `agentProvider`.
    var agentMode: String {
        didSet {
            d.set(agentMode, forKey: Keys.agentMode)
            if let kind = AIProviderKind(rawValue: agentMode), kind != agentProvider { agentProvider = kind }
        }
    }
    /// The reading provider the user chose (`agent.provider`). While AI reading is on
    /// (`agent.mode` claude / codex) changing it rewrites `agent.mode` too; callers then call
    /// `Engine.agentProviderDidChange()` (see `AppState.selectProvider`).
    var agentProvider: AIProviderKind {
        didSet {
            d.set(agentProvider.rawValue, forKey: Keys.agentProvider)
            LangStore.shared.provider = agentProvider
            if AIProviderKind(rawValue: agentMode) != nil, agentMode != agentProvider.rawValue {
                agentMode = agentProvider.rawValue
            }
        }
    }
    var autoReadNewPapers: Bool { didSet { d.set(autoReadNewPapers, forKey: Keys.autoRead) } }
    var cliPathOverride: String { didSet { d.set(cliPathOverride, forKey: Keys.cliPath) } }
    var agentModel: String { didSet { d.set(agentModel, forKey: Keys.agentModel) } }        // sonnet | opus | haiku (Claude)
    var codexModel: String { didSet { d.set(codexModel, forKey: Keys.codexModel) } }        // gpt-5.6-terra | -sol | -luna …
    var codexPathOverride: String { didSet { d.set(codexPathOverride, forKey: Keys.codexPath) } }
    var agentEffort: String { didSet { d.set(agentEffort, forKey: Keys.agentEffort) } }     // low | medium (both providers)
    var textBudget: Int { didSet { d.set(textBudget, forKey: Keys.textBudget) } }
    var allowNewCategories: Bool { didSet { d.set(allowNewCategories, forKey: Keys.allowNewCategories) } }

    // Library & storage
    var libraryPath: String { didSet { d.set(libraryPath, forKey: Keys.libraryPath) } }
    var importMode: String { didSet { d.set(importMode, forKey: Keys.importMode) } }        // copy | move
    var metadataLookup: Bool { didSet { d.set(metadataLookup, forKey: Keys.metadataLookup) } }
    var crossrefMailto: String { didSet { d.set(crossrefMailto, forKey: Keys.crossrefMailto) } }

    var setupCompleted: Bool { didSet { d.set(setupCompleted, forKey: Keys.setupCompleted) } }

    // Reading assist (`assist.*`, off by default) and the duplicate check (`dedupe.*`): the keys
    // `EngineSettings.load` reads; a write stores only the keys whose value changed.
    var assist: AssistSettings {
        didSet {
            assist.save(to: d, previous: oldValue)
            if assist.mode != oldValue.mode { onAssistModeChange?() }
            if assist.mode != oldValue.mode || assist.dailySoftCap != oldValue.dailySoftCap
                || assist.dailyHardCap != oldValue.dailyHardCap { onAssistQuotaChange?() }
            if assist.explainHotKey != oldValue.explainHotKey { onExplainHotKeyChange?() }
        }
    }
    /// Called after `assist.mode` or a daily cap changed: the footers' "today n/50" is published again
    /// (`AssistLane.publishSnapshot`: the new provider's count, the new cap).
    @ObservationIgnored var onAssistQuotaChange: (() -> Void)?
    /// Called after `assist.mode` changed (off, or another provider): the app closes the assist's
    /// warm / live processes (`AssistLane.closeAllSessions`) and registers or releases Explain's shortcut.
    @ObservationIgnored var onAssistModeChange: (() -> Void)?
    /// Called after `assist.explain.hotkey` changed (the recorder, a settings import): Explain
    /// registers the new shortcut (`ExplainBootstrap.shortcutChanged`).
    @ObservationIgnored var onExplainHotKeyChange: (() -> Void)?
    var dedupe: DedupeSettings { didSet { dedupe.save(to: d, previous: oldValue) } }

    // Mail (Settings ▸ Mail). The same UserDefaults keys `MailSettings.load` reads on the engine
    // side (arrays / criteria as JSON via `MailSettings.encode`). Every write notifies the
    // engine (debounced) through `onMailSettingsChange` — see `connectMail(to:)`.
    var mailEnabled: Bool { didSet { d.set(mailEnabled, forKey: MailKeys.enabled); mailDidChange() } }
    var mailAccounts: [MailAccount] { didSet { d.set(MailSettings.encode(mailAccounts), forKey: MailKeys.accounts); mailDidChange() } }
    var mailSenders: [SenderRule] { didSet { d.set(MailSettings.encode(mailSenders), forKey: MailKeys.senders); mailDidChange() } }
    var mailCriteria: ReadingCriteria { didSet { d.set(MailSettings.encode(mailCriteria), forKey: MailKeys.criteria); mailDidChange() } }
    /// 0 = manual only; else 5 / 15 / 30 / 60 minutes.
    var mailSyncMinutes: Int { didSet { d.set(mailSyncMinutes, forKey: MailKeys.syncMinutes); mailDidChange() } }
    var mailAIMode: MailSettings.AIMode { didSet { d.set(mailAIMode.rawValue, forKey: MailKeys.aiMode); mailDidChange() } }
    /// nil = the AI-reading provider (`agent.provider` / a claude|codex `agent.mode`).
    var mailTriageProvider: AIProviderKind? {
        didSet {
            if let p = mailTriageProvider { d.set(p.rawValue, forKey: MailKeys.triageProvider) }
            else { d.removeObject(forKey: MailKeys.triageProvider) }
            mailDidChange()
        }
    }
    var mailTriageModelClaude: String { didSet { d.set(mailTriageModelClaude, forKey: MailKeys.triageModelClaude); mailDidChange() } }
    var mailTriageModelCodex: String { didSet { d.set(mailTriageModelCodex, forKey: MailKeys.triageModelCodex); mailDidChange() } }
    var mailTriageDailyMax: Int { didSet { d.set(mailTriageDailyMax, forKey: MailKeys.triageDailyMax); mailDidChange() } }
    var mailTriageBodyCap: Int { didSet { d.set(mailTriageBodyCap, forKey: MailKeys.triageBodyCap); mailDidChange() } }
    var mailMaxAttachmentMB: Int { didSet { d.set(mailMaxAttachmentMB, forKey: MailKeys.maxAttachmentMB); mailDidChange() } }
    var mailPrefillNotes: Bool { didSet { d.set(mailPrefillNotes, forKey: MailKeys.prefillNotes); mailDidChange() } }
    var mailNotifyNewRequests: Bool {
        didSet {
            d.set(mailNotifyNewRequests, forKey: MailKeys.notifyNewRequests)
            // Only emails captured after the switch went on are announced (MailRequestNotifier).
            if mailNotifyNewRequests != oldValue { mailNotifyBook.since = mailNotifyNewRequests ? Date() : nil }
            mailDidChange()
        }
    }
    var mailIncludeInDailyReminder: Bool {
        didSet { d.set(mailIncludeInDailyReminder, forKey: MailKeys.includeInDailyReminder); mailDidChange() }
    }
    /// Days after a card is handled before its body is purged; `mailKeepForever` (-1) keeps it
    /// (never 0 — the sync loop would purge every handled card at once).
    var mailRetentionDays: Int { didSet { d.set(mailRetentionDays, forKey: MailKeys.retentionDays); mailDidChange() } }
    /// How "3/10" in an email reads (`mail.dateOrder`, Settings ▸ Mail ▸ Reading criteria). Absent
    /// means month first, as for every existing install; the configuration layer reads the same key.
    var mailDateOrder: SlashDateOrder {
        didSet {
            d.set(mailDateOrder.rawValue, forKey: MailKeys.dateOrder)
            config.reload()
            mailDidChange()
        }
    }

    /// Called on the main actor after mail settings were written: debounced with `.edit` (no
    /// un-park) after any write (a keystroke in Research interests, a slider, a toggle), at once
    /// with `.retry(accountID)` from an explicit retry of one account (`notifyMailNow(accountID:)`:
    /// 「测试并保存」, an account added or edited). Only an un-park gives an account parked on a
    /// rejected app password / missing setup a new sign-in attempt — editing unrelated settings
    /// must never retry a rejected password, and saving account A never retries account B.
    @ObservationIgnored var onMailSettingsChange: ((MailSettingsNotice) -> Void)?
    /// `mailRetentionDays` value for "keep email text" (both the sync loop and maintenance skip < 0).
    static let mailKeepForever = -1
    @ObservationIgnored private var mailNotifyTask: Task<Void, Never>?
    private typealias MailKeys = MailSettings.Keys

    enum Keys {
        static let language = "language", showMenuBarCount = "menubar.showCount", pdfOpener = "pdf.opener"
        static let dailyBudget = "plan.dailyBudget", readingWeekdays = "plan.readingWeekdays"
        static let cutoffHour = "plan.cutoffHour", reminderEnabled = "reminder.enabled"
        static let reminderHour = "reminder.hour", reminderMinute = "reminder.minute"
        static let remindWhenEmpty = "reminder.whenEmpty", autoMarkDone = "plan.autoMarkDone"
        static let notifyOnAgentDone = "agent.notifyDone", agentMode = "agent.mode", autoRead = "agent.autoRead"
        static let cliPath = "agent.cliPath", agentModel = "agent.model", agentEffort = "agent.effort"
        static let agentProvider = "agent.provider", codexModel = "agent.codexModel", codexPath = "agent.codexPath"
        static let textBudget = "agent.textBudget", allowNewCategories = "agent.allowNewCategories"
        static let libraryPath = "library.path", importMode = "library.importMode"
        static let metadataLookup = "metadata.lookup", crossrefMailto = "metadata.mailto"
        static let setupCompleted = "setup.completed"
    }

    init(defaults: UserDefaults = .standard, domain: String? = nil) {
        d = defaults
        domainName = domain
        d.register(defaults: [
            Keys.language: "en", Keys.showMenuBarCount: true, Keys.pdfOpener: "preview",
            Keys.dailyBudget: 60, Keys.readingWeekdays: Array(1...7), Keys.cutoffHour: 18,
            Keys.reminderEnabled: true, Keys.reminderHour: 11, Keys.reminderMinute: 0,
            Keys.remindWhenEmpty: false, Keys.autoMarkDone: true, Keys.notifyOnAgentDone: true,
            Keys.agentMode: "off", Keys.autoRead: true, Keys.cliPath: "", Keys.agentModel: "sonnet",
            Keys.agentEffort: "medium", Keys.textBudget: 120_000, Keys.allowNewCategories: true,
            Keys.agentProvider: AIProviderKind.claude.rawValue, Keys.codexModel: AIProviderKind.defaultCodexModel,
            Keys.codexPath: "",
            Keys.libraryPath: AppPaths.production().library.path, Keys.importMode: "copy",
            Keys.metadataLookup: true, Keys.crossrefMailto: "", Keys.setupCompleted: false,
        ])
        language = UILang(rawValue: d.string(forKey: Keys.language) ?? "en") ?? .en
        showMenuBarCount = d.bool(forKey: Keys.showMenuBarCount)
        pdfOpener = d.string(forKey: Keys.pdfOpener) ?? "preview"
        dailyBudgetMinutes = d.integer(forKey: Keys.dailyBudget)
        readingWeekdays = Set((d.array(forKey: Keys.readingWeekdays) as? [Int]) ?? Array(1...7))
        cutoffHour = d.integer(forKey: Keys.cutoffHour)
        reminderEnabled = d.bool(forKey: Keys.reminderEnabled)
        reminderHour = d.integer(forKey: Keys.reminderHour)
        reminderMinute = d.integer(forKey: Keys.reminderMinute)
        remindWhenEmpty = d.bool(forKey: Keys.remindWhenEmpty)
        autoMarkDone = d.bool(forKey: Keys.autoMarkDone)
        notifyOnAgentDone = d.bool(forKey: Keys.notifyOnAgentDone)
        let mode = d.string(forKey: Keys.agentMode) ?? "off"
        agentMode = mode
        // A claude / codex agent.mode wins over a stale agent.provider (as in EngineSettings.load).
        agentProvider = AIProviderKind(rawValue: mode)
            ?? d.string(forKey: Keys.agentProvider).flatMap(AIProviderKind.init(rawValue:)) ?? .claude
        autoReadNewPapers = d.bool(forKey: Keys.autoRead)
        cliPathOverride = d.string(forKey: Keys.cliPath) ?? ""
        agentModel = d.string(forKey: Keys.agentModel) ?? "sonnet"
        codexModel = d.string(forKey: Keys.codexModel).flatMap { $0.isEmpty ? nil : $0 } ?? AIProviderKind.defaultCodexModel
        codexPathOverride = d.string(forKey: Keys.codexPath) ?? ""
        agentEffort = d.string(forKey: Keys.agentEffort) ?? "medium"
        textBudget = d.integer(forKey: Keys.textBudget)
        allowNewCategories = d.bool(forKey: Keys.allowNewCategories)
        libraryPath = d.string(forKey: Keys.libraryPath) ?? AppPaths.production().library.path
        importMode = d.string(forKey: Keys.importMode) ?? "copy"
        metadataLookup = d.bool(forKey: Keys.metadataLookup)
        crossrefMailto = d.string(forKey: Keys.crossrefMailto) ?? ""
        setupCompleted = d.bool(forKey: Keys.setupCompleted)
        // Reading assist and dedupe: what the engine loads (nothing registered, nothing written).
        assist = AssistSettings.load(from: d)
        dedupe = DedupeSettings.load(from: d)
        // Mail: exactly what the engine loads (its defaults for missing keys; nothing registered).
        let mail = MailSettings.load(from: d)
        mailEnabled = mail.enabled
        mailAccounts = mail.accounts
        mailSenders = mail.senders
        mailCriteria = mail.criteria
        mailSyncMinutes = mail.syncMinutes
        mailAIMode = mail.aiMode
        mailTriageProvider = mail.triageProvider
        mailTriageModelClaude = mail.triageModelClaude
        mailTriageModelCodex = mail.triageModelCodex
        mailTriageDailyMax = mail.triageDailyMax
        mailTriageBodyCap = mail.triageBodyCap
        mailMaxAttachmentMB = mail.maxAttachmentMB
        mailPrefillNotes = mail.prefillNotes
        mailNotifyNewRequests = mail.notifyNewRequests
        mailIncludeInDailyReminder = mail.includeInDailyReminder
        mailRetentionDays = mail.retentionDays
        mailDateOrder = mail.dateOrder
        config = ConfigStore(defaults: defaults)
        // didSet doesn't run during init — sync the observable language / provider explicitly.
        LangStore.shared.lang = language
        LangStore.shared.provider = agentProvider
    }

    /// True while AI reading is on (claude, codex or the mock).
    var aiEnabled: Bool { agentMode != AgentMode.off.rawValue }

    /// The real provider `agent.mode` runs (nil while off / mock).
    var activeProvider: AIProviderKind? { AIProviderKind(rawValue: agentMode) }

    /// Model slug a real run of `kind` uses (Settings ▸ AI pickers).
    func model(for kind: AIProviderKind) -> String { kind == .codex ? codexModel : agentModel }

    /// The engine-side settings these defaults produce (what `EngineSettings.load` would read).
    var engineSettings: EngineSettings { EngineSettings.load(from: d) }

    // MARK: Mail

    /// Snapshot of Settings ▸ Mail — identical to `MailSettings.load` on the same defaults.
    var mailSettings: MailSettings {
        MailSettings(enabled: mailEnabled, accounts: mailAccounts, senders: mailSenders, criteria: mailCriteria,
                     syncMinutes: mailSyncMinutes, aiMode: mailAIMode, triageProvider: mailTriageProvider,
                     triageModelClaude: mailTriageModelClaude, triageModelCodex: mailTriageModelCodex,
                     triageDailyMax: mailTriageDailyMax, triageBodyCap: mailTriageBodyCap,
                     maxAttachmentMB: mailMaxAttachmentMB, prefillNotes: mailPrefillNotes,
                     notifyNewRequests: mailNotifyNewRequests, includeInDailyReminder: mailIncludeInDailyReminder,
                     retentionDays: mailRetentionDays, dateOrder: mailDateOrder)
    }

    /// The provider AI triage sends to: the triage override, else the reading provider.
    var mailEffectiveTriageProvider: AIProviderKind { mailTriageProvider ?? activeProvider ?? agentProvider }

    /// Every mail write reaches the engine: `MailSyncActor.settingsDidChange(unpark:accountIDs:)`
    /// re-reads the settings and re-evaluates held triage; only an explicit retry un-parks — and
    /// only the account it names. Idempotent (the app and the settings tab both call it).
    func connectMail(to engine: Engine) {
        guard onMailSettingsChange == nil else { return }
        let mail = engine.mail
        onMailSettingsChange = { notice in
            Task { await mail.settingsDidChange(unpark: notice.unpark, accountIDs: notice.accountIDs) }
        }
    }

    /// Notifies at once and un-parks `accountID` only (「测试并保存」 / an account added or edited:
    /// that account should try again right away — Test & Save may have stored a new app password
    /// without changing the account itself; another account parked on a rejected password stays
    /// parked). Replaces a pending debounced notification (the engine re-reads every setting anyway).
    func notifyMailNow(accountID: String) {
        mailNotifyTask?.cancel()
        mailNotifyTask = nil
        onMailSettingsChange?(.retry(accountID))
    }

    private func mailDidChange() {
        mailNotifyTask?.cancel()
        mailNotifyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.mailNotifyTask = nil
            self.onMailSettingsChange?(.edit)
        }
    }

    // MARK: Mail request notifications

    private enum NotifyKeys {
        static let since = "mail.notify.since", armed = "mail.notify.armedAccounts", sent = "mail.notify.sent"
    }

    /// App-side bookkeeping of 「有新的阅读请求时通知我」 (`MailRequestNotifier`): when the switch went
    /// on, each account's first successful sync, the message ids already announced. The engine never
    /// reads these keys; only changed keys are written.
    var mailNotifyBook: MailRequestNotifyRules.Book {
        get {
            let armed = (d.dictionary(forKey: NotifyKeys.armed) as? [String: Double]) ?? [:]
            return MailRequestNotifyRules.Book(
                since: (d.object(forKey: NotifyKeys.since) as? Double).map { Date(timeIntervalSince1970: $0) },
                armed: armed.mapValues { Date(timeIntervalSince1970: $0) },
                sent: d.stringArray(forKey: NotifyKeys.sent) ?? [])
        }
        set {
            let old = mailNotifyBook
            if newValue.since != old.since {
                if let since = newValue.since { d.set(since.timeIntervalSince1970, forKey: NotifyKeys.since) }
                else { d.removeObject(forKey: NotifyKeys.since) }
            }
            if newValue.armed != old.armed { d.set(newValue.armed.mapValues(\.timeIntervalSince1970), forKey: NotifyKeys.armed) }
            if newValue.sent != old.sent { d.set(newValue.sent, forKey: NotifyKeys.sent) }
        }
    }

    /// Adds or replaces (same id) an account, keeping the list order.
    func upsertMailAccount(_ account: MailAccount) {
        if let i = mailAccounts.firstIndex(where: { $0.id == account.id }) {
            if mailAccounts[i] != account { mailAccounts[i] = account }
        } else {
            mailAccounts.append(account)
        }
    }

    func removeMailAccount(id: String) {
        mailAccounts.removeAll { $0.id == id }
    }

    /// Adds or replaces (same id) a sender rule, keeping the list order.
    func upsertSender(_ rule: SenderRule) {
        if let i = mailSenders.firstIndex(where: { $0.id == rule.id }) {
            if mailSenders[i] != rule { mailSenders[i] = rule }
        } else {
            mailSenders.append(rule)
        }
    }

    func removeSender(id: String) {
        mailSenders.removeAll { $0.id == id }
    }

    /// Re-reads the mail keys (another process — the CLI — may have written them).
    func reloadMail() {
        let m = MailSettings.load(from: d)
        guard m != mailSettings else { return }
        if m.enabled != mailEnabled { mailEnabled = m.enabled }
        if m.accounts != mailAccounts { mailAccounts = m.accounts }
        if m.senders != mailSenders { mailSenders = m.senders }
        if m.criteria != mailCriteria { mailCriteria = m.criteria }
        if m.syncMinutes != mailSyncMinutes { mailSyncMinutes = m.syncMinutes }
        if m.aiMode != mailAIMode { mailAIMode = m.aiMode }
        if m.triageProvider != mailTriageProvider { mailTriageProvider = m.triageProvider }
        if m.triageModelClaude != mailTriageModelClaude { mailTriageModelClaude = m.triageModelClaude }
        if m.triageModelCodex != mailTriageModelCodex { mailTriageModelCodex = m.triageModelCodex }
        if m.triageDailyMax != mailTriageDailyMax { mailTriageDailyMax = m.triageDailyMax }
        if m.triageBodyCap != mailTriageBodyCap { mailTriageBodyCap = m.triageBodyCap }
        if m.maxAttachmentMB != mailMaxAttachmentMB { mailMaxAttachmentMB = m.maxAttachmentMB }
        if m.prefillNotes != mailPrefillNotes { mailPrefillNotes = m.prefillNotes }
        if m.notifyNewRequests != mailNotifyNewRequests { mailNotifyNewRequests = m.notifyNewRequests }
        if m.includeInDailyReminder != mailIncludeInDailyReminder { mailIncludeInDailyReminder = m.includeInDailyReminder }
        if m.retentionDays != mailRetentionDays { mailRetentionDays = m.retentionDays }
        if m.dateOrder != mailDateOrder { mailDateOrder = m.dateOrder }
    }

    /// Re-read keys other processes may change (build script / CLI write `agent.mode`).
    /// Returns true when the reading provider or mode changed (callers wake the agent queue).
    @discardableResult
    func reloadExternal() -> Bool {
        let oldMode = agentMode, oldProvider = agentProvider
        if let raw = d.string(forKey: Keys.agentProvider), let kind = AIProviderKind(rawValue: raw),
           kind != agentProvider, AIProviderKind(rawValue: d.string(forKey: Keys.agentMode) ?? "off") == nil {
            agentProvider = kind
        }
        let mode = d.string(forKey: Keys.agentMode) ?? "off"
        if mode != agentMode { agentMode = mode }
        return agentMode != oldMode || agentProvider != oldProvider
    }

    // MARK: Library change (Settings ▸ Library ▸ Change…)

    /// What the next launch does before opening the library (`library.pendingAction`; read from
    /// the defaults each time — the launch clears it once done).
    var libraryPendingAction: LibraryPendingAction? { LibraryPendingAction.load(d) }

    /// `library.previousPath`: the library before the last change (for "Go Back").
    var libraryPreviousPath: String? { d.string(forKey: ConfigKeys.libraryPreviousPath) }

    /// Records a confirmed Change…: the next launch's action (nil: none — the same library),
    /// the new `library.path` and the previous one.
    func scheduleLibraryChange(path: String, pending: LibraryPendingAction?, previousPath: String) {
        if let pending { pending.save(d) } else { LibraryPendingAction.clear(d) }
        d.set(previousPath, forKey: ConfigKeys.libraryPreviousPath)
        libraryPath = path
    }

    /// "Keep Current Location": the pending change is dropped.
    func cancelLibraryChange(keeping current: String) {
        LibraryPendingAction.clear(d)
        libraryPath = current
    }

    // MARK: Settings transfer

    /// The persisted values of this store's domain only (never registered defaults) — what an
    /// export reads and an import plan compares against. A store on another defaults object
    /// without a `domain` name (a render / self-test suite) reads nothing — never the app's domain.
    var persistedDomain: PersistedDomain {
        if let domainName { return PersistedDomain(d.persistentDomain(forName: domainName) ?? [:]) }
        return d === UserDefaults.standard ? .app() : PersistedDomain([:])
    }

    /// Keys an import never writes, whatever a plan says (the safety floors: AI reading, mail and
    /// setup stay as they are) — plus every key of the "never" class.
    static let importNeverKeys: Set<String> = [
        "agent.mode", "mail.enabled", "setup.completed", "general.launchAtLogin",
        "reminder.lastDeliveredDay", "reminder.scheduledFires", "panel.screenID",
        ConfigKeys.libraryPendingAction, ConfigKeys.libraryPreviousPath,
    ]
    static let importNeverPrefixes = ["config.", "onboarding.", "guide.", "transfer.", "mail.notify."]

    /// The mail keys stored as JSON strings (`MailSettings.encode`) and `org.custom`.
    private static let jsonStringKeys: Set<String> = [MailKeys.accounts, MailKeys.senders, MailKeys.criteria, ConfigKeys.orgCustom]

    /// Whether an import may write `key`: never a safety-floor / never-class key, and — once the
    /// allowlist (`SettingsRegistry`) is filled — only a key it lists as transferable.
    static func importMayWrite(_ key: String) -> Bool {
        guard !importNeverKeys.contains(key), !importNeverPrefixes.contains(where: { key.hasPrefix($0) }) else { return false }
        guard !SettingsRegistry.entries.isEmpty else { return true }
        guard let entry = SettingsRegistry.entry(key) else { return false }
        return entry.keyClass != .never
    }

    /// Applies an import plan (`SettingsImporter.plan`): writes its keys — never `agent.mode`,
    /// `mail.enabled`, `setup.completed` or another never-key — then re-reads every setting so the
    /// stores' setters run (the engine gets one debounced mail notice). A different reading
    /// provider is not applied while AI reading is on (that would switch the running provider).
    /// Returns how many keys were written.
    @discardableResult
    func applyImport(_ plan: ImportPlan, now: Date = Date()) -> Int {
        var written = 0
        for (key, value) in plan.writes.sorted(by: { $0.key < $1.key }) where Self.importMayWrite(key) {
            if key == Keys.agentProvider, activeProvider != nil { continue }
            if Self.jsonStringKeys.contains(key) {
                switch value {
                case .string(let s): d.set(s, forKey: key)
                case .null: d.removeObject(forKey: key)
                default:
                    guard let data = try? JSONEncoder().encode(value) else { continue }
                    d.set(String(decoding: data, as: UTF8.self), forKey: key)
                }
            } else if let object = Self.plistObject(value) {
                d.set(object, forKey: key)
            } else {
                d.removeObject(forKey: key)
            }
            written += 1
        }
        guard written > 0 else { return 0 }
        d.set(now.timeIntervalSince1970, forKey: ConfigKeys.transferImportedAt)
        reloadFromDefaults()
        return written
    }

    /// `transfer.lastExportedAt` (the Getting Started backup item, Settings ▸ General).
    func markSettingsExported(at date: Date = Date()) {
        d.set(date.timeIntervalSince1970, forKey: ConfigKeys.transferLastExportedAt)
    }

    /// A JSON value as a property-list object (integral numbers as Int); nil for null.
    static func plistObject(_ v: JSONValue) -> Any? {
        switch v {
        case .null: return nil
        case .bool(let b): return b
        case .number(let n): return n.rounded() == n && abs(n) < 9.0e15 ? Int(n) : n
        case .string(let s): return s
        case .array(let a): return a.compactMap(plistObject)
        case .object(let o): return o.compactMapValues(plistObject)
        }
    }

    /// Re-reads every setting an import may have written (only changed values are assigned, so
    /// each setter — and its engine notification — runs once). Never touches `agent.mode`,
    /// `mail.enabled` or `setup.completed`.
    func reloadFromDefaults() {
        func set<T: Equatable>(_ current: T, _ fresh: T, _ assign: (T) -> Void) { if current != fresh { assign(fresh) } }
        set(language, UILang(rawValue: d.string(forKey: Keys.language) ?? "en") ?? .en) { language = $0 }
        set(showMenuBarCount, d.bool(forKey: Keys.showMenuBarCount)) { showMenuBarCount = $0 }
        set(pdfOpener, d.string(forKey: Keys.pdfOpener) ?? "preview") { pdfOpener = $0 }
        set(dailyBudgetMinutes, d.integer(forKey: Keys.dailyBudget)) { dailyBudgetMinutes = $0 }
        set(readingWeekdays, Set((d.array(forKey: Keys.readingWeekdays) as? [Int]) ?? Array(1...7))) { readingWeekdays = $0 }
        set(cutoffHour, d.integer(forKey: Keys.cutoffHour)) { cutoffHour = $0 }
        set(reminderEnabled, d.bool(forKey: Keys.reminderEnabled)) { reminderEnabled = $0 }
        set(reminderHour, d.integer(forKey: Keys.reminderHour)) { reminderHour = $0 }
        set(reminderMinute, d.integer(forKey: Keys.reminderMinute)) { reminderMinute = $0 }
        set(remindWhenEmpty, d.bool(forKey: Keys.remindWhenEmpty)) { remindWhenEmpty = $0 }
        set(autoMarkDone, d.bool(forKey: Keys.autoMarkDone)) { autoMarkDone = $0 }
        set(notifyOnAgentDone, d.bool(forKey: Keys.notifyOnAgentDone)) { notifyOnAgentDone = $0 }
        if activeProvider == nil, let raw = d.string(forKey: Keys.agentProvider), let kind = AIProviderKind(rawValue: raw) {
            set(agentProvider, kind) { agentProvider = $0 }
        }
        set(autoReadNewPapers, d.bool(forKey: Keys.autoRead)) { autoReadNewPapers = $0 }
        set(cliPathOverride, d.string(forKey: Keys.cliPath) ?? "") { cliPathOverride = $0 }
        set(agentModel, d.string(forKey: Keys.agentModel) ?? "sonnet") { agentModel = $0 }
        set(codexModel, d.string(forKey: Keys.codexModel).flatMap { $0.isEmpty ? nil : $0 } ?? AIProviderKind.defaultCodexModel) { codexModel = $0 }
        set(codexPathOverride, d.string(forKey: Keys.codexPath) ?? "") { codexPathOverride = $0 }
        set(agentEffort, d.string(forKey: Keys.agentEffort) ?? "medium") { agentEffort = $0 }
        set(textBudget, d.integer(forKey: Keys.textBudget)) { textBudget = $0 }
        set(allowNewCategories, d.bool(forKey: Keys.allowNewCategories)) { allowNewCategories = $0 }
        set(libraryPath, d.string(forKey: Keys.libraryPath) ?? AppPaths.production().library.path) { libraryPath = $0 }
        set(importMode, d.string(forKey: Keys.importMode) ?? "copy") { importMode = $0 }
        set(metadataLookup, d.bool(forKey: Keys.metadataLookup)) { metadataLookup = $0 }
        set(crossrefMailto, d.string(forKey: Keys.crossrefMailto) ?? "") { crossrefMailto = $0 }
        // The duplicate check's settings (Settings ▸ Library ▸ Duplicates) travel; assist.mode never does.
        set(dedupe, DedupeSettings.load(from: d)) { dedupe = $0 }
        set(assist, AssistSettings.load(from: d)) { assist = $0 }
        reloadMail()
        config.reload()
    }

    // MARK: Launch at login

    var launchAtLoginAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    var launchAtLogin: Bool {
        guard launchAtLoginAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        guard launchAtLoginAvailable else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.app.error("SMAppService error: \(error.localizedDescription, privacy: .public)")
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
    }
}

/// What `SettingsStore.onMailSettingsChange` tells the engine (`MailSyncActor.settingsDidChange`).
struct MailSettingsNotice: Equatable {
    /// Give parked accounts a new sign-in attempt.
    var unpark: Bool
    /// The accounts to un-park; nil: every account (only 「立即同步」 does that, directly).
    var accountIDs: Set<String>?

    /// Any settings write: re-read, nobody un-parked.
    static let edit = MailSettingsNotice(unpark: false, accountIDs: nil)
    /// One account was tested and saved, added or edited: it — and only it — tries again.
    static func retry(_ accountID: String) -> MailSettingsNotice { MailSettingsNotice(unpark: true, accountIDs: [accountID]) }
}

/// 「立即同步」 (the inbox toolbar, Settings ▸ Mail): every enabled account syncs now and every
/// parked account gets a new attempt.
enum MailSyncCommands {
    static func syncAll(_ mail: MailSyncActor) async {
        await mail.settingsDidChange(unpark: true, accountIDs: nil)
        await mail.syncNow()
    }
}
