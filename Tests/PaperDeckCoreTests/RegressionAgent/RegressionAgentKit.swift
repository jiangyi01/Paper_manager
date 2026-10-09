import Foundation
import Synchronization
import Testing
@testable import PaperDeckCore

// Shared fixtures of the RegressionAgent suites (agent / schedule / reminder / sidecar fixes).
// Nothing here ever spawns a real `claude`: providers are scripted, and ClaudeCodeProvider
// only ever sees `RAFakeCLI.runner`.

/// Tuesday 2026-09-29 10:00 America/Chicago.
let raChicago = LocalDate.gregorian(TimeZone(identifier: "America/Chicago")!)
let raStart = raChicago.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 10))!

/// Lock-protected mutable value read by engine closures.
final class RABox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func update(_ f: (inout T) -> Void) { lock.withLock { f(&stored) } }
}

final class RARecorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ x: T) { lock.withLock { items.append(x) } }
    var all: [T] { lock.withLock { items } }
}

/// Polls `condition` every 10 ms for up to `timeout`.
func raEventually(_ timeout: Duration = .seconds(5), _ condition: () async throws -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if (try? await condition()) == true { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return (try? await condition()) == true
}

extension AgentQueue.Tuning {
    static let raFast = AgentQueue.Tuning(jobTimeout: .milliseconds(500), testTimeout: .milliseconds(500),
                                          maxNap: .milliseconds(20), idleNap: .milliseconds(50),
                                          loginRecheck: .seconds(30), shutdownWait: .seconds(1),
                                          detectThrottle: .zero)
}

/// Scripted provider: one outcome per `generateCard` (fallback afterwards), `detect()` answers `status`.
actor RAScriptedProvider: AgentProvider {
    nonisolated let id: String
    private var script: [AgentOutcome]
    private let fallback: AgentOutcome?
    private var status: ProviderStatus
    private(set) var generateCalls = 0
    private(set) var detectCalls = 0
    private(set) var requests: [CardRequest] = []

    init(id: String = "claude", script: [AgentOutcome] = [], fallback: AgentOutcome? = nil,
         status: ProviderStatus = .ready(plan: "max", version: "9.9.9", path: "/fake/claude")) {
        self.id = id; self.script = script; self.fallback = fallback; self.status = status
    }

    func push(_ outcomes: AgentOutcome...) { script += outcomes }
    func setStatus(_ s: ProviderStatus) { status = s }
    func detect() async -> ProviderStatus {
        detectCalls += 1
        return status
    }

    func generateCard(_ r: CardRequest, jobDir: URL) async -> AgentOutcome {
        generateCalls += 1
        requests.append(r)
        if !script.isEmpty { return script.removeFirst() }
        if let fallback { return fallback }
        return .success(card: MockAgentProvider.card(for: r), meta: RunMeta(
            model: "claude-test", durationMs: 10, costUSD: 0, inputTokens: 1, outputTokens: 1, numTurns: 1,
            variant: nil))
    }
}

/// Scripted `claude` binary for ClaudeCodeProvider: `auth status` / `--help` from fixtures (switchable),
/// `-p` from a reply queue. Every request is recorded.
final class RAFakeCLI: Sendable {
    struct State {
        var auth = ProcessRunner.Result(exitCode: 0)
        var help = ProcessRunner.Result(exitCode: 0)
        var printReplies: [ProcessRunner.Result] = []
        var requests: [ProcessRunner.Request] = []
    }
    let state: Mutex<State>

    static let binary = "/fake/bin/claude"

    static func fixture(_ name: String, _ ext: String = "json") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/agent"))
        return try Data(contentsOf: url)
    }

    init(auth: String = "auth-status", authExit: Int32 = 0, replies: [String] = []) throws {
        var s = State()
        s.auth = .init(exitCode: authExit, stdout: try Self.fixture(auth))
        s.help = .init(exitCode: 0, stdout: try Self.fixture("claude-help-2.1.284", "txt"))
        s.printReplies = try replies.map { .init(exitCode: 0, stdout: try Self.fixture($0), durationMs: 900) }
        state = Mutex(s)
    }

    func setAuth(_ name: String, exit: Int32 = 0) throws {
        let data = try Self.fixture(name)
        state.withLock { $0.auth = .init(exitCode: exit, stdout: data) }
    }

    func setAuthResult(_ r: ProcessRunner.Result) { state.withLock { $0.auth = r } }

    func pushSuccess(_ n: Int = 1) throws {
        let data = try Self.fixture("envelope-success")
        state.withLock { for _ in 0..<n { $0.printReplies.append(.init(exitCode: 0, stdout: data, durationMs: 900)) } }
    }

    var requests: [ProcessRunner.Request] { state.withLock { $0.requests } }
    var printRequests: [ProcessRunner.Request] { requests.filter { $0.arguments.first == "-p" } }
    var authRequests: [ProcessRunner.Request] { requests.filter { $0.arguments.first == "auth" } }

    var runner: ClaudeCodeProvider.Runner {
        { req in
            self.state.withLock { s in
                s.requests.append(req)
                switch req.arguments.first {
                case "auth": return s.auth
                case "--help": return s.help
                case "-p": return s.printReplies.isEmpty ? .init(exitCode: 1) : s.printReplies.removeFirst()
                default: return .init(exitCode: 2)
                }
            }
        }
    }

    static func locator() -> BinaryLocator {
        let probe = BinaryLocator.Probe(
            isExecutable: { $0 == binary },
            versionOutput: { _ in "2.1.284 (Claude Code)\n" },
            loginShellLookup: { nil },
            listDirectory: { _ in [] })
        return BinaryLocator(home: "/nonexistent-home", override: binary, probe: probe)
    }
}

