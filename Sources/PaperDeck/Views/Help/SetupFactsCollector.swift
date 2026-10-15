import AppKit
import Observation
import PaperDeckCore
import PaperDeckConfig
import PaperDeckShared

/// The live `SetupFacts` the guides check. Cheap facts (no I/O) come from the app's state when
/// read; probed facts are refreshed only while a guide view is visible (`activate` / `deactivate`):
/// the file system every 5 s, the widget and signing every 30 s, the other AI provider on demand
/// (at most every 20 s), and when PaperDeck becomes active again.
@Observable
final class SetupFactsCollector {
    let settings: SettingsStore
    let guide: GuideStore
    @ObservationIgnored let sources: any FactSources
    /// Set once the engine is open (the library's papers, the agent status, mail statuses).
    weak var state: AppState?
    /// Renders and self-tests: these facts are shown as they are (nothing is probed).
    var fixed: SetupFacts?
    /// The identity guard's last answer (AppDelegate).
    var libraryIdentity: LibraryIdentityCheck?
    /// Preflight: the folder the Library page is about to use (nil: the settings' library).
    var libraryOverride: URL?

    private(set) var library: ProbeState<LibraryFact> = .unknown
    private(set) var providers: [AIProviderKind: ProbeState<ProviderStatus>] = [:]
    private(set) var notifications: ProbeState<NotificationFact> = .unknown
    private(set) var loginItem: ProbeState<LoginItemFact> = .unknown
    private(set) var widget: ProbeState<WidgetFact> = .unknown
    private(set) var app: ProbeState<AppLocationFact> = .unknown
    private(set) var signing: ProbeState<SigningFact> = .unknown
    private(set) var cloud: ProbeState<CloudFact> = .unknown
    private(set) var folderExists: [String: Bool] = [:]
    private(set) var passwords: [String: Bool] = [:]
    private(set) var suggestedFolderExists: Bool?
    /// Live papers without a full-text row (`Engine.papersMissingFullTextCount`), counted in the
    /// slow refresh; nil until the engine has answered — the paper facts stay `.unknown` until
    /// then, so "search finds the full text" is never ticked without a check.
    private(set) var fullTextMissing: Int?

    @ObservationIgnored private var active: Set<String> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastSlow = Date.distantPast
    @ObservationIgnored private var lastProviderProbe: [AIProviderKind: Date] = [:]
    @ObservationIgnored private var becameActive: NSObjectProtocol?
    @ObservationIgnored private let home: URL

    init(settings: SettingsStore, guide: GuideStore, sources: any FactSources, home: URL = SharedPaths.realHome) {
        self.settings = settings
        self.guide = guide
        self.sources = sources
        self.home = home
    }

    // MARK: Visibility

    /// A guide view appeared (`id` unique per view): probing starts / continues.
    func activate(_ id: String) {
        guard fixed == nil else { return }
        let wasIdle = active.isEmpty
        active.insert(id)
        guard wasIdle else { return }
        becameActive = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            // Back from Terminal / System Settings: re-check (the CLIs only if a page asked for them).
            MainActor.assumeIsolated {
                guard let self else { return }
                self.kick(providers: !self.providers.isEmpty)
            }
        }
        // The AI CLIs are probed only when a page asks (`kick(providers: true)`), never on a timer.
        loop = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(slow: first || Date().timeIntervalSince(self.lastSlow) >= 30, providers: false)
                first = false
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// The view disappeared; the last one stops probing.
    func deactivate(_ id: String) {
        active.remove(id)
        guard active.isEmpty else { return }
        loop?.cancel()
        loop = nil
        if let becameActive { NotificationCenter.default.removeObserver(becameActive) }
        becameActive = nil
    }

    var isActive: Bool { !active.isEmpty }

    /// "I've signed in", returning from Terminal, a changed folder: probe now.
    func kick(providers: Bool = false) {
        guard fixed == nil else { return }
        Task { await refresh(slow: false, providers: providers, force: providers) }
    }

    // MARK: Probing

    @ObservationIgnored private var lastOnce = Date.distantPast

    /// The Today card: one pass without the AI CLIs, at most every 30 s (no loop).
    func refreshOnce() async {
        guard fixed == nil, !isActive, Date().timeIntervalSince(lastOnce) >= 30 else { return }
        lastOnce = Date()
        await refresh(slow: true, providers: false)
    }

