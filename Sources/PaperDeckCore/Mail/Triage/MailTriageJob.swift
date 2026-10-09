import Foundation

/// One AI triage call for one captured email, run by `AgentQueue`'s triage lane
/// (`enqueueTriage`). The lane keeps these in memory only; the durable state
/// (`triage_state`, attempts, results) lives on `mail_message` and is written by the
/// integration layer from the lane's handler (`setTriageHandler`).
package struct MailTriageJob: Sendable, Equatable {
    package var messagePK: Int64
    package var messageID: String
    /// Built with `MailTriageSchema.request(…)`: model / effort / timeout of the triage run.
    package var request: CardRequest
    /// The provider the user allows this email to go to (`MailSettings.triageProvider`);
    /// nil → `EngineSettings.selectedProvider`. It runs only while `agent.mode` names that
    /// provider (mock runs everything, zero quota); otherwise the handler gets `.cancelled`.
    package var provider: AIProviderKind?

    package init(messagePK: Int64, messageID: String, request: CardRequest, provider: AIProviderKind? = nil) {
        self.messagePK = messagePK; self.messageID = messageID; self.request = request; self.provider = provider
    }
}

/// Where a triage job would go right now under `agent.mode` (the spawn gates' rule: only the
/// provider the mode names may spawn). The integration layer uses it to word a held card.
package enum MailTriageRoute: Sendable, Equatable {
    /// Runs on this provider; nil = the zero-quota mock (agent.mode mock).
    case run(AIProviderKind?)
    /// agent.mode is off: nothing is sent to any AI.
    case modeOff(wanted: AIProviderKind)
    /// The email may only go to `wanted`, but agent.mode runs another provider.
    case providerNotActive(wanted: AIProviderKind, mode: AgentMode)

    package static func of(provider: AIProviderKind?, settings: EngineSettings) -> MailTriageRoute {
        let wanted = provider ?? settings.selectedProvider
        switch settings.agentMode {
        case .off: return .modeOff(wanted: wanted)
        case .mock: return .run(nil)
        case .claude, .codex:
            let active = settings.agentMode.providerKind ?? wanted
            return active == wanted ? .run(active) : .providerNotActive(wanted: wanted, mode: settings.agentMode)
        }
    }

    /// Why a triage is held (nil when it runs), e.g. 「AI 已关闭 · 邮件未发送给 AI」.
    package func heldText(_ lang: UILang) -> String? {
        let zh = lang == .zh
        switch self {
        case .run: return nil
        case .modeOff:
            return zh ? "AI 已关闭 · 邮件未发送给 AI" : "AI is off · the email was not sent to AI"
        case .providerNotActive(let wanted, let mode):
            let active = mode.providerKind?.shortName ?? mode.rawValue
            return zh ? "邮件分拣只允许使用 \(wanted.shortName)，当前 AI 模式是 \(active)"
                      : "Mail triage may only use \(wanted.shortName); the AI mode is \(active)"
        }
    }
}
