import Darwin
import Foundation
import Testing
@testable import PaperDeckCore

/// `LineSplitter` (random chunk splits, CRLF, oversize lines) and `StreamingProcess` on `/bin/sh`
/// fixture children: lines in order as they arrive, stdin kept open between sends, explicit EOF,
/// process-group cancel escalation, stderr cap. `ProcessRunner.run` (cards) is untouched — its own
/// suite (`ProcessRunnerTests`) and the contract test pin it.
@Suite struct LineSplitterTests {
    /// A tiny deterministic RNG (xorshift), so a failing split reproduces.
    struct Rng: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
    }

    @Test func randomChunkSplitsGiveTheSameLines() throws {
        var expected: [Data] = []
        var stream = Data()
        for i in 0..<300 {
            let line = Data((String(repeating: "é字x", count: i % 37) + "#\(i)").utf8)
            expected.append(line)
            stream.append(line)
            stream.append(0x0A)
        }
        for seed in [1, 7, 42, 99, 1234] as [UInt64] {
            var rng = Rng(state: seed)
            var splitter = LineSplitter()
            var got: [Data] = []
            var offset = 0
            while offset < stream.count {
                let n = min(stream.count - offset, Int.random(in: 1...97, using: &rng))
                got += splitter.push(stream.subdata(in: offset..<(offset + n)))
                offset += n
            }
            #expect(splitter.finish() == nil)
            #expect(got == expected, "seed \(seed)")
        }
    }

    @Test func crlfEmptyLinesAndTheUnterminatedRest() {
        var s = LineSplitter()
        #expect(s.push(Data("a\r\n\nb".utf8)) == [Data("a".utf8), Data()])
        #expect(s.push(Data("c".utf8)).isEmpty)
        #expect(s.finish() == Data("bc".utf8))
        #expect(s.finish() == nil)
    }

    @Test func anOversizeLineBecomesOneMarkerAndTheNextLinesSurvive() {
        var s = LineSplitter(maxLine: 16)
        var out = s.push(Data("ok\n".utf8))
        out += s.push(Data(String(repeating: "x", count: 10).utf8))
        out += s.push(Data(String(repeating: "y", count: 10).utf8))     // over the cap: marker, then discard
        out += s.push(Data(String(repeating: "z", count: 40).utf8))     // still the same line: dropped
        out += s.push(Data("zz\nnext\n".utf8))
        #expect(out == [Data("ok".utf8), LineSplitter.oversizeMarker, Data("next".utf8)])
        // An oversize line inside one chunk.
        var t = LineSplitter(maxLine: 4)
        #expect(t.push(Data("abcdefgh\nij\n".utf8)) == [LineSplitter.oversizeMarker, Data("ij".utf8)])
        #expect(t.finish() == nil)
    }
}

@Suite struct StreamingProcessTests {
    private let fast = ProcessRunner(interruptGrace: .milliseconds(300), terminateGrace: .milliseconds(300),
                                     drainGrace: .milliseconds(300))

    private func sh(_ script: String, stdin: Data? = nil, grace: ProcessRunner? = nil) throws -> StreamingProcess {
        try StreamingProcess.spawn(.init(executable: "/bin/sh", arguments: ["-c", script],
                                         environment: ["PATH": "/usr/bin:/bin"], stdin: stdin), grace: grace ?? fast)
    }

