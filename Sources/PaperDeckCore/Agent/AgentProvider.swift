import Foundation

/// A backend that turns one paper's prepared stdin into a reading card.
/// Ships `ClaudeCodeProvider` (Claude subscription CLI), `CodexProvider` (Codex CLI on a
/// ChatGPT plan login) — never API keys — and `MockAgentProvider`; `AIProviderKind` names the
/// real ones and `agent.mode` picks which runs.
/// Everything provider-specific (envelopes, argv variants, error text) stays
/// behind this protocol — `AgentQueue` only ever sees `AgentOutcome`.
package protocol AgentProvider: Sendable {
    var id: String { get }                                              // "claude" | "codex" | "mock"
    /// Binary / login / capability check. Must never spend subscription quota.
    func detect() async -> ProviderStatus
    /// One card generation. `jobDir` receives raw stdout/stderr for post-mortems.
    func generateCard(_ r: CardRequest, jobDir: URL) async -> AgentOutcome
}

/// One structured-output run. Generic over the task: the reading card (defaults) or the mail
/// triage (`MailTriageSchema.request`) — both go through the same hardened argv.
package struct CardRequest: Sendable, Equatable {
    package let systemPrompt: String
    package let schema: JSONValue
    package let stdin: Data
    package let model: String
    package let effort: String
    package let timeout: Duration
    /// Claude: the `-p` prompt (argv[2]). Default: the reading-card task.
    package let userPrompt: String
    /// Codex: the task paragraph that follows the system prompt in the positional prompt
    /// (`CodexProvider.prompt(systemPrompt:task:)`); nil = the reading-card task (`stdinInstruction`).
    package let codexTask: String?

    package init(systemPrompt: String = CardSchema.systemPrompt, schema: JSONValue, stdin: Data,
                 model: String = "sonnet", effort: String = "medium", timeout: Duration = .seconds(360),
                 userPrompt: String = CardSchema.userPrompt, codexTask: String? = nil) {
        self.systemPrompt = systemPrompt; self.schema = schema; self.stdin = stdin
        self.model = model; self.effort = effort; self.timeout = timeout
        self.userPrompt = userPrompt; self.codexTask = codexTask
    }
}

package struct RunMeta: Sendable, Equatable {
    package let model: String?
    package let durationMs: Int?
    package let costUSD: Double?
    package let inputTokens: Int?
    package let outputTokens: Int?
    package let numTurns: Int?
    /// argv variant that produced the card ("A" = `--tools ""`, "B" = `--disallowedTools`);
    /// the caller persists it per CLI version.
    package let variant: String?

    package init(model: String?, durationMs: Int?, costUSD: Double?, inputTokens: Int?,
                 outputTokens: Int?, numTurns: Int?, variant: String?) {
        self.model = model; self.durationMs = durationMs; self.costUSD = costUSD
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.numTurns = numTurns; self.variant = variant
    }
}

/// The associated String of `.notLoggedIn` / `.unsupported` is a stable reason CODE (see
/// `ProviderReason`), never display text — use `reasonText(_:)` for zh/en wording.
package enum ProviderStatus: Sendable, Equatable {
    case ready(plan: String?, version: String, path: String)
    case notInstalled
    case notLoggedIn(String)
    case unsupported(String)

    /// The parsed reason of `.notLoggedIn` / `.unsupported`; nil for ready / notInstalled.
    package var reason: ProviderReason? {
        switch self {
        case .notLoggedIn(let code), .unsupported(let code): return ProviderReason(code: code)
        case .ready, .notInstalled: return nil
        }
    }

    /// One line of zh/en text for badges, banners and the provider pill, worded for `provider`
    /// (whose CLI produced this status).
    package func reasonText(_ lang: UILang, provider: AIProviderKind = .claude) -> String {
        switch self {
        case .ready(let plan, let version, _):
            return ProviderReason.readyText(plan: plan, version: version, lang, provider: provider)
        case .notInstalled: return ProviderReason.notInstalledText(lang, provider: provider)
        case .notLoggedIn(let code):
            return ProviderReason(code: code).text(lang, loginProblem: true, provider: provider)
        case .unsupported(let code):
            return ProviderReason(code: code).text(lang, loginProblem: false, provider: provider)
        }
    }
}

