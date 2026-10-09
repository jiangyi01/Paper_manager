import Foundation

/// The real (subscription) reading backends PaperDeck can drive. Both run an official CLI on
/// the user's own subscription login, never API keys:
/// - `claude`: Claude Code CLI (`claude -p`, Claude Pro/Max).
/// - `codex`: OpenAI Codex CLI (`codex exec`, ChatGPT plan login).
///
/// `agent.mode` selects which one runs (`AgentMode.claude` / `.codex`); while the mode is
/// off or mock, UserDefaults `agent.provider` remembers the user's choice so the settings UI
/// can show that provider's login state before AI reading is enabled.
package enum AIProviderKind: String, Sendable, Codable, CaseIterable {
    case claude, codex

    /// Settings / setup-assistant name: "Claude" / "ChatGPT (Codex)".
    package func displayName(_ lang: UILang) -> String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "ChatGPT (Codex)"
        }
    }

    /// Badges, toasts and notes: 「Claude 已读完：…」 / 「ChatGPT 已读完：…」.
    package var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "ChatGPT"
        }
    }

    /// The CLI's own name, for install / version wording ("Claude Code" / "Codex CLI").
    package var cliName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        }
    }

    /// The `agent.mode` that makes this provider run.
    package var mode: AgentMode {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        }
    }

    /// `AgentProvider.id` of the real provider — also `agent_job.provider` and card.json `ai.provider`.
    package var providerID: String { rawValue }

    /// The model a new install reads papers with (Settings ▸ AI can change it).
    package var defaultModel: String {
        switch self {
        case .claude: return "sonnet"
        case .codex: return AIProviderKind.defaultCodexModel
        }
    }

    /// Model / effort of the user-initiated connection test (tiny synthetic paper).
    package var connectionTestModel: String {
        switch self {
        case .claude: return "haiku"
        case .codex: return "gpt-5.6-luna"
        }
    }

    package static let defaultCodexModel = "gpt-5.6-terra"

    /// Per-card watchdog of a real run (Codex answers in 30–120 s; Claude in 30–60 s).
    package var jobTimeout: Duration {
        switch self {
        case .claude: return .seconds(360)
        case .codex: return .seconds(480)
        }
    }

    /// ChatGPT models offered in Settings ▸ AI (slugs from `~/.codex/models_cache.json`).
    package static let codexModelChoices: [AIModelChoice] = [
        AIModelChoice(id: "gpt-5.6-terra", zh: "均衡（推荐）", en: "Balanced (recommended)"),
        AIModelChoice(id: "gpt-5.6-sol", zh: "更深入，消耗更多额度", en: "Deeper, uses more quota"),
        AIModelChoice(id: "gpt-5.6-luna", zh: "更快更省", en: "Faster, uses less quota"),
    ]
}

/// One entry of a model picker: the slug passed to the CLI plus a zh/en hint.
package struct AIModelChoice: Sendable, Equatable, Identifiable {
    package var id: String
    private var zh: String
    private var en: String

    package init(id: String, zh: String, en: String) {
        self.id = id; self.zh = zh; self.en = en
    }

    package func detail(_ lang: UILang) -> String { lang == .zh ? zh : en }
}

extension AgentMode {
    /// The real provider this mode runs; nil for `off` and `mock`.
    package var providerKind: AIProviderKind? {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .off, .mock: return nil
        }
    }
}
