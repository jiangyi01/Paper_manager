import Foundation
import Testing
@testable import PaperDeckCore

/// The located paper's context (LN §5, dive-cli §7): metadata, the nearest section, the abstract
/// (≤ 600), ±1,200 characters around the capture, the page's caption, the paper's vocabulary for
/// OCR, and the privacy inputs with the mail-window rule.
@Suite(.serialized) struct PaperContextBuilderTests {
    static func longPage(_ marker: String) -> String {
        let before = (0..<40).map { "Filler sentence number \($0) about unrelated background material." }.joined(separator: "\n")
        let after = (0..<40).map { "Trailing sentence number \($0) continues the discussion at length." }.joined(separator: "\n")
        return "2 Results\n" + before + "\n" + marker + "\n" + after
    }

    @Test func aMatchedCaptureGetsMetadataSectionAbstractAndNearbyText() async throws {
        let (engine, root) = try await ExplainKit.engine()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "The penalty keeps each attention head focused on a small set of tokens across all layers."
        let p = try await ExplainKit.paper(engine, title: "Attention-guided regularization",
                                           pages: ["Abstract\nWe study attention.\n1 Introduction\nIntro text here.", Self.longPage(marker)],
                                           authors: ["Ada Lovelace", "Grace Hopper", "Alan Turing", "Emmy Noether"], year: 2026,
                                           venue: "Synthetic Letters", abstract: String(repeating: "Abstract words go on. ", count: 60))
        let c = await engine.explainContext(for: PaperMatch(paperID: p.id, confidence: 0.9, via: .text), around: marker)
        #expect(c.isMatched && c.paperID == p.id && c.page == 2 && c.via == .text)
        #expect(c.title == "Attention-guided regularization" && c.authors == ["Ada Lovelace", "Grace Hopper", "Alan Turing"] && c.moreAuthors)
        #expect(c.year == 2026 && c.venue == "Synthetic Letters")
        #expect(c.metaLine == "Attention-guided regularization · Ada Lovelace, Grace Hopper, Alan Turing et al. · Synthetic Letters · 2026")
        let abstract = try #require(c.abstract)
        #expect(abstract.count <= PaperContextBuilder.Caps.abstract && abstract.hasSuffix("…"))
        #expect(c.section == "2 Results")
        let nearby = try #require(c.nearby)
        #expect(nearby.contains(marker))
        #expect(nearby.hasPrefix("… ") && nearby.hasSuffix(" …"))                  // cut on both sides
        #expect(nearby.count <= marker.count + 2 * PaperContextBuilder.Caps.nearbyEachSide + 8)
        #expect(nearby.count >= 2 * PaperContextBuilder.Caps.nearbyEachSide - 200)
        #expect(!nearby.contains("\n"))                                             // lines unwrapped
        #expect(c.customWords.contains("Attention-guided") && c.customWords.contains("regularization")
                && c.customWords.contains("Lovelace"))
        #expect(c.privacy(hostBundleID: "com.apple.Preview", windowTitle: "paper.pdf") == .ok && !c.privacyUnchecked)
        await engine.shutdown()
    }

    @Test func onlyThePageKnownGivesThePagesStartAndNoMatchGivesNothing() async throws {
        let (engine, root) = try await ExplainKit.engine()
        defer { try? FileManager.default.removeItem(at: root) }
        let p = try await ExplainKit.paper(engine, title: "Paged", pages: ["First page.", "Second page begins here.\nAnd goes on."])
        let c = await engine.explainContext(for: PaperMatch(paperID: p.id, page: 2, confidence: 0.95, via: .fileName), around: nil)
        #expect(c.page == 2 && c.nearby == "Second page begins here. And goes on.")
        // A page beyond the text: no nearby text, but the metadata stays.
        let beyond = await engine.explainContext(for: PaperMatch(paperID: p.id, page: 9, confidence: 0.9, via: .fileName), around: nil)
        #expect(beyond.nearby == nil && beyond.title == "Paged")
        #expect(await engine.explainContext(for: nil, around: "x") == .unmatched)
        #expect(await engine.explainContext(for: PaperMatch(paperID: "gone", confidence: 1, via: .user), around: nil) == .unmatched)
        #expect(ExplainContext.unmatched.metaLine == nil && !ExplainContext.unmatched.isMatched)
        await engine.shutdown()
    }

    @Test func theCaptureIsFoundAgainEvenWhenTheMatchHadNoPage() async throws {
        let (engine, root) = try await ExplainKit.engine()
        defer { try? FileManager.default.removeItem(at: root) }
        let pages = try ExplainKit.layoutPages("nature_layout")
        let p = try await ExplainKit.paper(engine, title: "Synthetic dynamics of the developing test cortex", pages: pages)
        let excerpt = "Tri-IPCs generate interneurons, oligodendrocytes and astrocytes (Fig. 5d). Benchmark comparisons with "
            + "published atlases confirmed the annotations"
        let c = await engine.explainContext(for: PaperMatch(paperID: p.id, confidence: 0.95, via: .windowTitle), around: ExplainKit.perturb(excerpt))
        #expect(c.page == 2 && c.nearby?.contains("Tri-IPCs generate interneurons") == true)
        // The page's caption: the one the capture names.
        let fig = await engine.explainContext(for: PaperMatch(paperID: p.id, page: 2, confidence: 0.9, via: .text),
                                              around: "a, Sampling scheme. b, UMAP of cell types as shown in Fig. 1")
        #expect(fig.figureCaption?.hasPrefix("Fig. 1 | A multi-omic survey") == true, "\(String(describing: fig.figureCaption))")
        #expect((fig.figureCaption?.count ?? 0) <= PaperContextBuilder.Caps.caption)
        await engine.shutdown()
    }

    @Test func privacyInputsAndTheMailWindowRule() async throws {
        let (engine, root) = try await ExplainKit.engine()
        defer { try? FileManager.default.removeItem(at: root) }
        let held = try await ExplainKit.paper(engine, title: "A manuscript from a colleague", aiNote: ImportAnnotation.unpublishedHoldNote)
        let c = await engine.explainContext(for: PaperMatch(paperID: held.id, confidence: 1, via: .reader), around: nil)
        #expect(c.aiNote == ImportAnnotation.unpublishedHoldNote)
        #expect(c.privacy(hostBundleID: nil, windowTitle: nil) == .confirm([.mailUnpublished]))
        #expect(c.privacy(hostBundleID: "com.apple.mail", windowTitle: "Re: draft") == .confirm([.mailUnpublished, .messagingHost]))
        let never = try await ExplainKit.paper(engine, title: "Never send this")
        try await engine.setPaperPolicy(paperID: never.id, confidential: true, neverAI: true)
        let n = await engine.explainContext(for: PaperMatch(paperID: never.id, confidence: 1, via: .reader), around: nil)
        #expect(n.privacy(hostBundleID: "com.google.Chrome", windowTitle: "Inbox (3) - me@example.org - Gmail") == .blocked)
        let conf = try await ExplainKit.paper(engine, title: "Confidential review copy")
        try await engine.setPaperPolicy(paperID: conf.id, confidential: true, neverAI: false)
        let k = await engine.explainContext(for: PaperMatch(paperID: conf.id, confidence: 1, via: .reader), around: nil)
        #expect(k.privacy(hostBundleID: nil, windowTitle: nil) == .confirm([.markedConfidential]))
        // Unmatched captures: only the window decides.
        let u = ExplainContext.unmatched
        #expect(u.privacy(hostBundleID: "com.google.Chrome", windowTitle: "paper.pdf - Google Chrome") == .ok)
        #expect(u.privacy(hostBundleID: "com.google.Chrome", windowTitle: "Inbox (3) - me@example.org - Gmail") == .confirm([.messagingHost]))
        #expect(u.privacy(hostBundleID: "com.tinyspeck.slackmacgap", windowTitle: nil) == .confirm([.messagingHost]))
        await engine.shutdown()
    }

    @Test(arguments: [
        ("com.google.Chrome", "Inbox (12) - jane@example.org - Gmail", true),
        ("com.apple.Safari", "Mail - Jane Doe - Outlook", true),
        ("org.mozilla.firefox", "Inbox – Proton Mail", true),
        ("com.microsoft.edgemac", "(2) Slack | general | Lab", true),
        ("com.google.Chrome", "jane.doe@example.org", true),
        ("com.google.Chrome", "收件箱 - QQ邮箱", true),
        ("com.google.Chrome", "Global outlook for tropical forests - Google Chrome", false),
        ("com.google.Chrome", "2406.12345v2.pdf", false),
        ("com.apple.Preview", "Inbox - Gmail", false),                 // not a browser: a PDF named so
        ("com.apple.mail", "Anything", true),
        ("com.microsoft.Outlook", nil, true),
        (nil, "Inbox - Gmail", true),
        (nil, nil, false),
    ] as [(String?, String?, Bool)])
    func mailWindows(_ bundle: String?, _ title: String?, _ expected: Bool) {
        #expect(MailWindow.isMessaging(bundleID: bundle, windowTitle: title) == expected, "\(String(describing: bundle)) \(String(describing: title))")
    }

    @Test func clipNeverSplitsACharacter() {
        let accent = String(repeating: "e\u{0301}", count: 50)                         // 50 graphemes, 100 scalars
        let cut = PaperContextBuilder.clip(accent, 10)
        #expect(cut.count == 10 && cut.hasSuffix("…") && cut.unicodeScalars.dropLast().last == "\u{0301}")
        let family = String(repeating: "👨‍👩‍👧", count: 20)
        let f = PaperContextBuilder.clip(family, 5)
        #expect(f == String(repeating: "👨‍👩‍👧", count: 4) + "…")
        #expect(PaperContextBuilder.clip("short", 10) == "short" && PaperContextBuilder.clip("x", 0) == "")
        #expect(PaperContextBuilder.clip("one two three four five six", 12) == "one two…")
    }
}
