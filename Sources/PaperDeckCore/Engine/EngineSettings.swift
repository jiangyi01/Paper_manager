import Foundation

/// Controls whether AI jobs may spawn a real CLI. `off` is the default so
/// nothing ever spends the user's subscription until they opt in.
/// `claude` runs the Claude Code CLI, `codex` the Codex CLI (ChatGPT plan login);
/// `mock` is the zero-quota demo provider.
package enum AgentMode: String, Sendable, Codable {
    case off, mock, claude, codex
}

/// Value snapshot of every setting the engine reads. UserDefaults is
/// thread-safe, so engine actors call `EngineSettings.load()` whenever they
/// need fresh values (e.g. `agent.mode` is re-read before every spawn).
package struct EngineSettings: Sendable, Equatable {
    package var plan: PlanSettings                 // skipDays filled from the DB by the engine
    package var lang: UILang
    /// Setting a real provider's mode (claude / codex) also makes it `agentProvider`.
    package var agentMode: AgentMode {
        didSet { if let kind = agentMode.providerKind { agentProvider = kind } }
    }
    /// The real provider the user chose (UserDefaults `agent.provider`). While `agentMode` is
    /// claude / codex that mode wins; while off / mock it says which provider the settings UI
    /// describes (login state, connection test) and which one `enable` would switch on.
    package var agentProvider: AIProviderKind
    package var autoReadNewPapers: Bool
    package var cliPathOverride: String?
    package var agentModel: String                 // sonnet | opus | haiku (Claude)
    package var agentEffort: String                // low | medium (both providers)
    /// Codex model slug (`codex exec -m`): gpt-5.6-terra | gpt-5.6-sol | gpt-5.6-luna.
    package var codexModel: String
    /// Settings ▸ AI path of the `codex` executable (UserDefaults `agent.codexPath`).
    package var codexPathOverride: String?
    package var textBudget: Int                    // chars of paper text sent to the agent
    package var allowNewCategories: Bool
    package var importMode: ImportMode
    package var metadataLookup: Bool
    package var crossrefMailto: String?
    package var autoMarkDone: Bool
    package var reminderEnabled: Bool
    /// Interactive reading assist (`assist.*`): off until the user turns it on.
    package var assist: AssistSettings
    /// Duplicate check (`dedupe.*`).
    package var dedupe: DedupeSettings

    package enum ImportMode: String, Sendable { case copy, move }

    package init(plan: PlanSettings = PlanSettings(), lang: UILang = .zh, agentMode: AgentMode = .off,
                 agentProvider: AIProviderKind = .claude,
                 autoReadNewPapers: Bool = true, cliPathOverride: String? = nil, agentModel: String = "sonnet",
                 agentEffort: String = "medium", codexModel: String = AIProviderKind.defaultCodexModel,
                 codexPathOverride: String? = nil, textBudget: Int = 120_000, allowNewCategories: Bool = true,
                 importMode: ImportMode = .copy, metadataLookup: Bool = true, crossrefMailto: String? = nil,
                 autoMarkDone: Bool = true, reminderEnabled: Bool = true,
                 assist: AssistSettings = AssistSettings(), dedupe: DedupeSettings = DedupeSettings()) {
        self.plan = plan; self.lang = lang; self.agentMode = agentMode
        self.agentProvider = agentMode.providerKind ?? agentProvider
        self.autoReadNewPapers = autoReadNewPapers; self.cliPathOverride = cliPathOverride
        self.agentModel = agentModel; self.agentEffort = agentEffort
        self.codexModel = codexModel; self.codexPathOverride = codexPathOverride
        self.textBudget = textBudget
        self.allowNewCategories = allowNewCategories; self.importMode = importMode
        self.metadataLookup = metadataLookup; self.crossrefMailto = crossrefMailto
        self.autoMarkDone = autoMarkDone; self.reminderEnabled = reminderEnabled
        self.assist = assist; self.dedupe = dedupe
    }

    /// The real provider in charge: the mode's provider when it is claude / codex, otherwise
    /// the remembered `agentProvider`.
    package var selectedProvider: AIProviderKind { agentMode.providerKind ?? agentProvider }

    /// Model slug a real run of `kind` uses.
    package func model(for kind: AIProviderKind) -> String {
        switch kind {
        case .claude: return agentModel
        case .codex: return codexModel
        }
    }

    /// Reads the same keys the app's SettingsStore writes.
    package static func load(from d: UserDefaults = .standard) -> EngineSettings {
        func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        func str(_ k: String) -> String? { d.string(forKey: k).flatMap { $0.isEmpty ? nil : $0 } }
        let weekdays = (d.array(forKey: "plan.readingWeekdays") as? [Int]).map(Set.init) ?? Set(1...7)
        let plan = PlanSettings(
            dailyBudgetMinutes: max(10, int("plan.dailyBudget", 60)),
            readingWeekdays: weekdays.isEmpty ? Set(1...7) : weekdays,
            cutoffHour: int("plan.cutoffHour", 18),
            reminderHour: int("reminder.hour", 11),
            reminderMinute: int("reminder.minute", 0),
            remindWhenEmpty: bool("reminder.whenEmpty", false)
        )
        let mode = AgentMode(rawValue: d.string(forKey: "agent.mode") ?? "off") ?? .off
        return EngineSettings(
            plan: plan,
            lang: UILang(rawValue: d.string(forKey: "language") ?? "en") ?? .en,
            agentMode: mode,
            // agent.mode claude / codex wins over a stale agent.provider (the init applies it).
            agentProvider: str("agent.provider").flatMap(AIProviderKind.init(rawValue:)) ?? .claude,
            autoReadNewPapers: bool("agent.autoRead", true),
            cliPathOverride: str("agent.cliPath"),
            agentModel: str("agent.model") ?? "sonnet",
            agentEffort: str("agent.effort") ?? "medium",
            codexModel: str("agent.codexModel") ?? AIProviderKind.defaultCodexModel,
            codexPathOverride: str("agent.codexPath"),
            textBudget: int("agent.textBudget", 120_000),
            allowNewCategories: bool("agent.allowNewCategories", true),
            importMode: ImportMode(rawValue: d.string(forKey: "library.importMode") ?? "copy") ?? .copy,
            metadataLookup: bool("metadata.lookup", true),
            crossrefMailto: str("metadata.mailto"),
            autoMarkDone: bool("plan.autoMarkDone", true),
            reminderEnabled: bool("reminder.enabled", true),
            assist: AssistSettings.load(from: d),
            dedupe: DedupeSettings.load(from: d)
        )
    }
}
