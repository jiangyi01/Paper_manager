import Foundation
import Testing

/// Portability verification regression #6: two app-target wirings no test caught (mutations A2,
/// A16). `--selftest app-rules` draws the inspector and `--selftest onboarding` drives the installed
/// activity path; these read the app sources (the test target doesn't link the app) so a lost
/// wiring also fails `./test.sh`. Read-only over the repository (`LintRepo`).
@Suite("App wirings (inspector consent, first-use policy)")
struct PF2AppWiringLintTests {
    static func source(_ path: String) throws -> String {
        try String(contentsOf: LintRepo.url(path), encoding: .utf8)
    }

    /// The argument lists of every `name(` call in `text` (balanced parentheses).
    static func calls(_ name: String, in text: String) -> [String] {
        var out: [String] = []
        var from = text.startIndex
        while let r = text.range(of: name + "(", range: from..<text.endIndex) {
            var depth = 1
            var i = r.upperBound
            while i < text.endIndex, depth > 0 {
                if text[i] == "(" { depth += 1 } else if text[i] == ")" { depth -= 1 }
                i = text.index(after: i)
            }
            out.append(String(text[r.upperBound..<text.index(before: i)]))
            from = i
        }
        return out
    }

    /// A2: the inspector shows the whole 「让 AI 分析」 explanation — never the one-line list version.
    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func theInspectorPassesTheFullConsent() throws {
        let detail = try Self.source("Sources/PaperDeck/Views/Mail/MailDetailView.swift")
        let inspector = Self.calls("MailTriageStatusView", in: detail)
        #expect(!inspector.isEmpty, "MailDetailView no longer shows the triage status")
        for args in inspector {
            // `compact` left out (it defaults to false) or false — nothing else.
            let compact = args.range(of: #"compact:\s*([^,)]+)"#, options: .regularExpression).map { String(args[$0]) }
            #expect(compact == nil || compact?.replacingOccurrences(of: " ", with: "") == "compact:false",
                    "the inspector must pass compact: false — found \(args)")
        }
        let card = try Self.source("Sources/PaperDeck/Views/Mail/MailCardView.swift")
        #expect(card.contains("static func compactConsent(selected: Bool) -> Bool { !selected }"))
        #expect(card.contains("var compact = false"), "MailTriageStatusView's default must stay the full box")
        let list = Self.calls("MailTriageStatusView", in: card)
        #expect(list.count == 1 && list[0].contains("compact: Self.compactConsent(selected: selected)"), "\(list)")
    }

    /// A16: the app installs the first-use store together with its policy, and a store without a
    /// policy records nothing (a lost wiring can't bring back legacy installs' `guide.activity`).
    @Test(.enabled(if: LintRepo.hasSources, "the sources aren't next to the tests"))
    func theAppInstallsTheActivityPolicy() throws {
        let delegate = try Self.source("Sources/PaperDeck/App/AppDelegate.swift")
        let launch = try #require(delegate.range(of: "func applicationDidFinishLaunching("))
        let body = delegate[launch.upperBound...].prefix(2500)
        #expect(body.components(separatedBy: "GuideActivity.install(guide, settings: settings, facts: facts)").count == 2,
                "applicationDidFinishLaunching must call GuideActivity.install once")
        let activity = try Self.source("Sources/PaperDeck/App/GuideActivity.swift")
        #expect(activity.contains("""
            static func install(_ guide: GuideStore, settings: SettingsStore, facts: SetupFactsCollector) {
                    guide.recordsActivity = policy(settings: settings, facts: facts)
                    store = guide
            """), "GuideActivity.install must set the policy with the store")
        #expect(activity.contains("guard let store, store.recordsActivity != nil else { return }"),
                "GuideActivity.record must fail closed without a policy")
        // Nothing else in the app sets the store (self-tests restore what they change).
        let setters = try LintRepo.grep(#"GuideActivity\.store\s*=[^=]"#, under: "Sources/PaperDeck")
            .filter { !$0.path.hasPrefix("Sources/PaperDeck/CLI/SelfTest") }
        #expect(setters.isEmpty, "\(setters)")
    }
}