    /// One refresh pass. `providers`: also the AI CLIs (throttled to 20 s unless `force`).
    func refresh(slow: Bool, providers probeProviders: Bool, force: Bool = false) async {
        guard fixed == nil else { return }
        guide.reload()
        let root = libraryOverride ?? state?.engine.paths.library ?? URL(fileURLWithPath: settings.libraryPath, isDirectory: true)
        let reminderEnabled = settings.reminderEnabled
        async let lib = sources.library(root)
        async let notes = sources.notifications(reminderEnabled: reminderEnabled)
        async let login = sources.loginItem()
        async let place = sources.appLocation()
        async let roots = sources.cloud(home: home)
        var libFact = await lib
        libFact.identity = libraryIdentity
        library = .value(libFact)
        notifications = .value(await notes)
        loginItem = .value(await login)
        app = .value(await place)
        let cloudFact = await roots
        cloud = .value(cloudFact)

        var folders: [String: Bool] = [:]
        for a in settings.mailAccounts where a.kind == .folder {
            if let p = a.folderPath { folders[p] = await sources.folderExists(p) }
        }
        folderExists = folders
        if let suggested = CloudRootLocator.suggestedFolder(
            for: .m365PowerAutomate, roots: cloudFact.roots,
            existingMailFolders: settings.mailAccounts.compactMap { $0.folderPath.map { URL(fileURLWithPath: $0) } },
            org: settings.config.snapshot.organization, lastChoice: guide.lastCloudRoot, home: home) {
            suggestedFolderExists = await sources.folderExists(suggested.path)
        } else {
            suggestedFolderExists = nil
        }

        if slow {
            lastSlow = Date()
            widget = .value(await sources.widget())
            signing = .value(await sources.signing())
            // Keychain items by their attributes only (never the secret), at most every 30 s.
            var pw: [String: Bool] = [:]
            for a in settings.mailAccounts where a.kind == .imap {
                pw[a.id] = await sources.passwordPresent(secretKey: a.secretKey)
            }
            passwords = pw
            await countFullText()
        } else if fullTextCountedLive != state?.snapshot?.rows.count {
            // Papers came or went since the last count (a rebuild, an import): count again now
            // rather than at the next slow pass.
            await countFullText()
        }
        if probeProviders { await refreshProviders(force: force) }
    }

    /// The live count `fullTextMissing` was taken at (re-counted when the library changes size).
    @ObservationIgnored private var fullTextCountedLive: Int?

    /// Counts the live papers without full text (one database query; a failure keeps the last answer).
    func countFullText() async {
        guard fixed == nil, let state else { return }
        let live = state.snapshot?.rows.count
        guard let missing = try? await state.engine.papersMissingFullTextCount() else { return }
        fullTextMissing = missing
        fullTextCountedLive = live
    }

    /// After a re-index: count again (the guides' "search finds the full text" step updates now).
    func recountFullText() {
        guard fixed == nil else { return }
        Task { await countFullText() }
    }

    /// The selected provider comes from the agent queue when it describes it (no extra CLI run);
    /// the other one — and both before the engine exists — through `ProviderProbe` (zero quota).
    func refreshProviders(force: Bool) async {
        for kind in AIProviderKind.allCases {
            if queueStatus(kind) != nil { continue }
            if !force, let last = lastProviderProbe[kind], Date().timeIntervalSince(last) < 20 { continue }
            lastProviderProbe[kind] = Date()
            if providers[kind]?.known == nil { providers[kind] = .checking }
            let override = kind == .claude ? settings.cliPathOverride : settings.codexPathOverride
            providers[kind] = .value(await sources.provider(kind, overridePath: override))
        }
    }

    /// The agent queue's status of `kind`, as a `ProviderStatus` (nil while it doesn't describe it).
    private func queueStatus(_ kind: AIProviderKind) -> ProviderStatus? {
        guard let s = state?.agentStatus, s.describes(kind) else { return nil }
        switch s.provider {
        case .ready(let plan, let version): return .ready(plan: plan, version: version, path: "")
        case .notInstalled: return .notInstalled
        case .notLoggedIn(let code): return .notLoggedIn(code)
        case .unsupported(let code): return .unsupported(code)
        case .unknown, .disabled: return nil
        }
    }

    // MARK: Facts

