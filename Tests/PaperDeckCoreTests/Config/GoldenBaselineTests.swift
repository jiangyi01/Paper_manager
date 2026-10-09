import Foundation
import Testing
@testable import PaperDeckCore
import PaperDeckConfig

// Golden baselines of the portability work (PORTABILITY_PLAN §5.2): what the current user sees
// today must stay byte-identical. The fixtures in Fixtures/config were produced mechanically from
// the build before any L10n edit (`PaperDeck --selftest strings --write … --write-prompt …`); the
// two plists are synthetic (/Users/example). Nothing here touches the app's defaults domain, the
// keychain or the network, and nothing spawns a CLI.

/// `org-strings-v1.json` (the app's `SelfTestStrings.Fixture`). Keys: `org.<OrgTextKey>`,
/// `org.consentNote.<provider>`, `field.<name>`; `strings` is lang → key → text.
struct GoldenOrgStrings: Decodable {
    var version: Int
    var organization: String
    var field: String
    var cardSystemPromptSHA256: String
    var strings: [String: [String: String]]

    static let consentProviders = ["Claude", "ChatGPT"]
    static let fieldKeys = ["describeHint", "categoryDescriptionPlaceholder", "customInstructionsHint", "alertsTip"]

    static func load() throws -> GoldenOrgStrings {
        try JSONDecoder().decode(GoldenOrgStrings.self, from: Data(contentsOf: GoldenFixtures.url("org-strings-v1", "json")))
    }

    func text(_ key: String, _ lang: UILang) -> String? { strings[lang.rawValue]?[key] }
}

enum GoldenFixtures {
    static func url(_ name: String, _ ext: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/config"))
    }

    static func plist(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: url(name, "plist"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// The legacy fixture loaded into a scratch domain (as `--render --seed-plist` does).
    static func seeded(_ name: String, tag: String) throws -> ScratchDefaults {
        let scratch = ScratchDefaults(tag)
        for (key, value) in try plist(name) { scratch.defaults.set(value, forKey: key) }
        return scratch
    }

    /// Collapses every run of whitespace (the literal wraps lines) to one space.
    static func normalized(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

@Suite struct GoldenBaselineTests {
    // MARK: Card system prompt

    @Test func theCardPromptLiteralEqualsTheFixtureByteForByte() throws {
        let fixture = try Data(contentsOf: GoldenFixtures.url("card-system-prompt-v1", "txt"))
        #expect(fixture == Data(CardSchema.systemPrompt.utf8))
    }

    @Test func theStringsFixtureRecordsThePromptsSHA256() throws {
        let golden = try GoldenOrgStrings.load()
        #expect(golden.version == 1)
        #expect(golden.cardSystemPromptSHA256 == FileOps.sha256(of: Data(CardSchema.systemPrompt.utf8)))
        #expect(golden.organization == OrganizationPresets.washu.id)
        #expect(golden.field == FieldPresets.lifeSciencesCompBio.id)
    }

    @Test func theLegacyProfileGetsTheLiteralItself() {
        #expect(CardSchema.systemPrompt(for: .legacyCompBio) == CardSchema.systemPrompt)
        #expect(FieldPresets.lifeSciencesCompBio.cardProfile(stage: .phd, readerOverride: nil) == .legacyCompBio)
        #expect(ConfigSnapshot.legacy.cardPromptProfile == .legacyCompBio)
        // The default engine dependency is today's reader.
        #expect(Engine.Dependencies(fetcher: nil, cliFacts: .inMemory()).loadCardProfile() == .legacyCompBio)
    }

    @Test func everyLegacyProfileSlotIsTextOfTheLiteral() {
        let literal = GoldenFixtures.normalized(CardSchema.systemPrompt)
        let p = CardPromptProfile.legacyCompBio
        #expect(literal.contains("The reader is \(p.reader) who wants"))
        #expect(literal.contains("difficulty relative to \(p.difficultyReference)."))
        #expect(literal.contains("method ≤500 chars (\(p.methodHint))."))
        #expect(literal.contains("(typical \(p.typicalTimes))."))
        #expect(p.checklistExamples.count == 4)
        let quoted = p.checklistExamples.map { "\"\($0)\"" }.joined(separator: ", ")
        #expect(literal.contains("e.g. \(quoted). section ="))
    }

    @Test func readerDescriptionsAreSanitized() {
        #expect(CardPromptProfile.sanitize("  a cell\nbiologist\t(<b>postdoc</b>)\u{0007}  ") == "a cell biologist (bpostdoc/b)")
        #expect(CardPromptProfile.sanitize(" \n\t ") == nil)
        #expect(CardPromptProfile.sanitize(String(repeating: "x", count: 500))?.count == CardPromptProfile.maxReaderLength)
    }

    // MARK: Sender presets

    @Test func theSenderPresetsAreFrozenInOrder() {
        #expect(SenderRule.presets.map(\.id) == [
            "preset-google-scholar", "preset-arxiv", "preset-biorxiv", "preset-medrxiv", "preset-highwire",
            "preset-nature", "preset-cell", "preset-elsevier", "preset-ncbi",
        ])
        #expect(SenderRule.presets.map(\.pattern) == [
            "scholaralerts-noreply@google.com", "@arxiv.org", "@biorxiv.org", "@medrxiv.org", "@alerts.highwire.org",
            "@*.nature.com", "@cell.com", "@*.elsevier.com", "@ncbi.nlm.nih.gov",
        ])
        #expect(SenderRule.presets.allSatisfy { $0.kind == .alert && $0.aiPolicy == .always && $0.enabled })
        // The life-sciences field suggests exactly today's list, in today's order.
        #expect(FieldPresets.lifeSciencesCompBio.senderPresetIDs == SenderRule.presets.map(\.id))
        #expect(SenderPresetCatalog.suggested(for: FieldPresets.lifeSciencesCompBio) == SenderRule.presets)
    }

