import Foundation

/// Zero-quota provider detection without an engine (onboarding, Help Center, diagnostics):
/// Doctor's construction — the provider's own `detect()` (`claude --version` / `auth status`;
/// `codex --version` / `login status` / `exec --help` / `features list`) with a spawn gate that
/// refuses every real run (`{ _ in false }`), so `claude -p` / `codex exec` can never start from here.
package enum ProviderProbe {
    /// - Parameters:
    ///   - overridePath: Settings ▸ AI's CLI path (`agent.cliPath` / `agent.codexPath`); nil or
    ///     empty searches the usual install locations.
    ///   - agentCwd: the fixed, empty working directory (`AppPaths.agentCwd`); created when missing.
    package static func status(_ kind: AIProviderKind, overridePath: String?, agentCwd: URL) async -> ProviderStatus {
        let override = overridePath.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        await BlockingIO.run { try? FileManager.default.createDirectory(at: agentCwd, withIntermediateDirectories: true) }
        switch kind {
        case .claude:
            let provider = ClaudeCodeProvider(locator: BinaryLocator(override: override), agentCwd: agentCwd,
                                              spawnGate: { _ in false })
            return await provider.detect()
        case .codex:
            let provider = CodexProvider(locator: CodexLocator(overrideSource: { override }), agentCwd: agentCwd,
                                         spawnGate: { _ in false })
            return await provider.detect()
        }
    }
}