/// Stable machine-readable reasons carried by `ProviderStatus` / `AgentQueueStatus.Provider`
/// (`.notLoggedIn(code)`, `.unsupported(code)`), so the UI can tell "logged out" from
/// "logged in, but not with the subscription" in either language. The codes are shared by
/// both CLIs; `text(_:loginProblem:provider:)` words them for the provider that produced them.
package enum ProviderReason: Sendable, Equatable {
    /// `claude auth status` / `codex login status`: not logged in.  code `logged_out`
    case loggedOut
    /// Logged in with something other than the subscription (Claude: api_key, apiKeyHelper,
    /// bedrock…; Codex: api_key).                                  code `non_subscription:<method>`
    case nonSubscription(method: String)
    /// This CLI version lacks flags PaperDeck needs.             code `missing_flags:<a,b>`
    case missingFlags([String])
    /// `claude auth status` did not answer in time.              code `timeout`
    case timeout
    /// The fixed agent working directory could not be created.   code `agent_cwd_unavailable`
    case agentCwdUnavailable
    /// Anything else (older free-text states, other providers).
    case other(String)

    package init(code: String) {
        func payload(_ prefix: String) -> String? {
            code.hasPrefix(prefix) ? String(code.dropFirst(prefix.count)) : nil
        }
        switch code {
        case "logged_out": self = .loggedOut
        case "timeout": self = .timeout
        case "agent_cwd_unavailable": self = .agentCwdUnavailable
        default:
            if let m = payload("non_subscription:") {
                self = .nonSubscription(method: m.isEmpty ? "unknown" : m)
            } else if let f = payload("missing_flags:") {
                self = .missingFlags(f.split(separator: ",").map(String.init))
            } else {
                self = .other(code)
            }
        }
    }

    package var code: String {
        switch self {
        case .loggedOut: return "logged_out"
        case .nonSubscription(let method): return "non_subscription:" + method
        case .missingFlags(let flags): return "missing_flags:" + flags.joined(separator: ",")
        case .timeout: return "timeout"
        case .agentCwdUnavailable: return "agent_cwd_unavailable"
        case .other(let raw): return raw
        }
    }

    /// `loginProblem` picks the generic wording for unknown codes (`.notLoggedIn` vs `.unsupported`).
    package func text(_ lang: UILang, loginProblem: Bool, provider: AIProviderKind = .claude) -> String {
        let zh = lang == .zh
        let cli = provider.cliName
        switch self {
        case .loggedOut:
            return Self.signInText(lang, provider: provider)
        case .nonSubscription(let method):
            let shown = Self.methodName(method, provider: provider)
            return zh ? "PaperDeck 只使用订阅登录（当前：\(shown)）"
                      : "PaperDeck only uses subscription login (current: \(shown))"
        case .missingFlags(let flags):
            let list = flags.joined(separator: ", ")
            switch provider {
            case .claude:
                return zh ? "Claude Code 版本过旧（缺少 \(list)），请运行 claude update"
                          : "Claude Code is too old (missing \(list)); run claude update"
            case .codex:
                return zh ? "Codex CLI 版本过旧（缺少 \(list)），请更新 ChatGPT 桌面版或 Codex CLI"
                          : "Codex CLI is too old (missing \(list)); update the ChatGPT app or the Codex CLI"
            }
        case .timeout:
            let command = provider == .codex ? "codex login status" : "claude auth status"
            return zh ? "\(cli) 没有响应（\(command) 超时）" : "\(cli) did not respond (\(command) timed out)"
        case .agentCwdUnavailable:
            return zh ? "无法创建 PaperDeck 的 agent 工作目录" : "Cannot create PaperDeck's agent working directory"
        case .other:
            if loginProblem { return Self.signInText(lang, provider: provider) }
            return zh ? "\(cli) 版本不受支持" : "Unsupported \(cli) version"
        }
    }

    /// 「需登录 Claude」 / 「需登录 ChatGPT：运行 codex login → Sign in with ChatGPT」.
    private static func signInText(_ lang: UILang, provider: AIProviderKind) -> String {
        let zh = lang == .zh
        switch provider {
        case .claude:
            return zh ? "需登录 Claude" : "Sign in to Claude"
        case .codex:
            return zh ? "需登录 ChatGPT：运行 codex login → Sign in with ChatGPT"
                      : "Sign in to ChatGPT: run codex login → Sign in with ChatGPT"
        }
    }

    /// Codex reports an API-key login as `non_subscription:api_key`; show it as "API key".
    /// Claude's methods keep their CLI spelling (api_key, apiKeyHelper, …).
    private static func methodName(_ method: String, provider: AIProviderKind) -> String {
        guard provider == .codex else { return method }
        switch method.lowercased() {
        case "api_key", "apikey", "api-key": return "API key"
        default: return method
        }
    }

    static func readyText(plan: String?, version: String, _ lang: UILang, provider: AIProviderKind = .claude) -> String {
        let plan = plan.flatMap { $0.isEmpty ? nil : $0 }
        let cli = provider.cliName
        switch lang {
        case .zh: return "已登录" + (plan.map { "（\($0)）" } ?? "") + " · \(cli) \(version)"
        case .en: return "Signed in" + (plan.map { " (\($0))" } ?? "") + " · \(cli) \(version)"
        }
    }

    static func notInstalledText(_ lang: UILang, provider: AIProviderKind = .claude) -> String {
        let cli = provider.cliName
        return lang == .zh ? "未找到 \(cli)" : "\(cli) not found"
    }
}

package enum AgentOutcome: Sendable, Equatable {
    case success(card: JSONValue, meta: RunMeta)
    case usageLimit(resetsAt: Date?)
    case notLoggedIn
    case overloaded
    case invalidOutput(String)
    case maxTurns
    case timeout
    case binaryMissing
    case cancelled
    case generic(String)
}
