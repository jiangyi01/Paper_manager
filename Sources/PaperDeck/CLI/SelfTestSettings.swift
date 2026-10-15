import Foundation
import PaperDeckCore
import PaperDeckConfig

/// `--selftest settings [--lang en|zh] [--fixtures DIR]`: the app side of the configuration
/// layer (PORTABILITY_PLAN §5.5 tests) on scratch defaults files under $TMPDIR (removed
/// afterwards) — never the app's own domain, no engine, no keychain, nothing spawned:
/// - with an institution-neutral (generic) or custom organization no organization- or
///   field-dependent string names the legacy institution, and the default configuration still
///   gives the golden texts;
/// - `ConfigStore` setters write exactly their own keys and mirror the institution / field into
///   `LangStore`; `SettingsStore` carries `mail.dateOrder` like `MailSettings.load`;
/// - applying an import plan never writes `agent.mode`, `mail.enabled` or `setup.completed` and
///   gives the engine one debounced mail notice;
/// - mail templates: the legacy Power Automate account opens the Power Automate form, the source
///   table, today's seven chooser rows in order, the legacy default account name;
/// - the alert-preset menu of life sciences equals today's presets; the triage / connection-test
///   ChatGPT models; new person rules take the institution's people default;
/// - Settings ▸ Library ▸ Change…: the decision table and what confirming writes;
/// - never looser (portability fixes 2): a lab file's looser AI triage / cap / sender policy and
///   switch is kept stricter —
///   the sheet's line in words (en, zh), applying the plan leaves this Mac's values, ticking the
///   item writes the file's; every settings key has a label in both languages (no raw key).
///
/// Checks that need the configuration engine (PORTABILITY_PLAN S1) print `skipped` while
/// `ConfigResolver` still resolves every domain to the legacy configuration.
/// `--fixtures DIR` (default `Tests/PaperDeckCoreTests/Fixtures/config`): the synthetic legacy
/// domain and the golden strings, when present.
enum SelfTestSettings {
    static func run(_ a: CLIArgs) async -> Int32 {
        let lang = UILang(rawValue: a.value("--lang") ?? "en") ?? .en
        let store = LangStore.shared
        let saved = (store.lang, store.provider, store.org, store.field, store.importFolderExample)
        defer { (store.lang, store.provider, store.org, store.field, store.importFolderExample) = saved }
        store.lang = lang

        let fixtures = a.url("--fixtures") ?? URL(fileURLWithPath: "Tests/PaperDeckCoreTests/Fixtures/config", isDirectory: true)
        let c = Checker()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-selftest-settings-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let suites = Suites(root: scratch)
        defer { suites.removeAll() }

        let engineReady = configEngineReady(suites)
        c.note(["configEngine": engineReady ? "resolves keys" : "W0 stub (legacy only)"])

        strings(c, lang: lang, fixtures: fixtures, engineReady: engineReady)
        configStore(c, suites, engineReady: engineReady)
        initWrites(c, suites)
        await importPlans(c, suites, engineReady: engineReady)
        listImpacts(c, suites)
        keptStricter(c, suites)
        mailTemplates(c, fixtures: fixtures, lang: lang)
        presetsAndModels(c)
        libraryChange(c, suites, scratch: scratch)

        CLIRunner.line(["check": "settings", "lang": lang.rawValue, "passed": c.passed, "failed": c.failed,
                        "skipped": c.skipped, "ok": c.ok])
        print(c.ok ? "SELFTEST PASS" : "SELFTEST FAIL")
        return c.ok ? 0 : 1
    }

    // MARK: Harness

    final class Checker {
        private(set) var ok = true
        private(set) var passed = 0, failed = 0, skipped = 0
        func check(_ name: String, _ pass: Bool, _ extra: [String: Any?] = [:]) {
            var line: [String: Any?] = ["check": name, "ok": pass]
            line.merge(extra) { a, _ in a }
            CLIRunner.line(line)
            if pass { passed += 1 } else { failed += 1; ok = false }
        }
        /// A check that needs the configuration engine: enforced once it resolves keys.
        func check(_ name: String, needsEngine ready: Bool, _ pass: @autoclosure () -> Bool, _ extra: [String: Any?] = [:]) {
            guard ready else {
                skipped += 1
                CLIRunner.line(["check": name, "skipped": "needs the configuration engine (S1)"])
                return
            }
            check(name, pass(), extra)
        }
        func note(_ extra: [String: Any?]) { CLIRunner.line(extra) }
    }

