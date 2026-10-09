import Foundation
import Testing
@testable import PaperDeckCore
@testable import PaperDeckConfig

/// Portability verification regression #2: since a lab setup file carries the triage preferences,
/// importing one into a Mac set to "Local rules only" (nothing is ever sent to AI) with a daily cap
/// of 30 wrote `mail.aiMode` heuristic_only → ai and `mail.triageDailyMax` 30 → 200 with no
/// confirmation. An import now never loosens a privacy- or quota-sensitive setting
/// (`SettingsSensitivity`) silently: this Mac's stricter value is kept and listed
/// (`ImportPlan.loosenings`, "Kept stricter" in the sheet), and only that item's opt-in
/// (`LooserAcceptance`; the CLI's `--accept-looser`) writes the looser value. Pure: synthetic
/// domains and bundles only.
@Suite struct PFSettingsNeverLoosenTests {
    static let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// A file exported from `d` (`sections`: a lab setup file is profile, organization, mail senders).
    static func bundle(_ d: [String: Any], sections: Set<SettingsSection> = Set(SettingsSection.allCases)) -> SettingsBundle {
        SettingsExporter.export(PersistedDomain(d), sections: sections, includePersonal: false, home: home, roots: [],
                                app: "PaperDeck 1.0 (27)", now: now)
    }

    static func plan(_ b: SettingsBundle, current: [String: Any], accept: LooserAcceptance = .none,
                     keepPeopleAlways: Bool = false) -> ImportPlan {
        SettingsImporter.plan(b, current: PersistedDomain(current), sections: Set(SettingsSection.allCases),
                              keepPeopleAlways: keepPeopleAlways, acceptReaderDescription: false, acceptLooser: accept,
                              home: home, roots: [])
    }

    static func senders(_ p: ImportPlan) -> [SenderRule] {
        MailSettings.list(p.writes[MailSettings.Keys.senders]?.stringValue, SenderRule.self, what: "s")
    }

    // MARK: The probe of the report

    @Test func aLabFileDoesNotTurnOnAITriageOrRaiseTheCap() throws {
        let here: [String: Any] = [MailSettings.Keys.aiMode: "heuristic_only", MailSettings.Keys.triageDailyMax: 30]
        let lab = Self.bundle([MailSettings.Keys.aiMode: "ai", MailSettings.Keys.triageDailyMax: 200,
                               ConfigKeys.profileField: "neuroCognitive"],
                              sections: [.profile, .organization, .mailSenders])
        let p = Self.plan(lab, current: here)
        #expect(p.writes[MailSettings.Keys.aiMode] == nil && p.writes[MailSettings.Keys.triageDailyMax] == nil)
        #expect(!p.changes.contains { $0.key == MailSettings.Keys.aiMode || $0.key == MailSettings.Keys.triageDailyMax })
        #expect(p.writes[ConfigKeys.profileField] == .string("neuroCognitive"))          // the rest still imports
        #expect(p.keptStricter.map(\.id) == [MailSettings.Keys.aiMode, MailSettings.Keys.triageDailyMax])
        let mode = try #require(p.loosenings.first { $0.id == MailSettings.Keys.aiMode })
        #expect(mode.mine == .string("heuristic_only") && mode.theirs == .string("ai") && !mode.accepted)
        #expect(mode.section == .mailSenders && mode.subject == nil)
        let cap = try #require(p.loosenings.first { $0.id == MailSettings.Keys.triageDailyMax })
        #expect(cap.mine == .number(30) && cap.theirs == .number(200))

        // One item ticked: only that one is written (and listed as confirmed).
        let one = Self.plan(lab, current: here, accept: .only([MailSettings.Keys.aiMode]))
        #expect(one.writes[MailSettings.Keys.aiMode] == .string("ai") && one.writes[MailSettings.Keys.triageDailyMax] == nil)
        #expect(one.changes.first { $0.key == MailSettings.Keys.aiMode }?.needsConfirmation == true)
        #expect(one.keptStricter.map(\.id) == [MailSettings.Keys.triageDailyMax])
        #expect(one.loosenings.count == 2 && one.loosenings.first { $0.id == MailSettings.Keys.aiMode }?.accepted == true)
        // The CLI's --accept-looser: every looser value.
        let all = Self.plan(lab, current: here, accept: .all)
        #expect(all.writes[MailSettings.Keys.aiMode] == .string("ai") && all.writes[MailSettings.Keys.triageDailyMax] == .number(200))
        #expect(all.keptStricter.isEmpty && all.loosenings.allSatisfy(\.accepted))
    }

