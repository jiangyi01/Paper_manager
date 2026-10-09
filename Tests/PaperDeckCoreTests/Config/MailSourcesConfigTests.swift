import Foundation
import Testing
@testable import PaperDeckCore
@testable import PaperDeckConfig

// T5 CloudRootLocatorTests, T6 MailSourceResolverTests and T14 MailRuleScriptsTests
// (PORTABILITY_PLAN §5.4). Pure: names and paths only — nothing lists or reads a real cloud folder.
@Suite struct CloudRootLocatorTests {
    static let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    static let cloud = CloudRootLocator.cloudStorage(home: home)
    static let names = ["OneDrive-Personal", "OneDrive-SharedLibraries-Contoso", "OneDrive-Contoso University", "Dropbox",
                        "GoogleDrive-a@b.com", "Box-Box", ".DS_Store"]

    static var roots: [CloudRoot] { CloudRootLocator.classify(names: names, cloudStorage: cloud) }

    @Test func rootsAreClassifiedByName() throws {
        let byName = Dictionary(uniqueKeysWithValues: Self.roots.map { ($0.name, $0) })
        #expect(byName.count == 6)                                              // hidden names skipped
        #expect(byName["OneDrive-Personal"]?.provider == .oneDrivePersonal)
        #expect(byName["OneDrive-SharedLibraries-Contoso"]?.provider == .oneDriveShared)
        #expect(byName["OneDrive-Contoso University"]?.provider == .oneDriveBusiness)
        #expect(byName["OneDrive-Contoso University"]?.displayName == "OneDrive – Contoso University")
        #expect(byName["Dropbox"]?.provider == .dropbox)
        let google = try #require(byName["GoogleDrive-a@b.com"])
        #expect(google.provider == .googleDrive && google.url.lastPathComponent == "My Drive")
        #expect(byName["Box-Box"]?.provider == .box)
        #expect(CloudRootLocator.classify(names: ["Something-Else"], cloudStorage: Self.cloud).first?.provider == .other)
        #expect(CloudRootLocator.iCloudDrive(home: Self.home).url.path == "/Users/someone/Library/Mobile Documents/com~apple~CloudDocs")
    }

    @Test func powerAutomateRanksWorkOneDriveFirstAndSkipsPersonalAndShared() {
        let ranked = CloudRootLocator.ranked(Self.roots, for: .m365PowerAutomate, org: OrganizationPresets.generic, lastChoice: nil)
        #expect(ranked.first?.name == "OneDrive-Contoso University")
        #expect(!ranked.contains { $0.provider == .oneDrivePersonal || $0.provider == .oneDriveShared })
        // The folder route keeps every root; the last choice first.
        let folder = CloudRootLocator.ranked(Self.roots, for: .folder, org: OrganizationPresets.generic, lastChoice: "Dropbox")
        #expect(folder.count == 6 && folder.first?.name == "Dropbox")
    }

    @Test func theLegacyHintRanksItsRootFirst() {
        let names = ["OneDrive-Contoso University", "OneDrive-WashingtonUniversityinSt.Louis", "OneDrive-Personal"]
        let roots = CloudRootLocator.classify(names: names, cloudStorage: Self.cloud)
        let washu = CloudRootLocator.ranked(roots, for: .m365PowerAutomate, org: OrganizationPresets.washu, lastChoice: nil)
        #expect(washu.first?.name == "OneDrive-WashingtonUniversityinSt.Louis")
        let generic = CloudRootLocator.ranked(roots, for: .m365PowerAutomate, org: OrganizationPresets.generic, lastChoice: nil)
        #expect(generic.first?.name == "OneDrive-Contoso University")                     // alphabetical
        let last = CloudRootLocator.ranked(roots, for: .m365PowerAutomate, org: OrganizationPresets.generic,
                                           lastChoice: "OneDrive-WashingtonUniversityinSt.Louis")
        #expect(last.first?.name == "OneDrive-WashingtonUniversityinSt.Louis")
    }

