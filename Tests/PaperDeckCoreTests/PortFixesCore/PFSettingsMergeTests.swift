import Foundation
import Testing
@testable import PaperDeckCore
@testable import PaperDeckConfig

/// Portability verification F12: an import replaced `mail.accounts` and `mail.senders` wholesale,
/// so an account or sender added on the new Mac before importing an older file (onboarding) was
/// dropped — its keychain item orphaned. Lists are now merged by id (a sender also by its
/// normalized pattern, a mailbox also by its address or folder; this Mac's id is kept): entries
/// only this Mac has are kept, and the plan reports what is added / replaced / kept for the sheet.
/// Pure: synthetic domains only.
@Suite struct PFSettingsMergeTests {
    static let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func bundle(senders: [SenderRule] = [], accounts: [MailAccount] = [], personal: Bool = false) -> SettingsBundle {
        var d: [String: Any] = [:]
        if !senders.isEmpty { d[MailSettings.Keys.senders] = MailSettings.encode(senders) }
        if !accounts.isEmpty { d[MailSettings.Keys.accounts] = MailSettings.encode(accounts) }
        return SettingsExporter.export(PersistedDomain(d), sections: Set(SettingsSection.allCases), includePersonal: personal, includeAddresses: personal,
                                       home: home, roots: [], app: "PaperDeck 1.0 (27)", now: now)
    }

    static func plan(_ b: SettingsBundle, current: [String: Any], keep: Bool = false) -> ImportPlan {
        SettingsImporter.plan(b, current: PersistedDomain(current), sections: Set(SettingsSection.allCases), keepPeopleAlways: keep,
                              acceptReaderDescription: false, home: home, roots: [])
    }

    static func senders(_ p: ImportPlan) -> [SenderRule] {
        MailSettings.list(p.writes[MailSettings.Keys.senders]?.stringValue, SenderRule.self, what: "s")
    }

    static func accounts(_ p: ImportPlan) -> [MailAccount] {
        MailSettings.list(p.writes[MailSettings.Keys.accounts]?.stringValue, MailAccount.self, what: "a")
    }

    // MARK: Senders

    @Test func sendersOnlyThisMacHasAreKept() throws {
        let advisorHere = SenderRule(id: "new-advisor", pattern: "pi@lab.example.edu", label: "PI", kind: .advisor)
        let nature = SenderRule.presets.first { $0.id == "preset-nature" }!
        let colleague = SenderRule(id: "old-colleague", pattern: "@lab.example.edu", label: "Lab", kind: .person)
        let p = Self.plan(Self.bundle(senders: [nature, colleague]),
                          current: [MailSettings.Keys.senders: MailSettings.encode([advisorHere, nature])])
        #expect(Self.senders(p).map(\.id) == ["new-advisor", "preset-nature", "old-colleague"])
        #expect(p.merges[MailSettings.Keys.senders] == ImportListMerge(added: ["Lab"], replaced: [], kept: ["PI", "Nature"]))
        let m = try #require(p.merges[MailSettings.Keys.senders])
        #expect(m.addCount == 1 && m.replaceCount == 0 && m.keepCount == 2)
    }

