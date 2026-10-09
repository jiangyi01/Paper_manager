import Darwin
import Foundation

/// Runs one child process to completion without touching the main actor or
/// blocking the cooperative pool.
///
/// - stdout/stderr are drained and stdin is written concurrently through
///   non-blocking dispatch sources, so a child that fills the 64 KB pipe buffer
///   before reading its input can never deadlock us.
/// - The child leads its own process group; timeout and Task cancellation both
///   escalate SIGINT → SIGTERM → SIGKILL on that group (SIGINT first because
///   the CLI turns SIGTERM into exit 143 without cleanup).
/// - A child that exits without reading stdin just ends the write (EPIPE is
///   reported per-fd via F_SETNOSIGPIPE, never as a process-wide SIGPIPE).
/// - Posix_spawn with CLOEXEC_DEFAULT: the child inherits fds 0–2 only.
package struct ProcessRunner: Sendable {
    package struct Request: Sendable, Equatable {
        package var executable: String
        package var arguments: [String]
        package var environment: [String: String]
        package var currentDirectory: String?
        /// nil → /dev/null; empty → immediate EOF.
        package var stdin: Data?
        package var timeout: Duration

        package init(executable: String, arguments: [String] = [], environment: [String: String] = [:],
                     currentDirectory: String? = nil, stdin: Data? = nil, timeout: Duration = .seconds(60)) {
            self.executable = executable; self.arguments = arguments; self.environment = environment
            self.currentDirectory = currentDirectory; self.stdin = stdin; self.timeout = timeout
        }
    }

    package struct Result: Sendable, Equatable {
        /// Exit status, or 128 + signal when an uncaught signal ended the child.
        package var exitCode: Int32
        package var signal: Int32?
        package var stdout: Data
        package var stderr: Data
        package var timedOut: Bool
        package var cancelled: Bool
        package var durationMs: Int

        package init(exitCode: Int32, signal: Int32? = nil, stdout: Data = Data(), stderr: Data = Data(),
                     timedOut: Bool = false, cancelled: Bool = false, durationMs: Int = 0) {
            self.exitCode = exitCode; self.signal = signal; self.stdout = stdout; self.stderr = stderr
            self.timedOut = timedOut; self.cancelled = cancelled; self.durationMs = durationMs
        }
    }

    /// The child never started (missing executable, bad cwd, fd exhaustion…).
    package struct LaunchError: Error, Equatable, CustomStringConvertible {
        package var path: String
        package var code: Int32          // errno
        package init(path: String, code: Int32) { self.path = path; self.code = code }
        package var description: String { "cannot launch \(path): \(String(cString: strerror(code)))" }
    }

    /// SIGINT → SIGTERM delay.
    package var interruptGrace: Duration
    /// SIGTERM → SIGKILL delay.
    package var terminateGrace: Duration
    /// After exit, how long to wait for EOF on pipes a stray grandchild may still hold.
    package var drainGrace: Duration

    package init(interruptGrace: Duration = .seconds(10), terminateGrace: Duration = .seconds(5),
                 drainGrace: Duration = .seconds(3)) {
        self.interruptGrace = interruptGrace; self.terminateGrace = terminateGrace; self.drainGrace = drainGrace
    }

    /// Throws `LaunchError` if the child could not start and `CancellationError`
    /// if the task was cancelled before spawning. Timeouts and later
    /// cancellation are reported in the `Result`.
    package func run(_ request: Request) async throws -> Result {
        try Task.checkCancellation()
        let child = try SpawnedChild.spawn(request, grace: self)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
                child.start(timeout: request.timeout) { cont.resume(returning: $0) }
            }
        } onCancel: {
            child.cancel()
        }
    }
}

/// One live child. All mutable state is confined to `queue`.
///
/// Two modes. `.collect` (cards, `ProcessRunner.run`): stdout and stderr are buffered until exit
/// and stdin is closed once the one-shot input is written. `.streaming` (the interactive assist,
/// `StreamingProcess`): stdout is split into lines as it arrives and handed to `onLine` (on
/// `queue`, in order, all before the completion); stderr is kept up to `streamingStderrLimit`;
/// stdin stays open after the buffer drains (the write source is suspended, `send` resumes it)
/// until `requestCloseInput`; there is no whole-process timeout (the caller owns the watchdogs).
final class SpawnedChild: @unchecked Sendable {
    enum Mode {
        case collect
        case streaming(onLine: @Sendable (Data) -> Void)

