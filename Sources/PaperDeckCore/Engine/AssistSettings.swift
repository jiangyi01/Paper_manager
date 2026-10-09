import Foundation

/// Settings of the interactive reading assist (Explain, Q&A, the duplicate judge's transport;
/// READING_ASSIST_PLAN §5). UserDefaults keys, read by `EngineSettings.load` and written by the
/// app's `SettingsStore` (only the keys that changed). Absent keys read as the defaults below, so
/// an existing install sees `assist.mode = off` until the user turns it on.
package struct AssistSettings: Sendable, Equatable {
    package enum Depth: String, Sendable, CaseIterable { case quick, thorough }
    /// How much the explanation assumes (the per-turn `<task level=…>`).
    package enum Level: String, Sendable, CaseIterable { case novice, student, researcher }
    /// The language of explanations: Chinese with English terms (D3), English, or the UI's.
    package enum ExplainLanguage: String, Sendable, CaseIterable { case zh, en, ui }
    /// Q&A answers in the question's language (`auto`), or always en / zh.
    package enum AnswerLanguage: String, Sendable, CaseIterable { case auto, en, zh }
    /// What the hotkey opens first: the frame (drag a box) or the lens (click a block).
    package enum OverlayMode: String, Sendable, CaseIterable { case frame, lens }

    /// A Carbon hotkey: virtual key code + Carbon modifier mask.
    package struct HotKey: Sendable, Equatable {
        package var keyCode: Int
        package var carbonModifiers: Int
        package init(keyCode: Int, carbonModifiers: Int) { self.keyCode = keyCode; self.carbonModifiers = carbonModifiers }
        /// ⌃⌥E (D4): kVK_ANSI_E = 0x0E, controlKey 0x1000 | optionKey 0x0800.
        package static let defaultExplain = HotKey(keyCode: 0x0E, carbonModifiers: 0x1000 | 0x0800)
    }

    package enum Keys {
        package static let mode = "assist.mode", consentVersion = "assist.consentVersion"
        package static let dailySoftCap = "assist.dailySoftCap", dailyHardCap = "assist.dailyHardCap"
        package static let keepWarm = "assist.keepWarm"
        package static let explainLang = "assist.explain.lang", explainDepth = "assist.explain.depth"
        package static let explainLevel = "assist.explain.level", explainContextChars = "assist.explain.contextChars"
        package static let explainHotkey = "assist.explain.hotkey", explainDefaultMode = "assist.explain.defaultMode"
        package static let explainAskBeforeSend = "assist.explain.askBeforeSend"
        package static let explainHistoryDays = "assist.explain.historyDays"
        package static let qaLang = "assist.qa.lang", qaDepth = "assist.qa.depth", qaTextBudget = "assist.qa.textBudget"
        package static let qaMultiMax = "assist.qa.multiMax"
        package static func model(_ provider: AIProviderKind, _ depth: Depth) -> String {
            "assist.model.\(provider.rawValue).\(depth.rawValue)"
        }
        /// Every key this struct reads (the model keys included).
        package static var all: [String] {
            [mode, consentVersion, dailySoftCap, dailyHardCap, keepWarm, explainLang, explainDepth, explainLevel,
             explainContextChars, explainHotkey, explainDefaultMode, explainAskBeforeSend, explainHistoryDays,
             qaLang, qaDepth, qaTextBudget, qaMultiMax]
                + AIProviderKind.allCases.flatMap { p in Depth.allCases.map { model(p, $0) } }
        }
        /// Never exported by a settings export or set by an org pack (plan §8): turning AI on, the
        /// consent the user gave. The kv counters and pauses live in the library, not here.
        package static let neverExported: Set<String> = [mode, consentVersion]
    }

    package static let defaultSoftCap = 50
    package static let defaultHardCap = 150

    package var mode: AssistMode
    /// The first-use consent sheet version the user accepted (0: never).
    package var consentVersion: Int
    /// Turns per provider per day before "Continue?" (a fresh `capOverride` ticket continues).
    package var dailySoftCap: Int
    /// Turns per provider per day, no override.
    package var dailyHardCap: Int
    /// Seconds a warm Claude process may idle before it is closed.
    package var keepWarmSeconds: Int
    package var explainLanguage: ExplainLanguage
    package var explainDepth: Depth
    package var explainLevel: Level
    package var explainContextChars: Int
    package var explainHotKey: HotKey
    package var explainDefaultMode: OverlayMode
    package var explainAskBeforeSend: Bool
    /// Days unpinned, unsaved explanations are kept.
    package var explainHistoryDays: Int
    package var qaLanguage: AnswerLanguage
    /// Q&A's model: quick by default (decision 6 of the approved proposal: Haiku / Luna, "Thorough"
    /// on request), like Explain — the default never spends the larger model's quota.
    package var qaDepth: Depth
    package var qaTextBudget: Int
    package var qaMultiMax: Int
    /// `assist.model.<provider>.<depth>`.
    package var models: [AIProviderKind: [Depth: String]]

    package static let defaultModels: [AIProviderKind: [Depth: String]] = [
        .claude: [.quick: "haiku", .thorough: "sonnet"],
        .codex: [.quick: "gpt-5.6-luna", .thorough: "gpt-5.6-terra"],
    ]

    package init(mode: AssistMode = .off, consentVersion: Int = 0, dailySoftCap: Int = AssistSettings.defaultSoftCap,
                 dailyHardCap: Int = AssistSettings.defaultHardCap, keepWarmSeconds: Int = 180,
                 explainLanguage: ExplainLanguage = .zh, explainDepth: Depth = .quick, explainLevel: Level = .student,
                 explainContextChars: Int = 6_000, explainHotKey: HotKey = .defaultExplain,
                 explainDefaultMode: OverlayMode = .frame, explainAskBeforeSend: Bool = false,
                 explainHistoryDays: Int = 90, qaLanguage: AnswerLanguage = .auto, qaDepth: Depth = .quick,
                 qaTextBudget: Int = 80_000, qaMultiMax: Int = 10,
                 models: [AIProviderKind: [Depth: String]] = AssistSettings.defaultModels) {
        self.mode = mode; self.consentVersion = consentVersion; self.dailySoftCap = dailySoftCap
        self.dailyHardCap = dailyHardCap; self.keepWarmSeconds = keepWarmSeconds
        self.explainLanguage = explainLanguage; self.explainDepth = explainDepth; self.explainLevel = explainLevel
        self.explainContextChars = explainContextChars; self.explainHotKey = explainHotKey
        self.explainDefaultMode = explainDefaultMode; self.explainAskBeforeSend = explainAskBeforeSend
        self.explainHistoryDays = explainHistoryDays; self.qaLanguage = qaLanguage; self.qaDepth = qaDepth
        self.qaTextBudget = qaTextBudget; self.qaMultiMax = qaMultiMax; self.models = models
    }

    /// The model slug of `provider` at `depth` (the default when unset).
    package func model(_ provider: AIProviderKind, _ depth: Depth) -> String {
        models[provider]?[depth] ?? Self.defaultModels[provider]?[depth] ?? provider.defaultModel
    }

    /// Reads the keys (absent or malformed → the default). Caps are clamped to sane ranges.
    package static func load(from d: UserDefaults = .standard) -> AssistSettings {
        func int(_ k: String, _ def: Int, _ range: ClosedRange<Int>) -> Int {
            guard d.object(forKey: k) != nil else { return def }
            return min(max(d.integer(forKey: k), range.lowerBound), range.upperBound)
        }
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        func raw<E: RawRepresentable>(_ k: String, _ def: E) -> E where E.RawValue == String {
            d.string(forKey: k).flatMap(E.init(rawValue:)) ?? def
        }
        var models = defaultModels
        for p in AIProviderKind.allCases {
            for depth in Depth.allCases {
                if let s = d.string(forKey: Keys.model(p, depth)), !s.trimmingCharacters(in: .whitespaces).isEmpty {
                    models[p, default: [:]][depth] = s
                }
            }
        }
        var hotKey = HotKey.defaultExplain
        if let dict = d.dictionary(forKey: Keys.explainHotkey),
           let code = (dict["keyCode"] as? NSNumber)?.intValue, let mods = (dict["modifiers"] as? NSNumber)?.intValue {
            hotKey = HotKey(keyCode: code, carbonModifiers: mods)
        }
        let hard = int(Keys.dailyHardCap, defaultHardCap, 1...1_000)
        return AssistSettings(
            mode: raw(Keys.mode, AssistMode.off),
            consentVersion: int(Keys.consentVersion, 0, 0...Int(Int32.max)),
            dailySoftCap: min(int(Keys.dailySoftCap, defaultSoftCap, 1...1_000), hard),
            dailyHardCap: hard,
            keepWarmSeconds: int(Keys.keepWarm, 180, 0...3_600),
            explainLanguage: raw(Keys.explainLang, ExplainLanguage.zh),
            explainDepth: raw(Keys.explainDepth, Depth.quick),
            explainLevel: raw(Keys.explainLevel, Level.student),
            explainContextChars: int(Keys.explainContextChars, 6_000, 1_000...24_000),
            explainHotKey: hotKey,
            explainDefaultMode: raw(Keys.explainDefaultMode, OverlayMode.frame),
            explainAskBeforeSend: bool(Keys.explainAskBeforeSend, false),
            explainHistoryDays: int(Keys.explainHistoryDays, 90, 1...3_650),
            qaLanguage: raw(Keys.qaLang, AnswerLanguage.auto),
            qaDepth: raw(Keys.qaDepth, Depth.quick),
            qaTextBudget: int(Keys.qaTextBudget, 80_000, 10_000...400_000),
            qaMultiMax: int(Keys.qaMultiMax, 10, AssistSettings.qaMultiMaxRange),   // the stepper's range
            models: models)
    }

    /// Writes the keys whose value differs from `previous` (nothing else, so an unchanged setting
    /// stays absent and keeps following the default).
    package func save(to d: UserDefaults, previous: AssistSettings) {
        func set<T: Equatable>(_ new: T, _ old: T, _ key: String, _ value: @autoclosure () -> Any) {
            if new != old { d.set(value(), forKey: key) }
        }
        set(mode, previous.mode, Keys.mode, mode.rawValue)
        set(consentVersion, previous.consentVersion, Keys.consentVersion, consentVersion)
        set(dailySoftCap, previous.dailySoftCap, Keys.dailySoftCap, dailySoftCap)
        set(dailyHardCap, previous.dailyHardCap, Keys.dailyHardCap, dailyHardCap)
        set(keepWarmSeconds, previous.keepWarmSeconds, Keys.keepWarm, keepWarmSeconds)
        set(explainLanguage, previous.explainLanguage, Keys.explainLang, explainLanguage.rawValue)
        set(explainDepth, previous.explainDepth, Keys.explainDepth, explainDepth.rawValue)
        set(explainLevel, previous.explainLevel, Keys.explainLevel, explainLevel.rawValue)
        set(explainContextChars, previous.explainContextChars, Keys.explainContextChars, explainContextChars)
        set(explainHotKey, previous.explainHotKey, Keys.explainHotkey,
            ["keyCode": explainHotKey.keyCode, "modifiers": explainHotKey.carbonModifiers])
        set(explainDefaultMode, previous.explainDefaultMode, Keys.explainDefaultMode, explainDefaultMode.rawValue)
        set(explainAskBeforeSend, previous.explainAskBeforeSend, Keys.explainAskBeforeSend, explainAskBeforeSend)
        set(explainHistoryDays, previous.explainHistoryDays, Keys.explainHistoryDays, explainHistoryDays)
        set(qaLanguage, previous.qaLanguage, Keys.qaLang, qaLanguage.rawValue)
        set(qaDepth, previous.qaDepth, Keys.qaDepth, qaDepth.rawValue)
        set(qaTextBudget, previous.qaTextBudget, Keys.qaTextBudget, qaTextBudget)
        set(qaMultiMax, previous.qaMultiMax, Keys.qaMultiMax, qaMultiMax)
        for p in AIProviderKind.allCases {
            for depth in Depth.allCases {
                let new = model(p, depth), old = previous.model(p, depth)
                if new != old { d.set(new, forKey: Keys.model(p, depth)) }
            }
        }
    }
}

