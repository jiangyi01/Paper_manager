import Foundation

/// What a subscription CLI needs to start an assist child, once the zero-quota checks passed
/// (located, subscription login re-checked, the flags of this version known).
package struct AssistLaunch: Sendable, Equatable {
    package var provider: AIProviderKind
    package var executable: String
    package var version: String
    /// `ChildEnvironment.make` — the same allowlist as cards (no API-key variables ever).
    package var environment: [String: String]
    /// The shared, empty agent working directory (`AppPaths.agentCwd`).
    package var cwd: String
    /// Flags this CLI version lists (`--help`).
    package var flags: Set<String>
    /// Codex: the denylisted features this version lists (each passed as `--disable`).
    package var disabledFeatures: [String]
    /// Codex: `cli_auth_credentials_store` forwarded from `~/.codex/config.toml`.
    package var authCredentialsStore: String?

    package init(provider: AIProviderKind, executable: String, version: String, environment: [String: String],
                 cwd: String, flags: Set<String>, disabledFeatures: [String] = [], authCredentialsStore: String? = nil) {
        self.provider = provider; self.executable = executable; self.version = version
        self.environment = environment; self.cwd = cwd; self.flags = flags
        self.disabledFeatures = disabledFeatures; self.authCredentialsStore = authCredentialsStore
    }
}

package enum AssistLaunchResult: Sendable, Equatable {
    case ready(AssistLaunch)
    case failed(AssistFailure)

    /// A refused login check as an assist failure (reason codes only; the App words them).
    package static func failure(for status: ProviderStatus) -> AssistFailure {
        switch status {
        case .ready: return .generic("ready")
        case .notInstalled: return .binaryMissing
        case .notLoggedIn(let code): return .notLoggedIn(ProviderReason(code: code))
        case .unsupported(let code):
            if case .missingFlags(let flags) = ProviderReason(code: code) { return .unsupported(missingFlags: flags) }
            return .notLoggedIn(ProviderReason(code: code))
        }
    }

    /// A provider's detection in the queue status' terms.
    package static func provider(_ status: ProviderStatus) -> AgentQueueStatus.Provider {
        switch status {
        case .ready(let plan, let version, _): return .ready(plan: plan, version: version)
        case .notInstalled: return .notInstalled
        case .notLoggedIn(let code): return .notLoggedIn(code)
        case .unsupported(let code): return .unsupported(code)
        }
    }
}

/// The zero-quota half of a subscription backend: locate the CLI, re-check the login (the card
/// path's 60 s cache, shared), read the capabilities. `ClaudeCodeProvider` / `CodexProvider` in the
/// app; scripted fakes in tests (which point `executable` at a `/bin/sh` fixture, never a real CLI).
package protocol AssistLauncher: Sendable {
    /// Never spends quota and never starts a model turn.
    func assistLaunch() async -> AssistLaunchResult
    /// The banner's detection (zero quota).
    func assistDetect() async -> AgentQueueStatus.Provider
}

/// A raw-line observer for `--assist-smoke --record` (the lead's format verification): the
/// provider, the turn index and one stdout line. Nil in the app — assist output is never persisted.
package typealias AssistWireTap = @Sendable (_ provider: AIProviderKind, _ turnIndex: Int, _ line: Data) -> Void
