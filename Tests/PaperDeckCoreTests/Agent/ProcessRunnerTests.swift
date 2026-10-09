import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct ProcessRunnerTests {
    /// Short grace periods so escalation tests finish in seconds.
    private let fast = ProcessRunner(interruptGrace: .seconds(1), terminateGrace: .seconds(1), drainGrace: .seconds(1))

    private func elapsed(_ body: () async throws -> Void) async rethrows -> Double {
        let clock = ContinuousClock()
        let t0 = clock.now
        try await body()
        let d = t0.duration(to: clock.now).components
        return Double(d.seconds) + Double(d.attoseconds) / 1e18
    }

    @Test func catRoundTripsFiveMegabytesWithoutDeadlock() async throws {
        var bytes = [UInt8](repeating: 0, count: 5 * 1024 * 1024)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 9) }
        let input = Data(bytes)
        let r = try await fast.run(.init(executable: "/bin/cat", stdin: input, timeout: .seconds(30)))
        #expect(r.exitCode == 0)
        #expect(r.signal == nil)
        #expect(!r.timedOut)
        #expect(!r.cancelled)
        #expect(r.stdout.count == input.count)
        #expect(r.stdout == input)
        #expect(r.stderr.isEmpty)
    }

    @Test func capturesStdoutStderrAndExitCode() async throws {
        let r = try await fast.run(.init(executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"]))
        #expect(r.exitCode == 3)
        #expect(String(decoding: r.stdout, as: UTF8.self) == "out\n")
        #expect(String(decoding: r.stderr, as: UTF8.self) == "err\n")
    }

    @Test func largeOutputOnBothStreams() async throws {
        let script = "head -c 3000000 /dev/zero; head -c 2000000 /dev/zero >&2"
        let r = try await fast.run(.init(executable: "/bin/sh", arguments: ["-c", script], timeout: .seconds(30)))
        #expect(r.exitCode == 0)
        #expect(r.stdout.count == 3_000_000)
        #expect(r.stderr.count == 2_000_000)
    }

    @Test func environmentIsExactlyWhatWasPassed() async throws {
        let r = try await fast.run(.init(executable: "/usr/bin/env", environment: ["FOO": "bar baz", "A": "1"]))
        let lines = Set(String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").map(String.init))
        #expect(lines == ["FOO=bar baz", "A=1"])
    }

    @Test func workingDirectoryIsHonored() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await fast.run(.init(executable: "/bin/pwd", arguments: ["-P"], currentDirectory: dir.path))
        let printed = String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        #expect(URL(fileURLWithPath: printed).resolvingSymlinksInPath() == dir.resolvingSymlinksInPath())
        #expect(printed.hasSuffix(dir.lastPathComponent))
    }

    @Test func nilStdinIsDevNull() async throws {
        // Load-tolerant (ENV-1): a cat on an open pipe would hang until the timeout; /dev/null ends at once.
        let r = try await fast.run(.init(executable: "/bin/cat", stdin: nil, timeout: .seconds(30)))
        #expect(r.exitCode == 0)
        #expect(r.stdout.isEmpty)
        #expect(!r.timedOut)
    }

    @Test func timeoutInterruptsWithSIGINTFirst() async throws {
        var r: ProcessRunner.Result?
        let seconds = try await elapsed {
            r = try await fast.run(.init(executable: "/bin/sleep", arguments: ["60"], timeout: .seconds(1)))
        }
        let result = try #require(r)
        #expect(result.timedOut)
        #expect(result.signal == SIGINT)
        #expect(result.exitCode == 128 + SIGINT)
        #expect(seconds < 45)                   // load-tolerant (ENV-1); the child sleeps 60
    }

    /// A child that ignores SIGINT and SIGTERM still dies: SIGKILL after both graces.
    @Test func timeoutEscalatesToSIGKILL() async throws {
        var r: ProcessRunner.Result?
        let seconds = try await elapsed {
            // 3 s, not 1: on a loaded machine the shell must have set its trap before the SIGINT (ENV-1).
            r = try await fast.run(.init(executable: "/bin/sh", arguments: ["-c", "trap '' INT TERM; sleep 60; echo late"],
                                         timeout: .seconds(3)))
        }
        let result = try #require(r)
        #expect(result.timedOut)
        #expect(result.signal == SIGKILL)
        #expect(result.stdout.isEmpty)
        #expect(seconds >= 2.5)
        #expect(seconds < 45)                   // load-tolerant (ENV-1); the child sleeps 60
    }

    @Test func childThatNeverReadsStdinDoesNotCrashUs() async throws {
        let input = Data(repeating: 0x61, count: 5 * 1024 * 1024)
        let t = try await fast.run(.init(executable: "/usr/bin/true", stdin: input, timeout: .seconds(60)))   // load-tolerant
        #expect(t.exitCode == 0)
        #expect(!t.timedOut)
        let h = try await fast.run(.init(executable: "/usr/bin/head", arguments: ["-c", "10"], stdin: input,
                                         timeout: .seconds(60)))
        #expect(h.exitCode == 0)
        #expect(h.stdout == Data(repeating: 0x61, count: 10))
    }

    @Test func emptyStdinGivesImmediateEOF() async throws {
        let r = try await fast.run(.init(executable: "/usr/bin/wc", arguments: ["-c"], stdin: Data(), timeout: .seconds(5)))
        #expect(String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "0")
    }

    @Test func taskCancellationStopsTheChild() async throws {
        let runner = fast
        let task = Task {
            try await runner.run(.init(executable: "/bin/sleep", arguments: ["60"], timeout: .seconds(60)))
        }
        try await Task.sleep(for: .milliseconds(300))
        var r: ProcessRunner.Result?
        let seconds = try await elapsed {
            task.cancel()
            r = try await task.value
        }
        let result = try #require(r)
        #expect(result.cancelled)
        #expect(!result.timedOut)
        #expect(seconds < 30)                   // load-tolerant (ENV-1); the child sleeps 60
    }

    @Test func alreadyCancelledTaskNeverSpawns() async {
        let runner = fast
        let task = Task { () async throws -> ProcessRunner.Result in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(.init(executable: "/bin/sleep", arguments: ["60"]))
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func launchFailures() async {
        await #expect(throws: ProcessRunner.LaunchError(path: "/nonexistent/claude", code: ENOENT)) {
            _ = try await fast.run(.init(executable: "/nonexistent/claude"))
        }
        await #expect(throws: ProcessRunner.LaunchError.self) {
            _ = try await fast.run(.init(executable: "/bin/echo", currentDirectory: "/nonexistent/dir"))
        }
        // A directory is not executable.
        await #expect(throws: ProcessRunner.LaunchError.self) {
            _ = try await fast.run(.init(executable: "/tmp"))
        }
    }

    @Test func manyConcurrentRunsKeepTheirOwnOutput() async throws {
        let runner = fast
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for i in 0..<16 {
                group.addTask {
                    let r = try await runner.run(.init(executable: "/bin/sh", arguments: ["-c", "cat; echo \(i)"],
                                                       stdin: Data("in\(i) ".utf8), timeout: .seconds(20)))
                    return (i, String(decoding: r.stdout, as: UTF8.self))
                }
            }
            for try await (i, out) in group { #expect(out == "in\(i) \(i)\n") }
        }
    }
}