        var isStreaming: Bool { if case .streaming = self { return true }; return false }
    }

    private let queue = DispatchQueue(label: "\(Log.subsystem).process-io")
    let pid: pid_t
    private let started = DispatchTime.now()
    private let grace: ProcessRunner
    private let mode: Mode

    private var stdoutFD: Int32
    private var stderrFD: Int32
    private var stdinFD: Int32               // -1 when stdin is /dev/null or closed
    private var input: Data
    private var inputOffset = 0

    private var stdoutData = Data()
    private var stderrData = Data()
    /// Per-stream capture limit; a runaway child is still drained, the excess dropped.
    private static let captureLimit = 64 * 1024 * 1024
    /// Streaming mode keeps at most this much stderr (diagnostics only).
    static let streamingStderrLimit = 64 * 1024
    private var readSources: [Int32: DispatchSourceRead] = [:]
    private var writeSource: DispatchSourceWrite?
    /// Streaming: the write source is suspended while there is nothing to write (balanced by `resume`).
    private var writeSuspended = false
    /// Streaming: `requestCloseInput` was called; stdin closes once the buffer is written.
    private var closeRequested = false
    private var readBuffer = [UInt8](repeating: 0, count: 64 * 1024)
    private var splitter = LineSplitter()

    private var exitStatus: (code: Int32, signal: Int32?)?
    private var timedOut = false
    private var cancelled = false
    private var escalating = false
    private var finished = false
    private var timers: [DispatchWorkItem] = []
    private var completion: (@Sendable (ProcessRunner.Result) -> Void)?

    private init(pid: pid_t, stdoutFD: Int32, stderrFD: Int32, stdinFD: Int32, input: Data, grace: ProcessRunner,
                 mode: Mode) {
        self.pid = pid; self.stdoutFD = stdoutFD; self.stderrFD = stderrFD; self.stdinFD = stdinFD
        self.input = input; self.grace = grace; self.mode = mode
    }

    // MARK: Spawn

    /// Streaming mode always gives the child a stdin pipe (an initial `r.stdin` is written first).
    static func spawn(_ r: ProcessRunner.Request, grace: ProcessRunner, mode: Mode = .collect) throws -> SpawnedChild {
        if let cwd = r.currentDirectory {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
                throw ProcessRunner.LaunchError(path: cwd, code: ENOENT)
            }
        }

        var opened: [Int32] = []
        func makePipe() throws -> (read: Int32, write: Int32) {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else { throw ProcessRunner.LaunchError(path: r.executable, code: errno) }
            for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            opened += fds
            return (fds[0], fds[1])
        }
        func closeAll() { for fd in opened { close(fd) } }

