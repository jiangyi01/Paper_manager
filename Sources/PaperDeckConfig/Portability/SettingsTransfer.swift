import Foundation
import PaperDeckCore

/// A settings file (`paperdeck.settings/1`). A "lab setup file" is the same format with only the
/// profile, organization and mail-sender sections. Never holds a password or app password.
package struct SettingsBundle: Codable, Sendable, Equatable {
    package static let formatID = "paperdeck.settings/1"

    package var format: String
    package var exportedAt: Date
    package var app: String                 // "PaperDeck 1.0 (27)"
    package var sections: [String: JSONValue]

    package init(format: String = SettingsBundle.formatID, exportedAt: Date, app: String, sections: [String: JSONValue]) {
        self.format = format; self.exportedAt = exportedAt; self.app = app; self.sections = sections
    }
}

package enum SettingsExporter {
    /// The allowlisted keys of `sections` present in `p` (`SettingsRegistry`; `never` keys and
    /// unlisted keys are never exported, personal ones only with `includePersonal`). Paths travel
    /// as `PortablePath`; the JSON-string settings (senders, accounts, criteria, the custom
    /// organization) as JSON trees. No password, app password or token is ever part of a domain's
    /// allowlisted keys — IMAP app passwords live in the keychain, which is never read here.
    package static func export(_ p: PersistedDomain, sections: Set<SettingsSection>, includePersonal: Bool,
                               home: URL, roots: [CloudRoot], app: String, now: Date) -> SettingsBundle {
        var out: [String: [String: JSONValue]] = [:]
        for entry in SettingsRegistry.entries where entry.keyClass != .never && sections.contains(entry.section) {
            if entry.personal && !includePersonal { continue }
            guard SettingsTransferValues.isSafeKey(entry.key), let raw = p.values[entry.key],
                  let value = exportValue(entry.key, raw, includePersonal: includePersonal, home: home, roots: roots)
            else { continue }
            out[entry.section.rawValue, default: [:]][entry.key] = value
        }
        return SettingsBundle(exportedAt: now, app: app, sections: out.mapValues { .object($0) })
    }

    static func exportValue(_ key: String, _ raw: Any, includePersonal: Bool, home: URL, roots: [CloudRoot]) -> JSONValue? {
        switch key {
        case "library.path", ConfigKeys.importLastFolder, "agent.cliPath", "agent.codexPath":
            guard let path = raw as? String, !path.isEmpty else { return nil }
            return try? JSONValue.from(PortablePath.encode(path, home: home, roots: roots))
        case MailSettings.Keys.accounts:
            let accounts = MailSettings.list(raw as? String, MailAccount.self, what: "account")
            guard !accounts.isEmpty else { return nil }
            return .array(accounts.compactMap { a -> JSONValue? in
                guard case .object(var o)? = try? JSONValue.from(a) else { return nil }
                o["folderPath"] = nil
                if let folder = a.folderPath, !folder.isEmpty,
                   let portable = try? JSONValue.from(PortablePath.encode(folder, home: home, roots: roots)) {
                    o["folder"] = portable
                }
                if !includePersonal { o["username"] = nil }      // the mailbox address
                return .object(o)
            })
        case MailSettings.Keys.senders:
            let rules = MailSettings.list(raw as? String, SenderRule.self, what: "sender")
            return try? JSONValue.from(rules)
        case MailSettings.Keys.criteria:
            guard let s = raw as? String, let data = s.data(using: .utf8),
                  let criteria = try? JSONDecoder().decode(ReadingCriteria.self, from: data) else { return nil }
            return try? JSONValue.from(criteria)
        case ConfigKeys.orgCustom:
            guard let s = raw as? String, let org = ConfigResolver.decodeCustom(s) else { return nil }
            return try? JSONValue.from(org)
        case ConfigKeys.profileReaderDescription:
            return (raw as? String).flatMap(CardPromptProfile.sanitize).map(JSONValue.string)
        default:
            return SettingsTransferValues.json(raw)
        }
    }
}

/// Plist ↔ JSON values of a settings transfer.
package enum SettingsTransferValues {
    /// A property-list value as JSON (`Bool` stays a bool; dates and data are not transferable).
    package static func json(_ v: Any) -> JSONValue? {
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        }
        if let s = v as? String { return .string(s) }
        if let a = v as? [Any] {
            let mapped = a.compactMap(json)
            return mapped.count == a.count ? .array(mapped) : nil
        }
        if let d = v as? [String: Any] {
            var o: [String: JSONValue] = [:]
            for (k, x) in d { guard let j = json(x) else { return nil }; o[k] = j }
            return .object(o)
        }
        return nil
    }

    /// What `UserDefaults.set(_:forKey:)` takes for a planned write: integral numbers as `Int`.
    package static func plistValue(_ v: JSONValue) -> Any? {
        switch v {
        case .null: return nil
        case .bool(let b): return b
        case .number(let n): return n.rounded() == n && abs(n) < 9.0e15 ? Int(n) as Any : n as Any
        case .string(let s): return s
        case .array(let a):
            let mapped = a.compactMap(plistValue)
            return mapped.count == a.count ? mapped : nil
        case .object(let o):
            var d: [String: Any] = [:]
            for (k, x) in o { guard let p = plistValue(x) else { return nil }; d[k] = p }
            return d
        }
    }

    /// Keys that could name a credential never travel, whatever the registry says.
    static func isSafeKey(_ key: String) -> Bool {
        let k = key.lowercased()
        return !["password", "secret", "token", "apppassword", "keychain"].contains { k.contains($0) }
    }

    /// A short, single-line rendering for the import preview ("11 → 9").
    static func describe(_ v: Any?) -> String? {
        guard let v else { return nil }
        if let j = v as? JSONValue { return describe(json: j) }
        return json(v).map { describe(json: $0) } ?? String(describing: v)
    }

    package static func describe(json v: JSONValue) -> String {
        let text: String
        switch v {
        case .string(let s): text = s
        case .number(let n): text = Int(exactly: n).map { String($0) } ?? String(n)   // 1e300 / NaN must not trap
        case .bool(let b): text = b ? "true" : "false"
        case .null: text = "null"
        default: text = v.compactString()
        }
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }
}

