import Foundation
import Testing
@testable import PaperDeckCore
@testable import PaperDeckConfig

/// The settings allowlist (`SettingsRegistry`), enumerated:
/// - portability verification regression #5: every key has a human label in en and zh, so the
///   import / export sheets and the CLI never show a raw key name (`L.Transfer.keyLabel` reads the
///   registry; it used to fall back to the key for any key it didn't list — `mail.aiMode`,
///   `mail.triageDailyMax`…, which lab setup files carry);
/// - regression #2: every privacy- or quota-sensitive key carries `sensitivity` (an import only
///   tightens it without the user's opt-in), and every other transferable key was reviewed as
///   neither — a new key fails here until it is classified; the same for every field of a sender
///   rule and of a mail account (lists compared per entry).
@Suite struct SettingsRegistryLintTests {
    /// The keys an import must never loosen silently (the report's list and the review's additions).
    static let sensitive: Set<String> = [
        // The report's list.
        MailSettings.Keys.aiMode, MailSettings.Keys.triageDailyMax, MailSettings.Keys.triageBodyCap,
        MailSettings.Keys.maxAttachmentMB, MailSettings.Keys.senders, MailSettings.Keys.notifyNewRequests,
        "agent.autoRead", MailSettings.Keys.retentionDays,
        // How much of the plan and the user's text is used, how often mail is fetched, online lookups,
        // the institution's default for people.
        MailSettings.Keys.triageModelClaude, MailSettings.Keys.triageModelCodex, MailSettings.Keys.syncMinutes,
        "agent.textBudget", "agent.effort", "agent.model", "agent.codexModel", "metadata.lookup",
        ConfigKeys.orgPreset, ConfigKeys.orgCustom,
        // Per entry: an account turned off here, its look-back (`everyFieldOfASenderOrAnAccountIsClassified`).
        MailSettings.Keys.accounts,
        // The integration round: AI triage sent to another AI service; remembering removed papers.
        MailSettings.Keys.triageProvider, DedupeSettings.Keys.history,
        // Phase 2 (Ask): the default depth (Thorough = the larger model), the paper text per question.
        AssistSettings.Keys.qaDepth, AssistSettings.Keys.qaTextBudget,
        // Phase 3 (Explain): its default depth, the shared daily limit before "Continue?", the
        // confirmation before every send (off is looser), how long explanations stay on this Mac.
        AssistSettings.Keys.explainDepth, AssistSettings.Keys.dailySoftCap, AssistSettings.Keys.explainAskBeforeSend,
        AssistSettings.Keys.explainHistoryDays,
    ]

    /// Transferable keys reviewed as neither privacy- nor quota-sensitive (why, where it isn't obvious).
    static let reviewedNotSensitive: Set<String> = [
        ConfigKeys.profileField, ConfigKeys.profileStage,
        ConfigKeys.profileReaderDescription,           // confirmed on its own ("Use this description")
        "language", "menubar.showCount", "pdf.opener",
        "metadata.mailto",                              // personal: exported only on request, a hint on import
        "plan.dailyBudget", "plan.readingWeekdays", "plan.cutoffHour", "plan.autoMarkDone",
        "reminder.enabled", "reminder.hour", "reminder.minute", "reminder.whenEmpty",
        "agent.provider",                               // a choice of service, not more of it; never switched while AI reading is on
        "agent.allowNewCategories", "agent.notifyDone",
        "agent.cliPath", "agent.codexPath",             // hints: confirmed, dropped when missing here
        "library.importMode", "library.path", ConfigKeys.importLastFolder,
        MailSettings.Keys.criteria, MailSettings.Keys.dateOrder,
        MailSettings.Keys.prefillNotes,                 // the email's sender / subject in the user's own notes
        MailSettings.Keys.includeInDailyReminder,       // a count of emails, no content
        ConfigKeys.mailCloudRoot,                       // a hint: confirmed, only a root this Mac has
        "panel.visible", "panel.edge", "panel.edgeYFraction", "panel.idleOpacity", "panel.expandOnDrag",
        "panel.showTodayOnHover",
        DedupeSettings.Keys.enabled, DedupeSettings.Keys.sensitivity,   // local only: nothing is sent or kept longer
        AssistSettings.Keys.qaLang,                     // the language of an answer, not more of it
        AssistSettings.Keys.qaMultiMax,                 // the user picks the papers each time; the text budget is shared
        AssistSettings.Keys.explainLang,                // the language of an explanation, not more of it
        AssistSettings.Keys.explainHotkey, AssistSettings.Keys.explainDefaultMode,   // how Explain opens; every turn still needs a gesture
        AssistSettings.Keys.keepWarm,                   // an idle Claude process sends nothing and uses no quota (spike Q3)
    ]

