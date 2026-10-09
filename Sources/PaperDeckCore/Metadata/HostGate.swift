import Foundation

/// Per-host traffic cop shared by every metadata lookup in the process.
///
/// Each host gets one request at a time (arXiv's ToU demands a single
/// connection; for the others it keeps us far below their limits) with a
/// minimum start-to-start spacing. A 429/5xx pushes the host's next slot out
/// by `Retry-After` (clamped to 60 s) or by exponential backoff, so parallel
/// EnrichActor tasks all respect the penalty, and the failed request is retried
/// only if the wait fits the caller's budget. Waiters are FIFO and cancellable.
package actor HostGate {
    package struct Policy: Sendable, Equatable {
        package var minInterval: TimeInterval
        package var maxAttempts: Int
        package var backoffBase: TimeInterval
        package var maxPenalty: TimeInterval

        package init(minInterval: TimeInterval, maxAttempts: Int = 3, backoffBase: TimeInterval = 2,
                     maxPenalty: TimeInterval = 60) {
            self.minInterval = minInterval; self.maxAttempts = max(1, maxAttempts)
            self.backoffBase = backoffBase; self.maxPenalty = maxPenalty
        }
    }

    /// Monotonic time source + sleeper; tests inject a virtual clock.
    package protocol Clock: Sendable {
        func now() -> TimeInterval
        func sleep(seconds: TimeInterval) async throws
        /// Returns once `now()` reaches `deadline` (default: `sleep(seconds: deadline - now())`).
        func sleep(until deadline: TimeInterval) async throws
    }

    package struct SystemClock: Clock {
        private static let origin = ContinuousClock.now
        package init() {}
        package func now() -> TimeInterval {
            let d = ContinuousClock.now - Self.origin
            return TimeInterval(d.components.seconds) + TimeInterval(d.components.attoseconds) / 1e18
        }
        package func sleep(seconds: TimeInterval) async throws {
            guard seconds > 0 else { return }
            try await Task.sleep(for: .seconds(seconds))
        }
        package func sleep(until deadline: TimeInterval) async throws {
            try await Task.sleep(until: Self.origin + .seconds(deadline), clock: .continuous)
        }
    }

    package enum GateError: Error, Equatable {
        /// The host is backed off for longer than the caller is willing to wait.
        case overBudget(wait: TimeInterval)
    }

    /// Spacing per documented limits (DESIGN §6.1): arXiv ≥ 3 s + margin, bioRxiv ≈ 1 req/s,
    /// Crossref 1 s anonymous / 0.25 s in the polite (mailto) pool, OpenAlex 0.2 s.
    package static func policy(forHost host: String, politeCrossref: Bool = false) -> Policy {
        switch host.lowercased() {
        case "export.arxiv.org", "arxiv.org": Policy(minInterval: 3.1)
        case "api.biorxiv.org": Policy(minInterval: 1.0)
        case "api.crossref.org": Policy(minInterval: politeCrossref ? 0.25 : 1.0)
        case "api.openalex.org": Policy(minInterval: 0.2)
        default: Policy(minInterval: 1.0)
        }
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct HostState {
        var busy = false
        var waiters: [Waiter] = []
        var nextAllowed: TimeInterval = -.infinity
        var consecutiveFailures = 0
    }

    private let clock: any Clock
    private let wallNow: @Sendable () -> Date
    private var hosts: [String: HostState] = [:]

    package init(clock: any Clock = SystemClock(), wallNow: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
        self.wallNow = wallNow
    }

    /// Runs `operation` when `host` is free and its spacing/penalty has elapsed.
    /// Retries 429/5xx up to `policy.maxAttempts` while the wait fits `budget`
    /// (seconds from now); otherwise returns the last throttled result as-is.
    package func perform(host: String, policy: Policy? = nil, budget: TimeInterval? = nil,
                         _ operation: @Sendable () async throws -> HTTPResult) async throws -> HTTPResult {
        let key = host.lowercased()
        let policy = policy ?? Self.policy(forHost: key)
        let started = clock.now()
        var attempt = 0
        while true {
            attempt += 1
            try await acquire(key)
            do {
                let wait = hosts[key, default: HostState()].nextAllowed - clock.now()
                if wait > 0 {
                    if let budget, clock.now() - started + wait > budget { throw GateError.overBudget(wait: wait) }
                    try await clock.sleep(seconds: wait)
                }
                try Task.checkCancellation()
            } catch {
                release(key)
                throw error
            }

            let start = clock.now()
            hosts[key, default: HostState()].nextAllowed = start + policy.minInterval
            let result: HTTPResult
            do {
                result = try await operation()
            } catch {
                release(key)
                throw error
            }

            let throttled = result.status == 429 || (500...599).contains(result.status)
            if throttled {
                var state = hosts[key, default: HostState()]
                state.consecutiveFailures += 1
                let penalty: TimeInterval
                if let header = result.header("Retry-After"),
                   let seconds = Self.parseRetryAfter(header, now: wallNow()) {
                    penalty = min(seconds, policy.maxPenalty)
                } else {
                    let exponent = Double(min(state.consecutiveFailures - 1, 16))
                    penalty = min(policy.backoffBase * pow(2, exponent), policy.maxPenalty)
                }
                state.nextAllowed = max(state.nextAllowed, clock.now() + penalty)
                hosts[key] = state
                Log.metadata.info("\(key, privacy: .public) returned \(result.status); backing off \(penalty, privacy: .public)s")
            } else {
                hosts[key, default: HostState()].consecutiveFailures = 0
            }
            release(key)

            guard throttled, attempt < policy.maxAttempts else { return result }
            let wait = hosts[key, default: HostState()].nextAllowed - clock.now()
            if let budget, clock.now() - started + max(0, wait) > budget { return result }
        }
    }

    /// Earliest monotonic time the next request to `host` may start (tests/diagnostics).
    package func nextAllowed(host: String) -> TimeInterval {
        hosts[host.lowercased(), default: HostState()].nextAllowed
    }

    /// `Retry-After` is either delta-seconds or an HTTP-date (RFC 9110 §10.2.3).
    package static func parseRetryAfter(_ value: String, now: Date) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let seconds = Double(trimmed), seconds.isFinite { return max(0, seconds) }
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = format
            if let date = f.date(from: trimmed) { return max(0, date.timeIntervalSince(now)) }
        }
        return nil
    }

    // MARK: - Slot hand-off

    private func acquire(_ host: String) async throws {
        if !hosts[host, default: HostState()].busy {
            hosts[host, default: HostState()].busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                hosts[host, default: HostState()].waiters.append(Waiter(id: id, continuation: cont))
            }
        } onCancel: {
            Task { await self.cancelWaiter(host: host, id: id) }
        }
    }

    /// Hands the slot straight to the next waiter (busy stays true) so no newcomer can jump the queue.
    private func release(_ host: String) {
        var state = hosts[host, default: HostState()]
        if state.waiters.isEmpty {
            state.busy = false
            hosts[host] = state
        } else {
            let next = state.waiters.removeFirst()
            hosts[host] = state
            next.continuation.resume()
        }
    }

    private func cancelWaiter(host: String, id: UUID) {
        guard let index = hosts[host]?.waiters.firstIndex(where: { $0.id == id }),
              let waiter = hosts[host]?.waiters.remove(at: index) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }
}

extension HostGate.Clock {
    package func sleep(until deadline: TimeInterval) async throws {
        try await sleep(seconds: deadline - now())
    }
}
