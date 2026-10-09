import Foundation
import Testing
@testable import PaperDeckCore
@testable import PaperDeckConfig

/// The docs changes of the last portability round and of the integration round say what the code
/// does: the move guide's merge-by-id and never-loosen rules (and the new guards), the user guide's
/// confidential-mail hold, MAIL_DESIGN's F3 (soft review requests) and F13 (confidential mail at
/// merge) — each with the code names it cites still present in the sources.
@Suite("Docs of the portability rounds", .enabled(if: LintRepo.hasSources, "the docs aren't next to the tests"))
struct PortDocsRegressionTests {
    static func doc(_ path: String) throws -> String {
        try String(contentsOf: LintRepo.url(path), encoding: .utf8)
    }

    /// The text from the first line containing `start` up to the next blank line or heading.
    static func paragraph(_ doc: String, from start: String) -> String? {
        let lines = doc.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.contains(start) }) else { return nil }
        var out = [lines[i]]
        for l in lines[(i + 1)...] {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("- **") || t.hasPrefix("**") { break }
            out.append(l)
        }
        return out.joined(separator: " ").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Whether `symbol` (e.g. `func isConfidential`) occurs in some file under Sources/.
    static func sourcesContain(_ symbol: String) -> Bool {
        LintRepo.swiftFiles(under: "Sources").contains { path in
            (try? String(contentsOf: LintRepo.url(path), encoding: .utf8))?.contains(symbol) ?? false
        }
    }

    // MARK: MOVE_TO_ANOTHER_MAC

    @Test func theMoveGuideMergesByIDAndKeepsThisMacsID() throws {
        let merge = try #require(Self.paragraph(try Self.doc("docs/guides/MOVE_TO_ANOTHER_MAC.md"),
                                                from: "**Senders and mail accounts are merged, not replaced.**"))
        for phrase in ["matched by its id", "a sender by its address or domain", "an account by its mailbox",
                       "keeps **this Mac's id**", "saved app password", "entries only this Mac has", "are kept",
                       "add 2 · replace 1 · keep 3"] {
            #expect(merge.contains(phrase), "\(phrase) — \(merge)")
        }
        // What the code does: same id first, else the same pattern / mailbox; this Mac's id is kept.
        var here = SenderRule(pattern: "pi@lab.example.edu", kind: .advisor)
        here.id = "pi"
        var theirs = SenderRule(pattern: "PI@lab.example.edu", kind: .advisor)
        theirs.id = "other-id"
        theirs.label = "Prof."
        let m = SettingsImporter.mergeSenders(current: [here], imported: [theirs], keepPeopleAlways: false)
        #expect(m.rules.map(\.id) == ["pi"] && m.rules.first?.label == "Prof." && m.merge.replaced == ["Prof."])
    }

    @Test func theMoveGuideNeverLoosensAndNamesEveryGuard() throws {
        let guide = try Self.doc("docs/guides/MOVE_TO_ANOTHER_MAC.md")
        let never = try #require(Self.paragraph(guide, from: "**Nothing gets looser about privacy or quota.**"))
        for phrase in ["Local rules only", "a lower AI triage daily limit", "a sender's lower AI policy (Never → Ask → Always)",
                       "a sender or mail account turned off", "an account's shorter look-back",
                       "\"Never send to AI\" for people", "**Kept stricter**", "off by default", "--accept-looser",
                       // The integration round's guards.
                       "**another AI service**", "**Delete processed files**",
                       "**new sender that is more specific than a stricter rule here**", "news@lab.example.edu"] {
            #expect(never.contains(phrase), "\(phrase) — \(never)")
        }
        let range = try #require(Self.paragraph(guide, from: "**Values out of range are dropped.**"))
        #expect(range.contains("1e300") && range.contains("not imported"), "\(range)")
        let reader = try #require(Self.paragraph(guide, from: "**The reader description** and **the instructions for AI email sorting**"))
        #expect(reader.contains("only if you confirm them"), "\(reader)")
        // The registry backs the text: those keys and fields are guarded.
        #expect(SettingsRegistry.entry(MailSettings.Keys.triageProvider)?.sensitivity?.order == .provider)
        #expect(SettingsImporter.guardedAccountFields.contains(.deleteProcessedFiles))
        #expect(SettingsRegistry.valueRules[MailSettings.Keys.triageDailyMax]?.validated(.number(1e300)) == nil)
    }

    @Test func theUserGuideAndReadmeListTheNewGuards() throws {
        let user = try #require(Self.paragraph(try Self.doc("docs/USER_GUIDE.md"),
                                               from: "**An imported file never loosens privacy or quota silently.**"))
        for phrase in ["**Kept stricter**", "another AI service", "\"Delete processed files\"", "a new sender more specific",
                       "1e300", "only after you confirm them"] {
            #expect(user.contains(phrase), "\(phrase) — \(user)")
        }
        let readme = try Self.doc("README.zh-CN.md")
        let zh = try #require(readme.components(separatedBy: "\n").first { $0.contains("导入设置文件从不悄悄放宽隐私或额度") })
        for phrase in ["保留更严格的设置", "另一家 AI 服务", "处理后删除文件", "更具体的新发件人", "1e300", "给 AI 的说明"] {
            #expect(zh.contains(phrase), "\(phrase) — \(zh)")
        }
    }

    // MARK: USER_GUIDE — the confidential hold

    @Test func theUserGuideDescribesTheConfidentialHold() throws {
        let hold = try #require(Self.paragraph(try Self.doc("docs/USER_GUIDE.md"),
                                               from: "**Confidential mail is never sent to AI or merged automatically**"))
        for phrase in ["review invitations and requests", "manuscript-system emails", "emails marked confidential",
                       "aren't searched online until you allow it", "**Read with AI** starts unticked",
                       "a PDF dropped on its row isn't queued for AI",
                       "\"Possibly unpublished — confirm before AI reading\"", "identified (DOI / arXiv id)"] {
            #expect(hold.contains(phrase), "\(phrase) — \(hold)")
        }
    }

    // MARK: MAIL_DESIGN — F3 and F13

    @Test func mailDesignF3NarrowsSoftReviewRequests() throws {
        let design = try Self.doc("docs/MAIL_DESIGN.md")
        let f3 = try #require(Self.paragraph(design, from: "**Soft review requests (narrowed, portability F3):**"))
        for phrase in ["never a preprint", "reviewer or editorial context", "`isEditorialSender`", "not @acm.org / @ieee.org",
                       "**Accepted trade-off:**", "held as possibly unpublished until identified"] {
            #expect(f3.contains(phrase), "\(phrase) — \(f3)")
        }
        let summary = try #require(design.components(separatedBy: "\n").first { $0.contains("portability F3; trade-off in Part A §4") })
        #expect(summary.contains("`MailHeuristics.isReviewRequest`"))
        #expect(Self.sourcesContain("func isEditorialSender") && Self.sourcesContain("func isReviewRequest"))
    }

    @Test func mailDesignF13HoldsConfidentialMailAtMerge() throws {
        let design = try Self.doc("docs/MAIL_DESIGN.md")
        let f13 = try #require(Self.paragraph(design, from: "**Confidential mail at merge (portability F13):**"))
        for phrase in ["every confidential email", "`MailHeuristics.isConfidential`", "whoever sent it", "@*.nature.com",
                       "starts unticked", "`MailMergeOptions.suggested`", "queues no AI reading unless the user ticks it",
                       "`holdAIUnlessIdentified`"] {
            #expect(f13.contains(phrase), "\(phrase) — \(f13)")
        }
        #expect(design.contains("Confidential mail merged by hand starts with AI reading off and is held like a person's PDF when asked for (F13)."))
        #expect(Self.sourcesContain("func isConfidential") && Self.sourcesContain("static func suggested(for message: MailMessage")
                && Self.sourcesContain("holdAIUnlessIdentified"))
    }
}
