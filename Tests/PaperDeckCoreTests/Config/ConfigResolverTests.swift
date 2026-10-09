import Foundation
import Testing
@testable import PaperDeckCore
@testable import PaperDeckConfig

// T12 ConfigResolverTests and T15 ConsentFloorTests (PORTABILITY_PLAN §5.4).
@Suite struct ConfigResolverTests {
    @Test func absentKeysResolveByOrigin() {
        let fresh = ConfigResolver.resolve(PersistedDomain(["config.origin": "fresh"]), databaseExists: true)
        #expect(fresh.origin == .fresh && fresh.organization == OrganizationPresets.generic && fresh.field == FieldPresets.general)
        #expect(fresh.stage == .phd && fresh.readerOverride == nil && fresh.mailDateOrder == .mdy)
        let legacy = ConfigResolver.resolve(PersistedDomain(["config.origin": "legacy"]), databaseExists: false)
        #expect(legacy == ConfigSnapshot.legacy)
        // No recorded origin: classified like the migration would.
        #expect(ConfigResolver.resolve(PersistedDomain([:]), databaseExists: false).origin == .fresh)
        #expect(ConfigResolver.resolve(PersistedDomain([:]), databaseExists: true).origin == .legacy)
        #expect(ConfigResolver.resolve(PersistedDomain(["setup.completed": true]), databaseExists: false) == .legacy)
    }

    @Test func storedChoicesWin() {
        let p = PersistedDomain(["config.origin": "legacy", "config.migrationVersion": 1, "org.preset": "generic",
                                 "profile.field": "physicsAstro", "profile.stage": "postdoc",
                                 "profile.readerDescription": "an X-ray crystallographer\n<script>", "mail.dateOrder": "dmy"])
        let s = ConfigResolver.resolve(p, databaseExists: true)
        #expect(s.migrationVersion == 1 && s.origin == .legacy)
        #expect(s.organization == OrganizationPresets.generic && s.field == FieldPresets.physicsAstro && s.stage == .postdoc)
        #expect(s.readerOverride == "an X-ray crystallographer script" && s.mailDateOrder == .dmy)
        #expect(s.cardPromptProfile.reader == "an X-ray crystallographer script")
        #expect(s.cardPromptProfile.difficultyReference == "the reader described above")
    }

    @Test func theCustomOrganizationDecodesSanitized() throws {
        let raw = OrganizationProfile(id: "custom", name: LocalizedText("Contoso University"), shortName: "Contoso",
                                      approvedAITools: ["Copilot Chat"], policyURL: URL(string: "https://ai.contoso.edu"),
                                      peopleDefault: .never,
                                      texts: ["policyNote": LocalizedText("Injected text that must never render")],
                                      mail: OrgMailHints(oneDriveRootHint: "Contoso", powerAutomatePortal: URL(string: "https://x.example")))
        let json = String(decoding: try JSONEncoder().encode(raw), as: UTF8.self)
        let s = ConfigResolver.resolve(PersistedDomain(["config.origin": "fresh", "org.preset": "custom", "org.custom": json]),
                                       databaseExists: false)
        #expect(s.organization.id == "custom" && s.organization.shortName == "Contoso")
        #expect(s.organization.texts.isEmpty)                                   // never imported, never rendered
        #expect(s.organization.peopleDefault == .never && s.organization.mail.oneDriveRootHint == "Contoso")
        #expect(s.organization.policyURL?.absoluteString == "https://ai.contoso.edu")
        #expect(!OrgStrings.text(.policyNote, org: s.organization, lang: .en).contains("Injected"))
        // The stored form round-trips.
        #expect(ConfigResolver.decodeCustom(ConfigResolver.encodeCustom(s.organization)) == s.organization)
        // Unreadable custom JSON, or an unknown preset id → the generic wording.
        #expect(ConfigResolver.organization("custom", custom: "{not json", origin: .legacy) == OrganizationPresets.generic)
        #expect(ConfigResolver.organization("custom", custom: nil, origin: .legacy) == OrganizationPresets.generic)
        #expect(ConfigResolver.organization("mit", custom: nil, origin: .legacy) == OrganizationPresets.generic)
        #expect(ConfigResolver.organization(nil, custom: nil, origin: .legacy) == OrganizationPresets.washu)
        #expect(ConfigResolver.organization(nil, custom: nil, origin: .fresh) == OrganizationPresets.generic)
        #expect(ConfigResolver.organization("washu", custom: nil, origin: .fresh) == OrganizationPresets.washu)
    }

