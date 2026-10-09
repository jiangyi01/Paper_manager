import Foundation

/// The assist backends the engine registers (READING_ASSIST_PLAN §3.2): the mock always; Claude and
/// Codex only when the engine runs the real providers (an injected test provider yields none, so a
/// test can never reach a CLI); the on-device model when the SDK has it. Nothing runs until
/// `assist.mode` names a backend and a user gesture's ticket passes `AssistGate`.
///
/// Claude may start one idle process when the Explain shortcut arms it (`prewarm`, gated by
/// `AssistGate.checkSpawn` and "Keep Claude ready", `assist.keepWarm`; R-UI-9, spike Q3: an idle
/// process sends nothing and costs no quota). It runs Explain's first turn: the same model, effort
/// and system prompt the panel's first turn asks for (`explainPrewarmSpec`), and closes after
/// `assist.keepWarm` idle like any warm process.
package enum AssistBackendFactory {
    package static func builtIn(claude: (any AgentProvider)?, codex: (any AgentProvider)?, paths: AppPaths,
                                load: @escaping @Sendable () -> EngineSettings,
                                now: @escaping @Sendable () -> Date = Date.init,
                                reader: @escaping @Sendable () -> String = { "" },
                                includeLocal: Bool = true) -> [any AssistBackend] {
        var backends: [any AssistBackend] = [MockAssistBackend()]
        if let claude = claude as? ClaudeCodeProvider {
            backends.append(ClaudeAssistBackend(launcher: claude, now: now,
                                                keepWarm: { ClaudeAssistBackend.keepWarm(seconds: load().assist.keepWarmSeconds) },
                                                prewarmSpec: { explainPrewarmSpec(load().assist, reader: reader()) },
                                                idleSpawnOnPrewarm: true))
        }
        if let codex = codex as? CodexProvider {
            backends.append(CodexAssistBackend(launcher: codex, jobsDir: paths.jobs, now: now))
        }
        if includeLocal, let local = LocalAssistBackend.system() { backends.append(local) }
        return backends
    }

    /// What Explain's first turn on Claude runs (`ClaudeAssistSession.Spec`: model, effort, system
    /// prompt) at the default depth — the pre-started process is used only by a turn asking exactly
    /// this; nil with "Keep Claude ready" off.
    package static func explainPrewarmSpec(_ settings: AssistSettings, reader: String) -> ClaudeAssistSession.Spec? {
        guard settings.keepWarmSeconds > 0 else { return nil }
        var claude = settings
        claude.mode = .claude
        let (model, effort) = ExplainModelChoice.model(claude, depth: settings.explainDepth)
        return ClaudeAssistSession.Spec(model: model, systemPrompt: ExplainPrompt.system(reader: reader), effort: effort)
    }
}