    // MARK: Every sensitive key

    @Test func anAbsentKeyIsComparedWithTheAppsDefault() {
        // A fresh Mac (nothing stored): the defaults are what it uses.
        let looser: [String: Any] = [
            MailSettings.Keys.triageDailyMax: 200, MailSettings.Keys.triageBodyCap: 50_000,
            MailSettings.Keys.maxAttachmentMB: 200, MailSettings.Keys.notifyNewRequests: true,
            MailSettings.Keys.retentionDays: 0, MailSettings.Keys.syncMinutes: 5,
            MailSettings.Keys.triageModelClaude: "sonnet", MailSettings.Keys.triageModelCodex: "gpt-5.6-terra",
            "agent.textBudget": 200_000, "agent.model": "opus", "agent.codexModel": "gpt-5.6-sol",
        ]
        let p = Self.plan(Self.bundle(looser), current: [:])
        #expect(Set(p.keptStricter.map(\.id)) == Set(looser.keys), "\(p.keptStricter.map(\.id))")
        #expect(p.writes.isEmpty, "\(p.writes.keys.sorted())")
        #expect(p.loosenings.first { $0.id == MailSettings.Keys.retentionDays }?.mine == .number(30))
        #expect(p.loosenings.first { $0.id == "agent.model" }?.mine == .string("sonnet"))
        // The defaults themselves, and stricter values, import as before.
        let fine: [String: Any] = [
            MailSettings.Keys.aiMode: "ai", MailSettings.Keys.triageDailyMax: 10, MailSettings.Keys.triageBodyCap: 4_000,
            MailSettings.Keys.maxAttachmentMB: 20, MailSettings.Keys.notifyNewRequests: false,
            MailSettings.Keys.retentionDays: 7, MailSettings.Keys.syncMinutes: 0, MailSettings.Keys.triageModelClaude: "haiku",
            "agent.autoRead": true, "agent.textBudget": 60_000, "agent.effort": "low", "agent.model": "haiku",
            "metadata.lookup": true, "plan.dailyBudget": 90,
        ]
        let q = Self.plan(Self.bundle(fine), current: [:])
        #expect(q.loosenings.isEmpty, "\(q.loosenings.map(\.id))")
        #expect(Set(q.writes.keys) == Set(fine.keys))
    }

    @Test func switchesTurnedOffHereStayOff() {
        let here: [String: Any] = ["agent.autoRead": false, MailSettings.Keys.notifyNewRequests: false,
                                   "metadata.lookup": false, "agent.effort": "low", MailSettings.Keys.retentionDays: 14,
                                   MailSettings.Keys.syncMinutes: 0]
        let there: [String: Any] = ["agent.autoRead": true, MailSettings.Keys.notifyNewRequests: true,
                                    "metadata.lookup": true, "agent.effort": "medium", MailSettings.Keys.retentionDays: 30,
                                    MailSettings.Keys.syncMinutes: 60]
        let p = Self.plan(Self.bundle(there), current: here)
        #expect(Set(p.keptStricter.map(\.id)) == Set(there.keys))
        #expect(p.writes.isEmpty && p.changes.isEmpty)
        let auto = p.loosenings.first { $0.id == "agent.autoRead" }
        #expect(auto?.mine == .bool(false) && auto?.theirs == .bool(true))
        // Tightening is never held back: the other way round everything is written.
        let back = Self.plan(Self.bundle(here), current: there)
        #expect(back.loosenings.isEmpty)
        #expect(Set(back.writes.keys) == Set(here.keys))
    }

