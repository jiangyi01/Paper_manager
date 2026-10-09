import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// CUX-4: what a click explains ignores tiny or unreadable OCR blocks next to it — a panel letter, an
/// axis tick, a legend entry is part of a figure — prefers the block the click is in, and falls back to
/// the figure the overlay found (the focus' fallback), never to a 42 × 50 px picture of one letter.
@Suite struct FocusNoiseTests {
    static let size = CGSize(width: 1400, height: 720)
    /// The figure the overlay found around the click (unit rect of the band).
    static let fallback = CGRect(x: 0.30, y: 0.20, width: 0.40, height: 0.60)

    static func focus(_ x: CGFloat, _ y: CGFloat, term: Bool = false) -> ExplainFocus {
        ExplainFocus(unit: CGPoint(x: x / size.width, y: y / size.height), term: term, fallback: fallback)
    }

    static func block(_ text: String, _ box: CGRect, confidence: Double = 0.8, words: [OCRWord] = []) -> [OCRLine] {
        [OCRLine(text: text, box: box, confidence: confidence, words: words)]
    }

    /// Probe P10's layout: a chart with a panel letter "a" at its corner, ticks, a legend entry, and a
    /// real paragraph further away.
    static func figureWithLabels() -> OCRResult {
        OCRPostProcess.assemble(paragraphs: [
            block("a", CGRect(x: 430, y: 150, width: 20, height: 28)),
            block("0", CGRect(x: 440, y: 560, width: 14, height: 24)),
            block("10", CGRect(x: 440, y: 400, width: 26, height: 24)),
            block("Control", CGRect(x: 820, y: 170, width: 90, height: 24)),
            block("Regrowth accelerates once the blastema forms, as the curve shows.", CGRect(x: 40, y: 640, width: 1200, height: 30)),
        ])
    }

    @Test func aClickBesideAPanelLetterExplainsTheFigureNotTheLetter() throws {
        let ocr = Self.figureWithLabels()
        // Probe P10: 14 px right of "a" (inside the chart).
        let hit = ExplainFocusResolver.resolve(ocr, imageSize: Self.size, focus: Self.focus(464, 165))
        #expect(hit.selection == nil, "\(hit)")
        #expect(hit.crop == Self.focus(464, 165).fallbackPixels(in: Self.size))
        let crop = try #require(hit.crop)
        #expect(crop.width > 400 && crop.height > 300, "the figure, not 42 × 50 px: \(crop)")
        // Next to a tick and next to a legend entry: the figure as well.
        #expect(ExplainFocusResolver.resolve(ocr, imageSize: Self.size, focus: Self.focus(475, 410)).selection == nil)
        #expect(ExplainFocusResolver.resolve(ocr, imageSize: Self.size, focus: Self.focus(800, 180)).selection == nil)
        // Right on the panel letter or the legend entry (a plain click): still the figure.
        #expect(ExplainFocusResolver.resolve(ocr, imageSize: Self.size, focus: Self.focus(440, 160)).selection == nil)
        #expect(ExplainFocusResolver.resolve(ocr, imageSize: Self.size, focus: Self.focus(850, 180)).selection == nil)
    }

    @Test func aShiftClickOnALabelStillTakesItsTerm() {
        let ocr = Self.figureWithLabels()
        let term = ExplainFocusResolver.resolve(ocr, imageSize: Self.size, focus: Self.focus(850, 180, term: true))
        #expect(term.selection == "Control", "\(term)")
        // A one-character label has no term.
        #expect(ExplainFocusResolver.resolve(ocr, imageSize: Self.size, focus: Self.focus(440, 160, term: true)).selection == nil)
    }

    @Test func realTextNearTheClickIsStillExplained() throws {
        let ocr = Self.figureWithLabels()
        // Just above the caption-like paragraph (within 1.5 lines): that paragraph.
        let near = ExplainFocusResolver.resolve(ocr, imageSize: Self.size, focus: Self.focus(300, 625))
        #expect(near.selection?.hasPrefix("Regrowth accelerates") == true, "\(near)")
        #expect(near.crop != Self.focus(300, 625).fallbackPixels(in: Self.size))
    }

    @Test func theBlockTheClickIsInWinsOverANearerEdge() throws {
        let ocr = OCRPostProcess.assemble(paragraphs: [
            Self.block("The first paragraph sits right above the second one here.", CGRect(x: 40, y: 100, width: 1200, height: 30)),
            Self.block("The second paragraph is the one the user clicked inside.", CGRect(x: 40, y: 134, width: 1200, height: 30)),
        ])
        // Inside the second block, 4 px from the first one's bottom edge.
        let hit = ExplainFocusResolver.resolve(ocr, imageSize: Self.size, focus: Self.focus(300, 136))
        #expect(hit.selection?.hasPrefix("The second paragraph") == true, "\(hit)")
    }

    @Test func unreadableTextIsNotExplainedAsText() {
        let ocr = OCRPostProcess.assemble(paragraphs: [
            Self.block("Ilil lIil 1lIl il1I lIl1 Il1l", CGRect(x: 40, y: 300, width: 1200, height: 30), confidence: 0.1),
        ])
        let hit = ExplainFocusResolver.resolve(ocr, imageSize: Self.size, focus: Self.focus(300, 310))
        #expect(hit.selection == nil && hit.crop == Self.focus(300, 310).fallbackPixels(in: Self.size))
    }

    @Test func theNoiseRuleUsesTheClassifiersBounds() {
        #expect(ExplainFocusResolver.minCharacters == RegionClassifier.Thresholds.default.minCharacters)
        #expect(ExplainFocusResolver.minConfidence == RegionClassifier.Thresholds.default.minConfidence)
        let ocr = Self.figureWithLabels()
        #expect(ocr.paragraphs.filter { ExplainFocusResolver.isText($0, in: ocr) }.count == 1)
    }
}
