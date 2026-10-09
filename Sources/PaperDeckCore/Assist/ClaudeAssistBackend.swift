import Foundation

/// Backends that keep processes between turns (the lane closes them on quit, sleep and provider changes).
package protocol AssistSessionOwning: Sendable {
    func closeAllSessions() async
}

/// The Claude assist backend (READING_ASSIST_PLAN §2 "Follow-ups"): at most one live
/// `claude -p --input-format stream-json` process app-wide, tied to one conversation (a panel or a
/// Q&A thread, `AssistSessionPolicy.reuse(threadKey:)`). A follow-up on that conversation is just
/// another stdin line (no cold start; the prefix is cache-read). Anything else — another
/// conversation, a one-shot turn, another model or system prompt, the 12-turn cap, a dead process —
/// closes it and starts a fresh one, which gets the earlier turns resent in `<history>` (the
/// stateless fallback). Never `--resume`.
///
/// The process is closed after `keepWarm` idle (`assist.keepWarm`, default 3 min), after a one-shot
/// turn, on `closeSession` / `closeAllSessions`. `prewarm` re-checks the login (zero quota); it
/// spawns an idle process ahead of the turn only when `idleSpawnOnPrewarm` is set and a spec is
/// known — the app's factory sets both since phase 3 (spike Q3: an idle process costs nothing).
///
/// Every turn and pre-spawn reaches this backend only through `AssistLane`, after `AssistGate`.
package actor ClaudeAssistBackend: AssistBackend, AssistSessionOwning {
    package static let maxTurnsPerSession = 12
    /// The longest an idle process may wait (the approved 3 minutes; Settings' switch writes 0 or this).
    package static let maxKeepWarmSeconds = 180

    /// `assist.keepWarm` as the backend uses it: 0…`maxKeepWarmSeconds` (a hand-edited or older
    /// larger value never keeps a process longer — F7).
    package static func keepWarm(seconds: Int) -> Duration { .seconds(min(max(seconds, 0), maxKeepWarmSeconds)) }

    package nonisolated let mode: AssistMode = .claude
    private let launcher: any AssistLauncher
    private let now: @Sendable () -> Date
    private let keepWarm: @Sendable () -> Duration
    private let sleep: @Sendable (Duration) async -> Void
    private let prewarmSpec: (@Sendable () -> ClaudeAssistSession.Spec?)?
    private let idleSpawnOnPrewarm: Bool
    private let tap: AssistWireTap?

    private struct Live {
        let id: Int
        let session: ClaudeAssistSession
        /// The conversation it belongs to; nil while a pre-spawned process waits for its first turn.
        var threadKey: String?
    }

    private var live: Live?
    private var nextID = 0
    private var idleTimer: Task<Void, Never>?
    private var idleGeneration = 0
    /// Processes started (tests and logs).
    package private(set) var spawns = 0

    /// - Parameters:
    ///   - launcher: the zero-quota checks (`ClaudeCodeProvider` in the app).
    ///   - keepWarm: how long an idle process may live (re-read after every turn).
    ///   - sleep: the idle timer's clock (tests inject a manual one).
    ///   - prewarmSpec: what a pre-spawned process would run (Explain's model and system prompt).
    ///   - tap: raw stdout lines for `--assist-smoke --record`; nil in the app.
    package init(launcher: any AssistLauncher, now: @escaping @Sendable () -> Date = Date.init,
                 keepWarm: @escaping @Sendable () -> Duration = { .seconds(180) },
                 sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                 prewarmSpec: (@Sendable () -> ClaudeAssistSession.Spec?)? = nil,
                 idleSpawnOnPrewarm: Bool = false, tap: AssistWireTap? = nil) {
        self.launcher = launcher; self.now = now; self.keepWarm = keepWarm; self.sleep = sleep
        self.prewarmSpec = prewarmSpec; self.idleSpawnOnPrewarm = idleSpawnOnPrewarm; self.tap = tap
    }

    package nonisolated func turn(_ request: AssistRequest, turnIndex: Int) -> AsyncStream<AssistEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                await self.run(request, turnIndex: turnIndex, into: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ r: AssistRequest, turnIndex: Int, into c: AsyncStream<AssistEvent>.Continuation) async {
        idleTimer?.cancel()
        let spec = ClaudeAssistSession.Spec(r)
        let key = r.session.threadKey
        var chosen: Live?
        var warm = false
        if let l = live, await reusable(l, spec: spec, key: key), live?.id == l.id {
            chosen = l
            live?.threadKey = key
            warm = true
        } else {
            await closeLive()
            c.yield(.phase(.starting))
            switch await launcher.assistLaunch() {
            case .failed(let failure):
                c.yield(.failed(failure, partial: nil))
                return
            case .ready(let launch):
                guard !Task.isCancelled else { return }
                do {
                    let session = try await ClaudeAssistSession.start(spec: spec, launch: launch, now: now, tap: tap)
                    nextID += 1
                    spawns += 1
                    let fresh = Live(id: nextID, session: session, threadKey: key)
                    // A turn that started meanwhile may have installed its own process: keep at most one.
                    if let other = live, other.id != fresh.id { live = nil; await other.session.close() }
                    live = fresh
                    chosen = fresh
                } catch is CancellationError {
                    return
                } catch {
                    Log.assist.error("claude assist process could not start: \(String(describing: error), privacy: .public)")
                    c.yield(.failed(.binaryMissing, partial: nil))
                    return
                }
            }
        }
        guard let used = chosen else { return }
        // A process that has had no turn yet knows nothing of the conversation: resend it.
        let firstTurn = await used.session.turnsDone == 0
        let text = firstTurn ? AssistFraming.statelessText(turnText: r.turnText, history: r.history) : r.turnText
        var terminal: AssistEvent?
        for await event in await used.session.send(ClaudeAssistSession.userLine(text: text, image: r.image),
                                                   turnIndex: turnIndex, warm: warm) {
            c.yield(event)
            if event.isTerminal { terminal = event; break }
        }
        if case .done? = terminal, key != nil, await used.session.canTakeTurn {
            scheduleIdleTimer()
        } else {
            // One-shot, failed, cancelled or dead: this process is done.
            await closeLive(ifID: used.id)
        }
    }

    private func reusable(_ l: Live, spec: ClaudeAssistSession.Spec, key: String?) async -> Bool {
        guard l.session.spec == spec, await l.session.canTakeTurn else { return false }
        let turns = await l.session.turnsDone
        guard turns < Self.maxTurnsPerSession else { return false }
        if l.threadKey == nil { return turns == 0 }             // a pre-spawned process: any first turn
        return key != nil && l.threadKey == key
    }

    /// The Explain shortcut armed: an idle live process gets its keep-warm time again; a busy one (a
    /// turn is running) is left alone — its own end schedules the timer (F6: the idle timer never
    /// runs during a turn). With no live process, the login is re-checked (zero quota) and — when
    /// allowed and a spec is known — one idle process is started. A turn that installed its own
    /// process meanwhile keeps it: the pre-started one is closed instead.
    package func prewarm() async {
        if let l = live, await l.session.isAlive {
            if await l.session.canTakeTurn, live?.id == l.id { scheduleIdleTimer() }
            return
        }
        // The login re-check runs now (zero quota), so the turn doesn't wait for it.
        let launched = await launcher.assistLaunch()
        guard idleSpawnOnPrewarm, case .ready(let launch) = launched, let spec = prewarmSpec?(), live == nil else { return }
        do {
            let session = try await ClaudeAssistSession.start(spec: spec, launch: launch, now: now, tap: tap)
            nextID += 1
            spawns += 1
            guard live == nil else {
                await session.close()                       // a turn started its own process meanwhile
                return
            }
            live = Live(id: nextID, session: session, threadKey: nil)
            scheduleIdleTimer()
        } catch {
            Log.assist.error("claude assist pre-spawn failed: \(String(describing: error), privacy: .public)")
        }
    }

    package func closeSession(threadKey: String) async {
        guard let l = live, l.threadKey == threadKey else { return }
        await closeLive(ifID: l.id)
    }

    package func closeAllSessions() async {
        idleTimer?.cancel()
        await closeLive()
    }

    package nonisolated func detect() async -> AgentQueueStatus.Provider { await launcher.assistDetect() }

    /// The live process' conversation (nil: none, or a pre-spawned one) — tests and status.
    package var liveThreadKey: String?? { live.map { $0.threadKey } }

    package var hasLiveProcess: Bool { live != nil }

    // MARK: - Internals

    private func scheduleIdleTimer() {
        idleTimer?.cancel()
        idleGeneration += 1
        let generation = idleGeneration
        let delay = keepWarm()
        let sleep = self.sleep
        idleTimer = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            await self?.idleExpired(generation)
        }
    }

    /// The keep-warm time passed: the live process closes — only while it is idle (a turn that runs
    /// now ends by itself and schedules a new timer).
    private func idleExpired(_ generation: Int) async {
        guard generation == idleGeneration, let l = live, await l.session.canTakeTurn,
              generation == idleGeneration, live?.id == l.id else { return }
        Log.assist.info("claude assist process idle for \(Int(self.keepWarm().components.seconds)) s; closing it")
        await closeLive(ifID: l.id)
    }

    private func closeLive(ifID id: Int? = nil) async {
        guard let l = live, id == nil || l.id == id else { return }
        live = nil
        await l.session.close()
    }
}
