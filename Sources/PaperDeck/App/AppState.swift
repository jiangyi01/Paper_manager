import AppKit
import Observation
import PaperDeckCore
import PaperDeckConfig

/// Sidebar sections of the library window.
enum SidebarItem: Hashable {
    case today, toRead, reading, done, all, needsAttention, uncategorized, recentlyDeleted
    case category(Int64)
    /// 邮件 / Mail inbox (MAIL_DESIGN Part A §3): email cards instead of paper cards.
    case mail
}

enum SortOrder: String, CaseIterable {
    case deadline, added, title
}

/// Window/navigation actions the state layer can request. AppDelegate installs
/// the implementations (so views never talk to window controllers directly).
struct AppRouter {
    var showLibrary: () -> Void = {}
    var showPaper: (_ id: String) -> Void = { _ in }
    var showToday: () -> Void = {}
    /// Library window ▸ Mail, selecting the email when an id is given (deep link paperdeck://mail[/id],
    /// menu-bar row, panel peek line, 「已匹配邮件请求」 toasts). AppState installs a default.
    var showMail: (_ id: String?) -> Void = { _ in }
    var showSettings: (_ tab: String?) -> Void = { _ in }
    /// The setup window in revisit mode (Settings ▸ General ▸ Setup Assistant…, Help ▸ Setup Assistant…).
    var showSetupAssistant: () -> Void = {}
    /// Help Center at a topic (nil: Getting Started).
    var showHelp: (_ topic: GuideTopicID?) -> Void = { _ in }
    /// Opens the menu-bar menu (the tour's [Show Me]).
    var showMenuBarMenu: () -> Void = {}
    var armDropPanel: (_ seconds: TimeInterval) -> Void = { _ in }
    var pickAndImportFiles: () -> Void = {}
    var pickAndImportFolder: () -> Void = {}
}

/// Single observable source of truth for all windows. Owns the engine
/// subscription; every view reads from here and calls its methods.
@Observable
final class AppState {
    let engine: Engine
    let settings: SettingsStore
    var router = AppRouter()
    /// Onboarding and Help Center state on this Mac (in memory unless a defaults domain is given).
    let guide: GuideStore
    /// The live facts the Help Center and the Getting Started card check (AppDelegate / renders).
    var facts: SetupFactsCollector?

    // Reading assist (READING_ASSIST_PLAN §6.0): one model per slice, each in its slice's own file.
    /// Multi-select (Slice C, App/SelectionModel.swift). The focused paper stays `selectedPaperID`.
    let selection = SelectionModel()
    /// Duplicate reviews (Slice B, App/DedupeUIModel.swift).
    let dedupe = DedupeUIModel()
    /// Explain & Ask state shared by the assist surfaces (Slice A, Assist/AssistUIModel.swift).
    let assist = AssistUIModel()
    /// Edits saved a moment later (the notes editor's 1 s debounce): quitting writes them first
    /// (`AppDelegate.applicationShouldTerminate`).
    @ObservationIgnored let pendingSaves = PendingSaves()

    // Library read model (refreshed on every committed change, debounced)
    private(set) var snapshot: LibrarySnapshot? { didSet { rowsGeneration &+= 1 } }
    private(set) var agentStatus = AgentQueueStatus()
    private(set) var queuePositions: [Int64: Int] = [:]

    // Import feedback (floating panel)
    private(set) var importRows: [ImportRowUpdate] = []
    private(set) var toasts: [Toast] = []
    /// Set when a finished batch needs the "schedule / read with Claude?" dialog.
    var pendingBatch: ImportBatchSummary?

    // Navigation
    var sidebar: SidebarItem = .today { didSet { rowsGeneration &+= 1 } }
    var selectedPaperID: String?
    var searchText: String = "" { didSet { scheduleSearch() } }
    private(set) var searchResults: [String]? { didSet { rowsGeneration &+= 1 } }
    var sort: SortOrder = .deadline { didSet { rowsGeneration &+= 1 } }
    /// Bumped whenever an input of `visibleRows` changes (snapshot, sidebar, search, sort): the
    /// visible rows and the grid's sections are computed once per change, not on every read (one
    /// render reads them from the grid, the subtitle, the inspector and the selection bar).
    @ObservationIgnored private(set) var rowsGeneration = 0
    @ObservationIgnored private var visibleRowsCache: (generation: Int, rows: [PaperRow])?

