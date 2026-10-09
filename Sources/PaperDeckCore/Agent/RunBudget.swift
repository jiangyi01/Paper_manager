import Foundation

/// Counts real CLI spawns — `claude -p` and `codex exec` alike (§3.1 额度安全闸). The CLI sets a
/// limit from `--max-runs N`; the GUI leaves it unlimited. Every real spawn — including the
/// Claude provider's one-off variant-B retry — takes one run through `AgentSpawnGate`,
/// so retries and backoffs can never exceed what the user agreed to.
/// Thread-safe (checked from the provider actors and the queue actor).
package final class RunBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var limit: Int?
    private var used = 0

    /// `maxRuns == nil` → unlimited.
    package init(maxRuns: Int? = nil) {
        limit = maxRuns.map { max(0, $0) }
    }

    /// Changes the ceiling (runs already taken still count).
    package func setLimit(_ maxRuns: Int?) {
        lock.withLock { limit = maxRuns.map { max(0, $0) } }
    }

    package var maxRuns: Int? { lock.withLock { limit } }
    package var consumed: Int { lock.withLock { used } }
    package var remaining: Int? { lock.withLock { limit.map { max(0, $0 - used) } } }
    package var isExhausted: Bool { lock.withLock { limit.map { used >= $0 } ?? false } }

    /// Takes one run. Returns false — taking nothing — once the budget is spent.
    package func consume() -> Bool {
        lock.withLock {
            if let limit, used >= limit { return false }
            used += 1
            return true
        }
    }
}

/// The last line of defence before a real spawn: `ClaudeCodeProvider` and `CodexProvider` call
/// it (through `claudeSpawnGate` / `codexSpawnGate`) before every process, the Claude variant-B
/// retry included. A spawn by provider P is allowed only when the freshly re-read
/// `agent.mode == P.mode` (claude → only Claude may spawn, codex → only Codex, off / mock →
/// neither) and the RunBudget has a run left. A user-initiated connection test of P temporarily
/// replaces P's mode check with its own small allowance (DESIGN: 预算 2 次，不受 mode 限制) — the
/// RunBudget still applies, and the other provider keeps its normal mode check.
package final class AgentSpawnGate: @unchecked Sendable {
    package enum Verdict: Sendable, Equatable {
        case allowed
        /// agent.mode (`mode`) does not run the provider that asked (`provider`).
        case modeNotActive(provider: AIProviderKind, mode: AgentMode)
        case budgetExhausted
        case testAllowanceExhausted

        /// The Claude refusal of earlier builds: agent.mode was not claude.
        package static func modeNotClaude(_ mode: AgentMode) -> Verdict { .modeNotActive(provider: .claude, mode: mode) }
    }

    private struct ConnectionTest {
        var provider: AIProviderKind
        var allowance: Int
    }

    package let budget: RunBudget
    private let loadSettings: @Sendable () -> EngineSettings
    private let lock = NSLock()
    private var test: ConnectionTest?

    package init(budget: RunBudget = RunBudget(), loadSettings: @escaping @Sendable () -> EngineSettings) {
        self.budget = budget
        self.loadSettings = loadSettings
    }

    /// Decides for a spawn by `provider` (and on `.allowed` consumes one run).
    package func check(provider: AIProviderKind = .claude, summary: String) -> Verdict {
        let verdict: Verdict = lock.withLock {
            if let t = test, t.provider == provider {
                guard t.allowance > 0 else { return .testAllowanceExhausted }
                guard budget.consume() else { return .budgetExhausted }
                test?.allowance = t.allowance - 1
                return .allowed
            }
            let mode = loadSettings().agentMode
            guard mode == provider.mode else { return .modeNotActive(provider: provider, mode: mode) }
            return budget.consume() ? .allowed : .budgetExhausted
        }
        switch verdict {
        case .allowed:
            Log.agent.info("\(provider.rawValue, privacy: .public) spawn allowed (runs used \(self.budget.consumed))")
        case .modeNotActive(let p, let mode):
            Log.agent.notice("\(p.rawValue, privacy: .public) spawn refused: agent.mode=\(mode.rawValue, privacy: .public) — \(summary, privacy: .public)")
        case .budgetExhausted:
            Log.agent.notice("RUN BUDGET EXHAUSTED — spawn refused: \(summary, privacy: .public)")
        case .testAllowanceExhausted:
            Log.agent.notice("connection-test allowance used up — spawn refused")
        }
        return verdict
    }

    package func allowSpawn(provider: AIProviderKind = .claude, summary: String) -> Bool {
        check(provider: provider, summary: summary) == .allowed
    }

    /// The closure handed to `ClaudeCodeProvider(spawnGate:)`: only while agent.mode is claude.
    package var claudeSpawnGate: ClaudeCodeProvider.SpawnGate {
        { [self] plan in self.allowSpawn(provider: .claude, summary: plan.summary) }
    }

    /// The closure handed to `CodexProvider(spawnGate:)`: only while agent.mode is codex.
    package var codexSpawnGate: CodexProvider.SpawnGate {
        { [self] plan in self.allowSpawn(provider: .codex, summary: plan.summary) }
    }

    /// While active, spawns by `provider` are allowed regardless of agent.mode, at most `spawns`
    /// times (the RunBudget still counts them). Other providers keep their normal check.
    package func beginConnectionTest(provider: AIProviderKind = .claude, spawns: Int) {
        lock.withLock { test = ConnectionTest(provider: provider, allowance: max(0, spawns)) }
    }

    package func endConnectionTest() {
        lock.withLock { test = nil }
    }

    package var isTestingConnection: Bool { lock.withLock { test != nil } }

    /// The provider under a running connection test, nil when none is running.
    package var connectionTestProvider: AIProviderKind? { lock.withLock { test?.provider } }
}

