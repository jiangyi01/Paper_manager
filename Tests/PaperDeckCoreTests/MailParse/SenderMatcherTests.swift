import Foundation
import Testing
@testable import PaperDeckCore

@Suite("MailParse · SenderMatcher") struct MailParseSenderMatcherTests {

    private static let advisor = SenderRule(id: "advisor", pattern: "Prof.X@wustl.edu", label: "Prof. X", kind: .advisor)
    private static let wustl = SenderRule(id: "wustl", pattern: "@wustl.edu", label: "WashU", kind: .person)
    private static let nature = SenderRule(id: "nature", pattern: "@*.nature.com", label: "Nature", kind: .alert)
    private static let natureApex = SenderRule(id: "nature-apex", pattern: "@nature.com", label: "Nature apex", kind: .person)
    private static let mailNature = SenderRule(id: "mail-nature", pattern: "@mail.nature.com", label: "mail", kind: .person)

    private static func match(_ a: String, _ rules: [SenderRule]) -> String? {
        SenderMatcher.match(address: a, rules: rules)?.id
    }

    @Test func normalize() {
        #expect(SenderMatcher.normalize("  Prof.X+papers@WUSTL.edu ") == "prof.x@wustl.edu")
        #expect(SenderMatcher.normalize("\"Prof X\" <Prof.X@wustl.edu>") == "prof.x@wustl.edu")
        #expect(SenderMatcher.normalize("mailto:prof.x@wustl.edu?subject=hi") == "prof.x@wustl.edu")
        #expect(SenderMatcher.normalize("prof.x@wustl.edu.") == "prof.x@wustl.edu")
        #expect(SenderMatcher.normalize("+leading@x.org") == "+leading@x.org")
        #expect(SenderMatcher.normalize("no-at-sign") == "no-at-sign")
    }

    @Test func exactAddressAndTags() {
        let rules = [Self.advisor]
        #expect(Self.match("prof.x@wustl.edu", rules) == "advisor")
        #expect(Self.match("PROF.X@WUSTL.EDU", rules) == "advisor")
        #expect(Self.match("prof.x+journalclub@wustl.edu", rules) == "advisor")
        #expect(Self.match("prof.y@wustl.edu", rules) == nil)
        #expect(Self.match("prof.x@wustl.edu.evil.com", rules) == nil)
        #expect(Self.match("prof.x@wustl.edu@evil.com", rules) == nil)
    }

    @Test func displayNamesNeverMatch() {
        let rules = [Self.advisor]
        #expect(Self.match("\"prof.x@wustl.edu\" <attacker@evil.com>", rules) == nil)
        #expect(Self.match("Prof X (prof.x@wustl.edu) <attacker@evil.com>", rules) == nil)
        #expect(Self.match("Prof X <prof.x@wustl.edu>", rules) == "advisor")
    }

    @Test func domainsAndWildcards() {
        #expect(Self.match("anyone@wustl.edu", [Self.wustl]) == "wustl")
        #expect(Self.match("anyone@med.wustl.edu", [Self.wustl]) == nil)             // subdomains need "*."
        #expect(Self.match("alerts@e-alerts.nature.com", [Self.nature]) == "nature")
        #expect(Self.match("alerts@nature.com", [Self.nature]) == "nature")          // wildcard also covers the apex
        #expect(Self.match("alerts@notnature.com", [Self.nature]) == nil)
        #expect(Self.match("x@nature.com.evil.org", [Self.nature]) == nil)
    }

    @Test func precedence() {
        let all = [Self.wustl, Self.nature, Self.natureApex, Self.mailNature, Self.advisor]
        #expect(Self.match("prof.x@wustl.edu", all) == "advisor")                    // exact beats domain
        #expect(Self.match("a@mail.nature.com", all) == "mail-nature")              // exact domain beats a wildcard
        #expect(Self.match("a@nature.com", all) == "nature-apex")                   // exact domain beats wildcard apex
        let deep = SenderRule(id: "deep", pattern: "@*.alerts.nature.com", kind: .alert)
        #expect(Self.match("a@x.alerts.nature.com", [Self.nature, deep]) == "deep")  // longer suffix wins
        let first = SenderRule(id: "first", pattern: "@wustl.edu", kind: .advisor)
        #expect(Self.match("a@wustl.edu", [first, Self.wustl]) == "first")           // ties keep list order
    }

    @Test func disabledAndInvalidRulesAreIgnored() {
        var off = Self.advisor
        off.enabled = false
        #expect(Self.match("prof.x@wustl.edu", [off]) == nil)
        #expect(Self.match("prof.x@wustl.edu", [off, Self.wustl]) == "wustl")
        let junk = [SenderRule(pattern: "", kind: .person), SenderRule(pattern: "@", kind: .person),
                    SenderRule(pattern: "@*", kind: .person), SenderRule(pattern: "*", kind: .person),
                    SenderRule(pattern: "@*.com.", kind: .person)]
        #expect(Self.match("someone@example.com", junk) == nil)
        #expect(Self.match("", [Self.wustl]) == nil)
        #expect(Self.match("@wustl.edu", [Self.wustl]) == nil)
    }

    @Test func lenientPatternForms() {
        #expect(SenderMatcher.Pattern("Prof X <Prof.X+tag@wustl.edu>") == .address("prof.x@wustl.edu"))
        #expect(SenderMatcher.Pattern("wustl.edu") == .domain("wustl.edu"))
        #expect(SenderMatcher.Pattern("*.nature.com") == .wildcard("nature.com"))
        #expect(SenderMatcher.Pattern(" @BioRxiv.org ") == .domain("biorxiv.org"))
        #expect(SenderMatcher.Pattern("not a pattern") == nil)
    }

    @Test func presets() {
        let p = SenderRule.presets
        #expect(Self.match("scholaralerts-noreply@google.com", p) == "preset-google-scholar")
        #expect(Self.match("no-reply@arxiv.org", p) == "preset-arxiv")
        #expect(Self.match("biorxiv@alerts.highwire.org", p) == "preset-highwire")
        #expect(Self.match("ealert@nature.com", p) == "preset-nature")
        #expect(Self.match("cellpress@notification.elsevier.com", p) == "preset-elsevier")
        #expect(Self.match("someone@gmail.com", p) == nil)
        #expect(Self.match("fake-scholar@google.com", p) == nil)
    }
}
