import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// OCR post-processing on the synthetic line fixtures (LN §10 "OCRPostProcess"): reading order
/// across column gutters, line merging, paragraph breaks, de-hyphenation (TextPreparer's rule plus
/// the compound guard), CJK joins, ligature folding, block / word at a point, copied-text
/// normalization.
@Suite struct OCRPostProcessTests {
    static func line(_ t: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat = 24, _ c: Double = 0.95) -> OCRLine {
        OCRLine(text: t, box: CGRect(x: x, y: y, width: w, height: h), confidence: c)
    }

    @Test func twoColumnsReadLeftColumnFirstUnderASpanningTitle() throws {
        let f = try ExplainKit.fixture("two_column")
        let r = f.result
        // Title, then the left column's two paragraphs, then the right column's two.
        try #require(r.paragraphs.count == 5, "\(r.paragraphs.map(\.text))")
        #expect(r.paragraphs.map(\.column) == [-1, 0, 0, 1, 1])
        #expect(r.paragraphs[0].text == "Results of the differentiation experiment")
        #expect(r.paragraphs[1].text.hasPrefix("Cells were grown") && r.paragraphs[1].text.hasSuffix("vendor kit."))
        #expect(r.paragraphs[3].text.hasPrefix("Clustering recovered"))
        // De-hyphenation: "pre-/pared" joins; "single-/cell" keeps its hyphen (a compound);
        // "progeni-/tors" and "con-/sistent" join.
        #expect(r.paragraphs[1].text.contains("prepared with") && r.paragraphs[1].text.contains("single-cell sequencing"))
        #expect(r.paragraphs[4].text.contains("progenitors between") && r.paragraphs[4].text.contains("consistent with"))
        // The left column never interleaves with the right one.
        let leftEnd = try #require(r.text.range(of: "removed."))
        let rightStart = try #require(r.text.range(of: "Clustering"))
        #expect(leftEnd.upperBound <= rightStart.lowerBound)
        #expect(r.lines.count == 17 && r.meanConfidence > 0.6)
        #expect(OCRPostProcess.gutters(f.lines, lineHeight: 24).count == 1)
    }

    @Test func proseSplitsAtTheGapAndTheIndentAndJoinsHyphens() throws {
        let r = try ExplainKit.fixture("prose").result
        try #require(r.paragraphs.count == 2, "\(r.paragraphs.map(\.text))")
        #expect(r.paragraphs[0].text.contains("In contrast to dropout"))         // "con-/trast" joined
        #expect(r.paragraphs[0].text.hasSuffix("training on long documents."))
        #expect(r.paragraphs[1].text.hasPrefix("The second effect"))
        #expect(r.text == r.paragraphs.map(\.text).joined(separator: "\n\n"))
        #expect(OCRPostProcess.gutters(try ExplainKit.fixture("prose").lines, lineHeight: 24).isEmpty)
    }

