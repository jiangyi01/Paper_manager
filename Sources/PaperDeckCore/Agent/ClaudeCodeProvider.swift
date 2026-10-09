import Foundation

/// Reading cards through the official Claude Code CLI on the user's
/// subscription (`claude -p`), never API keys.
///
/// Envelope parsing, the argv A/B variant switch and error-text matching all
/// live here; `AgentQueue` only sees `AgentOutcome`. Every real `-p` spawn
/// first re-checks subscription auth (`claude auth status --json`, zero quota,
/// trusted for at most `authRecheckInterval`) and then passes `spawnGate`
/// (agent.mode / RunBudget), including the one-off variant-B retry, so no code
/// path can spend quota — or bill an API key — behind the gate's back.
package actor ClaudeCodeProvider: AgentProvider {
    /// A = `--tools ""` (default). B = `--disallowedTools …`, used if A turns out
    /// to hide the StructuredOutput tool (success with null structured_output).
    package enum ArgvVariant: String, Sendable, CaseIterable {
        case a = "A", b = "B"
    }

    /// Which optional flags this CLI version understands (parsed once per version from `--help`).
    package struct Capabilities: Sendable, Equatable {
        package var flags: Set<String>

        package static let required = [
            "--print", "--output-format", "--json-schema", "--tools", "--strict-mcp-config",
            "--disable-slash-commands", "--no-session-persistence", "--permission-mode", "--system-prompt", "--model",
        ]
        package static let optional = [
            "--safe-mode", "--permission-prompts", "--effort", "--fallback-model", "--disallowedTools",
        ]
        /// Everything present — for dry runs before any detection.
        package static let assumed = Capabilities(flags: Set(required + optional))
        /// `--help` unreadable: keep the core flags, drop anything optional.
        package static let minimal = Capabilities(flags: Set(required))

        package init(flags: Set<String>) { self.flags = flags }

        package func has(_ flag: String) -> Bool { flags.contains(flag) }
        package var missingRequired: [String] { Self.required.filter { !flags.contains($0) } }

        /// Option definitions are the lines indented by exactly two spaces:
        /// `  -p, --print   …`, `  --allowedTools, --allowed-tools <tools...>`.
        package static func parse(help: String) -> Capabilities {
            var flags = Set<String>()
            for line in help.split(whereSeparator: \.isNewline) {
                guard line.hasPrefix("  -") else { continue }
                let spec = line.dropFirst(2).components(separatedBy: "  ").first ?? ""
                for part in spec.components(separatedBy: ", ") {
                    guard let token = part.split(separator: " ").first, token.hasPrefix("--") else { continue }
                    flags.insert(String(token))
                }
            }
            return Capabilities(flags: flags)
        }
    }

    /// What a spawn would look like — for `--agent-argv`, WOULD RUN logs and the spawn gate.
    package struct DryRun: Sendable, Equatable {
        package var argv: [String]
        package var cwd: String
        package var environmentKeys: [String]
        package var stdinBytes: Int
        package var variant: ArgvVariant

        /// Human-readable, with long values (system prompt, schema) elided. Env values never appear.
        package var summary: String {
            let args = argv.map { $0.count > 160 ? "<\($0.count) chars>" : Self.shellQuote($0) }
            return """
            argv: \(args.joined(separator: " "))
            cwd: \(cwd)
            env keys: \(environmentKeys.joined(separator: " "))
            stdin: \(stdinBytes) bytes
            variant: \(variant.rawValue)
            """
        }

        private static func shellQuote(_ s: String) -> String {
            if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:,@+".contains($0) }) { return s }
            return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    package typealias Runner = @Sendable (ProcessRunner.Request) async throws -> ProcessRunner.Result
    /// Called before every real `-p` spawn; `false` means "do not spawn".
    package typealias SpawnGate = @Sendable (DryRun) async -> Bool

    package static let disallowedTools = "Bash,Edit,Write,NotebookEdit,Read,Glob,Grep,WebFetch,WebSearch,Task"
    /// The CLI's piped-stdin ceiling.
    package static let cliStdinLimit = 10 * 1024 * 1024

    package nonisolated let id = "claude"

    private let locator: BinaryLocator
    private let agentCwd: URL
    private let maxTurns: Int
    private let fallbackModel: String?
    private let runner: Runner
    private let parentEnvironment: @Sendable () -> [String: String]
    private let spawnGate: SpawnGate?
    private let now: @Sendable () -> Date
    private var variant: ArgvVariant = .a
    private var variantCLIVersion: String?
    private var capabilitiesByVersion: [String: Capabilities] = [:]
    /// Last `auth status` that confirmed claude.ai auth, per binary path (injected clock).
    private var authVerified: (path: String, at: Date)?
    /// Why the latest `generateCard` refused to spawn (nil when it did not refuse).
    package private(set) var lastAuthRefusal: ProviderStatus?

    /// A confirmed subscription login is trusted for at most this long before a spawn.
    package static let authRecheckInterval: TimeInterval = 60

    /// - Parameters:
    ///   - agentCwd: fixed, empty, shared working directory (`AppPaths.agentCwd`), so
    ///     `~/.claude.json` gains one project entry in total, not one per paper.
    ///   - runner: injectable for tests — never let tests spawn a real `claude -p`.
    package init(locator: BinaryLocator = BinaryLocator(), agentCwd: URL, maxTurns: Int = 5,
                 fallbackModel: String? = "haiku",
                 runner: @escaping Runner = { try await ProcessRunner().run($0) },
                 parentEnvironment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
                 spawnGate: SpawnGate? = nil,
                 now: @escaping @Sendable () -> Date = { Date() }) {
        self.locator = locator; self.agentCwd = agentCwd; self.maxTurns = maxTurns
        self.fallbackModel = fallbackModel; self.runner = runner; self.parentEnvironment = parentEnvironment
        self.spawnGate = spawnGate; self.now = now
    }

    // MARK: - Variant preference (persisted by the caller)

    /// Restores the variant learned earlier (UserDefaults `agent.claude.argvVariant`
    /// + `…argvVariantCLIVersion`). It only applies while the CLI version matches.
    package func setPreferredVariant(_ v: ArgvVariant, cliVersion: String?) {
        variant = v
        variantCLIVersion = cliVersion
    }

    /// What to persist after a success reported `RunMeta.variant == "B"`.
    package var learnedVariant: (variant: ArgvVariant, cliVersion: String?) { (variant, variantCLIVersion) }

    package func preferredVariant(for cliVersion: String?) -> ArgvVariant {
        guard variant == .b else { return .a }
        if let pinned = variantCLIVersion, let cliVersion, pinned != cliVersion { return .a }
        return .b
    }

    // MARK: - Detection (no quota)

    package func detect() async -> ProviderStatus {
        guard let bin = await locator.locate(revalidate: true) else { return .notInstalled }
        let cwd: String
        do { cwd = try ensureAgentCwd() } catch {
            Log.agent.error("cannot create \(self.agentCwd.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .unsupported(ProviderReason.agentCwdUnavailable.code)
        }
        let plan: String?
        switch await checkAuth(bin, cwd: cwd) {
        case .subscription(let p): plan = p
        case .refused(let status): return status
        case .cancelled: return .unsupported(ProviderReason.timeout.code)
        case .launchFailed:
            await locator.invalidate()
            return .notInstalled
        }

        let caps = await capabilities(for: bin)
        guard caps.missingRequired.isEmpty else {
            Log.agent.error("Claude Code \(bin.version, privacy: .public) lacks \(caps.missingRequired.joined(separator: ", "), privacy: .public)")
            return .unsupported(ProviderReason.missingFlags(caps.missingRequired).code)
        }
        return .ready(plan: plan, version: bin.version, path: bin.path)
    }

    private enum AuthCheck {
        case subscription(plan: String?)
        case refused(ProviderStatus)
        case launchFailed(String)
        case cancelled
    }

    /// `claude auth status --json` (no quota): §3.1 requires `loggedIn && authMethod == "claude.ai"`.
    /// Anything else — logged out, API key / apiKeyHelper / Console login, no answer — refuses.
    private func checkAuth(_ bin: BinaryLocator.Binary, cwd: String) async -> AuthCheck {
        let auth: ProcessRunner.Result
        do {
            auth = try await runner(.init(executable: bin.path, arguments: ["auth", "status", "--json"],
                                          environment: environment(for: bin), currentDirectory: cwd,
                                          stdin: nil, timeout: .seconds(20)))
        } catch is CancellationError {
            return .cancelled
        } catch {
            authVerified = nil
            return .launchFailed(String(describing: error))
        }
        if auth.cancelled { return .cancelled }
        authVerified = nil
        if auth.timedOut { return .refused(.unsupported(ProviderReason.timeout.code)) }
        let status = Self.authStatus(auth.stdout)
        guard auth.exitCode == 0, status?.loggedIn == true else {
            return .refused(.notLoggedIn(ProviderReason.loggedOut.code))
        }
        guard status?.authMethod == "claude.ai" else {
            let method = status?.authMethod.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            return .refused(.notLoggedIn(ProviderReason.nonSubscription(method: method).code))
        }
        authVerified = (bin.path, now())
        return .subscription(plan: status?.subscriptionType)
    }

    /// A subscription login confirmed less than `authRecheckInterval` ago for this binary.
    private func authIsFresh(for bin: BinaryLocator.Binary) -> Bool {
        guard let v = authVerified, v.path == bin.path else { return false }
        let age = now().timeIntervalSince(v.at)
        return age >= 0 && age < Self.authRecheckInterval
    }

    private struct AuthStatus {
        var loggedIn: Bool?
        var authMethod: String?
        var subscriptionType: String?
    }

    private static func authStatus(_ stdout: Data) -> AuthStatus? {
        var value = try? JSONDecoder().decode(JSONValue.self, from: stdout)
        if value?.objectValue == nil {
            let last = String(decoding: stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
                .last { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
            value = last.flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        }
        guard let o = value?.objectValue else { return nil }
        return AuthStatus(loggedIn: o["loggedIn"]?.boolValue, authMethod: o["authMethod"]?.stringValue,
                          subscriptionType: o["subscriptionType"]?.stringValue)
    }

    private func capabilities(for bin: BinaryLocator.Binary) async -> Capabilities {
        if let c = capabilitiesByVersion[bin.version] { return c }
        guard let cwd = try? ensureAgentCwd(),
              let r = try? await runner(.init(executable: bin.path, arguments: ["--help"],
                                              environment: environment(for: bin), currentDirectory: cwd,
                                              stdin: nil, timeout: .seconds(20))),
              r.exitCode == 0, !r.timedOut else {
            Log.agent.error("claude --help failed; using the minimal flag set")
            return .minimal
        }
        let caps = Capabilities.parse(help: String(decoding: r.stdout, as: UTF8.self))
        guard !caps.flags.isEmpty else { return .minimal }
        capabilitiesByVersion[bin.version] = caps
        return caps
    }

    // MARK: - argv

    /// The exact command line. The prompt is argv[2], directly after `-p`, so
    /// the variadic `--tools` / `--disallowedTools` can never swallow it.
    package static func argv(binary: String, request r: CardRequest, variant: ArgvVariant,
                             capabilities caps: Capabilities = .assumed, maxTurns: Int = 5,
                             fallbackModel: String? = "haiku") -> [String] {
        var a = [binary, "-p", prompt(r.userPrompt),
                 "--output-format", "json", "--json-schema", schemaArgument(r.schema)]
        switch variant {
        case .a: a += ["--tools", ""]
        case .b: a += ["--disallowedTools", disallowedTools]
        }
        a.append("--strict-mcp-config")
        if caps.has("--safe-mode") { a.append("--safe-mode") }
        a += ["--disable-slash-commands", "--no-session-persistence", "--permission-mode", "dontAsk"]
        if caps.has("--permission-prompts") { a += ["--permission-prompts", "none"] }
        a += ["--system-prompt", r.systemPrompt, "--model", r.model]
        if caps.has("--effort") { a += ["--effort", r.effort] }
        // The CLI rejects a fallback equal to the main model (e.g. smoke runs on haiku).
        if let fb = fallbackModel, !fb.isEmpty, caps.has("--fallback-model"),
           !r.model.lowercased().contains(fb.lowercased()) {
            a += ["--fallback-model", fb]
        }
        a += ["--max-turns", String(maxTurns)]
        return a
    }

    /// The `-p` value: the request's task prompt (`CardRequest.userPrompt`). Blank falls back to
    /// the reading-card prompt; a leading "-" is prefixed so it can never be parsed as an option.
    package static func prompt(_ userPrompt: String) -> String {
        let p = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? CardSchema.userPrompt : userPrompt
        return p.hasPrefix("-") ? "Task: " + p : p
    }

    /// Compact JSON; a stray top-level "$schema" (2020-12) would make the CLI exit 1.
    package static func schemaArgument(_ schema: JSONValue) -> String {
        guard case .object(var o) = schema else { return schema.compactString() }
        o.removeValue(forKey: "$schema")
        return JSONValue.object(o).compactString()
    }

    /// `--agent-argv`: what the next job would run, without running anything.
    package func dryRun(_ r: CardRequest) async -> DryRun {
        let bin = await locator.locate()
        let caps = if let bin { await capabilities(for: bin) } else { Capabilities.assumed }
        return makeDryRun(r, binary: bin, capabilities: caps, variant: preferredVariant(for: bin?.version))
    }

    private func makeDryRun(_ r: CardRequest, binary: BinaryLocator.Binary?, capabilities caps: Capabilities,
                            variant v: ArgvVariant) -> DryRun {
        let env = binary.map(environment(for:)) ?? ChildEnvironment.make(binaryDir: "", parent: parentEnvironment())
        return DryRun(argv: Self.argv(binary: binary?.path ?? "claude", request: r, variant: v, capabilities: caps,
                                      maxTurns: maxTurns, fallbackModel: fallbackModel),
                      cwd: agentCwd.path, environmentKeys: env.keys.sorted(), stdinBytes: r.stdin.count, variant: v)
    }

    // MARK: - Generation

    package func generateCard(_ r: CardRequest, jobDir: URL) async -> AgentOutcome {
        lastAuthRefusal = nil
        if Task.isCancelled { return .cancelled }
        guard r.stdin.count <= Self.cliStdinLimit else {
            return .generic("stdin is \(r.stdin.count) bytes; the CLI accepts at most \(Self.cliStdinLimit)")
        }
        guard let located = await locator.locate() else { return .binaryMissing }
        let cwd: String
        do {
            cwd = try ensureAgentCwd()
            try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        } catch {
            return .generic("cannot create job directories: \(error.localizedDescription)")
        }

        var bin = located
        let first = preferredVariant(for: bin.version)
        let attempt = await spawn(r, binary: &bin, variant: first, cwd: cwd, jobDir: jobDir, isRetry: false)

        guard first == .a, case .finished(let res, let env, _) = attempt, !res.cancelled, !res.timedOut,
              env?.isSuccessWithoutStructuredOutput == true, !Task.isCancelled,
              await capabilities(for: bin).has("--disallowedTools") else {
            return await outcome(attempt, request: r, variant: first)
        }
        Log.agent.notice("variant A returned null structured_output; retrying once with variant B")
        let retry = await spawn(r, binary: &bin, variant: .b, cwd: cwd, jobDir: jobDir, isRetry: true)
        if case .denied = retry {
            // The gate (budget / agent.mode) said no: report A's result and let the queue decide.
            return await outcome(attempt, request: r, variant: first)
        }
        if case .finished(_, let env2, _) = retry, env2?.isSuccess == true {
            variant = .b
            variantCLIVersion = bin.version
        }
        return await outcome(retry, request: r, variant: .b)
    }

    private enum Attempt {
        case finished(ProcessRunner.Result, ClaudeEnvelope?, ClaudeEnvelope.Classification)
        case launchFailed(String)
        case denied
        /// `claude auth status` no longer reports the subscription (reason in `lastAuthRefusal`).
        case authRefused
        case cancelled
    }

    /// One gated spawn: auth re-check (cached ≤ 60 s) → spawn gate → `-p`. A launch failure
    /// re-resolves the binary once (the updater may have moved it) before giving up.
    private func spawn(_ r: CardRequest, binary bin: inout BinaryLocator.Binary, variant v: ArgvVariant,
                       cwd: String, jobDir: URL, isRetry: Bool) async -> Attempt {
        var relocated = false
        while true {
            if !authIsFresh(for: bin) {
                switch await checkAuth(bin, cwd: cwd) {
                case .subscription:
                    break
                case .refused(let status):
                    lastAuthRefusal = status
                    Log.agent.notice("no spawn: \(status.reasonText(.en), privacy: .public)")
                    return .authRefused
                case .cancelled:
                    return .cancelled
                case .launchFailed(let message):
                    await locator.invalidate()
                    guard !relocated, let fresh = await locator.locate() else { return .launchFailed(message) }
                    relocated = true
                    bin = fresh
                    continue
                }
            }
            let caps = await capabilities(for: bin)
            let plan = makeDryRun(r, binary: bin, capabilities: caps, variant: v)
            if let gate = spawnGate, await gate(plan) == false {
                Log.agent.notice("spawn gate refused: \(plan.summary, privacy: .public)")
                return .denied
            }
            do {
                let res = try await runner(.init(executable: bin.path, arguments: Array(plan.argv.dropFirst()),
                                                 environment: environment(for: bin), currentDirectory: cwd,
                                                 stdin: r.stdin, timeout: r.timeout))
                await persist(res, jobDir: jobDir, isRetry: isRetry)
                let env = ClaudeEnvelope.parse(res.stdout)
                let cost = env?.totalCostUSD.map { String(format: "%.4f", $0) } ?? "?"
                let subtype = env?.subtype ?? "-"
                Log.agent.info("""
                    claude -p variant \(v.rawValue, privacy: .public): exit \(res.exitCode) \
                    subtype \(subtype, privacy: .public) \(res.durationMs) ms cost $\(cost, privacy: .public) \
                    stdin \(r.stdin.count) B timedOut \(res.timedOut)
                    """)
                let cls = ClaudeEnvelope.classify(exitCode: res.exitCode, envelope: env, stdout: res.stdout,
                                                  stderr: res.stderr, now: now())
                return .finished(res, env, cls)
            } catch is CancellationError {
                return .cancelled
            } catch {
                await locator.invalidate()
                guard !relocated, let fresh = await locator.locate() else {
                    return .launchFailed(String(describing: error))
                }
                relocated = true
                bin = fresh
            }
        }
    }

    private func outcome(_ attempt: Attempt, request r: CardRequest, variant v: ArgvVariant) async -> AgentOutcome {
        switch attempt {
        case .denied, .cancelled:
            return .cancelled
        case .authRefused:
            return .notLoggedIn
        case .launchFailed(let message):
            Log.agent.error("claude could not be launched: \(message, privacy: .public)")
            return .binaryMissing
        case .finished(let res, let env, let cls):
            if res.cancelled { return .cancelled }
            if res.timedOut { return .timeout }
            switch cls {
            case .success(let card):
                guard card.objectValue != nil || card.stringValue != nil else {
                    return .invalidOutput("structured_output is not an object")
                }
                return .success(card: card, meta: RunMeta(
                    model: env?.model ?? r.model, durationMs: env?.durationMs ?? res.durationMs,
                    costUSD: env?.totalCostUSD, inputTokens: env?.inputTokens, outputTokens: env?.outputTokens,
                    numTurns: env?.numTurns, variant: v.rawValue))
            case .usageLimit(let resetsAt): return .usageLimit(resetsAt: resetsAt)
            case .overloaded: return .overloaded
            case .notLoggedIn: return .notLoggedIn
            case .maxTurns: return .maxTurns
            case .invalidOutput(let message): return .invalidOutput(message)
            case .binaryMissing:
                await locator.invalidate()
                return .binaryMissing
            case .generic(let message): return .generic(message)
            }
        }
    }

    // MARK: - Helpers

    private func environment(for bin: BinaryLocator.Binary) -> [String: String] {
        ChildEnvironment.make(binaryDir: bin.directory, parent: parentEnvironment())
    }

    private func ensureAgentCwd() throws -> String {
        try FileManager.default.createDirectory(at: agentCwd, withIntermediateDirectories: true)
        return agentCwd.path
    }

    /// Raw output for post-mortems (AgentQueue deletes the job dir on success).
    /// The first attempt's files are kept under `*-A.*` when variant B retries.
    private func persist(_ res: ProcessRunner.Result, jobDir: URL, isRetry: Bool) async {
        let out = jobDir.appendingPathComponent("stdout.json")
        let err = jobDir.appendingPathComponent("stderr.txt")
        let stdout = res.stdout, stderr = res.stderr
        await BlockingIO.run {
            let fm = FileManager.default
            if isRetry {
                for (url, name) in [(out, "stdout-A.json"), (err, "stderr-A.txt")] {
                    let dest = jobDir.appendingPathComponent(name)
                    try? fm.removeItem(at: dest)
                    try? fm.moveItem(at: url, to: dest)
                }
            }
            do {
                try stdout.write(to: out, options: .atomic)
                try stderr.write(to: err, options: .atomic)
            } catch {
                Log.agent.error("cannot write job output: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Interactive assist (READING_ASSIST_PLAN §4; dive-cli §3)

extension ClaudeCodeProvider.Capabilities {
    /// What an assist session needs on top of `-p`: stream-json in and out (with `--verbose`, which
    /// the CLI demands for `-p` + stream-json output), tools off, no MCP, no persistence.
    /// `--include-partial-messages` is optional: without it the answer appears as a whole.
    package static let assistRequired = [
        "--print", "--input-format", "--output-format", "--verbose", "--tools", "--strict-mcp-config",
        "--disable-slash-commands", "--no-session-persistence", "--permission-mode", "--system-prompt", "--model",
    ]

    package var missingAssistRequired: [String] { Self.assistRequired.filter { !flags.contains($0) } }

    /// Everything an assist argv may use — for dry runs before any detection.
    package static let assistAssumed = ClaudeCodeProvider.Capabilities(flags: Set(required + optional + assistRequired
                                                               + ["--include-partial-messages"]))
}

extension ClaudeCodeProvider: AssistLauncher {
    /// `--max-turns` of an assist process: twice the lane's own 12-turn session cap (whether the
    /// CLI counts it per message or per process is unverified, so the lane enforces its own cap).
    package static let assistMaxTurns = 24

    /// One live assist process (`ClaudeAssistSession`). There is no positional prompt: with
    /// `--input-format stream-json` every turn — text, context, image — is a JSON line on stdin,
    /// never argv. `--tools ""` is followed by a flag; no `--json-schema`, no `--fallback-model`.
    package static func assistArgv(binary: String, model: String, systemPrompt: String, effort: String?,
                                   capabilities caps: Capabilities = .assistAssumed,
                                   maxTurns: Int = ClaudeCodeProvider.assistMaxTurns) -> [String] {
        var a = [binary, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        if caps.has("--include-partial-messages") { a.append("--include-partial-messages") }
        a += ["--tools", "", "--strict-mcp-config"]
        if caps.has("--safe-mode") { a.append("--safe-mode") }
        a += ["--disable-slash-commands", "--no-session-persistence", "--permission-mode", "dontAsk"]
        if caps.has("--permission-prompts") { a += ["--permission-prompts", "none"] }
        // A value starting with "-" could be read as an option.
        let system = systemPrompt.hasPrefix("-") ? "System: " + systemPrompt : systemPrompt
        let slug = model.hasPrefix("-") || model.isEmpty ? "haiku" : model
        a += ["--system-prompt", system, "--model", slug]
        if let effort, !effort.isEmpty, !effort.hasPrefix("-"), caps.has("--effort") { a += ["--effort", effort] }
        a += ["--max-turns", String(maxTurns)]
        return a
    }

    /// The zero-quota checks before an assist spawn: locate the CLI, re-check the subscription
    /// login (the card path's 60 s cache, shared), and the assist flags of this CLI version. The
    /// card path's spawn gate (`agent.mode`) is not consulted: the assist turn already passed
    /// `AssistGate` (`assist.mode`, consent ticket, pause, caps, RunBudget).
    package func assistLaunch() async -> AssistLaunchResult {
        guard var bin = await locator.locate() else { return .failed(.binaryMissing) }
        let cwd: String
        do { cwd = try ensureAgentCwd() } catch {
            return .failed(.generic(ProviderReason.agentCwdUnavailable.code))
        }
        var relocated = false
        auth: while !authIsFresh(for: bin) {
            switch await checkAuth(bin, cwd: cwd) {
            case .subscription:
                break auth
            case .refused(let status):
                Log.assist.notice("no assist spawn: \(status.reasonText(.en), privacy: .public)")
                return .failed(AssistLaunchResult.failure(for: status))
            case .cancelled:
                return .failed(.cancelled)
            case .launchFailed:
                await locator.invalidate()
                guard !relocated, let fresh = await locator.locate() else { return .failed(.binaryMissing) }
                relocated = true
                bin = fresh
            }
        }
        let caps = await capabilities(for: bin)
        let missing = caps.missingAssistRequired
        guard missing.isEmpty else {
            Log.assist.error("Claude Code \(bin.version, privacy: .public) lacks \(missing.joined(separator: ", "), privacy: .public) for assist")
            return .failed(.unsupported(missingFlags: missing))
        }
        return .ready(AssistLaunch(provider: .claude, executable: bin.path, version: bin.version,
                                   environment: environment(for: bin), cwd: cwd, flags: caps.flags))
    }

    /// Detection for the assist banner (zero quota): the card detection plus the assist flags.
    package func assistDetect() async -> AgentQueueStatus.Provider {
        let status = await detect()
        guard case .ready(let plan, let version, _) = status else { return AssistLaunchResult.provider(status) }
        if let bin = await locator.locate() {
            let missing = await capabilities(for: bin).missingAssistRequired
            if !missing.isEmpty { return .unsupported(ProviderReason.missingFlags(missing).code) }
        }
        return .ready(plan: plan, version: version)
    }
}