    static func hasCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    // MARK: Labels (regression #5)

    @Test func everyKeyHasAnEnglishAndAChineseLabel() {
        for e in SettingsRegistry.entries {
            let en = e.label.en, zh = e.label.zh
            #expect(!en.trimmingCharacters(in: .whitespaces).isEmpty && !zh.trimmingCharacters(in: .whitespaces).isEmpty, "\(e.key)")
            #expect(en != e.key && zh != e.key && !en.contains(e.key) && !zh.contains(e.key), "\(e.key): a raw key name")
            #expect(!Self.hasCJK(en), "\(e.key): en label \(en)")
            #expect(Self.hasCJK(zh), "\(e.key): zh label \(zh) is not Chinese")
            // Never a dotted identifier ("mail.aiMode") in place of words.
            for label in [en, zh] {
                #expect(label.range(of: #"\b[a-z]+\.[a-zA-Z]+\b"#, options: .regularExpression) == nil, "\(e.key): \(label)")
            }
            #expect(SettingsRegistry.label(e.key, .en) == en && SettingsRegistry.label(e.key, .zh) == zh)
        }
        #expect(SettingsRegistry.label("made.up", .en) == nil)
    }

    @Test func labelsAreUniqueInEachLanguage() {
        for lang in UILang.allCases {
            let labels = SettingsRegistry.entries.map { $0.label(lang) }
            let dupes = Dictionary(grouping: labels, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
            #expect(dupes.isEmpty, "\(lang.rawValue): \(dupes)")
        }
    }

    /// The app's `L.Transfer.keyLabel` (the sheets, the CLI) reads the registry and has no raw-key
    /// fallback (the app target isn't linked by the tests: its source is read).
    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func theAppsKeyLabelReadsTheRegistry() throws {
        let source = try String(contentsOf: LintRepo.url("Sources/PaperDeck/App/L10n+settings.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "static func keyLabel(_ key: String) -> String {"))
        let body = String(source[start.upperBound...].prefix { $0 != "}" })
        #expect(body.contains("SettingsRegistry.label(key, L.lang)"), "\(body)")
        #expect(!body.contains("return key") && !body.contains("?? key"), "\(body)")
        // The CLI's dropped-path warning names the setting, not its key.
        let warning = try #require(source.range(of: "case .cliPathDropped(let key):"))
        #expect(source[warning.upperBound...].prefix(80).contains("keyLabel(key)"))
    }

    // MARK: Sensitivity (regression #2)

    @Test func everyPrivacyOrQuotaKeyIsTightenOnly() {
        for key in Self.sensitive {
            let e = SettingsRegistry.entry(key)
            #expect(e?.tightensOnly == true && e?.keyClass != .never, "\(key) must carry a sensitivity")
        }
        let transferable = Set(SettingsRegistry.entries.filter { $0.keyClass != .never }.map(\.key))
        let marked = Set(SettingsRegistry.entries.filter(\.tightensOnly).map(\.key))
        #expect(marked == Self.sensitive, "marked but not listed: \(marked.subtracting(Self.sensitive).sorted())")
        // Every transferable key is classified one way or the other.
        let unclassified = transferable.subtracting(Self.sensitive).subtracting(Self.reviewedNotSensitive)
        #expect(unclassified.isEmpty, "classify as sensitive or not: \(unclassified.sorted())")
        #expect(Self.sensitive.isDisjoint(with: Self.reviewedNotSensitive))
        #expect(Self.reviewedNotSensitive.isSubset(of: transferable), "\(Self.reviewedNotSensitive.subtracting(transferable).sorted())")
        for e in SettingsRegistry.entries where e.tightensOnly {
            #expect(!(e.sensitivity?.concerns.isEmpty ?? true), "\(e.key): privacy, quota or both")
        }
    }

    /// The fields of the per-entry keys' entries reviewed as neither privacy- nor quota-sensitive
    /// (the guarded ones are the importer's: `SettingsImporter.guardedSenderFields` / `guardedAccountFields`).
    static let reviewedSenderFields: Set<String> = [
        "id", "pattern", "label",
        "kind",                     // compared with the AI policy (`aiLooseness`: an alert's always < a person's)
        "defaultPriority", "defaultCategory", "useDueDateAsDDL",
    ]
    static let reviewedAccountFields: Set<String> = [
        "id", "kind", "displayName", "folderPath", "imapPreset", "host", "port", "username", "mailbox", "source",
    ]

    /// Every field of a sender rule and of a mail account is guarded (an import never loosens it for
    /// an entry this Mac has) or was reviewed as neither — a new field fails here until classified.
    @Test func everyFieldOfASenderOrAnAccountIsClassified() {
        let sender = Set(Mirror(reflecting: SenderRule(pattern: "@x.example", kind: .alert)).children.compactMap(\.label))
        let account = Set(Mirror(reflecting: MailAccount(kind: .imap, displayName: "x")).children.compactMap(\.label))
        let guardedSender = Set(SettingsImporter.guardedSenderFields.map(\.rawValue))
        let guardedAccount = Set(SettingsImporter.guardedAccountFields.map(\.rawValue))
        #expect(sender.subtracting(guardedSender).subtracting(Self.reviewedSenderFields).isEmpty,
                "classify: \(sender.subtracting(guardedSender).subtracting(Self.reviewedSenderFields).sorted())")
        #expect(account.subtracting(guardedAccount).subtracting(Self.reviewedAccountFields).isEmpty,
                "classify: \(account.subtracting(guardedAccount).subtracting(Self.reviewedAccountFields).sorted())")
        #expect(guardedSender.isSubset(of: sender) && guardedAccount.isSubset(of: account))
        #expect(Self.reviewedSenderFields.isSubset(of: sender) && Self.reviewedAccountFields.isSubset(of: account))
        #expect(guardedSender.isDisjoint(with: Self.reviewedSenderFields) && guardedAccount.isDisjoint(with: Self.reviewedAccountFields))
        #expect(Set(ImportEntryField.allCases.map(\.rawValue)) == guardedSender.union(guardedAccount))
        // Both lists are compared per entry by the importer.
        #expect(SettingsRegistry.entry(MailSettings.Keys.senders)?.sensitivity?.order == .perEntry)
        #expect(SettingsRegistry.entry(MailSettings.Keys.accounts)?.sensitivity?.order == .perEntry)
    }

    /// The registry's defaults are what the app reads while a key is absent (an empty domain), so
    /// "this Mac's value" of a fresh Mac is right.
    @Test func theDefaultsAreTheEnginesDefaults() throws {
        let scratch = ScratchDefaults("registry-defaults")
        defer { scratch.drop() }
        let mail = MailSettings.load(from: scratch.defaults)
        let engine = EngineSettings.load(from: scratch.defaults)
        let expected: [String: JSONValue] = [
            MailSettings.Keys.aiMode: .string(mail.aiMode.rawValue),
            MailSettings.Keys.triageDailyMax: .number(Double(mail.triageDailyMax)),
            MailSettings.Keys.triageBodyCap: .number(Double(mail.triageBodyCap)),
            MailSettings.Keys.triageModelClaude: .string(mail.triageModelClaude),
            MailSettings.Keys.triageModelCodex: .string(mail.triageModelCodex),
            MailSettings.Keys.maxAttachmentMB: .number(Double(mail.maxAttachmentMB)),
            MailSettings.Keys.syncMinutes: .number(Double(mail.syncMinutes)),
            MailSettings.Keys.notifyNewRequests: .bool(mail.notifyNewRequests),
            MailSettings.Keys.retentionDays: .number(Double(mail.retentionDays)),
            "agent.autoRead": .bool(engine.autoReadNewPapers),
            "agent.textBudget": .number(Double(engine.textBudget)),
            "agent.effort": .string(engine.agentEffort),
            "agent.model": .string(engine.agentModel),
            "agent.codexModel": .string(engine.codexModel),
            "metadata.lookup": .bool(engine.metadataLookup),
            DedupeSettings.Keys.history: .bool(engine.dedupe.history),
            AssistSettings.Keys.qaDepth: .string(engine.assist.qaDepth.rawValue),
            AssistSettings.Keys.qaTextBudget: .number(Double(engine.assist.qaTextBudget)),
            AssistSettings.Keys.explainDepth: .string(engine.assist.explainDepth.rawValue),
            AssistSettings.Keys.dailySoftCap: .number(Double(engine.assist.dailySoftCap)),
            AssistSettings.Keys.explainAskBeforeSend: .bool(engine.assist.explainAskBeforeSend),
            AssistSettings.Keys.explainHistoryDays: .number(Double(engine.assist.explainHistoryDays)),
        ]
        // Compared by the importer itself: per entry, or the AI service (`mail.triageProvider`).
        func byImporter(_ o: SettingsSensitivity.Order) -> Bool { o == .perEntry || o == .provider }
        for e in SettingsRegistry.entries {
            guard let s = e.sensitivity, !byImporter(s.order) else { continue }
            #expect(s.effective(nil) == expected[e.key], "\(e.key)")
            // Its own default is never looser than itself.
            if let d = s.effective(nil) { #expect(!s.isLooser(d, than: nil), "\(e.key)") }
        }
        #expect(Set(expected.keys) == Set(SettingsRegistry.entries.filter { $0.sensitivity.map { !byImporter($0.order) } ?? false }.map(\.key)))
        // A ranked key's default is one of its known values.
        for e in SettingsRegistry.entries {
            if case .ranked(let list, let d)? = e.sensitivity?.order { #expect(list.contains(d), "\(e.key)") }
        }
    }

    // MARK: Value rules (integration round: never write 1e300)

    /// Keys whose values the importer validates itself (lists, the criteria, the institution, paths)
    /// or the app's loaders check (a string a loader doesn't know falls back to its default).
    static let validatedElsewhere: Set<String> = [
        MailSettings.Keys.senders, MailSettings.Keys.accounts, MailSettings.Keys.criteria, ConfigKeys.orgCustom,
        ConfigKeys.orgPreset, ConfigKeys.profileField, ConfigKeys.profileStage, ConfigKeys.profileReaderDescription,
        "library.path", ConfigKeys.importLastFolder, "agent.cliPath", "agent.codexPath", ConfigKeys.mailCloudRoot,
        MailSettings.Keys.triageProvider,
        // Strings.
        "language", "pdf.opener", "metadata.mailto", "agent.provider", "agent.model", "agent.codexModel", "agent.effort",
        "library.importMode", MailSettings.Keys.dateOrder, MailSettings.Keys.aiMode, MailSettings.Keys.triageModelClaude,
        MailSettings.Keys.triageModelCodex, "panel.edge", DedupeSettings.Keys.sensitivity,
        AssistSettings.Keys.qaDepth, AssistSettings.Keys.qaLang,
        AssistSettings.Keys.explainLang, AssistSettings.Keys.explainDepth, AssistSettings.Keys.explainDefaultMode,
        // A dictionary: the loader reads only its two numbers, and `HotKeySpec.validate` refuses an
        // unusable combination before anything is registered.
        AssistSettings.Keys.explainHotkey,
    ]

    /// Every transferable key has a value rule (bools and numbers) or is validated elsewhere — a
    /// new numeric key fails here until it gets its range.
    @Test func everyTransferableKeyIsValidatedOnImport() {
        let transferable = Set(SettingsRegistry.entries.filter { $0.keyClass != .never }.map(\.key))
        let ruled = Set(SettingsRegistry.valueRules.keys)
        #expect(ruled.isSubset(of: transferable), "\(ruled.subtracting(transferable).sorted())")
        #expect(ruled.isDisjoint(with: Self.validatedElsewhere))
        let unclassified = transferable.subtracting(ruled).subtracting(Self.validatedElsewhere)
        #expect(unclassified.isEmpty, "give a value rule: \(unclassified.sorted())")
        // The app's defaults pass their own rules (a fresh Mac's values can be imported back).
        let defaults: [String: JSONValue] = [
            "plan.dailyBudget": .number(60), "plan.readingWeekdays": .array((1...7).map { .number(Double($0)) }),
            "plan.cutoffHour": .number(18), "reminder.hour": .number(11), "reminder.minute": .number(0),
            "agent.textBudget": .number(120_000), MailSettings.Keys.syncMinutes: .number(15),
            MailSettings.Keys.maxAttachmentMB: .number(50), MailSettings.Keys.retentionDays: .number(30),
            MailSettings.Keys.triageDailyMax: .number(30), MailSettings.Keys.triageBodyCap: .number(12_000),
            "panel.edgeYFraction": .number(0.5), "panel.idleOpacity": .number(0.6),
            AssistSettings.Keys.qaTextBudget: .number(80_000), AssistSettings.Keys.qaMultiMax: .number(10),
            AssistSettings.Keys.explainAskBeforeSend: .bool(false), AssistSettings.Keys.explainHistoryDays: .number(90),
            AssistSettings.Keys.keepWarm: .number(180), AssistSettings.Keys.dailySoftCap: .number(50),
        ]
        for (key, v) in defaults { #expect(SettingsRegistry.valueRules[key]?.validated(v) == v, "\(key)") }
        for (key, rule) in SettingsRegistry.valueRules {
            #expect(rule.validated(.number(1e300)) == nil, "\(key) accepts 1e300")
            #expect(rule.validated(.number(-.infinity)) == nil, "\(key) accepts -inf")
            #expect(rule.validated(.string("12")) == nil, "\(key) accepts a string")
        }
    }
}
