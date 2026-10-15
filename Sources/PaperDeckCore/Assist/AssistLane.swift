import Foundation

/// The interactive AI lane (READING_ASSIST_PLAN §2–§4): at most one generating assist turn
/// app-wide, independent of the card queue's slot (the queue only stops *claiming* new jobs while
/// a turn generates, through `isBusyNow`; a running card is never cancelled). A new submit cancels
/// the running turn, which ends with `.failed(.cancelled, partial:)` (its text so far, shown as
/// "stopped").
///
/// Every turn passes, in this order: the ticket must be for the request's surface; `AssistGate.checkTurn`
/// (`assist.mode` on and naming the backend, a fresh single-use ticket, no usage-limit pause, ≤ 6
/// turns / minute, the daily caps, the shared RunBudget); only then the backend registered for the
/// mode runs it. Every pre-spawn passes `AssistGate.checkSpawn`. A mode without a backend fails with
/// `.unsupported` before anything is consumed.
///
/// While a turn runs the lane watches it: the first-token watchdog says "still waiting", the turn
/// timeout stops it, the output cap stops a runaway answer — streamed, or arriving whole as one
/// `replace` / `done` (Codex sends no deltas) — and keeps its first `maxOutputChars` characters as
/// the partial text of `.failed(.invalidOutput("output_cap"), partial:)` (Phase 2 fix QA-11); every
/// fragment is sanitized and the final text is `AssistSanitizer.answer`. A usage limit from a subscription backend pauses that
/// provider for cards and assist alike (`onUsageLimit` → `AgentQueue.recordUsageLimit`). One log line
/// per turn, without content.
package actor AssistLane {
    private enum StopReason { case user, superseded, timeout, outputCap }

    private struct Running {
        var id: UUID
        var surface: AssistSurface
        var threadKey: String?
        var task: Task<Void, Never>?
        var stop: StopReason?
    }

    private let gate: AssistGate
    private let load: @Sendable () -> EngineSettings
    private let now: @Sendable () -> Date
    private let pause: @Sendable (AIProviderKind) -> Date?
    private var backends: [AssistMode: any AssistBackend]
    private var running: Running?
    private var turnIndex: [String: Int] = [:]
    private var onIdle: (@Sendable () -> Void)?
    private var onUsageLimit: (@Sendable (AIProviderKind, Date?) async -> Void)?
    private var statusSink: (@Sendable (AssistStatus) -> Void)?
    /// The last detection per mode (status snapshots never spawn a detection themselves).
    private var detected: [AssistMode: AgentQueueStatus.Provider] = [:]
    /// The mode of the last turn or pre-spawn: switching closes the other backends' processes.
    private var lastMode: AssistMode?
    private nonisolated let busyFlag = BusyFlag()

    package init(gate: AssistGate, load: @escaping @Sendable () -> EngineSettings,
                 now: @escaping @Sendable () -> Date = Date.init,
                 pause: @escaping @Sendable (AIProviderKind) -> Date? = { _ in nil },
                 backends: [any AssistBackend] = []) {
        self.gate = gate; self.load = load; self.now = now; self.pause = pause
        self.backends = Dictionary(backends.map { ($0.mode, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Registers (or replaces) the backend of its mode.
    package func register(_ backend: any AssistBackend) { backends[backend.mode] = backend }

    /// The modes that have a backend.
    package var registeredModes: Set<AssistMode> { Set(backends.keys) }

    /// Called whenever the lane becomes idle (the card queue waits while a turn generates and is
    /// woken here).
    package func setOnIdle(_ hook: (@Sendable () -> Void)?) { onIdle = hook }

    /// Called when a subscription turn hit its provider's usage limit (the engine records the
    /// shared pause, `agent.<provider>.pausedUntil`).
    package func setOnUsageLimit(_ hook: (@Sendable (AIProviderKind, Date?) async -> Void)?) { onUsageLimit = hook }

    /// Receives a status snapshot when a turn starts or ends, after a pause and on `publishSnapshot`
    /// (the engine forwards it as `EngineEvent.assistStatus`). Snapshots never run a detection.
    package func setStatusSink(_ sink: (@Sendable (AssistStatus) -> Void)?) { statusSink = sink }

    /// The engine's wiring in one call: usage limits pause the queue's provider, status goes out
    /// as `EngineEvent.assistStatus`.
    package func wire(agents: AgentQueue, events: EventHub<EngineEvent>) {
        onUsageLimit = { [agents] kind, resetsAt in await agents.recordUsageLimit(kind: kind, resetsAt: resetsAt) }
        statusSink = { [events] status in events.send(.assistStatus(status)) }
    }

    /// Runs one turn of `r` with the user's `ticket`. The stream ends after exactly one terminal
    /// event; dropping it cancels the turn.
    package func submit(_ r: AssistRequest, ticket: ConsentTicket) -> AsyncStream<AssistEvent> {
        let (stream, continuation) = AsyncStream<AssistEvent>.makeStream(bufferingPolicy: .unbounded)
        func refuse(_ failure: AssistFailure) -> AsyncStream<AssistEvent> {
            continuation.yield(.failed(failure, partial: nil))
            continuation.finish()
            return stream
        }
        let mode = load().assist.mode
        guard mode == .off || backends[mode] != nil else { return refuse(.unsupported(missingFlags: [])) }
        // A ticket answers one gesture on one surface (an Explain box can't pay for a Q&A turn).
        guard ticket.surface == r.surface else { return refuse(.refused(.consentMissing)) }
        let verdict = gate.checkTurn(backend: mode, ticket: ticket, now: now())
        guard verdict == .allowed, let backend = backends[mode] else {
            return refuse(.refused(verdict == .allowed ? .disabled : verdict))
        }
        if var old = running {
            old.stop = .superseded
            running = old
            old.task?.cancel()
        }
        switchMode(to: mode)
        let id = UUID()
        let key = r.session.threadKey
        let index = key.map { turnIndex[$0, default: 0] } ?? 0
        if let key { turnIndex[key] = index + 1 }
        running = Running(id: id, surface: r.surface, threadKey: key, task: nil, stop: nil)
        busyFlag.set(true)
        publishStatus()
        let limits = r.limits
        let provider = mode.providerKind
        let summary = Self.summary(r, mode: mode, turnIndex: index)
        let task = Task { [weak self] in
            // The turn timeout counts from the submit; the first-token watchdog only says "still waiting".
            let deadline = Task { [weak self] in
                try? await Task.sleep(for: limits.turnTimeout)
                guard !Task.isCancelled else { return }
                await self?.stop(id, .timeout)
            }
            let watchdog = Task {
                try? await Task.sleep(for: limits.firstTokenWatchdog)
                guard !Task.isCancelled else { return }
                continuation.yield(.phase(.stillWaiting))
            }
            var partial = ""
            var terminal: AssistEvent?
            for await raw in backend.turn(r, turnIndex: index) {
                var event = raw
                switch raw {
                case .delta(let s):
                    let clean = AssistSanitizer.fragment(s)
                    watchdog.cancel()
                    guard partial.count + clean.count <= limits.maxOutputChars else {
                        partial += clean.prefix(max(0, limits.maxOutputChars - partial.count))   // kept up to the cap
                        await self?.stop(id, .outputCap)
                        continue
                    }
                    partial += clean
                    event = .delta(clean)
                case .replace(let s):
                    let clean = AssistSanitizer.fragment(s)
                    watchdog.cancel()
                    guard clean.count <= limits.maxOutputChars else {
                        partial = String(clean.prefix(limits.maxOutputChars))
                        await self?.stop(id, .outputCap)
                        continue
                    }
                    partial = clean
                    event = .replace(clean)
                case .done(let text, let meta):
                    guard text.count <= limits.maxOutputChars else {
                        partial = String(AssistSanitizer.fragment(text).prefix(limits.maxOutputChars))
                        await self?.stop(id, .outputCap)
                        continue
                    }
                    event = .done(text: AssistSanitizer.answer(text, limit: limits.maxOutputChars), meta: meta)
                case .failed(let failure, let p):
                    // The shared pause is in place before anyone sees the failure (and retries).
                    if case .usageLimit(let resetsAt) = failure, let provider {
                        await self?.recordUsageLimit(provider, resetsAt)
                    }
                    event = .failed(failure, partial: p.map(AssistSanitizer.fragment).flatMap { $0.isEmpty ? nil : $0 })
                default:
                    break
                }
                continuation.yield(event)
                if event.isTerminal { terminal = event; break }
            }
            watchdog.cancel()
            deadline.cancel()
            if terminal == nil {
                let reason = await self?.stopReason(id)
                let failure: AssistFailure
                switch reason {
                case .timeout?: failure = .timeout
                case .outputCap?: failure = .invalidOutput("output_cap")
                default: failure = .cancelled
                }
                let kept = String(partial.prefix(limits.maxOutputChars))
                terminal = .failed(failure, partial: kept.isEmpty ? nil : kept)
                continuation.yield(terminal!)
            }
            continuation.finish()
            await self?.finished(id, terminal: terminal, summary: summary)
        }
        running?.task = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Stops the running turn if it belongs to `surface`.
    package func cancel(surface: AssistSurface) {
        guard let r = running, r.surface == surface else { return }
        stop(r.id, .user)
    }

    /// The hotkey was pressed: a backend may start a warm process (only if the gate allows it).
    package func prewarm(_ arming: ArmingToken) async {
        let mode = load().assist.mode
        guard let backend = backends[mode] else { return }
        if let p = mode.providerKind {
            guard gate.checkSpawn(p, arming: arming, now: now()) else { return }
        } else if arming.isExpired(at: now()) {
            return
        }
        switchMode(to: mode)
        await backend.prewarm()
    }

    /// A panel or thread closed: its session ends and its turn count restarts.
    package func closeSession(threadKey: String) async {
        turnIndex[threadKey] = nil
        if running?.threadKey == threadKey, let id = running?.id { stop(id, .user) }
        for backend in backends.values { await backend.closeSession(threadKey: threadKey) }
    }

    /// Quit, sleep, or the user turned assist off: the running turn stops and every warm or live
    /// process is closed.
    package func closeAllSessions() async {
        if let id = running?.id { stop(id, .user) }
        turnIndex.removeAll()
        for backend in backends.values {
            if let owner = backend as? any AssistSessionOwning { await owner.closeAllSessions() }
        }
    }

    /// Engine shutdown.
    package func shutdown() async { await closeAllSessions() }

    /// A turn is generating.
    package var isBusy: Bool { running != nil }

    /// `isBusy` for synchronous callers (the card queue's yield hook).
    package nonisolated var isBusyNow: Bool { busyFlag.value }

    /// Mode, detection, pause and today's count of the current mode's provider. Runs the backend's
    /// detection (zero quota).
    package func status() async -> AssistStatus {
        let mode = load().assist.mode
        if mode != .off, let backend = backends[mode] {
            detected[mode] = await backend.detect()
        }
        return snapshot()
    }

    /// Sends the status as it is now to the status sink, without a detection or anything spawned
    /// (zero quota): after launch (the restored daily counts), when `assist.mode` or the caps
    /// changed, and when the day changed — a turn starting or ending isn't the only time today's
    /// count can be stale.
    package func publishSnapshot() { publishStatus() }

    // MARK: - Internals

    /// The status without a detection (the last one, or `.unknown` before any).
    private func snapshot() -> AssistStatus {
        let settings = load().assist
        let mode = settings.mode
        var status = AssistStatus(mode: mode, softCap: settings.dailySoftCap, hardCap: settings.dailyHardCap,
                                  busy: running != nil)
        guard mode != .off else { return status }
        guard backends[mode] != nil else {
            status.provider = .notInstalled
            return status
        }
        status.provider = detected[mode] ?? .unknown
        if let p = mode.providerKind {
            let t = now()
            status.pausedUntil = pause(p).flatMap { $0 > t ? $0 : nil }
            status.todayCount = gate.todayCount(p, now: t)
        }
        return status
    }

    private func publishStatus() {
        guard let statusSink else { return }
        statusSink(snapshot())
    }

    /// Another mode than last time: the other backends' processes go (≤ 1 assist process).
    private func switchMode(to mode: AssistMode) {
        guard lastMode != mode else { return }
        let previous = lastMode
        lastMode = mode
        guard previous != nil else { return }
        let others = backends.filter { $0.key != mode }.values.compactMap { $0 as? any AssistSessionOwning }
        guard !others.isEmpty else { return }
        Task { for owner in others { await owner.closeAllSessions() } }
    }

    private func stop(_ id: UUID, _ reason: StopReason) {
        guard var r = running, r.id == id else { return }
        r.stop = r.stop ?? reason
        running = r
        r.task?.cancel()
    }

    private func stopReason(_ id: UUID) -> StopReason? {
        running?.id == id ? running?.stop : .superseded
    }

    private func recordUsageLimit(_ provider: AIProviderKind, _ resetsAt: Date?) async {
        Log.assist.notice("assist \(provider.rawValue, privacy: .public) hit its usage limit; pausing the provider")
        await onUsageLimit?(provider, resetsAt)
    }

    private func finished(_ id: UUID, terminal: AssistEvent?, summary: String) async {
        Self.log(summary, terminal: terminal)
        guard running?.id == id else {
            publishStatus()
            return
        }
        running = nil
        busyFlag.set(false)
        publishStatus()
        onIdle?()
    }

    /// The content-free part of the turn's log line (dive-cli §7).
    private static func summary(_ r: AssistRequest, mode: AssistMode, turnIndex: Int) -> String {
        var parts = ["assist", mode.rawValue, r.surface.rawValue, r.model, "turn=\(turnIndex)", "text=\(r.turnText.count)c"]
        if let image = r.image {
            parts.append("img=\(Int(image.pixelSize.width))x\(Int(image.pixelSize.height)) \(image.data.count / 1024)KB")
        }
        if !r.history.isEmpty { parts.append("history=\(r.history.count)") }
        return parts.joined(separator: " ")
    }

    private static func log(_ summary: String, terminal: AssistEvent?) {
        switch terminal {
        case .done(let text, let meta)?:
            let ttft = meta.ttftMs.map { "\($0)ms" } ?? "-"
            let tokens = "\(meta.inputTokens.map(String.init) ?? "?")/\(meta.outputTokens.map(String.init) ?? "?")"
            let cost = meta.costUSD.map { String(format: "$%.4f", $0) } ?? "-"
            Log.assist.info("\(summary, privacy: .public) warm=\(meta.warm ? 1 : 0) ttft=\(ttft, privacy: .public) total=\(meta.totalMs)ms out=\(text.count)c tok=\(tokens, privacy: .public) cost=\(cost, privacy: .public) outcome=success")
        case .failed(let failure, let partial)?:
            Log.assist.notice("\(summary, privacy: .public) out=\(partial?.count ?? 0)c outcome=\(Self.code(failure), privacy: .public)")
        default:
            Log.assist.notice("\(summary, privacy: .public) outcome=none")
        }
    }

    /// A failure's code for logs (no detail strings: they may quote stderr).
    package static func code(_ f: AssistFailure) -> String {
        switch f {
        case .refused(let v): return "refused:\(v)"
        case .usageLimit: return "usage_limit"
        case .notLoggedIn(let r): return "not_logged_in:\(r.code)"
        case .overloaded: return "overloaded"
        case .timeout: return "timeout"
        case .cancelled: return "cancelled"
        case .binaryMissing: return "binary_missing"
        case .unsupported(let flags): return "unsupported:\(flags.joined(separator: ","))"
        case .invalidOutput: return "invalid_output"
        case .generic: return "generic"
        }
    }

    private final class BusyFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var busy = false
        var value: Bool { lock.withLock { busy } }
        func set(_ b: Bool) { lock.withLock { busy = b } }
    }
}