/// Settings of the duplicate check (READING_ASSIST_PLAN §5, DQ §3). The new layers are on by
/// default with the safe behaviour (they only ever ask; nothing is deleted, merged or replaced
/// without a click); the AI judge is off and only ever runs on a click (D2).
package struct DedupeSettings: Sendable, Equatable {
    package enum Sensitivity: String, Sendable, CaseIterable { case strict, balanced, loose }

    package enum Keys {
        package static let enabled = "dedupe.enabled", sensitivity = "dedupe.sensitivity", history = "dedupe.history"
        package static let aiAuto = "dedupe.ai.auto", aiDailyCap = "dedupe.ai.dailyCap"
        package static let all = [enabled, sensitivity, history, aiAuto, aiDailyCap]
        /// Never exported, never set by an org pack (an import can't switch the AI judge on).
        package static let neverExported: Set<String> = [aiAuto]
    }

    /// Master switch of the new layers. Off → today's two-button same-work toast, unchanged.
    package var enabled: Bool
    package var sensitivity: Sensitivity
    /// Compare against papers already read and removed (`paper_history`).
    package var history: Bool
    /// The AI judge runs by itself on likely matches (v1.1). Off by default; v1 judges on a click only.
    package var aiAuto: Bool
    /// Automatic judge turns per day (kv `dedupe.ai.count.<day>`).
    package var aiDailyCap: Int

    package init(enabled: Bool = true, sensitivity: Sensitivity = .balanced, history: Bool = true,
                 aiAuto: Bool = false, aiDailyCap: Int = 10) {
        self.enabled = enabled; self.sensitivity = sensitivity; self.history = history
        self.aiAuto = aiAuto; self.aiDailyCap = aiDailyCap
    }

    package static func load(from d: UserDefaults = .standard) -> DedupeSettings {
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        let cap = d.object(forKey: Keys.aiDailyCap) == nil ? 10 : min(max(d.integer(forKey: Keys.aiDailyCap), 0), 100)
        return DedupeSettings(
            enabled: bool(Keys.enabled, true),
            sensitivity: d.string(forKey: Keys.sensitivity).flatMap(Sensitivity.init(rawValue:)) ?? .balanced,
            history: bool(Keys.history, true),
            aiAuto: bool(Keys.aiAuto, false),
            aiDailyCap: cap)
    }

    /// Writes the keys whose value differs from `previous`.
    package func save(to d: UserDefaults, previous: DedupeSettings) {
        if enabled != previous.enabled { d.set(enabled, forKey: Keys.enabled) }
        if sensitivity != previous.sensitivity { d.set(sensitivity.rawValue, forKey: Keys.sensitivity) }
        if history != previous.history { d.set(history, forKey: Keys.history) }
        if aiAuto != previous.aiAuto { d.set(aiAuto, forKey: Keys.aiAuto) }
        if aiDailyCap != previous.aiDailyCap { d.set(aiDailyCap, forKey: Keys.aiDailyCap) }
    }
}