    @Test func suggestions() {
        // No roots: the legacy preset keeps today's path, generic suggests nothing (Choose…).
        let today = "/Users/someone/Library/CloudStorage/OneDrive-WashingtonUniversityinSt.Louis/PaperDeck Mail"
        #expect(CloudRootLocator.suggestedFolder(for: .m365PowerAutomate, roots: [], existingMailFolders: [],
                                                 org: OrganizationPresets.washu, lastChoice: nil, home: Self.home)?.path == today)
        #expect(CloudRootLocator.suggestedFolder(for: .m365PowerAutomate, roots: [], existingMailFolders: [],
                                                 org: OrganizationPresets.generic, lastChoice: nil, home: Self.home) == nil)
        // Roots: PaperDeck Mail under the best work OneDrive (never Personal).
        let suggested = CloudRootLocator.suggestedFolder(for: .m365PowerAutomate, roots: Self.roots, existingMailFolders: [],
                                                         org: OrganizationPresets.generic, lastChoice: nil, home: Self.home)
        #expect(suggested?.path == "/Users/someone/Library/CloudStorage/OneDrive-Contoso University/PaperDeck Mail")
        // Only a personal OneDrive: nothing usable for the flow.
        let personal = CloudRootLocator.classify(names: ["OneDrive-Personal"], cloudStorage: Self.cloud)
        #expect(CloudRootLocator.suggestedFolder(for: .m365PowerAutomate, roots: personal, existingMailFolders: [],
                                                 org: OrganizationPresets.generic, lastChoice: nil, home: Self.home) == nil)
        // An existing PaperDeck Mail folder wins (even under a lower-ranked root).
        let two = CloudRootLocator.classify(names: ["OneDrive-Contoso University", "OneDrive-Fabrikam"], cloudStorage: Self.cloud)
        let existing = Self.cloud.appendingPathComponent("OneDrive-Fabrikam/PaperDeck Mail", isDirectory: true)
        #expect(CloudRootLocator.suggestedFolder(for: .m365PowerAutomate, roots: two, existingMailFolders: [existing],
                                                 org: OrganizationPresets.generic, lastChoice: nil, home: Self.home)?.path
                == existing.path)
        #expect(CloudRootLocator.suggestedFolder(for: .folder, roots: two, existingMailFolders: [existing],
                                                 org: OrganizationPresets.generic, lastChoice: nil, home: Self.home)?.path
                == existing.path)
        #expect(CloudRootLocator.suggestedFolder(for: .folder, roots: two, existingMailFolders: [],
                                                 org: OrganizationPresets.generic, lastChoice: nil, home: Self.home) == nil)
        #expect(CloudRootLocator.suggestedFolder(for: .imapGmail, roots: two, existingMailFolders: [existing],
                                                 org: OrganizationPresets.generic, lastChoice: nil, home: Self.home) == nil)
    }

    @Test func splitFindsTheRootOfAPath() throws {
        let a = try #require(CloudRootLocator.split("/Users/someone/Library/CloudStorage/OneDrive-Contoso University/Lab/PaperDeck Mail",
                                                    home: Self.home))
        #expect(a.root.provider == .oneDriveBusiness && a.root.name == "OneDrive-Contoso University" && a.relative == "Lab/PaperDeck Mail")
        // Another user's home (a settings file from another Mac, the seeded render fixture) too.
        let b = try #require(CloudRootLocator.split("/Users/example/Library/CloudStorage/OneDrive-WashingtonUniversityinSt.Louis/PaperDeck Mail",
                                                    home: Self.home))
        #expect(b.root.name == "OneDrive-WashingtonUniversityinSt.Louis" && b.relative == "PaperDeck Mail")
        let g = try #require(CloudRootLocator.split("~/Library/CloudStorage/GoogleDrive-a@b.com/My Drive/PaperDeck Mail", home: Self.home))
        #expect(g.root.provider == .googleDrive && g.relative == "PaperDeck Mail" && g.root.url.lastPathComponent == "My Drive")
        let i = try #require(CloudRootLocator.split("/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/Mail", home: Self.home))
        #expect(i.root.provider == .iCloudDrive && i.relative == "Mail")
        let legacy = try #require(CloudRootLocator.split("/Users/someone/OneDrive - Contoso/PaperDeck Mail", home: Self.home))
        #expect(legacy.root.provider == .oneDriveBusiness && legacy.root.name == "OneDrive - Contoso" && legacy.relative == "PaperDeck Mail")
        #expect(CloudRootLocator.split("/Users/someone/Documents/Mail", home: Self.home) == nil)
        #expect(CloudRootLocator.split("relative/path", home: Self.home) == nil)
    }
}

@Suite struct MailSourceResolverTests {
    @Test func legacyAccountsAreInferredAsToday() {
        let washu = MailAccount(id: "washu-pa", kind: .folder, displayName: "WashU (Power Automate)",
                                folderPath: "/Users/example/Library/CloudStorage/OneDrive-WashingtonUniversityinSt.Louis/PaperDeck Mail")
        #expect(MailSourceResolver.source(of: washu) == .m365PowerAutomate)
        let named = MailAccount(kind: .folder, displayName: "Lab (Power Automate)", folderPath: "/Volumes/X/mail")
        #expect(MailSourceResolver.source(of: named) == .m365PowerAutomate)
        let plain = MailAccount(kind: .folder, displayName: "Saved mail", folderPath: "/Users/x/Mail")
        #expect(MailSourceResolver.source(of: plain) == .folder)
        let gmail = MailAccount(kind: .imap, displayName: "Gmail", imapPreset: .gmail)
        #expect(MailSourceResolver.source(of: gmail) == .imapGmail)
        #expect(MailSourceResolver.source(of: MailAccount(kind: .imap, displayName: "x")) == .imapCustom)
    }