    @Test func loadReadsTheLiveDefaults() {
        let scratch = ScratchDefaults("config-load")
        defer { scratch.drop() }
        // Nothing recorded: the app's legacy fallback is today's configuration.
        #expect(ConfigResolver.load(scratch.defaults, legacyFallback: true) == .legacy)
        #expect(ConfigResolver.load(scratch.defaults, legacyFallback: false).origin == .fresh)
        #expect(ConfigResolver.cardPromptProfile(scratch.defaults) == .legacyCompBio)
        scratch.defaults.set("csML", forKey: ConfigKeys.profileField)
        scratch.defaults.set("faculty", forKey: ConfigKeys.profileStage)
        let p = ConfigResolver.cardPromptProfile(scratch.defaults)
        #expect(p.reader == "a computer-science / machine-learning researcher (faculty level)")
        #expect(CardSchema.systemPrompt(for: p) != CardSchema.systemPrompt)
    }

    @Test func persistedDomainsReadOnlyStoredValues() {
        let p = PersistedDomain(["a": "x", "n": 3, "b": true, "d": 1.5])
        #expect(p.has("a") && !p.has("z") && p.string("a") == "x" && p.string("n") == nil)
        #expect(p.int("n") == 3 && p.int("b") == nil && p.int("a") == nil)
        #expect(p.values.count == 4)
    }

    @Test func configKeysAreUniqueAndNeverRegistered() {
        #expect(Set(ConfigKeys.all).count == ConfigKeys.all.count)
        #expect(ConfigKeys.all.allSatisfy { !$0.isEmpty })
    }
}

@Suite struct ConsentFloorTests {
    @Test func peopleDefaultsCanOnlyBeAskOrNever() {
        #expect(PeopleAIDefault.allCases == [.ask, .never])
        #expect(PeopleAIDefault.ask.policy == .ask && PeopleAIDefault.never.policy == .never)
        #expect(PeopleAIDefault(rawValue: "always") == nil)
        for org in OrganizationPresets.builtIn { #expect(org.peopleDefault == .ask, "\(org.id)") }
    }

    @Test func importedOrganizationsCannotLoosen() throws {
        // A hand-edited file asking for "always" for people decodes as ask.
        let json = #"{"id":"custom","name":{"en":"Lab","zh":"Lab"},"peopleDefault":"always","approvedAITools":["X"]}"#
        let decoded = try JSONDecoder().decode(OrganizationProfile.self, from: Data(json.utf8))
        #expect(decoded.peopleDefault == .ask)
        #expect(ConfigResolver.decodeCustom(json)?.peopleDefault == .ask)
        let never = #"{"id":"custom","peopleDefault":"never"}"#
        #expect(ConfigResolver.decodeCustom(never)?.peopleDefault == .never)
    }

    @Test func alertDefaultsAreUnchanged() {
        #expect(SenderRule(pattern: "@biorxiv.org", kind: .alert).aiPolicy == .always)
        #expect(SenderRule(pattern: "a@b.org", kind: .person).aiPolicy == .ask)
        #expect(SenderRule(pattern: "a@b.org", kind: .advisor).aiPolicy == .ask)
        #expect(MailSettings().aiMode == .ai && MailSettings().triageDailyMax == 30 && !MailSettings().enabled)
    }
}
