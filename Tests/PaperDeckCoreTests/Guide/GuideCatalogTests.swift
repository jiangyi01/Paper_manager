import Foundation
import Testing
@testable import PaperDeckCore
import PaperDeckConfig
import PaperDeckShared

/// The Help Center catalog: §3.8 ids, bilingual text, links and verification rules (`GuideLint`).
@Suite("Guide catalog")
struct GuideCatalogTests {
    @Test func theTopicIDCatalogMatchesTheContract() {
        let ids = GuideTopicID.catalog
        #expect(ids.count == 46)                // §3.8's 40 + the reading assist's duplicates, multi-select, ask, reader, explain, screen-recording
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { DeepLink.isValidTopic($0.rawValue) })
        #expect(ids.contains(.connectMail) && ids.contains(.fixTwoMacsDiverged) && ids.contains(.gettingStarted))
    }

    @Test func everyCatalogTopicFollowsTheContentRules() {
        let problems = GuideLint.problems(GuideCatalog.topics)
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// Runs once the content (S4) is in the build.
    @Test(.disabled(if: GuideCatalog.topics.isEmpty, "the guide content isn't in this build yet"))
    func everyCatalogIDHasExactlyOneTopic() {
        let topics = GuideCatalog.topics
        #expect(GuideLint.missing(topics).isEmpty, "missing: \(GuideLint.missing(topics).map(\.rawValue))")
        #expect(Set(topics.map(\.id)).count == topics.count)
        for id in GuideTopicID.catalog { #expect(GuideCatalog.topic(id)?.id == id) }
    }

    @Test(.disabled(if: GuideCatalog.topics.isEmpty, "the guide content isn't in this build yet"))
    func everyTopicDeepLinkRoundTrips() throws {
        for t in GuideCatalog.topics {
            let link = DeepLink.help(topic: t.id.rawValue)
            #expect(DeepLink(url: link.url) == link)
        }
    }

    @Test func theSamplesPassTheLint() {
        #expect(GuideLint.problems(GuideSamples.all).isEmpty, "\(GuideLint.problems(GuideSamples.all))")
    }

    @Test func theLintCatchesEachRule() {
        let t = GuideSamples.text
        var bad = GuideTopic(id: "Bad_ID", kind: .tutorial, title: LocalizedText(en: "Title", zh: ""), summary: t("s", "s"),
                             steps: [
                                GuideStep(id: "a", text: t("a", "a"), verification: .manual(reason: LocalizedText(en: "", zh: ""))),
                                GuideStep(id: "b", text: t("b", "b"), verification: .manual(reason: t("r", "r"))),
                                GuideStep(id: "c", text: t("c", "c"), verification: .impliedBy(step: 0),
                                          actions: [.openURL(URL(string: "https://evil.example.net/x")!),
                                                    .openURL(URL(string: "http://make.powerautomate.com")!)],
                                          commands: ["cp /Users/jane/file .", "mail jane.doe@gmail.com", "ok@example.edu"]),
                             ],
                             related: ["no-such-topic"], lastReviewed: "October")
        let once = GuideLint.problems([bad])
        let names = (GuideLint.problems([bad, bad])).joined(separator: "\n")
        for fragment in ["duplicate id", "^[a-z0-9-]{1,48}$", "title needs en and zh", "a manual step needs a reason",
                         "at most one manual step", "impliedBy must point to a later step", "link host evil.example.net",
                         "link host make.powerautomate.com", "home path", "real-looking address", "related no-such-topic",
                         "lastReviewed must be YYYY-MM"] {
            #expect(names.contains(fragment), "lint missed: \(fragment)")
        }
        // The example domains are fine; the gmail address isn't.
        #expect(once.count(where: { $0.contains("real-looking address") }) == 1)
        #expect(!once.contains { $0.contains("duplicate id") })
        // An institution named in a command (the preset's own names, never a literal in the linter).
        bad = GuideTopic(id: "inst", kind: .tutorial, title: t("t", "t"), summary: t("s", "s"),
                         steps: [GuideStep(id: "x", text: t("x", "x"), commands: ["echo \(OrganizationPresets.washu.shortName ?? "")"])],
                         lastReviewed: "2026-10")
        #expect(GuideLint.problems([bad]).contains { $0.contains("names an institution") })
    }

    @Test func linksOnlyGoToTheAllowlist() {
        #expect(GuideLinks.isAllowed(URL(string: "https://make.powerautomate.com/environments")!))
        #expect(GuideLinks.isAllowed(URL(string: "https://myaccount.google.com/apppasswords")!))
        #expect(!GuideLinks.isAllowed(URL(string: "http://claude.ai")!))
        #expect(!GuideLinks.isAllowed(URL(string: "https://claude.ai.evil.com")!))
        #expect(!GuideLinks.isAllowed(URL(string: "paperdeck://help")!))
        #expect(GuideLinks.allowedHosts.count == 12)
    }

    @Test func aMissingTopicIsNil() {
        #expect(GuideCatalog.topic("no-such-topic") == nil)
    }
}