    @Test func anExplicitSourceWinsAndRoundTrips() throws {
        var a = MailAccount(id: "a1", kind: .folder, displayName: "Work (Power Automate)", folderPath: "/tmp/x")
        a.source = MailSourceID.folder.rawValue
        #expect(MailSourceResolver.source(of: a) == .folder)
        let json = MailSettings.encode([a])
        #expect(json.contains("\"source\":\"folder\""))
        #expect(MailSettings.list(json, MailAccount.self, what: "account") == [a])
        // Today's JSON (no source) still decodes; an unknown source falls back to inference.
        let old = #"[{"id":"b","kind":"folder","displayName":"Work (Power Automate)","folderPath":"/tmp/y"}]"#
        let decoded = MailSettings.list(old, MailAccount.self, what: "account")
        #expect(decoded.count == 1 && decoded[0].source == nil && MailSourceResolver.source(of: decoded[0]) == .m365PowerAutomate)
        var future = decoded[0]
        future.source = "imap.someday"
        #expect(MailSourceResolver.source(of: future) == .m365PowerAutomate)
        // MailSettings.list tolerates the field inside a list of accounts.
        let scratch = ScratchDefaults("mail-source-list")
        defer { scratch.drop() }
        scratch.defaults.set(json, forKey: MailSettings.Keys.accounts)
        #expect(MailSettings.load(from: scratch.defaults).accounts == [a])
    }

    @Test func theChooserKeepsTodaysOrderThenTheOtherWays() throws {
        let entries = MailSourceCatalog.entries(org: OrganizationPresets.washu)
        #expect(entries.filter { $0.section == .setUp }.map(\.id)
                == [.m365PowerAutomate, .imapGmail, .imapICloud, .imapYahoo, .imapFastmail, .imapCustom, .folder])
        #expect(entries.filter { $0.section == .otherWays }.map(\.id)
                == [.guideOutlookCom, .guideWorkspace, .guideM365Blocked, .guideAppleMailRule, .guideAppsScript, .guideDragOnly])
        #expect(entries.allSatisfy { $0.section == .setUp ? $0.id.createsAccount : !$0.id.createsAccount })
        #expect(Set(entries.map(\.id)) == Set(MailSourceID.allCases))
        // The legacy preset's rows read as today's chooser; generic names no institution.
        try #require(entries.count > 0)          // no index past a failed expectation (QA-15)
        let pa = entries[0]
        #expect(pa.title.en == "Microsoft 365 via Power Automate (WashU)" && pa.blurb.en.hasSuffix("No IT app approval needed."))
        let generic = MailSourceCatalog.entries(org: OrganizationPresets.generic)
        #expect(generic[0].title.en == "Microsoft 365 (work or school) via Power Automate")
        for e in generic {
            for t in [e.title.en, e.title.zh, e.blurb.en, e.blurb.zh] { #expect(!t.lowercased().contains("washu"), "\(e.id)") }
            #expect(GuideTopicID.catalog.contains(e.helpTopic), "\(e.id)")
        }
        #expect(MailSourceID.imapGmail.imapPreset == .gmail && MailSourceID.folder.imapPreset == nil)
    }
}

@Suite struct MailRuleScriptsTests {
    @Test func theAppleMailRuleWritesTheSourceIntoTheFolder() {
        let script = MailRuleScripts.appleMailRule(folder: URL(fileURLWithPath: "/Users/x/Dropbox/Paper \"Deck\" Mail\\in", isDirectory: true))
        #expect(script.contains("source of msg"))
        #expect(script.contains("on perform mail action with messages"))
        #expect(script.contains(#"property targetFolder : "/Users/x/Dropbox/Paper \"Deck\" Mail\\in/""#))
        #expect(script.contains(".eml"))
        for secret in ["password", "token", "secret"] { #expect(!script.lowercased().contains(secret)) }
    }

    @Test func theAppsScriptEmbedsTheSendersAndTheFolderEscaped() {
        let script = MailRuleScripts.googleAppsScript(driveFolderName: "PaperDeck \"Mail\"</script>",
                                                      senders: ["scholaralerts-noreply@google.com", "@biorxiv.org", "@*.nature.com", " "],
                                                      label: "PaperDeck/Alerts")
        #expect(script.contains(#"const FOLDER_NAME = "PaperDeck \"Mail\"<\/script>";"#))
        #expect(script.contains(#"const SENDERS = ["scholaralerts-noreply@google.com", "@biorxiv.org", "@*.nature.com"];"#))
        #expect(script.contains(#"const LABEL = "PaperDeck\/Alerts";"#))
        #expect(script.contains("getRawContent()") && script.contains("message/rfc822"))
        #expect(!script.contains("</script>"))
        let noLabel = MailRuleScripts.googleAppsScript(driveFolderName: "", senders: ["@arxiv.org"], label: nil)
        #expect(noLabel.contains("const LABEL = null;") && noLabel.contains(#"const FOLDER_NAME = "PaperDeck Mail";"#))
        for secret in ["password", "token", "secret", "apikey"] { #expect(!script.lowercased().contains(secret)) }
    }
}