/// A temp-rooted engine whose agent queue runs with fast timings.
struct RAQueueHarness {
    let root: URL
    let engine: Engine
    let clock: RABox<Date>
    let settings: RABox<EngineSettings>
    let cliFacts: CLIFactStore

    var db: Database { engine.db }
    var queue: AgentQueue { engine.agents }
    var ctx: EngineContext { engine.ctx }

    static func newRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-ra-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// `codex` defaults to a ready scripted fake (nil builds the real CodexProvider — never spawned here).
    static func make(mode: AgentMode, claude: (any AgentProvider)?,
                     codex: (any AgentProvider)? = RAScriptedProvider(id: "codex", status: .ready(
                         plan: "ChatGPT", version: "0.153.4", path: "/fake/codex")),
                     root: URL? = nil, clock: RABox<Date>? = nil,
                     cliFacts: CLIFactStore = .inMemory(), tuning: AgentQueue.Tuning = .raFast,
                     adjust: (inout EngineSettings) -> Void = { _ in }) async throws -> RAQueueHarness {
        let root = try root ?? newRoot()
        var initial = EngineSettings(plan: PlanSettings(dailyBudgetMinutes: 60), lang: .zh, agentMode: mode,
                                     metadataLookup: false)
        adjust(&initial)
        let settings = RABox(initial)
        let clock = clock ?? RABox(raStart)
        // test-engine-lint: real-card-provider — `claude: nil` builds the real ClaudeCodeProvider for the
        // locator tests only (agent.mode off, never started); the assist lane gets the mock only.
        let deps = Engine.Dependencies(loadSettings: { settings.value }, now: { clock.value }, calendar: raChicago,
                                       fetcher: nil, claude: claude, codex: codex, mock: MockAgentProvider(),
                                       sidecarDelay: .milliseconds(10), cliFacts: cliFacts, assistBackends: [MockAssistBackend()])
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: deps)
        await engine.agents.configure(tuning)
        return RAQueueHarness(root: root, engine: engine, clock: clock, settings: settings, cliFacts: cliFacts)
    }

    /// Stops the engine; keeps the files (a later harness may reopen `root`).
    func stop() async {
        await engine.shutdown()
        await engine.db.close()
    }

    func finish() async {
        await stop()
        try? FileManager.default.removeItem(at: root)
    }

    /// A ready paper with cached text (so the queue can build a request).
    @discardableResult
    func insertPaper(title: String = "cortex-atlas.pdf") async throws -> Paper {
        let id = UUID().uuidString.lowercased()
        let sha = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let folder = "Papers/_Inbox/\(sha.prefix(8))"
        try FileManager.default.createDirectory(at: engine.paths.library.appendingPathComponent(folder),
                                                withIntermediateDirectories: true)
        let paper = Paper(id: id, sha256: sha, fileSize: 1000, title: title, titleRank: .font, pageCount: 3,
                          charCount: 300, folder: folder, pdfName: "paper.pdf", originalName: "paper.pdf",
                          stage: .ready, deadline: LocalDate(year: 2026, month: 9, day: 30), scheduleMode: .auto,
                          deadlineOrigin: .place, placementFloor: LocalDate(year: 2026, month: 9, day: 29),
                          provisional: true, estMinutes: 30, estSource: .heuristic,
                          addedAt: clock.value.addingTimeInterval(-3600), updatedAt: clock.value)
        let saved = try await db.insertPaper(paper, checklist: [])
        try ctx.texts.save("Deep Atlas of Developing Cortex Cells\nAbstract\nWe profile cells.\u{0C}Results\nFig. 1 shows it.",
                           id: id)
        return saved
    }

    func paper(_ pk: Int64) async throws -> Paper { try #require(try await db.paper(pk: pk)) }

    func job(_ paperPK: Int64) async throws -> AgentJob {
        let all = try await db.jobs(states: Set(AgentJobState.allCases))
        return try #require(all.filter { $0.paperPK == paperPK }.max { $0.pk < $1.pk })
    }
}
