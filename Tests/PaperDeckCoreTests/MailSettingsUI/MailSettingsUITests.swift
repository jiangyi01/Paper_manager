import Foundation
import Testing
@testable import PaperDeckCore
import PaperDeckConfig

// Contracts Settings ▸ Mail (App target: SettingsStore, the sender sheet, the Power Automate
// guide, 「清除所有邮件数据」) and the mail CLI modes rely on. Nothing here touches the real
// UserDefaults domain, the keychain, a mail server or the network, and nothing spawns a CLI.

private enum MailUIKit {
    static func fixtureURL(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "eml", subdirectory: "Fixtures/mail/mail-ui-settings"))
    }

    static let advisor = SenderRule(id: "ui-advisor", pattern: "jsmith@wustl.edu", label: "Prof. Smith", kind: .advisor)
    static let biorxiv = SenderRule(id: "ui-biorxiv", pattern: "@alerts.highwire.org", label: "bioRxiv", kind: .alert)

    /// Writes every key the way the app's SettingsStore does (JSON via `MailSettings.encode`).
    static func write(_ m: MailSettings, to d: UserDefaults) {
        let k = MailSettings.Keys.self
        d.set(m.enabled, forKey: k.enabled)
        d.set(MailSettings.encode(m.accounts), forKey: k.accounts)
        d.set(MailSettings.encode(m.senders), forKey: k.senders)
        d.set(MailSettings.encode(m.criteria), forKey: k.criteria)
        d.set(m.syncMinutes, forKey: k.syncMinutes)
        d.set(m.aiMode.rawValue, forKey: k.aiMode)
        if let p = m.triageProvider { d.set(p.rawValue, forKey: k.triageProvider) } else { d.removeObject(forKey: k.triageProvider) }
        d.set(m.triageModelClaude, forKey: k.triageModelClaude)
        d.set(m.triageModelCodex, forKey: k.triageModelCodex)
        d.set(m.triageDailyMax, forKey: k.triageDailyMax)
        d.set(m.triageBodyCap, forKey: k.triageBodyCap)
        d.set(m.maxAttachmentMB, forKey: k.maxAttachmentMB)
        d.set(m.prefillNotes, forKey: k.prefillNotes)
        d.set(m.notifyNewRequests, forKey: k.notifyNewRequests)
        d.set(m.includeInDailyReminder, forKey: k.includeInDailyReminder)
        d.set(m.retentionDays, forKey: k.retentionDays)
    }

    static func custom() -> MailSettings {
        MailSettings(
            enabled: true,
            accounts: [
                MailAccount(id: "a1", kind: .folder, displayName: "WashU (Power Automate)",
                            folderPath: "/tmp/OneDrive/PaperDeck Mail", deleteProcessedFiles: true),
                MailAccount(id: "a2", kind: .imap, displayName: "Gmail — x@gmail.com", enabled: false, lookbackDays: 30,
                            imapPreset: .gmail, host: "imap.gmail.com", port: 993, username: "x@gmail.com", mailbox: "PaperDeck"),
            ],
            senders: [advisor, SenderRule(id: "p", pattern: "@wustl.edu", kind: .person, aiPolicy: .never,
                                          defaultPriority: .low, defaultCategory: "Neuroscience", useDueDateAsDDL: false,
                                          autoMerge: true, autoDownload: false)] + SenderRule.presets,
            criteria: ReadingCriteria(keepKinds: [.advisorRequest, .other], includeKeywords: ["neocortex", "空间转录组"],
                                      excludeKeywords: ["retracted"], researchInterests: "spatial omics",
                                      customInstructions: "Lab-meeting papers are requests.", minConfidence: 0.65,
                                      maxAlertPapers: 5),
            syncMinutes: 0, aiMode: .heuristicOnly, triageProvider: .codex, triageModelClaude: "sonnet",
            triageModelCodex: "gpt-5.6-terra", triageDailyMax: 50, triageBodyCap: 8_000, maxAttachmentMB: 25,
            prefillNotes: false, notifyNewRequests: true, includeInDailyReminder: false, retentionDays: -1)
    }
}

