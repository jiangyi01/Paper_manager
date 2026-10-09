import Foundation

extension ProcessRunner {
    /// Interactive grace (READING_ASSIST_PLAN §6.2): SIGINT → 2 s → SIGTERM → 2 s → SIGKILL on the
    /// child's process group. Cards keep the 10 s / 5 s default.
    package static let interactive = ProcessRunner(interruptGrace: .seconds(2), terminateGrace: .seconds(2),
                                                   drainGrace: .seconds(1))
}

/// A long-lived child for the interactive assist: NDJSON lines out as they arrive, stdin kept open
/// for more turns (`send`), explicit `closeInput`, and `cancel` = the process-group escalation of
/// `ProcessRunner` with the interactive grace. There is no whole-process timeout: the lane owns the
/// per-turn watchdogs and the backend the idle timer.
///
/// Started only by the subscription backends (`ClaudeAssistSession`, `CodexAssistTurn`), which run
/// only through `AssistLane` — whose every turn and pre-spawn asks `AssistGate` first (contract test
/// `AssistContractGrepTests.noStreamingSpawnBypassesTheGate`). Content travels on stdin only.
package final class StreamingProcess: @unchecked Sendable {
    /// One stdout line per element (no trailing newline). Finishes when the child exited and its
    /// stdout reached EOF — before `exit()` returns.
    package let lines: AsyncStream<Data>
    package let pid: Int32
    private let child: SpawnedChild
    private let box = ResultBox()

    private init(child: SpawnedChild, lines: AsyncStream<Data>) {
        self.child = child; self.lines = lines; self.pid = child.pid
    }

    /// Spawns `r.executable` (an initial `r.stdin`, if any, is written first; `r.timeout` is
    /// ignored). Throws `ProcessRunner.LaunchError` when the child can't start, and
    /// `CancellationError` when the task is already cancelled (nothing is spawned then).
    package static func spawn(_ r: ProcessRunner.Request, grace: ProcessRunner = .interactive) throws -> StreamingProcess {
        try Task.checkCancellation()
        let (lines, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let child = try SpawnedChild.spawn(r, grace: grace, mode: .streaming(onLine: { continuation.yield($0) }))
        let process = StreamingProcess(child: child, lines: lines)
        let box = process.box
        child.start(timeout: nil) { result in
            continuation.finish()
            box.resolve(result)
        }
        return process
    }

    /// Writes `line` to stdin (it should end in "\n"). Dropped once stdin is closed.
    package func send(_ line: Data) { child.send(line) }

    /// Closes stdin after what was sent is written: a stream-json CLI ends its session at EOF.
    package func closeInput() { child.requestCloseInput() }

    /// SIGINT → SIGTERM → SIGKILL on the process group (no-op once it exited).
    package func cancel() { child.cancel() }

    /// The exit status (stdout empty in streaming mode; stderr ≤ 64 KB).
    package func exit() async -> ProcessRunner.Result { await box.value() }

    /// The child has exited and its output is drained.
    package var hasExited: Bool { box.isResolved }

    /// stderr captured so far (≤ 64 KB), while the child may still run.
    package func stderrSoFar() async -> Data {
        await withCheckedContinuation { (c: CheckedContinuation<Data, Never>) in
            child.stderrSnapshot { c.resume(returning: $0) }
        }
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: ProcessRunner.Result?
        private var waiters: [CheckedContinuation<ProcessRunner.Result, Never>] = []

        var isResolved: Bool { lock.withLock { result != nil } }

        func resolve(_ r: ProcessRunner.Result) {
            let pending: [CheckedContinuation<ProcessRunner.Result, Never>] = lock.withLock {
                guard result == nil else { return [] }
                result = r
                defer { waiters.removeAll() }
                return waiters
            }
            for w in pending { w.resume(returning: r) }
        }

        func value() async -> ProcessRunner.Result {
            await withCheckedContinuation { (c: CheckedContinuation<ProcessRunner.Result, Never>) in
                let ready: ProcessRunner.Result? = lock.withLock {
                    if let result { return result }
                    waiters.append(c)
                    return nil
                }
                if let ready { c.resume(returning: ready) }
            }
        }
    }
}