    // Banners
    var atRiskBannerDismissed = false
    private(set) var lastError: String?

    // Mail (AppState+Mail.swift)
    /// The Mail inbox read model (refreshed on ChangeHub `.mail` / `.mailBulk`, periodically, on demand).
    var mailSnapshot: MailSnapshot?
    /// The email card shown in the inspector while the sidebar is on Mail.
    var selectedMailID: String?
    /// The inbox's segmented filter.
    var mailFilter: MailInboxFilter = .pending
    /// Rows / cards with an operation in flight (spinners, disabled buttons): item ids and message ids.
    var mailBusy: Set<String> = []
    /// Cards whose 「让 AI 分析」 was just clicked (shown as waiting until the next snapshot says more).
    var mailAIRequested: Set<String> = []
    /// 立即同步 is running.
    var mailSyncing = false
    /// Settings ▸ Mail should open the Power Automate guide (the account id, "" for none) — set by
    /// the 「不是完整的邮件」 hints, consumed by `MailSettingsTab`.
    var mailGuideRequest: String?
    @ObservationIgnored var mailRefreshTask: Task<Void, Never>?
    @ObservationIgnored var mailRefreshedAt = Date.distantPast
    /// Every new inbox snapshot (the app's `MailRequestNotifier`; never set by renders / the CLI).
    @ObservationIgnored var onMailSnapshot: ((MailSnapshot) -> Void)?

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var toastExpiry: [String: Task<Void, Never>] = [:]
    /// The [Undo] of a toast goes when the engine's record does (`Toast.undoButtonLifetime`).
    @ObservationIgnored private var undoExpiry: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var rowExpiry: [String: Task<Void, Never>] = [:]

    init(engine: Engine, settings: SettingsStore, guide: GuideStore = GuideStore(defaults: nil)) {
        self.engine = engine
        self.settings = settings
        self.guide = guide
        router.showMail = { [weak self] id in self?.openMail(id) }
        selection.attach(self)
        dedupe.attach(self)
        assist.attach(self)
    }

    // MARK: Lifecycle

