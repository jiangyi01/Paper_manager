import Foundation
import Testing
@testable import PaperDeckCore
@testable import PaperDeckConfig

// T3 (PORTABILITY_PLAN §5.4): organization- and field-dependent texts. The legacy preset renders
// the golden fixture (produced from the build before any L10n edit) word for word; `generic` and
// custom organizations never name an institution they aren't; every Power Automate default
// account name keeps "Power Automate" (the legacy source inference relies on it).
@Suite struct OrgStringsGoldenTests {
    static let institutionWords = ["washu", "wustl", "washington"]

    static let contoso = OrganizationPresets.custom(
        name: "Contoso University", shortName: "Contoso", approvedAITools: ["Copilot Chat", "Gemini Edu"],
        policyURL: URL(string: "https://ai.contoso.edu/policy"), peopleDefault: .never, oneDriveRootHint: "Contoso")
    static let nameOnly = OrganizationPresets.custom(name: "Fabrikam Institute", shortName: nil, approvedAITools: [],
                                                     policyURL: nil, peopleDefault: .ask, oneDriveRootHint: nil)

    static func all(_ org: OrganizationProfile, _ lang: UILang) -> [String: String] {
        var out: [String: String] = [:]
        for key in OrgTextKey.allCases where key != .consentNote { out[key.rawValue] = OrgStrings.text(key, org: org, lang: lang) }
        for provider in GoldenOrgStrings.consentProviders {
            out["consentNote.\(provider)"] = OrgStrings.consentNote(provider: provider, org: org, lang: lang)
        }
        out["paDefaultAccountName()"] = OrgStrings.paDefaultAccountName(org: org, lang: lang)
        out["aiPolicyLine"] = OrgStrings.aiPolicyLine(org: org, lang: lang)
        return out
    }

