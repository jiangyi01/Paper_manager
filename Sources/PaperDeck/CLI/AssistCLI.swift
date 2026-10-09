import Foundation
import PaperDeckCore

/// `--assist-argv [explain|qa|judge] [--provider claude|codex] [--model M] [--root DIR]`: what one
/// interactive assist turn would run — argv (long values elided), cwd, env keys, the stdin line's
/// shape — from the pure argv builders only. Nothing is located, probed or spawned, no directory is
/// created, no setting is read. `--assist-smoke` (CLIRunner) runs the real thing.
enum AssistCLI {
    static func surface(_ raw: String?) -> AssistSurface? {
        switch raw?.lowercased() {
        case nil, "explain"?: return .explain
        case "qa"?, "ask"?: return .qa
        case "judge"?, "dupjudge"?: return .dupJudge
        default: return nil
        }
    }

    /// The agent working directory's path (never created here): under `--root`, else the app's.
    static func agentCwdPath(_ args: CLIArgs) -> String {
        (args.url("--root").map { AppPaths.rooted(at: $0) } ?? AppPaths.production()).agentCwd.path
    }

    static func argv(_ args: CLIArgs) -> Int32 {
        guard let surface = surface(args.positional) else { return CLIRunner.fail("--assist-argv explain|qa|judge") }
        guard let provider = AIProviderKind(rawValue: (args.value("--provider") ?? "claude").lowercased()) else {
            return CLIRunner.fail("--provider must be claude or codex")
        }
        let dry = AssistSmoke.dryRun(surface: surface, provider: provider, model: args.value("--model"),
                                     agentCwd: agentCwdPath(args), parentEnvironment: ProcessInfo.processInfo.environment)
        print(dry.summary)
        let leaked = AssistSmoke.leakedKeys(dry.environmentKeys)
        let content = [AssistSmoke.firstTurnText, AssistSmoke.followUpText]
        let contentInArgv = dry.argv.contains { arg in content.contains { arg.contains($0) } }
        var checks: [String: Any?] = ["provider": provider.rawValue, "surface": surface.rawValue,
                                      "envKeys": dry.environmentKeys.count, "leakedCredentialKeys": leaked,
                                      "contentInArgv": contentInArgv, "spawned": false]
        var ok = leaked.isEmpty && !contentInArgv
        let pairs = Array(zip(dry.argv, dry.argv.dropFirst()))
        switch provider {
        case .claude:
            let toolsFollowedByFlag = pairs.contains { $0.0 == "--tools" && $0.1 == "" }
                && dry.argv.firstIndex(of: "--tools").map { i in i + 2 < dry.argv.count && dry.argv[i + 2].hasPrefix("--") } == true
            let streamJSON = pairs.contains { $0.0 == "--input-format" && $0.1 == "stream-json" }
                && pairs.contains { $0.0 == "--output-format" && $0.1 == "stream-json" }
            checks["toolsFollowedByFlag"] = toolsFollowedByFlag
            checks["streamJSON"] = streamJSON
            checks["noSessionPersistence"] = dry.argv.contains("--no-session-persistence")
            ok = ok && toolsFollowedByFlag && streamJSON && dry.argv.contains("--no-session-persistence")
        case .codex:
            let disabled = pairs.filter { $0.0 == "--disable" }.map(\.1)
            let readOnly = pairs.contains { $0.0 == "--sandbox" && $0.1 == "read-only" }
            let required = ["--ignore-user-config", "--ephemeral", "--json", "-o"]
            let missing = required.filter { !dry.argv.contains($0) }
            let imageForm = dry.argv.allSatisfy { $0 != "-i" && $0 != "--image" }
            checks["disabledFeatures"] = disabled
            checks["sandboxReadOnly"] = readOnly
            checks["missingSafetyFlags"] = missing
            checks["imageEqualsForm"] = imageForm
            checks["noOutputSchema"] = !dry.argv.contains("--output-schema")
            ok = ok && readOnly && missing.isEmpty && imageForm && disabled.contains("view_image")
                && !dry.argv.contains("--output-schema")
        }
        CLIRunner.line(checks)
        return ok ? 0 : 1
    }

    /// The real backend of a smoke (`spawnGate` of the provider refuses every card spawn: only the
    /// assist path, behind the smoke lane's `AssistGate`, may run).
    static func smokeBackend(_ plan: AssistSmoke.Plan, args: CLIArgs, tap: AssistWireTap?) -> any AssistBackend {
        let cwd = args.url("--root").map { AppPaths.rooted(at: $0).agentCwd } ?? AppPaths.production().agentCwd
        try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        switch plan.provider {
        case .claude:
            let provider = ClaudeCodeProvider(locator: BinaryLocator(override: AgentCLI.cliOverride(.claude)), agentCwd: cwd,
                                              spawnGate: { _ in false })
            let idle = plan.prewarmIdleSeconds
            let spec = ClaudeAssistSession.Spec(AssistSmoke.request(plan, index: 0, history: [], image: nil))
            return ClaudeAssistBackend(launcher: provider, keepWarm: { .seconds((idle ?? 0) + 60) },
                                       prewarmSpec: { spec }, idleSpawnOnPrewarm: idle != nil, tap: tap)
        case .codex:
            let jobs = args.url("--root").map { AppPaths.rooted(at: $0).jobs }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("paperdeck-assist-smoke-jobs", isDirectory: true)
            try? FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
            let provider = AgentCLI.codexProvider(args, spawnGate: { _ in false })
            return CodexAssistBackend(launcher: provider, jobsDir: jobs, tap: tap)
        }
    }

    static func report(_ r: AssistSmoke.TurnReport) {
        CLIRunner.line(["turn": r.index, "outcome": r.outcome, "chars": r.text.count, "deltas": r.deltas,
                        "replaces": r.replaces, "model": r.meta?.model, "warm": r.meta?.warm,
                        "ttftMs": r.meta?.ttftMs, "totalMs": r.meta?.totalMs, "inputTokens": r.meta?.inputTokens,
                        "outputTokens": r.meta?.outputTokens, "costUSD": r.meta?.costUSD])
    }
}