/// One key an import would change, shown as a diff ("Reminder: 11:00 → 09:30").
package struct ImportChange: Sendable, Equatable {
    package var key: String
    package var section: SettingsSection
    package var old: String?
    package var new: String
    package var needsConfirmation: Bool

    package init(key: String, section: SettingsSection, old: String?, new: String, needsConfirmation: Bool) {
        self.key = key; self.section = section; self.old = old; self.new = new; self.needsConfirmation = needsConfirmation
    }
}

package enum ImportWarning: Sendable, Equatable {
    case needsAppPassword(account: String), folderRemapped(account: String, to: String), folderUnresolved(account: String, root: String)
    case cliPathDropped(String), peopleAlwaysClamped(sender: String), readerDescriptionNeedsConfirm, unknownKeysIgnored(Int)
    /// The file's value of the key is of the wrong type, not finite or out of range: not imported.
    case valueOutOfRange(String)
    /// That many entries of a list key (mail accounts) had such a value: skipped.
    case entriesSkipped(String, Int)
    /// The reading criteria's custom instructions (they enter the AI triage prompt) differ: this
    /// Mac's stay unless the user confirms the file's (`acceptCriteriaInstructions`).
    case criteriaInstructionsNeedConfirm
}

/// How an import folds a list setting (`mail.senders`, `mail.accounts`) into this Mac's: by id
/// (a sender also by its pattern, a mailbox also by its address or folder — this Mac's id is
/// kept, so its keychain item and its emails stay linked). Nothing this Mac has is removed. The
/// names are what the import sheet lists ("2 added · 1 replaced · 3 kept").
package struct ImportListMerge: Sendable, Equatable {
    /// The file's entries this Mac doesn't have: appended.
    package var added: [String]
    /// This Mac's entries the file changes: replaced by the file's version.
    package var replaced: [String]
    /// This Mac's entries left as they are: only on this Mac, or the same in the file.
    package var kept: [String]

    package init(added: [String] = [], replaced: [String] = [], kept: [String] = []) {
        self.added = added; self.replaced = replaced; self.kept = kept
    }

    package var addCount: Int { added.count }
    package var replaceCount: Int { replaced.count }
    package var keepCount: Int { kept.count }
}

/// A value the file holds that is looser about privacy or quota than this Mac's
/// (`SettingsSensitivity`): this Mac's value is kept ("kept stricter") unless the user accepts the
/// file's for this one item (`LooserAcceptance`).
package struct ImportLoosening: Sendable, Equatable, Identifiable {
    /// What the user ticks: the key (`mail.aiMode`), `mail.senders/<this Mac's rule id>` for one
    /// sender's AI policy (`…/<field>` for its other fields), `mail.accounts/<this Mac's id>/<field>`
    /// for one account's, or `org.peopleDefault` for the institution's default for people.
    package var id: String
    /// The settings key the value belongs to.
    package var key: String
    package var section: SettingsSection
    /// The sender or account the value belongs to (its label / name, else its pattern / id); nil
    /// for a plain key.
    package var subject: String?
    /// Which field of that sender or account (nil for a plain key).
    package var field: ImportEntryField?
    /// The value this Mac keeps (its own; the default when the key is absent) and the file's
    /// looser one: a key's value, a sender's AI policy (`MailAIPolicy`), an entry's switch or
    /// number, or the institution's people default (`PeopleAIDefault`).
    package var mine: JSONValue
    package var theirs: JSONValue
    /// The user accepted the looser value: it is written. Otherwise this Mac's stays.
    package var accepted: Bool
    /// For a sender the file adds: this Mac's broader, stricter rule it would take over from (its
    /// label, else its pattern) — the new rule is more specific, so it would win for that mail.
    package var overrides: String?

    package init(id: String, key: String, section: SettingsSection, subject: String? = nil,
                 field: ImportEntryField? = nil, mine: JSONValue, theirs: JSONValue, accepted: Bool,
                 overrides: String? = nil) {
        self.id = id; self.key = key; self.section = section; self.subject = subject; self.field = field
        self.mine = mine; self.theirs = theirs; self.accepted = accepted; self.overrides = overrides
    }

    /// The id of one field of one sender (this Mac's rule id); its AI policy is `mail.senders/<id>`.
    package static func senderID(_ ruleID: String, _ field: ImportEntryField = .aiPolicy) -> String {
        let base = "\(MailSettings.Keys.senders)/\(ruleID)"
        return field == .aiPolicy ? base : "\(base)/\(field.rawValue)"
    }
    /// The id of one field of a sender the file adds (the file's rule id) that would take over mail
    /// from a stricter, broader rule of this Mac.
    package static func newSenderID(_ fileRuleID: String, _ field: ImportEntryField = .aiPolicy) -> String {
        let base = "\(MailSettings.Keys.senders)/new/\(fileRuleID)"
        return field == .aiPolicy ? base : "\(base)/\(field.rawValue)"
    }
    /// The id of one field of one mail account (this Mac's account id).
    package static func accountID(_ accountID: String, _ field: ImportEntryField) -> String {
        "\(MailSettings.Keys.accounts)/\(accountID)/\(field.rawValue)"
    }
    /// The id of the institution's people default.
    package static let peopleDefaultID = "org.peopleDefault"
}

/// A field of a sender rule or a mail account an import never loosens for an entry this Mac
/// already has (`SettingsImporter.mergeSenders` / `mergeAccounts`; `SettingsRegistryLintTests`
/// classifies every other field).
package enum ImportEntryField: String, Sendable, CaseIterable {
    /// A sender's AI policy: never < ask < an alert's always < a person's always.
    case aiPolicy
    /// A sender or account turned off here: its mail isn't read (on is looser).
    case enabled
    /// A sender's papers with a PDF are merged without waiting for the user (on is looser).
    case autoMerge
    /// A sender's attachments are stored when the email arrives (on is looser).
    case autoDownload
    /// How far back an account's check reads (more days is looser).
    case lookbackDays
    /// A folder account removes its .eml files once captured (on deletes the user's files).
    case deleteProcessedFiles
}