    // MARK: Organization and field strings (WashU + life sciences = today's texts)

    @Test(arguments: UILang.allCases)
    func theWashUTextsAreTodaysWordForWord(_ lang: UILang) throws {
        let golden = try GoldenOrgStrings.load()
        let washu = OrganizationPresets.washu
        var covered: Set<String> = []
        for key in OrgTextKey.allCases where key != .consentNote {
            let name = "org.\(key.rawValue)"
            covered.insert(name)
            #expect(OrgStrings.text(key, org: washu, lang: lang) == golden.text(name, lang), "\(name) [\(lang)]")
        }
        for provider in GoldenOrgStrings.consentProviders {
            let name = "org.consentNote.\(provider)"
            covered.insert(name)
            #expect(OrgStrings.consentNote(provider: provider, org: washu, lang: lang) == golden.text(name, lang), "\(name) [\(lang)]")
        }
        #expect(OrgStrings.paDefaultAccountName(org: washu, lang: lang) == golden.text("org.paDefaultAccountName", lang))
        let field = FieldPresets.lifeSciencesCompBio
        let fieldTexts = [
            "describeHint": FieldStrings.describeHint(field, lang),
            "categoryDescriptionPlaceholder": FieldStrings.categoryDescriptionPlaceholder(field, lang),
            "customInstructionsHint": FieldStrings.customInstructionsHint(field, lang),
            "alertsTip": FieldStrings.alertsTip(field, lang),
        ]
        #expect(Set(fieldTexts.keys) == Set(GoldenOrgStrings.fieldKeys))
        for (key, text) in fieldTexts {
            covered.insert("field.\(key)")
            #expect(text == golden.text("field.\(key)", lang), "field.\(key) [\(lang)]")
        }
        // The fixture holds exactly these keys (nothing unchecked).
        #expect(Set(golden.strings[lang.rawValue]?.keys.map { $0 } ?? []) == covered)
        #expect(covered.count == 18)
    }

    @Test func theLifeSciencesStartersAreTodays() {
        let starters = FieldPresets.lifeSciencesCompBio.starterCategories
        #expect(starters.map(\.name) == PaperCategory.starters.map(\.name))
        #expect(starters.map(\.description) == PaperCategory.starters.map(\.description))
    }

    @Test func theLegacySnapshotIsWashULifeSciencesMonthFirst() {
        let s = ConfigSnapshot.legacy
        #expect(s.organization == OrganizationPresets.washu)
        #expect(s.field == FieldPresets.lifeSciencesCompBio)
        #expect(s.stage == .phd && s.readerOverride == nil && s.mailDateOrder == .mdy && s.origin == .legacy)
        #expect(LegacyInstall.organizationID == OrganizationPresets.washu.id)
        #expect(LegacyInstall.fieldID == FieldPresets.lifeSciencesCompBio.id)
        #expect(LegacyInstall.dateOrder == .mdy)
    }

    // MARK: Synthetic settings domains

    @Test func theLegacyDomainFixtureHasTheCurrentUsersShape() throws {
        let p = try GoldenFixtures.plist("legacy-washu-domain")
        #expect(p["setup.completed"] as? Bool == true)
        #expect(p["agent.mode"] as? String == "claude")
        #expect(p["agent.provider"] as? String == "claude")
        #expect(p["library.path"] as? String == "/Users/example/Documents/PaperDeck")
        #expect(p["mail.enabled"] as? Bool == true)
        #expect(p["language"] == nil)                           // registered "en"
        #expect(!ConfigKeys.all.contains { p[$0] != nil })       // a domain from before the config layer

        let scratch = try GoldenFixtures.seeded("legacy-washu-domain", tag: "golden-legacy")
        defer { scratch.drop() }
        let mail = MailSettings.load(from: scratch.defaults)
        #expect(mail.enabled)
        #expect(mail.dateOrder == .mdy)
        let account = try #require(mail.accounts.first)
        #expect(mail.accounts.count == 1)
        #expect(account.id == "washu-pa" && account.kind == .folder && account.displayName == "WashU (Power Automate)")
        #expect(account.folderPath == "/Users/example/Library/CloudStorage/OneDrive-WashingtonUniversityinSt.Louis/PaperDeck Mail")
        #expect(account.source == nil)
        #expect(MailSourceResolver.source(of: account) == .m365PowerAutomate)
        #expect(mail.senders.map(\.id) == ["advisor-jsmith", "preset-google-scholar", "preset-biorxiv"])
        let advisor = try #require(mail.senders.first)
        #expect(advisor.pattern == "jsmith@wustl.edu" && advisor.kind == .advisor && advisor.aiPolicy == .ask)
        #expect(!mail.criteria.researchInterests.isEmpty)
    }