    func start() {
        // Settings ▸ Mail writes (from any window) reach the mail loop: MailSyncActor.settingsDidChange(unpark:accountIDs:).
        settings.connectMail(to: engine)
        let changes = engine.changes.subscribe()
        tasks.append(Task { [weak self] in
            for await change in changes {
                switch change {
                case .mail, .mailBulk: self?.scheduleMailRefresh()
                default: self?.scheduleRefresh()
                }
            }
        })
        let events = engine.events.subscribe()
        tasks.append(Task { [weak self] in
            for await e in events { self?.handle(e) }
        })
        // The today plan depends on the clock (cutoff hour, day change): refresh periodically too.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                self?.scheduleRefresh()
            }
        })
        scheduleRefresh(delay: .zero)
        Task { agentStatus = await engine.agents.status() }
        tasks += startMail()
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    /// Coalesces bursts of ChangeHub events into one snapshot read.
    func scheduleRefresh(delay: Duration = .milliseconds(150)) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            do {
                let snap = try await self.engine.librarySnapshot()
                let positions = await self.engine.agents.queuePositions()
                guard !Task.isCancelled else { return }
                self.snapshot = snap
                self.queuePositions = positions
            } catch {
                Log.app.error("snapshot failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Derived lists

    /// Rows for the current sidebar selection, filtered by search, sorted. Computed once per change
    /// of its inputs (`rowsGeneration`); every read still registers them with Observation.
    var visibleRows: [PaperRow] {
        let snap = snapshot
        _ = (sidebar, sort, searchResults)
        if let cached = visibleRowsCache, cached.generation == rowsGeneration { return cached.rows }
        let rows = Self.visibleRows(snap, sidebar: sidebar, searchResults: searchResults, sort: sort)
        visibleRowsCache = (rowsGeneration, rows)
        return rows
    }

    private static func visibleRows(_ snapshot: LibrarySnapshot?, sidebar: SidebarItem, searchResults: [String]?,
                                    sort: SortOrder) -> [PaperRow] {
        guard let snap = snapshot else { return [] }
        var rows: [PaperRow]
        switch sidebar {
        case .today: rows = snap.todayRows
        case .toRead: rows = snap.rows.filter { $0.paper.status == .toRead }
        case .reading: rows = snap.rows.filter { $0.paper.status == .reading }
        case .done: rows = snap.rows.filter { $0.paper.status == .done }
        case .all: rows = snap.rows
        case .needsAttention: rows = snap.needsAttention
        case .uncategorized: rows = snap.rows.filter { $0.paper.categoryPK == nil }
        case .recentlyDeleted: rows = snap.deleted
        case .category(let pk): rows = snap.rows.filter { $0.paper.categoryPK == pk }
        case .mail: return []
        }
        if let results = searchResults {
            let rank = Dictionary(results.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            return rows.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
        }
        if sidebar == .today || sidebar == .recentlyDeleted { return rows }
        return sorted(rows, by: sort)
    }

    private static func sorted(_ rows: [PaperRow], by sort: SortOrder) -> [PaperRow] {
        switch sort {
        case .deadline:
            return rows.sorted {
                switch ($0.paper.deadline, $1.paper.deadline) {
                case let (a?, b?) where a != b: return a < b
                case (nil, _?): return false
                case (_?, nil): return true
                default: return $0.paper.queueRank < $1.paper.queueRank
                }
            }
        case .added: return rows.sorted { $0.paper.addedAt > $1.paper.addedAt }
        case .title: return rows.sorted { $0.paper.title.localizedCaseInsensitiveCompare($1.paper.title) == .orderedAscending }
        }
    }

    var selectedRow: PaperRow? {
        guard let id = selectedPaperID, let snap = snapshot else { return nil }
        return snap.row(id: id) ?? snap.deleted.first { $0.id == id }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchResults = nil; return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            let ids = (try? await self.engine.search(q)) ?? []
            guard !Task.isCancelled else { return }
            self.searchResults = ids
        }
    }

    // MARK: Import

    /// Entry point for every drop / Open With / file picker.
    func ingest(_ items: [IntakeItem], origin: ImportOrigin, ignoredNames: [String] = [],
                scheduling: BatchScheduling = .automatic, ai: BatchAIPolicy = .automatic) {
        if !ignoredNames.isEmpty {
            let names = ignoredNames.prefix(3).joined(separator: ", ")
            post(Toast(kind: .warning, message: L.ignoredNonPDF(count: ignoredNames.count, names: names)))
        }
        guard !items.isEmpty else { return }
        let options = ImportOptions(origin: origin, scheduling: scheduling, ai: ai)
        Task { _ = await engine.intake.ingest(items, options: options) }
    }

    // MARK: Engine events

    private func handle(_ e: EngineEvent) {
        // The duplicate check sees every event first (it may take over the same-work toast);
        // with dedupe off or unavailable it consumes nothing.
        if dedupe.handle(e) { return }
        switch e {
        case .importRow(let row):
            if let i = importRows.firstIndex(where: { $0.id == row.id }) { importRows[i] = row } else { importRows.append(row) }
            if row.stage.isTerminal { expireRow(row.id) }
        case .toast(let t):
            post(t)
        case .agentStatus(let s):
            let triageChanged = s.triageQueued != agentStatus.triageQueued
                || s.runningTriageMessagePK != agentStatus.runningTriageMessagePK
            agentStatus = s
            // "Running" lives only in the queue: the email cards follow its status at once.
            if triageChanged { scheduleMailRefresh() }
        case .batchFinished(let summary):
            if !summary.heldForAI.isEmpty || summary.added.count > 10 { pendingBatch = summary }
        case .assistStatus(let s):
            assist.update(s)
        case .dedupe:
            break                                   // DedupeUIModel.handle consumes these once it is available
        case .batchApplied(let notice):
            selection.didApply(notice)
        }
    }

    private func expireRow(_ id: String) {
        rowExpiry[id]?.cancel()
        rowExpiry[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.importRows.removeAll { $0.id == id }
        }
    }

    var hasActiveImports: Bool { importRows.contains { !$0.stage.isTerminal } }

    // MARK: Toasts

    func post(_ toast: Toast) {
        if let i = toasts.firstIndex(where: { $0.id == toast.id }) { toasts[i] = toast } else { toasts.append(toast) }
        if toasts.count > 6 { toasts.removeFirst(toasts.count - 6) }
        if !toast.isSticky {
            toastExpiry[toast.id]?.cancel()
            toastExpiry[toast.id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.dismissToast(toast.id)
            }
        }
        scheduleUndoExpiry(toast)
    }

    /// An [Undo] (今天跳过, a multi-select batch, a duplicate decision) works for `UndoToken.lifetime`
    /// only: when that window closes the button goes and the toast says "Undo expired" (it then
    /// expires like a plain toast). A sticky toast would otherwise keep a button that does nothing.
    private func scheduleUndoExpiry(_ toast: Toast) {
        let id = toast.id
        undoExpiry[id]?.cancel()
        undoExpiry[id] = nil
        guard toast.undoTokens != nil else { return }
        undoExpiry[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Toast.undoButtonLifetime))
            guard !Task.isCancelled, let self else { return }
            self.undoExpiry[id] = nil
            guard let shown = self.toasts.first(where: { $0.id == id }),
                  let expired = shown.withUndoExpired(note: L.Select.undoExpired) else { return }
            self.post(expired)
        }
    }

    func dismissToast(_ id: String) {
        toasts.removeAll { $0.id == id }
        toastExpiry[id]?.cancel()
        toastExpiry[id] = nil
        undoExpiry[id]?.cancel()
        undoExpiry[id] = nil
    }

    var hasStickyToasts: Bool { toasts.contains { $0.isSticky } }

    func handleToastAction(_ action: Toast.Action, toastID: String) {
        dismissToast(toastID)
        switch action {
        case .openPaper(let id):
            router.showPaper(id)
        case .setHighPriority(let id):
            perform { try await self.engine.setPriority(paperID: id, .high) }
        case .replaceKeepingChecklist(let pending):
            Task { await engine.intake.resolvePending(pendingID: pending, replace: true) }
        case .ignorePending(let pending):
            Task { await engine.intake.resolvePending(pendingID: pending, replace: false) }
        case .restorePaper(let id):
            perform { try await self.engine.restore(paperID: id) }
        case .openInBrowser(let url):
            NSWorkspace.shared.open(url)
        case .undo(let token):
            Task {
                // False: the record is gone (expired or already used) — say so instead of nothing.
                if (try? await engine.undo(token: token)) != true {
                    post(Toast(kind: .info, message: L.Select.undoUnavailable))
                }
            }
        case .openSettings(let tab):
            router.showSettings(tab)
        case .openMail(let id):
            router.showMail(id)
        case .linkMailItem(let itemID, let paperID):
            perform { try await self.engine.linkMailItem(itemID: itemID, paperID: paperID) }
        case .undoMailLink(let token):
            perform {
                let undone = try await self.engine.undoMailLink(token: token)
                self.post(Toast(id: "mail-link-undo-\(token)", kind: undone ? .success : .info,
                                message: undone ? L.Mail.linkUndone : L.Mail.linkUndoFailed))
            }
        case .openDuplicateReview(let id):
            dedupe.openReview(id: id)
        case .resolveDuplicate(let reviewID, let choice):
            dedupe.resolveFromToast(reviewID, choice)
        }
    }

    // MARK: Operations

    /// Runs an engine operation; failures become an error toast (zh/en).
    func perform(_ op: @escaping () async throws -> Void) {
        Task {
            do { try await op() } catch { report(error) }
        }
    }

    func report(_ error: Error) {
        let message: String
        if let e = error as? PaperOperationError { message = e.message(settings.language) }
        else if let e = error as? MailOperationError { message = e.message(settings.language) }
        else if let e = error as? MailTriageError { message = e.message(settings.language) }
        else if let e = error as? QAError { message = e.message(settings.language) }
        else if let e = error as? ExplainOperationError { message = e.message(settings.language) }
        else { message = String(describing: error) }
        lastError = message
        post(Toast(kind: .error, message: message))
    }

    /// 今天跳过: moves today's auto DDLs one reading day and shows an undo toast.
    func skipToday() {
        perform {
            let token = try await self.engine.skipToday()
            self.post(token.toast)
        }
    }

    func toggleChecklistItem(paperID: String, itemID: String) {
        perform {
            let result = try await self.engine.toggleChecklistItem(paperID: paperID, itemID: itemID)
            if result.becameDone {
                self.post(Toast(id: "done-\(paperID)", kind: .success, message: L.markedDone(result.paper.title)))
            }
        }
    }

    /// Deleting the last open item of an otherwise ticked checklist marks the paper read, with the
    /// same toast as ticking it.
    func deleteChecklistItem(paperID: String, itemID: String) {
        perform {
            let result = try await self.engine.deleteChecklistItem(paperID: paperID, itemID: itemID)
            if result.markedDone {
                self.post(Toast(id: "done-\(paperID)", kind: .success, message: L.markedDone(result.paper.title)))
            }
        }
    }

    func openPDF(_ row: PaperRow) {
        let url = row.pdfURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            post(Toast(kind: .error, message: L.pdfMissing))
            return
        }
        // Settings ▸ General ▸ Open PDFs with ▸ PaperDeck Reader (Slice C, C4; Preview stays the default).
        if ReaderRouter.opensInReader(opener: settings.pdfOpener) {
            ReaderRouter(state: self).openReader(row, page: nil, quote: nil)
            return
        }
        if settings.pdfOpener == "preview",
           let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
        engine.recentOpens.push(paperID: row.id)        // Explain's paper locator prefers recent opens
        perform { _ = try await self.engine.markOpened(paperID: row.id) }
    }

    func revealInFinder(_ row: PaperRow) {
        NSWorkspace.shared.activateFileViewerSelecting([row.pdfURL])
    }
}

