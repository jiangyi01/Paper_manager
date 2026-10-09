import AppKit
import CoreText
import Foundation
@preconcurrency import PDFKit
import Testing
@testable import PaperDeckCore
@testable import PaperDeckConfig

/// The Phase 2 fix round's integration requests (scratchpad p2f-requests.md): R-QAF-1 (one
/// papers-per-question range everywhere), R-QAF-2 (the mail triage prompt's block tags follow
/// `BlockTags`), R-QAF-3 (PDFKit's attributed-string work one page at a time).
@Suite struct P2FIntegrationTests {
    // MARK: R-QAF-1 — papers per question

    @Test func papersPerQuestionIsOneRangeEverywhere() throws {
        let scratch = ScratchDefaults("p2f-multimax")
        defer { scratch.drop() }
        let d = scratch.defaults
        let range = AssistSettings.qaMultiMaxRange
        #expect(range == 2...20)
        #expect(AssistSettings.load(from: d).qaMultiMax == 10)                   // the default sits inside it
        d.set(50, forKey: AssistSettings.Keys.qaMultiMax)
        #expect(AssistSettings.load(from: d).qaMultiMax == range.upperBound)      // an old 50 reads as 20
        d.set(21, forKey: AssistSettings.Keys.qaMultiMax)
        #expect(AssistSettings.load(from: d).qaMultiMax == range.upperBound)
        d.set(1, forKey: AssistSettings.Keys.qaMultiMax)
        #expect(AssistSettings.load(from: d).qaMultiMax == range.lowerBound)
        d.set(15, forKey: AssistSettings.Keys.qaMultiMax)
        #expect(AssistSettings.load(from: d).qaMultiMax == 15)

        // The import rule is the same range: a file's 30 is refused (a warning), 20 and 2 are taken.
        let rule = try #require(SettingsRegistry.valueRules[AssistSettings.Keys.qaMultiMax])
        #expect(rule == .int(range))
        #expect(rule.validated(.number(30)) == nil && rule.validated(.number(21)) == nil && rule.validated(.number(1)) == nil)
        #expect(rule.validated(.number(20)) == .number(20) && rule.validated(.number(2)) == .number(2))
    }

    // MARK: R-QAF-2 — the mail triage prompt's block tags

