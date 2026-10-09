import Foundation
import PaperDeckCore

/// The sections of a settings export (`paperdeck.settings/1`).
package enum SettingsSection: String, Codable, Sendable, CaseIterable {
    case profile, organization, general, plan, ai, library, mailSenders, mailAccounts, panel
}

/// Whether a key travels: exported, shown as a hint and confirmed on import, or never.
package enum SettingsKeyClass: Sendable {
    case export, hint, never
}

/// A privacy- or quota-sensitive key: an import never makes it looser than this Mac's value
/// without the user's opt-in for that one item (`SettingsImporter.plan`, `ImportLoosening`).
package struct SettingsSensitivity: Sendable, Equatable {
    /// What a looser value gives away.
    package enum Concern: String, Sendable, CaseIterable {
        /// More of the user's mail or papers leaves the Mac (to AI, online lookups, the screen) or stays longer.
        case privacy
        /// More of the AI subscription, the network or the disk is used.
        case quota
    }

    /// How two values of the key compare. `default` is what the app uses while the key is absent
    /// (the same as `MailSettings()` / `EngineSettings()` — `SettingsRegistryLintTests`).
    package enum Order: Sendable, Equatable {
        /// On is looser.
        case onIsLooser(default: Bool)
        /// Off is looser (a safeguard: "Ask before every send").
        case offIsLooser(default: Bool)
        /// A larger number is looser.
        case higherIsLooser(default: Double)
        /// A longer period is looser; 0 or less keeps everything (the loosest).
        case longerIsLooserZeroForever(default: Double)
        /// A shorter interval is looser; 0 or less is manual only (the strictest).
        case shorterIsLooserZeroManual(default: Double)
        /// Later in the list is looser; a value the list doesn't know counts as looser than any
        /// other (nothing proves it isn't).
        case ranked([String], default: String)
        /// Compared inside the value by the importer: each sender's AI policy and switches
        /// (`mail.senders`), each account's switch and look-back (`mail.accounts`), the
        /// institution's people default (`org.preset`, `org.custom`).
        case perEntry
        /// Which AI service gets the data, compared by the importer with the one this Mac uses
        /// (`mail.triageProvider`: unset → the AI-reading provider): another service is looser —
        /// the user's mail would go to a company this Mac doesn't send it to.
        case provider
    }

    package var concerns: Set<Concern>
    package var order: Order

    package init(_ concerns: Set<Concern>, _ order: Order) {
        self.concerns = concerns; self.order = order
    }

    /// The value this Mac uses for a stored value (`nil`: the key is absent → the default), as
    /// JSON (what the import sheet shows as "this Mac"). Nil for `perEntry`.
    package func effective(_ stored: Any?) -> JSONValue? {
        switch order {
        case .onIsLooser(let def), .offIsLooser(let def): return .bool(Self.bool(stored) ?? def)
        case .higherIsLooser(let def), .longerIsLooserZeroForever(let def), .shorterIsLooserZeroManual(let def):
            return .number(Self.number(stored) ?? def)
        case .ranked(_, let def): return .string((stored as? String).flatMap { $0.isEmpty ? nil : $0 } ?? def)
        case .perEntry, .provider: return nil
        }
    }

    /// Whether writing `new` would loosen this Mac's `stored` value (absent: the default). A
    /// value of the wrong type counts as looser. Always false for `perEntry` (the importer decides).
    package func isLooser(_ new: JSONValue, than stored: Any?) -> Bool {
        guard let mine = effective(stored) else { return false }
        switch order {
        case .onIsLooser:
            guard let theirs = new.boolValue ?? new.doubleValue.map({ $0 != 0 }) else { return true }
            return theirs && mine.boolValue != true
        case .offIsLooser:
            guard let theirs = new.boolValue ?? new.doubleValue.map({ $0 != 0 }) else { return true }
            return !theirs && mine.boolValue != false
        case .higherIsLooser:
            guard let theirs = new.doubleValue, let m = mine.doubleValue else { return true }
            return theirs > m
        case .longerIsLooserZeroForever:
            guard let theirs = new.doubleValue, let m = mine.doubleValue else { return true }
            func period(_ x: Double) -> Double { x <= 0 ? .infinity : x }
            return period(theirs) > period(m)
        case .shorterIsLooserZeroManual:
            guard let theirs = new.doubleValue, let m = mine.doubleValue else { return true }
            func interval(_ x: Double) -> Double { x <= 0 ? .infinity : x }
            return interval(theirs) < interval(m)
        case .ranked(let list, _):
            guard let theirs = new.stringValue, let m = mine.stringValue else { return true }
            guard theirs != m else { return false }
            guard let t = list.firstIndex(of: theirs) else { return true }
            return t > (list.firstIndex(of: m) ?? list.count)
        case .perEntry, .provider:
            return false
        }
    }

    private static func bool(_ v: Any?) -> Bool? {
        (v as? NSNumber)?.boolValue
    }

    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
}

