import Foundation
import Synchronization
import Testing
@testable import PaperDeckCore

/// Every test drives a fake runner — no real `claude -p` is ever spawned here.
@Suite struct ClaudeCodeProviderTests {
    private static let binary = "/fake/bin/claude"

    private static func fixture(_ name: String, _ ext: String = "json") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/agent"))
        return try Data(contentsOf: url)
    }

    /// Scripted `claude`: answers auth/help from fixtures and `-p` from a queue.
    private final class FakeCLI: Sendable {
        enum Reply: Sendable {
            case result(ProcessRunner.Result)
            case launchError
        }
        struct State {
            var auth = ProcessRunner.Result(exitCode: 0)
            var help = ProcessRunner.Result(exitCode: 0)
            var printReplies: [Reply] = []
            var requests: [ProcessRunner.Request] = []
        }
        let state: Mutex<State>
        init(_ s: State) { state = Mutex(s) }

        var requests: [ProcessRunner.Request] { state.withLock { $0.requests } }
        var printRequests: [ProcessRunner.Request] { requests.filter { $0.arguments.first == "-p" } }

        var runner: ClaudeCodeProvider.Runner {
            { req in
                let reply: Reply = self.state.withLock { s in
                    s.requests.append(req)
                    switch req.arguments.first {
                    case "auth": return .result(s.auth)
                    case "--help": return .result(s.help)
                    case "-p": return s.printReplies.isEmpty ? .result(.init(exitCode: 1)) : s.printReplies.removeFirst()
                    default: return .result(.init(exitCode: 2))
                    }
                }
                switch reply {
                case .result(let r): return r
                case .launchError: throw ProcessRunner.LaunchError(path: req.executable, code: ENOENT)
                }
            }
        }
    }

    private static let poisonedParent: [String: String] = [
        "HOME": "/Users/tester", "USER": "tester", "TMPDIR": "/tmp/",
        "ANTHROPIC_API_KEY": "sk-dummy", "CLAUDECODE": "1", "CLAUDE_CODE_USE_BEDROCK": "1",
    ]

    private struct Harness {
        let provider: ClaudeCodeProvider
        let cli: FakeCLI
        let locator: BinaryLocator
        let root: URL
        var agentCwd: URL { root.appendingPathComponent("Support/agent-cwd") }
        func jobDir() -> URL { root.appendingPathComponent("Support/jobs/\(UUID().uuidString)") }
    }

    private static func result(_ name: String, ext: String = "json", exit: Int32 = 0, stderr: String = "") throws
        -> FakeCLI.Reply {
        .result(.init(exitCode: exit, stdout: try fixture(name, ext), stderr: Data(stderr.utf8), durationMs: 900))
    }

    private static func harness(auth: String = "auth-status", authExit: Int32 = 0, help: String? = nil,
                                replies: [FakeCLI.Reply] = [], binaryPresent: Bool = true,
                                gate: ClaudeCodeProvider.SpawnGate? = nil) throws -> Harness {
        var s = FakeCLI.State()
        s.auth = .init(exitCode: authExit, stdout: try fixture(auth))
        s.help = .init(exitCode: 0, stdout: try help.map { Data($0.utf8) } ?? fixture("claude-help-2.1.284", "txt"))
        s.printReplies = replies
        let cli = FakeCLI(s)
        let probe = BinaryLocator.Probe(
            isExecutable: { binaryPresent && $0 == binary },
            versionOutput: { _ in "2.1.284 (Claude Code)\n" },
            loginShellLookup: { nil },
            listDirectory: { _ in [] })
        let locator = BinaryLocator(home: "/nonexistent-home", override: binary, probe: probe)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-provider-\(UUID().uuidString)")
        let now = nowLA
        let provider = ClaudeCodeProvider(
            locator: locator, agentCwd: root.appendingPathComponent("Support/agent-cwd"), runner: cli.runner,
            parentEnvironment: { poisonedParent }, spawnGate: gate, now: { now })
        return Harness(provider: provider, cli: cli, locator: locator, root: root)
    }

    private static let nowLA: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 10))!
    }()

    private static func request() -> CardRequest {
        CardRequest(schema: CardSchema.schema(categories: PaperCategory.starters.map(\.name)),
                    stdin: CardSchema.stdin(metadata: nil, pageCount: 3, categories: [], frequentTags: [],
                                            paperText: "[[p. 1]]\nA paper"),
                    model: "sonnet", effort: "medium", timeout: .seconds(360))
    }

    // MARK: detect

    @Test func detectReadyWithSubscriptionPlan() async throws {
        let h = try Self.harness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        #expect(await h.provider.detect() == .ready(plan: "max", version: "2.1.284", path: Self.binary))
        let auth = try #require(h.cli.requests.first { $0.arguments.first == "auth" })
        #expect(auth.arguments == ["auth", "status", "--json"])
        #expect(Set(auth.environment.keys) == ChildEnvironment.keys)
        #expect(auth.environment["PATH"]?.hasPrefix("/fake/bin:") == true)
        #expect(auth.stdin == nil)
        #expect(h.cli.printRequests.isEmpty)
        // --help is parsed once per CLI version.
        _ = await h.provider.detect()
        #expect(h.cli.requests.filter { $0.arguments.first == "--help" }.count == 1)
    }

    @Test func detectRejectsNonSubscriptionAuth() async throws {
        let h = try Self.harness(auth: "auth-status-api-key")
        defer { try? FileManager.default.removeItem(at: h.root) }
        let status = await h.provider.detect()
        guard case .notLoggedIn(let code) = status else { Issue.record("expected notLoggedIn"); return }
        #expect(code == "non_subscription:api_key")                     // a stable reason code, not prose
        #expect(status.reason == .nonSubscription(method: "api_key"))
        #expect(status.reasonText(.zh) == "PaperDeck 只使用订阅登录（当前：api_key）")
        #expect(status.reasonText(.en).contains("only uses subscription login"))
    }

    @Test func detectLoggedOut() async throws {
        let h = try Self.harness(auth: "auth-status-logged-out", authExit: 1)
        defer { try? FileManager.default.removeItem(at: h.root) }
        let status = await h.provider.detect()
        guard case .notLoggedIn(let code) = status else { Issue.record("expected notLoggedIn"); return }
        #expect(code == "logged_out")
        #expect(status.reasonText(.zh) == "需登录 Claude")
    }

    @Test func detectNotInstalled() async throws {
        let h = try Self.harness(binaryPresent: false)
        defer { try? FileManager.default.removeItem(at: h.root) }
        #expect(await h.provider.detect() == .notInstalled)
        #expect(h.cli.requests.isEmpty)
    }

    @Test func detectUnsupportedWhenRequiredFlagsAreMissing() async throws {
        let h = try Self.harness(help: "Options:\n  -p, --print  Print\n  --model <m>  Model\n")
        defer { try? FileManager.default.removeItem(at: h.root) }
        let status = await h.provider.detect()
        guard case .unsupported(let code) = status else { Issue.record("expected unsupported"); return }
        #expect(code.hasPrefix("missing_flags:") && code.contains("--json-schema"))
        guard case .missingFlags(let flags) = status.reason else { Issue.record("expected missingFlags"); return }
        #expect(flags.contains("--json-schema") && flags.contains("--tools"))
    }

    // MARK: generateCard

    @Test func successMapsMetaAndPersistsOutput() async throws {
        let h = try Self.harness(replies: [try Self.result("envelope-success")])
        defer { try? FileManager.default.removeItem(at: h.root) }
        let job = h.jobDir()
        let r = Self.request()
        guard case .success(let card, let meta) = await h.provider.generateCard(r, jobDir: job) else {
            Issue.record("expected success"); return
        }
        #expect(card["category"] == .string("AI Agents for Science"))
        #expect(meta == RunMeta(model: "claude-sonnet-4-6", durationMs: 41233, costUSD: 0.185031, inputTokens: 41888,
                                outputTokens: 1834, numTurns: 2, variant: "A"))

        let spawn = try #require(h.cli.printRequests.first)
        #expect(spawn.executable == Self.binary)
        #expect(spawn.arguments[0] == "-p")
        #expect(spawn.arguments[1] == CardSchema.userPrompt)
        #expect(spawn.arguments == Array(ClaudeCodeProvider.argv(binary: Self.binary, request: r, variant: .a).dropFirst()))
        #expect(spawn.currentDirectory == h.agentCwd.path)
        #expect(spawn.stdin == r.stdin)
        #expect(spawn.timeout == .seconds(360))
        #expect(Set(spawn.environment.keys) == ChildEnvironment.keys)
        #expect(!spawn.environment.values.contains { $0.contains("sk-dummy") })

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: h.agentCwd.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(try Data(contentsOf: job.appendingPathComponent("stdout.json")) == (try Self.fixture("envelope-success")))
        #expect(FileManager.default.fileExists(atPath: job.appendingPathComponent("stderr.txt").path))
    }

    @Test func nullStructuredOutputUnderVariantASwitchesToBOnce() async throws {
        let h = try Self.harness(replies: [try Self.result("envelope-success-null-structured"),
                                           try Self.result("envelope-success")])
        defer { try? FileManager.default.removeItem(at: h.root) }
        let job = h.jobDir()
        guard case .success(_, let meta) = await h.provider.generateCard(Self.request(), jobDir: job) else {
            Issue.record("expected success after B retry"); return
        }
        #expect(meta.variant == "B")
        let spawns = h.cli.printRequests
        try #require(spawns.count == 2)                 // no index past a failed expectation (QA-15)
        #expect(spawns[0].arguments.contains("--tools"))
        #expect(!spawns[0].arguments.contains("--disallowedTools"))
        #expect(spawns[1].arguments.contains("--disallowedTools"))
        #expect(!spawns[1].arguments.contains("--tools"))
        try #require(spawns[1].arguments.count > 1)
        #expect(spawns[1].arguments[1] == CardSchema.userPrompt)
        #expect(await h.provider.preferredVariant(for: "2.1.284") == .b)
        let learned = await h.provider.learnedVariant
        #expect(learned.variant == .b && learned.cliVersion == "2.1.284")
        #expect(FileManager.default.fileExists(atPath: job.appendingPathComponent("stdout-A.json").path))
        #expect(try Data(contentsOf: job.appendingPathComponent("stdout.json")) == (try Self.fixture("envelope-success")))
    }

    @Test func learnedVariantBIsUsedFirstNextTime() async throws {
        let h = try Self.harness(replies: [try Self.result("envelope-success")])
        defer { try? FileManager.default.removeItem(at: h.root) }
        await h.provider.setPreferredVariant(.b, cliVersion: "2.1.284")
        guard case .success(_, let meta) = await h.provider.generateCard(Self.request(), jobDir: h.jobDir()) else {
            Issue.record("expected success"); return
        }
        #expect(meta.variant == "B")
        #expect(h.cli.printRequests.count == 1)
        #expect(h.cli.printRequests[0].arguments.contains("--disallowedTools"))
    }

    @Test func storedVariantIsIgnoredForAnotherCLIVersion() async throws {
        let h = try Self.harness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        await h.provider.setPreferredVariant(.b, cliVersion: "2.1.100")
        #expect(await h.provider.preferredVariant(for: "2.1.284") == .a)
        #expect(await h.provider.preferredVariant(for: "2.1.100") == .b)
    }

    @Test func variantBFailureKeepsA() async throws {
        let h = try Self.harness(replies: [try Self.result("envelope-success-null-structured"),
                                           try Self.result("envelope-success-null-structured")])
        defer { try? FileManager.default.removeItem(at: h.root) }
        guard case .invalidOutput = await h.provider.generateCard(Self.request(), jobDir: h.jobDir()) else {
            Issue.record("expected invalidOutput"); return
        }
        #expect(h.cli.printRequests.count == 2)
        #expect(await h.provider.preferredVariant(for: "2.1.284") == .a)
    }

    @Test func retriesExhaustedDoesNotSwitchVariant() async throws {
        let h = try Self.harness(replies: [try Self.result("envelope-max-structured-retries", exit: 1)])
        defer { try? FileManager.default.removeItem(at: h.root) }
        guard case .invalidOutput = await h.provider.generateCard(Self.request(), jobDir: h.jobDir()) else {
            Issue.record("expected invalidOutput"); return
        }
        #expect(h.cli.printRequests.count == 1)
    }

    @Test func gateCanRefuseTheBRetry() async throws {
        let seen = Mutex<[ClaudeCodeProvider.DryRun]>([])
        let gate: ClaudeCodeProvider.SpawnGate = { plan in
            seen.withLock { $0.append(plan); return $0.count == 1 }
        }
        let h = try Self.harness(replies: [try Self.result("envelope-success-null-structured"),
                                           try Self.result("envelope-success")], gate: gate)
        defer { try? FileManager.default.removeItem(at: h.root) }
        guard case .invalidOutput = await h.provider.generateCard(Self.request(), jobDir: h.jobDir()) else {
            Issue.record("expected A's invalidOutput"); return
        }
        #expect(h.cli.printRequests.count == 1)
        #expect(seen.withLock { $0.map(\.variant) } == [.a, .b])
    }

    @Test func gateRefusingTheFirstSpawnMeansNoSpawn() async throws {
        let h = try Self.harness(replies: [try Self.result("envelope-success")], gate: { _ in false })
        defer { try? FileManager.default.removeItem(at: h.root) }
        #expect(await h.provider.generateCard(Self.request(), jobDir: h.jobDir()) == .cancelled)
        #expect(h.cli.printRequests.isEmpty)
    }

    @Test func classificationMapping() async throws {
        let cal: Calendar = {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = .current
            return c
        }()
        let cases: [(FakeCLI.Reply, AgentOutcome)] = [
            (try Self.result("envelope-429-session", exit: 1),
             .usageLimit(resetsAt: cal.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 15, minute: 45)))),
            (try Self.result("envelope-weekly-limit", exit: 1),
             .usageLimit(resetsAt: cal.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 9)))),
            (try Self.result("envelope-legacy-limit", exit: 1), .usageLimit(resetsAt: Date(timeIntervalSince1970: 1759244400))),
            (try Self.result("envelope-529", exit: 1), .overloaded),
            (try Self.result("envelope-not-logged-in", exit: 1), .notLoggedIn),
            (try Self.result("envelope-max-turns", exit: 1), .maxTurns),
            (.result(.init(exitCode: 127, stderr: Data("not found".utf8))), .binaryMissing),
            (.result(.init(exitCode: 130, signal: SIGINT, timedOut: true)), .timeout),
            (.result(.init(exitCode: 130, signal: SIGINT, cancelled: true)), .cancelled),
            (.result(.init(exitCode: 1, stdout: Data("boom".utf8))), .generic("exit 1: boom")),
        ]
        for (reply, expected) in cases {
            let h = try Self.harness(replies: [reply])
            defer { try? FileManager.default.removeItem(at: h.root) }
            let outcome = await h.provider.generateCard(Self.request(), jobDir: h.jobDir())
            #expect(outcome == expected)
        }
    }

    @Test func launchFailureReresolvesOnceThenReportsBinaryMissing() async throws {
        let h = try Self.harness(replies: [.launchError, .launchError])
        defer { try? FileManager.default.removeItem(at: h.root) }
        #expect(await h.provider.generateCard(Self.request(), jobDir: h.jobDir()) == .binaryMissing)
        #expect(h.cli.printRequests.count == 2)
    }

    @Test func launchFailureRecoversAfterReresolve() async throws {
        let h = try Self.harness(replies: [.launchError, try Self.result("envelope-success")])
        defer { try? FileManager.default.removeItem(at: h.root) }
        guard case .success = await h.provider.generateCard(Self.request(), jobDir: h.jobDir()) else {
            Issue.record("expected success after re-resolve"); return
        }
    }

    @Test func missingBinaryNeverSpawns() async throws {
        let h = try Self.harness(binaryPresent: false)
        defer { try? FileManager.default.removeItem(at: h.root) }
        #expect(await h.provider.generateCard(Self.request(), jobDir: h.jobDir()) == .binaryMissing)
        #expect(h.cli.requests.isEmpty)
    }

    @Test func oversizedStdinIsRefused() async throws {
        let h = try Self.harness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let big = CardRequest(schema: .object([:]), stdin: Data(count: ClaudeCodeProvider.cliStdinLimit + 1))
        guard case .generic = await h.provider.generateCard(big, jobDir: h.jobDir()) else {
            Issue.record("expected generic"); return
        }
        #expect(h.cli.printRequests.isEmpty)
    }

    @Test func helpWithoutOptionalFlagsDropsThemFromArgv() async throws {
        let help = try String(decoding: Self.fixture("claude-help-2.1.284", "txt"), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("  --safe-mode") && !$0.hasPrefix("  --permission-prompts") }
            .joined(separator: "\n")
        let h = try Self.harness(help: help, replies: [try Self.result("envelope-success")])
        defer { try? FileManager.default.removeItem(at: h.root) }
        _ = await h.provider.generateCard(Self.request(), jobDir: h.jobDir())
        let args = try #require(h.cli.printRequests.first).arguments
        #expect(!args.contains("--safe-mode"))
        #expect(!args.contains("--permission-prompts"))
        #expect(args.contains("--strict-mcp-config"))
    }

    @Test func dryRunDescribesWithoutSpawning() async throws {
        let h = try Self.harness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let r = Self.request()
        let plan = await h.provider.dryRun(r)
        #expect(plan.argv[0] == Self.binary)
        #expect(plan.argv[2] == CardSchema.userPrompt)
        #expect(plan.cwd == h.agentCwd.path)
        #expect(plan.cwd.hasSuffix("/agent-cwd"))
        #expect(Set(plan.environmentKeys) == ChildEnvironment.keys)
        #expect(plan.stdinBytes == r.stdin.count)
        #expect(plan.variant == .a)
        let summary = plan.summary
        #expect(summary.contains("--tools ''"))
        #expect(summary.contains("stdin: \(r.stdin.count) bytes"))
        #expect(summary.range(of: "ANTHROPIC|CLAUDECODE|sk-dummy", options: .regularExpression) == nil)
        #expect(h.cli.printRequests.isEmpty)
    }
}
