import AppKit
import Foundation
import Observation
import PaperDeckCore

/// Duplicate reviews in the UI: the decision sheet, the sidebar count, the ribbon and the chip
/// (READING_ASSIST_PLAN §4, §6.3, §7). `AppState.dedupe`. Owned by Slice B.
///
/// It sees every engine event before AppState (`handle`): it keeps the open reviews for the
/// sidebar row / ribbon / chip, and words the import's classic toasts from their review
/// ([Review…] plus the one quick answer that never throws the library's version away). With
/// the duplicate check off (`dedupe.enabled = false`) it consumes nothing, so today's
/// two-button same-work toast reaches the user unchanged. Nothing here applies a choice by
/// itself: every change goes through the decision sheet's [Apply], undoable for 30 s.
@Observable
final class DedupeUIModel {
    /// The UI ships (menu item, sidebar row, ribbon, chip, settings section).
    static let isAvailable = true

    /// The AI judge's UI (B3): Settings ▸ Library ▸ Duplicates ▸ "Ask AI", [Ask AI] in the sheets.
    static let judgeIsAvailable = true

    /// The judge is offered once Explain & Ask can be turned on (its Settings tab ships): without
    /// `assist.mode` no AI turn can run, so a button would only explain why not.
    static var judgeShips: Bool { isAvailable && judgeIsAvailable && AssistRollout.assistSettings }

    /// Settings ▸ Library ▸ Duplicates ▸ "Ask AI" (kept with the library; off by default).
    private(set) var judgeEnabled = false

    /// The model the card ribbon reads (`DuplicateRibbon(row:)` has no state): the last attached.
    private(set) static weak var current: DedupeUIModel?

    /// Open reviews, newest first (sidebar ▸ Duplicates, ribbon, chip).
    private(set) var open: [DupReviewSummary] = []
    /// Open reviews (sidebar ▸ Duplicates).
    var openCount: Int { open.count }
    /// Library ▸ Check for Duplicates…: running (`done` of `total`) or finished.
    private(set) var check: CheckState?

    struct CheckState: Equatable {
        var done = 0
        var total = 0
        var running = true
        /// Reviews opened by this check (when finished).
        var found: Int?
        var stopped = false
    }

    @ObservationIgnored private weak var state: AppState?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var prepared = false
    /// Review sheets already on screen (one per review id).
    @ObservationIgnored private var presenting: Set<String> = []

    init() {}

    /// Called once by `AppState.init`.
    func attach(_ state: AppState) {
        self.state = state
        Self.current = self
    }

    /// The check runs on new imports: available in this build and enabled in Settings ▸ Library.
    /// Questions already open stay answerable (sidebar, ribbon, chip) with the switch off.
    var isOn: Bool { Self.isAvailable && (state?.settings.dedupe.enabled ?? false) }

    // MARK: Events

    /// Sees every engine event before AppState's own handling; returns true when it took the event
    /// over (a review notice, or a classic same-work / lookalike toast it rewords).
    func handle(_ e: EngineEvent) -> Bool {
        guard Self.isAvailable, let state else { return false }
        switch e {
        case .dedupe:
            scheduleRefresh()
            return true
        case .toast(let t):
            guard state.settings.dedupe.enabled,
                  DupExplainer.classicSameWorkPendingID(t) != nil || DupExplainer.classicLookalikePaperID(t) != nil
            else { return false }
            let engine = state.engine
            Task { [weak self] in
                let replaced = await engine.duplicateToast(replacing: t)
                // A parked file that was answered meanwhile (its review resolved by an email's
                // "use this version", a sheet, a toast): no stale Replace / Ignore for it.
                if replaced == nil, let pending = DupExplainer.classicSameWorkPendingID(t),
                   await !engine.intake.isPending(pending) {
                    return
                }
                self?.state?.post(replaced ?? t)
            }
            return true
        default:
            return false
        }
    }

    /// Once per launch (the library window's sidebar appears): identity keys for older papers,
    /// parked files a relaunch lost (their reviews expire, with a toast), then the open reviews.
    func prepare() {
        guard Self.isAvailable, !prepared, let state else { return }
        prepared = true
        let engine = state.engine
        Task { [weak self] in
            let result = await engine.prepareDuplicateReviews()
            self?.judgeEnabled = await engine.duplicateJudgeEnabled()
            if result.expired > 0 {
                self?.state?.post(Toast(id: "dup-expired", kind: .info, message: L.Dedupe.expired(result.expired)))
            }
            self?.scheduleRefresh(delay: .zero)
        }
    }