/// What a scalar key accepts from a settings file (`SettingsImporter.plan`): a value of the wrong
/// type, not finite or out of range is dropped with a warning (`ImportWarning.valueOutOfRange`) —
/// never written, never offered as a looser value. Ranges hold every value the app's own controls
/// and loaders produce.
package enum SettingsValueRule: Sendable, Equatable {
    /// true / false (a file's 0 / 1 is read as a bool).
    case bool
    /// A whole number in the range.
    case int(ClosedRange<Int>)
    /// A finite number in the range.
    case number(ClosedRange<Double>)
    /// A list of whole numbers, each in the range.
    case intList(ClosedRange<Int>)
    /// One of these whole numbers (a switch stored as a number: only what the app's control writes).
    case intChoice([Int])

    /// The value to write for `v`, or nil when it isn't acceptable.
    package func validated(_ v: JSONValue) -> JSONValue? {
        switch self {
        case .bool:
            if case .bool = v { return v }
            if let d = v.doubleValue, d == 0 || d == 1 { return .bool(d == 1) }
            return nil
        case .int(let r):
            guard let d = v.doubleValue, d.isFinite, d.rounded() == d,
                  d >= Double(r.lowerBound), d <= Double(r.upperBound) else { return nil }
            return .number(d)
        case .number(let r):
            guard let d = v.doubleValue, d.isFinite, r.contains(d) else { return nil }
            return .number(d)
        case .intList(let r):
            guard case .array(let items) = v else { return nil }
            let checked = items.compactMap { SettingsValueRule.int(r).validated($0) }
            return checked.count == items.count ? .array(checked) : nil
        case .intChoice(let allowed):
            guard let d = v.doubleValue, d.isFinite, d.rounded() == d, allowed.contains(where: { Double($0) == d }) else { return nil }
            return .number(d)
        }
    }
}

package struct SettingsKeyEntry: Sendable {
    package var key: String
    package var section: SettingsSection
    package var keyClass: SettingsKeyClass
    /// Personal data (an address, a path with a user name): off by default in an export.
    package var personal: Bool
    /// What the import / export sheets and the CLI call the key — never the raw key name.
    package var label: LocalizedText
    /// Set for privacy- and quota-sensitive keys: an import only tightens them unless the user
    /// accepts the looser value for that item.
    package var sensitivity: SettingsSensitivity?

    package init(key: String, section: SettingsSection, keyClass: SettingsKeyClass, personal: Bool = false,
                 label: LocalizedText = LocalizedText(en: "", zh: ""), sensitivity: SettingsSensitivity? = nil) {
        self.key = key; self.section = section; self.keyClass = keyClass; self.personal = personal
        self.label = label; self.sensitivity = sensitivity
    }

    /// An import never loosens this key silently.
    package var tightensOnly: Bool { sensitivity != nil }
}

