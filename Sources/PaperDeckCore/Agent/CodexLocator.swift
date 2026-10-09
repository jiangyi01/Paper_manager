import Foundation

/// Finds OpenAI's `codex` CLI for a Finder-launched app (PATH is only `/usr/bin:/bin:/usr/sbin:/sbin`).
///
/// Order: settings override (`agent.codexPath`, re-read on every resolve) → well-known install
/// paths → a login shell's `command -v codex` → the CLI bundled inside the ChatGPT / Codex desktop
/// app. A candidate counts only if it is executable and `--version` prints `codex-cli X.Y.Z`.
/// Like `BinaryLocator`, the path is cached exactly as found (symlinks are never resolved: npm and
/// Homebrew re-point them on update).
package actor CodexLocator {
    private let home: String
    private let probe: BinaryLocator.Probe
    private var override: String?
    private let overrideSource: @Sendable () -> String?
    private var cached: BinaryLocator.Binary?
    private var inflight: Task<BinaryLocator.Binary?, Never>?

    /// - Parameter overrideSource: read on every `locate()`; when its value changed, the cached
    ///   binary is dropped and resolution starts over (a Settings change needs no relaunch).
    package init(home: String = SharedPaths.realHome.path, overrideSource: @escaping @Sendable () -> String? = { nil },
                 probe: BinaryLocator.Probe = .live) {
        self.home = home
        self.overrideSource = overrideSource
        self.override = Self.nonEmpty(overrideSource())
        self.probe = probe
    }

    /// The override currently in effect (after re-reading the live source).
    package func currentOverride() -> String? {
        refreshOverride()
        return override
    }

    /// Forget the cached binary (after a spawn failure, exit 126/127, or a settings change).
    package func invalidate() { cached = nil }

    package var current: BinaryLocator.Binary? { cached }

    /// The cached binary, resolving on first use. `revalidate` re-runs `--version` on the cached
    /// path (an update may have replaced it) and falls back to a full resolution if it fails.
    package func locate(revalidate: Bool = false) async -> BinaryLocator.Binary? {
        refreshOverride()
        if let c = cached {
            guard revalidate else { return c }
            if let v = await validVersion(c.path) {
                let fresh = BinaryLocator.Binary(path: c.path, version: v)
                if cached?.path == c.path { cached = fresh }
                return fresh
            }
            if cached?.path == c.path { cached = nil }
        }
        if let task = inflight { return await task.value }
        let resolvingFor = override
        let task = Task { await self.resolve() }
        inflight = task
        let found = await task.value
        // The override changed while resolving: that result belongs to the old setting.
        guard resolvingFor == override else { return await locate(revalidate: false) }
        inflight = nil
        cached = found
        return found
    }

    private func refreshOverride() {
        let new = Self.nonEmpty(overrideSource())
        guard new != override else { return }
        override = new
        cached = nil
        inflight = nil                       // a resolution for the old override must not win
    }

    // MARK: - Resolution

    /// Package-manager install locations, probed before the login shell.
    package static func fixedCandidates(home: String) -> [String] {
        [
            "/opt/homebrew/bin/codex",
            home + "/.local/bin/codex",
            "/usr/local/bin/codex",
            home + "/.npm-global/bin/codex",
            home + "/.bun/bin/codex",
        ]
    }

    /// The CLI bundled in the (merged) ChatGPT + Codex desktop app — the last resort.
    package static func desktopCandidates(home: String) -> [String] {
        [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            home + "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
    }

    private func resolve() async -> BinaryLocator.Binary? {
        var tried = Set<String>()
        // Lazy stages: the login-shell lookup (≤5 s) only runs when no well-known path worked.
        for stage in 0..<4 {
            let paths: [String]
            switch stage {
            case 0: paths = override.map { [Self.expandTilde($0, home: home)] } ?? []
            case 1: paths = Self.fixedCandidates(home: home)
            case 2:
                paths = await probe.loginShellLookup(command: "codex")
                    .flatMap(BinaryLocator.lastAbsolutePath(in:)).map { [$0] } ?? []
            default: paths = Self.desktopCandidates(home: home)
            }
            for path in paths where path.hasPrefix("/") && tried.insert(path).inserted {
                if let v = await validVersion(path) { return BinaryLocator.Binary(path: path, version: v) }
            }
        }
        return nil
    }

    private func validVersion(_ path: String) async -> String? {
        guard probe.isExecutable(path), let out = await probe.versionOutput(path) else { return nil }
        return Self.parseVersion(out)
    }

    // MARK: - Pure helpers

    /// "codex-cli 0.153.4" → "0.153.4" (a pre-release suffix such as "-alpha.3" is kept).
    /// The first line that matches wins, so a warning printed before it does not hide the CLI.
    package static func parseVersion(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let r = text.range(of: #"^codex-cli \d+\.\d+\.\d+(-[0-9A-Za-z.]+)?(?=\s|$)"#,
                                     options: .regularExpression) else { continue }
            return String(text[r].dropFirst("codex-cli ".count))
        }
        return nil
    }

    private static func expandTilde(_ path: String, home: String) -> String {
        path == "~" ? home : (path.hasPrefix("~/") ? home + path.dropFirst() : path)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
