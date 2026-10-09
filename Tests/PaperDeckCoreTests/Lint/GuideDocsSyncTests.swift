import Foundation
import Testing
@testable import PaperDeckCore
import PaperDeckConfig

/// The docs follow the Help Center (PORTABILITY_PLAN §4, §6.1.2):
/// - docs/TROUBLESHOOTING.md's generated blocks (`<!-- BEGIN GENERATED: troubleshooting <lang> -->`
///   … `<!-- END GENERATED: troubleshooting <lang> -->`) are exactly `GuideMarkdown.troubleshooting`
///   — what `PaperDeck --guide-export DIR --lang <lang>` writes to `TROUBLESHOOTING.generated.<lang>.md`.
///   Edit `Sources/PaperDeckConfig/Guide/Content/`, then paste the export between the markers;
///   never edit the blocks by hand.
/// - docs/USER_GUIDE.md has an anchor (`<a id="<topic id>"></a>`) for every topic id, so the
///   Help Center's ids, the user guide and the troubleshooting block's related links agree.
/// Skips when the docs aren't next to the sources (a relocated test bundle).
@Suite("Docs follow the guide catalog")
struct GuideDocsSyncTests {
    static let troubleshooting = LintRepo.url("docs/TROUBLESHOOTING.md")
    static let userGuide = LintRepo.url("docs/USER_GUIDE.md")
    static var docsPresent: Bool {
        FileManager.default.fileExists(atPath: troubleshooting.path) && FileManager.default.fileExists(atPath: userGuide.path)
    }

    /// The text between the BEGIN marker's line and the END marker (the block's own lines).
    static func block(_ doc: String, lang: UILang) -> String? {
        let begin = "<!-- BEGIN GENERATED: troubleshooting \(lang.rawValue) -->\n"
        let end = "<!-- END GENERATED: troubleshooting \(lang.rawValue) -->"
        guard let b = doc.range(of: begin), let e = doc.range(of: end, range: b.upperBound..<doc.endIndex) else { return nil }
        return String(doc[b.upperBound..<e.lowerBound])
    }

    @Test(.enabled(if: docsPresent, "docs/ isn't next to the sources"), arguments: [UILang.en, .zh])
    func theTroubleshootingBlocksAreTheExport(_ lang: UILang) throws {
        let doc = try String(contentsOf: Self.troubleshooting, encoding: .utf8)
        let block = try #require(Self.block(doc, lang: lang), "no generated \(lang.rawValue) block in docs/TROUBLESHOOTING.md")
        let export = GuideMarkdown.troubleshooting(lang: lang)
        #expect(!export.isEmpty)
        // The export ends with one newline; the END marker starts the next line.
        #expect(block == export, "docs/TROUBLESHOOTING.md (\(lang.rawValue)) is out of date: paste `PaperDeck --guide-export DIR --lang \(lang.rawValue)`'s TROUBLESHOOTING.generated.\(lang.rawValue).md between the markers")
        // Every troubleshooting topic is in the block, once.
        for t in GuideCatalog.topics where t.kind == .troubleshoot {
            #expect(block.components(separatedBy: "<a id=\"\(t.id.rawValue)\"></a>").count == 2, "\(t.id.rawValue)")
        }
    }

    @Test(.enabled(if: docsPresent, "docs/ isn't next to the sources"))
    func everyTopicIDHasAnAnchorInTheUserGuide() throws {
        let doc = try String(contentsOf: Self.userGuide, encoding: .utf8)
        let missing = GuideTopicID.catalog.filter { !doc.contains("<a id=\"\($0.rawValue)\"></a>") }
        #expect(missing.isEmpty, "docs/USER_GUIDE.md lacks anchors: \(missing.map(\.rawValue))")
    }

    /// Links in the troubleshooting block resolve: a topic in the block by `#id`, any other topic
    /// in the user guide (`USER_GUIDE.md#id`, an anchor checked above).
    @Test(.enabled(if: docsPresent, "docs/ isn't next to the sources"), arguments: [UILang.en, .zh])
    func theBlocksLinksResolve(_ lang: UILang) throws {
        let doc = try String(contentsOf: Self.troubleshooting, encoding: .utf8)
        let block = try #require(Self.block(doc, lang: lang))
        let guide = try String(contentsOf: Self.userGuide, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"\]\((USER_GUIDE\.md)?#([a-z0-9-]+)\)"#)
        let ns = block as NSString
        let links = regex.matches(in: block, range: NSRange(location: 0, length: ns.length))
        #expect(!links.isEmpty)
        for m in links {
            let inGuide = m.range(at: 1).location != NSNotFound
            let id = ns.substring(with: m.range(at: 2))
            let anchor = "<a id=\"\(id)\"></a>"
            #expect((inGuide ? guide : block).contains(anchor), "\(lang.rawValue): link to \(inGuide ? "USER_GUIDE.md" : "")#\(id) has no anchor")
        }
    }

    @Test func aRelatedTopicOutsideTheRenderedSetLinksToTheUserGuide() {
        let md = GuideMarkdown.render([GuideSamples.m365], lang: .en)
        #expect(md.contains("**Related:** [When Microsoft 365 blocks Power Automate](USER_GUIDE.md#mail-m365-blocked)"))
        let both = GuideMarkdown.render([GuideSamples.m365, GuideSamples.blocked], lang: .en)
        #expect(both.contains("](#mail-m365-blocked)") && !both.contains("USER_GUIDE.md#mail-m365-blocked"))
    }
}