/// The allowlist of transferable settings keys (PORTABILITY_PLAN §2.10): a key that isn't listed
/// is never exported, and `never` entries document what stays on a Mac on purpose.
package enum SettingsRegistry {
    package static let entries: [SettingsKeyEntry] = {
        func e(_ s: SettingsSection, _ c: SettingsKeyClass, personal: Bool = false, _ keys: String...) -> [SettingsKeyEntry] {
            keys.map { SettingsKeyEntry(key: $0, section: s, keyClass: c, personal: personal) }
        }
        var all: [SettingsKeyEntry] = []
        all += e(.profile, .export, ConfigKeys.profileField, ConfigKeys.profileStage, ConfigKeys.profileReaderDescription)
        all += e(.organization, .export, ConfigKeys.orgPreset, ConfigKeys.orgCustom)
        all += e(.general, .export, "language", "menubar.showCount", "pdf.opener", "metadata.lookup")
        all += e(.general, .hint, personal: true, "metadata.mailto")
        all += e(.plan, .export, "plan.dailyBudget", "plan.readingWeekdays", "plan.cutoffHour", "plan.autoMarkDone",
                 "reminder.enabled", "reminder.hour", "reminder.minute", "reminder.whenEmpty")
        all += e(.ai, .export, "agent.provider", "agent.model", "agent.codexModel", "agent.effort", "agent.textBudget",
                 "agent.allowNewCategories", "agent.autoRead", "agent.notifyDone")
        all += e(.ai, .hint, "agent.cliPath", "agent.codexPath")
        // Settings ▸ Explain & Ask ▸ Ask (phase 2). The switch and its consent never travel (below);
        // the per-depth models wait for a setting of their own (unlisted: never exported).
        all += e(.ai, .export, AssistSettings.Keys.qaDepth, AssistSettings.Keys.qaLang, AssistSettings.Keys.qaTextBudget,
                 AssistSettings.Keys.qaMultiMax)
        // Settings ▸ Explain & Ask ▸ Explain (phase 3, R-UI-8) and the daily limit both surfaces share.
        all += e(.ai, .export, AssistSettings.Keys.explainLang, AssistSettings.Keys.explainDepth, AssistSettings.Keys.explainHotkey,
                 AssistSettings.Keys.explainDefaultMode, AssistSettings.Keys.explainAskBeforeSend,
                 AssistSettings.Keys.explainHistoryDays, AssistSettings.Keys.keepWarm, AssistSettings.Keys.dailySoftCap)
        all += e(.library, .export, "library.importMode")
        // The duplicate check (Settings ▸ Library ▸ Duplicates); the AI judge's cap travels once its
        // setting is shown (B3), its automatic mode never.
        all += e(.library, .export, DedupeSettings.Keys.enabled, DedupeSettings.Keys.sensitivity, DedupeSettings.Keys.history)
        all += e(.library, .hint, "library.path", ConfigKeys.importLastFolder)
        // "Mail senders & criteria": who is read and how — the sender list, the reading criteria,
        // the date order of their due dates and the triage preferences (a lab setup file carries
        // them; never an address of the user's own mailbox).
        all += e(.mailSenders, .export, MailSettings.Keys.senders, MailSettings.Keys.criteria, MailSettings.Keys.dateOrder,
                 MailSettings.Keys.aiMode, MailSettings.Keys.triageProvider, MailSettings.Keys.triageModelClaude,
                 MailSettings.Keys.triageModelCodex, MailSettings.Keys.triageDailyMax, MailSettings.Keys.triageBodyCap)
        // "Mail accounts (no passwords)": the mailboxes and how they are fetched and kept.
        all += e(.mailAccounts, .export, MailSettings.Keys.syncMinutes, MailSettings.Keys.maxAttachmentMB,
                 MailSettings.Keys.prefillNotes, MailSettings.Keys.notifyNewRequests,
                 MailSettings.Keys.includeInDailyReminder, MailSettings.Keys.retentionDays)
        all += e(.mailAccounts, .hint, MailSettings.Keys.accounts, ConfigKeys.mailCloudRoot)
        all += e(.panel, .export, "panel.visible", "panel.edge", "panel.edgeYFraction", "panel.idleOpacity",
                 "panel.expandOnDrag", "panel.showTodayOnHover")
        // Never: what a new Mac decides for itself (AI and mail stay off until turned on there),
        // per-Mac state, and every marker of this layer.
        all += e(.ai, .never, "agent.mode", "agent.failureTotals", "agent.claude.argvVariant",
                 "agent.claude.argvVariantCLIVersion")
        // Explain & Ask on or off and the consent given for it, the duplicate judge running by
        // itself: decided on each Mac (READING_ASSIST_PLAN §8 — a file or a pack never turns AI on).
        all += e(.ai, .never, AssistSettings.Keys.mode, AssistSettings.Keys.consentVersion)
        all += e(.library, .never, DedupeSettings.Keys.aiAuto)
        all += e(.general, .never, "setup.completed", "general.launchAtLogin", "panel.screenID")
        all += e(.plan, .never, "reminder.lastDeliveredDay", "reminder.scheduledFires")
        all += e(.mailAccounts, .never, MailSettings.Keys.enabled)
        all += e(.library, .never, ConfigKeys.libraryPendingAction, ConfigKeys.libraryPreviousPath)
        all += e(.general, .never, ConfigKeys.migrationVersion, ConfigKeys.origin, ConfigKeys.migratedAt,
                 ConfigKeys.migrationNote, ConfigKeys.onboardingVersion, ConfigKeys.onboardingCompletedAt,
                 ConfigKeys.onboardingAIDecision, ConfigKeys.onboardingMailDecision, ConfigKeys.onboardingLegacy,
                 ConfigKeys.guideChecklistDismissed, ConfigKeys.guideSkipped, ConfigKeys.guideManualDone,
                 ConfigKeys.guideActivity, ConfigKeys.transferLastExportedAt, ConfigKeys.transferImportedAt)
        return all.map { entry in
            var entry = entry
            entry.label = labels[entry.key] ?? LocalizedText(en: "", zh: "")
            entry.sensitivity = sensitivities[entry.key]
            return entry
        }
    }()

    /// The privacy- and quota-sensitive keys and how their values compare (`SettingsSensitivity`).
    /// Every other key was reviewed as neither (`SettingsRegistryLintTests.reviewedNotSensitive`).
    static let sensitivities: [String: SettingsSensitivity] = {
        let claudeModels = ["haiku", "sonnet", "opus"]                              // lighter → uses more of the plan
        let codexModels = ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol"]
        let m = MailSettings(), es = EngineSettings()
        return [
            // Mail: what goes to AI, how much, how often, and how long it is kept.
            MailSettings.Keys.aiMode: .init([.privacy, .quota],
                                            .ranked([MailSettings.AIMode.heuristicOnly.rawValue, MailSettings.AIMode.ai.rawValue],
                                                    default: m.aiMode.rawValue)),
            // Per entry this Mac has: a sender's AI policy and switches, an account's switch and look-back
            // (`SettingsImporter.guardedSenderFields` / `guardedAccountFields`).
            MailSettings.Keys.senders: .init([.privacy, .quota], .perEntry),
            MailSettings.Keys.accounts: .init([.privacy, .quota], .perEntry),
            MailSettings.Keys.triageDailyMax: .init([.quota], .higherIsLooser(default: Double(m.triageDailyMax))),
            MailSettings.Keys.triageBodyCap: .init([.privacy, .quota], .higherIsLooser(default: Double(m.triageBodyCap))),
            MailSettings.Keys.triageModelClaude: .init([.quota], .ranked(claudeModels, default: m.triageModelClaude)),
            MailSettings.Keys.triageModelCodex: .init([.quota], .ranked(codexModels, default: m.triageModelCodex)),
            MailSettings.Keys.maxAttachmentMB: .init([.privacy, .quota], .higherIsLooser(default: Double(m.maxAttachmentMB))),
            MailSettings.Keys.syncMinutes: .init([.quota], .shorterIsLooserZeroManual(default: Double(m.syncMinutes))),
            MailSettings.Keys.notifyNewRequests: .init([.privacy], .onIsLooser(default: m.notifyNewRequests)),
            MailSettings.Keys.retentionDays: .init([.privacy], .longerIsLooserZeroForever(default: Double(m.retentionDays))),
            // AI reading: what is read without asking, how much text is sent, how much of the plan it uses.
            "agent.autoRead": .init([.privacy, .quota], .onIsLooser(default: es.autoReadNewPapers)),
            "agent.textBudget": .init([.privacy, .quota], .higherIsLooser(default: Double(es.textBudget))),
            "agent.effort": .init([.quota], .ranked(["low", "medium"], default: es.agentEffort)),
            "agent.model": .init([.quota], .ranked(claudeModels, default: es.agentModel)),
            "agent.codexModel": .init([.quota], .ranked(codexModels, default: es.codexModel)),
            // Online metadata lookups send titles and identifiers to Crossref / arXiv / OpenAlex.
            "metadata.lookup": .init([.privacy], .onIsLooser(default: es.metadataLookup)),
            // AI email sorting sent to another AI service than the one this Mac uses.
            MailSettings.Keys.triageProvider: .init([.privacy], .provider),
            // Ask: the larger model by default, more of a paper's text with every question.
            AssistSettings.Keys.qaDepth: .init([.quota], .ranked(AssistSettings.Depth.allCases.map(\.rawValue),
                                                                 default: es.assist.qaDepth.rawValue)),
            AssistSettings.Keys.qaTextBudget: .init([.privacy, .quota], .higherIsLooser(default: Double(es.assist.qaTextBudget))),
            // Explain: the larger model, more turns before "Continue?", no confirmation before a send,
            // explanations kept longer on this Mac.
            AssistSettings.Keys.explainDepth: .init([.quota], .ranked(AssistSettings.Depth.allCases.map(\.rawValue),
                                                                     default: es.assist.explainDepth.rawValue)),
            AssistSettings.Keys.dailySoftCap: .init([.quota], .higherIsLooser(default: Double(es.assist.dailySoftCap))),
            AssistSettings.Keys.explainAskBeforeSend: .init([.privacy, .quota], .offIsLooser(default: es.assist.explainAskBeforeSend)),
            AssistSettings.Keys.explainHistoryDays: .init([.privacy],
                                                          .longerIsLooserZeroForever(default: Double(es.assist.explainHistoryDays))),
            // Remembering removed papers (title, ids) for the duplicate check keeps more on this Mac.
            DedupeSettings.Keys.history: .init([.privacy], .onIsLooser(default: es.dedupe.history)),
            // The institution's default for new person senders ("Never send to AI" here stays).
            ConfigKeys.orgPreset: .init([.privacy], .perEntry),
            ConfigKeys.orgCustom: .init([.privacy], .perEntry),
        ]
    }()

    /// What each scalar key accepts on import (`SettingsValueRule`; the structured keys — senders,
    /// accounts, criteria, the institution, paths — are validated by the importer, the string keys
    /// by the app's loaders; `SettingsRegistryLintTests` classifies every transferable key).
    package static let valueRules: [String: SettingsValueRule] = {
        var r: [String: SettingsValueRule] = [:]
        for key in ["menubar.showCount", "metadata.lookup", "plan.autoMarkDone", "reminder.enabled", "reminder.whenEmpty",
                    "agent.allowNewCategories", "agent.autoRead", "agent.notifyDone", MailSettings.Keys.prefillNotes,
                    MailSettings.Keys.notifyNewRequests, MailSettings.Keys.includeInDailyReminder, "panel.visible",
                    "panel.expandOnDrag", "panel.showTodayOnHover", DedupeSettings.Keys.enabled, DedupeSettings.Keys.history] {
            r[key] = .bool
        }
        r["plan.dailyBudget"] = .int(0...1_440)                 // minutes a day
        r["plan.readingWeekdays"] = .intList(1...7)
        r["plan.cutoffHour"] = .int(0...24)
        r["reminder.hour"] = .int(0...23)
        r["reminder.minute"] = .int(0...59)
        r["agent.textBudget"] = .int(1_000...2_000_000)         // characters per paper
        r[AssistSettings.Keys.qaTextBudget] = .int(10_000...400_000)   // characters per question (the loader's clamp)
        r[AssistSettings.Keys.qaMultiMax] = .int(AssistSettings.qaMultiMaxRange)   // papers in one Ask window (the stepper's range)
        r[AssistSettings.Keys.explainAskBeforeSend] = .bool
        r[AssistSettings.Keys.explainHistoryDays] = .int(1...3_650)    // days (the loader's clamp)
        // Seconds an idle Claude may wait: the switch's two values only (Settings ▸ Explain "Keep
        // Claude ready": off 0, on 180 — the approved 3 minutes; phase-3 fix F7).
        r[AssistSettings.Keys.keepWarm] = .intChoice([0, ClaudeAssistBackend.maxKeepWarmSeconds])
        r[AssistSettings.Keys.dailySoftCap] = .int(1...1_000)          // turns a day before "Continue?" (the loader's clamp)
        r[MailSettings.Keys.syncMinutes] = .int(-1...10_080)    // ≤ 0 manual only; at most a week
        r[MailSettings.Keys.maxAttachmentMB] = .int(1...2_048)
        r[MailSettings.Keys.retentionDays] = .int(-1...36_500)  // ≤ 0 keeps the text
        r[MailSettings.Keys.triageDailyMax] = .int(0...10_000)
        r[MailSettings.Keys.triageBodyCap] = .int(0...1_000_000)
        r["panel.edgeYFraction"] = .number(0...1)
        r["panel.idleOpacity"] = .number(0...1)
        return r
    }()

    /// The human label of every registry key, in both UI languages (`SettingsRegistryLintTests`).
    static let labels: [String: LocalizedText] = {
        func t(_ en: String, _ zh: String) -> LocalizedText { LocalizedText(en: en, zh: zh) }
        return [
            // Profile & institution
            ConfigKeys.profileField: t("Research field", "研究领域"),
            ConfigKeys.profileStage: t("Career stage", "职业阶段"),
            ConfigKeys.profileReaderDescription: t("Reader description", "读者描述"),
            ConfigKeys.orgPreset: t("Institution", "机构"),
            ConfigKeys.orgCustom: t("Custom institution", "自定义机构"),
            // General
            "language": t("Language", "语言"),
            "menubar.showCount": t("Today's count in the menu bar", "菜单栏显示今日待读数量"),
            "pdf.opener": t("Open PDFs with", "打开 PDF 使用"),
            "metadata.lookup": t("Look up paper metadata online", "联网查询论文元数据"),
            "metadata.mailto": t("Crossref contact email", "Crossref 联系邮箱"),
            // Plan & reminder
            "plan.dailyBudget": t("Daily reading budget", "每日阅读预算"),
            "plan.readingWeekdays": t("Reading days", "阅读日"),
            "plan.cutoffHour": t("Daily cutoff", "当天截止"),
            "plan.autoMarkDone": t("Mark as read when the checklist is done", "清单全部勾选后自动标记为已读"),
            "reminder.enabled": t("Daily reminder", "每日提醒"),
            "reminder.hour": t("Reminder time (hour)", "提醒时间（时）"),
            "reminder.minute": t("Reminder time (minute)", "提醒时间（分）"),
            "reminder.whenEmpty": t("Remind me even when nothing is left to read", "无待读时也提醒"),
            // AI reading
            "agent.provider": t("Reading service", "解读服务"),
            "agent.model": t("Claude model", "Claude 模型"),
            "agent.codexModel": t("ChatGPT model", "ChatGPT 模型"),
            "agent.effort": t("Effort", "思考强度"),
            "agent.textBudget": t("Text sent per paper", "每篇发送的文本上限"),
            "agent.allowNewCategories": t("Let AI create categories", "允许 AI 新建分类"),
            "agent.autoRead": t("Read new papers automatically", "自动解读新论文"),
            "agent.notifyDone": t("Notify when AI finishes a paper", "AI 解读完成时通知"),
            "agent.cliPath": t("Claude Code program path", "Claude Code 程序路径"),
            "agent.codexPath": t("Codex program path", "Codex 程序路径"),
            // Library
            "library.importMode": t("When importing", "导入方式"),
            DedupeSettings.Keys.enabled: t("Check new papers against your library", "新论文与资料库比对查重"),
            DedupeSettings.Keys.sensitivity: t("Duplicate check sensitivity", "查重灵敏度"),
            DedupeSettings.Keys.history: t("Remember papers you removed", "记住已删除的论文"),
            DedupeSettings.Keys.aiAuto: t("AI duplicate check runs by itself", "AI 查重自动运行"),
            AssistSettings.Keys.qaDepth: t("Default answer depth for questions", "提问的默认回答深度"),
            AssistSettings.Keys.qaLang: t("Answer language for questions", "提问的回答语言"),
            AssistSettings.Keys.qaTextBudget: t("Paper text sent per question", "每次提问发送的论文文字"),
            AssistSettings.Keys.qaMultiMax: t("Papers per question, at most", "一次提问最多几篇论文"),
            AssistSettings.Keys.explainLang: t("Explanation language", "讲解语言"),
            AssistSettings.Keys.explainDepth: t("Default model for explanations", "讲解的默认模型"),
            AssistSettings.Keys.explainHotkey: t("Explain shortcut", "讲解快捷键"),
            AssistSettings.Keys.explainDefaultMode: t("What the Explain shortcut opens", "讲解快捷键打开的方式"),
            AssistSettings.Keys.explainAskBeforeSend: t("Ask before every explanation is sent", "每次讲解发送前先问我"),
            AssistSettings.Keys.explainHistoryDays: t("Days explanations are kept", "讲解记录保留天数"),
            AssistSettings.Keys.keepWarm: t("Keep Claude ready while Explain is open", "讲解打开时让 Claude 预先就绪"),
            AssistSettings.Keys.dailySoftCap: t("Explain & Ask turns a day before asking", "讲解与问答每天超过多少次先问我"),
            AssistSettings.Keys.mode: t("Explain & Ask on or off", "讲解与问答开关"),
            AssistSettings.Keys.consentVersion: t("Explain & Ask consent", "讲解与问答的同意记录"),
            "library.path": t("Library location", "论文库位置"),
            ConfigKeys.importLastFolder: t("Last import folder", "上次导入的文件夹"),
            // Mail senders & criteria
            MailSettings.Keys.senders: t("Sender list", "发件人列表"),
            MailSettings.Keys.criteria: t("Reading criteria", "阅读标准"),
            MailSettings.Keys.dateOrder: t("Date order", "日期顺序"),
            MailSettings.Keys.aiMode: t("Email triage", "邮件分拣方式"),
            MailSettings.Keys.triageProvider: t("Triage service", "分拣服务"),
            MailSettings.Keys.triageModelClaude: t("Triage Claude model", "分拣用 Claude 模型"),
            MailSettings.Keys.triageModelCodex: t("Triage ChatGPT model", "分拣用 ChatGPT 模型"),
            MailSettings.Keys.triageDailyMax: t("AI triage daily limit", "AI 分拣每日上限"),
            MailSettings.Keys.triageBodyCap: t("Email text sent to AI", "发送给 AI 的正文长度"),
            // Mail accounts
            MailSettings.Keys.syncMinutes: t("Check mail automatically", "自动检查邮件"),
            MailSettings.Keys.maxAttachmentMB: t("Largest attachment stored", "附件大小上限"),
            MailSettings.Keys.prefillNotes: t("“From email” line in paper notes", "论文笔记中的「来自邮件」"),
            MailSettings.Keys.notifyNewRequests: t("Notify me about new reading requests", "有新的阅读请求时通知我"),
            MailSettings.Keys.includeInDailyReminder: t("Emails in the daily reminder", "每日提醒中包含邮件"),
            MailSettings.Keys.retentionDays: t("Keep email text for", "邮件正文保留"),
            MailSettings.Keys.accounts: t("Mail accounts", "邮件账户"),
            ConfigKeys.mailCloudRoot: t("Cloud folder for mail", "邮件所在的云文件夹"),
            // Drop strip
            "panel.visible": t("Show the drop strip", "显示侧边悬浮条"),
            "panel.edge": t("Drop strip edge", "侧边悬浮条所在边缘"),
            "panel.edgeYFraction": t("Drop strip position", "侧边悬浮条位置"),
            "panel.idleOpacity": t("Drop strip opacity when idle", "侧边悬浮条闲置时的透明度"),
            "panel.expandOnDrag": t("Expand the drop strip while dragging files", "拖动文件时展开侧边悬浮条"),
            "panel.showTodayOnHover": t("Show today on hover", "悬停时显示今日清单"),
            // Never transferred (named in diagnostics and the allowlist's documentation)
            "agent.mode": t("AI reading on or off", "AI 解读开关"),
            "agent.failureTotals": t("AI failure counts", "AI 失败次数统计"),
            "agent.claude.argvVariant": t("Claude command-line variant", "Claude 命令行变体"),
            "agent.claude.argvVariantCLIVersion": t("Claude CLI version of that variant", "该变体对应的 Claude CLI 版本"),
            "setup.completed": t("Setup finished", "设置已完成"),
            "general.launchAtLogin": t("Open at login", "登录时打开"),
            "panel.screenID": t("Drop strip display", "侧边悬浮条所在显示器"),
            "reminder.lastDeliveredDay": t("Last reminder delivered", "上次发送提醒的日期"),
            "reminder.scheduledFires": t("Scheduled reminders", "已排定的提醒"),
            MailSettings.Keys.enabled: t("Mail on or off", "邮件开关"),
            ConfigKeys.libraryPendingAction: t("Pending library change", "待执行的论文库更改"),
            ConfigKeys.libraryPreviousPath: t("Previous library location", "之前的论文库位置"),
            ConfigKeys.migrationVersion: t("Settings migration version", "设置迁移版本"),
            ConfigKeys.origin: t("Install origin", "安装来源"),
            ConfigKeys.migratedAt: t("Settings migrated at", "设置迁移时间"),
            ConfigKeys.migrationNote: t("Settings migration note", "设置迁移备注"),
            ConfigKeys.onboardingVersion: t("Setup Assistant version", "设置助手版本"),
            ConfigKeys.onboardingCompletedAt: t("Setup Assistant finished at", "设置助手完成时间"),
            ConfigKeys.onboardingAIDecision: t("Setup Assistant AI choice", "设置助手中的 AI 选择"),
            ConfigKeys.onboardingMailDecision: t("Setup Assistant mail choice", "设置助手中的邮件选择"),
            ConfigKeys.onboardingLegacy: t("Earlier install noted", "已识别的旧版安装"),
            ConfigKeys.guideChecklistDismissed: t("Getting Started hidden", "已隐藏入门清单"),
            ConfigKeys.guideSkipped: t("Skipped Getting Started items", "已跳过的入门项目"),
            ConfigKeys.guideManualDone: t("Getting Started items marked done", "已手动完成的入门项目"),
            ConfigKeys.guideActivity: t("First uses for Getting Started", "入门清单记录的首次使用"),
            ConfigKeys.transferLastExportedAt: t("Settings last exported", "上次导出设置的时间"),
            ConfigKeys.transferImportedAt: t("Settings last imported", "上次导入设置的时间"),
        ]
    }()

    package static func entry(_ key: String) -> SettingsKeyEntry? {
        entries.first { $0.key == key }
    }

    /// The human label of `key` in `lang` (nil: not a registry key).
    package static func label(_ key: String, _ lang: UILang) -> String? {
        guard let e = entry(key), !e.label(lang).isEmpty else { return nil }
        return e.label(lang)
    }

    /// Keys that sat in another section in files written by earlier builds (the criteria, the date
    /// order and the triage preferences were filed under Mail accounts): an import still reads
    /// them there — that section's checkbox decides — and files them under their section now.
    package static let formerSections: [String: SettingsSection] = [
        MailSettings.Keys.criteria: .mailAccounts, MailSettings.Keys.dateOrder: .mailAccounts,
        MailSettings.Keys.aiMode: .mailAccounts, MailSettings.Keys.triageProvider: .mailAccounts,
        MailSettings.Keys.triageModelClaude: .mailAccounts, MailSettings.Keys.triageModelCodex: .mailAccounts,
        MailSettings.Keys.triageDailyMax: .mailAccounts, MailSettings.Keys.triageBodyCap: .mailAccounts,
    ]

    /// Whether a file's `section` may hold `key` (its registry section, or where an earlier build
    /// filed it).
    package static func section(_ section: SettingsSection, mayHold key: String) -> Bool {
        guard let e = entry(key) else { return false }
        return e.section == section || formerSections[key] == section
    }

    /// Whether `key` may ever travel (listed and not `never`; `mail.notify.*` and every unlisted
    /// key never do).
    package static func isTransferable(_ key: String) -> Bool {
        guard !key.hasPrefix("mail.notify."), let e = entry(key) else { return false }
        return e.keyClass != .never
    }
}