    /// Path-named scratch defaults files (never the app's domain).
    final class Suites {
        let root: URL
        private var names: [String] = []
        init(root: URL) { self.root = root }
        func make(_ label: String) -> (name: String, defaults: UserDefaults)? {
            let name = root.appendingPathComponent("defaults/\(label)-\(names.count)").path
            try? FileManager.default.createDirectory(atPath: (name as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            guard let d = UserDefaults(suiteName: name) else { return nil }
            d.removePersistentDomain(forName: name)
            names.append(name)
            return (name, d)
        }
        func persisted(_ name: String) -> [String: Any] {
            UserDefaults(suiteName: name)?.persistentDomain(forName: name) ?? [:]
        }
        func removeAll() {
            for n in names { UserDefaults(suiteName: n)?.removePersistentDomain(forName: n) }
        }
    }

    /// Whether `ConfigResolver` reads the keys (S1) or is still the W0 legacy-only stub.
    static func configEngineReady(_ suites: Suites) -> Bool {
        guard let s = suites.make("probe") else { return false }
        s.defaults.set(OrganizationPresets.generic.id, forKey: ConfigKeys.orgPreset)
        s.defaults.set(FieldPresets.general.id, forKey: ConfigKeys.profileField)
        let snap = ConfigResolver.load(s.defaults, legacyFallback: true)
        return snap.organization.id == OrganizationPresets.generic.id && snap.field.id == FieldPresets.general.id
    }

    /// The legacy institution's names (from its preset: short name, the first word of its name,
    /// its mail domains' first label), as they must never appear for another organization.
    static let legacyNames: [String] = {
        guard let org = OrganizationPresets.preset(id: LegacyInstall.organizationID) else { return [] }
        var names = [org.shortName, org.name?.en.split(separator: " ").first.map(String.init)].compactMap { $0 }
        names += org.mail.knownSenderDomains.compactMap { $0.split(separator: ".").first.map(String.init) }
        return names.filter { $0.count >= 4 }
    }()

    static func namesLegacy(_ s: String) -> Bool {
        legacyNames.contains { s.range(of: $0, options: [.caseInsensitive]) != nil }
    }

    // MARK: Strings

    private static func strings(_ c: Checker, lang: UILang, fixtures: URL, engineReady: Bool) {
        // The default (legacy) configuration still says today's words.
        let golden = fixtures.appendingPathComponent("org-strings-v1.json")
        if let data = try? Data(contentsOf: golden),
           let fixture = try? JSONDecoder().decode(SelfTestStrings.Fixture.self, from: data),
           let expected = fixture.strings[lang.rawValue] {
            let now = SelfTestStrings.evaluate([lang])[lang.rawValue] ?? [:]
            let diff = expected.keys.filter { expected[$0] != now[$0] }.sorted()
            c.check("strings: the legacy configuration gives the golden texts", diff.isEmpty, ["differs": diff])
        } else {
            c.note(["skipped": "strings: golden fixture not found", "path": golden.path])
        }
        // Generic and custom organizations never name the legacy institution.
        c.check("strings: the legacy institution's names are known", legacyNames.count >= 3, ["names": legacyNames.count])
        let custom = OrganizationPresets.custom(name: "Contoso University", shortName: "Contoso",
                                                approvedAITools: ["Contoso Copilot"],
                                                policyURL: URL(string: "https://ai.contoso.example/policy"),
                                                peopleDefault: .never, oneDriveRootHint: nil)
        for (label, org) in [("generic", OrganizationPresets.generic), ("custom", custom)] {
            for l in UILang.allCases {
                let texts = SelfTestStrings.evaluate([l], org: org, field: FieldPresets.general)[l.rawValue] ?? [:]
                let named = texts.filter { namesLegacy($0.value) }.keys.sorted()
                c.check("strings: \(label) (\(l.rawValue)) names no legacy institution", needsEngine: engineReady,
                        named.isEmpty, ["keys": named])
                c.check("strings: \(label) (\(l.rawValue)) default account name keeps “Power Automate”",
                        (texts["org.paDefaultAccountName"] ?? "").contains("Power Automate"),
                        ["name": texts["org.paDefaultAccountName"]])
            }
        }
        // The custom short name is used.
        let customTexts = SelfTestStrings.evaluate([.en], org: custom, field: FieldPresets.general)["en"] ?? [:]
        c.check("strings: custom wording uses the short name", needsEngine: engineReady,
                customTexts.values.contains { $0.contains("Contoso") })
    }

    // MARK: ConfigStore / SettingsStore

    private static func configStore(_ c: Checker, _ suites: Suites, engineReady: Bool) {
        guard let s = suites.make("config") else { c.check("config: scratch defaults", false); return }
        let config = ConfigStore(defaults: s.defaults)
        c.check("config: init writes nothing", suites.persisted(s.name).isEmpty, ["keys": Array(suites.persisted(s.name).keys)])

        func written(_ action: () -> Void) -> Set<String> {
            let before = suites.persisted(s.name)
            action()
            let after = suites.persisted(s.name)
            return Set(after.keys.filter { key in
                guard let a = after[key] else { return false }
                guard let b = before[key] else { return true }
                return !(a as AnyObject).isEqual(b)
            }).union(Set(before.keys).subtracting(after.keys))
        }
        let cases: [(String, String, () -> Void)] = [
            ("fieldID", ConfigKeys.profileField, { config.fieldID = FieldPresets.general.id }),
            ("stage", ConfigKeys.profileStage, { config.stage = .postdoc }),
            ("readerOverride", ConfigKeys.profileReaderDescription, { config.readerOverride = "a single-cell biologist" }),
            ("organizationID", ConfigKeys.orgPreset, { config.organizationID = OrganizationPresets.generic.id }),
            ("customOrganization", ConfigKeys.orgCustom, {
                config.customOrganization = OrganizationPresets.custom(name: "Contoso University", shortName: "Contoso",
                                                                      approvedAITools: [], policyURL: nil,
                                                                      peopleDefault: .ask, oneDriveRootHint: nil)
            }),
            ("dateOrder", ConfigKeys.mailDateOrder, { config.dateOrder = .dmy }),
            ("importLastFolder", ConfigKeys.importLastFolder, { config.importLastFolder = "~/Papers to read" }),
            ("cloudRoot", ConfigKeys.mailCloudRoot, { config.cloudRoot = "OneDrive-Contoso" }),
            ("readerOverride = nil", ConfigKeys.profileReaderDescription, { config.readerOverride = nil }),
        ]
        for (name, key, action) in cases {
            let keys = written(action)
            c.check("config: \(name) writes exactly \(key)", keys == [key], ["written": keys.sorted()])
        }
        let custom = suites.persisted(s.name)[ConfigKeys.orgCustom] as? String ?? ""
        c.check("config: org.custom carries no texts", !custom.contains("\"texts\":{\"") && !custom.isEmpty, ["json": custom])
        c.check("config: LangStore mirrors the resolved institution and field",
                LangStore.shared.org == config.snapshot.organization && LangStore.shared.field == config.snapshot.field)
        c.check("config: LangStore mirrors the import folder",
                LangStore.shared.importFolderExample == "~/Papers to read")
        c.check("config: the resolved field follows profile.field", needsEngine: engineReady,
                config.snapshot.field.id == FieldPresets.general.id && LangStore.shared.field.id == FieldPresets.general.id)
        c.check("config: the resolved institution follows org.preset", needsEngine: engineReady,
                config.snapshot.organization.id == OrganizationPresets.generic.id)

        // SettingsStore: mail.dateOrder like MailSettings.load (absent → mdy; auto kept).
        guard let m = suites.make("mail") else { c.check("mail: scratch defaults", false); return }
        let fresh = SettingsStore(defaults: m.defaults, domain: m.name)
        c.check("mail: absent mail.dateOrder reads month first", fresh.mailSettings.dateOrder == .mdy
                && fresh.mailSettings == MailSettings.load(from: m.defaults))
        m.defaults.set(SlashDateOrder.auto.rawValue, forKey: MailSettings.Keys.dateOrder)
        let auto = SettingsStore(defaults: m.defaults, domain: m.name)
        c.check("mail: the settings snapshot carries mail.dateOrder",
                auto.mailSettings.dateOrder == .auto && auto.mailSettings == MailSettings.load(from: m.defaults))
        var notices: [MailSettingsNotice] = []
        auto.onMailSettingsChange = { notices.append($0) }
        let keys = written2(suites, m.name) { auto.mailDateOrder = .dmy }
        c.check("mail: the date-order picker writes exactly mail.dateOrder", keys == [MailSettings.Keys.dateOrder],
                ["written": keys.sorted()])
        auto.reloadMail()
        c.check("mail: reloadMail sees no change after its own write", notices.isEmpty || notices == [.edit])
    }

    // MARK: Import sheet: what happens to senders and accounts

    /// The import sheet names, before Import, which senders and accounts a file adds, replaces and
    /// keeps — and any of this Mac's it would remove (`SettingsImportSheet.listImpacts`).
    private static func listImpacts(_ c: Checker, _ suites: Suites) {
        typealias Sheet = SettingsImportSheet
        let a = SenderRule(id: "a", pattern: "a@example.edu", label: "A", kind: .advisor)
        let b = SenderRule(id: "b", pattern: "b@example.edu", label: "", kind: .person)
        var a2 = a
        a2.useDueDateAsDDL.toggle()             // not a privacy / quota field (automatic merge on is kept stricter)
        let cRule = SenderRule(id: "c", pattern: "@alerts.example.org", label: "Alerts", kind: .alert)
        let one = Sheet.impact("mail.senders", mine: [a, b], written: [a2, cRule], name: { $0.label.isEmpty ? $0.pattern : $0.label })
        c.check("import lists: add / replace / remove by id", one.added == ["Alerts"] && one.replaced == ["A"]
                    && one.kept.isEmpty && one.removed == ["b@example.edu"], ["impact": "\(one)"])
        let two = Sheet.impact("mail.senders", mine: [a, b], written: [a, a2, b, cRule], name: \.id)
        c.check("import lists: equal entries are kept, nothing removed, a duplicate id counts once",
                two.kept == ["a", "b"] && two.added == ["c"] && two.replaced.isEmpty && two.removed.isEmpty, ["impact": "\(two)"])

        // Through the planner: this Mac has an IMAP account and a sender; the file has another
        // account, the same sender changed and a new one.
        guard let src = suites.make("lists-src"), let dst = suites.make("lists-dst") else {
            c.check("import lists: scratch defaults", false)
            return
        }
        let here = MailAccount(id: "here", kind: .imap, displayName: "Lab Gmail", imapPreset: .gmail, host: "imap.gmail.com",
                               username: "me@example.com")
        let there = MailAccount(id: "there", kind: .imap, displayName: "Old Mac iCloud", imapPreset: .icloud,
                                host: "imap.mail.me.com", username: "old@example.com")
        dst.defaults.set(MailSettings.encode([here]), forKey: MailSettings.Keys.accounts)
        dst.defaults.set(MailSettings.encode([a]), forKey: MailSettings.Keys.senders)
        src.defaults.set(MailSettings.encode([there]), forKey: MailSettings.Keys.accounts)
        src.defaults.set(MailSettings.encode([a2, cRule]), forKey: MailSettings.Keys.senders)
        let home = FileManager.default.temporaryDirectory
        let bundle = SettingsExporter.export(PersistedDomain(suites.persisted(src.name)), sections: Set(SettingsSection.allCases),
                                             includePersonal: true, includeAddresses: true, home: home, roots: [],
                                             app: "PaperDeck selftest",
                                             now: Date(timeIntervalSince1970: 1_800_000_000))
        let current = PersistedDomain(suites.persisted(dst.name))
        let plan = SettingsImporter.plan(bundle, current: current, sections: Set(SettingsSection.allCases), keepPeopleAlways: false,
                                         acceptReaderDescription: false, home: home, roots: [])
        let impacts = Sheet.listImpacts(plan, current: current)
        let senders = impacts.first { $0.key == MailSettings.Keys.senders }
        let accounts = impacts.first { $0.key == MailSettings.Keys.accounts }
        c.check("import lists: the sheet lists the senders the file adds and replaces",
                senders?.added == ["Alerts"] && senders?.replaced == ["A"], ["senders": "\(String(describing: senders))"])
        // The planner merges: this Mac's own account is kept, nothing is removed.
        c.check("import lists: this Mac's account is kept (nothing removed)",
                accounts?.added == ["Old Mac iCloud"] && accounts?.kept == ["Lab Gmail"] && accounts?.replaced == []
                    && accounts?.removed == [] && senders?.removed == [],
                ["accounts": "\(String(describing: accounts))"])
        // The sheet's names are the planner's (`ImportPlan.merges`), and the by-id comparison agrees.
        let agree = [senders, accounts].allSatisfy { list in
            guard let list, let merge = plan.merges[list.key] else { return false }
            return list.added == merge.added && list.replaced == merge.replaced && list.kept == merge.kept
        }
        let derived = impacts.map { list -> Bool in
            let key = list.key
            guard case .string(let json)? = plan.writes[key] else { return false }
            let byID = key == MailSettings.Keys.senders
                ? Sheet.impact(key, mine: MailSettings.list(current.values[key] as? String, SenderRule.self, what: "sender"),
                               written: MailSettings.list(json, SenderRule.self, what: "sender"),
                               name: { $0.label.isEmpty ? $0.pattern : $0.label })
                : Sheet.impact(key, mine: MailSettings.list(current.values[key] as? String, MailAccount.self, what: "account"),
                               written: MailSettings.list(json, MailAccount.self, what: "account"),
                               name: { $0.displayName.isEmpty ? $0.id : $0.displayName })
            return byID == list
        }
        c.check("import lists: the sheet shows the planner's add / replace / keep; the by-id check agrees",
                agree && impacts.count == 2 && derived.allSatisfy { $0 }, ["merges": "\(plan.merges)"])
        let store = LangStore.shared
        let saved = store.lang
        defer { store.lang = saved }
        var texts: [String] = []
        for lang in UILang.allCases {
            store.lang = lang
            texts += [L.Transfer.listSummary("X", added: 1, replaced: 2, kept: 3), L.Transfer.listRemoved(["Y"]),
                      L.Transfer.listNames(.added, ["Z"]), L.Transfer.listNames(.replaced, ["Z"]), L.Transfer.listNames(.kept, ["Z"])]
        }
        let half = texts.count / 2
        c.check("import lists: the breakdown is worded in en and zh",
                zip(texts[..<half], texts[half...]).allSatisfy { $0 != $1 } && texts[0].contains("1") && texts[0].contains("3"))
    }

    // MARK: Never looser (portability fixes 2: regressions #2, #5)

    private static func keptStricter(_ c: Checker, _ suites: Suites) {
        let store = LangStore.shared
        let saved = store.lang
        defer { store.lang = saved }
        // Every key's label, both languages: words, never the key.
        var raw: [String] = []
        for lang in UILang.allCases {
            store.lang = lang
            for e in SettingsRegistry.entries {
                let label = L.Transfer.keyLabel(e.key)
                if label.isEmpty || label == e.key || label.contains(e.key) || label == L.Transfer.keyLabel("made.up") {
                    raw.append("\(lang.rawValue):\(e.key)")
                }
            }
        }
        c.check("never looser: every settings key has a label in en and zh", raw.isEmpty, ["raw": raw])
        // Every guarded field of a sender and of an account, as the sheet words it (en, zh).
        var fieldLines: [String: [String]] = [:]
        for lang in UILang.allCases {
            store.lang = lang
            for (key, fields, id) in [(MailSettings.Keys.senders, SettingsImporter.guardedSenderFields, "r1"),
                                      (MailSettings.Keys.accounts, SettingsImporter.guardedAccountFields, "a1")] {
                for f in fields {
                    let isAccount = key == MailSettings.Keys.accounts
                    let (mine, theirs): (JSONValue, JSONValue) = switch f {
                    case .aiPolicy: (.string("never"), .string("always"))
                    case .lookbackDays: (.number(14), .number(60))
                    case .kind: (.string(SenderKind.advisor.rawValue), .string(SenderKind.alert.rawValue))
                    case .server: (.string("me@example.com · imap.example.com:993"), .string("me@example.com · imap.example.org:993"))
                    case .enabled, .autoMerge, .autoDownload, .deleteProcessedFiles: (.bool(false), .bool(true))
                    }
                    let item = ImportLoosening(id: isAccount ? ImportLoosening.accountID(id, f) : ImportLoosening.senderID(id, f),
                                               key: key, section: isAccount ? .mailAccounts : .mailSenders, subject: "Lab", field: f,
                                               mine: mine, theirs: theirs, accepted: false)
                    fieldLines["\(lang.rawValue) \(key) \(f.rawValue)", default: []].append(SettingsImportSheet.keptStricterLine(item))
                }
            }
        }
        let flat = fieldLines.values.flatMap { $0 }
        let enAccount = fieldLines["en \(MailSettings.Keys.accounts) enabled"]?.first ?? ""
        let zhAccount = fieldLines["zh \(MailSettings.Keys.accounts) enabled"]?.first ?? ""
        c.check("never looser: every guarded sender / account field is worded, in en and zh",
                Set(flat).count == flat.count && !flat.contains { l in ImportEntryField.allCases.contains { l.contains($0.rawValue) } }
                    && !flat.contains { $0.contains("true") || $0.contains("false") || $0.contains("never") }
                    && enAccount.contains("Lab: Check this account — Off (file: On)") && zhAccount.contains("Lab：检查此账户 — 关（文件：开）")
                    && fieldLines["en \(MailSettings.Keys.accounts) lookbackDays"]?.first?.contains("14 days (file: 60 days)") == true,
                ["lines": fieldLines.keys.sorted().map { "\($0): \(fieldLines[$0]?.first ?? "")" }])
        // Integration round: a new sender taking over a stricter rule, AI triage on another service,
        // values out of range and the triage instructions — worded in en and zh, never a raw key.
        var guardLines: [String: [String]] = [:]
        for lang in UILang.allCases {
            store.lang = lang
            let overriding = ImportLoosening(id: ImportLoosening.newSenderID("news"), key: MailSettings.Keys.senders,
                                             section: .mailSenders, subject: "Lab news", field: .aiPolicy,
                                             mine: .string("never"), theirs: .string("always"), accepted: false, overrides: "Lab")
            let provider = ImportLoosening(id: MailSettings.Keys.triageProvider, key: MailSettings.Keys.triageProvider,
                                           section: .mailSenders, mine: .string("claude"), theirs: .string("codex"), accepted: false)
            guardLines[lang.rawValue] = [SettingsImportSheet.keptStricterLine(overriding), SettingsImportSheet.keptStricterLine(provider),
                                         L.Transfer.warning(.valueOutOfRange(MailSettings.Keys.triageDailyMax)),
                                         L.Transfer.warning(.entriesSkipped(MailSettings.Keys.accounts, 2)),
                                         L.Transfer.warning(.criteriaInstructionsNeedConfirm)]
        }
        let gEN = guardLines["en"] ?? [], gZH = guardLines["zh"] ?? []
        let rawKey = (gEN + gZH).contains { (line: String) -> Bool in
            line.contains("mail.") || line.contains("triageProvider") || line.contains("deleteProcessed")
        }
        c.check("never looser: the integration round's guards are worded, in en and zh",
                gEN.count == 5 && gZH.count == 5 && zip(gEN, gZH).allSatisfy { $0 != $1 }
                    && gEN[0].contains("Lab news (new, more specific than Lab)") && gZH[0].contains("比「Lab」更具体")
                    && gEN[1].contains("Claude") && gEN[1].contains("ChatGPT") && gEN[2].contains("AI triage daily limit")
                    && gZH[2].contains("AI 分拣每日上限") && !rawKey,
                ["en": gEN, "zh": gZH])
        store.lang = saved

        guard let dst = suites.make("looser-dst") else { c.check("never looser: scratch defaults", false); return }
        dst.defaults.set("heuristic_only", forKey: MailSettings.Keys.aiMode)
        dst.defaults.set(30, forKey: MailSettings.Keys.triageDailyMax)
        let pi = SenderRule(id: "pi", pattern: "pi@lab.example.edu", label: "PI", kind: .advisor, aiPolicy: .never,
                            autoDownload: false)
        dst.defaults.set(MailSettings.encode([pi]), forKey: MailSettings.Keys.senders)
        var piThere = pi
        piThere.aiPolicy = .always
        piThere.autoDownload = true
        let lab = SettingsBundle(exportedAt: Date(timeIntervalSince1970: 1_800_000_000), app: "PaperDeck selftest", sections: [
            SettingsSection.mailSenders.rawValue: .object([
                MailSettings.Keys.aiMode: .string("ai"), MailSettings.Keys.triageDailyMax: .number(200),
                MailSettings.Keys.senders: (try? JSONValue.from([piThere])) ?? .null,
                MailSettings.Keys.dateOrder: .string("dmy"),
            ]),
        ])
        let home = FileManager.default.temporaryDirectory
        func plan(_ accept: LooserAcceptance) -> ImportPlan {
            SettingsImporter.plan(lab, current: PersistedDomain(suites.persisted(dst.name)), sections: Set(SettingsSection.allCases),
                                  keepPeopleAlways: true, acceptReaderDescription: false, acceptLooser: accept, home: home, roots: [])
        }
        let kept = plan(.none)
        c.check("never looser: AI triage, the cap and a sender's policy and switch are kept stricter",
                kept.keptStricter.map(\.id) == [MailSettings.Keys.aiMode, ImportLoosening.senderID("pi"),
                                                ImportLoosening.senderID("pi", .autoDownload), MailSettings.Keys.triageDailyMax]
                    && kept.writes[MailSettings.Keys.aiMode] == nil && kept.writes[MailSettings.Keys.triageDailyMax] == nil,
                ["kept": kept.keptStricter.map(\.id), "writes": kept.writes.keys.sorted()])
        var lines: [UILang: [String]] = [:]
        for lang in UILang.allCases {
            store.lang = lang
            lines[lang] = kept.loosenings.map(SettingsImportSheet.keptStricterLine)
        }
        let en = lines[.en] ?? [], zh = lines[.zh] ?? []
        let rawWords = ["heuristic_only", "mail.", "\"ai\"", "always", "never", "autoDownload", "true", "false"]
        c.check("never looser: the sheet's kept-stricter lines are words, in en and zh",
                en.count == 4 && zh.count == 4 && zip(en, zh).allSatisfy { $0 != $1 }
                    && en[0].contains("Local rules only") && en[3].contains("30") && en[3].contains("200") && en[1].contains("PI")
                    && en[2].contains("PI: Store attachments automatically — Off (file: On)") && zh[2].contains("自动保存附件")
                    && zh.allSatisfy { $0.contains("保留更严格") } && !(en + zh).contains { l in rawWords.contains { l.contains($0) } },
                ["en": en, "zh": zh])
        store.lang = saved
        // Applying: this Mac's stricter values stay; the rest of the file is written.
        let settings = SettingsStore(defaults: dst.defaults, domain: dst.name)
        settings.onMailSettingsChange = { _ in }
        let n = settings.applyImport(kept)
        let after = suites.persisted(dst.name)
        c.check("never looser: applying the plan leaves this Mac's stricter values",
                n == 1 && after[MailSettings.Keys.aiMode] as? String == "heuristic_only"
                    && (after[MailSettings.Keys.triageDailyMax] as? Int) == 30 && after[MailSettings.Keys.dateOrder] as? String == "dmy"
                    && MailSettings.list(after[MailSettings.Keys.senders] as? String, SenderRule.self, what: "s").first
                        .map { $0.aiPolicy == .never && !$0.autoDownload } == true,
                ["written": n])
        // The sheet's own plan: nothing ticked keeps every item stricter; a ticked one is written.
        let sheetDomain = PersistedDomain(suites.persisted(dst.name))
        func sheet(_ ticked: Set<String>) -> ImportPlan {
            SettingsImportSheet.plan(lab, current: sheetDomain, sections: Set(SettingsSection.allCases), keepPeopleAlways: false,
                                     acceptReader: false, ticked: ticked, home: home, roots: [])
        }
        let untouched = sheet([]), tickedCap = sheet([MailSettings.Keys.triageDailyMax])
        c.check("never looser: the import sheet keeps every item stricter until its box is ticked",
                untouched.keptStricter.count == 4 && untouched.writes[MailSettings.Keys.aiMode] == nil
                    && tickedCap.writes[MailSettings.Keys.triageDailyMax] == .number(200) && tickedCap.keptStricter.count == 3,
                ["kept": untouched.keptStricter.map(\.id)])
        // The CLI's dry run: kept stricter unless --accept-looser.
        c.check("never looser: the CLI keeps stricter values unless --accept-looser",
                ConfigCLI.looserAcceptance(CLIArgs(["PaperDeck", "--import-settings", "in.json", "--dry-run"])) == .none
                    && ConfigCLI.looserAcceptance(CLIArgs(["PaperDeck", "--import-settings", "in.json", "--dry-run", "--accept-looser"])) == .all)
        // Ticking one item writes only that one.
        let one = plan(.only([MailSettings.Keys.triageDailyMax]))
        let ticked = one.loosenings.first { $0.id == MailSettings.Keys.triageDailyMax }.map(SettingsImportSheet.keptStricterLine)
        c.check("never looser: a ticked item writes the file's value, the others stay",
                one.writes[MailSettings.Keys.triageDailyMax] == .number(200) && one.writes[MailSettings.Keys.aiMode] == nil
                    && one.writes[MailSettings.Keys.senders] == nil
                    && ticked?.hasPrefix(L.Transfer.looserAccepted("", mine: "", theirs: "").prefix(5)) == true,
                ["line": ticked])
    }

    // MARK: Launch-time stores write nothing (not even the values already there)

    /// A scratch defaults file that records every write call (`set…` / `removeObject`), including
    /// ones that store the value already there — which a before/after comparison of the persisted
    /// domain can't see. Reads pass through.
    nonisolated final class RecordingDefaults: UserDefaults {
        private(set) var writes: [String] = []
        private func note(_ key: String) { writes.append(key) }
        override func set(_ value: Any?, forKey key: String) { note(key); super.set(value, forKey: key) }
        override func set(_ value: Int, forKey key: String) { note(key); super.set(value, forKey: key) }
        override func set(_ value: Bool, forKey key: String) { note(key); super.set(value, forKey: key) }
        override func set(_ value: Double, forKey key: String) { note(key); super.set(value, forKey: key) }
        override func set(_ value: Float, forKey key: String) { note(key); super.set(value, forKey: key) }
        override func set(_ url: URL?, forKey key: String) { note(key); super.set(url, forKey: key) }
        override func removeObject(forKey key: String) { note(key); super.removeObject(forKey: key) }
    }

    /// `ConfigStore` and `GuideStore` are created at every launch: on an empty domain and on
    /// populated ones (a preset institution with every config key; a custom institution) their
    /// inits make no write call at all — the `reloading` / `loading` guards, not equal values,
    /// keep the domain untouched.
    private static func initWrites(_ c: Checker, _ suites: Suites) {
        let custom = OrganizationPresets.custom(name: "Contoso University", shortName: "Contoso", approvedAITools: [],
                                                policyURL: nil, peopleDefault: .ask, oneDriveRootHint: nil)
        let populated: [String: Any] = [
            ConfigKeys.origin: "legacy", ConfigKeys.orgPreset: LegacyInstall.organizationID,
            ConfigKeys.profileField: LegacyInstall.fieldID, ConfigKeys.profileStage: CareerStage.postdoc.rawValue,
            ConfigKeys.profileReaderDescription: "a single-cell biologist", ConfigKeys.mailDateOrder: SlashDateOrder.mdy.rawValue,
            ConfigKeys.importLastFolder: "~/Papers to read", ConfigKeys.mailCloudRoot: "OneDrive-Contoso",
            ConfigKeys.onboardingAIDecision: "claude", ConfigKeys.onboardingMailDecision: "configured",
            ConfigKeys.guideChecklistDismissed: true, ConfigKeys.guideSkipped: ["widget"],
            ConfigKeys.guideManualDone: ["getting-started/widget"],
            ConfigKeys.guideActivity: [GuideActivityKind.panelDrop.rawValue: 1_790_000_000.0],
        ]
        var customDomain = populated
        customDomain[ConfigKeys.orgPreset] = "custom"
        customDomain[ConfigKeys.orgCustom] = ConfigResolver.encodeCustom(custom)
        for (label, seed) in [("empty", [String: Any]()), ("populated", populated), ("custom institution", customDomain)] {
            guard let s = suites.make("init-writes"), let rec = RecordingDefaults(suiteName: s.name) else {
                c.check("init writes: scratch defaults (\(label))", false)
                continue
            }
            for (k, v) in seed { s.defaults.set(v, forKey: k) }
            let before = suites.persisted(s.name) as NSDictionary
            let config = ConfigStore(defaults: rec)
            c.check("init writes: ConfigStore(\(label)) makes no write call", rec.writes.isEmpty, ["calls": rec.writes])
            let guide = GuideStore(defaults: rec)
            guide.reload()
            c.check("init writes: GuideStore(\(label)) and reload() make no write call", rec.writes.isEmpty, ["calls": rec.writes])
            config.reload()
            c.check("init writes: ConfigStore.reload() (\(label)) makes no write call", rec.writes.isEmpty, ["calls": rec.writes])
            c.check("init writes: the domain is unchanged (\(label))", (suites.persisted(s.name) as NSDictionary) == before)
            if label == "populated" {
                // The recorder sees real writes (so an empty list above means none happened).
                config.stage = .phd
                c.check("init writes: a setter is recorded", rec.writes == [ConfigKeys.profileStage], ["calls": rec.writes])
            }
        }
    }

    private static func written2(_ suites: Suites, _ name: String, _ action: () -> Void) -> Set<String> {
        let before = suites.persisted(name)
        action()
        let after = suites.persisted(name)
        return Set(after.keys.filter { key in
            guard let a = after[key] else { return false }
            guard let b = before[key] else { return true }
            return !(a as AnyObject).isEqual(b)
        })
    }

    // MARK: Import

    private static func importPlans(_ c: Checker, _ suites: Suites, engineReady: Bool) async {
        guard let s = suites.make("import") else { c.check("import: scratch defaults", false); return }
        s.defaults.set("off", forKey: "agent.mode")
        s.defaults.set(false, forKey: MailSettings.Keys.enabled)
        s.defaults.set(false, forKey: "setup.completed")
        let store = SettingsStore(defaults: s.defaults, domain: s.name)
        var notices: [MailSettingsNotice] = []
        store.onMailSettingsChange = { notices.append($0) }
        let senders = MailSettings.encode([SenderRule(id: "imp-advisor", pattern: "advisor@example.edu", label: "Advisor",
                                                      kind: .advisor)])
        let plan = ImportPlan(changes: [], warnings: [], writes: [
            "agent.mode": .string("claude"), MailSettings.Keys.enabled: .bool(true), "setup.completed": .bool(true),
            "config.origin": .string("fresh"), "onboarding.version": .number(1),
            "reminder.hour": .number(9), "reminder.minute": .number(30), "plan.readingWeekdays": .array([.number(1), .number(3)]),
            MailSettings.Keys.senders: .string(senders), MailSettings.Keys.triageDailyMax: .number(12),
            ConfigKeys.profileStage: .string(CareerStage.faculty.rawValue),
        ])
        let n = store.applyImport(plan)
        try? await Task.sleep(for: .milliseconds(700))
        let p = suites.persisted(s.name)
        c.check("import: never writes agent.mode / mail.enabled / setup.completed",
                p["agent.mode"] as? String == "off" && p[MailSettings.Keys.enabled] as? Bool == false
                && p["setup.completed"] as? Bool == false && store.agentMode == "off" && !store.mailEnabled && !store.setupCompleted,
                ["agent.mode": p["agent.mode"] as? String, "mail.enabled": p[MailSettings.Keys.enabled] as? Bool])
        c.check("import: never writes config.* / onboarding.*",
                p["config.origin"] == nil && p["onboarding.version"] == nil)
        c.check("import: writes the allowed keys through the stores",
                n == 6 && store.reminderHour == 9 && store.reminderMinute == 30 && store.readingWeekdays == [1, 3]
                && store.mailSenders.map(\.id) == ["imp-advisor"] && store.mailTriageDailyMax == 12
                && p[ConfigKeys.profileStage] as? String == CareerStage.faculty.rawValue,
                ["written": n, "hour": store.reminderHour, "senders": store.mailSenders.map(\.id)])
        c.check("import: one debounced mail notice", notices == [.edit], ["notices": "\(notices)"])
        c.check("import: transfer.importedAt recorded", p[ConfigKeys.transferImportedAt] != nil)
        c.check("import: an empty plan writes nothing", store.applyImport(ImportPlan()) == 0)

        // Round trip through the engine's exporter / planner: AI and mail stay off.
        guard let src = suites.make("export"), let dst = suites.make("target") else { return }
        src.defaults.set("claude", forKey: "agent.mode")
        src.defaults.set(true, forKey: MailSettings.Keys.enabled)
        src.defaults.set(true, forKey: "setup.completed")
        src.defaults.set(9, forKey: "reminder.hour")
        src.defaults.set(senders, forKey: MailSettings.Keys.senders)
        let bundle = SettingsExporter.export(PersistedDomain(suites.persisted(src.name)), sections: Set(SettingsSection.allCases),
                                             includePersonal: false, includeAddresses: false,
                                             home: FileManager.default.temporaryDirectory, roots: [],
                                             app: "PaperDeck selftest", now: Date(timeIntervalSince1970: 1_800_000_000))
        let encoded = (try? SettingsExportSheet.encode(bundle)).flatMap { try? SettingsImporter.decode($0) }
        c.check("import: an exported file decodes again", encoded == bundle)
        let target = SettingsStore(defaults: dst.defaults, domain: dst.name)
        target.onMailSettingsChange = { _ in }
        let roundTrip = SettingsImporter.plan(bundle, current: target.persistedDomain, sections: Set(SettingsSection.allCases),
                                              keepPeopleAlways: false, acceptReaderDescription: false,
                                              home: FileManager.default.temporaryDirectory, roots: [])
        target.applyImport(roundTrip)
        let q = suites.persisted(dst.name)
        c.check("import: a round trip leaves AI reading, mail and setup off",
                q["agent.mode"] == nil && q[MailSettings.Keys.enabled] == nil && q["setup.completed"] == nil)
        c.check("import: a round trip carries the reminder and senders", needsEngine: !bundle.sections.isEmpty,
                target.reminderHour == 9 && target.mailSenders.map(\.id) == ["imp-advisor"])
    }

    // MARK: Mail templates

    private static func mailTemplates(_ c: Checker, fixtures: URL, lang: UILang) {
        // The legacy account (synthetic fixture shaped like an existing install's).
        let plist = fixtures.appendingPathComponent("legacy-\(LegacyInstall.organizationID)-domain.plist")
        var legacyName: String?
        if let data = try? Data(contentsOf: plist),
           let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let json = values[MailSettings.Keys.accounts] as? String,
           let accounts = try? JSONDecoder().decode([MailAccount].self, from: Data(json.utf8)),
           let account = accounts.first {
            legacyName = account.displayName
            c.check("mail: the legacy account opens the Power Automate form", MailAccountTemplate(account) == .powerAutomate,
                    ["source": MailSourceResolver.source(of: account).rawValue])
        } else {
            c.note(["skipped": "mail: legacy fixture not found", "path": plist.path])
        }
        let folder = MailAccount(kind: .folder, displayName: "Lab drop", folderPath: "/tmp/eml")
        c.check("mail: a plain folder account opens the folder form", MailAccountTemplate(folder) == .folder)
        var explicit = folder
        explicit.source = MailSourceID.m365PowerAutomate.rawValue
        c.check("mail: a stored source wins", MailAccountTemplate(explicit) == .powerAutomate)
        let gmail = MailAccount(kind: .imap, displayName: "", imapPreset: .gmail, host: "imap.gmail.com", port: 993)
        c.check("mail: an IMAP account opens its preset", MailAccountTemplate(gmail) == .imap(.gmail))

        // The source table: account routes map both ways; guide-only routes have no form.
        var table: [String] = []
        for id in MailSourceID.allCases {
            let t = MailAccountTemplate(source: id)
            if id.createsAccount != (t != nil) || (t.map { $0.sourceID != id } ?? false) { table.append(id.rawValue) }
        }
        c.check("mail: the source ↔ template table holds", table.isEmpty, ["broken": table])
        for t in MailAccountTemplate.choices {
            c.check("mail: \(t.sourceID.rawValue) round-trips", MailAccountTemplate(source: t.sourceID) == t)
        }

        // The chooser: today's seven rows, in today's order.
        let today: [MailAccountTemplate] = [.powerAutomate, .imap(.gmail), .imap(.icloud), .imap(.yahoo), .imap(.fastmail),
                                            .imap(.custom), .folder]
        for org in [ConfigSnapshot.legacy.organization, OrganizationPresets.generic] {
            let entries = MailSourceCatalog.entries(org: org)
            c.check("mail: the chooser's set-up rows are today's seven (\(org.id))",
                    MailAccountTemplate.setUpChoices(entries) == today,
                    ["rows": MailAccountTemplate.setUpChoices(entries).map(\.sourceID.rawValue)])
            c.check("mail: every catalog route opens a form or a help topic (\(org.id))",
                    entries.allSatisfy { e in
                        e.section == .setUp ? MailAccountTemplate(source: e.id) != nil
                                            : (!e.id.createsAccount && GuideTopicID.catalog.contains(e.helpTopic))
                    })
        }

        // The legacy default name of a new Power Automate account.
        let saved = LangStore.shared.org
        LangStore.shared.org = ConfigSnapshot.legacy.organization
        let previous = LangStore.shared.lang
        LangStore.shared.lang = .en
        let name = L.MailPref.powerAutomateDefaultName
        LangStore.shared.lang = previous
        LangStore.shared.org = saved
        c.check("mail: the legacy Power Automate default name is today's",
                legacyName.map { $0 == name } ?? name.contains("Power Automate"), ["name": name, "fixture": legacyName])
    }

    // MARK: Presets, models, people default

    private static func presetsAndModels(_ c: Checker) {
        let menu = MailSenderRulesEditor.presetMenu(field: FieldPresets.lifeSciencesCompBio, existing: [])
        c.check("presets: life sciences suggests today's presets in order",
                menu.suggested.map(\.rule) == SenderRule.presets, ["ids": menu.suggested.map(\.rule.id)])
        let have = MailSenderRulesEditor.presetMenu(field: FieldPresets.lifeSciencesCompBio,
                                                    existing: [SenderRule.presets[0], SenderRule(pattern: "@biorxiv.org", kind: .alert)])
        c.check("presets: patterns already listed are left out",
                !have.suggested.contains { $0.rule.id == SenderRule.presets[0].id || $0.rule.id == "preset-biorxiv" }
                && have.suggested.count == SenderRule.presets.count - 2)
        let all = Set(menu.suggested.map(\.rule.id)).union(menu.others.map(\.rule.id))
        c.check("presets: suggested + more cover the catalog once",
                all == Set(SenderPresetCatalog.all.map(\.rule.id)) && menu.suggested.count + menu.others.count == all.count)

        // Triage picker: today's two when the cache has no list; the connection test's model.
        c.check("models: the triage ChatGPT picker without a cache is today's",
                MailTriageSection.codexChoices([], current: "gpt-5.6-luna", lang: .en).map(\.id) == MailTriageSection.codexModels)
        let cached = [CodexModelCatalog.Model(id: "gpt-5.6-terra", name: "GPT-5.6-Terra", detail: nil),
                      CodexModelCatalog.Model(id: "gpt-6-astra", name: "GPT-6 Astra", detail: nil)]
        let choices = MailTriageSection.codexChoices(cached, current: "gpt-5.6-luna", lang: .en).map(\.id)
        c.check("models: the triage picker follows the cache and keeps the current model",
                choices.first == "gpt-5.6-terra" && choices.contains("gpt-6-astra") && choices.contains("gpt-5.6-luna"),
                ["ids": choices])
        c.check("models: the connection test keeps GPT-5.6-Luna when listed",
                AISettingsTab.codexTestModel([]) == "gpt-5.6-luna"
                && AISettingsTab.codexTestModel(CodexModelCatalog.merge([], lang: .en)) == "gpt-5.6-luna")
        c.check("models: otherwise the first cached model", AISettingsTab.codexTestModel(cached) == "gpt-5.6-terra")

        // People's default: never "always"; an organization can only be stricter.
        c.check("people: no organization default sends people's mail automatically",
                PeopleAIDefault.allCases.allSatisfy { $0.policy != .always })
        c.check("people: a new person rule takes the organization's default",
                SenderRule(pattern: "", kind: .person, aiPolicy: PeopleAIDefault.never.policy).aiPolicy == .never
                && SenderRule(pattern: "", kind: .person, aiPolicy: PeopleAIDefault.ask.policy).aiPolicy == .ask)
    }

    // MARK: Library Change…

    private static func libraryChange(_ c: Checker, _ suites: Suites, scratch: URL) {
        let current = scratch.appendingPathComponent("LibA", isDirectory: true)
        let other = scratch.appendingPathComponent("LibB", isDirectory: true)
        let parent = scratch.appendingPathComponent("Parent", isDirectory: true)
        typealias D = LibraryChangeDecision
        let rows: [(String, LibraryFolderKind, URL, D, [D.Action])] = [
            ("same folder", .existingLibrary(libraryID: "a", cardCount: 3), current, .current, [.chooseAnother]),
            ("same id elsewhere", .existingLibrary(libraryID: "a", cardCount: 3), other, .useSameLibrary(other),
             [.useThisFolder, .chooseAnother]),
            ("another library", .existingLibrary(libraryID: "b", cardCount: 5), other, .openOther(other, cards: 5),
             [.openThisLibrary, .chooseAnother]),
            ("cards without a manifest", .existingLibrary(libraryID: nil, cardCount: 2), other, .openOther(other, cards: 2),
             [.openThisLibrary, .chooseAnother]),
            ("parent of a library", .parentOfLibrary(child: other, cardCount: 5), parent, .suggestChild(other, cards: 5),
             [.useChild, .chooseAnother]),
            ("empty", .empty, other, .startNew(other, otherItems: 0), [.startNewLibrary, .chooseAnother]),
            ("other content", .otherContent(items: 4), other,
             .startNew(other.appendingPathComponent("Papers", isDirectory: true), otherItems: 4), [.startNewLibrary, .chooseAnother]),
            ("missing", .missing, other, .unusable(missing: true), [.chooseAnother]),
            ("unreadable", .unreadable, other, .unusable(missing: false), [.chooseAnother]),
        ]
        for (name, kind, folder, expected, actions) in rows {
            let d = D.decide(folder, kind: kind, currentLibrary: current, currentID: "a")
            c.check("change: \(name)", d == expected && d.offered == actions, ["got": "\(d)"])
        }
        c.check("change: confirming writes",
                D.useSameLibrary(other).confirmation(previous: current).map { $0.pending == nil && $0.path == other.path } == true
                && D.openOther(other, cards: 1).confirmation(previous: current)?.pending
                    == LibraryPendingAction(kind: .openExisting, path: other.path, previousPath: current.path)
                && D.startNew(other, otherItems: 0).confirmation(previous: current)?.pending?.kind == .startNew
                && D.current.confirmation(previous: current) == nil && D.unusable(missing: true).confirmation(previous: current) == nil)

        guard let s = suites.make("library") else { c.check("change: scratch defaults", false); return }
        let store = SettingsStore(defaults: s.defaults, domain: s.name)
        let action = LibraryPendingAction(kind: .openExisting, path: other.path, previousPath: current.path)
        store.scheduleLibraryChange(path: other.path, pending: action, previousPath: current.path)
        let p = suites.persisted(s.name)
        c.check("change: the pending action, previous path and library path are written",
                LibraryPendingAction.load(s.defaults) == action && p[ConfigKeys.libraryPreviousPath] as? String == current.path
                && p["library.path"] as? String == other.path && store.libraryPendingAction == action)
        store.cancelLibraryChange(keeping: current.path)
        c.check("change: Keep Current Location drops the pending action",
                LibraryPendingAction.load(s.defaults) == nil && store.libraryPath == current.path)
        c.check("change: an import never schedules or clears a library action",
                !SettingsStore.importMayWrite(ConfigKeys.libraryPendingAction) && !SettingsStore.importMayWrite(ConfigKeys.libraryPreviousPath))
    }
}