/// Which looser values (`ImportLoosening.id`) the user accepted: none by default (every one is
/// kept stricter), the import sheet's ticked items, or all (the CLI's `--accept-looser`).
package enum LooserAcceptance: Sendable, Equatable {
    case none
    case only(Set<String>)
    case all

    package func accepts(_ id: String) -> Bool {
        switch self {
        case .none: return false
        case .only(let ids): return ids.contains(id)
        case .all: return true
        }
    }
}

/// What an import writes (pure). Invariant: `writes` never holds `agent.mode`, `mail.enabled`,
/// `setup.completed` or any other "never" key, nor a looser privacy / quota value the user did
/// not accept (`loosenings`).
package struct ImportPlan: Sendable, Equatable {
    package var changes: [ImportChange]
    package var warnings: [ImportWarning]
    package var writes: [String: JSONValue]
    /// For each list key the plan changes (`mail.senders`, `mail.accounts`): what is added,
    /// replaced and kept (`SettingsImporter.mergeSenders` / `mergeAccounts`).
    package var merges: [String: ImportListMerge]
    /// Every looser privacy / quota value of the file, accepted or kept stricter (sections and
    /// keys in order, the institution's people default last).
    package var loosenings: [ImportLoosening]
    /// The file's custom instructions for AI triage (`mail.criteria`) when they differ from this
    /// Mac's: shown for confirmation, written only with `acceptCriteriaInstructions`.
    package var criteriaInstructions: String?

    package init(changes: [ImportChange] = [], warnings: [ImportWarning] = [], writes: [String: JSONValue] = [:],
                 merges: [String: ImportListMerge] = [:], loosenings: [ImportLoosening] = [],
                 criteriaInstructions: String? = nil) {
        self.changes = changes; self.warnings = warnings; self.writes = writes; self.merges = merges
        self.loosenings = loosenings; self.criteriaInstructions = criteriaInstructions
    }

    /// The looser values not accepted: this Mac's stricter value stays.
    package var keptStricter: [ImportLoosening] { loosenings.filter { !$0.accepted } }
}

