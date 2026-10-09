import Foundation

/// Finds the `claude` executable for a Finder-launched app, whose PATH is only
/// `/usr/bin:/bin:/usr/sbin:/sbin`.
///
/// Order: settings override (re-read on every resolve when live) → well-known install paths → a login shell's
/// `command -v claude` → newest Claude Desktop bundled CLI. A candidate counts
/// only if it is executable and `--version` prints `X.Y.Z (Claude Code)`.
/// The path is cached exactly as found — e.g. `~/.local/bin/claude`, a symlink
/// into `versions/2.1.284` — never the resolved target, because the updater
/// re-points the symlink and deletes old versions.
package actor BinaryLocator {
    package struct Binary: Sendable, Equatable {
        package var path: String
        package var version: String                  // "2.1.284"
        package var directory: String { (path as NSString).deletingLastPathComponent }
        package init(path: String, version: String) { self.path = path; self.version = version }
    }

    /// Side effects behind closures so tests can fake the filesystem and processes.
    /// The live probes run in the temp dir so a protected launch cwd (e.g. ~/Documents) is never touched.
    package struct Probe: Sendable {
        package var isExecutable: @Sendable (String) -> Bool
        /// stdout of `<path> --version`, nil if it failed to run or exited non-zero.
        package var versionOutput: @Sendable (String) async -> String?
        /// stdout of `/bin/zsh -lc 'command -v claude'` (stdin=/dev/null, 5 s timeout).
        package var loginShellLookup: @Sendable () async -> String?
        package var listDirectory: @Sendable (String) -> [String]
        /// stdout of `/bin/zsh -lc 'command -v <name>'` for another CLI (e.g. `codex`, used by
        /// `CodexLocator`). nil → `loginShellLookup` answers every name (test fakes).
        package var commandLookup: (@Sendable (String) async -> String?)?

        package init(isExecutable: @escaping @Sendable (String) -> Bool,
                     versionOutput: @escaping @Sendable (String) async -> String?,
                     loginShellLookup: @escaping @Sendable () async -> String?,
                     listDirectory: @escaping @Sendable (String) -> [String],
                     commandLookup: (@Sendable (String) async -> String?)? = nil) {
            self.isExecutable = isExecutable; self.versionOutput = versionOutput
            self.loginShellLookup = loginShellLookup; self.listDirectory = listDirectory
            self.commandLookup = commandLookup
        }

        /// The login-shell lookup for `command` (`claude` keeps using `loginShellLookup`).
        package func loginShellLookup(command: String) async -> String? {
            if let commandLookup { return await commandLookup(command) }
            return await loginShellLookup()
        }

        /// `/bin/zsh -lc 'command -v <name>'` (stdin=/dev/null, 5 s timeout). Only plain command
        /// names are accepted, so nothing but a fixed word ever reaches the shell.
        package static func liveLoginShellLookup(_ command: String) async -> String? {
            guard !command.isEmpty, command.count <= 32,
                  command.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
                return nil
            }
            let env = ChildEnvironment.make(binaryDir: "", parent: ProcessInfo.processInfo.environment)
            let runner = ProcessRunner(interruptGrace: .seconds(1), terminateGrace: .seconds(1))
            guard let r = try? await runner.run(.init(executable: "/bin/zsh",
                                                      arguments: ["-lc", "command -v " + command],
                                                      environment: env, currentDirectory: NSTemporaryDirectory(),
                                                      stdin: nil, timeout: .seconds(5))),
                  !r.timedOut else { return nil }
            return String(decoding: r.stdout, as: UTF8.self)
        }

        package static let live = Probe(
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            versionOutput: { path in
                let env = ChildEnvironment.make(binaryDir: (path as NSString).deletingLastPathComponent,
                                                parent: ProcessInfo.processInfo.environment)
                let runner = ProcessRunner(interruptGrace: .seconds(2), terminateGrace: .seconds(2))
                guard let r = try? await runner.run(.init(executable: path, arguments: ["--version"],
                                                          environment: env, currentDirectory: NSTemporaryDirectory(),
                                                          timeout: .seconds(10))),
                      r.exitCode == 0, !r.timedOut else { return nil }
                return String(decoding: r.stdout, as: UTF8.self)
            },
            loginShellLookup: {
                let env = ChildEnvironment.make(binaryDir: "", parent: ProcessInfo.processInfo.environment)
                let runner = ProcessRunner(interruptGrace: .seconds(1), terminateGrace: .seconds(1))
                guard let r = try? await runner.run(.init(executable: "/bin/zsh",
                                                          arguments: ["-lc", "command -v claude"],
                                                          environment: env, currentDirectory: NSTemporaryDirectory(),
                                                          stdin: nil, timeout: .seconds(5))),
                      !r.timedOut else { return nil }
                return String(decoding: r.stdout, as: UTF8.self)
            },
            listDirectory: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
            commandLookup: { await liveLoginShellLookup($0) }
        )
    }

    private let home: String
    private let probe: Probe
    private var override: String?
    /// Live override (Settings ▸ AI `agent.cliPath`), re-read before every resolve.
    private var overrideSource: (@Sendable () -> String?)?
    private var cached: Binary?
    private var inflight: Task<Binary?, Never>?

    /// Fixed override (CLI tools, tests).
    package init(home: String = SharedPaths.realHome.path, override: String? = nil, probe: Probe = .live) {
        self.home = home
        self.override = Self.nonEmpty(override)
        self.probe = probe
    }

    /// Live override: `overrideSource` is read on every `locate()`; when its value changed, the
    /// cached binary is dropped and resolution starts over (a Settings change needs no relaunch).
    package init(home: String = SharedPaths.realHome.path, overrideSource: @escaping @Sendable () -> String?,
                 probe: Probe = .live) {
        self.home = home
        self.override = Self.nonEmpty(overrideSource())
        self.overrideSource = overrideSource
        self.probe = probe
    }

    /// Replaces the override (and any live source) with a fixed value.
    package func setOverride(_ path: String?) {
        overrideSource = nil
        applyOverride(Self.nonEmpty(path))
    }

    private func applyOverride(_ new: String?) {
        guard new != override else { return }
        override = new
        cached = nil
        inflight = nil                       // a resolution for the old override must not win
    }

    /// Picks up a changed live override.
    private func refreshOverride() {
        guard let overrideSource else { return }
        applyOverride(Self.nonEmpty(overrideSource()))
    }

    /// The override currently in effect (after re-reading a live source).
    package func currentOverride() -> String? {
        refreshOverride()
        return override
    }

    /// Forget the cached binary (after a spawn failure, exit 126/127, or a settings change).
    package func invalidate() { cached = nil }

    package var current: Binary? { cached }

    /// The cached binary, resolving on first use. `revalidate` re-runs
    /// `--version` on the cached path (the symlink may now point at an update)
    /// and falls back to a full resolution if it no longer passes.
    package func locate(revalidate: Bool = false) async -> Binary? {
        refreshOverride()
        if let c = cached {
            guard revalidate else { return c }
            if let v = await validVersion(c.path) {
                let fresh = Binary(path: c.path, version: v)
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

    // MARK: - Resolution

    /// Known install locations, in probe order.
    package static func fixedCandidates(home: String) -> [String] {
        [
            home + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home + "/.claude/local/claude",
            home + "/.npm-global/bin/claude",
            home + "/.bun/bin/claude",
        ]
    }

    private func resolve() async -> Binary? {
        var tried = Set<String>()
        // Stages are produced lazily: the login-shell lookup (≤5 s) only runs
        // when no well-known path worked.
        for stage in 0..<4 {
            let paths: [String]
            switch stage {
            case 0: paths = override.map { [Self.expandTilde($0, home: home)] } ?? []
            case 1: paths = Self.fixedCandidates(home: home)
            case 2: paths = await probe.loginShellLookup().flatMap(Self.lastAbsolutePath(in:)).map { [$0] } ?? []
            default: paths = desktopBundledCandidates()
            }
            for path in paths where path.hasPrefix("/") && tried.insert(path).inserted {
                if let v = await validVersion(path) { return Binary(path: path, version: v) }
            }
        }
        return nil
    }

    private func validVersion(_ path: String) async -> String? {
        guard probe.isExecutable(path), let out = await probe.versionOutput(path) else { return nil }
        return Self.parseVersion(out)
    }

    /// Claude Desktop ships its own CLI under a versioned folder: newest first.
    private func desktopBundledCandidates() -> [String] {
        let root = home + "/Library/Application Support/Claude/claude-code"
        return probe.listDirectory(root)
            .filter { !$0.hasPrefix(".") }
            .sorted { Self.versionComponents($0).lexicographicallyPrecedes(Self.versionComponents($1)) }
            .reversed()
            .map { root + "/" + $0 + "/claude.app/Contents/MacOS/claude" }
    }

    // MARK: - Pure helpers

    /// "2.1.284 (Claude Code)" → "2.1.284"; anything else → nil.
    package static func parseVersion(_ output: String) -> String? {
        let first = output.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard let r = first.range(of: #"^\d+\.\d+\.\d+ \(Claude Code\)"#, options: .regularExpression) else {
            return nil
        }
        return first[r].components(separatedBy: " ").first
    }

    /// Login shells may print banners; the answer is the last line that is an absolute path.
    package static func lastAbsolutePath(in output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
    }

    private static func versionComponents(_ s: String) -> [Int] {
        s.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
    }

    private static func expandTilde(_ path: String, home: String) -> String {
        path == "~" ? home : (path.hasPrefix("~/") ? home + path.dropFirst() : path)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
