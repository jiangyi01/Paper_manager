import Foundation
import Testing
@testable import PaperDeckCore
@testable import PaperDeckConfig

/// Portability verification F4: the reading criteria, the due-date order and the triage
/// preferences were registered under "Mail accounts (no passwords)", so a lab setup file
/// (Profile & institution + "Mail senders & criteria") carried the sender list only, and unticking
/// the accounts (to keep mailbox addresses out) silently dropped the criteria. They now belong to
/// the senders & criteria section; files written by earlier builds still import them from where
/// those builds filed them. Pure: synthetic domains, no defaults, no keychain.
@Suite struct PFSettingsSectionsTests {
    static let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static let criteria = ReadingCriteria(includeKeywords: ["radial glia"], researchInterests: "cortical development",
                                          customInstructions: "Prefer primary research.")

    /// A domain with senders, criteria, triage preferences, accounts and fetch preferences.
    static func domain() -> [String: Any] {
        [
            MailSettings.Keys.senders: MailSettings.encode([SenderRule(id: "adv", pattern: "pi@lab.example.edu", label: "PI",
                                                                       kind: .advisor)]),
            MailSettings.Keys.criteria: MailSettings.encode(criteria),
            MailSettings.Keys.dateOrder: "dmy",
            MailSettings.Keys.aiMode: "heuristicOnly",
            MailSettings.Keys.triageProvider: "codex",
            MailSettings.Keys.triageDailyMax: 12,
            MailSettings.Keys.triageBodyCap: 8000,
            MailSettings.Keys.accounts: MailSettings.encode([MailAccount(id: "gm", kind: .imap, displayName: "Gmail",
                                                                         imapPreset: .gmail, host: "imap.gmail.com",
                                                                         port: 993, username: "me@gmail.com")]),
            MailSettings.Keys.syncMinutes: 30,
            MailSettings.Keys.retentionDays: 60,
            ConfigKeys.profileField: "lifeSciencesCompBio",
        ]
    }

    static func export(_ d: [String: Any], _ sections: Set<SettingsSection>) -> SettingsBundle {
        SettingsExporter.export(PersistedDomain(d), sections: sections, includePersonal: false, includeAddresses: false, home: home, roots: [],
                                app: "PaperDeck test", now: now)
    }

    static let movedKeys = [MailSettings.Keys.criteria, MailSettings.Keys.dateOrder, MailSettings.Keys.aiMode,
                            MailSettings.Keys.triageProvider, MailSettings.Keys.triageModelClaude,
                            MailSettings.Keys.triageModelCodex, MailSettings.Keys.triageDailyMax, MailSettings.Keys.triageBodyCap]

    @Test func criteriaDateOrderAndTriageBelongToSendersAndCriteria() {
        for key in Self.movedKeys {
            #expect(SettingsRegistry.entry(key)?.section == .mailSenders, "\(key)")
            #expect(SettingsRegistry.formerSections[key] == .mailAccounts, "\(key)")
        }
        #expect(SettingsRegistry.entry(MailSettings.Keys.senders)?.section == .mailSenders)
        for key in [MailSettings.Keys.accounts, ConfigKeys.mailCloudRoot, MailSettings.Keys.syncMinutes,
                    MailSettings.Keys.maxAttachmentMB, MailSettings.Keys.retentionDays] {
            #expect(SettingsRegistry.entry(key)?.section == .mailAccounts, "\(key)")
        }
        #expect(SettingsRegistry.entry(MailSettings.Keys.enabled)?.keyClass == .never)
    }