// MARK: - Optional provider capabilities the queue uses when available

/// Providers that can describe a spawn without running it (WOULD RUN logs, `--agent-argv`).
package protocol AgentDryRunning: Sendable {
    func dryRunSummary(_ r: CardRequest) async -> String
}

/// Providers with a learned argv variant (Claude: A = `--tools ""`, B = `--disallowedTools`),
/// persisted by the queue in UserDefaults `agent.claude.argvVariant` / `…argvVariantCLIVersion`
/// (a CLI fact, §3.1 — see `CLIFactStore`).
package protocol AgentVariantLearning: Sendable {
    func restoreLearnedVariant(_ variant: String, cliVersion: String?) async
    func learnedVariantForPersistence() async -> (variant: String, cliVersion: String?)
}

/// Providers that re-check auth before spawning and can say why a `.notLoggedIn` outcome
/// happened without a spawn (e.g. `non_subscription:api_key`).
package protocol AgentAuthReporting: Sendable {
    /// The status behind the latest `.notLoggedIn` outcome of `generateCard`, nil when the
    /// CLI itself reported it (then "logged out" is the best guess).
    func authRefusalStatus() async -> ProviderStatus?
}

extension ClaudeCodeProvider: AgentDryRunning, AgentVariantLearning, AgentAuthReporting {
    package func authRefusalStatus() async -> ProviderStatus? { lastAuthRefusal }

    package func dryRunSummary(_ r: CardRequest) async -> String {
        await dryRun(r).summary.replacingOccurrences(of: "\n", with: " · ")
    }

    package func restoreLearnedVariant(_ variant: String, cliVersion: String?) async {
        guard let v = ArgvVariant(rawValue: variant) else { return }
        setPreferredVariant(v, cliVersion: cliVersion)
    }

    package func learnedVariantForPersistence() async -> (variant: String, cliVersion: String?) {
        let learned = learnedVariant
        return (learned.variant.rawValue, learned.cliVersion)
    }
}