    @Test(arguments: UILang.allCases)
    func theLegacyPresetRendersTheFixtureWordForWord(_ lang: UILang) throws {
        let golden = try GoldenOrgStrings.load()
        let org = OrganizationPresets.washu
        for key in OrgTextKey.allCases where key != .consentNote {
            #expect(OrgStrings.text(key, org: org, lang: lang) == golden.text("org.\(key.rawValue)", lang), "\(key) [\(lang)]")
        }
        for provider in GoldenOrgStrings.consentProviders {
            #expect(OrgStrings.consentNote(provider: provider, org: org, lang: lang)
                    == golden.text("org.consentNote.\(provider)", lang), "consentNote.\(provider) [\(lang)]")
        }
        let field = FieldPresets.lifeSciencesCompBio
        #expect(FieldStrings.describeHint(field, lang) == golden.text("field.describeHint", lang))
        #expect(FieldStrings.categoryDescriptionPlaceholder(field, lang) == golden.text("field.categoryDescriptionPlaceholder", lang))
        #expect(FieldStrings.customInstructionsHint(field, lang) == golden.text("field.customInstructionsHint", lang))
        #expect(FieldStrings.alertsTip(field, lang) == golden.text("field.alertsTip", lang))
        // The legacy note is shown only for a migrated (legacy) install.
        #expect(OrgStrings.legacyNote(org: org, origin: .legacy, lang: lang)?.isEmpty == false)
        #expect(OrgStrings.legacyNote(org: org, origin: .fresh, lang: lang) == nil)
    }

    @Test(arguments: UILang.allCases)
    func genericAndCustomNeverNameAnotherInstitution(_ lang: UILang) {
        for org in [OrganizationPresets.generic, Self.contoso, Self.nameOnly] {
            for (key, text) in Self.all(org, lang) {
                let lower = text.lowercased()
                for word in Self.institutionWords { #expect(!lower.contains(word), "\(org.id).\(key) [\(lang)]: \(text)") }
                #expect(!text.isEmpty, "\(org.id).\(key) [\(lang)]")
                #expect(!text.contains("{") && !text.contains("}"), "\(org.id).\(key) [\(lang)]: unfilled slot")
            }
            #expect(OrgStrings.legacyNote(org: org, origin: .legacy, lang: lang) == nil)
        }
    }

    @Test(arguments: UILang.allCases)
    func theDefaultAccountNameAlwaysSaysPowerAutomate(_ lang: UILang) {
        for org in [OrganizationPresets.generic, OrganizationPresets.washu, Self.contoso, Self.nameOnly] {
            let name = OrgStrings.paDefaultAccountName(org: org, lang: lang)
            #expect(name.contains("Power Automate"), "\(org.id) [\(lang)]")
            // A new account with that name is the Power Automate route even without `source`.
            let account = MailAccount(kind: .folder, displayName: name, folderPath: "/tmp/elsewhere")
            #expect(MailSourceResolver.source(of: account) == .m365PowerAutomate)
        }
        #expect(OrgStrings.paDefaultAccountName(org: Self.contoso, lang: .en) == "Contoso (Power Automate)")
        #expect(OrgStrings.paDefaultAccountName(org: OrganizationPresets.generic, lang: .en) == "Microsoft 365 (Power Automate)")
    }

    @Test func customTextsUseTheShortNameAndTheApprovedTools() {
        let en = Self.all(Self.contoso, .en), zh = Self.all(Self.contoso, .zh)
        #expect(en["paTemplateName"] == "Microsoft 365 via Power Automate (Contoso)")
        #expect(en["policyNote"]?.hasPrefix("Contoso AI guidance: don't put unpublished work into AI platforms that aren't approved (Copilot Chat / Gemini Edu are).") == true)
        #expect(en["triagePrivacy"]?.hasSuffix(" Contoso: prefer Copilot Chat / Gemini Edu logins for people's mail.") == true)
        #expect(en["personSenderWarning"] == "People may send unpublished work; Contoso University asks not to put it into AI tools that aren't approved.")
        #expect(en["consentNote.Claude"]?.hasPrefix("Sends this one email's text to Claude once") == true)
        #expect(en["consentNote.Claude"]?.hasSuffix("Contoso guidance: don't send unpublished work to an unapproved AI.") == true)
        #expect(en["aiPolicyLine"] == "Contoso guidance: use an approved AI login (Copilot Chat, Gemini Edu) for unpublished work.")
        #expect(en["paIntro"]?.contains("with your Contoso account") == true)
        for (key, text) in zh where ["paTemplateName", "policyNote", "triagePrivacy", "paDefaultAccountName"].contains(key) {
            #expect(text.contains("Contoso"), "\(key) [zh]")
        }
        // A name without a short name: the name labels the texts.
        #expect(Self.all(Self.nameOnly, .en)["paTemplateName"] == "Microsoft 365 via Power Automate (Fabrikam Institute)")
        // No approved tools: no "(… are)" claim.
        #expect(Self.all(Self.nameOnly, .en)["policyNote"]?.contains(" are)") == false)
    }

    @Test func genericTextsAreTheNeutralWording() {
        let en = Self.all(OrganizationPresets.generic, .en)
        #expect(en["patternInvalid"] == "Not an address or a domain. Examples: name@university.edu, @biorxiv.org, @*.nature.com")
        #expect(en["paTemplateName"] == "Microsoft 365 (work or school) via Power Automate")
        #expect(en["triagePrivacy"]?.hasSuffix("The model has no tools and the email is marked as untrusted.") == true)
        #expect(en["consentNote.ChatGPT"]?.hasSuffix("Check your institution's guidance before sending unpublished work to an AI.") == true)
        #expect(en["paIntro"]?.contains("make.powerautomate.com") == true)
        #expect(en["aiPolicyLine"] == "Check your institution's guidance before sending unpublished work to an AI.")
        // An organization's own (https) Power Automate portal is named instead.
        var gov = OrganizationPresets.generic
        gov.mail.powerAutomatePortal = URL(string: "https://make.gov.powerautomate.us")
        #expect(OrgStrings.text(.paIntro, org: gov, lang: .en).contains("make.gov.powerautomate.us"))
        gov.mail.powerAutomatePortal = URL(string: "http://phish.example")
        #expect(OrgStrings.text(.paIntro, org: gov, lang: .en).contains("make.powerautomate.com"))
    }

    @Test func customFreeTextIsCappedAndPlain() {
        let org = OrganizationPresets.custom(name: String(repeating: "N", count: 90) + "\n{provider}<b>", shortName: "Very Long Short Name Here",
                                             approvedAITools: (1...8).map { "Tool \($0) " + String(repeating: "t", count: 50) },
                                             policyURL: URL(string: "http://insecure.example"), peopleDefault: .never,
                                             oneDriveRootHint: nil)
        #expect((org.name?.en.count ?? 0) <= 60 && org.name?.en.contains("{") == false && org.name?.en.contains("<") == false)
        #expect((org.shortName?.count ?? 0) <= 16)
        #expect(org.approvedAITools.count == 5 && org.approvedAITools.allSatisfy { $0.count <= 40 })
        #expect(org.policyURL == nil)
        #expect(org.texts.isEmpty && org.id == "custom")
    }

    @Test func fieldStringsFillEveryFieldsSlots() {
        for field in FieldPresets.all {
            for lang in UILang.allCases {
                for text in [FieldStrings.describeHint(field, lang), FieldStrings.categoryDescriptionPlaceholder(field, lang),
                             FieldStrings.customInstructionsHint(field, lang), FieldStrings.alertsTip(field, lang)] {
                    #expect(!text.isEmpty && text.count < 400, "\(field.id) [\(lang)]")
                }
            }
        }
    }
}
