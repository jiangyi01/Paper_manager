import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct HostGateTests {
    /// Virtual monotonic clock: `sleep` advances time instantly and records the request.
    final class VirtualClock: HostGate.Clock, @unchecked Sendable {
        private let lock = NSLock()
        private var t: TimeInterval = 1000
        private var slept: [TimeInterval] = []

        func now() -> TimeInterval { lock.withLock { t } }
        func sleep(seconds: TimeInterval) async throws {
            try Task.checkCancellation()
            lock.withLock { t += seconds; slept.append(seconds) }
        }
        func advance(_ s: TimeInterval) { lock.withLock { t += s } }
        var sleeps: [TimeInterval] { lock.withLock { slept } }
    }

    /// Records when each operation started (virtual time) and the peak concurrency.
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var starts: [TimeInterval] = []
        private var inFlight = 0
        private var peak = 0
        func begin(_ at: TimeInterval) { lock.withLock { starts.append(at); inFlight += 1; peak = max(peak, inFlight) } }
        func end() { lock.withLock { inFlight -= 1 } }
        var startTimes: [TimeInterval] { lock.withLock { starts } }
        var maxConcurrent: Int { lock.withLock { peak } }
    }

    private static func gaps(_ xs: [TimeInterval]) -> [TimeInterval] {
        zip(xs.dropFirst(), xs).map { $0 - $1 }
    }

    @Test func defaultPolicies() {
        #expect(HostGate.policy(forHost: "export.arxiv.org").minInterval >= 3.1)
        #expect(HostGate.policy(forHost: "api.biorxiv.org").minInterval == 1.0)
        #expect(HostGate.policy(forHost: "api.crossref.org").minInterval == 1.0)
        #expect(HostGate.policy(forHost: "api.crossref.org", politeCrossref: true).minInterval == 0.25)
        #expect(HostGate.policy(forHost: "API.OpenAlex.org").minInterval == 0.2)
        #expect(HostGate.policy(forHost: "example.com").minInterval == 1.0)
    }

    @Test func sequentialRequestsAreSpaced() async throws {
        let clock = VirtualClock()
        let gate = HostGate(clock: clock)
        let probe = Probe()
        for _ in 0..<3 {
            let r = try await gate.perform(host: "export.arxiv.org") {
                probe.begin(clock.now()); defer { probe.end() }
                return HTTPResult(status: 200)
            }
            #expect(r.status == 200)
        }
        let gaps = Self.gaps(probe.startTimes)
        #expect(gaps.count == 2)
        #expect(gaps.allSatisfy { $0 >= 3.1 - 1e-9 })
    }

    @Test func noWaitWhenSpacingAlreadyElapsed() async throws {
        let clock = VirtualClock()
        let gate = HostGate(clock: clock)
        _ = try await gate.perform(host: "api.openalex.org") { HTTPResult(status: 200) }
        clock.advance(5)
        _ = try await gate.perform(host: "api.openalex.org") { HTTPResult(status: 200) }
        #expect(clock.sleeps.isEmpty)
    }

    @Test func hostsAreIndependent() async throws {
        let clock = VirtualClock()
        let gate = HostGate(clock: clock)
        _ = try await gate.perform(host: "export.arxiv.org") { HTTPResult(status: 200) }
        _ = try await gate.perform(host: "api.crossref.org") { HTTPResult(status: 200) }
        #expect(clock.sleeps.isEmpty)
    }

    @Test func concurrentCallersAreSerializedAndSpaced() async throws {
        let clock = VirtualClock()
        let gate = HostGate(clock: clock)
        let probe = Probe()
        let policy = HostGate.Policy(minInterval: 1.0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    _ = try await gate.perform(host: "api.biorxiv.org", policy: policy) {
                        probe.begin(clock.now())
                        try await Task.sleep(for: .milliseconds(5))   // real suspension while holding the slot
                        probe.end()
                        return HTTPResult(status: 200)
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(probe.maxConcurrent == 1)
        #expect(probe.startTimes.count == 5)
        #expect(Self.gaps(probe.startTimes.sorted()).allSatisfy { $0 >= 1.0 - 1e-9 })
    }

    @Test func retryAfterIsHonouredThenRetried() async throws {
        let clock = VirtualClock()
        let gate = HostGate(clock: clock)
        let probe = Probe()
        let result = try await gate.perform(host: "api.crossref.org", policy: HostGate.Policy(minInterval: 1)) {
            probe.begin(clock.now()); defer { probe.end() }
            return probe.startTimes.count == 1
                ? HTTPResult(status: 429, headers: ["retry-after": "5"])
                : HTTPResult(status: 200, body: Data("ok".utf8))
        }
        #expect(result.status == 200)
        #expect(probe.startTimes.count == 2)
        #expect(Self.gaps(probe.startTimes).first.map { $0 >= 5 - 1e-9 } == true)
    }

    @Test func retryAfterIsClampedTo60s() async throws {
        let clock = VirtualClock()
        let gate = HostGate(clock: clock)
        let r = try await gate.perform(host: "export.arxiv.org", policy: HostGate.Policy(minInterval: 3.1, maxAttempts: 1)) {
            HTTPResult(status: 503, headers: ["Retry-After": "3600"])
        }
        #expect(r.status == 503)
        let wait = await gate.nextAllowed(host: "export.arxiv.org") - clock.now()
        #expect(abs(wait - 60) < 1e-6)
    }

    @Test func exponentialBackoffWithoutRetryAfter() async throws {
        let clock = VirtualClock()
        let gate = HostGate(clock: clock)
        let probe = Probe()
        let r = try await gate.perform(host: "api.biorxiv.org", policy: HostGate.Policy(minInterval: 0.5, maxAttempts: 3)) {
            probe.begin(clock.now()); defer { probe.end() }
            return HTTPResult(status: 502)
        }
        #expect(r.status == 502)          // gave up after maxAttempts and returned the last answer
        #expect(probe.startTimes.count == 3)
        let gaps = Self.gaps(probe.startTimes)
        #expect(abs(gaps[0] - 2) < 1e-6)
        #expect(abs(gaps[1] - 4) < 1e-6)
        // Success resets the failure streak.
        _ = try await gate.perform(host: "api.biorxiv.org", policy: HostGate.Policy(minInterval: 0.5)) { HTTPResult(status: 200) }
        let wait = await gate.nextAllowed(host: "api.biorxiv.org") - clock.now()
        #expect(wait <= 0.5 + 1e-6)
    }

    @Test func noRetryBeyondBudget() async throws {
        let clock = VirtualClock()
        let gate = HostGate(clock: clock)
        let probe = Probe()
        let r = try await gate.perform(host: "api.crossref.org", policy: HostGate.Policy(minInterval: 1), budget: 10) {
            probe.begin(clock.now()); defer { probe.end() }
            return HTTPResult(status: 429, headers: ["Retry-After": "30"])
        }
        #expect(r.status == 429)
        #expect(probe.startTimes.count == 1)
        // The penalty still applies to the next caller, who is told it won't fit their budget.
        await #expect(throws: HostGate.GateError.self) {
            _ = try await gate.perform(host: "api.crossref.org", budget: 5) { HTTPResult(status: 200) }
        }
    }

    @Test func notFoundIsNotThrottling() async throws {
        let clock = VirtualClock()
        let gate = HostGate(clock: clock)
        let probe = Probe()
        let r = try await gate.perform(host: "api.crossref.org", policy: HostGate.Policy(minInterval: 1)) {
            probe.begin(clock.now()); defer { probe.end() }
            return HTTPResult(status: 404)
        }
        #expect(r.status == 404)
        #expect(probe.startTimes.count == 1)
    }

    @Test func transportErrorReleasesTheSlot() async throws {
        let gate = HostGate(clock: VirtualClock())
        await #expect(throws: URLError.self) {
            _ = try await gate.perform(host: "api.openalex.org") { throw URLError(.timedOut) }
        }
        let r = try await gate.perform(host: "api.openalex.org") { HTTPResult(status: 200) }
        #expect(r.status == 200)
    }

    @Test func cancelledWaiterLeavesTheQueue() async throws {
        let gate = HostGate(clock: VirtualClock())
        let (holding, holdingCont) = AsyncStream<Void>.makeStream()
        let (finish, finishCont) = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await gate.perform(host: "api.crossref.org") {
                holdingCont.yield()
                for await _ in finish { break }
                return HTTPResult(status: 200)
            }
        }
        for await _ in holding { break }
        let waiter = Task { try await gate.perform(host: "api.crossref.org") { HTTPResult(status: 200) } }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiter.value }
        finishCont.yield()
        #expect(try await holder.value.status == 200)
        let after = try await gate.perform(host: "api.crossref.org") { HTTPResult(status: 201) }
        #expect(after.status == 201)
    }

    @Test func parseRetryAfter() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(HostGate.parseRetryAfter("12", now: now) == 12)
        #expect(HostGate.parseRetryAfter(" 0 ", now: now) == 0)
        #expect(HostGate.parseRetryAfter("-5", now: now) == 0)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let later = f.string(from: now.addingTimeInterval(42))
        #expect(HostGate.parseRetryAfter(later, now: now).map { abs($0 - 42) < 1 } == true)
        #expect(HostGate.parseRetryAfter("soon", now: now) == nil)
    }
}