    /// Re-reads the open reviews (coalesced).
    func scheduleRefresh(delay: Duration = .milliseconds(150)) {
        guard let state else { return }
        let engine = state.engine
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            guard let list = try? await engine.duplicateReviewSummaries(), !Task.isCancelled else { return }
            if self?.open != list { self?.open = list }
        }
    }

    // MARK: Lookups (ribbon, chip)

    /// The open review whose new paper is `paperID`.
    func review(newPaper paperID: String) -> DupReviewSummary? {
        open.first { $0.review.newPaperID == paperID }
    }

    /// Open reviews that compare a new file with `paperID`.
    func reviews(existingPaper paperID: String) -> [DupReviewSummary] {
        open.filter { $0.review.existingPaperID == paperID }
    }

    /// The card shows the "Duplicate?" ribbon: the new side of an open certain / likely review (its
    /// help says what the review holds back, `DupReview.hold`).
    func showsRibbon(_ paperID: String) -> Bool {
        guard Self.isAvailable, let r = review(newPaper: paperID) else { return false }
        // A held paper keeps its ribbon even when the AI judge moved its review to "possible".
        return r.review.holdsNewPaper || r.review.hold != .none
    }

    // MARK: Opening

    /// A toast's [Review] (`Toast.Action.openDuplicateReview`), the ribbon, the chip: the decision
    /// sheet for `id`; when the same import left more open reviews, the batch review of that
    /// import (one row each, `id` among them).
    func openReview(id: String) {
        guard Self.isAvailable else { return }
        if let batch = open.first(where: { $0.id == id })?.review.batchID {
            let rows = open.filter { $0.review.batchID == batch }.reversed().map(\.id)
            if rows.count >= Self.batchThreshold {
                presentBatch(rows, title: .importBatch)
                return
            }
        }
        present([id])
    }

    /// Two or more open questions get the batch review.
    static let batchThreshold = 2

    /// The decision sheet of one review (the batch review's [Details…]).
    func openSingle(id: String) {
        guard Self.isAvailable else { return }
        present([id])
    }

    /// The ribbon / chip of a paper (as the new side, else as the earlier one).
    func openReview(forPaper paperID: String) {
        if let r = review(newPaper: paperID) ?? reviews(existingPaper: paperID).first { openReview(id: r.id) }
    }

    /// Sidebar ▸ Duplicates ▸ Review All: every open review, oldest first — in the batch review
    /// when there are several.
    func reviewAll() {
        let ids = open.reversed().map(\.id)
        if ids.count >= Self.batchThreshold { presentBatch(ids, title: .all) } else { present(ids) }
    }

    /// The reviews a finished library check opened (the Duplicates list's [Review N…]).
    func reviewCheckResults() {
        guard let state else { return }
        let engine = state.engine
        Task { [weak self] in
            let ids = await engine.duplicateBatchReviewIDs(batchID: nil)
            guard let self, !ids.isEmpty else { return }
            if ids.count >= Self.batchThreshold { self.presentBatch(ids, title: .check) } else { self.present(ids) }
        }
    }

    /// Sidebar ▸ Duplicates: the list of open reviews (and a library check).
    func showList() {
        guard Self.isAvailable, let state else { return }
        scheduleRefresh(delay: .zero)
        CardSheetPresenter.present { close in
            DuplicatesList(state: state, close: close)
        }
    }

    private func presentBatch(_ ids: [String], title: DuplicateBatchModel.Origin) {
        guard let state, let first = ids.first, !presenting.contains("batch:" + first) else { return }
        presenting.insert("batch:" + first)
        let model = DuplicateBatchModel(state: state, ids: ids, origin: title)
        CardSheetPresenter.present { close in
            DuplicateBatchSheet(model: model) { [weak self] next in
                self?.presenting.remove("batch:" + first)
                close()
                // [Details…]: the row's own decision sheet, once this one is gone.
                if let next { Task { @MainActor in self?.openSingle(id: next) } }
            }
        }
    }

    private func present(_ queue: [String]) {
        guard let state, let first = queue.first, !presenting.contains(first) else { return }
        presenting.insert(first)
        let model = DuplicateSheetModel(state: state, queue: queue)
        CardSheetPresenter.present { close in
            DuplicateSheet(model: model) { [weak self] in
                self?.presenting.remove(first)
                close()
            }
        }
    }

    // MARK: Library check

    /// Library ▸ Check for Duplicates… and the selection bar's "Check duplicates" (`ids`: the
    /// selection, empty for the whole library): the Duplicates list opens and shows the progress.
    func checkSelected(ids: [String]) {
        guard Self.isAvailable, state != nil else { return }
        startCheck(ids: ids)
        showList()
    }

    /// Starts (or restarts) a check; the Duplicates list shows it.
    func startCheck(ids: [String] = []) {
        guard let state, check?.running != true else { return }
        let engine = state.engine
        check = CheckState()
        let progress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            guard let model = self else { return }
            Task { @MainActor in model.checkProgressed(done, total) }
        }
        checkTask = Task { [weak self] in
            do {
                let summary = try await engine.checkDuplicates(paperIDs: ids, progress: progress)
                self?.check = CheckState(done: summary.checked, total: summary.checked, running: false,
                                         found: summary.opened.count)
            } catch {
                let stopped = error is CancellationError
                self?.check?.running = false
                self?.check?.stopped = stopped
                if !stopped { self?.state?.report(error) }
            }
            self?.scheduleRefresh(delay: .zero)
        }
    }

    private func checkProgressed(_ done: Int, _ total: Int) {
        guard check?.running == true else { return }
        check?.done = done
        check?.total = total
    }

    func stopCheck() { checkTask?.cancel() }

    /// The finished check's line goes away when the list closes.
    func clearFinishedCheck() {
        if check?.running == false { check = nil }
    }

    // MARK: AI judge

    /// Reads the switch (Settings opened before the library window).
    func loadJudgeSwitch() async {
        guard let state else { return }
        judgeEnabled = await state.engine.duplicateJudgeEnabled()
    }

    /// Settings ▸ Library ▸ Duplicates ▸ "Ask AI".
    func setJudgeEnabled(_ on: Bool) {
        guard let state else { return }
        judgeEnabled = on
        let engine = state.engine
        state.perform { try await engine.setDuplicateJudgeEnabled(on) }
    }

    /// The judge turn of a click (`ticket` minted by the button), then the open reviews refresh.
    func askJudge(_ reviewID: String, ticket: ConsentTicket) async throws -> DupReview {
        guard let state else { throw DupJudgeError.blocked(.reviewClosed) }
        let review = try await state.engine.askDuplicateJudge(reviewID: reviewID, ticket: ticket)
        scheduleRefresh(delay: .zero)
        return review
    }

    // MARK: Applying (the batch review)

    /// [Apply] of the batch review: every row, one toast with one Undo for all of them.
    func resolveBatch(_ items: [(reviewID: String, choice: DupChoice)]) async -> DupBatchResolution {
        guard let state else { return DupBatchResolution() }
        let result = await state.engine.resolveDuplicates(items)
        var buttons: [Toast.Button] = []
        if let token = result.undoToken { buttons.append(.init(title: L.Dedupe.undo, action: .undo(token: token))) }
        let id = "dup-batch-result-" + (items.first?.reviewID ?? "none")
        state.post(Toast(id: id, kind: result.failed.isEmpty ? .success : .warning, message: result.message, buttons: buttons))
        var batches = Set<String>()
        for r in result.resolved {
            state.dismissToast("dup-" + r.reviewID)
            if let batch = open.first(where: { $0.id == r.reviewID })?.review.batchID { batches.insert(batch) }
        }
        let done = Set(result.resolved.map(\.reviewID))
        open.removeAll { done.contains($0.id) }
        for batch in batches where !open.contains(where: { $0.review.batchID == batch }) {
            state.dismissToast("dup-batch-" + batch)
        }
        scheduleRefresh(delay: .zero)
        return result
    }

    // MARK: Email merge popover

    /// The popover's answer for an email row that looks like a library paper (`MailDupChoice`):
    /// the row is busy meanwhile, then a toast (with Undo when the library changed).
    func resolveMail(_ item: MailItem, paperID: String, choice: MailDupChoice, options: MailMergeOptions) {
        guard let state else { return }
        let engine = state.engine
        let key = item.id
        state.mailBusy.insert(key)
        Task { [weak self] in
            do {
                let outcome = try await engine.resolveMailDuplicate(itemID: key, paperID: paperID, choice: choice,
                                                                   options: options)
                var buttons: [Toast.Button] = []
                if let token = outcome.undoToken {
                    buttons.append(.init(title: L.Dedupe.undo, action: .undo(token: token)))
                } else if let id = outcome.paperID {
                    buttons.append(.init(title: L.Dedupe.open, action: .openPaper(id: id)))
                }
                state.post(Toast(id: "dup-mail-" + key, kind: outcome.paperID == nil ? .warning : .success,
                                 message: outcome.message, buttons: buttons))
                if let review = outcome.reviewID { state.dismissToast("dup-" + review) }
            } catch let e as DupResolutionError {
                state.post(Toast(id: "dup-mail-" + key, kind: .error, message: e.message(L.lang)))
            } catch {
                state.report(error)
            }
            state.mailBusy.remove(key)
            state.scheduleMailRefresh(delay: .zero)
            self?.scheduleRefresh(delay: .zero)
        }
    }

    // MARK: Applying (the decision sheet)

    /// Applies a choice; the toast offers Undo for 30 s (or Open when nothing can be undone).
    func resolve(_ reviewID: String, _ choice: DupChoice) async throws -> DupResolution {
        guard let state else { throw DupResolutionError.reviewNotFound(reviewID) }
        let result = try await state.engine.resolveDuplicate(reviewID: reviewID, choice)
        var buttons: [Toast.Button] = []
        if let token = result.undoToken {
            buttons.append(.init(title: L.Dedupe.undo, action: .undo(token: token)))
        } else if let kept = result.keptPaperID {
            buttons.append(.init(title: L.Dedupe.open, action: .openPaper(id: kept)))
        }
        state.post(Toast(id: "dup-result-" + reviewID, kind: .success, message: result.message, buttons: buttons))
        state.dismissToast("dup-" + reviewID)
        // The import's one review toast goes once its last review is answered.
        if let batch = open.first(where: { $0.id == reviewID })?.review.batchID,
           !open.contains(where: { $0.id != reviewID && $0.review.batchID == batch }) {
            state.dismissToast("dup-batch-" + batch)
        }
        open.removeAll { $0.id == reviewID }
        scheduleRefresh(delay: .zero)
        return result
    }
}