    /// The origin the guides see (renders and self-tests: the canned facts'), without composing
    /// the facts (`GettingStartedCard.isShown` asks this first).
    var origin: ConfigOrigin? {
        if let fixed { return fixed.profile.origin }
        return settings.config.snapshot.origin
    }

    /// How often `facts` was composed (`--selftest onboarding`: a legacy Today composes none).
    @ObservationIgnored private(set) var factsComposed = 0

    /// The facts now (cheap facts composed on every read).
    var facts: SetupFacts {
        factsComposed += 1
        if let fixed { return fixed }
        var statuses = providers
        for kind in AIProviderKind.allCases {
            if let s = queueStatus(kind) {
                // Keep the probed path when the queue (which doesn't carry one) says the same.
                if case .ready(let plan, let version, _) = s, case .ready(_, _, let path)? = providers[kind]?.known {
                    statuses[kind] = .value(.ready(plan: plan, version: version, path: path))
                } else {
                    statuses[kind] = .value(s)
                }
            }
        }
        let paused = state?.agentStatus.pausedUntil.flatMap { $0 > Date() ? $0 : nil }
        let ai = AIFact(mode: AgentMode(rawValue: settings.agentMode) ?? .off, provider: settings.agentProvider,
                        decision: guide.aiDecision, statuses: statuses, pausedUntil: paused)

        return SetupFacts(library: library, papers: papers, activity: guide.activity, ai: ai,
                          notifications: notifications, loginItem: loginItem, widget: widget, app: app,
                          signing: signing, mail: mail, cloud: cloud,
                          transfer: TransferFact(lastExportedAt: guide.lastExportedAt, importedAt: guide.importedAt),
                          profile: ProfileFact(origin: settings.config.snapshot.origin, fieldID: guide.storedFieldID,
                                               organizationID: guide.storedOrganizationID,
                                               readerCustomized: settings.config.readerOverride != nil),
                          features: [.settingsTransfer, .libraryFlows, .widgetRepair])
    }

    private var papers: ProbeState<PaperCounts> {
        guard let state else { return .value(PaperCounts()) }       // preflight: no library yet
        guard let snap = state.snapshot else { return .unknown }
        return Self.paperCounts(snap.rows.map(\.paper), fullTextMissing: fullTextMissing)
    }

    /// The paper facts from the snapshot's papers plus the engine's full-text count. The snapshot
    /// has no full-text counts, so until the engine has answered (`fullTextMissing == nil`) the
    /// whole fact is `.unknown` — never "indexed" by assumption.
    static func paperCounts(_ papers: [Paper], fullTextMissing: Int?) -> ProbeState<PaperCounts> {
        guard let fullTextMissing else { return .unknown }
        let live = papers.count
        return .value(PaperCounts(live: live, withCard: papers.count(where: { $0.card != nil }),
                                  opened: papers.count(where: { $0.openedAt != nil }),
                                  missingFiles: papers.count(where: { $0.flags.contains(.missing) }),
                                  fullTextIndexed: max(0, live - fullTextMissing)))
    }

    private var mail: MailFact {
        let snap = state?.mailSnapshot
        let infos = Dictionary((snap?.accounts ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var cards: [String: Int] = [:]
        for list in snap?.groups.values.map({ $0 }) ?? [] {
            for c in list { if let id = c.account?.id { cards[id, default: 0] += 1 } }
        }
        let accounts = settings.mailAccounts.map { a -> MailAccountFact in
            // The status as the inbox pill and Settings ▸ Mail show it, and whether the last pass got
            // through (skipped or undownloadable emails are no "server isn't reachable").
            MailAccountFact(id: a.id, source: MailSourceResolver.source(of: a), info: infos[a.id], cards: cards[a.id] ?? 0,
                            passwordPresent: a.kind == .imap ? passwords[a.id] : nil,
                            folderExists: a.kind == .folder ? a.folderPath.flatMap { folderExists[$0] } : nil)
        }
        var senders: [SenderKind: Int] = [:]
        for r in settings.mailSenders where r.enabled { senders[r.kind, default: 0] += 1 }
        return MailFact(enabled: settings.mailEnabled, decision: guide.mailDecision, accounts: accounts, senders: senders,
                        emlImportedManually: guide.activity[.emlImported] != nil,
                        suggestedFolderExists: suggestedFolderExists)
    }
}
