import Foundation
import PaperDeckCore
import PaperDeckConfig

/// `--agent-argv [--provider claude|codex]` (dry run, no spawn) and
/// `--agent-smoke --yes [--provider claude|codex] [--max-runs N]` (one tiny REAL run).
enum AgentCLI {
    static let samplePaper = """
    [[p. 1]]
    Spatial transcriptomics of the developing mouse cortex reveals layer-specific progenitor states
    Abstract
    We profiled 12 embryonic mouse cortices (E12.5–E17.5) with a spatial transcriptomics assay at 10 µm resolution and
    identified 14 progenitor states. Layer-specific states emerged at E14.5 and were validated by smFISH in 3 independent
    litters. A graph neural network trained on the spatial data predicted neuronal fate with an AUROC of 0.91 on held-out
    sections. Data are available in GEO under accession GSE000000 and code on GitHub.
    [[p. 2]]
    Results
    Fig. 1 shows the atlas; Fig. 2 compares progenitor proportions across stages (Wilcoxon test, FDR < 0.05).
    Methods
    Sections were processed as described; clustering used Leiden (resolution 0.8). Statistics used pseudobulk DESeq2.
    Discussion
    Limitations include a single mouse strain and no human validation.
    """

    /// The reading-card request for the sample paper, with the system prompt the app would send
    /// for the configured reader (Settings ▸ Profile: field, stage, reader description).
    static func request(model: String, effort: String, timeout: Duration = .seconds(240)) -> CardRequest {
        let categories = PaperCategory.starters.map { (name: $0.name, description: Optional($0.description), count: 0) }
        let stdin = CardSchema.stdin(metadata: nil, pageCount: 2, categories: categories, frequentTags: [],
                                     paperText: samplePaper)
        return CardRequest(systemPrompt: CardSchema.systemPrompt(for: ConfigResolver.cardPromptProfile()),
                           schema: CardSchema.schema(categories: categories.map(\.name)), stdin: stdin,
                           model: model, effort: effort, timeout: timeout)
    }

