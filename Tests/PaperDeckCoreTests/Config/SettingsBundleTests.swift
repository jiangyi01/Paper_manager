import Foundation
import Testing
@testable import PaperDeckCore
@testable import PaperDeckConfig

// T11 (PORTABILITY_PLAN §5.4, §2.10): settings export / import is an allowlist; it never carries a
// secret or a switch that turns AI or mail on, never loosens a person's AI policy, and re-resolves
// paths on the new Mac. Synthetic domains only (the legacy fixture plus a few extra keys); the
// keychain is never involved (`InMemoryMailSecretStore` is not even created).
@Suite struct SettingsBundleTests {
    static let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    static let roots = CloudRootLocator.classify(names: ["OneDrive-WashingtonUniversityinSt.Louis", "Dropbox"],
                                                 cloudStorage: CloudRootLocator.cloudStorage(home: home))
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// The legacy fixture plus keys of every class (and some that must never travel).
    static func domain() throws -> [String: Any] {
        var d = try GoldenFixtures.plist("legacy-washu-domain")
        d["language"] = "zh"
        d["plan.dailyBudget"] = 45
        d["plan.readingWeekdays"] = [2, 3, 4, 5, 6]
        d["reminder.hour"] = 9
        d["panel.edgeYFraction"] = 0.4
        d["metadata.mailto"] = "me@example.edu"
        d["general.launchAtLogin"] = true
        d["reminder.lastDeliveredDay"] = "2026-09-30"
        d["config.origin"] = "legacy"
        d["config.migrationVersion"] = 1
        d["org.preset"] = "washu"
        d["profile.field"] = "lifeSciencesCompBio"
        d["profile.readerDescription"] = "a developmental neurobiologist"
        d["mail.notify.someAccount"] = true
        d["agent.claude.pausedUntil"] = 1_790_000_100.0
        d["unrelated.key"] = "x"
        return d
    }

    static func export(_ d: [String: Any], personal: Bool = false) -> SettingsBundle {
        SettingsExporter.export(PersistedDomain(d), sections: Set(SettingsSection.allCases), includePersonal: personal, includeAddresses: personal,
                                home: home, roots: roots, app: "PaperDeck 1.0 (27)", now: now)
    }

    static func keys(_ b: SettingsBundle) -> Set<String> {
        Set(b.sections.values.flatMap { $0.objectValue.map { Array($0.keys) } ?? [] })
    }