// MARK: - AI provider & master switch

extension AppState {
    /// 总开关「AI 解读」 (settings ▸ AI, setup assistant): ON runs the chosen provider
    /// (`agent.mode = agent.provider`), OFF writes `off`. The queue re-detects at once (no quota).
    func setAIReading(_ on: Bool) {
        let mode = on ? settings.agentProvider.rawValue : AgentMode.off.rawValue
        guard settings.agentMode != mode else { return }
        settings.agentMode = mode
        let engine = self.engine
        Task { await engine.agentProviderDidChange() }
    }

    /// Claude ⇄ ChatGPT. While AI reading is on this also rewrites `agent.mode`; a running
    /// job finishes on its provider, queued jobs run with the new one.
    func selectProvider(_ kind: AIProviderKind) {
        guard settings.agentProvider != kind else { return }
        settings.agentProvider = kind
        let engine = self.engine
        Task { await engine.agentProviderDidChange() }
    }
}

extension AgentQueueStatus {
    /// The provider the chrome names for this status: the one `mode` runs (claude / codex),
    /// otherwise the one `provider` describes (the user's choice while off / mock).
    var shownKind: AIProviderKind { mode.providerKind ?? providerKind }

    /// `provider`, or `.unknown` while it still describes the previous provider right after a
    /// Claude ⇄ ChatGPT switch (never show one provider's login state under the other's name).
    var shownProvider: Provider {
        mode.providerKind == nil || describesActiveProvider ? provider : .unknown
    }

    /// True once the status describes `kind` (settings ▸ AI shows 「正在检测…」 until then).
    func describes(_ kind: AIProviderKind) -> Bool {
        providerKind == kind && (mode.providerKind == nil || mode.providerKind == kind)
    }
}