    @Test func aLabSetupFileCarriesTheCriteria() throws {
        let b = Self.export(Self.domain(), [.profile, .organization, .mailSenders])
        let senders = try #require(b.sections["mailSenders"]?.objectValue)
        for key in [MailSettings.Keys.senders, MailSettings.Keys.criteria, MailSettings.Keys.dateOrder, MailSettings.Keys.aiMode,
                    MailSettings.Keys.triageProvider, MailSettings.Keys.triageDailyMax, MailSettings.Keys.triageBodyCap] {
            #expect(senders[key] != nil, "\(key)")
        }
        #expect(try senders[MailSettings.Keys.criteria]?.decode(ReadingCriteria.self) == Self.criteria)
        // Nothing of the user's own mailboxes.
        #expect(b.sections["mailAccounts"] == nil)
        let text = String(decoding: try JSONEncoder().encode(b), as: UTF8.self)
        #expect(!text.contains("me@gmail.com") && !text.contains("imap.gmail.com"))
        #expect(b.sections["profile"]?[ConfigKeys.profileField] == .string("lifeSciencesCompBio"))

        // …and importing just that section writes them.
        let plan = SettingsImporter.plan(b, current: PersistedDomain([:]), sections: [.mailSenders], keepPeopleAlways: false,
                                         acceptReaderDescription: false, home: Self.home, roots: [])
        #expect(MailSettings.list(plan.writes[MailSettings.Keys.senders]?.stringValue, SenderRule.self, what: "s").map(\.id) == ["adv"])
        // The custom instructions (they enter the triage prompt) wait for "Use these instructions"
        // (integration round); the rest of the criteria imports.
        let written = try #require(plan.writes[MailSettings.Keys.criteria]?.stringValue)
        var held = Self.criteria
        held.customInstructions = ""
        #expect(try JSONDecoder().decode(ReadingCriteria.self, from: Data(written.utf8)) == held)
        #expect(plan.criteriaInstructions == Self.criteria.customInstructions && plan.warnings.contains(.criteriaInstructionsNeedConfirm))
        let confirmed = SettingsImporter.plan(b, current: PersistedDomain([:]), sections: [.mailSenders], keepPeopleAlways: false,
                                              acceptReaderDescription: false, acceptCriteriaInstructions: true,
                                              home: Self.home, roots: [])
        let all = try #require(confirmed.writes[MailSettings.Keys.criteria]?.stringValue)
        #expect(try JSONDecoder().decode(ReadingCriteria.self, from: Data(all.utf8)) == Self.criteria)
        #expect(plan.writes[MailSettings.Keys.dateOrder] == .string("dmy"))
        #expect(plan.writes[MailSettings.Keys.triageDailyMax] == .number(12))
        #expect(plan.changes.filter { Self.movedKeys.contains($0.key) }.allSatisfy { $0.section == .mailSenders })
        #expect(!plan.warnings.contains { if case .unknownKeysIgnored = $0 { true } else { false } })
    }

    @Test func untickingMailAccountsKeepsTheCriteria() throws {
        let all = Set(SettingsSection.allCases).subtracting([.mailAccounts])
        let b = Self.export(Self.domain(), all)
        #expect(b.sections["mailSenders"]?[MailSettings.Keys.criteria] != nil)
        #expect(b.sections["mailAccounts"] == nil)
        // The accounts section alone carries the mailboxes and their fetch preferences only.
        let accounts = Self.export(Self.domain(), [.mailAccounts])
        let keys = Set(accounts.sections["mailAccounts"]?.objectValue?.keys.map { $0 } ?? [])
        #expect(keys == [MailSettings.Keys.accounts, MailSettings.Keys.syncMinutes, MailSettings.Keys.retentionDays])
    }

    /// A file from an earlier build (criteria under "mailAccounts") still imports them — under the
    /// accounts checkbox, as that build offered them — and reports them under their section now.
    @Test func anOlderFileStillImportsTheCriteriaFromTheAccountsSection() throws {
        let criteria = try JSONValue.from(Self.criteria)
        let old = SettingsBundle(exportedAt: Self.now, app: "PaperDeck 1.0 (27)", sections: [
            "mailSenders": .object([MailSettings.Keys.senders: .array([])]),
            "mailAccounts": .object([MailSettings.Keys.criteria: criteria, MailSettings.Keys.dateOrder: .string("dmy"),
                                     MailSettings.Keys.triageDailyMax: .number(9), MailSettings.Keys.syncMinutes: .number(30)]),
        ])
        let plan = SettingsImporter.plan(old, current: PersistedDomain([:]), sections: [.mailAccounts], keepPeopleAlways: false,
                                         acceptReaderDescription: false, home: Self.home, roots: [])
        #expect(plan.writes[MailSettings.Keys.criteria] != nil)
        #expect(plan.writes[MailSettings.Keys.dateOrder] == .string("dmy"))
        #expect(plan.writes[MailSettings.Keys.triageDailyMax] == .number(9))
        #expect(plan.writes[MailSettings.Keys.syncMinutes] == .number(30))
        #expect(plan.changes.first { $0.key == MailSettings.Keys.criteria }?.section == .mailSenders)
        #expect(!plan.warnings.contains { if case .unknownKeysIgnored = $0 { true } else { false } })
        // Not chosen → not written.
        let without = SettingsImporter.plan(old, current: PersistedDomain([:]), sections: [.mailSenders], keepPeopleAlways: false,
                                            acceptReaderDescription: false, home: Self.home, roots: [])
        #expect(without.writes[MailSettings.Keys.criteria] == nil && without.writes[MailSettings.Keys.syncMinutes] == nil)
        // A key in a section that never held it is still ignored.
        let forged = SettingsBundle(exportedAt: Self.now, app: "x", sections: [
            "plan": .object([MailSettings.Keys.criteria: criteria]),
        ])
        let refused = SettingsImporter.plan(forged, current: PersistedDomain([:]), sections: Set(SettingsSection.allCases),
                                            keepPeopleAlways: false, acceptReaderDescription: false, home: Self.home, roots: [])
        #expect(refused.writes.isEmpty && refused.warnings.contains(.unknownKeysIgnored(1)))
    }
}