        let out: (read: Int32, write: Int32)
        let err: (read: Int32, write: Int32)
        var inp: (read: Int32, write: Int32)?
        do {
            out = try makePipe()
            err = try makePipe()
            if r.stdin != nil || mode.isStreaming { inp = try makePipe() }
        } catch {
            closeAll()
            throw error
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let inp {
            posix_spawn_file_actions_adddup2(&actions, inp.read, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, out.write, 1)
        posix_spawn_file_actions_adddup2(&actions, err.write, 2)
        if let cwd = r.currentDirectory { posix_spawn_file_actions_addchdir(&actions, cwd) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK
                                              | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        // Ignored dispositions (e.g. our SIGPIPE) would otherwise be inherited.
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        posix_spawnattr_setsigdefault(&attr, &defaults)

        let argv: [UnsafeMutablePointer<CChar>?] = ([r.executable] + r.arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = r.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for p in argv { free(p) }
            for p in envp { free(p) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, r.executable, &actions, &attr, argv, envp)
        // The child's ends now live in the child (or nowhere, on failure).
        close(out.write); close(err.write)
        if let inp { close(inp.read) }
        guard rc == 0 else {
            close(out.read); close(err.read)
            if let inp { close(inp.write) }
            throw ProcessRunner.LaunchError(path: r.executable, code: rc)
        }

        for fd in [out.read, err.read] { setNonBlocking(fd) }
        if let inp {
            setNonBlocking(inp.write)
            _ = fcntl(inp.write, F_SETNOSIGPIPE, 1)
        }
        return SpawnedChild(pid: pid, stdoutFD: out.read, stderrFD: err.read, stdinFD: inp?.write ?? -1,
                            input: r.stdin ?? Data(), grace: grace, mode: mode)
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    // MARK: Lifecycle

    /// `timeout` nil: no whole-process watchdog (streaming mode passes nil).
    func start(timeout: Duration?, completion: @escaping @Sendable (ProcessRunner.Result) -> Void) {
        queue.async { [self] in
            self.completion = completion
            for (fd, isStdout) in [(stdoutFD, true), (stderrFD, false)] {
                let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                src.setEventHandler { [weak self] in self?.drain(fd, isStdout: isStdout) }
                src.setCancelHandler { close(fd) }
                readSources[fd] = src
                src.activate()
            }
            if stdinFD >= 0 {
                if input.isEmpty && !mode.isStreaming {
                    close(stdinFD)
                    stdinFD = -1
                } else {
                    let fd = stdinFD
                    let src = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    src.setEventHandler { [weak self] in self?.pump() }
                    src.setCancelHandler { close(fd) }
                    writeSource = src
                    src.activate()
                }
            }
            if let timeout {
                schedule(after: timeout) { child in
                    guard child.exitStatus == nil else { return }
                    child.timedOut = true
                    child.escalate()
                }
            }
            watchExit()
        }
    }

    func cancel() {
        queue.async { [self] in
            guard exitStatus == nil, !cancelled else { return }
            cancelled = true
            escalate()
        }
    }

    /// Streaming: appends `data` to stdin (dropped once stdin is closed or closing).
    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            guard mode.isStreaming, stdinFD >= 0, !closeRequested, writeSource != nil else { return }
            if inputOffset >= input.count {
                input = data
                inputOffset = 0
            } else {
                input.append(data)
            }
            if writeSuspended {
                writeSuspended = false
                writeSource?.resume()
            }
        }
    }

    /// Streaming: closes stdin once what was sent is written (the child sees EOF).
    func requestCloseInput() {
        queue.async { [self] in
            closeRequested = true
            if inputOffset >= input.count { closeInput() }
        }
    }

    /// stderr captured so far.
    func stderrSnapshot(_ deliver: @escaping @Sendable (Data) -> Void) {
        queue.async { [self] in deliver(stderrData) }
    }

    /// Blocks a GCD thread (never the cooperative pool) until the child exits.
    /// WNOWAIT leaves it a zombie so its pid/pgid cannot be recycled before
    /// `reap` runs on `queue` — no signal can ever hit an unrelated process.
    private func watchExit() {
        let pid = self.pid
        DispatchQueue.global(qos: .utility).async { [self] in
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
            queue.async { self.reap() }
        }
    }

    private func reap() {
        var status: Int32 = 0
        var rc: pid_t
        repeat { rc = waitpid(pid, &status, 0) } while rc == -1 && errno == EINTR
        if rc == pid {
            let sig = status & 0x7f
            exitStatus = sig == 0 ? (code: (status >> 8) & 0xff, signal: nil) : (code: 128 + sig, signal: sig)
        } else {
            exitStatus = (code: -1, signal: nil)
        }
        closeInput()
        schedule(after: grace.drainGrace) { child in
            for src in child.readSources.values { src.cancel() }
            child.readSources.removeAll()
            child.flushPartialLine()
            child.finishIfDone()
        }
        finishIfDone()
    }

    private func escalate() {
        guard !escalating else { return }
        escalating = true
        sendSignal(SIGINT)
        schedule(after: grace.interruptGrace) { child in
            guard child.exitStatus == nil else { return }
            child.sendSignal(SIGTERM)
            child.schedule(after: child.grace.terminateGrace) { child in
                guard child.exitStatus == nil else { return }
                child.sendSignal(SIGKILL)
            }
        }
    }

    private func sendSignal(_ sig: Int32) {
        if killpg(pid, sig) != 0 { _ = kill(pid, sig) }
    }

    /// Timers hold the child weakly so a finished run is freed immediately.
    private func schedule(after delay: Duration, _ body: @escaping @Sendable (SpawnedChild) -> Void) {
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            body(self)
        }
        timers.append(item)
        queue.asyncAfter(deadline: .now() + delay.dispatchInterval, execute: item)
    }

    // MARK: I/O

    private func drain(_ fd: Int32, isStdout: Bool) {
        while true {
            let n = readBuffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                if case .streaming(let onLine) = mode {
                    readBuffer.withUnsafeBytes { raw in
                        let chunk = UnsafeRawBufferPointer(rebasing: raw[0..<n])
                        if isStdout {
                            for line in splitter.push(chunk) { onLine(line) }
                        } else {
                            let keep = min(n, max(0, Self.streamingStderrLimit - stderrData.count))
                            if keep > 0 { stderrData.append(contentsOf: UnsafeRawBufferPointer(rebasing: chunk[0..<keep])) }
                        }
                    }
                    continue
                }
                let held = isStdout ? stdoutData.count : stderrData.count
                let keep = min(n, max(0, Self.captureLimit - held))
                if keep > 0 {
                    readBuffer.withUnsafeBytes { raw in
                        let chunk = UnsafeRawBufferPointer(rebasing: raw[0..<keep])
                        if isStdout { stdoutData.append(contentsOf: chunk) } else { stderrData.append(contentsOf: chunk) }
                    }
                }
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN { return }
            // EOF or a hard error: this stream is done.
            readSources.removeValue(forKey: fd)?.cancel()
            if isStdout { flushPartialLine() }
            finishIfDone()
            return
        }
    }

    /// Streaming: a last line without a trailing newline still counts.
    private func flushPartialLine() {
        guard case .streaming(let onLine) = mode, let rest = splitter.finish() else { return }
        onLine(rest)
    }

    private func pump() {
        while inputOffset < input.count {
            let offset = inputOffset
            let n = input.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(stdinFD, base + offset, min(64 * 1024, raw.count - offset))
            }
            if n > 0 { inputOffset += n; continue }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN { return }
            closeInput()                            // EPIPE: the child stopped reading
            return
        }
        if mode.isStreaming && !closeRequested {
            // Everything sent is written: wait (suspended, no busy loop) for the next `send`.
            input = Data()
            inputOffset = 0
            if !writeSuspended, let src = writeSource {
                writeSuspended = true
                src.suspend()
            }
            return
        }
        closeInput()
    }

    private func closeInput() {
        if let src = writeSource {
            // A suspended source must be resumed before it is cancelled (or released).
            if writeSuspended {
                writeSuspended = false
                src.resume()
            }
            src.cancel()
            writeSource = nil
        } else if stdinFD >= 0 && mode.isStreaming {
            close(stdinFD)
        }
        stdinFD = -1
        input = Data()
        inputOffset = 0
    }

    private func finishIfDone() {
        guard !finished, let exit = exitStatus, readSources.isEmpty, let completion else { return }
        finished = true
        closeInput()
        for t in timers { t.cancel() }
        timers.removeAll()
        self.completion = nil
        let elapsed = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
        completion(ProcessRunner.Result(
            exitCode: exit.code, signal: exit.signal, stdout: stdoutData, stderr: stderrData,
            timedOut: timedOut, cancelled: cancelled, durationMs: Int(elapsed / 1_000_000)))
    }
}

fileprivate extension Duration {
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        guard seconds >= 0 else { return .nanoseconds(0) }
        guard seconds < Int64(Int.max / 1_000_000_000) - 1 else { return .never }
        let nanos = max(0, seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
        return .nanoseconds(Int(nanos))
    }
}