    @Test func theOrdersOfTheSensitiveKeys() throws {
        func s(_ key: String) throws -> SettingsSensitivity { try #require(SettingsRegistry.entry(key)?.sensitivity, "\(key)") }
        // Retention: 0 or less keeps forever (the loosest).
        let keep = try s(MailSettings.Keys.retentionDays)
        #expect(keep.isLooser(.number(0), than: 30 as NSNumber) && keep.isLooser(.number(-1), than: 365 as NSNumber))
        #expect(!keep.isLooser(.number(90), than: 0 as NSNumber) && keep.isLooser(.number(90), than: nil))
        // Sync: manual only (0) is the strictest; a shorter interval is looser.
        let sync = try s(MailSettings.Keys.syncMinutes)
        #expect(sync.isLooser(.number(60), than: 0 as NSNumber) && sync.isLooser(.number(5), than: 15 as NSNumber))
        #expect(!sync.isLooser(.number(0), than: 5 as NSNumber) && !sync.isLooser(.number(30), than: 15 as NSNumber))
        // A model the list doesn't know can't be proven lighter.
        let model = try s("agent.model")
        #expect(model.isLooser(.string("opus-9"), than: "haiku" as NSString) && !model.isLooser(.string("haiku"), than: "opus-9" as NSString))
        #expect(!model.isLooser(.string("sonnet"), than: "sonnet" as NSString))
        // A value of the wrong type counts as looser; a number 1 for a switch is on.
        let notify = try s(MailSettings.Keys.notifyNewRequests)
        #expect(notify.isLooser(.string("yes"), than: false as NSNumber) && notify.isLooser(.number(1), than: nil))
        #expect(!notify.isLooser(.number(0), than: nil) && !notify.isLooser(.bool(true), than: true as NSNumber))
    }

    // MARK: Senders (every kind)

    @Test func aSendersAIPolicyIsNeverRaised() throws {
        let here = [SenderRule(id: "nat", pattern: "@*.nature.com", label: "Nature", kind: .alert, aiPolicy: .ask),
                    SenderRule(id: "pi", pattern: "pi@lab.example.edu", label: "PI", kind: .advisor, aiPolicy: .never),
                    SenderRule(id: "amy", pattern: "amy@lab.example.edu", label: "Amy", kind: .person, aiPolicy: .ask),
                    SenderRule(id: "lab", pattern: "@lab.example.edu", label: "Lab", kind: .alert, aiPolicy: .always),
                    SenderRule(id: "bio", pattern: "@biorxiv.org", label: "bioRxiv", kind: .alert, aiPolicy: .always)]
        let file = [SenderRule(id: "nat", pattern: "@*.nature.com", label: "Nature", kind: .alert, aiPolicy: .always),
                    SenderRule(id: "pi-old", pattern: "PI@lab.example.edu", label: "Prof. Smith", kind: .advisor, aiPolicy: .ask),
                    SenderRule(id: "amy", pattern: "amy@lab.example.edu", label: "Amy", kind: .person, aiPolicy: .always),
                    // An alert's "always" (list mail only) turned into a person's (every email).
                    SenderRule(id: "lab", pattern: "@lab.example.edu", label: "Lab", kind: .person, aiPolicy: .always),
                    // Tightened in the file: applied.
                    SenderRule(id: "bio", pattern: "@biorxiv.org", label: "bioRxiv", kind: .alert, aiPolicy: .never)]
        let b = Self.bundle([MailSettings.Keys.senders: MailSettings.encode(file)])
        let current: [String: Any] = [MailSettings.Keys.senders: MailSettings.encode(here)]
        let p = Self.plan(b, current: current, keepPeopleAlways: true)        // the new-sender opt-out changes nothing here
        let rules = Self.senders(p)
        #expect(rules.map(\.id) == ["nat", "pi", "amy", "lab", "bio"])
        #expect(rules.map(\.aiPolicy) == [.ask, .never, .ask, .ask, .never])
        try #require(rules.count > 3)          // no index past a failed expectation (QA-15)
        #expect(rules[1].label == "Prof. Smith" && rules[3].kind == .person)     // everything else is the file's
        #expect(p.keptStricter.map(\.id) == ["nat", "pi", "amy", "lab"].map { ImportLoosening.senderID($0) })
        #expect(p.keptStricter.map(\.subject) == ["Nature", "Prof. Smith", "Amy", "Lab"])
        #expect(p.keptStricter.map(\.mine) == [.string("ask"), .string("never"), .string("ask"), .string("ask")])
        #expect(p.keptStricter.map(\.theirs) == [.string("always"), .string("ask"), .string("always"), .string("always")])
        #expect(!p.warnings.contains { if case .peopleAlwaysClamped = $0 { true } else { false } })
        // One sender accepted: only its policy is raised.
        let one = Self.plan(b, current: current, accept: .only([ImportLoosening.senderID("nat")]))
        #expect(Self.senders(one).map(\.aiPolicy) == [.always, .never, .ask, .ask, .never])
        #expect(one.changes.first { $0.key == MailSettings.Keys.senders }?.needsConfirmation == true)
        #expect(Self.senders(Self.plan(b, current: current, accept: .all)).map(\.aiPolicy) == [.always, .ask, .always, .always, .never])
    }

    @Test func onlyThePolicyDifferenceKeepsTheListAsItIs() {
        let here = [SenderRule(id: "nat", pattern: "@*.nature.com", label: "Nature", kind: .alert, aiPolicy: .never)]
        var there = here
        there[0].aiPolicy = .always
        let p = Self.plan(Self.bundle([MailSettings.Keys.senders: MailSettings.encode(there)]),
                          current: [MailSettings.Keys.senders: MailSettings.encode(here)])
        #expect(p.writes[MailSettings.Keys.senders] == nil && p.changes.isEmpty && p.merges.isEmpty)
        #expect(p.keptStricter.map(\.id) == [ImportLoosening.senderID("nat")])
    }

    // MARK: A sender's and an account's switches (every field the lint classifies as guarded)

    @Test func aSendersSwitchesTurnedOffHereStayOff() throws {
        let here = [SenderRule(id: "pi", pattern: "pi@lab.example.edu", label: "PI", kind: .advisor, enabled: false,
                               autoMerge: false, autoDownload: false),
                    SenderRule(id: "nat", pattern: "@*.nature.com", label: "Nature", kind: .alert, autoMerge: true, autoDownload: true)]
        var file = here
        file[0].enabled = true
        file[0].autoMerge = true
        file[0].autoDownload = true
        file[0].label = "Prof. Smith"
        file[1].autoMerge = false                           // tightened in the file: applied
        file[1].autoDownload = false
        let new = SenderRule(id: "amy", pattern: "amy@lab.example.edu", label: "Amy", kind: .person, autoMerge: true)
        let b = Self.bundle([MailSettings.Keys.senders: MailSettings.encode(file + [new])])
        let current: [String: Any] = [MailSettings.Keys.senders: MailSettings.encode(here)]
        let p = Self.plan(b, current: current)
        let rules = Self.senders(p)
        #expect(rules.map(\.id) == ["pi", "nat", "amy"])
        try #require(rules.count > 2)          // no index past a failed expectation (QA-15)
        #expect(!rules[0].enabled && !rules[0].autoMerge && !rules[0].autoDownload && rules[0].label == "Prof. Smith")
        #expect(!rules[1].autoMerge && !rules[1].autoDownload)
        #expect(rules[2] == new)                            // a new sender: nothing here to compare with
        let ids = [ImportEntryField.enabled, .autoMerge, .autoDownload].map { ImportLoosening.senderID("pi", $0) }
        #expect(p.keptStricter.map(\.id) == ids)
        #expect(p.keptStricter.allSatisfy {
            $0.mine == .bool(false) && $0.theirs == .bool(true) && $0.subject == "Prof. Smith"
                && $0.section == .mailSenders && $0.key == MailSettings.Keys.senders && $0.field != nil
        })
        // One switch accepted: only that one is turned on (and the list change is confirmed).
        let one = Self.plan(b, current: current, accept: .only([ImportLoosening.senderID("pi", .autoDownload)]))
        let r = Self.senders(one)[0]
        #expect(r.autoDownload && !r.autoMerge && !r.enabled)
        #expect(one.changes.first { $0.key == MailSettings.Keys.senders }?.needsConfirmation == true)
        let all = Self.senders(Self.plan(b, current: current, accept: .all))[0]
        #expect(all.enabled && all.autoMerge && all.autoDownload)
    }

    @Test func anAccountTurnedOffHereStaysOffAndKeepsItsLookBack() {
        func accounts(_ p: ImportPlan) -> [MailAccount] {
            MailSettings.list(p.writes[MailSettings.Keys.accounts]?.stringValue, MailAccount.self, what: "a")
        }
        let here = MailAccount(id: "gm", kind: .imap, displayName: "Gmail", enabled: false, lookbackDays: 14,
                               imapPreset: .gmail, host: "imap.gmail.com", port: 993, username: "me@gmail.com")
        var there = here
        there.enabled = true
        there.lookbackDays = 90
        there.mailbox = "PaperDeck"                         // not guarded: imported
        let current: [String: Any] = [MailSettings.Keys.accounts: MailSettings.encode([here])]
        let b = Self.bundle([MailSettings.Keys.accounts: MailSettings.encode([there])])
        let p = Self.plan(b, current: current)
        let merged = accounts(p)
        #expect(merged.count == 1 && merged[0].id == "gm" && !merged[0].enabled && merged[0].lookbackDays == 14)
        #expect(merged.first?.mailbox == "PaperDeck")
        #expect(p.keptStricter.map(\.id) == [ImportLoosening.accountID("gm", .enabled), ImportLoosening.accountID("gm", .lookbackDays)])
        #expect(p.keptStricter.last?.mine == .number(14) && p.keptStricter.last?.theirs == .number(90))
        #expect(p.keptStricter.allSatisfy { $0.section == .mailAccounts && $0.key == MailSettings.Keys.accounts && $0.subject == "Gmail" })
        let all = accounts(Self.plan(b, current: current, accept: .all))
        #expect(all.first?.enabled == true && all.first?.lookbackDays == 90)
        // Only a guarded field differs: nothing is written, the item is listed.
        var onlyOn = here
        onlyOn.enabled = true
        let q = Self.plan(Self.bundle([MailSettings.Keys.accounts: MailSettings.encode([onlyOn])]), current: current)
        #expect(q.writes[MailSettings.Keys.accounts] == nil && q.changes.isEmpty)
        #expect(q.keptStricter.map(\.id) == [ImportLoosening.accountID("gm", .enabled)])
        // An account this Mac doesn't have is added as it is; one turned off in the file is turned off.
        var other = there
        other.id = "yahoo"
        other.host = "imap.mail.yahoo.com"
        other.username = "me@yahoo.com"
        var off = here
        off.enabled = true
        let tightened = Self.plan(Self.bundle([MailSettings.Keys.accounts: MailSettings.encode([here, other])]),
                                  current: [MailSettings.Keys.accounts: MailSettings.encode([off])])
        #expect(tightened.loosenings.isEmpty && accounts(tightened).map(\.enabled) == [false, true])
    }

    // MARK: The institution's people default

    @Test func theInstitutionsPeopleDefaultNeverStaysNever() throws {
        let strict = OrganizationPresets.custom(name: "Lab Institute", shortName: "LI", approvedAITools: [], policyURL: nil,
                                                peopleDefault: .never, oneDriveRootHint: nil)
        var asking = strict
        asking.peopleDefault = .ask
        asking.shortName = "LI2"
        let here: [String: Any] = [ConfigKeys.orgPreset: "custom", ConfigKeys.orgCustom: ConfigResolver.encodeCustom(strict)]
        // The file's own custom institution: written, with this Mac's "never".
        let custom = Self.bundle([ConfigKeys.orgPreset: "custom", ConfigKeys.orgCustom: ConfigResolver.encodeCustom(asking)])
        let p = Self.plan(custom, current: here)
        let written = try #require(p.writes[ConfigKeys.orgCustom]?.stringValue.flatMap(ConfigResolver.decodeCustom))
        #expect(written.peopleDefault == .never && written.shortName == "LI2")
        #expect(p.keptStricter.map(\.id) == [ImportLoosening.peopleDefaultID])
        #expect(p.keptStricter.first?.mine == .string("never") && p.keptStricter.first?.theirs == .string("ask"))
        #expect(p.changes.contains { $0.key == ConfigKeys.orgCustom })
        let accepted = Self.plan(custom, current: here, accept: .only([ImportLoosening.peopleDefaultID]))
        #expect(accepted.writes[ConfigKeys.orgCustom]?.stringValue.flatMap(ConfigResolver.decodeCustom)?.peopleDefault == .ask)
        // A built-in preset (they all ask): the switch is not made unless accepted.
        let preset = Self.bundle([ConfigKeys.orgPreset: "washu"])
        let q = Self.plan(preset, current: here)
        #expect(q.writes[ConfigKeys.orgPreset] == nil && !q.changes.contains { $0.key == ConfigKeys.orgPreset })
        #expect(q.keptStricter.map(\.id) == [ImportLoosening.peopleDefaultID])
        #expect(Self.plan(preset, current: here, accept: .all).writes[ConfigKeys.orgPreset] == .string("washu"))
        // A Mac that asks already: nothing is held back.
        let open: [String: Any] = [ConfigKeys.orgPreset: "custom", ConfigKeys.orgCustom: ConfigResolver.encodeCustom(asking)]
        #expect(Self.plan(preset, current: open).loosenings.isEmpty)
    }
}
