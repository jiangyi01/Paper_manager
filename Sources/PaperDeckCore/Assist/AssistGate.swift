import Foundation

/// The last line of defence before an interactive AI turn (READING_ASSIST_PLAN §2, §4). Every assist
/// turn — Explain, Q&A, the duplicate judge — asks `checkTurn` right before its content is written
/// to a backend; every pre-spawn of a warm process asks `checkSpawn`. Safety-critical; Lead-owned.
///
/// A turn is allowed only when, re-read at that moment:
/// 1. `assist.mode` is on (not `off`) — independent of `agent.mode` (card reading);
/// 2. the mode runs the backend that asks (claude → only Claude, codex → only Codex, …);
/// 3. a fresh `ConsentTicket` from a user gesture comes with it — never reused, never expired;
/// 4. for a subscription CLI: the provider isn't paused by a usage limit (the same
///    `agent.<p>.pausedUntil` the card queue uses), the burst limit (6 turns / minute) and the daily
///    caps (soft: a `capOverride` ticket continues; hard: no override) aren't reached, and the
///    engine's `RunBudget` (shared with card reading) has a run left.
///
/// `.allowed` consumes the ticket, one run of the budget, one burst slot and one daily count. A
/// refusal consumes nothing. The connection-test allowance of `AgentSpawnGate` is neither used nor
/// changed here. Thread-safe.
package final class AssistGate: @unchecked Sendable {
    package enum Verdict: Sendable, Equatable {
        case allowed
        /// `assist.mode` is off.
        case disabled
        /// `assist.mode` runs another backend than the one that asked.
        case wrongProvider
        case consentMissing
        case consentReused
        case consentExpired
        /// A usage limit pauses the provider until then.
        case paused(until: Date)
        /// More than `burstLimit` turns in `burstWindow`.
        case burst
        /// Today's count reached the soft cap (`Int`); a fresh `capOverride` ticket continues.
        case dailySoftCap(Int)
        /// Today's count reached the hard cap (`Int`).
        case dailyHardCap(Int)
        /// The RunBudget (`--max-runs`) is spent.
        case budgetExhausted
        /// The paper's policy forbids AI (`AssistPrivacy.Verdict.blocked`); returned by callers
        /// that checked privacy, never by `checkTurn` itself.
        case policyBlocked
    }

    package static let burstLimit = 6
    package static let burstWindow: TimeInterval = 60

    package let budget: RunBudget
    package let counter: AssistDailyCounter
    private let load: @Sendable () -> EngineSettings
    private let pause: @Sendable (AIProviderKind) -> Date?
    private let lock = NSLock()
    /// Ids of tickets already used, with their issue time (pruned once they'd be expired anyway).
    private var consumed: [UUID: Date] = [:]
    private var recentTurns: [Date] = []

    /// - Parameters:
    ///   - budget: the engine's RunBudget (the same instance `AgentSpawnGate` counts).
    ///   - load: a fresh settings snapshot (re-read on every check).
    ///   - pause: the provider's usage-limit pause end, if any (`AgentQueue.pause(for:)`).
    ///   - counter: today's turns per provider.
    package init(budget: RunBudget, load: @escaping @Sendable () -> EngineSettings,
                 pause: @escaping @Sendable (AIProviderKind) -> Date?, counter: AssistDailyCounter) {
        self.budget = budget; self.load = load; self.pause = pause; self.counter = counter
    }

    /// A subscription CLI turn by `p`. Consumes on `.allowed`.
    package func checkTurn(_ p: AIProviderKind, ticket: ConsentTicket?, now: Date) -> Verdict {
        check(p.assistMode, ticket: ticket, now: now)
    }

    /// A turn by the backend of `backend` (local / mock included: they need consent too, but no quota).
    package func checkTurn(backend: AssistMode, ticket: ConsentTicket?, now: Date) -> Verdict {
        check(backend, ticket: ticket, now: now)
    }

    /// Whether `p` may start a warm process for an armed hotkey. Consumes nothing; a turn on that
    /// process still needs `checkTurn`.
    package func checkSpawn(_ p: AIProviderKind, arming: ArmingToken?, now: Date) -> Bool {
        guard let arming, !arming.isExpired(at: now) else { return false }
        let settings = load().assist
        guard settings.mode == p.assistMode else { return false }
        if let until = pause(p), until > now { return false }
        if budget.isExhausted { return false }
        return lock.withLock {
            pruneBurst(now)
            guard recentTurns.count < Self.burstLimit else { return false }
            return counter.count(at: now, provider: p.rawValue) < settings.dailyHardCap
        }
    }

    /// Today's count for `p` (the footer's "12 / 50 today").
    package func todayCount(_ p: AIProviderKind, now: Date) -> Int { counter.count(at: now, provider: p.rawValue) }

    private func check(_ backend: AssistMode, ticket: ConsentTicket?, now: Date) -> Verdict {
        let settings = load().assist
        let verdict: Verdict = lock.withLock {
            guard settings.mode != .off, backend != .off else { return .disabled }
            guard settings.mode == backend else { return .wrongProvider }
            guard let ticket else { return .consentMissing }
            pruneConsumed(now)
            guard consumed[ticket.id] == nil else { return .consentReused }
            guard !ticket.isExpired(at: now) else { return .consentExpired }
            if let p = backend.providerKind {
                if let until = pause(p), until > now { return .paused(until: until) }
                pruneBurst(now)
                guard recentTurns.count < Self.burstLimit else { return .burst }
                let today = counter.count(at: now, provider: p.rawValue)
                if today >= settings.dailyHardCap { return .dailyHardCap(settings.dailyHardCap) }
                if today >= settings.dailySoftCap, ticket.gesture != .capOverride {
                    return .dailySoftCap(settings.dailySoftCap)
                }
                guard budget.consume() else { return .budgetExhausted }
                recentTurns.append(now)
                counter.increment(at: now, provider: p.rawValue)
            }
            consumed[ticket.id] = ticket.issuedAt
            return .allowed
        }
        switch verdict {
        case .allowed:
            Log.assist.info("assist turn allowed (\(backend.rawValue, privacy: .public), \(ticket?.surface.rawValue ?? "-", privacy: .public))")
        default:
            Log.assist.notice("assist turn refused (\(backend.rawValue, privacy: .public)): \(String(describing: verdict), privacy: .public)")
        }
        return verdict
    }

    private func pruneConsumed(_ now: Date) {
        consumed = consumed.filter { now.timeIntervalSince($0.value) <= ConsentTicket.validity + 5 }
    }

    private func pruneBurst(_ now: Date) {
        recentTurns.removeAll { now.timeIntervalSince($0) >= Self.burstWindow || $0 > now.addingTimeInterval(1) }
    }
}