    @Test func aSenderWithTheSameIdOrPatternIsReplacedKeepingThisMacsId() throws {
        let here = [SenderRule(id: "a", pattern: "pi@lab.example.edu", label: "PI", kind: .advisor),
                    SenderRule(id: "new-uuid", pattern: "Amy@Lab.Example.edu", label: "", kind: .person)]
        let file = [SenderRule(id: "a", pattern: "pi@lab.example.edu", label: "Prof. Smith", kind: .advisor, defaultCategory: "Lab"),
                    SenderRule(id: "old-uuid", pattern: "amy@lab.example.edu", label: "Amy", kind: .person, autoMerge: true)]
        let merged = SettingsImporter.mergeSenders(current: here, imported: file, keepPeopleAlways: false)
        #expect(merged.rules.map(\.id) == ["a", "new-uuid"])                    // no duplicate pattern, ids kept
        try #require(merged.rules.count > 1)          // no index past a failed expectation (QA-15)
        #expect(merged.rules[0].label == "Prof. Smith" && merged.rules[0].defaultCategory == "Lab")
        // Automatic merge off here stays off unless accepted (regression #2, `PFSettingsNeverLoosenTests`).
        #expect(merged.rules[1].label == "Amy" && !merged.rules[1].autoMerge)
        #expect(merged.loosened.map(\.id) == [ImportLoosening.senderID("new-uuid", .autoMerge)])
        #expect(SettingsImporter.mergeSenders(current: here, imported: file, keepPeopleAlways: false, acceptLooser: .all)
            .rules[1].autoMerge)
        #expect(merged.merge == ImportListMerge(added: [], replaced: ["Prof. Smith", "Amy"], kept: []))
        #expect(merged.clamped.isEmpty)
        // The same rule in the file: nothing changes, nothing to write.
        let same = Self.plan(Self.bundle(senders: here), current: [MailSettings.Keys.senders: MailSettings.encode(here)])
        #expect(same.writes[MailSettings.Keys.senders] == nil && same.merges.isEmpty && same.changes.isEmpty)
    }

    @Test func peoplesAlwaysIsClampedUnlessThisMacAlreadyHasIt() {
        let here = [SenderRule(id: "pi", pattern: "pi@lab.example.edu", label: "PI", kind: .advisor, aiPolicy: .always)]
        let file = [SenderRule(id: "pi", pattern: "pi@lab.example.edu", label: "PI", kind: .advisor, aiPolicy: .always),
                    SenderRule(id: "amy", pattern: "amy@lab.example.edu", label: "Amy", kind: .person, aiPolicy: .always),
                    SenderRule(id: "bio", pattern: "@biorxiv.org", label: "bioRxiv", kind: .alert, aiPolicy: .always)]
        let p = Self.plan(Self.bundle(senders: file), current: [MailSettings.Keys.senders: MailSettings.encode(here)])
        #expect(Self.senders(p).map(\.aiPolicy) == [.always, .ask, .always])     // nothing loosened
        #expect(p.warnings.contains(.peopleAlwaysClamped(sender: "Amy")))
        #expect(!p.warnings.contains(.peopleAlwaysClamped(sender: "PI")))
        #expect(p.merges[MailSettings.Keys.senders] == ImportListMerge(added: ["Amy", "bioRxiv"], replaced: [], kept: ["PI"]))
        // This Mac's "ask" is not raised by the file's "always": kept stricter (regression #2 — its
        // own opt-in, `PFSettingsNeverLoosenTests`), even with the new-sender opt-out ticked.
        let asking = [SenderRule(id: "pi", pattern: "pi@lab.example.edu", label: "PI", kind: .advisor, aiPolicy: .ask)]
        for keep in [false, true] {
            let q = Self.plan(Self.bundle(senders: file), current: [MailSettings.Keys.senders: MailSettings.encode(asking)], keep: keep)
            #expect(Self.senders(q).first?.aiPolicy == .ask)
            #expect(q.keptStricter.map(\.id) == [ImportLoosening.senderID("pi")])
            #expect(!q.warnings.contains(.peopleAlwaysClamped(sender: "PI")))
        }
    }

    // MARK: Accounts

    @Test func anAccountAddedDuringOnboardingSurvivesAnOlderFile() throws {
        let gmailHere = MailAccount(id: "new-gmail", kind: .imap, displayName: "Gmail", imapPreset: .gmail,
                                    host: "imap.gmail.com", port: 993, username: "me@gmail.com")
        let folderHere = MailAccount(id: "local", kind: .folder, displayName: "Saved emails",
                                     folderPath: "/Users/example/Mail Drop")
        let gmailThere = MailAccount(id: "old-gmail", kind: .imap, displayName: "Gmail (old Mac)", imapPreset: .gmail,
                                     host: "imap.gmail.com", port: 993, username: "Me@Gmail.com", mailbox: "PaperDeck")
        let yahooThere = MailAccount(id: "yahoo", kind: .imap, displayName: "Yahoo", imapPreset: .yahoo,
                                     host: "imap.mail.yahoo.com", port: 993, username: "me@yahoo.com")
        let p = Self.plan(Self.bundle(accounts: [gmailThere, yahooThere], personal: true),
                          current: [MailSettings.Keys.accounts: MailSettings.encode([gmailHere, folderHere])])
        let merged = Self.accounts(p)
        #expect(merged.map(\.id) == ["new-gmail", "local", "yahoo"])             // the keychain item "new-gmail.imap" stays linked
        try #require(merged.count > 1)          // no index past a failed expectation (QA-15)
        #expect(merged[0].mailbox == "PaperDeck" && merged[0].displayName == "Gmail (old Mac)")
        #expect(merged[1] == folderHere)
        #expect(p.merges[MailSettings.Keys.accounts] == ImportListMerge(added: ["Yahoo"], replaced: ["Gmail (old Mac)"],
                                                                        kept: ["Saved emails"]))
        // The mailbox set up here needs no new app password; the added one does.
        #expect(p.warnings.contains(.needsAppPassword(account: "Yahoo")))
        #expect(!p.warnings.contains(.needsAppPassword(account: "Gmail (old Mac)")))
        #expect(p.changes.first { $0.key == MailSettings.Keys.accounts }?.needsConfirmation == true)
    }

    @Test func theSameAccountKeepsItsAddressWhenTheFileLeftItOut() throws {
        let here = MailAccount(id: "gm", kind: .imap, displayName: "Gmail", imapPreset: .gmail, host: "imap.gmail.com",
                               port: 993, username: "me@gmail.com")
        var there = here
        there.lookbackDays = 7
        // Exported without personal data: no username in the file.
        let p = Self.plan(Self.bundle(accounts: [there], personal: false),
                          current: [MailSettings.Keys.accounts: MailSettings.encode([here])])
        let merged = Self.accounts(p)
        #expect(merged.count == 1 && merged[0].username == "me@gmail.com" && merged[0].lookbackDays == 7)
        #expect(p.merges[MailSettings.Keys.accounts] == ImportListMerge(added: [], replaced: ["Gmail"], kept: []))
        #expect(p.loosenings.isEmpty)                         // a shorter look-back tightens: imported as is
        // Exactly the same account: no change at all.
        let same = Self.plan(Self.bundle(accounts: [here], personal: false),
                             current: [MailSettings.Keys.accounts: MailSettings.encode([here])])
        #expect(same.writes[MailSettings.Keys.accounts] == nil && same.merges.isEmpty)
    }

    @Test func aFolderAccountMatchesTheSameWatchedFolder() {
        let here = MailAccount(id: "pa-here", kind: .folder, displayName: "Work", folderPath: "/Users/example/OneDrive/PaperDeck Mail")
        let there = MailAccount(id: "pa-there", kind: .folder, displayName: "Work (Power Automate)",
                                folderPath: "/Users/example/OneDrive/PaperDeck Mail/", deleteProcessedFiles: true)
        let merged = SettingsImporter.mergeAccounts(current: [here], imported: [there])
        // "Delete processed files" is never switched on for an account this Mac keeps the files for
        // (integration round) — unless that item is accepted.
        #expect(merged.accounts.map(\.id) == ["pa-here"] && !merged.accounts[0].deleteProcessedFiles)
        #expect(merged.loosened.map(\.id) == [ImportLoosening.accountID("pa-here", .deleteProcessedFiles)])
        #expect(SettingsImporter.mergeAccounts(current: [here], imported: [there], acceptLooser: .all).accounts[0].deleteProcessedFiles)
        #expect(merged.existingMailboxes == [0])
        #expect(merged.merge == ImportListMerge(added: [], replaced: ["Work (Power Automate)"], kept: []))
        // An empty Mac: everything is added, as before.
        let fresh = SettingsImporter.mergeAccounts(current: [], imported: [there])
        #expect(fresh.accounts == [there] && fresh.existingMailboxes.isEmpty)
        #expect(fresh.merge == ImportListMerge(added: ["Work (Power Automate)"], replaced: [], kept: []))
    }
}