    @Test func stdinStaysOpenBetweenTurnsAndEOFIsExplicit() async throws {
        let p = try sh(#"while IFS= read -r l; do printf 'got:%s\n' "$l"; done; echo bye"#)
        var it = p.lines.makeAsyncIterator()
        p.send(Data("one\n".utf8))
        #expect(await it.next() == Data("got:one".utf8))
        // Nothing more arrives until the next send: the child is still waiting on stdin.
        try await Task.sleep(for: .milliseconds(150))
        #expect(!p.hasExited)
        p.send(Data("two\nthree\n".utf8))
        #expect(await it.next() == Data("got:two".utf8))
        #expect(await it.next() == Data("got:three".utf8))
        p.closeInput()
        #expect(await it.next() == Data("bye".utf8))
        #expect(await it.next() == nil)
        let r = await p.exit()
        #expect(r.exitCode == 0 && !r.cancelled && r.stdout.isEmpty)
        #expect(p.hasExited)
        p.send(Data("late\n".utf8))                                 // after exit: dropped, no crash
    }

    @Test func linesArriveInOrderAsTheyAreWrittenEvenInPieces() async throws {
        let p = try sh(#"printf 'al'; sleep 0.1; printf 'pha\nbe'; sleep 0.1; printf 'ta\n'; printf 'gamma'"#)
        var got: [String] = []
        for await line in p.lines { got.append(String(decoding: line, as: UTF8.self)) }
        #expect(got == ["alpha", "beta", "gamma"])                  // the unterminated last line counts
        #expect(await p.exit().exitCode == 0)
    }

    @Test func aBurstOfLinesIsDeliveredCompletely() async throws {
        let p = try sh(#"i=0; while [ $i -lt 3000 ]; do echo "{\"n\":$i}"; i=$((i+1)); done"#)
        var count = 0
        var last = Data()
        for await line in p.lines { count += 1; last = line }
        #expect(count == 3000 && last == Data(#"{"n":2999}"#.utf8))
    }

    @Test func aLargeInitialStdinIsWrittenWithoutDeadlock() async throws {
        let payload = Data(String(repeating: "x", count: 3 * 1024 * 1024).utf8) + Data("\n".utf8)
        let p = try sh("wc -c", stdin: payload)
        p.closeInput()
        var lines: [String] = []
        for await line in p.lines { lines.append(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)) }
        #expect(lines == [String(payload.count)])
    }

    @Test func stderrIsCappedAndReadableWhileRunning() async throws {
        let p = try sh(#"head -c 200000 /dev/zero | tr '\0' 'e' >&2; echo ready; read x || true"#)
        var it = p.lines.makeAsyncIterator()
        #expect(await it.next() == Data("ready".utf8))
        #expect(await assistEventually { await p.stderrSoFar().count == SpawnedChild.streamingStderrLimit })
        p.closeInput()
        let r = await p.exit()
        #expect(r.stderr.count == SpawnedChild.streamingStderrLimit && r.exitCode == 0)
    }

    @Test func cancelEscalatesOnTheWholeProcessGroup() async throws {
        // The shell ignores SIGINT (so does its child): SIGTERM after the grace ends both.
        let p = try sh(#"trap '' INT; sleep 30 & echo "child $!"; wait"#)
        var it = p.lines.makeAsyncIterator()
        let first = String(decoding: await it.next() ?? Data(), as: UTF8.self)
        let child = try #require(Int32(first.replacingOccurrences(of: "child ", with: "")))
        let clock = ContinuousClock()
        let t0 = clock.now
        p.cancel()
        let r = await p.exit()
        let elapsed = t0.duration(to: clock.now)
        #expect(r.cancelled)
        #expect(r.signal == SIGTERM || r.signal == SIGKILL)
        // Load-tolerant (ENV-1): under a busy machine the escalation takes longer; well under the
        // child's 30 s still proves it was stopped, not waited for.
        #expect(elapsed >= .milliseconds(250) && elapsed < .seconds(25))
        // The grandchild in the same group is gone too (no stray `sleep 30`).
        #expect(await assistEventually(.seconds(20)) { kill(child, 0) != 0 })
    }

    @Test func theInteractiveGraceIsTwoAndTwoSeconds() {
        #expect(ProcessRunner.interactive.interruptGrace == .seconds(2))
        #expect(ProcessRunner.interactive.terminateGrace == .seconds(2))
        // Cards keep their own (longer) default.
        #expect(ProcessRunner().interruptGrace == .seconds(10) && ProcessRunner().terminateGrace == .seconds(5))
    }

    @Test func launchFailuresAndCancelledTasksSpawnNothing() async throws {
        #expect(throws: ProcessRunner.LaunchError.self) {
            _ = try StreamingProcess.spawn(.init(executable: "/nonexistent/claude"))
        }
        let cli = try FakeCLI("echo spawned > \"$PD_FAKE_DIR/ran\"\n")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try StreamingProcess.spawn(.init(executable: cli.script.path, environment: ["PD_FAKE_DIR": cli.dir.path]))
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        try await Task.sleep(for: .milliseconds(200))
        #expect(cli.read("ran") == nil)
    }

    @Test func theCardRunnerStillCollectsAndClosesStdin() async throws {
        let r = try await fast.run(.init(executable: "/bin/sh", arguments: ["-c", "cat; echo done"], stdin: Data("in\n".utf8),
                                         timeout: .seconds(10)))
        #expect(String(decoding: r.stdout, as: UTF8.self) == "in\ndone\n")
    }
}
