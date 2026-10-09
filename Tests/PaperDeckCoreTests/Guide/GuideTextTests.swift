import Foundation
import Testing
@testable import PaperDeckCore
import PaperDeckConfig
import PaperDeckShared

/// `paperdeck://help[/<topic>]` and `paperdeck://setup`: navigation only, strict ids.
@Suite("Deep links: help and setup")
struct DeepLinkHelpTests {
    private func link(_ s: String) -> DeepLink? { URL(string: s).flatMap(DeepLink.init(url:)) }

    @Test func parsesAndRoundTrips() {
        #expect(link("paperdeck://help") == .help(topic: nil))
        #expect(link("paperdeck://help/connect-mail") == .help(topic: "connect-mail"))
        #expect(link("paperdeck://setup") == .setup)
        #expect(link("PAPERDECK://Help") == .help(topic: nil))       // scheme and host are case-insensitive
        for l in [DeepLink.help(topic: nil), .help(topic: "fix-widget-missing"), .setup] {
            #expect(DeepLink(url: l.url) == l)
        }
        for id in GuideTopicID.catalog { #expect(link("paperdeck://help/\(id.rawValue)") == .help(topic: id.rawValue)) }
    }

    @Test func rejectsAnythingElse() {
        #expect(link("paperdeck://help/../x") == nil)
        #expect(link("paperdeck://help/Connect-Mail") == nil)                       // upper case
        #expect(link("paperdeck://help/" + String(repeating: "a", count: 49)) == nil)
        #expect(link("paperdeck://help/" + String(repeating: "a", count: 48)) == .help(topic: String(repeating: "a", count: 48)))
        #expect(link("paperdeck://help/a/b") == nil)
        #expect(link("paperdeck://help/a.b") == nil)
        #expect(link("paperdeck://help/%2E%2E") == nil)
        #expect(link("paperdeck://help/a_b") == nil)
        #expect(link("paperdeck://setup/now") == nil)
        #expect(link("https://help/connect-mail") == nil)
        #expect(!DeepLink.isValidTopic("") && !DeepLink.isValidTopic("é") && DeepLink.isValidTopic("fix-2"))
    }

    /// The links that existed before are untouched.
    @Test func existingLinksStillParse() {
        #expect(link("paperdeck://today") == .today)
        #expect(link("paperdeck://settings/mail") == .settings(tab: "mail"))
        #expect(link("paperdeck://mail") == .mail(id: nil))
    }
}

/// The copyable diagnostics: home → `~`, emails masked, nothing personal beyond counts.
@Suite("Diagnostics redaction")
struct DiagnosticsRedactionTests {
    typealias S = GuideSamples
    static let home = "/Users/jane"

    private func facts() -> SetupFacts {
        S.facts {
            $0.library = .value(LibraryFact(status: .ok, tildePath: "/Users/jane/Research/PaperDeck", volume: .local, hasManifest: true))
            $0.papers = .value(PaperCounts(live: 12, withCard: 10, opened: 3, missingFiles: 1, fullTextIndexed: 11))
            $0.ai = AIFact(mode: .claude, provider: .claude, decision: "claude",
                           statuses: [.claude: .value(.ready(plan: "max", version: "2.1", path: "/Users/jane/.local/bin/claude")),
                                      .codex: .value(.notLoggedIn("logged_out"))])
            $0.mail = MailFact(enabled: true, decision: "configured", accounts: [
                MailAccountFact(id: "jane.doe@gmail.com", source: .imapGmail, status: .authFailed("LOGIN for jane.doe@gmail.com rejected"),
                                passwordPresent: true),
                MailAccountFact(id: "work", source: .m365PowerAutomate, status: .ready(detail: "3 new files"), captured: 3, folderExists: true),
            ], senders: [.advisor: 1, .alert: 2])
            $0.cloud = .value(CloudFact(roots: [S.root(.googleDrive, "GoogleDrive-jane.doe@gmail.com")]))
        }
    }

    private func render(redact: Bool) -> String {
        DiagnosticsReport.render(facts(), identity: BuildIdentity.resolve(info: nil, mainBundleID: nil), config: .legacy,
                                 appVersion: "1.0 (27)", home: Self.home, redact: redact)
    }

    @Test func redactedTextHasNoHomeNoAddresses() {
        let text = render(redact: true)
        #expect(!text.contains("/Users/jane"))
        #expect(text.contains("~/Research/PaperDeck") && text.contains("~/.local/bin/claude"))
        #expect(!text.contains("jane.doe@gmail.com"))
        #expect(text.contains("googleDrive GoogleDrive-j***@gmail.com"))
        // Account ids, statuses' free text and folder names never appear (only kinds and counts).
        #expect(!text.contains("LOGIN for"))
        #expect(!text.contains("3 new files"))
        #expect(text.contains("account 1: imap.gmail · sign-in failed"))
        #expect(text.contains("account 2: m365.powerAutomate · ready"))
        #expect(text.contains("Papers: 12 (cards 10, opened 3, missing files 1, full text 11)"))
        #expect(text.contains("Bundle id: com.yijiang.paperdeck"))
        #expect(text.contains("org washu · field lifeSciencesCompBio · stage phd · origin legacy · dates mdy"))
        #expect(text.hasSuffix("\n"))
    }

