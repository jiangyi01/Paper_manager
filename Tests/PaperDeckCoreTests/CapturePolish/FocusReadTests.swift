import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// CUX-8 (capture polish): a click's paragraph that runs past the band is read once more from the
/// larger area the capture holds (`ExplainFocusResolver.read`, `OCRPostProcess.isCutOff`) — only when
/// it does, only once, never past the capture (the window under the click).
@Suite struct FocusReadTests {
    /// The capture: the read area of a click, 1400 × 720 pt at 2× (2800 × 1440 px); the band is its
    /// middle 700 × 360 pt (700…2100 × 360…1080 px).
    static let size = CGSize(width: 2800, height: 1440)
    static let bandUnit = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    static let bandPx = CGRect(x: 700, y: 360, width: 1400, height: 720)
    static let whole = CGRect(origin: .zero, size: size)
    static let fallbackUnit = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)

    static func focus(_ click: CGPoint, term: Bool = false, band: CGRect? = bandUnit, size: CGSize = size) -> ExplainFocus {
        ExplainFocus(unit: CGPoint(x: click.x / size.width, y: click.y / size.height), term: term, fallback: fallbackUnit, band: band)
    }

    static func read(_ ocr: PolishKit.FakeOCR, _ focus: ExplainFocus, size: CGSize = size) async -> ExplainFocusResolver.Result {
        await ExplainFocusResolver.read(focus, imageSize: size) { ocr.read($0) }
    }

    @Test func aParagraphInsideTheBandIsReadOnce() async throws {
        let ocr = PolishKit.FakeOCR(PolishKit.paragraph(1, origin: CGPoint(x: 900, y: 450), width: 1000, count: 6))
        let hit = await Self.read(ocr, Self.focus(CGPoint(x: 1400, y: 520)))
        #expect(ocr.calls == [Self.bandPx], "only the band is read")
        let text = try #require(hit.paragraph)
        #expect(text.contains("p1 line 0") && text.contains("p1 line 5"))
        let crop = try #require(hit.crop)
        #expect(Self.bandPx.contains(crop), "\(crop)")
    }

    @Test func aParagraphRunningPastTheBandIsReadOnceMoreWhole() async throws {
        // 20 lines from y 600 to 1270: the band ends at 1080, in the gap after line 13 (line 14 is cut away).
        let ocr = PolishKit.FakeOCR(PolishKit.paragraph(1, origin: CGPoint(x: 900, y: 600), width: 1000, count: 20))
        let hit = await Self.read(ocr, Self.focus(CGPoint(x: 1400, y: 700)))
        #expect(ocr.calls == [Self.bandPx, Self.whole], "the band, then once the whole capture")
        let text = try #require(hit.paragraph)
        #expect(text.contains("p1 line 0") && text.contains("p1 line 19"), "\(text)")
        #expect(hit.selection == hit.paragraph)
        let crop = try #require(hit.crop)
        #expect(crop.maxY > 1270 && crop.minY < 600 && Self.whole.contains(crop), "\(crop)")
        // The paragraph's own reading, in the crop's pixels, has every line.
        #expect(hit.block?.lines.count == 20)
    }

    @Test func eachOpenEdgeCounts() async throws {
        // Lines wider than the band on both sides (a single wide column): cut at the left and right edges.
        let wide = PolishKit.FakeOCR(PolishKit.paragraph(1, origin: CGPoint(x: 400, y: 600), width: 2000, count: 3))
        let hit = await Self.read(wide, Self.focus(CGPoint(x: 1400, y: 620)))
        #expect(wide.calls == [Self.bandPx, Self.whole])
        let crop = try #require(hit.crop)
        #expect(crop.minX < 400 && crop.maxX > 2400, "\(crop)")
        // Starting above the band.
        let tall = PolishKit.FakeOCR(PolishKit.paragraph(1, origin: CGPoint(x: 900, y: 200), width: 1000, count: 12))
        _ = await Self.read(tall, Self.focus(CGPoint(x: 1400, y: 500)))
        #expect(tall.calls == [Self.bandPx, Self.whole])
    }

    @Test func aCutAtTheCapturesOwnEdgeIsNotReadAgain() async throws {
        // The capture ends where the band does (the window under the click ends there): nothing more to read.
        let size = CGSize(width: 2800, height: 1080)
        let band = CGRect(x: 0.25, y: 1.0 / 3.0, width: 0.5, height: 2.0 / 3.0)
        let ocr = PolishKit.FakeOCR(PolishKit.paragraph(1, origin: CGPoint(x: 900, y: 600), width: 1000, count: 20))
        let hit = await Self.read(ocr, Self.focus(CGPoint(x: 1400, y: 700), band: band, size: size), size: size)
        #expect(ocr.calls == [CGRect(x: 700, y: 360, width: 1400, height: 720)])
        #expect(hit.paragraph?.contains("p1 line 13") == true && hit.paragraph?.contains("p1 line 19") == false)
    }

    @Test func aParagraphEndingWellInsideTheBandIsNotReadAgain() async {
        // Ends at 1022: two line heights and more above the band's bottom (1080).
        let ocr = PolishKit.FakeOCR(PolishKit.paragraph(1, origin: CGPoint(x: 900, y: 488), width: 1000, count: 16))
        _ = await Self.read(ocr, Self.focus(CGPoint(x: 1400, y: 700)))
        #expect(ocr.calls == [Self.bandPx])
    }

    @Test func onlyTheParagraphUnderTheClickCounts() async {
        // Paragraph 2 runs past the band; the click is on paragraph 1, inside it.
        let page = PolishKit.paragraph(1, origin: CGPoint(x: 900, y: 450), width: 1000, count: 4)
            + PolishKit.paragraph(2, origin: CGPoint(x: 900, y: 700), width: 1000, count: 20)
        let ocr = PolishKit.FakeOCR(page)
        let hit = await Self.read(ocr, Self.focus(CGPoint(x: 1400, y: 480)))
        #expect(ocr.calls == [Self.bandPx])
        #expect(hit.paragraph?.hasPrefix("p1 line 0") == true)
    }

    @Test func aTermsParagraphIsReadWholeTooAndTheTermStays() async throws {
        let ocr = PolishKit.FakeOCR(PolishKit.paragraph(1, origin: CGPoint(x: 900, y: 600), width: 1000, count: 20))
        // ⇧-click near the end of line 3 ("… gamma delta").
        let hit = await Self.read(ocr, Self.focus(CGPoint(x: 1880, y: 712), term: true))
        #expect(ocr.calls == [Self.bandPx, Self.whole])
        #expect(hit.selection == "delta", "\(String(describing: hit.selection))")
        #expect(hit.paragraph?.contains("p1 line 19") == true)
    }

    @Test func failuresKeepWhatWasRead() async throws {
        // The band's reading fails: the fallback (the figure / small band), never a second read.
        let page = PolishKit.paragraph(1, origin: CGPoint(x: 900, y: 600), width: 1000, count: 20)
        let first = PolishKit.FakeOCR(page, failing: [0])
        let none = await Self.read(first, Self.focus(CGPoint(x: 1400, y: 700)))
        #expect(first.calls == [Self.bandPx])
        #expect(none == ExplainFocusResolver.unresolved(Self.focus(CGPoint(x: 1400, y: 700)), imageSize: Self.size))
        #expect(none.crop == CGRect(x: 1120, y: 576, width: 560, height: 288))
        // The second reading fails: the band's paragraph stays.
        let second = PolishKit.FakeOCR(page, failing: [1])
        let hit = await Self.read(second, Self.focus(CGPoint(x: 1400, y: 700)))
        #expect(second.calls.count == 2)
        #expect(hit.paragraph?.contains("p1 line 13") == true && hit.paragraph?.contains("p1 line 19") == false)
    }

    @Test func withoutABandTheWholeImageIsReadOnceAsBefore() async {
        let ocr = PolishKit.FakeOCR(PolishKit.paragraph(1, origin: CGPoint(x: 900, y: 600), width: 1000, count: 20))
        let focus = Self.focus(CGPoint(x: 1400, y: 700), band: nil)
        let hit = await Self.read(ocr, focus)
        #expect(ocr.calls == [Self.whole])
        let direct = PolishKit.FakeOCR(ocr.page).read(Self.whole)
        #expect(hit == ExplainFocusResolver.resolve(direct!, imageSize: Self.size, focus: focus))
    }

    // MARK: The focus in the larger capture

    @Test func aFocusWidensFromTheBandToTheReadArea() throws {
        let band = CGRect(x: 100, y: 100, width: 700, height: 360)
        let area = CGRect(x: 0, y: 0, width: 1400, height: 720)
        // The click at (450, 280) pt; the fallback the band's middle half.
        let f = try #require(ExplainFocus(local: CGPoint(x: 450, y: 280), in: band, term: true,
                                          fallback: CGRect(x: 275, y: 190, width: 350, height: 180)))
        let w = f.widened(from: band, to: area)
        #expect(abs(w.unit.x - 450.0 / 1400) < 1e-9 && abs(w.unit.y - 280.0 / 720) < 1e-9)
        let fb = try #require(w.fallback)
        #expect(abs(fb.minX - 275.0 / 1400) < 1e-9 && abs(fb.width - 350.0 / 1400) < 1e-9 && abs(fb.minY - 190.0 / 720) < 1e-9)
        let b = try #require(w.band)
        #expect(abs(b.minX - 100.0 / 1400) < 1e-9 && abs(b.minY - 100.0 / 720) < 1e-9 && abs(b.width - 0.5) < 1e-9
                    && abs(b.height - 0.5) < 1e-9)
        #expect(w.term)
        // In pixels of the area's capture (2×): the band and the click land where they were.
        let px = CGSize(width: 2800, height: 1440)
        #expect(w.bandPixels(in: px) == CGRect(x: 200, y: 200, width: 1400, height: 720))
        let click = w.pixel(in: px)
        #expect(abs(click.x - 900) < 1e-6 && abs(click.y - 560) < 1e-6, "\(click)")
        // Nothing to widen: the same area, or one that doesn't hold the band.
        #expect(f.widened(from: band, to: band) == f)
        #expect(f.widened(from: band, to: CGRect(x: 200, y: 0, width: 1400, height: 720)) == f)
        #expect(f.band == nil && f.bandPixels(in: px) == nil)
        // A band that is the whole capture is no band.
        #expect(ExplainFocus(unit: .zero, band: CGRect(x: 0, y: 0, width: 1, height: 1)).band == nil)
    }

    // MARK: OCR helpers

    @Test func cutOffChecksOnlyTheGivenEdges() {
        let p = OCRParagraph(text: "x", box: CGRect(x: 0, y: 100, width: 500, height: 600), lineIndices: [])
        let size = CGSize(width: 1000, height: 720)
        #expect(OCRPostProcess.isCutOff(p, imageSize: size))                       // the left edge
        #expect(!OCRPostProcess.isCutOff(p, imageSize: size, edges: [.top, .right, .bottom]))
        #expect(OCRPostProcess.isCutOff(p, imageSize: size, margin: 24, edges: .bottom))        // 20 px from the bottom
        #expect(!OCRPostProcess.isCutOff(p, imageSize: size, margin: 2, edges: .bottom))
        #expect(!OCRPostProcess.isCutOff(p, imageSize: size, edges: []))
    }

    @Test func aPartsReadingMovesIntoTheImage() {
        let r = OCRResult(lines: [OCRLine(text: "a b", box: CGRect(x: 1, y: 2, width: 30, height: 10), confidence: 0.9,
                                          words: [OCRWord(text: "a", box: CGRect(x: 1, y: 2, width: 10, height: 10))])],
                          paragraphs: [OCRParagraph(text: "a b", box: CGRect(x: 1, y: 2, width: 30, height: 10), lineIndices: [0])],
                          text: "a b", meanConfidence: 0.9)
        let moved = OCRPostProcess.offset(r, by: CGPoint(x: 100, y: 50))
        #expect(moved.lines[0].box == CGRect(x: 101, y: 52, width: 30, height: 10))
        #expect(moved.lines[0].words[0].box == CGRect(x: 101, y: 52, width: 10, height: 10))
        #expect(moved.paragraphs[0].box == CGRect(x: 101, y: 52, width: 30, height: 10))
        #expect(moved.text == r.text && moved.meanConfidence == r.meanConfidence)
        #expect(OCRPostProcess.offset(r, by: .zero) == r)
    }
}
