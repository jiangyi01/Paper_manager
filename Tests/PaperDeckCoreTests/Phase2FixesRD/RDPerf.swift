import Foundation

/// Timing in the test gate (ENV-1). In a full `./test.sh` run every suite runs in parallel and any
/// one measurement can come out several times slower than the code's own cost — the intake checks
/// measured 13.6 / 18.3 ms alone and up to 55 / 85 ms beside the other suites, against budgets of 30 / 60.
/// So the default gate takes the best of a few rounds (a pause between them lets a burst of load
/// pass) against three times the budget — still failing a check that really got slow — and the strict
/// budgets, plus the long timing-only probes, run with `PAPERDECK_PERF_PROBES=1` on a quiet machine
/// (`PAPERDECK_PERF_PROBES=1 ./test.sh -c release -j 4 --filter 'RDTombstoneScan|RDReaderFind|TombstoneScan|intakeCheckIsCheap|theCheckInsideTheCommitLockIsCheap'`).
enum RDPerf {
    static let probes = ProcessInfo.processInfo.environment["PAPERDECK_PERF_PROBES"] == "1"

    /// The budget the gate asserts: `budget` with the perf probes on, three times it otherwise.
    static func gate(_ budget: Double) -> Double { probes ? budget : budget * 3 }

    /// The best of up to `rounds` rounds of `runs` timings (ms) of `body`, stopping at the first
    /// round whose best is under `budget`; also the last round's median (printed).
    static func best(rounds: Int = 4, runs: Int, under budget: Double,
                     _ body: () async throws -> Void) async rethrows -> (best: Double, median: Double) {
        var best = Double.infinity, median = 0.0
        for round in 0..<max(1, rounds) {
            if round > 0 { try? await Task.sleep(for: .milliseconds(750)) }
            var times: [Double] = []
            for _ in 0..<max(1, runs) {
                let t0 = DispatchTime.now().uptimeNanoseconds
                try await body()
                times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            median = times.sorted()[times.count / 2]
            best = min(best, times.min() ?? .infinity)
            if best < budget { break }
        }
        return (best, median)
    }
}