    @Test func unredactedKeepsPaths() {
        let text = render(redact: false)
        #expect(text.contains("/Users/jane/Research/PaperDeck"))
    }

    @Test func helpers() {
        #expect(DiagnosticsReport.tilde("/Users/jane/x and /Users/janet/y", home: "/Users/jane") == "~/x and /Users/janet/y")
        #expect(DiagnosticsReport.tilde("home /Users/jane", home: "/Users/jane/") == "home ~")
        #expect(DiagnosticsReport.maskEmails("a@b.co, x.y+z@example.edu") == "a***@b.co, x***@example.edu")
        #expect(DiagnosticsReport.maskEmails("no address here") == "no address here")
    }

    @Test func aSecretNeverAppears() {
        // SetupFacts holds no secret field at all: the only keychain fact is "saved yes/no".
        let text = render(redact: true)
        #expect(text.contains("password saved yes"))
        #expect(!text.lowercased().contains("token"))
    }
}

/// Help search (en and zh), over sample topics and — once it has content — the catalog.
@Suite("Guide search")
struct GuideSearchTests {
    typealias S = GuideSamples

    @Test func findsByTitleKeywordAndID() {
        #expect(GuideSearch.search("onedrive", lang: .en, in: S.all).first == .mailM365PowerAutomate)
        #expect(GuideSearch.search("widget", lang: .en, in: S.all) == [.fixWidgetMissing])
        #expect(GuideSearch.search("邮件", lang: .zh, in: S.all).contains(.mailM365Blocked))
        #expect(GuideSearch.search("小组件", lang: .zh, in: S.all) == [.fixWidgetMissing])
        // The other language still matches (lower).
        #expect(GuideSearch.search("widget", lang: .zh, in: S.all) == [.fixWidgetMissing])
        // Every token must match.
        #expect(GuideSearch.search("onedrive widget", lang: .en, in: S.all).isEmpty)
        #expect(GuideSearch.search("  ", lang: .en, in: S.all).isEmpty)
        // Case and diacritics folded.
        #expect(GuideSearch.search("ONEDRÍVE", lang: .en, in: S.all).first == .mailM365PowerAutomate)
    }

    @Test(.disabled(if: GuideCatalog.topics.isEmpty, "the guide content isn't in this build yet"))
    func findsCatalogTopics() {
        #expect(GuideSearch.search("onedrive", lang: .en).contains(.mailM365PowerAutomate))
        #expect(GuideSearch.search("邮件", lang: .zh).contains(.connectMail))
        #expect(GuideSearch.search("widget", lang: .en).contains(.fixWidgetMissing))
    }
}

/// `--guide-export` / docs/TROUBLESHOOTING.md: deterministic Markdown with anchors = topic ids.
@Suite("Guide markdown")
struct GuideMarkdownTests {
    typealias S = GuideSamples

    @Test func rendersAnchorsStepsLinksAndRelated() {
        let md = GuideMarkdown.render([S.m365, S.blocked], lang: .en)
        #expect(md.hasPrefix("<a id=\"mail-m365-power-automate\"></a>\n### Microsoft 365 with Power Automate\n"))
        #expect(md.contains("1. Install OneDrive"))
        #expect(md.contains("6. First email arrives"))
        #expect(md.contains("[make.powerautomate.com](https://make.powerautomate.com)"))
        #expect(md.contains("**Related:** [When Microsoft 365 blocks Power Automate](#mail-m365-blocked)"))
        #expect(md.contains("*Last reviewed: 2026-10*"))
        let zh = GuideMarkdown.render([S.m365], lang: .zh)
        #expect(zh.contains("### Microsoft 365 + Power Automate") && zh.contains("最近核对：") == false && zh.contains("*最近核对: 2026-10*"))
    }

    @Test func commandsAreCodeBlocks() {
        let md = GuideMarkdown.render([S.widget], lang: .en)
        #expect(md.contains("   ```\n   open -a PaperDeck\n   ```"))
    }

    @Test func isDeterministic() {
        #expect(GuideMarkdown.render(S.all, lang: .en) == GuideMarkdown.render(S.all, lang: .en))
        #expect(GuideMarkdown.render([], lang: .en).isEmpty)
    }

    @Test func theTroubleshootingBlockHoldsOnlyTroubleshootingTopics() {
        let block = GuideMarkdown.troubleshooting(lang: .en, topics: S.all)
        #expect(block.contains("fix-widget-missing") && block.contains("fix-documents-access"))
        #expect(!block.contains("mail-m365-power-automate\""))
        #expect(block == GuideMarkdown.render([S.widget, S.documents], lang: .en))
    }
}