    /// The agent working directory: under `--root` when given (so checks never touch the real
    /// Application Support folder), else the app's own `agent-cwd`.
    static func agentCwd(_ args: CLIArgs? = nil) -> URL {
        let url = args?.url("--root").map { AppPaths.rooted(at: $0).agentCwd } ?? AppPaths.production().agentCwd
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `--provider claude|codex` (default claude); nil for anything else.
    static func providerKind(_ args: CLIArgs) -> AIProviderKind? {
        guard let raw = args.value("--provider") else { return .claude }
        return AIProviderKind(rawValue: raw.lowercased())
    }

    /// Settings ▸ AI path overrides (UserDefaults `agent.cliPath` / `agent.codexPath`).
    static func cliOverride(_ kind: AIProviderKind) -> String? {
        let key = kind == .codex ? "agent.codexPath" : "agent.cliPath"
        return UserDefaults.standard.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A Codex provider for the CLI checks; `spawnGate` nil = never spawn `codex exec`.
    static func codexProvider(_ args: CLIArgs, spawnGate: CodexProvider.SpawnGate? = nil) -> CodexProvider {
        let override = cliOverride(.codex)
        return CodexProvider(locator: CodexLocator(overrideSource: { override }), agentCwd: agentCwd(args),
                             spawnGate: spawnGate ?? { dry in
                                 print("REFUSED (no spawn allowed here): \(dry.argv.prefix(2).joined(separator: " "))")
                                 return false
                             })
    }

    /// Env keys that must never reach a child: anything outside the allowlist or credential-looking.
    static func leakedKeys(_ keys: [String]) -> [String] {
        keys.filter { k in
            !ChildEnvironment.keys.contains(k) || k.hasPrefix("ANTHROPIC") || k.hasPrefix("CLAUDE")
                || k.hasPrefix("OPENAI") || k.hasPrefix("CODEX") || k.hasPrefix("AZURE") || k.contains("API_KEY")
                || k.contains("TOKEN")
        }
    }

    static func argv(_ args: CLIArgs) async -> Int32 {
        guard let kind = providerKind(args) else { return CLIRunner.fail("--provider must be claude or codex") }
        switch kind {
        case .claude:
            let provider = ClaudeCodeProvider(locator: BinaryLocator(override: cliOverride(.claude)), agentCwd: agentCwd(args))
            let dry = await provider.dryRun(request(model: "sonnet", effort: "medium"))
            print(dry.summary)
            let leaked = leakedKeys(dry.environmentKeys)
            CLIRunner.line(["provider": "claude", "envKeys": dry.environmentKeys.count, "leakedCredentialKeys": leaked])
            return leaked.isEmpty ? 0 : 1
        case .codex:
            // Zero quota: codex --version, exec --help and features list only (never exec itself).
            let provider = codexProvider(args)
            let model = UserDefaults.standard.string(forKey: "agent.codexModel").flatMap { $0.isEmpty ? nil : $0 }
                ?? AIProviderKind.defaultCodexModel
            let dry = await provider.dryRun(request(model: model, effort: "medium", timeout: AIProviderKind.codex.jobTimeout))
            print(dry.summary)
            let leaked = leakedKeys(dry.environmentKeys)
            let disabled = zip(dry.argv, dry.argv.dropFirst()).filter { $0.0 == "--disable" }.map(\.1)
            let required = ["--ignore-user-config", "--json", "--output-schema"]
            let missing = required.filter { !dry.argv.contains($0) }
            let readOnly = zip(dry.argv, dry.argv.dropFirst()).contains { $0.0 == "--sandbox" && $0.1 == "read-only" }
            CLIRunner.line(["provider": "codex", "envKeys": dry.environmentKeys.count, "leakedCredentialKeys": leaked,
                            "disabledFeatures": disabled, "missingSafetyFlags": missing, "sandboxReadOnly": readOnly])
            return leaked.isEmpty && missing.isEmpty && readOnly && disabled.contains("shell_tool") ? 0 : 1
        }
    }

    /// One real run on the tiny synthetic paper — spends a little subscription quota.
    /// Claude: `claude -p` (haiku, effort low, 3 turns). Codex: `codex exec` (gpt-5.6-luna, effort low).
    static func smoke(_ args: CLIArgs) async -> Int32 {
        guard let kind = providerKind(args) else { return CLIRunner.fail("--provider must be claude or codex") }
        guard args.has("--yes") else {
            let what = kind == .codex ? "codex exec (spends ChatGPT subscription quota)" : "claude -p (spends subscription quota)"
            return CLIRunner.fail("--agent-smoke runs a REAL \(what). Re-run with --yes [--provider \(kind.rawValue)] [--max-runs N]")
        }
        let maxRuns = args.int("--max-runs") ?? 1
        guard maxRuns > 0 else { return CLIRunner.fail("--max-runs must be at least 1") }
        let budget = RunBudget(maxRuns: maxRuns)
        switch kind {
        case .claude: return await smokeClaude(args, budget: budget)
        case .codex: return await smokeCodex(args, budget: budget)
        }
    }

    private static func smokeClaude(_ args: CLIArgs, budget: RunBudget) async -> Int32 {
        let provider = ClaudeCodeProvider(locator: BinaryLocator(override: cliOverride(.claude)), agentCwd: agentCwd(args), maxTurns: 3,
                                          spawnGate: { dry in
                                              let ok = budget.consume()
                                              print(ok ? "SPAWN (\(dry.variant.rawValue))" : "RUN BUDGET EXHAUSTED")
                                              return ok
                                          })
        let status = await provider.detect()
        print("detect: \(status)")
        guard case .ready = status else { return 1 }
        let jobDir = FileManager.default.temporaryDirectory.appendingPathComponent("paperdeck-smoke-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        let t0 = Date()
        let outcome = await provider.generateCard(request(model: "haiku", effort: "low"), jobDir: jobDir)
        let secs = Date().timeIntervalSince(t0)
        switch outcome {
        case .success(let card, let meta):
            CLIRunner.line(["outcome": "success", "variant": meta.variant, "model": meta.model, "durationMs": meta.durationMs,
                            "costUSD": meta.costUSD, "turns": meta.numTurns, "wallSeconds": Int(secs)])
            printCard(card)
            // The working argv variant is a fact about this CLI version: share it with the app.
            let learned = await provider.learnedVariant
            CLIFactStore.standard.set(learned.variant.rawValue, forKey: AgentQueue.variantKey)
            CLIFactStore.standard.set(learned.cliVersion, forKey: AgentQueue.variantCLIVersionKey)
            print("argv variant \(learned.variant.rawValue) recorded for CLI \(learned.cliVersion ?? "?")")
            return 0
        default:
            CLIRunner.line(["outcome": String(describing: outcome), "wallSeconds": Int(secs), "jobDir": jobDir.path])
            return 1
        }
    }

    private static func smokeCodex(_ args: CLIArgs, budget: RunBudget) async -> Int32 {
        let provider = codexProvider(args, spawnGate: { dry in
            let ok = budget.consume()
            print(ok ? "SPAWN codex exec (\(budget.consumed)/\(budget.maxRuns.map(String.init) ?? "∞"))" : "RUN BUDGET EXHAUSTED")
            return ok
        })
        let status = await provider.detect()
        print("detect: \(status) — \(status.reasonText(.en, provider: .codex))")
        guard case .ready = status else { return 1 }
        let jobDir = FileManager.default.temporaryDirectory.appendingPathComponent("paperdeck-smoke-codex-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        let t0 = Date()
        let outcome = await provider.generateCard(request(model: AIProviderKind.codex.connectionTestModel, effort: "low",
                                                          timeout: AIProviderKind.codex.jobTimeout), jobDir: jobDir)
        let secs = Date().timeIntervalSince(t0)
        switch outcome {
        case .success(let card, let meta):
            CLIRunner.line(["outcome": "success", "model": meta.model, "durationMs": meta.durationMs,
                            "inputTokens": meta.inputTokens, "outputTokens": meta.outputTokens, "turns": meta.numTurns,
                            "wallSeconds": Int(secs), "runsUsed": budget.consumed])
            printCard(card)
            return 0
        default:
            // stdout.jsonl / stderr.txt / last.json stay in jobDir for inspection.
            CLIRunner.line(["outcome": String(describing: outcome), "wallSeconds": Int(secs), "jobDir": jobDir.path,
                            "runsUsed": budget.consumed])
            return 1
        }
    }

    private static func printCard(_ card: JSONValue) {
        guard let c = try? CardSanitizer.sanitize(card, pageCount: 2) else {
            print("card did not pass CardSanitizer")
            return
        }
        print("tldr: \(c.tldr)\ncategory: \(c.category)  tags: \(c.tags.joined(separator: ", "))  est: \(c.estimatedMinutes)′")
        for s in c.checklist { print("  - [\(s.minutes)′] \(s.task)  (\(s.section ?? "-"))") }
    }
}
