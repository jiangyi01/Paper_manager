import Foundation

/// Transient UI-facing events that are not library state (import progress rows,
/// toasts, agent-queue status). Library state changes go through ChangeHub.
package enum EngineEvent: Sendable, Equatable {
    case importRow(ImportRowUpdate)
    case toast(Toast)
    case agentStatus(AgentQueueStatus)
    case batchFinished(ImportBatchSummary)
    /// The assist lane's state changed (mode, detection, pause, today's count, busy) — Slice 0 contract.
    case assistStatus(AssistStatus)
    /// Duplicate reviews opened / changed (dedupe, Slice B) — Slice 0 contract.
    case dedupe(DedupeNotice)
    /// A batch operation on several papers committed (multi-select, Slice C) — Slice 0 contract.
    case batchApplied(BatchNotice)
}

/// What the duplicate check tells the UI (READING_ASSIST_PLAN §6.3, §7 "Duplicate review").
package enum DedupeNotice: Sendable, Equatable {
    /// A review was opened for `paperID` (nil: the new file is parked, not committed).
    case reviewOpened(reviewID: String, paperID: String?)
    /// A review was resolved, dismissed or expired.
    case reviewClosed(reviewID: String)
    /// The number of open reviews (sidebar ▸ Duplicates).
    case openCount(Int)
}

/// One committed batch operation (one transaction, one undo token).
package struct BatchNotice: Sendable, Equatable {
    /// The operation's code (`BatchOperation` raw name; the App words it).
    package var operation: String
    package var paperIDs: [String]
    /// `Engine.undo(token:)` reverts it (nil: not undoable).
    package var undoToken: String?

    package init(operation: String, paperIDs: [String], undoToken: String? = nil) {
        self.operation = operation; self.paperIDs = paperIDs; self.undoToken = undoToken
    }
}

/// One line in the floating panel's processing list.
package struct ImportRowUpdate: Sendable, Equatable, Identifiable {
    package enum Stage: Sendable, Equatable {
        case receiving
        case downloading(fraction: Double?)
        case waitingForCloud                    // OneDrive/iCloud placeholder materializing
        case verifying
        case parsing
        case metadata
        case filing
        case added(paperID: String, deadline: LocalDate?, provisional: Bool)
        case queuedForAI(paperID: String)
        case duplicate(paperID: String)                         // exact bytes already in the library
        case sameWork(existingPaperID: String, pendingID: String) // same DOI/arXiv — user decides replace/ignore
        case rejected(reason: String)                           // not a PDF, locked, …
        case failed(reason: String)

        package var isTerminal: Bool {
            switch self {
            case .added, .queuedForAI, .duplicate, .sameWork, .rejected, .failed: return true
            default: return false
            }
        }
    }

    package var id: String                       // row id (stable for one dropped file)
    package var batchID: String
    package var displayName: String
    package var stage: Stage

    package init(id: String, batchID: String, displayName: String, stage: Stage) {
        self.id = id; self.batchID = batchID; self.displayName = displayName; self.stage = stage
    }
}

package struct Toast: Sendable, Equatable, Identifiable {
    package enum Kind: String, Sendable { case success, info, warning, error }
    package enum Action: Sendable, Equatable {
        case openPaper(id: String)
        case setHighPriority(paperID: String)
        case replaceKeepingChecklist(pendingID: String)
        case ignorePending(pendingID: String)
        case restorePaper(id: String)
        case openInBrowser(URL)
        case undo(token: String)
        case openSettings(tab: String)
        /// Show the email card (Mail inbox, selected).
        case openMail(id: String)
        /// 「关联」: link a waiting email item to a paper (a title-only match the user confirms).
        case linkMailItem(itemID: String, paperID: String)
        /// 「撤销」 on 「已匹配邮件请求」: `Engine.undoMailLink(token:)` puts the automatically linked
        /// rows back to waiting for a PDF (and reopens the card when the link completed it).
        case undoMailLink(token: String)
        /// Opens the duplicate decision sheet of a review (dedupe, Slice B).
        case openDuplicateReview(id: String)
        /// A review toast's quick answer ([Keep New] / [Skip]): applied through the review
        /// (`Engine.resolveDuplicate`) like the decision sheet's [Apply], so the parked file is kept
        /// for Undo and the result toast offers Undo for 30 s.
        case resolveDuplicate(reviewID: String, choice: DupChoice)
    }
    package struct Button: Sendable, Equatable {
        package var title: String
        package var action: Action
        package init(title: String, action: Action) { self.title = title; self.action = action }
    }

    package var id: String
    package var kind: Kind
    package var message: String
    package var buttons: [Button]
    /// Actionable and error toasts stay until handled; plain successes expire.
    package var isSticky: Bool { kind == .error || !buttons.isEmpty }

    package init(id: String = UUID().uuidString, kind: Kind, message: String, buttons: [Button] = []) {
        self.id = id; self.kind = kind; self.message = message; self.buttons = buttons
    }
}

package struct ImportBatchSummary: Sendable, Equatable {
    package var batchID: String
    package var added: [String]                  // paper ids
    package var duplicates: Int
    package var rejected: Int
    package var failed: Int
    package var heldForAI: [String]              // paper ids whose AI jobs await confirmation
    package var lastDeadline: LocalDate?
    /// One result per item, in the order the items were expanded (folders: their PDFs).
    package var items: [ImportItemResult]
    package init(batchID: String, added: [String] = [], duplicates: Int = 0, rejected: Int = 0, failed: Int = 0,
                 heldForAI: [String] = [], lastDeadline: LocalDate? = nil, items: [ImportItemResult] = []) {
        self.batchID = batchID; self.added = added; self.duplicates = duplicates; self.rejected = rejected
        self.failed = failed; self.heldForAI = heldForAI; self.lastDeadline = lastDeadline; self.items = items
    }
}

