import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// The frame / lens layer's rules (phase-3 integration): what a mouse release means, the lens'
/// zoom and magnified source, the box's size label, and what a click explains (`ExplainFocus` →
/// `ExplainFocusResolver`: the paragraph, or ⇧ the term, under the click — nothing under it sends
/// the band as a figure). Pure, plus one Vision pass on a synthetic in-memory page (no screen).
@Suite struct CaptureLayerRulesTests {
    static let display = CGSize(width: 1440, height: 900)

    // MARK: Release

    @Test func aDragIsABoxClampedToTheDisplay() {
        let box = CaptureGesture.release(from: CGPoint(x: 100, y: 120), to: CGPoint(x: 400, y: 300), option: false, shift: false,
                                         displaySize: Self.display)
        #expect(box == .box(CGRect(x: 100, y: 120, width: 300, height: 180), figure: false))
        // Dragged up-left: the same box.
        let back = CaptureGesture.release(from: CGPoint(x: 400, y: 300), to: CGPoint(x: 100, y: 120), option: true, shift: false,
                                          displaySize: Self.display)
        #expect(back == .box(CGRect(x: 100, y: 120, width: 300, height: 180), figure: true))
        // Past the display's edge: clamped (a drag never spans displays).
        let edge = CaptureGesture.release(from: CGPoint(x: 1300, y: 800), to: CGPoint(x: 1700, y: 1100), option: false, shift: false,
                                          displaySize: Self.display)
        #expect(edge == .box(CGRect(x: 1300, y: 800, width: 140, height: 100), figure: false))
    }