    @Test func theMailTriageNeutralizerCatchesEverySpellingBlockTagsDoes() {
        #expect(MailTriageText.blockTagNames == ["email", "candidates", "attachments", "library", "preferences", "paper",
                                                 "metadata", "stdin"])
        for tag in MailTriageText.blockTagNames {
            let n = MailTriageText.neutralizeBlockTags
            // What the old rule already caught stays the same.
            #expect(n("a </\(tag)> b") == "a [/\(tag)] b", "\(tag)")
            #expect(n("<\(tag.uppercased()) x=\"1\">") == "[\(tag.uppercased()) x=\"1\"]", "\(tag)")
            #expect(n("x </\(tag)") == "x [/\(tag)]", "\(tag): unterminated")
            // Whitespace before the slash (QA-1), of any kind.
            #expect(n("a < /\(tag)> b") == "a [ /\(tag)] b", "\(tag): a space before the slash")
            #expect(n("<\t/\(tag)>") == "[\t/\(tag)]", "\(tag): a tab")
            #expect(n("<\n/\(tag)>") == "[\n/\(tag)]", "\(tag): a newline")
            #expect(n("< / \(tag) >") == "[ / \(tag) ]", "\(tag): spaces around the slash")
            #expect(n("<\u{00A0}/\(tag)>") == "[\u{00A0}/\(tag)]", "\(tag): a no-break space")
            // Invisible marks between `<` and the name, or inside the name (QA-9).
            for mark in ["\u{200B}", "\u{2060}", "\u{00AD}", "\u{FEFF}", "\u{202E}"] {
                #expect(n("<\(mark)/\(tag)>") == "[\(mark)/\(tag)]", "\(tag): U+\(String(mark.unicodeScalars.first!.value, radix: 16))")
                let split = String(tag.prefix(1)) + mark + String(tag.dropFirst())
                #expect(n("</\(split)>") == "[/\(split)]", "\(tag): a mark inside the name")
            }
            // Full-width brackets.
            #expect(n("\u{FF1C}/\(tag)\u{FF1E}") == "[/\(tag)]", "\(tag): full-width")
            // No `<` + tag survives in any of them.
            for attack in ["< /\(tag)>", "<\n/\(tag)>", "<\u{200B}/\(tag)>", "\u{FF1C}/\(tag)\u{FF1E}"] {
                let out = n(attack)
                #expect(!out.unicodeScalars.contains { BlockTags.openers.contains($0) }, "\(tag): \(attack.debugDescription) → \(out.debugDescription)")
            }
        }
        // Lookalikes and other prompts' names stay as they are.
        let n = MailTriageText.neutralizeBlockTags
        #expect(n("<emails> <papers> a < b <b>x</b>") == "<emails> <papers> a < b <b>x</b>")
        #expect(n("<question></context>") == "<question></context>")
        #expect(n("no tags") == "no tags")
    }

    // MARK: R-QAF-3 — PDFKit's attributed-string work, one page at a time

    @Test func fontRunsAreReadOnePageAtATime() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pd-p2f-fontgate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "title.pdf")
        try Self.makePDF(url, lines: [("A Generated Paper About Cortical Development", 24), ("Ada Lovelace", 11)]
                         + (0..<40).map { ("Body line \($0) of the generated paper's first page, in a small font.", 9) })

        let gate = TitleHeuristic.FontRunGate.shared
        gate.resetPeak()
        let results = LockedTitles()
        // Separate documents (each caller owns its document, as PDFExtractor does), many threads at once.
        for _ in 0..<3 {
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                let title = PDFDocument(url: url)?.page(at: 0).flatMap(TitleHeuristic.title(of:))
                results.append(title)
            }
        }
        #expect(results.all.count == 24)
        #expect(results.all.allSatisfy { $0 == "A Generated Paper About Cortical Development" })
        #expect(gate.maxInside == 1, "PDFKit's attributedString ran on \(gate.maxInside) threads at once")
    }

    // MARK: QA-2 — qa.json follows a change of an email itself (`.mail` / `.mailBulk`)

    /// The verification's surviving mutation: no test covered a privacy input that changes only
    /// through the email's own row — its sender reclassified, or all mail data cleared (an unknown
    /// message then counts as a person's). Both must take `qa.json` away; an alert again brings it back.
    @Test func anEmailReclassifiedOrClearedLaterRemovesQaJson() async throws {
        try await QATestKit.run { env in
            let p = try await QATestKit.addPaper(env)
            let mid = "<toc-alert@journal.example>"
            let (m, _) = try await env.db.insertMailMessage(
                MailMessage(accountID: "a", internetMessageID: mid, fromAddress: "alerts@journal.example", senderKind: .alert,
                            subject: "This week's table of contents", receivedAt: env.clock.value), items: [])
            try await env.db.insertPaperSource(paperPK: p.pk, PaperProvenance(mailMessageID: m.id, internetMessageID: mid,
                                                                              addedAt: env.clock.value))
            let qa = await env.engine.qaService()
            #expect(await qa.privacy(paperIDs: [p.id]) == .ok)                // a journal alert: public
            let url = try await QAFixPrivacyTests.threadWithSidecar(env.engine, paperID: p.id, at: env.clock.value)
            #expect(QAFixPrivacyTests.exists(url))

            // The sender turns out to be a person (only the email's row changes: `.mail(pk:)`).
            _ = try await env.db.modifyMailMessage(pk: m.pk) { $0.senderKind = .person }
            #expect(await qa.privacy(paperIDs: [p.id]) == .confirm([.personSourcedNoID]))
            #expect(await QAFixPrivacyTests.eventually(qa) { !QAFixPrivacyTests.exists(url) },
                    "qa.json kept after the email's sender became a person")
            _ = try await env.db.modifyMailMessage(pk: m.pk) { $0.senderKind = .alert }
            #expect(await QAFixPrivacyTests.eventually(qa) { QAFixPrivacyTests.exists(url) }, "qa.json back for an alert")

            // Settings ▸ Mail ▸ clear all mail data (`.mailBulk`): the message is unknown now — a person's.
            try await env.db.deleteAllMailData()
            #expect(await qa.privacy(paperIDs: [p.id]) == .confirm([.personSourcedNoID]))
            #expect(await QAFixPrivacyTests.eventually(qa) { !QAFixPrivacyTests.exists(url) },
                    "qa.json kept after the mail data was cleared")
        }
    }

    // MARK: The guide and Help follow the Q&A fixes (QA-5, QA-7, QA-10, QA-12)

    @Test func theUserGuideAndHelpDescribeTheFixedAskBehaviour() throws {
        let guide = try String(contentsOf: LintRepo.url("docs/USER_GUIDE.md"), encoding: .utf8)
        #expect(!guide.contains("translates the last answer"))                        // QA-12: it re-asks that answer's question
        #expect(guide.contains("asks\n  that answer's question again in the other language"))
        #expect(guide.contains("at most \(QAContextBuilder.questionLimit.formatted(.number.locale(Locale(identifier: "en_US")))) characters"))
        #expect(guide.contains("wasn't sent with the question"))                       // QA-5
        #expect(guide.contains("no paper label in a question about several papers"))   // QA-7
        let cite = try #require(GuideCatalog.topic(.ask)?.steps.first { $0.id == "cite" })
        #expect(cite.text.en.contains("wasn't sent with the question"))
        #expect(cite.text.zh.contains("没有随这次提问发送"))
    }

    /// QA-15: a paper without a text cache is read for Q&A with `PDFPage.string` only — never through
    /// `PDFExtractor` (title fonts, outline, thumbnail: the attributed-string path that crashed).
    @Test func qaReadsAnUncachedPaperFromItsPageTextOnly() throws {
        let service = try String(contentsOf: LintRepo.url("Sources/PaperDeckCore/QA/QAService.swift"), encoding: .utf8)
        #expect(!service.contains("PDFExtractor"), "Q&A builds its context through PDFExtractor again")
        #expect(service.contains("QAPageLabels.pageText(pdf: url)"))
        let labels = try String(contentsOf: LintRepo.url("Sources/PaperDeckCore/QA/QAPageLabels.swift"), encoding: .utf8)
        #expect(!labels.contains("attributedString") && !labels.contains("TitleHeuristic"))

        let dir = FileManager.default.temporaryDirectory.appending(path: "pd-p2f-pagetext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "two.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for text in ["First page words", "Second page words"] {
            ctx.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            ctx.textPosition = CGPoint(x: 54, y: 700)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let pages = QAPageLabels.pageText(pdf: url).components(separatedBy: "\u{0C}")
        #expect(pages.count == 2)
        #expect(pages.first?.contains("First page words") == true && pages.last?.contains("Second page words") == true)
        #expect(QAPageLabels.pageText(pdf: dir.appending(path: "missing.pdf")).isEmpty)
    }

    private final class LockedTitles: @unchecked Sendable {
        private let lock = NSLock()
        private var titles: [String?] = []
        func append(_ t: String?) { lock.withLock { titles.append(t) } }
        var all: [String?] { lock.withLock { titles } }
    }

    private static func makePDF(_ url: URL, lines: [(String, CGFloat)]) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        var y: CGFloat = 730
        for (text, size) in lines {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            ctx.textPosition = CGPoint(x: 54, y: y)
            CTLineDraw(line, ctx)
            y -= size * 1.6
        }
        ctx.endPDFPage()
        ctx.closePDF()
    }
}