    @Test func aShortLineEndingASentenceEndsTheParagraph() {
        let lines = [Self.line("The first paragraph runs the whole width of the column here", 0, 0, 900),
                     Self.line("and stops short.", 0, 30, 300),
                     Self.line("A second one starts flush left without any gap above it at", 0, 60, 900),
                     Self.line("all, and continues.", 0, 90, 350)]
        let r = OCRPostProcess.assemble(lines, imageSize: CGSize(width: 1000, height: 200))
        #expect(r.paragraphs.map(\.text) == ["The first paragraph runs the whole width of the column here and stops short.",
                                             "A second one starts flush left without any gap above it at all, and continues."])
    }

    @Test func fragmentsOfOneLineMergeLeftToRightAndPageNumbersDrop() {
        let lines = [Self.line("12", 480, 0, 30),                                      // a page number at the top
                     Self.line("the second half", 420, 41, 300), Self.line("First half of the line and", 0, 40, 400),
                     Self.line("the next line follows on.", 0, 72, 500), Self.line("Last line here.", 0, 104, 300)]
        let r = OCRPostProcess.assemble(lines, imageSize: CGSize(width: 800, height: 200))
        // The short line ending a sentence closes the paragraph.
        #expect(r.text == "First half of the line and the second half the next line follows on.\n\nLast line here.")
        #expect(r.lines.count == 3)
    }

    @Test func chineseLinesJoinWithoutSpacesAndMixedOnesWithOne() throws {
        let r = try ExplainKit.fixture("chinese").result
        #expect(r.paragraphs.count == 1)
        #expect(r.text.contains("少量的词元") && !r.text.contains(" "))
        #expect(OCRPostProcess.join(["注意力机制", "attention 权重"]) == "注意力机制attention 权重")
        #expect(OCRPostProcess.join(["uses the", "注意力"]) == "uses the注意力")
        #expect(OCRPostProcess.join(["first line", "second line"]) == "first line second line")
        // Hangul keeps the space (Korean separates words).
        #expect(OCRPostProcess.join(["한국어", "문장"]) == "한국어 문장")
    }

    @Test func dehyphenationFollowsTextPreparersRuleWithACompoundGuard() {
        // The rule: word char + "-" at the line end + lowercase start → joined, hyphen dropped.
        let cases: [(String, String)] = [
            ("analy-\nsis", "analysis"), ("repre-\nsentation", "representation"), ("x-\nray", "xray"),
            ("COVID-\n19", "COVID-\n19"), ("Fig-\nure", "Figure"), ("end of line -\nnext", "end of line -\nnext"),
        ]
        for (input, expected) in cases {
            #expect(OCRPostProcess.dehyphenate(input) == expected, "\(input)")
            // The same result as TextPreparer's own pass over one page (which also unwraps the lines).
            let prepared = TextPreparer.prepare(pageTexts: [input], structure: DocumentStructure(), budget: 0).text
            #expect(prepared.replacingOccurrences(of: "[[p. 1]]\n", with: "").contains(expected.components(separatedBy: "\n")[0]),
                    "\(input) → \(prepared)")
        }
        // Where TextPreparer would glue a compound, OCR keeps the hyphen.
        #expect(OCRPostProcess.dehyphenate("self-\nsupervised") == "self-supervised")
        #expect(OCRPostProcess.dehyphenate("state-of-the-\nart") == "state-of-the-art")
        #expect(OCRPostProcess.dehyphenate("high-\nthroughput assays") == "high-throughput assays")
        // Line joins: the same rule, plus capitals / digits keep the hyphen without a space, and a
        // soft hyphen always goes.
        #expect(OCRPostProcess.join(["the recog-", "nition step"]) == "the recognition step")
        #expect(OCRPostProcess.join(["the end-to-", "end model"]) == "the end-to-end model")
        #expect(OCRPostProcess.join(["SARS-CoV-", "2 infection"]) == "SARS-CoV-2 infection")
        #expect(OCRPostProcess.join(["Pre-", "Training"]) == "Pre-Training")
        #expect(OCRPostProcess.join(["self\u{00AD}", "supervised"]) == "selfsupervised")
        #expect(OCRPostProcess.join(["a dash -", "and more"]) == "a dash - and more")
    }

    @Test func ligaturesFoldButSuperscriptsAndCJKPunctuationStay() {
        #expect(OCRPostProcess.foldLigatures("\u{FB01}ne \u{FB02}ow e\u{FB00}ect o\u{FB03}ce ba\u{FB04}e") == "fine flow effect office baffle")
        #expect(OCRPostProcess.foldLigatures("ＡＢＣ１２３") == "ABC123")
        #expect(OCRPostProcess.foldLigatures("x² + y₁，注意。") == "x² + y₁，注意。")
        #expect(OCRPostProcess.cleanLine("  a\u{200B}b\t\tc\u{00A0} d  ") == "ab c d")
    }

    @Test func blockAtAPointPicksTheParagraphUnderOrNearIt() throws {
        let r = try ExplainKit.fixture("two_column").result
        try #require(r.paragraphs.count == 5)
        // Inside the right column's second paragraph.
        let right2 = try #require(OCRPostProcess.block(at: CGPoint(x: 800, y: 290), in: r))
        #expect(right2.text.hasPrefix("Trajectory analysis"))
        // In the gutter, level with the left column's first paragraph: the nearest (within 1.5 h).
        let gutter = try #require(OCRPostProcess.block(at: CGPoint(x: 590, y: 100), in: r))
        #expect(gutter.column == 0 || gutter.column == 1)
        // Far below everything: nothing.
        #expect(OCRPostProcess.block(at: CGPoint(x: 600, y: 395), in: r) == nil)
        #expect(OCRPostProcess.block(at: .zero, in: .empty) == nil)
        // The fixture's blocks sit inside the capture; one touching the edge is cut off.
        #expect(!OCRPostProcess.isCutOff(right2, imageSize: CGSize(width: 1200, height: 400)))
        #expect(OCRPostProcess.isCutOff(right2, imageSize: CGSize(width: 1181, height: 400)))
        var top = right2
        top.box.origin.y = 1
        #expect(OCRPostProcess.isCutOff(top, imageSize: CGSize(width: 1200, height: 400)))
    }

    @Test func wordAtAPointUsesWordBoxesOrSplitsTheLine() {
        let plain = OCRResult(lines: [Self.line("We regularize the attention weights.", 0, 0, 360)],
                              paragraphs: [OCRParagraph(text: "We regularize the attention weights.", box: CGRect(x: 0, y: 0, width: 360, height: 24), lineIndices: [0])],
                              text: "We regularize the attention weights.", meanConfidence: 0.9)
        #expect(OCRPostProcess.word(at: CGPoint(x: 200, y: 12), in: plain) == "attention")
        #expect(OCRPostProcess.word(at: CGPoint(x: 355, y: 12), in: plain) == "weights")      // the period is trimmed
        #expect(OCRPostProcess.word(at: CGPoint(x: 200, y: 200), in: plain) == nil)
        var boxed = plain
        boxed.lines[0].words = [OCRWord(text: "We", box: CGRect(x: 0, y: 0, width: 30, height: 24)),
                                OCRWord(text: "regularize", box: CGRect(x: 40, y: 0, width: 110, height: 24))]
        #expect(OCRPostProcess.word(at: CGPoint(x: 90, y: 10), in: boxed) == "regularize")
        let cjk = OCRResult(lines: [Self.line("注意力机制很重要", 0, 0, 320)], paragraphs: [], text: "注意力机制很重要", meanConfidence: 0.9)
        let term = OCRPostProcess.word(at: CGPoint(x: 60, y: 10), in: cjk)
        #expect(term.map { "注意力机制很重要".contains($0) && $0.count >= 2 } == true)
    }

    @Test func copiedTextIsUnwrappedDehyphenatedAndKeepsParagraphs() {
        let raw = "We regu-\r\nlarize the at\u{FB01}tention\nweights.\n\n\nA second   paragraph\u{2028}continues.\n"
        #expect(OCRPostProcess.normalizeCopied(raw) == "We regularize the atfitention weights.\n\nA second paragraph continues.")
        #expect(OCRPostProcess.normalizeCopied("第一行\n第二行") == "第一行第二行")
        #expect(OCRPostProcess.normalizeCopied("  \n \n") == "")
        // A soft hyphen at a copied line's end joins the word; inside a line it disappears.
        #expect(OCRPostProcess.normalizeCopied("self\u{00AD}\nsupervised learn\u{00AD}ing") == "selfsupervised learning")
    }

    @Test func documentParagraphsKeepVisionsOrder() {
        let p1 = [Self.line("Right column first?", 600, 0, 300)]
        let p2 = [Self.line("Left column", 0, 0, 300), Self.line("contin-", 0, 30, 300), Self.line("ues here.", 0, 60, 300)]
        let r = OCRPostProcess.assemble(paragraphs: [p2, p1, []])
        #expect(r.paragraphs.map(\.text) == ["Left column continues here.", "Right column first?"])
        #expect(r.lines.count == 4 && r.paragraphs[1].lineIndices == [3])
        #expect(OCRPostProcess.assemble(paragraphs: []) == .empty)
        #expect(OCRPostProcess.assemble([], imageSize: .zero) == .empty)
    }
}