    @Test func aTinyDragIsAClickAtTheRelease() {
        // Both sides under `clickSide` (8 pt), or only one: a click, not a sliver of a box.
        let click = CaptureGesture.release(from: CGPoint(x: 500, y: 400), to: CGPoint(x: 503, y: 402), option: false, shift: false,
                                           displaySize: Self.display)
        #expect(click == .point(CGPoint(x: 503, y: 402), term: false, figure: false))
        let sliver = CaptureGesture.release(from: CGPoint(x: 500, y: 400), to: CGPoint(x: 700, y: 405), option: false, shift: false,
                                            displaySize: Self.display)
        #expect(sliver == .point(CGPoint(x: 700, y: 405), term: false, figure: false))
        // Exactly the click side on both: a box.
        let smallest = CaptureGesture.release(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 18, y: 18), option: false, shift: false,
                                              displaySize: Self.display)
        #expect(smallest == .box(CGRect(x: 10, y: 10, width: 8, height: 8), figure: false))
        // ⇧: the term; ⌥: a figure (⌥ wins over ⇧: the image goes, not one word).
        #expect(CaptureGesture.release(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5), option: false, shift: true,
                                       displaySize: Self.display) == .point(CGPoint(x: 5, y: 5), term: true, figure: false))
        #expect(CaptureGesture.release(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5), option: true, shift: true,
                                       displaySize: Self.display) == .point(CGPoint(x: 5, y: 5), term: false, figure: true))
        // A release just outside the display clicks its edge.
        #expect(CaptureGesture.release(from: CGPoint(x: 1439, y: 10), to: CGPoint(x: 1443, y: 12), option: false, shift: false,
                                       displaySize: Self.display) == .point(CGPoint(x: 1440, y: 12), term: false, figure: false))
    }

    // MARK: Lens

    @Test func theZoomStaysInRangeAndScrollsBothWays() {
        #expect(CaptureGesture.defaultZoom == 2 && CaptureGesture.zoomRange == 1.5...6)
        let up = CaptureGesture.zoom(2, scrolledBy: 1)
        #expect(up > 2 && abs(up - 2 * CaptureGesture.zoomStep) < 1e-9)
        #expect(CaptureGesture.zoom(2, scrolledBy: -1) < 2)
        #expect(CaptureGesture.zoom(5.9, scrolledBy: 3) == 6)
        #expect(CaptureGesture.zoom(1.6, scrolledBy: -3) == 1.5)
        // A huge trackpad delta moves at most four notches; nonsense keeps the zoom sane.
        #expect(CaptureGesture.zoom(2, scrolledBy: 500) == CaptureGesture.clampZoom(2 * pow(CaptureGesture.zoomStep, 4)))
        #expect(CaptureGesture.zoom(2, scrolledBy: .nan) == 2)
        #expect(CaptureGesture.clampZoom(.infinity) == CaptureGesture.defaultZoom)
        #expect(CaptureGesture.zoom(3, scrolledBy: 0) == 3)
    }

    @Test func theLensMagnifiesTheSquareAroundTheCursor() {
        let d = CaptureGesture.lensDiameter
        let src = CaptureGesture.lensSource(at: CGPoint(x: 300, y: 200), zoom: 2)
        #expect(src == CGRect(x: 300 - d / 4, y: 200 - d / 4, width: d / 2, height: d / 2))
        // The magnified still is shifted so the cursor's point lands in the lens' centre.
        for (cursor, zoom) in [(CGPoint(x: 300, y: 200), 2.0), (CGPoint(x: 0, y: 0), 4.0), (CGPoint(x: 1439, y: 899), 1.5)] {
            let off = CaptureGesture.lensOffset(at: cursor, zoom: zoom)
            #expect(abs(cursor.x * zoom + off.width - d / 2) < 1e-9 && abs(cursor.y * zoom + off.height - d / 2) < 1e-9)
        }
        // Out-of-range zooms are clamped the same way in both.
        #expect(CaptureGesture.lensSource(at: .zero, zoom: 100).width == d / 6)
    }

    @Test func theBoxLabelReadsItsSizeAndStaysOnTheDisplay() {
        #expect(CaptureGesture.sizeLabel(CGRect(x: 0, y: 0, width: 612.4, height: 239.6)) == "612 × 240")
        let label = CGSize(width: 80, height: 20)
        // Under the bottom-right corner.
        #expect(CaptureGesture.labelOrigin(for: CGRect(x: 100, y: 100, width: 300, height: 200), label: label,
                                           displaySize: Self.display) == CGPoint(x: 320, y: 306))
        // At the bottom edge: inside the box instead.
        #expect(CaptureGesture.labelOrigin(for: CGRect(x: 100, y: 700, width: 300, height: 200), label: label,
                                           displaySize: Self.display) == CGPoint(x: 320, y: 874))
        // A box at the left edge narrower than its label: the label stays on the display.
        #expect(CaptureGesture.labelOrigin(for: CGRect(x: 0, y: 10, width: 20, height: 20), label: label,
                                           displaySize: Self.display).x == 0)
    }

    // MARK: Focus

    @Test func theClickIsAFractionOfTheBandSoScalingKeepsIt() throws {
        let band = CGRect(x: 100, y: 50, width: 700, height: 360)
        let f = try #require(ExplainFocus(local: CGPoint(x: 450, y: 230), in: band, term: true))
        #expect(f.unit == CGPoint(x: 0.5, y: 0.5) && f.term)
        #expect(f.pixel(in: CGSize(width: 1400, height: 720)) == CGPoint(x: 700, y: 360))
        #expect(f.pixel(in: CGSize(width: 700, height: 360)) == CGPoint(x: 350, y: 180))
        // Outside the band: clamped to its edge; an empty band has no click.
        #expect(ExplainFocus(local: CGPoint(x: 0, y: 1_000), in: band)?.unit == CGPoint(x: 0, y: 1))
        #expect(ExplainFocus(local: .zero, in: .zero) == nil)
        // With a band from `CaptureGeometry.band`, the click is the band's own point.
        let local = CGPoint(x: 20, y: 880)
        let edgeBand = CaptureGeometry.band(around: local, displaySize: Self.display)
        let g = try #require(ExplainFocus(local: local, in: edgeBand))
        #expect(abs(g.unit.x * edgeBand.width + edgeBand.minX - local.x) < 1e-9)
        #expect(abs(g.unit.y * edgeBand.height + edgeBand.minY - local.y) < 1e-9)
    }

    /// A click at pixel (x, y) of the 1400 × 720 px band (as the unit fraction the overlay records).
    static func at(_ x: CGFloat, _ y: CGFloat, term: Bool = false) -> ExplainFocus {
        ExplainFocus(unit: CGPoint(x: x / 1400, y: y / 720), term: term)
    }

    /// Two paragraphs in a 1400 × 720 px band (lines 30 px tall).
    static func twoParagraphs() -> OCRResult {
        func line(_ text: String, y: CGFloat, words: [String] = []) -> OCRLine {
            var x: CGFloat = 40
            let ws = words.map { w -> OCRWord in
                let width = CGFloat(w.count) * 16
                defer { x += width + 12 }
                return OCRWord(text: w, box: CGRect(x: x, y: y, width: width, height: 30))
            }
            return OCRLine(text: text, box: CGRect(x: 40, y: y, width: 1200, height: 30), confidence: 0.6, words: ws)
        }
        return OCRPostProcess.assemble(paragraphs: [
            [line("We regularize the attention weights by", y: 100), line("penalizing their entropy.", y: 140)],
            [line("The temperature tau controls how sharp", y: 300, words: ["The", "temperature", "tau", "controls", "how", "sharp"]),
             line("the softmax becomes.", y: 340, words: ["the", "softmax", "becomes."])],
        ])
    }

    @Test func aClickKeepsOnlyItsParagraphAndCropsToIt() throws {
        let ocr = Self.twoParagraphs()
        let size = CGSize(width: 1400, height: 720)
        // On the second paragraph's first line.
        let hit = ExplainFocusResolver.resolve(ocr, imageSize: size, focus: Self.at(300, 315))
        let text = try #require(hit.selection)
        #expect(text.contains("temperature tau") && text.contains("softmax") && !text.contains("entropy"), "\(text)")
        #expect(hit.paragraph == text)
        // The crop: the paragraph's box grown by 0.6 line heights (30 px → 18 px), on whole pixels.
        let crop = try #require(hit.crop)
        #expect(crop == CGRect(x: 22, y: 282, width: 1236, height: 106), "\(crop)")
        // Its own OCR, in the crop's pixels (the classifier reads it).
        let block = try #require(hit.block)
        #expect(block.lines.count == 2 && block.paragraphs.count == 1 && block.text == text)
        #expect(block.lines[0].box.minX == 18 && block.lines[0].box.minY == 18)
        #expect(block.lines[0].words.first?.box.origin == CGPoint(x: 18, y: 18))
        #expect(RegionClassifier.classify(block, imageSize: crop.size) == .text)
    }

    @Test func aShiftClickTakesTheTermUnderIt() throws {
        let ocr = Self.twoParagraphs()
        let size = CGSize(width: 1400, height: 720)
        // "temperature" spans x 100…276 on the line at y 300.
        let term = ExplainFocusResolver.resolve(ocr, imageSize: size,
                                                focus: Self.at(150, 312, term: true))
        #expect(term.selection == "temperature")
        #expect(term.paragraph?.contains("controls how sharp") == true)
        #expect(term.crop != nil)
        // A term click on a line without word boxes splits the line evenly (OCRPostProcess.word).
        let plain = ExplainFocusResolver.resolve(ocr, imageSize: size,
                                                 focus: Self.at(60, 112, term: true))
        #expect(plain.selection == "We")
    }

    @Test func aClickOnNothingSendsTheBandAsAFigure() {
        let ocr = Self.twoParagraphs()
        let size = CGSize(width: 1400, height: 720)
        // Far below both paragraphs (more than 1.5 line heights away): nothing.
        let none = ExplainFocusResolver.resolve(ocr, imageSize: size, focus: ExplainFocus(unit: CGPoint(x: 0.5, y: 0.95)))
        #expect(none == .none)
        #expect(ExplainFocusResolver.resolve(.empty, imageSize: size, focus: ExplainFocus(unit: CGPoint(x: 0.5, y: 0.5))) == .none)
        // Close below a paragraph (within 1.5 lines): that paragraph.
        let near = ExplainFocusResolver.resolve(ocr, imageSize: size, focus: Self.at(420, 400))
        #expect(near.selection?.contains("softmax") == true)
    }

    @Test func aParagraphAtTheBandsEdgeIsCroppedInsideIt() throws {
        let line = OCRLine(text: "Edge text right at the top of the band.", box: CGRect(x: 0, y: 0, width: 600, height: 30),
                           confidence: 0.6)
        let ocr = OCRPostProcess.assemble(paragraphs: [[line]])
        let hit = ExplainFocusResolver.resolve(ocr, imageSize: CGSize(width: 700, height: 360), focus: ExplainFocus(unit: CGPoint(x: 0.1, y: 0.02)))
        let crop = try #require(hit.crop)
        #expect(crop.minX == 0 && crop.minY == 0 && crop.maxX == 618 && crop.maxY == 48)
        #expect(hit.block?.lines.first?.box.origin == .zero)
    }

    /// End to end on a synthetic page (Vision, in memory): a click on the second paragraph explains
    /// that paragraph only.
    @Test func visionReadsOnlyTheClickedParagraph() async throws {
        let image = try #require(ExplainKit.render(
            ["We regularize the attention weights by penalizing", "their entropy across heads.", "", "",
             "The temperature parameter controls how sharp", "the softmax distribution becomes."],
            width: 1000, height: 340))
        let size = CGSize(width: image.width, height: image.height)
        let ocr = try await OCREngine.recognize(image, languages: OCREngine.defaultLanguages, customWords: [])
        let second = try #require(ocr.lines.first { $0.text.lowercased().contains("temperature") })
        let unit = CGPoint(x: second.box.midX / size.width, y: second.box.midY / size.height)
        let hit = ExplainFocusResolver.resolve(ocr, imageSize: size, focus: ExplainFocus(unit: unit))
        let text = try #require(hit.selection).lowercased()
        #expect(text.contains("temperature") && !text.contains("entropy"), "\(text) — \(ocr.paragraphs.map(\.text))")
        let crop = try #require(hit.crop)
        #expect(crop.minY > 0 && crop.contains(CGPoint(x: second.box.midX, y: second.box.midY)))
        let word = ExplainFocusResolver.resolve(ocr, imageSize: size, focus: ExplainFocus(unit: unit, term: true)).selection
        #expect(word.map { !$0.contains(" ") && !$0.isEmpty } == true, "\(word ?? "nil")")
    }
}