package enum SettingsImporter {
    package enum Failure: Error, Equatable {
        case unknownFormat(String), malformed
    }

    /// Decodes a settings file; an unknown `format` is refused.
    package static func decode(_ data: Data) throws -> SettingsBundle {
        let bundle: SettingsBundle
        do { bundle = try JSONDecoder().decode(SettingsBundle.self, from: data) } catch { throw Failure.malformed }
        guard bundle.format == SettingsBundle.formatID else { throw Failure.unknownFormat(bundle.format) }
        return bundle
    }

    /// Keys an import never writes, whatever a file says (AI and mail stay as they are — off on a
    /// new Mac — and setup is the app's own state).
    package static let neverWritten: Set<String> = ["agent.mode", MailSettings.Keys.enabled, "setup.completed",
                                                    AssistSettings.Keys.mode, DedupeSettings.Keys.aiAuto]

    /// What importing `b` into `current` would change (PORTABILITY_PLAN §2.10, pure apart from
    /// checking that an imported CLI path exists on this Mac):
    /// 1. never `agent.mode`, `mail.enabled`, `setup.completed`, nor any `never` / unlisted key
    ///    (unknown keys are counted);
    /// 2. a privacy- or quota-sensitive key (`SettingsSensitivity`) is never loosened: a file value
    ///    looser than this Mac's (its default when absent) — AI triage turned on, a higher daily
    ///    cap, body cap, text budget or attachment size, a notification or automatic reading turned
    ///    on, a longer retention, a more expensive model, a sender's AI policy raised (never → ask
    ///    → always, any kind), a sender or account turned off here turned on, a sender's automatic
    ///    merge or attachment storing turned on, an account's longer look-back, the institution's
    ///    people default `never` → `ask` — keeps this Mac's value and is listed in `loosenings`,
    ///    unless `acceptLooser` accepts that item;
    /// 2a. a *new* person or advisor sender with AI `always` arrives as `ask` unless
    ///    `keepPeopleAlways`;
    /// 3. IMAP accounts arrive as "needs app password" (same ids: on the same Mac the keychain item
    ///    is found again);
    /// 3a. senders and accounts are merged into this Mac's by id (`mergeSenders`, `mergeAccounts`):
    ///    entries only this Mac has are kept, `merges` counts what is added / replaced / kept;
    /// 4. folder accounts are re-resolved against this Mac's roots (same root name, else the only
    ///    root of the same provider, else "choose later");
    /// 5. the reader description is written only with `acceptReaderDescription`, the reading
    ///    criteria's custom instructions for AI triage only with `acceptCriteriaInstructions` (both
    ///    enter an AI prompt);
    /// 6. the organization carries only name, short name, approved tools, an https link, the people
    ///    default and the OneDrive hint — never texts, senders or AI enablement;
    /// 7. a value of the wrong type, not finite or out of range (`SettingsRegistry.valueRules`, an
    ///    account's look-back or port, the criteria's numbers) is dropped with a warning — never written;
    /// 8. AI triage switched to another AI service than this Mac's (`mail.triageProvider`), a sender
    ///    the file adds that is more specific than a stricter rule here (it would take over that
    ///    mail), an existing folder account's "delete processed files" turned on: kept stricter, as in 2.
    /// Values equal to the current ones are left out. Hint keys (paths, accounts) need confirmation.
    package static func plan(_ b: SettingsBundle, current: PersistedDomain, sections: Set<SettingsSection>,
                             keepPeopleAlways: Bool, acceptReaderDescription: Bool, acceptLooser: LooserAcceptance = .none,
                             acceptCriteriaInstructions: Bool = false,
                             home: URL, roots: [CloudRoot]) -> ImportPlan {
        var plan = ImportPlan()
        var unknown = 0
        for (sectionName, payload) in b.sections.sorted(by: { $0.key < $1.key }) {
            guard let section = SettingsSection(rawValue: sectionName), case .object(let kv) = payload else {
                unknown += payload.objectValue?.count ?? 1
                continue
            }
            guard sections.contains(section) else { continue }
            for (key, value) in kv.sorted(by: { $0.key < $1.key }) {
                // A key is read in its registry section — or where an earlier build filed it.
                guard let entry = SettingsRegistry.entry(key), SettingsRegistry.isTransferable(key),
                      SettingsRegistry.section(section, mayHold: key), !neverWritten.contains(key),
                      SettingsTransferValues.isSafeKey(key) else {
                    unknown += 1
                    continue
                }
                // Never a value of the wrong type, not finite or out of range (1e300 for a daily cap).
                var value = value
                if let rule = SettingsRegistry.valueRules[key] {
                    guard let valid = rule.validated(value) else {
                        if !plan.warnings.contains(.valueOutOfRange(key)) { plan.warnings.append(.valueOutOfRange(key)) }
                        continue
                    }
                    value = valid
                }
                guard let (write, wantsConfirm) = importValue(key, value, plan: &plan, current: current,
                                                          keepPeopleAlways: keepPeopleAlways,
                                                          acceptReaderDescription: acceptReaderDescription,
                                                          acceptCriteriaInstructions: acceptCriteriaInstructions,
                                                          acceptLooser: acceptLooser, home: home, roots: roots) else { continue }
                // AI triage sent to another AI service than this Mac's: kept unless accepted.
                if entry.sensitivity?.order == .provider, let theirs = write.stringValue {
                    let mine = effectiveTriageProvider(current)
                    if theirs != mine.rawValue {
                        let accepted = acceptLooser.accepts(key)
                        if !plan.loosenings.contains(where: { $0.id == key }) {
                            plan.loosenings.append(ImportLoosening(id: key, key: key, section: entry.section,
                                                                   mine: .string(mine.rawValue), theirs: write,
                                                                   accepted: accepted))
                        }
                        guard accepted else { continue }
                    }
                }
                // Never looser about privacy or quota than this Mac without the user's yes.
                if let s = entry.sensitivity, s.isLooser(write, than: current.values[key]), let mine = s.effective(current.values[key]) {
                    let accepted = acceptLooser.accepts(key)
                    if !plan.loosenings.contains(where: { $0.id == key }) {          // a key filed twice is listed once
                        plan.loosenings.append(ImportLoosening(id: key, key: key, section: entry.section, mine: mine,
                                                               theirs: write, accepted: accepted))
                    }
                    guard accepted else { continue }
                }
                let confirm = wantsConfirm || plan.loosenings.contains { $0.key == key && $0.accepted }
                let old = SettingsTransferValues.describe(current.values[key])
                let new = SettingsTransferValues.describe(json: write)
                if let currentValue = current.values[key], sameValue(key, currentValue, write) {
                    plan.merges[key] = nil
                    continue
                }
                plan.changes.append(ImportChange(key: key, section: entry.section, old: old, new: new,
                                                 needsConfirmation: confirm || entry.keyClass == .hint))
                if !(key == ConfigKeys.profileReaderDescription && !acceptReaderDescription) {
                    plan.writes[key] = write
                }
            }
        }
        if unknown > 0 { plan.warnings.append(.unknownKeysIgnored(unknown)) }
        keepStricterPeopleDefault(&plan, current: current, acceptLooser: acceptLooser)
        // The invariant, once more: nothing outside the allowlist, never the three switches, no
        // looser value of a key the user didn't accept.
        let keptKeys = Set(plan.keptStricter.filter { $0.id == $0.key }.map(\.key))
        plan.writes = plan.writes.filter {
            SettingsRegistry.isTransferable($0.key) && !neverWritten.contains($0.key) && !keptKeys.contains($0.key)
        }
        return plan
    }

    /// The AI service this Mac's AI triage uses: its triage override, else the AI-reading provider
    /// (a claude / codex `agent.mode`, else `agent.provider`; Claude when nothing is stored) —
    /// `SettingsStore.mailEffectiveTriageProvider`.
    package static func effectiveTriageProvider(_ current: PersistedDomain) -> AIProviderKind {
        current.string(MailSettings.Keys.triageProvider).flatMap(AIProviderKind.init(rawValue:))
            ?? current.string("agent.mode").flatMap(AIProviderKind.init(rawValue:))
            ?? current.string("agent.provider").flatMap(AIProviderKind.init(rawValue:))
            ?? .claude
    }

    /// The institution's default for new person senders: "never" on this Mac is not loosened to
    /// "ask" by the file's institution (a custom one with "ask", or a built-in preset — they all
    /// ask) unless the user accepts `ImportLoosening.peopleDefaultID`. Kept stricter: the file's
    /// custom institution is written with "never", and a switch to a built-in preset is not made.
    private static func keepStricterPeopleDefault(_ plan: inout ImportPlan, current: PersistedDomain,
                                                  acceptLooser: LooserAcceptance) {
        let presetKey = ConfigKeys.orgPreset, customKey = ConfigKeys.orgCustom
        guard plan.writes[presetKey] != nil || plan.writes[customKey] != nil else { return }
        let mine = ConfigResolver.organization(current.string(presetKey), custom: current.string(customKey), origin: .fresh)
        guard mine.peopleDefault == .never else { return }
        let preset = plan.writes[presetKey]?.stringValue ?? current.string(presetKey)
        let custom = plan.writes[customKey]?.stringValue ?? current.string(customKey)
        let theirs = ConfigResolver.organization(preset, custom: custom, origin: .fresh)
        guard theirs.peopleDefault != .never else { return }
        let accepted = acceptLooser.accepts(ImportLoosening.peopleDefaultID)
        plan.loosenings.append(ImportLoosening(id: ImportLoosening.peopleDefaultID, key: customKey, section: .organization,
                                               mine: .string(mine.peopleDefault.rawValue),
                                               theirs: .string(theirs.peopleDefault.rawValue), accepted: accepted))
        if accepted {
            for i in plan.changes.indices where [presetKey, customKey].contains(plan.changes[i].key) {
                plan.changes[i].needsConfirmation = true
            }
            return
        }
        func drop(_ key: String) {
            plan.writes[key] = nil
            plan.changes.removeAll { $0.key == key }
        }
        if let json = plan.writes[customKey]?.stringValue, var org = ConfigResolver.decodeCustom(json) {
            org.peopleDefault = .never
            if current.string(customKey).flatMap(ConfigResolver.decodeCustom) == org {
                drop(customKey)
            } else {
                let kept = JSONValue.string(ConfigResolver.encodeCustom(org))
                plan.writes[customKey] = kept
                if let i = plan.changes.firstIndex(where: { $0.key == customKey }) {
                    plan.changes[i].new = SettingsTransferValues.describe(json: kept)
                }
            }
        }
        if preset != "custom" { drop(presetKey) }
    }

    /// The value to write for one imported key (nil: skipped) and whether the user must confirm it.
    private static func importValue(_ key: String, _ value: JSONValue, plan: inout ImportPlan, current: PersistedDomain,
                                    keepPeopleAlways: Bool, acceptReaderDescription: Bool, acceptCriteriaInstructions: Bool,
                                    acceptLooser: LooserAcceptance, home: URL, roots: [CloudRoot]) -> (JSONValue, Bool)? {
        switch key {
        case ConfigKeys.profileReaderDescription:
            guard let text = value.stringValue.flatMap(CardPromptProfile.sanitize) else { return nil }
            if !acceptReaderDescription { plan.warnings.append(.readerDescriptionNeedsConfirm) }
            return (.string(text), true)
        case ConfigKeys.profileField:
            guard let id = value.stringValue, FieldPresets.preset(id: id) != nil else { return nil }
            return (.string(id), false)
        case ConfigKeys.profileStage:
            guard let raw = value.stringValue, CareerStage(rawValue: raw) != nil else { return nil }
            return (.string(raw), false)
        case ConfigKeys.orgPreset:
            guard let id = value.stringValue, OrganizationPresets.preset(id: id) != nil || id == "custom" else { return nil }
            return (.string(id), false)
        case ConfigKeys.orgCustom:
            guard let raw = try? value.decode(OrganizationProfile.self) else { return nil }
            let org = OrganizationPresets.custom(name: raw.name?.en ?? "", shortName: raw.shortName,
                                                 approvedAITools: raw.approvedAITools, policyURL: raw.policyURL,
                                                 peopleDefault: raw.peopleDefault, oneDriveRootHint: raw.mail.oneDriveRootHint)
            return (.string(ConfigResolver.encodeCustom(org)), false)
        case MailSettings.Keys.senders:
            guard case .array(let items) = value else { return nil }
            let rules = items.compactMap { try? $0.decode(SenderRule.self) }
            let mine = MailSettings.list(current.values[key] as? String, SenderRule.self, what: "sender")
            let merged = mergeSenders(current: mine, imported: rules, keepPeopleAlways: keepPeopleAlways,
                                      acceptLooser: acceptLooser)
            for name in merged.clamped { plan.warnings.append(.peopleAlwaysClamped(sender: name)) }
            plan.loosenings += merged.loosened
            plan.merges[key] = merged.merge
            return (.string(MailSettings.encode(merged.rules)), false)
        case MailSettings.Keys.accounts:
            guard case .array(let items) = value else { return nil }
            var accounts: [MailAccount] = []
            var warnings: [[ImportWarning]] = []                 // per account (an existing mailbox needs none)
            var skipped = 0
            for item in items {
                guard case .object(var o) = item else { continue }
                let folder = o["folder"].flatMap { try? $0.decode(PortablePath.self) }
                o["folder"] = nil
                o["folderPath"] = nil
                // A number that isn't a whole number in range (1e300 days, port 70000) skips the account
                // — checked on the file's value: the account's decoder would fall back to a default.
                let numbersOK = [("lookbackDays", accountLookback), ("port", 1...65_535)].allSatisfy { field, range in
                    guard let raw = o[field], !raw.isNull else { return true }
                    return SettingsValueRule.int(range).validated(raw) != nil
                }
                guard numbersOK, var account = try? JSONValue.object(o).decode(MailAccount.self),
                      accountLookback.contains(account.lookbackDays),
                      account.port.map({ (1...65_535).contains($0) }) ?? true else {
                    skipped += 1
                    continue
                }
                let name = account.displayName.isEmpty ? account.id : account.displayName
                var own: [ImportWarning] = []
                switch account.kind {
                case .imap:
                    own.append(.needsAppPassword(account: name))
                case .folder:
                    if let folder {
                        switch folder.resolve(home: home, roots: roots) {
                        case .exact(let url):
                            account.folderPath = url.path
                        case .sameProvider(let url):
                            account.folderPath = url.path
                            own.append(.folderRemapped(account: name, to: url.path))
                        case .unresolved:
                            if case .cloud(_, let root, _) = folder {
                                own.append(.folderUnresolved(account: name, root: root))
                            }
                        }
                    }
                }
                accounts.append(account)
                warnings.append(own)
            }
            if skipped > 0 { plan.warnings.append(.entriesSkipped(key, skipped)) }
            let mine = MailSettings.list(current.values[key] as? String, MailAccount.self, what: "account")
            let merged = mergeAccounts(current: mine, imported: accounts, acceptLooser: acceptLooser)
            for (i, own) in warnings.enumerated() where !merged.existingMailboxes.contains(i) {
                plan.warnings.append(contentsOf: own)
            }
            plan.loosenings += merged.loosened
            plan.merges[key] = merged.merge
            return (.string(MailSettings.encode(merged.accounts)), true)
        case MailSettings.Keys.criteria:
            // Checked on the file's values (the criteria's decoder falls back to defaults).
            let raw = value.objectValue ?? [:]
            let numbersOK = (raw["minConfidence"].map { $0.isNull || SettingsValueRule.number(0...1).validated($0) != nil } ?? true)
                && (raw["maxAlertPapers"].map { $0.isNull || SettingsValueRule.int(1...100).validated($0) != nil } ?? true)
            guard numbersOK, var criteria = try? value.decode(ReadingCriteria.self), criteria.minConfidence.isFinite,
                  (0...1).contains(criteria.minConfidence), (1...100).contains(criteria.maxAlertPapers) else {
                plan.warnings.append(.valueOutOfRange(key))
                return nil
            }
            // The custom instructions enter the AI triage prompt: like the reader description, the
            // file's are used only once the user confirms them (else this Mac's stay).
            let mine = (current.values[key] as? String).flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(ReadingCriteria.self, from: $0) } ?? ReadingCriteria()
            let theirs = criteria.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !theirs.isEmpty, theirs != mine.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return (.string(MailSettings.encode(criteria)), false)
            }
            plan.criteriaInstructions = criteria.customInstructions
            if !acceptCriteriaInstructions {
                plan.warnings.append(.criteriaInstructionsNeedConfirm)
                criteria.customInstructions = mine.customInstructions
            }
            return (.string(MailSettings.encode(criteria)), true)
        case MailSettings.Keys.triageProvider:
            guard let raw = value.stringValue, AIProviderKind(rawValue: raw) != nil else {
                plan.warnings.append(.valueOutOfRange(key))
                return nil
            }
            return (.string(raw), false)
        case "library.path", ConfigKeys.importLastFolder:
            guard let path = try? value.decode(PortablePath.self) else { return nil }
            switch path.resolve(home: home, roots: roots) {
            case .exact(let url), .sameProvider(let url): return (.string(url.path), true)
            case .unresolved: return nil
            }
        case "agent.cliPath", "agent.codexPath":
            guard let path = try? value.decode(PortablePath.self) else { return nil }
            guard case .exact(let url) = path.resolve(home: home, roots: roots),
                  FileManager.default.isExecutableFile(atPath: url.path) else {
                plan.warnings.append(.cliPathDropped(key))
                return nil
            }
            return (.string(url.path), true)
        case ConfigKeys.mailCloudRoot:
            guard let name = value.stringValue, roots.contains(where: { $0.name == name }) else { return nil }
            return (.string(name), true)
        default:
            switch value {
            case .bool, .number, .string: return (value, false)
            case .array(let a) where a.allSatisfy({ if case .number = $0 { return true }; return false }): return (value, false)
            default: return nil
            }
        }
    }

    // MARK: Lists (merged by id)

    /// The file's senders folded into this Mac's (`current`): a rule with the same id — else the
    /// same normalized pattern (`SenderMatcher.Pattern`; this Mac's id is kept, its emails name
    /// it) — is replaced by the file's, the file's other rules are appended, and rules only this
    /// Mac has are kept, in their order. Nothing is loosened:
    /// - a sender this Mac has keeps its AI policy when the file's lets more of its mail go to AI
    ///   (`aiLooseness`: never → ask → always, any kind; an alert's `always` turned into a
    ///   person's — `loosened` lists them, with the policy kept) unless `acceptLooser` accepts
    ///   `ImportLoosening.senderID(<this Mac's id>)`;
    /// - … and its switches turned off here stay off (`guardedSenderSwitches`: the sender itself,
    ///   automatic merge, storing attachments) unless `senderID(<id>, field)` is accepted;
    /// - a new person's / advisor's `always` arrives as `ask` (`clamped` names them) unless
    ///   `keepPeopleAlways`. A new alert sender keeps the file's policy (alerts are public);
    /// - a rule this Mac has under the same id whose pattern the file changed is, for its new
    ///   pattern, also a new rule: where it would take over mail from another, stricter rule of this
    ///   Mac (`keepNewSenderStricter`), it gets that rule's values unless
    ///   `ImportLoosening.newSenderID(<id>, field)` is accepted.
    package static func mergeSenders(current: [SenderRule], imported: [SenderRule], keepPeopleAlways: Bool,
                                     acceptLooser: LooserAcceptance = .none)
        -> (rules: [SenderRule], merge: ImportListMerge, clamped: [String], loosened: [ImportLoosening]) {
        func name(_ r: SenderRule) -> String { r.label.isEmpty ? r.pattern : r.label }
        let matches = match(current: current, imported: imported, id: \.id) { a, b in
            guard let p = SenderMatcher.Pattern(a.pattern) else { return false }
            return SenderMatcher.Pattern(b.pattern) == p
        }
        var clamped: [String] = []
        var loosened: [ImportLoosening] = []
        var incoming = imported
        for j in incoming.indices {
            guard let i = matches[j] else {
                if incoming[j].aiPolicy == .always, incoming[j].kind != .alert, !keepPeopleAlways {
                    incoming[j].aiPolicy = .ask
                    clamped.append(name(incoming[j]))
                }
                // A new rule more specific than one of this Mac's would take over that rule's mail
                // (`SenderMatcher` precedence): never looser than the rule it overrides.
                loosened += keepNewSenderStricter(&incoming[j], current: current, acceptLooser: acceptLooser, name: name)
                continue
            }
            let here = current[i], theirs = incoming[j]
            func keep(_ field: ImportEntryField, mine: JSONValue, theirs value: JSONValue) -> Bool {
                let id = ImportLoosening.senderID(here.id, field)
                let accepted = acceptLooser.accepts(id)
                loosened.append(ImportLoosening(id: id, key: MailSettings.Keys.senders, section: .mailSenders,
                                                subject: name(theirs), field: field, mine: mine, theirs: value,
                                                accepted: accepted))
                return !accepted
            }
            if aiLooseness(theirs) > aiLooseness(here) {
                // The loosest policy of the file's kind that isn't looser than this Mac's rule.
                func with(_ p: MailAIPolicy) -> SenderRule { var r = theirs; r.aiPolicy = p; return r }
                let kept = [MailAIPolicy.always, .ask, .never].first { aiLooseness(with($0)) <= aiLooseness(here) } ?? .never
                if keep(.aiPolicy, mine: .string(kept.rawValue), theirs: .string(theirs.aiPolicy.rawValue)) {
                    incoming[j].aiPolicy = kept
                }
            }
            for (field, path) in guardedSenderSwitches where !here[keyPath: path] && theirs[keyPath: path] {
                if keep(field, mine: .bool(false), theirs: .bool(true)) { incoming[j][keyPath: path] = false }
            }
            // Matched by id but pointed at other mail (a moved pattern): for that mail it is a new
            // rule, checked against this Mac's other rules (this one's old pattern goes away).
            if SenderMatcher.Pattern(theirs.pattern) != SenderMatcher.Pattern(here.pattern) {
                var others = current
                others.remove(at: i)
                loosened += keepNewSenderStricter(&incoming[j], current: others, acceptLooser: acceptLooser, name: name)
            }
        }
        let (rules, merge) = fold(current: current, imported: incoming, matches: matches, name: name) { mine, theirs in
            var r = theirs
            r.id = mine.id
            return r
        }
        return (rules, merge, clamped, loosened)
    }

    /// A sender the file adds whose pattern is more specific than a rule this Mac has — an address
    /// under `@lab.example.edu`, a domain under `@*.lab.example.edu` — wins for that mail
    /// (`SenderMatcher`: exact address > domain > wildcard), so its settings would replace the
    /// broader rule's there. Nothing gets looser: where the rule it takes over from (the one that
    /// matches that mail here now) is stricter, the new rule gets its stricter value — a lower AI
    /// policy (the loosest of the new rule's kind that isn't looser), automatic merge or attachment
    /// storing off — and where this Mac's most specific rule for that mail is turned off, the new
    /// rule arrives turned off, unless `acceptLooser` accepts `ImportLoosening.newSenderID(<file id>, field)`.
    static func keepNewSenderStricter(_ rule: inout SenderRule, current: [SenderRule], acceptLooser: LooserAcceptance,
                                      name: (SenderRule) -> String) -> [ImportLoosening] {
        guard rule.enabled, let probe = probeAddress(rule.pattern) else { return [] }
        let theirs = rule
        var out: [ImportLoosening] = []
        func keep(_ field: ImportEntryField, over here: SenderRule, mine: JSONValue, theirs value: JSONValue) -> Bool {
            let id = ImportLoosening.newSenderID(theirs.id, field)
            let accepted = acceptLooser.accepts(id)
            out.append(ImportLoosening(id: id, key: MailSettings.Keys.senders, section: .mailSenders, subject: name(theirs),
                                       field: field, mine: mine, theirs: value, accepted: accepted, overrides: name(here)))
            return !accepted
        }
        // This Mac's most specific rule for that mail, on or off: off means the user stopped reading it.
        let all = current.map { r -> SenderRule in var x = r; x.enabled = true; return x }
        if let governing = SenderMatcher.match(address: probe, rules: all),
           let here = current.first(where: { $0.id == governing.id }), !here.enabled {
            if keep(.enabled, over: here, mine: .bool(false), theirs: .bool(true)) {
                rule.enabled = false
                return out
            }
        }
        // The rule that reads that mail here now.
        guard let here = SenderMatcher.match(address: probe, rules: current) else { return out }
        if aiLooseness(theirs) > aiLooseness(here) {
            func with(_ p: MailAIPolicy) -> SenderRule { var r = theirs; r.aiPolicy = p; return r }
            let kept = [MailAIPolicy.always, .ask, .never].first { aiLooseness(with($0)) <= aiLooseness(here) } ?? .never
            if keep(.aiPolicy, over: here, mine: .string(kept.rawValue), theirs: .string(theirs.aiPolicy.rawValue)) {
                rule.aiPolicy = kept
            }
        }
        for (field, path) in guardedSenderSwitches where field != .enabled && !here[keyPath: path] && theirs[keyPath: path] {
            if keep(field, over: here, mine: .bool(false), theirs: .bool(true)) { rule[keyPath: path] = false }
        }
        return out
    }

    /// An address only `pattern` (and the rules broader than it) can match, so `SenderMatcher`
    /// tells which of this Mac's rules a new rule would take over from: the address itself, a
    /// mailbox at the domain, a mailbox at a subdomain no domain rule names.
    static func probeAddress(_ pattern: String) -> String? {
        switch SenderMatcher.Pattern(pattern) {
        case .address(let a)?: return a
        case .domain(let d)?: return "paperdeck-import-probe@\(d)"
        case .wildcard(let d)?: return "paperdeck-import-probe@paperdeck-import-probe.\(d)"
        case nil: return nil
        }
    }

    /// The look-back an imported account may have (Settings ▸ Mail offers 3–90 days).
    static let accountLookback = 1...3_650

    /// A sender's switches an import never turns on for a sender this Mac has turned off: the
    /// sender itself (its mail is read), automatic merge, storing its attachments.
    static var guardedSenderSwitches: [(ImportEntryField, WritableKeyPath<SenderRule, Bool>)] {
        [(.enabled, \.enabled), (.autoMerge, \.autoMerge), (.autoDownload, \.autoDownload)]
    }

    /// Every guarded field of a sender (`SettingsRegistryLintTests`: each other field is reviewed).
    package static var guardedSenderFields: [ImportEntryField] { [.aiPolicy] + guardedSenderSwitches.map(\.0) }
    /// Every guarded field of a mail account.
    package static var guardedAccountFields: [ImportEntryField] { [.enabled, .lookbackDays, .deleteProcessedFiles] }

    /// How much of a sender's mail its rule lets go to AI: never < ask < an alert's always (its
    /// mailing-list mail only, `MailSyncActor.isBulk`) < a person's / advisor's always (every email).
    package static func aiLooseness(_ r: SenderRule) -> Int {
        switch r.aiPolicy {
        case .never: return 0
        case .ask: return 1
        case .always: return r.kind == .alert ? 2 : 3
        }
    }

    /// The file's accounts folded into this Mac's (`current`): an account with the same id — else
    /// the same mailbox (IMAP host and address, or the same watched folder; this Mac's id is kept
    /// with its keychain item) — is replaced by the file's, keeping this Mac's mailbox address and
    /// folder where the file has none (personal data left out, a folder not found here); the
    /// file's other accounts are appended and accounts only this Mac has are kept. Nothing is
    /// loosened: an account turned off here stays off and keeps its shorter look-back
    /// (`guardedAccountFields`; `loosened` lists them) unless `acceptLooser` accepts
    /// `ImportLoosening.accountID(<this Mac's id>, field)`.
    /// `existingMailboxes`: indices into `imported` merged into a mailbox this Mac already had
    /// under another id (set up here: no app-password or folder warning).
    package static func mergeAccounts(current: [MailAccount], imported: [MailAccount], acceptLooser: LooserAcceptance = .none)
        -> (accounts: [MailAccount], merge: ImportListMerge, existingMailboxes: Set<Int>, loosened: [ImportLoosening]) {
        func name(_ a: MailAccount) -> String { a.displayName.isEmpty ? a.id : a.displayName }
        let matches = match(current: current, imported: imported, id: \.id, same: sameMailbox)
        var existing: Set<Int> = []
        for (j, i) in matches.enumerated() {
            if let i, current[i].id != imported[j].id { existing.insert(j) }
        }
        var loosened: [ImportLoosening] = []
        var incoming = imported
        for (j, i) in matches.enumerated() {
            guard let i else { continue }
            let here = current[i], theirs = incoming[j]
            func keep(_ field: ImportEntryField, mine: JSONValue, theirs value: JSONValue) -> Bool {
                let id = ImportLoosening.accountID(here.id, field)
                let accepted = acceptLooser.accepts(id)
                loosened.append(ImportLoosening(id: id, key: MailSettings.Keys.accounts, section: .mailAccounts,
                                                subject: name(theirs), field: field, mine: mine, theirs: value,
                                                accepted: accepted))
                return !accepted
            }
            if !here.enabled, theirs.enabled, keep(.enabled, mine: .bool(false), theirs: .bool(true)) {
                incoming[j].enabled = false
            }
            if theirs.lookbackDays > here.lookbackDays,
               keep(.lookbackDays, mine: .number(Double(here.lookbackDays)), theirs: .number(Double(theirs.lookbackDays))) {
                incoming[j].lookbackDays = here.lookbackDays
            }
            // Deleting the captured .eml files (in a synced folder, the cloud copy too) is never
            // switched on for an account this Mac keeps them for.
            if !here.deleteProcessedFiles, theirs.deleteProcessedFiles,
               keep(.deleteProcessedFiles, mine: .bool(false), theirs: .bool(true)) {
                incoming[j].deleteProcessedFiles = false
            }
        }
        let (accounts, merge) = fold(current: current, imported: incoming, matches: matches, name: name) { mine, theirs in
            var a = theirs
            a.id = mine.id
            if a.username?.isEmpty ?? true { a.username = mine.username }
            if a.folderPath?.isEmpty ?? true { a.folderPath = mine.folderPath }
            return a
        }
        return (accounts, merge, existing, loosened)
    }

    /// The same mailbox: IMAP on the same host with the same address, or the same watched folder.
    static func sameMailbox(_ a: MailAccount, _ b: MailAccount) -> Bool {
        guard a.kind == b.kind else { return false }
        switch a.kind {
        case .imap:
            guard let u = a.username?.lowercased(), !u.isEmpty, u == b.username?.lowercased() else { return false }
            return (a.host ?? "").lowercased() == (b.host ?? "").lowercased()
        case .folder:
            guard let p = a.folderPath, !p.isEmpty, let q = b.folderPath, !q.isEmpty else { return false }
            return URL(fileURLWithPath: p).standardizedFileURL.path == URL(fileURLWithPath: q).standardizedFileURL.path
        }
    }

    /// For each imported entry, the index of the entry of `current` it stands for: the same id
    /// first, then (`same`) among the entries no id claimed. Each entry of `current` is claimed once.
    private static func match<T>(current: [T], imported: [T], id: KeyPath<T, String>, same: (T, T) -> Bool) -> [Int?] {
        var out = [Int?](repeating: nil, count: imported.count)
        var taken: Set<Int> = []
        for (j, item) in imported.enumerated() {
            if let i = current.firstIndex(where: { $0[keyPath: id] == item[keyPath: id] }), !taken.contains(i) {
                out[j] = i
                taken.insert(i)
            }
        }
        for (j, item) in imported.enumerated() where out[j] == nil {
            if current.contains(where: { $0[keyPath: id] == item[keyPath: id] }) { continue }   // a duplicate id
            if let i = current.indices.first(where: { !taken.contains($0) && same(current[$0], item) }) {
                out[j] = i
                taken.insert(i)
            }
        }
        return out
    }

    /// `current` with the matched entries replaced (`combine(mine, theirs)`) and the unmatched
    /// imported ones appended (one per id), plus what was added / replaced / kept.
    private static func fold<T: Equatable>(current: [T], imported: [T], matches: [Int?], name: (T) -> String,
                                           combine: (T, T) -> T) -> ([T], ImportListMerge) where T: Identifiable, T.ID == String {
        var result = current
        var merge = ImportListMerge()
        var replaced: Set<Int> = []
        var appended: Set<String> = []
        for (j, item) in imported.enumerated() {
            if let i = matches[j] {
                let next = combine(current[i], item)
                if next != current[i], !replaced.contains(i) {
                    result[i] = next
                    replaced.insert(i)
                    merge.replaced.append(name(next))
                }
            } else if !current.contains(where: { $0.id == item.id }), appended.insert(item.id).inserted {
                result.append(item)
                merge.added.append(name(item))
            }
        }
        merge.kept = current.indices.filter { !replaced.contains($0) }.map { name(current[$0]) }
        return (result, merge)
    }

    /// Whether a planned write equals what the domain holds (JSON settings compared decoded).
    private static func sameValue(_ key: String, _ current: Any, _ write: JSONValue) -> Bool {
        switch key {
        case MailSettings.Keys.senders:
            return MailSettings.list(current as? String, SenderRule.self, what: "sender")
                == MailSettings.list(write.stringValue, SenderRule.self, what: "sender")
        case MailSettings.Keys.accounts:
            return MailSettings.list(current as? String, MailAccount.self, what: "account")
                == MailSettings.list(write.stringValue, MailAccount.self, what: "account")
        case MailSettings.Keys.criteria:
            func decode(_ s: String?) -> ReadingCriteria? {
                s.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(ReadingCriteria.self, from: $0) }
            }
            return decode(current as? String) == decode(write.stringValue)
        case ConfigKeys.orgCustom:
            return (current as? String).flatMap(ConfigResolver.decodeCustom) == write.stringValue.flatMap(ConfigResolver.decodeCustom)
        default:
            return SettingsTransferValues.json(current) == write
        }
    }
}
