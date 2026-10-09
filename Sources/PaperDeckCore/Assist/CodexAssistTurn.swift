import Foundation

/// One Codex assist turn: one `codex exec --ephemeral --json -o last.txt [--image=shot.png]` run
/// with the turn's blocks on stdin (dive-cli §4). Codex has no live session: every follow-up resends
/// the conversation (`AssistFraming.statelessText`). The answer arrives whole (or as full-text
/// snapshots), never as token deltas; the `-o` file is the authoritative final text.
///
/// The image is written mode 0600 into `jobs/assist-<uuid>/`, and that folder is removed when the
/// turn ends (`CodexAssistBackend` sweeps leftovers of a crash). Nothing else is persisted: no
/// stdout, no answer. Classification reads only error events and stderr
/// (`CodexEvents.classifyFailure`), never the model's message.
package enum CodexAssistTurn {
    package static let jobPrefix = "assist-"
    package static let lastMessageFileName = "last.txt"
    /// stdin ceiling (the card path's).
    package static let stdinLimit = CodexProvider.stdinLimit

    /// Runs the turn and yields its events into `c`: exactly one terminal event, except when the
    /// task is cancelled (then the process group is interrupted and nothing more is yielded).
    package static func run(_ r: AssistRequest, turnIndex: Int, launch: AssistLaunch, jobsDir: URL,
                            now: @escaping @Sendable () -> Date = Date.init, tap: AssistWireTap? = nil,
                            into c: AsyncStream<AssistEvent>.Continuation) async {
        let clock = ContinuousClock()
        let started = clock.now
        let text = AssistFraming.statelessText(turnText: r.turnText, history: r.history)
        let stdin = CodexProvider.stdinPayload(Data(text.utf8))
        guard stdin.count <= stdinLimit else {
            c.yield(.failed(.invalidOutput("stdin_too_large"), partial: nil))
            return
        }
        let jobDir = jobsDir.appendingPathComponent(jobPrefix + UUID().uuidString.lowercased(), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: jobDir) }
        let imagePath: String?
        do {
            try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            imagePath = try r.image.map { try writeImage($0, in: jobDir) }
        } catch {
            c.yield(.failed(.generic("job_dir_unavailable"), partial: nil))
            return
        }
        let lastURL = jobDir.appendingPathComponent(lastMessageFileName)
        let prompt = CodexProvider.prompt(systemPrompt: r.systemPrompt, task: CodexProvider.assistStdinInstruction)
        let argv = CodexProvider.assistArgv(binary: launch.executable, model: r.model, effort: r.effort, prompt: prompt,
                                            agentCwd: launch.cwd, lastMessagePath: lastURL.path, imagePath: imagePath,
                                            capabilities: CodexProvider.Capabilities(flags: launch.flags),
                                            disabledFeatures: launch.disabledFeatures,
                                            authCredentialsStore: launch.authCredentialsStore)
        let process: StreamingProcess
        do {
            process = try StreamingProcess.spawn(.init(executable: launch.executable, arguments: Array(argv.dropFirst()),
                                                       environment: launch.environment, currentDirectory: launch.cwd,
                                                       stdin: stdin))
        } catch is CancellationError {
            return
        } catch {
            Log.assist.error("codex assist run could not start: \(String(describing: error), privacy: .public)")
            c.yield(.failed(.binaryMissing, partial: nil))
            return
        }
        process.closeInput()                                   // the blocks are all there is: EOF after them
        var parser = CodexAssistEvents()
        var shown = ""
        var firstText: ContinuousClock.Instant?
        var oversized = false
        await withTaskCancellationHandler {
            for await line in process.lines {
                tap?(.codex, turnIndex, line)
                for output in parser.feed(line) {
                    switch output {
                    case .turnStarted:
                        c.yield(.waiting(warm: false))
                        c.yield(.phase(.waitingForFirstToken))
                    case .thinking:
                        break
                    case .message(let s):
                        if firstText == nil {
                            firstText = clock.now
                            c.yield(.phase(.streaming))
                        }
                        shown = s
                        c.yield(.replace(s))
                    case .oversize:
                        oversized = true
                        process.cancel()
                    }
                }
            }
        } onCancel: {
            process.cancel()
        }
        let result = await process.exit()
        guard !Task.isCancelled else { return }
        if oversized {
            c.yield(.failed(.invalidOutput("oversize_line"), partial: shown.isEmpty ? nil : shown))
            return
        }
        guard !result.cancelled else { return }
        let events = parser.events
        let fileText = (try? String(contentsOf: lastURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let finalText = fileText.isEmpty ? (events.lastAgentMessage ?? events.latestAgentText ?? "") : fileText
        let completed = !events.failed && (result.exitCode == 0 || events.turnsCompleted > 0)
        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if completed, !trimmed.isEmpty {
            if trimmed != shown { c.yield(.replace(trimmed)) }
            let ms = { (d: Duration) in Int(d.components.seconds) * 1_000 + Int(d.components.attoseconds / 1_000_000_000_000_000) }
            c.yield(.done(text: trimmed, meta: AssistMeta(
                provider: AIProviderKind.codex.rawValue, model: CodexProvider.model(for: r.model), warm: false,
                turnIndex: turnIndex, ttftMs: firstText.map { ms(started.duration(to: $0)) },
                totalMs: ms(started.duration(to: clock.now)), inputTokens: events.usage?.inputTokens,
                outputTokens: events.usage?.outputTokens, costUSD: nil)))
            return
        }
        let partial = shown.isEmpty ? nil : shown
        if completed {
            c.yield(.failed(.invalidOutput("empty_answer"), partial: partial))
            return
        }
        let failure = failure(CodexEvents.classifyFailure(events: events, stderr: result.stderr,
                                                          exitCode: result.exitCode, now: now()))
        Log.assist.notice("codex assist turn failed: exit \(result.exitCode) types \(parser.typeSequence.joined(separator: ","), privacy: .public)")
        c.yield(.failed(failure, partial: partial))
    }

    package static func failure(_ c: CodexEvents.Classification) -> AssistFailure {
        switch c {
        case .success: return .invalidOutput("unexpected_card")
        case .usageLimit(let resetsAt): return .usageLimit(resetsAt: resetsAt)
        case .overloaded: return .overloaded
        case .notLoggedIn: return .notLoggedIn(.loggedOut)
        case .invalidOutput(let m): return .invalidOutput(m)
        case .binaryMissing: return .binaryMissing
        case .generic(let m): return .generic(m)
        }
    }

    /// `shot.png` / `shot.jpg`, mode 0600 (never readable by other users).
    private static func writeImage(_ image: AssistImage, in dir: URL) throws -> String {
        let ext = image.mediaType == "image/jpeg" ? "jpg" : "png"
        let url = dir.appendingPathComponent("shot." + ext)
        guard FileManager.default.createFile(atPath: url.path, contents: image.data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url.path
    }
}

/// The Codex assist backend: each turn a fresh `codex exec` (Codex has no useful warm process —
/// the image must be known at argv time). `prewarm` only refreshes the login check (zero quota).
package actor CodexAssistBackend: AssistBackend {
    package nonisolated let mode: AssistMode = .codex
    private let launcher: any AssistLauncher
    private let jobsDir: URL
    private let now: @Sendable () -> Date
    private let tap: AssistWireTap?
    private var swept = false

    package init(launcher: any AssistLauncher, jobsDir: URL, now: @escaping @Sendable () -> Date = Date.init,
                 tap: AssistWireTap? = nil) {
        self.launcher = launcher; self.jobsDir = jobsDir; self.now = now; self.tap = tap
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
        sweepLeftovers()
        c.yield(.phase(.starting))
        switch await launcher.assistLaunch() {
        case .failed(let failure):
            c.yield(.failed(failure, partial: nil))
        case .ready(let launch):
            guard !Task.isCancelled else { return }
            await CodexAssistTurn.run(r, turnIndex: turnIndex, launch: launch, jobsDir: jobsDir, now: now, tap: tap, into: c)
        }
    }

    package func prewarm() async { _ = await launcher.assistLaunch() }

    package func closeSession(threadKey: String) async {}

    package nonisolated func detect() async -> AgentQueueStatus.Provider { await launcher.assistDetect() }

    /// Job folders of earlier assist turns (a crash skipped their `defer`): removed once per launch.
    private func sweepLeftovers() {
        guard !swept else { return }
        swept = true
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: jobsDir.path) else { return }
        for name in names where name.hasPrefix(CodexAssistTurn.jobPrefix) {
            try? fm.removeItem(at: jobsDir.appendingPathComponent(name, isDirectory: true))
        }
    }
}