@Suite("MailSettingsUI · UserDefaults contract")
struct MailSettingsUIDefaultsTests {
    @Test func everyKeyWrittenLikeTheSettingsStoreLoadsBack() {
        let scratch = ScratchDefaults("mailui")
        defer { scratch.drop() }
        let d = scratch.defaults
        let custom = MailUIKit.custom()
        MailUIKit.write(custom, to: d)
        #expect(MailSettings.load(from: d) == custom)
    }

    @Test func missingKeysAreTheEngineDefaults() {
        let scratch = ScratchDefaults("mailui")
        defer { scratch.drop() }
        let d = scratch.defaults
        let loaded = MailSettings.load(from: d)
        #expect(loaded == MailSettings())
        #expect(!loaded.enabled && loaded.aiMode == .ai && loaded.syncMinutes == 15 && loaded.triageDailyMax == 30)
    }

    @Test func removingTheTriageProviderMeansTheReadingProvider() {
        let scratch = ScratchDefaults("mailui")
        defer { scratch.drop() }
        let d = scratch.defaults
        var m = MailUIKit.custom()
        MailUIKit.write(m, to: d)
        #expect(MailSettings.load(from: d).triageProvider == .codex)
        m.triageProvider = nil
        MailUIKit.write(m, to: d)
        #expect(MailSettings.load(from: d).triageProvider == nil)
    }

    @Test func keepForeverRetentionAndManualSyncSurvive() {
        let scratch = ScratchDefaults("mailui")
        defer { scratch.drop() }
        let d = scratch.defaults
        MailUIKit.write(MailUIKit.custom(), to: d)
        let loaded = MailSettings.load(from: d)
        #expect(loaded.retentionDays == -1)          // 「永久保留」: never 0 (the sync loop would purge at once)
        #expect(loaded.syncMinutes == 0)             // 「仅手动」
    }

    @Test func corruptJSONFallsBackWithoutLosingTheOtherKeys() {
        let scratch = ScratchDefaults("mailui")
        defer { scratch.drop() }
        let d = scratch.defaults
        MailUIKit.write(MailUIKit.custom(), to: d)
        d.set("{not json", forKey: MailSettings.Keys.senders)
        let loaded = MailSettings.load(from: d)
        #expect(loaded.senders.isEmpty)
        #expect(loaded.accounts.count == 2 && loaded.criteria.maxAlertPapers == 5)
    }
}

@Suite("MailSettingsUI · sender patterns and the Power Automate From value")
struct MailSettingsUIPatternTests {
    @Test func theSheetCanonicalizesWhatTheMatcherAccepts() {
        #expect(SenderMatcher.Pattern("Prof X <Prof.X+papers@WUSTL.edu>") == .address("prof.x@wustl.edu"))
        #expect(SenderMatcher.Pattern(" @BioRxiv.org ") == .domain("biorxiv.org"))
        #expect(SenderMatcher.Pattern("biorxiv.org") == .domain("biorxiv.org"))
        #expect(SenderMatcher.Pattern("@*.nature.com") == .wildcard("nature.com"))
        #expect(SenderMatcher.Pattern("*.nature.com") == .wildcard("nature.com"))
        for bad in ["prof", "@nature", "a@b", "", "@*.", "x@@y..org"] {
            #expect(SenderMatcher.Pattern(bad) == nil, "\(bad)")
        }
        // The canonical text the sheet stores matches exactly what the typed text matched.
        let typed = SenderRule(pattern: "Prof X <Prof.X+papers@WUSTL.edu>", kind: .advisor)
        let stored = SenderRule(pattern: "prof.x@wustl.edu", kind: .advisor)
        for (address, matches) in [("prof.x@wustl.edu", true), ("Prof.X+abc@wustl.edu", true),
                                   ("\"prof.x@wustl.edu\" <evil@evil.com>", false)] {
            #expect((SenderMatcher.match(address: address, rules: [typed]) != nil) == matches, "\(address)")
            #expect((SenderMatcher.match(address: address, rules: [stored]) != nil) == matches, "\(address)")
        }
    }

    @Test func presetsAreValidAlertsSentToAIAutomatically() {
        #expect(!SenderRule.presets.isEmpty)
        for p in SenderRule.presets {
            #expect(SenderMatcher.Pattern(p.pattern) != nil, "\(p.pattern)")
            #expect(p.kind == .alert && p.aiPolicy == .always)
        }
        #expect(Set(SenderRule.presets.map(\.id)).count == SenderRule.presets.count)
    }

