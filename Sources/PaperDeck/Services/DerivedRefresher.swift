import AppKit
import Observation
import WidgetKit
import PaperDeckCore

/// Keeps time- and library-derived outputs current (§6.5 重排触发, §6.6): the rolling
/// daily reminders and the widget snapshot, behind one 2 s debounce.
///
/// Triggers: library changes (ChangeHub), launch, wake, midnight, clock / time-zone
/// changes, and the settings that change the plan or its wording (budget, reading days,
/// cutoff, reminder switch / time / empty rule, language — which also refreshes the inbox and its
/// account statuses). Wake and day change also run
/// the reminder catch-up and refresh the library snapshot; app activation wakes the
/// agent queue (login state, agent.mode written by the build script / CLI).
final class DerivedRefresher {
    /// Exposed so the app delegate can add its own system-event handlers.
    let events = SystemEvents()

    private let state: AppState
    private let reminders: ReminderService
    private var tasks: [Task<Void, Never>] = []
    private var debounce: Task<Void, Never>?
    private var catchUpTask: Task<Void, Never>?
    private var refreshing = false
    private var dirty = false
    private var started = false

    static let debounceDelay: Duration = .seconds(2)

    init(state: AppState, reminders: ReminderService) {
        self.state = state
        self.reminders = reminders
    }

    func start() {
        guard !started else { return }
        started = true
        reminders.flushQueuedResponses()
        // 开机自启: once per launch, re-register when the user wants it but the service
        // is no longer enabled (app moved / re-signed). Idempotent.
        LaunchAtLogin.reconcileAtLaunch(settings: state.settings)

        events.on(.wake) { [weak self] in self?.timeChanged(catchUpAfter: .seconds(60)) }
        events.on(.dayChanged) { [weak self] in self?.timeChanged(catchUpAfter: .seconds(1)) }
        events.on(.clockChanged) { [weak self] in self?.timeChanged(catchUpAfter: .seconds(5)) }
        events.on(.timeZoneChanged) { [weak self] in self?.timeChanged(catchUpAfter: nil) }
        events.on(.becameActive) { [weak self] in
            guard let self else { return }
            // agent.mode / agent.provider written by the build script or the CLI.
            let switched = self.state.settings.reloadExternal()
            let engine = self.state.engine
            Task { if switched { await engine.agentProviderDidChange() } else { await engine.agents.wake() } }
        }
        events.start()

        let changes = state.engine.changes.subscribe()
        tasks.append(Task { [weak self] in
            for await _ in changes { self?.schedule() }
        })
        let engineEvents = state.engine.events.subscribe()
        tasks.append(Task { [weak self] in
            for await event in engineEvents { self?.handle(event) }
        })
        observeSettings()

        schedule(after: .zero)                      // launch
        catchUp(after: .seconds(5))
    }

    func stop() {
        events.stop()
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        debounce?.cancel()
        catchUpTask?.cancel()
    }

    /// Debounced reschedule + widget snapshot. Safe to call from anywhere on the main actor.
    func schedule(after delay: Duration = DerivedRefresher.debounceDelay) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.runRefresh()
        }
    }

    // MARK: - Private

    private func timeChanged(catchUpAfter delay: Duration?) {
        state.scheduleRefresh()
        schedule()
        if let delay { catchUp(after: delay) }
    }

    private func catchUp(after delay: Duration) {
        catchUpTask?.cancel()
        catchUpTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.reminders.catchUp()
        }
    }

    /// Runs outside the debounce task so a new trigger never cancels a half-done pass;
    /// triggers during a pass fold into one more pass.
    private func runRefresh() {
        guard !refreshing else { dirty = true; return }
        refreshing = true
        Task { [weak self] in
            guard let self else { return }
            repeat {
                self.dirty = false
                await self.refresh()
            } while self.dirty
            self.refreshing = false
        }
    }

    private func refresh() async {
        await reminders.reschedule()
        do {
            if try await state.engine.writeWidgetSnapshot() {
                Self.reloadWidgets()
                Log.widget.info("snapshot written, timelines reloaded")
            }
        } catch {
            Log.widget.error("widget snapshot failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// No-op for a bare `swift build` binary (no bundle, no widget extension to talk to).
    static func reloadWidgets() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Settings that change the plan or the reminder / widget wording.
    private struct PlanSignature: Equatable {
        var budget: Int, weekdays: Set<Int>, cutoff: Int
        var reminderOn: Bool, hour: Int, minute: Int, whenEmpty: Bool
        var language: UILang
    }

    private var planSignature: PlanSignature {
        let s = state.settings
        return PlanSignature(budget: s.dailyBudgetMinutes, weekdays: s.readingWeekdays, cutoff: s.cutoffHour,
                             reminderOn: s.reminderEnabled, hour: s.reminderHour, minute: s.reminderMinute,
                             whenEmpty: s.remindWhenEmpty, language: s.language)
    }

    private func observeSettings() {
        let before = withObservationTracking { planSignature } onChange: { [weak self] in
            // Fires before the new value is stored; re-read on the main actor afterwards.
            Task { @MainActor [weak self] in self?.settingsChanged() }
        }
        lastSignature = before
    }

    private var lastSignature: PlanSignature?

    private func settingsChanged() {
        let old = lastSignature
        observeSettings()
        guard lastSignature != old else { return }
        state.scheduleRefresh()                     // today plan in the library read model
        schedule()
        // A language switch: the inbox snapshot rewords its stored machine texts and its account
        // statuses (`MailSyncActor.accountSyncInfo(lang:)`, worded at display time; no new sync).
        if let old, old.language != lastSignature?.language { state.scheduleMailRefresh(delay: .zero) }
    }

    // MARK: Agent notices (「Claude 已读完」/「额度已用尽」)

    private func handle(_ event: EngineEvent) {
        guard case .toast(let toast) = event else { return }
        if toast.id.hasPrefix(AgentQueue.usageLimitToastPrefix) {
            // One per limit event; the toast id keeps it from ringing twice.
            let reminders = self.reminders
            Task { await reminders.postNotice(id: toast.id, title: toast.message, body: "", url: nil) }
        } else if let paperID = AgentQueue.paperID(fromFinishedToastID: toast.id) {
            // Only when nothing else is waiting (a single drop, or the end of a batch) and the
            // user is not looking at PaperDeck — the in-app toast covers that case.
            guard state.settings.notifyOnAgentDone, !NSApp.isActive, state.agentStatus.queued == 0 else { return }
            let reminders = self.reminders
            let url = DeepLink.isValidID(paperID) ? DeepLink.paper(id: paperID).url : DeepLink.today.url
            Task { await reminders.postNotice(id: toast.id, title: toast.message, body: "", url: url) }
        }
    }
}