    @Test func theFreshDomainFixtureIsEmpty() throws {
        #expect(try GoldenFixtures.plist("fresh-domain").isEmpty)
    }

    @Test func thePersistedDomainNeverSeesRegisteredDefaults() {
        let scratch = ScratchDefaults("golden-persisted")
        defer { scratch.drop() }
        // Registered defaults are process-wide: unique keys keep other suites' tests unaffected.
        let tag = UUID().uuidString.lowercased()
        let flag = "golden.\(tag).completed", path = "golden.\(tag).path"
        scratch.defaults.register(defaults: [flag: false, path: "/Users/example/Documents/PaperDeck"])
        #expect(scratch.defaults.object(forKey: flag) != nil)
        #expect(!PersistedDomain.suite(scratch.name).has(flag))
        scratch.defaults.set(true, forKey: flag)
        scratch.defaults.set(3, forKey: "config.migrationVersion")
        let p = PersistedDomain.suite(scratch.name)
        #expect(p.has(flag) && !p.has(path))
        #expect(p.int("config.migrationVersion") == 3 && p.int(flag) == nil)
    }

    // MARK: Core ports stay behavior-neutral

    @Test func anAccountWithoutASourceEncodesAsBefore() throws {
        let a = MailAccount(id: "a1", kind: .folder, displayName: "Work (Power Automate)", folderPath: "/tmp/x")
        let json = MailSettings.encode([a])
        #expect(!json.contains("source"))
        var tagged = a
        tagged.source = "m365.powerAutomate"
        let round = MailSettings.list(MailSettings.encode([tagged]), MailAccount.self, what: "account")
        #expect(round == [tagged])
        #expect(MailSettings.list(json, MailAccount.self, what: "account") == [a])
    }

    @Test func slashDatesStayMonthFirstUnlessChosen() {
        let scratch = ScratchDefaults("golden-date-order")
        defer { scratch.drop() }
        #expect(MailSettings.Keys.dateOrder == "mail.dateOrder")
        #expect(MailSettings().dateOrder == .mdy)
        #expect(MailSettings.load(from: scratch.defaults).dateOrder == .mdy)
        scratch.defaults.set("dmy", forKey: MailSettings.Keys.dateOrder)
        #expect(MailSettings.load(from: scratch.defaults).dateOrder == .dmy)
        #expect(SlashDateOrder.auto.resolved(locale: Locale(identifier: "en_US")) == .mdy)
        #expect(SlashDateOrder.auto.resolved(locale: Locale(identifier: "en_GB")) == .dmy)
        #expect(SlashDateOrder.mdy.resolved(locale: Locale(identifier: "en_GB")) == .mdy)
    }

    @Test func theBuildIdentityFallbackIsTodaysIdentity() {
        let id = BuildIdentity.resolve(info: nil, mainBundleID: nil)
        #expect(id.bundleID == "com.yijiang.paperdeck")
        #expect(id.widgetBundleID == "com.yijiang.paperdeck.widget")
        #expect(id.keychainService == "com.yijiang.paperdeck.mail")
        #expect(id.logSubsystem == "com.yijiang.paperdeck")
        #expect(id.channel == .local)
        #expect(BuildIdentity.defaultBundleID == "com.yijiang.paperdeck")
        #expect(BuildIdentity.defaultSigningIdentityName == "PaperDeck Local Signing")
        #expect(BuildIdentity.resolve(info: nil, mainBundleID: "com.yijiang.paperdeck.widget") == id)
    }

    @Test func theNewDeepLinksRenderTheirURLs() {
        #expect(DeepLink.help(topic: nil).url.absoluteString == "paperdeck://help")
        #expect(DeepLink.help(topic: "connect-mail").url.absoluteString == "paperdeck://help/connect-mail")
        #expect(DeepLink.setup.url.absoluteString == "paperdeck://setup")
    }

    @Test func theTopicCatalogIdsAreUniqueAndWellFormed() {
        let ids = GuideTopicID.catalog.map(\.rawValue)
        #expect(Set(ids).count == ids.count)
        #expect(ids.count == 46)                // §3.8's 40 + the reading assist's duplicates, multi-select, ask, reader, explain, screen-recording
        #expect(ids.contains("duplicates") && ids.contains("multi-select") && ids.contains("ask") && ids.contains("reader"))
        #expect(ids.contains("explain") && ids.contains("screen-recording"))
        #expect(ids.allSatisfy { $0.range(of: "^[a-z0-9-]{1,48}$", options: .regularExpression) != nil })
    }
}