    @Test func peopleDefaultToAskAndAlertsToAlways() {
        #expect(SenderRule(pattern: "a@b.edu", kind: .advisor).aiPolicy == .ask)
        #expect(SenderRule(pattern: "a@b.edu", kind: .person).aiPolicy == .ask)
        #expect(SenderRule(pattern: "@b.org", kind: .alert).aiPolicy == .always)
        #expect(SenderRule(pattern: "a@b.edu", kind: .advisor).effectivePriority == .high)
    }

    @Test func fromValueComesFromTheEnabledExactAddresses() {
        var off = SenderRule(pattern: "old@wustl.edu", kind: .person)
        off.enabled = false
        let rules = [MailUIKit.advisor, SenderRule(pattern: "JSmith@wustl.edu", kind: .person),
                     SenderRule(pattern: "b.lee@wustl.edu", kind: .person), off]
        let plan = PowerAutomatePackage.senderPlan(PowerAutomatePackage.senders(from: rules))
        #expect(plan.addresses == ["b.lee@wustl.edu", "jsmith@wustl.edu"])
        #expect(plan.fromFilter == "b.lee@wustl.edu;jsmith@wustl.edu")
        #expect(!plan.allSenders)

        let mixed = PowerAutomatePackage.senderPlan(PowerAutomatePackage.senders(from: rules + [MailUIKit.biorxiv]))
        #expect(mixed.domainRules == ["@alerts.highwire.org"])
        #expect(mixed.allSenders && mixed.fromFilter.isEmpty)          // the guide then warns and explains
        #expect(mixed.addresses.joined(separator: ";") == "b.lee@wustl.edu;jsmith@wustl.edu")
    }

    @Test func accountPresetsCarryWhatTheSheetPrefills() {
        #expect(MailAccount.IMAPPreset.gmail.host == "imap.gmail.com")
        #expect(MailAccount.IMAPPreset.icloud.host == "imap.mail.me.com")
        for p in MailAccount.IMAPPreset.allCases {
            #expect(p.port == 993)
            #expect((p.appPasswordURL == nil) == (p == .custom))
            #expect(p.appPasswordURL?.scheme == nil || p.appPasswordURL?.scheme == "https")
        }
        let folder = CloudRootLocator.suggestedFolder(for: .m365PowerAutomate, roots: [], existingMailFolders: [],
                                                      org: OrganizationPresets.washu, lastChoice: nil,
                                                      home: URL(fileURLWithPath: "/Users/someone"))
        #expect(folder?.path == "/Users/someone/Library/CloudStorage/OneDrive-WashingtonUniversityinSt.Louis/PaperDeck Mail")
        #expect(MailAccount(id: "abc", kind: .imap, displayName: "x").secretKey == "abc.imap")
    }
}

@Suite("MailSettingsUI · folder account end to end", .serialized)
struct MailSettingsUIFolderTests {
    @Test func advisorFixtureCarriesARealPDF() throws {
        let data = try Data(contentsOf: try MailUIKit.fixtureURL("advisor-journal-club-pdf"))
        let content = try MIMEParser.parse(data, maxAttachmentBytes: 1 << 20)
        #expect(content.header.fromAddress == "jsmith@wustl.edu")
        #expect(content.header.internetMessageID == "<mail-ui-settings-advisor-0001@wustl.edu>")
        let pdf = try #require(content.attachments.first { $0.looksLikePDF })
        #expect(MailPDFFetcher.validate(pdf, maxBytes: 1 << 20, truncated: false) == nil)
    }