/// Snapshot of the agent queue for the menu bar / provider pill.
package struct AgentQueueStatus: Sendable, Equatable {
    /// `.notLoggedIn(code)` / `.unsupported(code)` carry a `ProviderReason` code
    /// (`logged_out`, `non_subscription:<method>`, `missing_flags:<a,b>`, `timeout`, …);
    /// show `reasonText(_:provider:)` (or `AgentQueueStatus.providerText(_:)`), never the code.
    package enum Provider: Sendable, Equatable {
        case unknown, disabled, ready(plan: String?, version: String), notInstalled, notLoggedIn(String), unsupported(String)

        /// The parsed reason of `.notLoggedIn` / `.unsupported`; nil otherwise.
        package var reason: ProviderReason? {
            switch self {
            case .notLoggedIn(let code), .unsupported(let code): return ProviderReason(code: code)
            default: return nil
            }
        }

        /// One line of zh/en text worded for `provider`, e.g. 「PaperDeck 只使用订阅登录（当前：api_key）」
        /// or 「需登录 ChatGPT：运行 codex login → Sign in with ChatGPT」.
        package func reasonText(_ lang: UILang, provider: AIProviderKind = .claude) -> String {
            let zh = lang == .zh
            switch self {
            case .unknown: return zh ? "正在检查 \(provider.cliName)…" : "Checking \(provider.cliName)…"
            case .disabled:
                return zh ? "\(provider.shortName) 解读已关闭" : "\(provider.shortName) reading is off"
            case .ready(let plan, let version):
                return ProviderReason.readyText(plan: plan, version: version, lang, provider: provider)
            case .notInstalled: return ProviderReason.notInstalledText(lang, provider: provider)
            case .notLoggedIn(let code):
                return ProviderReason(code: code).text(lang, loginProblem: true, provider: provider)
            case .unsupported(let code):
                return ProviderReason(code: code).text(lang, loginProblem: false, provider: provider)
            }
        }
    }
    /// Detection result of the provider named by `providerKind`.
    package var provider: Provider
    /// Which real provider `provider` describes: the one `mode` runs (claude / codex), or — while
    /// the mode is off or mock — the one the user chose (`EngineSettings.agentProvider`), so the
    /// settings UI can show its login state before AI reading is enabled. Right after a switch it
    /// may still name the previous provider until the new one has been detected (`provider` is
    /// `.unknown` meanwhile).
    package var providerKind: AIProviderKind
    package var mode: AgentMode
    package var runningPaperID: String?
    package var runningSince: Date?
    package var queued: Int
    package var held: Int
    /// Usage-limit pause of `providerKind` (each provider has its own quota).
    package var pausedUntil: Date?
    package var pauseReason: String?
    /// Mail triage lane (not counted in `queued` / `runningPaperID`): jobs waiting for the slot,
    /// and the email being analyzed right now (its mail_message pk) with its start time.
    package var triageQueued: Int
    package var runningTriageMessagePK: Int64?
    package var triageRunningSince: Date?

    package init(provider: Provider = .unknown, providerKind: AIProviderKind = .claude, mode: AgentMode = .off,
                 runningPaperID: String? = nil, runningSince: Date? = nil, queued: Int = 0, held: Int = 0,
                 pausedUntil: Date? = nil, pauseReason: String? = nil, triageQueued: Int = 0,
                 runningTriageMessagePK: Int64? = nil, triageRunningSince: Date? = nil) {
        self.provider = provider; self.providerKind = providerKind; self.mode = mode
        self.runningPaperID = runningPaperID
        self.runningSince = runningSince; self.queued = queued; self.held = held
        self.pausedUntil = pausedUntil; self.pauseReason = pauseReason
        self.triageQueued = triageQueued; self.runningTriageMessagePK = runningTriageMessagePK
        self.triageRunningSince = triageRunningSince
    }

    /// An email is being analyzed by the AI right now (the slot is busy even with no paper running).
    package var triageRunning: Bool { runningTriageMessagePK != nil }

    /// 「正在分析邮件…」 while a triage runs, 「N 封邮件待 AI 分析」 while some wait; nil otherwise.
    package func triageText(_ lang: UILang) -> String? {
        let zh = lang == .zh
        if triageRunning { return zh ? "正在分析邮件…" : "Analyzing email…" }
        guard triageQueued > 0 else { return nil }
        if zh { return "\(triageQueued) 封邮件待 AI 分析" }
        return triageQueued == 1 ? "1 email waiting for AI analysis" : "\(triageQueued) emails waiting for AI analysis"
    }

    /// `provider.reasonText` worded for `providerKind`.
    package func providerText(_ lang: UILang) -> String { provider.reasonText(lang, provider: providerKind) }

    /// True once `provider` describes the provider `mode` runs (false while off / mock, and right
    /// after switching claude ⇄ codex until the new provider was detected).
    package var describesActiveProvider: Bool { mode.providerKind == providerKind }
}

/// Generic fan-out broadcaster (same semantics as ChangeHub).
package final class EventHub<Event: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    package init() {}

    package func subscribe() -> AsyncStream<Event> {
        let id = UUID()
        let (stream, cont) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(512))
        cont.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.continuations[id] = nil; self.lock.unlock()
        }
        lock.lock(); continuations[id] = cont; lock.unlock()
        return stream
    }

    package func send(_ event: Event) {
        lock.lock(); let conts = Array(continuations.values); lock.unlock()
        for c in conts { c.yield(event) }
    }
}
