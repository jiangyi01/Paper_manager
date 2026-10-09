import Foundation

/// One live `claude -p --input-format stream-json --output-format stream-json` process (dive-cli
/// §3.4 A): a turn is one user line on stdin; the answer streams back as `stream_event` text
/// deltas; the `result` line ends the turn. One turn at a time. The session dies with its process
/// (a crash, a cancelled turn, a failed turn, an idle close); `ClaudeAssistBackend` then resends the
/// conversation to a fresh process (the stateless fallback). `--no-session-persistence` keeps
/// nothing under `~/.claude`; the image travels in the stdin line and is never written to disk.
///
/// Classification happens only on the result line and stderr (`ClaudeEnvelope.classifyTurn`):
/// the streamed, model-authored text is never pattern-matched.
package actor ClaudeAssistSession {
    /// What a process is started with; a turn whose model, system prompt or effort differ needs another.
    package struct Spec: Sendable, Hashable {
        package var model: String
        package var systemPrompt: String
        package var effort: String?

        package init(model: String, systemPrompt: String, effort: String?) {
            self.model = model; self.systemPrompt = systemPrompt; self.effort = effort
        }

        package init(_ r: AssistRequest) { self.init(model: r.model, systemPrompt: r.systemPrompt, effort: r.effort) }
    }

    package enum State: Sendable, Equatable { case idle, busy, closing, dead }

    private struct Turn {
        let index: Int
        let warm: Bool
        let continuation: AsyncStream<AssistEvent>.Continuation
        let started: ContinuousClock.Instant
        var firstText: ContinuousClock.Instant?
    }

    package nonisolated let spec: Spec
    package nonisolated let version: String
    private let process: StreamingProcess
    private let now: @Sendable () -> Date
    private let tap: AssistWireTap?
    private let clock = ContinuousClock()
    private var parser = ClaudeStreamParser()
    private var turn: Turn?
    package private(set) var state: State = .idle
    /// Turns that ended with a result line (success or not).
    package private(set) var turnsDone = 0
    package private(set) var lastActivity: Date
    private var pump: Task<Void, Never>?

    private init(spec: Spec, version: String, process: StreamingProcess, now: @escaping @Sendable () -> Date,
                 tap: AssistWireTap?) {
        self.spec = spec; self.version = version; self.process = process; self.now = now; self.tap = tap
        self.lastActivity = now()
    }

    /// Spawns the process (stdin open, nothing written: no turn, no quota). Throws
    /// `ProcessRunner.LaunchError` / `CancellationError`.
    package static func start(spec: Spec, launch: AssistLaunch, now: @escaping @Sendable () -> Date = Date.init,
                              tap: AssistWireTap? = nil) async throws -> ClaudeAssistSession {
        let argv = ClaudeCodeProvider.assistArgv(binary: launch.executable, model: spec.model,
                                                 systemPrompt: spec.systemPrompt, effort: spec.effort,
                                                 capabilities: ClaudeCodeProvider.Capabilities(flags: launch.flags))
        let process = try StreamingProcess.spawn(.init(executable: launch.executable, arguments: Array(argv.dropFirst()),
                                                       environment: launch.environment, currentDirectory: launch.cwd,
                                                       stdin: nil))
        Log.assist.info("claude assist process \(process.pid) started (\(launch.version, privacy: .public), \(spec.model, privacy: .public))")
        let session = ClaudeAssistSession(spec: spec, version: launch.version, process: process, now: now, tap: tap)
        await session.startPump()
        return session
    }

    private func startPump() {
        let lines = process.lines
        pump = Task { [weak self] in
            for await line in lines { await self?.handle(line) }
            await self?.processEnded()
        }
    }

    /// Idle and alive: ready for a turn.
    package var canTakeTurn: Bool { state == .idle && !process.hasExited }

    /// Not dead or closing (a turn may be running).
    package var isAlive: Bool { (state == .idle || state == .busy) && !process.hasExited }

    /// Writes one turn and streams its events (exactly one terminal event, unless the consumer
    /// stops: then the process is interrupted and the session is dead). `warm`: the process was
    /// running before this turn.
    package func send(_ line: Data, turnIndex: Int, warm: Bool) -> AsyncStream<AssistEvent> {
        let (stream, c) = AsyncStream<AssistEvent>.makeStream(bufferingPolicy: .unbounded)
        guard canTakeTurn else {
            c.yield(.failed(.generic("session_closed"), partial: nil))
            c.finish()
            return stream
        }
        state = .busy
        parser.beginTurn()
        turn = Turn(index: turnIndex, warm: warm, continuation: c, started: clock.now)
        c.onTermination = { [weak self] reason in
            if case .cancelled = reason { Task { await self?.interrupt() } }
        }
        c.yield(.waiting(warm: warm))
        c.yield(.phase(.waitingForFirstToken))
        process.send(line)
        return stream
    }

    /// Ends the session: stdin closes (the CLI exits at EOF), and after 2 s the process group is
    /// interrupted if it is still there.
    package func close() {
        guard state != .dead && state != .closing else { return }
        if let t = turn {
            turn = nil
            t.continuation.yield(.failed(.cancelled, partial: parser.text.isEmpty ? nil : parser.text))
            t.continuation.finish()
        }
        state = .closing
        process.closeInput()
        let process = self.process
        Task {
            try? await Task.sleep(for: .seconds(2))
            if !process.hasExited { process.cancel() }
        }
    }

    /// The consumer stopped mid-turn: SIGINT the process group; the session is dead (the next turn
    /// starts a fresh process). v1 has no in-band interrupt (unverified).
    private func interrupt() {
        guard turn != nil || state == .busy else { return }
        turn = nil
        state = .dead
        process.cancel()
    }

    private func handle(_ line: Data) async {
        tap?(.claude, turn?.index ?? -1, line)
        for output in parser.feed(line) {
            switch output {
            case .started(_, _, let tools):
                // Paranoia: tools must really be off (`--tools ""`).
                if !tools.isEmpty {
                    Log.assist.error("claude assist process reported \(tools.count) tools; stopping it")
                    fail(.generic("tools_not_off"))
                }
            case .delta(let s):
                markText()
                turn?.continuation.yield(.delta(s))
            case .replace(let s):
                markText()
                turn?.continuation.yield(.replace(s))
            case .oversize:
                fail(.invalidOutput("oversize_line"))
            case .result(let env):
                await finishTurn(env)
            }
        }
    }

    private func markText() {
        guard var t = turn, t.firstText == nil else { return }
        t.firstText = clock.now
        turn = t
        t.continuation.yield(.phase(.streaming))
    }

    private func finishTurn(_ env: ClaudeEnvelope) async {
        guard let t = turn else { return }
        turnsDone += 1
        lastActivity = now()
        let streamed = parser.text
        let stderr = env.subtype == "success" && env.isError != true ? Data() : await process.stderrSoFar()
        // `turn` may have been cleared (cancelled) while stderr was read.
        guard let current = turn, current.index == t.index else { return }
        turn = nil
        switch ClaudeEnvelope.classifyTurn(result: env, stderr: stderr, exitCode: nil, now: now()) {
        case .success(let result):
            let text = (result?.isEmpty == false ? result : nil) ?? streamed
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state = .idle
                t.continuation.yield(.failed(.invalidOutput("empty_answer"), partial: nil))
                t.continuation.finish()
                return
            }
            state = .idle
            let total = Self.ms(t.started.duration(to: clock.now))
            let ttft = t.firstText.map { Self.ms(t.started.duration(to: $0)) }
            t.continuation.yield(.done(text: text, meta: AssistMeta(
                provider: AIProviderKind.claude.rawValue, model: env.model ?? spec.model, warm: t.warm,
                turnIndex: t.index, ttftMs: ttft, totalMs: total, inputTokens: env.inputTokens,
                outputTokens: env.outputTokens, costUSD: env.totalCostUSD)))
            t.continuation.finish()
        case .failure(let cls):
            // A failed turn ends the process: the next turn starts clean.
            state = .dead
            process.cancel()
            t.continuation.yield(.failed(Self.failure(cls), partial: streamed.isEmpty ? nil : streamed))
            t.continuation.finish()
        }
    }

    private func fail(_ failure: AssistFailure) {
        state = .dead
        process.cancel()
        guard let t = turn else { return }
        turn = nil
        t.continuation.yield(.failed(failure, partial: parser.text.isEmpty ? nil : parser.text))
        t.continuation.finish()
    }

    /// The process exited (or its stdout closed): a running turn ends with what exit code and
    /// stderr say — never the streamed text.
    private func processEnded() async {
        let result = await process.exit()
        let wasClosing = state == .closing
        state = .dead
        guard let t = turn else {
            if !wasClosing {
                Log.assist.notice("claude assist process exited between turns (exit \(result.exitCode))")
            }
            return
        }
        turn = nil
        let partial = parser.text.isEmpty ? nil : parser.text
        let failure: AssistFailure
        if result.cancelled {
            failure = .cancelled
        } else if case .failure(let cls) = ClaudeEnvelope.classifyTurn(result: nil, stderr: result.stderr,
                                                                         exitCode: result.exitCode, now: now()) {
            failure = Self.failure(cls)
        } else {
            failure = .generic("exit \(result.exitCode)")
        }
        t.continuation.yield(.failed(failure, partial: partial))
        t.continuation.finish()
    }

    package static func failure(_ c: ClaudeEnvelope.Classification) -> AssistFailure {
        switch c {
        case .success: return .invalidOutput("unexpected_card")
        case .usageLimit(let resetsAt): return .usageLimit(resetsAt: resetsAt)
        case .overloaded: return .overloaded
        case .notLoggedIn: return .notLoggedIn(.loggedOut)
        case .maxTurns: return .generic("max_turns")
        case .invalidOutput(let m): return .invalidOutput(m)
        case .binaryMissing: return .binaryMissing
        case .generic(let m): return .generic(m)
        }
    }

    /// One stdin line: an image block first (if any), then the text block — the Agent SDK's
    /// streaming-input shape (dive-cli §3.2). Compact JSON escapes the newlines, so it is one line.
    package static func userLine(text: String, image: AssistImage?) -> Data {
        var content: [JSONValue] = []
        if let image {
            content.append(.object([
                "type": .string("image"),
                "source": .object(["type": .string("base64"), "media_type": .string(image.mediaType),
                                   "data": .string(image.data.base64EncodedString())]),
            ]))
        }
        content.append(.object(["type": .string("text"), "text": .string(text)]))
        let message: JSONValue = .object([
            "type": .string("user"), "session_id": .string(""), "parent_tool_use_id": .null,
            "message": .object(["role": .string("user"), "content": .array(content)]),
        ])
        return Data((message.compactString() + "\n").utf8)
    }

    private static func ms(_ d: Duration) -> Int {
        let c = d.components
        return Int(c.seconds) * 1_000 + Int(c.attoseconds / 1_000_000_000_000_000)
    }
}