    /// The folder account the Settings sheet creates, synced like 「立即同步」 / `--mail-sync`:
    /// only allowlisted senders are captured, files stay (delete off), the advisor's attachment
    /// merges with high priority and email provenance, and 「清除所有邮件数据」 empties the inbox.
    @Test func folderAccountSyncMergeAndClear() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pd-mailui-\(UUID().uuidString)", isDirectory: true)
        let inbox = root.appendingPathComponent("PaperDeck Mail", isDirectory: true)
        let library = root.appendingPathComponent("lib", isDirectory: true)
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let names = ["advisor-journal-club-pdf", "biorxiv-alert", "colleague-share", "scholar-alert"]
        let hourAgo = Date().addingTimeInterval(-3600)
        for n in names {
            let dst = inbox.appendingPathComponent(n + ".eml")
            try fm.copyItem(at: try MailUIKit.fixtureURL(n), to: dst)
            try fm.setAttributes([.modificationDate: hourAgo], ofItemAtPath: dst.path)
        }
        let account = MailAccount(id: "ui-folder", kind: .folder, displayName: "Watched", lookbackDays: 7,
                                  folderPath: inbox.path, deleteProcessedFiles: false)
        let mail = MailSettings(enabled: true, accounts: [account], senders: [MailUIKit.advisor, MailUIKit.biorxiv],
                                syncMinutes: 0, aiMode: .ai)
        let es = EngineSettings(plan: PlanSettings(dailyBudgetMinutes: 60), lang: .en, agentMode: .off,
                                autoReadNewPapers: false, metadataLookup: false)
        let deps = Engine.Dependencies(loadSettings: { es }, fetcher: nil, claude: MockAgentProvider(behavior: .notLoggedIn),
                                       codex: MockAgentProvider(behavior: .notLoggedIn), mock: MockAgentProvider(),
                                       sidecarDelay: .milliseconds(10), cliFacts: .inMemory(),
                                       loadMailSettings: { mail }, mailSecrets: InMemoryMailSecretStore(), assistBackends: [MockAssistBackend()])
        let engine = try await Engine.open(paths: AppPaths.rooted(at: library), deps: deps)
        await engine.agents.configure(AgentQueue.Tuning(jobTimeout: .seconds(5), testTimeout: .seconds(5), maxNap: .seconds(1),
                                                        idleNap: .seconds(1), loginRecheck: .seconds(1),
                                                        shutdownWait: .seconds(2), detectThrottle: .zero))
        do {
            try await Self.syncMergeClear(engine, inbox: inbox, files: names.count, settings: es)
        } catch {
            Issue.record(error)
        }
        await engine.shutdown()
        await engine.db.close()
    }

    private static func syncMergeClear(_ engine: Engine, inbox: URL, files: Int, settings es: EngineSettings) async throws {
            let fm = FileManager.default
            await engine.start()
            await engine.mail.syncNow()
            await engine.mail.waitUntilIdle()

            let info = try #require(await engine.mail.accountSyncInfo().first)
            guard case .ready? = info.status else {
                Issue.record("folder account not ready: \(String(describing: info.status))")
                return
            }
            var snap = try await engine.mailSnapshot()
            let cards = MailInboxFilter.allCases.flatMap { snap.cards($0) }
            #expect(Set(cards.map(\.message.fromAddress)) == ["jsmith@wustl.edu", "biorxiv@alerts.highwire.org"])
            #expect(try fm.contentsOfDirectory(atPath: inbox.path).count == files)            // delete off: files stay

            let advisorCard = try #require(cards.first { $0.message.senderKind == .advisor })
            #expect(advisorCard.message.triageState == .awaitingConsent)                   // people: ask first
            let attachment = try #require(advisorCard.items.first { $0.origin == .attachment })
            #expect(attachment.pdfState == .hasPDF)

            let today = LocalDate.today(now: Date(), calendar: .current)
            var options = MailMergeOptions.suggested(for: advisorCard.message, rule: advisorCard.rule, settings: es, today: today)
            options.readWithAI = false
            let paperID = try #require(try await engine.mergeMailItem(itemID: attachment.id, options: options))
            let paper = try #require(try await engine.db.paper(id: paperID))
            #expect(paper.priority == .high)
            let sources = try await engine.db.paperSources(paperPK: paper.pk)
            #expect(sources.contains { $0.mailMessageID == advisorCard.id && $0.fromAddress == "jsmith@wustl.edu" })

            try await engine.mail.deleteAllMailData()
            snap = try await engine.mailSnapshot()
            #expect(snap.isEmpty)
            #expect(try await engine.db.paperSources(paperPK: paper.pk).count == sources.count)   // library keeps its source
    }
}