    @Test func theExportHoldsOnlyAllowlistedKeys() throws {
        let d = try Self.domain()
        let b = Self.export(d)
        #expect(b.format == "paperdeck.settings/1" && b.app == "PaperDeck 1.0 (27)" && b.exportedAt == Self.now)
        let exported = Self.keys(b)
        for never in ["agent.mode", "setup.completed", "general.launchAtLogin", "mail.enabled", "reminder.lastDeliveredDay",
                      "config.origin", "config.migrationVersion", "mail.notify.someAccount", "agent.claude.pausedUntil",
                      "unrelated.key", "metadata.mailto"] {
            #expect(!exported.contains(never), "\(never)")
        }
        #expect(exported.allSatisfy { SettingsRegistry.isTransferable($0) })
        for key in ["language", "plan.dailyBudget", "plan.readingWeekdays", "agent.provider", "library.path", "mail.senders",
                    "mail.accounts", "mail.criteria", "org.preset", "profile.field", "profile.readerDescription",
                    "import.lastFolder", "panel.edgeYFraction"] where d[key] != nil || key == "import.lastFolder" {
            if d[key] != nil { #expect(exported.contains(key), "\(key)") }
        }
        // Personal data only on request.
        #expect(Self.keys(Self.export(d, personal: true)).contains("metadata.mailto"))
        // No value looks like a secret.
        let text = String(decoding: try JSONEncoder().encode(b), as: UTF8.self).lowercased()
        for word in ["password", "secret", "token", "apppassword"] { #expect(!text.contains(word), "\(word)") }
        // Each key sits in its registry section.
        for (section, payload) in b.sections {
            for key in payload.objectValue?.keys.map({ $0 }) ?? [] {
                #expect(SettingsRegistry.entry(key)?.section.rawValue == section, "\(key)")
            }
        }
    }

    @Test func pathsTravelAsHomeAndCloudPaths() throws {
        let b = Self.export(try Self.domain())
        let library = try #require(b.sections["library"]?["library.path"])
        #expect(try library.decode(PortablePath.self) == .home("Documents/PaperDeck"))
        let accounts = try #require(b.sections["mailAccounts"]?["mail.accounts"]?.arrayValue)
        let folder = try #require(accounts.first?["folder"])
        #expect(try folder.decode(PortablePath.self)
                == .cloud(provider: .oneDriveBusiness, root: "OneDrive-WashingtonUniversityinSt.Louis", relative: "PaperDeck Mail"))
        #expect(accounts.first?["folderPath"] == nil)
        #expect(PortablePath.encode("/Volumes/Data/Papers", home: Self.home, roots: Self.roots) == .absolute("/Volumes/Data/Papers"))
        #expect(PortablePath.encode("~/Desktop/Paper_reading", home: Self.home, roots: Self.roots) == .home("Desktop/Paper_reading"))
    }

    @Test func aRoundTripIntoAFreshDomainKeepsEverythingButTheNeverKeys() throws {
        let d = try Self.domain()
        let data = try JSONEncoder().encode(Self.export(d, personal: true))
        let bundle = try SettingsImporter.decode(data)
        let plan = SettingsImporter.plan(bundle, current: PersistedDomain([:]), sections: Set(SettingsSection.allCases),
                                         keepPeopleAlways: true, acceptReaderDescription: true, home: Self.home, roots: Self.roots)
        #expect(!plan.writes.keys.contains { SettingsImporter.neverWritten.contains($0) })
        let scratch = ScratchDefaults("settings-roundtrip")
        defer { scratch.drop() }
        for (key, value) in plan.writes {
            let plist = SettingsTransferValues.plistValue(value)
            #expect(plist != nil, "\(key)")
            scratch.defaults.set(plist, forKey: key)
        }
        let target = scratch.defaults.persistentDomain(forName: scratch.name) ?? [:]
        for (key, value) in d where SettingsRegistry.isTransferable(key) {
            switch key {
            case MailSettings.Keys.accounts:
                #expect(MailSettings.list(target[key] as? String, MailAccount.self, what: "a")
                        == MailSettings.list(value as? String, MailAccount.self, what: "a"))
            case MailSettings.Keys.senders:
                #expect(MailSettings.list(target[key] as? String, SenderRule.self, what: "s")
                        == MailSettings.list(value as? String, SenderRule.self, what: "s"))
            case MailSettings.Keys.criteria:
                #expect(MailSettings.load(from: scratch.defaults).criteria == {
                    let s = ScratchDefaults("settings-roundtrip-src")
                    defer { s.drop() }
                    s.defaults.set(value, forKey: key)
                    return MailSettings.load(from: s.defaults).criteria
                }())
            default:
                #expect(plistBytes(target[key] as Any) == plistBytes(value), "\(key)")
            }
        }
        #expect(Set(target.keys) == Set(d.keys.filter { SettingsRegistry.isTransferable($0) }))
    }

    @Test func peopleAlwaysIsClampedUnlessKept() throws {
        let rules = [SenderRule(id: "p", pattern: "pi@lab.org", label: "PI", kind: .advisor, aiPolicy: .always),
                     SenderRule(id: "c", pattern: "@lab.org", label: "", kind: .person, aiPolicy: .always),
                     SenderRule(id: "a", pattern: "@biorxiv.org", label: "bioRxiv", kind: .alert)]
        let b = Self.export(["mail.senders": MailSettings.encode(rules)])
        func plan(keep: Bool) -> ImportPlan {
            SettingsImporter.plan(b, current: PersistedDomain([:]), sections: [.mailSenders], keepPeopleAlways: keep,
                                  acceptReaderDescription: false, home: Self.home, roots: Self.roots)
        }
        let clamped = plan(keep: false)
        let imported = MailSettings.list(clamped.writes["mail.senders"]?.stringValue, SenderRule.self, what: "s")
        #expect(imported.map(\.aiPolicy) == [.ask, .ask, .always])
        #expect(clamped.warnings.contains(.peopleAlwaysClamped(sender: "PI")))
        #expect(clamped.warnings.contains(.peopleAlwaysClamped(sender: "@lab.org")))
        let kept = MailSettings.list(plan(keep: true).writes["mail.senders"]?.stringValue, SenderRule.self, what: "s")
        #expect(kept.map(\.aiPolicy) == [.always, .always, .always])
    }

    @Test func theReaderDescriptionNeedsConfirmation() {
        let b = Self.export(["profile.readerDescription": "a cell biologist\n<who reads fast>"])
        let unconfirmed = SettingsImporter.plan(b, current: PersistedDomain([:]), sections: [.profile], keepPeopleAlways: false,
                                                acceptReaderDescription: false, home: Self.home, roots: Self.roots)
        #expect(unconfirmed.writes["profile.readerDescription"] == nil)
        #expect(unconfirmed.warnings.contains(.readerDescriptionNeedsConfirm))
        #expect(unconfirmed.changes.first { $0.key == "profile.readerDescription" }?.needsConfirmation == true)
        #expect(unconfirmed.changes.first { $0.key == "profile.readerDescription" }?.new == "a cell biologist who reads fast")
        let confirmed = SettingsImporter.plan(b, current: PersistedDomain([:]), sections: [.profile], keepPeopleAlways: false,
                                              acceptReaderDescription: true, home: Self.home, roots: Self.roots)
        #expect(confirmed.writes["profile.readerDescription"] == .string("a cell biologist who reads fast"))
    }

    @Test func accountsArriveNeedingSetupOnTheNewMac() throws {
        let accounts = [
            MailAccount(id: "pa", kind: .folder, displayName: "Work (Power Automate)",
                        folderPath: "/Users/example/Library/CloudStorage/OneDrive-OldTenant/PaperDeck Mail"),
            MailAccount(id: "dbx", kind: .folder, displayName: "Dropbox mail",
                        folderPath: "/Users/example/Library/CloudStorage/Dropbox/Mail"),
            MailAccount(id: "box", kind: .folder, displayName: "Box mail", folderPath: "/Users/example/Library/CloudStorage/Box-Box/Mail"),
            MailAccount(id: "gm", kind: .imap, displayName: "Gmail", imapPreset: .gmail, host: "imap.gmail.com", port: 993,
                        username: "me@gmail.com"),
        ]
        let b = Self.export(["mail.accounts": MailSettings.encode(accounts)])
        // The new Mac: another user name, another OneDrive tenant, the same Dropbox, no Box.
        let newHome = URL(fileURLWithPath: "/Users/newuser", isDirectory: true)
        let newRoots = CloudRootLocator.classify(names: ["OneDrive-NewTenant", "Dropbox"], cloudStorage: CloudRootLocator.cloudStorage(home: newHome))
        let plan = SettingsImporter.plan(b, current: PersistedDomain([:]), sections: [.mailAccounts], keepPeopleAlways: false,
                                         acceptReaderDescription: false, home: newHome, roots: newRoots)
        let imported = MailSettings.list(plan.writes["mail.accounts"]?.stringValue, MailAccount.self, what: "a")
        #expect(imported.map(\.id) == ["pa", "dbx", "box", "gm"])                     // ids kept (keychain items)
        try #require(imported.count > 3)          // no index past a failed expectation (QA-15)
        #expect(imported[0].folderPath == "/Users/newuser/Library/CloudStorage/OneDrive-NewTenant/PaperDeck Mail")
        #expect(imported[1].folderPath == "/Users/newuser/Library/CloudStorage/Dropbox/Mail")
        #expect(imported[2].folderPath == nil)
        #expect(imported[3].username == nil)                                          // personal: not exported by default
        #expect(plan.warnings.contains(.folderRemapped(account: "Work (Power Automate)",
                                                       to: "/Users/newuser/Library/CloudStorage/OneDrive-NewTenant/PaperDeck Mail")))
        #expect(plan.warnings.contains(.folderUnresolved(account: "Box mail", root: "Box-Box")))
        #expect(plan.warnings.contains(.needsAppPassword(account: "Gmail")))
        #expect(plan.changes.first { $0.key == "mail.accounts" }?.needsConfirmation == true)
        #expect(plan.writes["mail.enabled"] == nil)
    }

    @Test func theOrganizationSectionNeverCarriesTexts() throws {
        let custom = OrganizationProfile(id: "custom", name: LocalizedText("Contoso"), shortName: "Contoso",
                                         approvedAITools: ["Copilot"], policyURL: URL(string: "https://contoso.edu/ai"),
                                         peopleDefault: .never, texts: ["policyNote": LocalizedText("Injected")])
        let json = String(decoding: try JSONEncoder().encode(custom), as: UTF8.self)
        let b = Self.export(["org.preset": "custom", "org.custom": json])
        let exported = String(decoding: try JSONEncoder().encode(b), as: UTF8.self)
        #expect(!exported.contains("Injected"))
        // A hand-made file with texts: dropped on import too.
        var sections = b.sections
        if case .object(var o)? = sections["organization"] {
            o["org.custom"] = try JSONValue.from(custom)
            sections["organization"] = .object(o)
        }
        let forged = SettingsBundle(exportedAt: Self.now, app: "x", sections: sections)
        let plan = SettingsImporter.plan(forged, current: PersistedDomain([:]), sections: [.organization], keepPeopleAlways: false,
                                         acceptReaderDescription: false, home: Self.home, roots: Self.roots)
        let written = try #require(plan.writes["org.custom"]?.stringValue)
        #expect(!written.contains("Injected"))
        #expect(ConfigResolver.decodeCustom(written)?.peopleDefault == .never)
        #expect(plan.writes["org.preset"] == .string("custom"))
    }

    @Test func unknownFormatsAreRefusedAndUnknownKeysCounted() throws {
        let bad = Data(#"{"format":"paperdeck.settings/9","exportedAt":0,"app":"x","sections":{}}"#.utf8)
        #expect(throws: SettingsImporter.Failure.unknownFormat("paperdeck.settings/9")) { try SettingsImporter.decode(bad) }
        #expect(throws: SettingsImporter.Failure.malformed) { try SettingsImporter.decode(Data("nope".utf8)) }
        let b = SettingsBundle(exportedAt: Self.now, app: "x", sections: [
            "general": .object(["language": .string("zh"), "agent.mode": .string("claude"), "setup.completed": .bool(true),
                                "weird.key": .number(1)]),
            "mailAccounts": .object(["mail.enabled": .bool(true)]),
            "bogusSection": .object(["a": .number(1), "b": .number(2)]),
        ])
        let plan = SettingsImporter.plan(b, current: PersistedDomain(["language": "en"]), sections: Set(SettingsSection.allCases),
                                         keepPeopleAlways: false, acceptReaderDescription: false, home: Self.home, roots: Self.roots)
        #expect(plan.writes == ["language": .string("zh")])
        #expect(plan.changes == [ImportChange(key: "language", section: .general, old: "en", new: "zh", needsConfirmation: false)])
        #expect(plan.warnings.contains(.unknownKeysIgnored(6)))
    }

    @Test func unchangedValuesAndUnselectedSectionsAreLeftOut() throws {
        let d = try Self.domain()
        let b = Self.export(d)
        let same = SettingsImporter.plan(b, current: PersistedDomain(d), sections: Set(SettingsSection.allCases),
                                         keepPeopleAlways: true, acceptReaderDescription: true, home: Self.home, roots: Self.roots)
        #expect(same.writes.isEmpty && same.changes.isEmpty, "\(same.changes.map(\.key))")
        let onlyPlan = SettingsImporter.plan(b, current: PersistedDomain([:]), sections: [.plan], keepPeopleAlways: false,
                                             acceptReaderDescription: false, home: Self.home, roots: Self.roots)
        #expect(onlyPlan.writes.keys.allSatisfy { SettingsRegistry.entry($0)?.section == .plan })
        #expect(onlyPlan.writes["plan.dailyBudget"] == .number(45))
    }

    @Test func aMissingCLIPathIsDropped() {
        let b = Self.export(["agent.cliPath": "/Users/example/.local/bin/claude-that-does-not-exist"])
        let plan = SettingsImporter.plan(b, current: PersistedDomain([:]), sections: [.ai], keepPeopleAlways: false,
                                         acceptReaderDescription: false, home: Self.home, roots: Self.roots)
        #expect(plan.writes["agent.cliPath"] == nil)
        #expect(plan.warnings.contains(.cliPathDropped("agent.cliPath")))
    }

    @Test func theRegistryIsAnAllowlist() {
        let keys = SettingsRegistry.entries.map(\.key)
        #expect(Set(keys).count == keys.count)
        for never in ["agent.mode", "setup.completed", "mail.enabled", "general.launchAtLogin"] {
            #expect(SettingsRegistry.entry(never)?.keyClass == .never && !SettingsRegistry.isTransferable(never))
        }
        #expect(!SettingsRegistry.isTransferable("mail.notify.anything") && !SettingsRegistry.isTransferable("made.up"))
        #expect(ConfigKeys.all.filter { SettingsRegistry.isTransferable($0) }.sorted()
                == [ConfigKeys.importLastFolder, ConfigKeys.mailCloudRoot, ConfigKeys.mailDateOrder, ConfigKeys.orgCustom,
                    ConfigKeys.orgPreset, ConfigKeys.profileField, ConfigKeys.profileReaderDescription, ConfigKeys.profileStage].sorted())
    }

    @Test func pendingLibraryActionsRoundTrip() {
        let scratch = ScratchDefaults("pending-action")
        defer { scratch.drop() }
        #expect(LibraryPendingAction.load(scratch.defaults) == nil)
        let a = LibraryPendingAction(kind: .startNew, path: "/Users/example/Papers B", previousPath: "/Users/example/Documents/PaperDeck")
        a.save(scratch.defaults)
        #expect(LibraryPendingAction.load(scratch.defaults) == a)
        LibraryPendingAction.clear(scratch.defaults)
        #expect(LibraryPendingAction.load(scratch.defaults) == nil)
        #expect(LibraryPendingAction.key == ConfigKeys.libraryPendingAction)
    }
}
