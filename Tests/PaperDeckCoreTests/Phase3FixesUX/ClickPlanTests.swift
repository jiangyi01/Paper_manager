import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// F3 (a click, a lens click or an ⌥-click sends only what the user meant) and CUX-8 (a blank or flat
/// capture is refused): `CaptureClickPlan` on synthetic displays — the band stays in the window under
/// the click, ⌥ sends the figure's own bounds, a click with no paragraph under it sends the figure or a
/// small band (never the 700 × 360 band), and nothing legible means nothing is sent.
@Suite struct ClickPlanTests {
    /// The page plus a text block left of the chart (inside the band of a click on the chart).
    static let sideText = CGRect(x: 340, y: 400, width: 180, height: 80)

    static func page() throws -> CGImage {
        try #require(UXKit.display(UXKit.size) { ctx in
            UXKit.paragraph(ctx, UXKit.paragraphRect)
            UXKit.paragraph(ctx, sideText)
            UXKit.chart(ctx, UXKit.chartRect)
        })
    }

    /// A click on the second (tallest) bar.
    static let onBar = CGPoint(x: 690, y: 450)

    @Test func anOptionClickSendsTheFigureNotTheBand() throws {
        let image = try Self.page()
        let plan = try #require(CaptureClickPlan.plan(click: Self.onBar, displaySize: UXKit.size, window: nil, term: false, figure: true,
                                                      crop: UXKit.cropper(image)))
        guard case .figure(let rect) = plan else { Issue.record("\(plan)"); return }
        // The whole chart, a little padding, nothing of the text beside it.
        #expect(rect.contains(UXKit.chartRect.insetBy(dx: 1, dy: 1)), "\(rect)")
        #expect(rect.minX > Self.sideText.maxX, "\(rect)")
        #expect(rect.width < UXKit.chartRect.width + 40 && rect.height < UXKit.chartRect.height + 40, "\(rect)")
        // Far smaller than the band the click used to send.
        #expect(rect.width * rect.height < 0.5 * CaptureGeometry.clickBand.width * CaptureGeometry.clickBand.height)
    }

    /// A chart wider than the 700 pt band (render check: an ⌥-click near its left end was cut at the band).
    @Test func aFigureWiderThanTheBandIsFoundWhole() throws {
        let size = CGSize(width: 1600, height: 900)
        let wide = CGRect(x: 150, y: 300, width: 900, height: 300)
        let image = try #require(UXKit.display(size) { ctx in
            UXKit.paragraph(ctx, CGRect(x: 150, y: 120, width: 900, height: 120))
            UXKit.chart(ctx, wide)
        })
        let click = CGPoint(x: 260, y: 560)                        // the first bar, near the chart's left end
        let figure = try #require(CaptureClickPlan.plan(click: click, displaySize: size, window: nil, term: false, figure: true,
                                                        crop: UXKit.cropper(image)))
        guard case .figure(let rect) = figure else { Issue.record("\(figure)"); return }
        #expect(rect.contains(wide.insetBy(dx: 1, dy: 1)) && rect.minY > 240, "\(rect)")
        // A plain click: the band read on this Mac grows to hold it; the fallback is the whole chart.
        let plain = try #require(CaptureClickPlan.plan(click: click, displaySize: size, window: nil, term: false, figure: false,
                                                       crop: UXKit.cropper(image)))
        guard case .paragraph(let band, let focus) = plain else { Issue.record("\(plain)"); return }
        #expect(band.contains(wide) && band.width <= CaptureClickPlan.maxGrownBand.width, "\(band)")
        #expect(UXKit.points(try #require(focus.fallback), in: band).contains(wide.insetBy(dx: 1, dy: 1)))
    }

    @Test func aPlainClickOnAFigureFallsBackToThatFigure() throws {
        let image = try Self.page()
        let plan = try #require(CaptureClickPlan.plan(click: Self.onBar, displaySize: UXKit.size, window: nil, term: false, figure: false,
                                                      crop: UXKit.cropper(image)))
        guard case .paragraph(let band, let focus) = plan else { Issue.record("\(plan)"); return }
        #expect(band.size == CaptureGeometry.clickBand)
        let fallback = UXKit.points(try #require(focus.fallback), in: band)
        #expect(fallback.contains(UXKit.chartRect.insetBy(dx: 1, dy: 1)) && fallback.minX > Self.sideText.maxX, "\(fallback)")
        // The click itself survives as a fraction of the band.
        #expect(abs(focus.unit.x * band.width + band.minX - Self.onBar.x) < 1e-6)
        // Local OCR finding nothing readable there keeps only that figure.
        let px = CGSize(width: band.width * 2, height: band.height * 2)
        let hit = ExplainFocusResolver.resolve(.empty, imageSize: px, focus: focus)
        #expect(hit.selection == nil && hit.crop == focus.fallbackPixels(in: px) && hit.crop != nil)
        #expect(hit.crop.map { $0.width < px.width * 0.6 } == true)
    }

    @Test func aClickNearNothingSendsASmallBandNotTheWholeBand() throws {
        let image = try Self.page()
        let click = CGPoint(x: 300, y: 280)               // 74 pt under the paragraph, nothing within reach
        let plan = try #require(CaptureClickPlan.plan(click: click, displaySize: UXKit.size, window: nil, term: false, figure: false,
                                                      crop: UXKit.cropper(image)))
        guard case .paragraph(let band, let focus) = plan else { Issue.record("\(plan)"); return }
        let fallback = UXKit.points(try #require(focus.fallback), in: band)
        #expect(abs(fallback.width - CaptureFigure.smallBand.width) < 1 && abs(fallback.height - CaptureFigure.smallBand.height) < 1,
                "\(fallback)")
        #expect(fallback.contains(click))
        // ⌥ there: the same small band as the figure.
        let figure = try #require(CaptureClickPlan.plan(click: click, displaySize: UXKit.size, window: nil, term: false, figure: true,
                                                        crop: UXKit.cropper(image)))
        guard case .figure(let r) = figure else { Issue.record("\(figure)"); return }
        #expect(abs(r.width - CaptureFigure.smallBand.width) < 1 && abs(r.height - CaptureFigure.smallBand.height) < 1)
    }

    @Test func theBandNeverLeavesTheWindowUnderTheClick() throws {
        let image = try Self.page()
        let window = CGRect(x: 530, y: 0, width: 470, height: 700)          // the chart's window; the text is another app
        let plan = try #require(CaptureClickPlan.plan(click: Self.onBar, displaySize: UXKit.size, window: window, term: false,
                                                      figure: false, crop: UXKit.cropper(image)))
        guard case .paragraph(let band, _) = plan else { Issue.record("\(plan)"); return }
        #expect(band.minX >= window.minX && band.maxX <= window.maxX && band.contains(Self.onBar), "\(band)")
        // A window that doesn't hold the click (or none) leaves the band alone.
        let elsewhere = CGRect(x: 0, y: 0, width: 200, height: 200)
        #expect(CaptureGeometry.clip(CGRect(x: 300, y: 270, width: 700, height: 360), toWindow: elsewhere, keeping: Self.onBar)
                == CGRect(x: 300, y: 270, width: 700, height: 360))
        #expect(CaptureGeometry.clip(CGRect(x: 300, y: 270, width: 700, height: 360), toWindow: window, keeping: Self.onBar)
                == CGRect(x: 530, y: 270, width: 470, height: 360))
    }

    @Test func nothingLegibleUnderOrNearTheClickIsRefused() throws {
        let image = try Self.page()
        // Bottom-left margin: nothing within the small band either.
        let blank = CaptureClickPlan.plan(click: CGPoint(x: 100, y: 620), displaySize: UXKit.size, window: nil, term: false, figure: false,
                                          crop: UXKit.cropper(image))
        #expect(blank == .blank)
        #expect(CaptureClickPlan.plan(click: CGPoint(x: 100, y: 620), displaySize: UXKit.size, window: nil, term: false, figure: true,
                                      crop: UXKit.cropper(image)) == .blank)
        // A protected window / a sleeping display: one flat colour everywhere.
        let black = try #require(UXKit.display(UXKit.size, fill: 0))
        for p in [Self.onBar, CGPoint(x: 10, y: 10), CGPoint(x: 999, y: 699)] {
            #expect(CaptureClickPlan.plan(click: p, displaySize: UXKit.size, window: nil, term: false, figure: false,
                                          crop: UXKit.cropper(black)) == .blank)
        }
        // A still that can't be read: no plan (the overlay beeps), never a send.
        #expect(CaptureClickPlan.plan(click: Self.onBar, displaySize: UXKit.size, window: nil, term: false, figure: false,
                                      crop: { _ in nil }) == nil)
    }

    // MARK: CUX-8 blank

    @Test func flatCapturesAreBlankButSparseContentIsNot() throws {
        for gray in [0.0, 1.0, 0.5] {
            let flat = try #require(UXKit.display(CGSize(width: 400, height: 300), fill: gray))
            #expect(CaptureFigure.isBlank(flat) && ExplainImage.isBlank(flat), "\(gray)")
        }
        // One small mark in a large white box: content (a 32-cell average called this blank).
        let sparse = try #require(UXKit.display(CGSize(width: 800, height: 500)) { ctx in
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 400, y: 250, width: 6, height: 8))
        })
        #expect(!CaptureFigure.isBlank(sparse) && !ExplainImage.isBlank(sparse))
        #expect((ExplainImage.luminance(sparse)?.deviation ?? 1) < 0.01, "the old rule's measure: why it failed")
        // A dark-mode page (light text on dark) is content too.
        let dark = try #require(UXKit.display(CGSize(width: 400, height: 300), fill: 0.12) { ctx in
            ctx.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 20, y: 20, width: 200, height: 10))
        })
        #expect(!CaptureFigure.isBlank(dark))
    }

    @Test func theFigureBoundsFollowTheInkAroundTheClick() throws {
        let image = try Self.page()
        // On the paragraph (dense lines join into one block), on the chart, and off everything.
        let para = try #require(CaptureFigure.bounds(in: image, around: CGPoint(x: 200 * 2, y: 150 * 2), scale: 2))
        let p = CGRect(x: para.minX / 2, y: para.minY / 2, width: para.width / 2, height: para.height / 2)
        #expect(p.contains(CGRect(x: 61, y: 101, width: 418, height: 100)) && p.maxX < UXKit.chartRect.minX, "\(p)")
        #expect(CaptureFigure.bounds(in: image, around: CGPoint(x: 100 * 2, y: 650 * 2), scale: 2) == nil)
        // A lone mark keeps a minimum of context.
        let dot = try #require(UXKit.display(CGSize(width: 300, height: 300)) { ctx in
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 150, y: 150, width: 4, height: 4))
        })
        let r = try #require(CaptureFigure.bounds(in: dot, around: CGPoint(x: 304, y: 304), scale: 2))
        #expect(r.width >= CaptureFigure.minSide * 2 - 1 && r.height >= CaptureFigure.minSide * 2 - 1, "\(r)")
    }
}
