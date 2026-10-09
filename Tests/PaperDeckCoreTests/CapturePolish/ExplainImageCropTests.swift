import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// CUX-7 / CUX-8 (capture polish): what the overlay sends for a box or a click is made off the main
/// thread by `ExplainImageCrop` — the plan, the crop, the blank check, the encoding and a detached OCR
/// copy; a flat capture says "came back blank" and sends nothing; a click's capture holds the larger
/// area around its band (inside the window under the click) for the paragraph that runs past it.
@Suite struct ExplainImageCropTests {
    /// 1600 × 1000 pt at 2×: a text column top-left, a chart right of it.
    static let size = CGSize(width: 1600, height: 1000)
    static let column = CGRect(x: 100, y: 100, width: 800, height: 800)
    static let chart = CGRect(x: 1050, y: 300, width: 450, height: 400)

    static func page() throws -> CGImage {
        try #require(PolishKit.still(size) { ctx in
            UXKit.paragraph(ctx, column)
            UXKit.chart(ctx, chart)
        })
    }

    static func ready(_ outcome: ExplainImageCrop.Outcome) throws -> ExplainImageCrop.Prepared {
        guard case .ready(let p) = outcome else { throw Failure.notReady("\(outcome)") }
        return p
    }

    enum Failure: Error { case notReady(String) }

    static func kind(_ outcome: ExplainImageCrop.Outcome) -> String {
        switch outcome {
        case .ready: return "ready"
        case .nothingLegible: return "nothingLegible"
        case .blank: return "blank"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    // MARK: A box

    @Test func aBoxIsCroppedEncodedAndCopiedForOCR() throws {
        let s = PolishKit.screens(try Self.page(), size: Self.size)
        let box = CaptureRegion(displayID: 1, rect: CGRect(x: 120, y: 120, width: 400, height: 200))
        let p = try Self.ready(ExplainImageCrop.prepare(.box(box, figure: false), window: nil, frozen: s))
        #expect(p.region == box && p.readArea == box && !p.readsBeyondRegion)
        #expect(p.kind == .explain && p.focus == nil && p.click == nil)
        #expect(p.ocrImage.width == 800 && p.ocrImage.height == 400, "full resolution for OCR")
        #expect(p.image.pixelSize == CGSize(width: 800, height: 400) && p.image.mediaType == "image/png")
        // ⌥: the same box as a figure.
        let f = try Self.ready(ExplainImageCrop.prepare(.box(box, figure: true), window: nil, frozen: s))
        #expect(f.kind == .figure && f.focus == nil)
        // A full 5K screen is downscaled for sending; OCR keeps every pixel.
        let five = PolishKit.screens(try #require(PolishKit.fiveKPage()), size: PolishKit.fiveK)
        let all = CaptureRegion(displayID: 1, rect: CGRect(origin: .zero, size: PolishKit.fiveK))
        let big = try Self.ready(ExplainImageCrop.prepare(.box(all, figure: false), window: nil, frozen: five))
        #expect(max(big.image.pixelSize.width, big.image.pixelSize.height) <= AssistImage.maxLongEdge)
        #expect(big.ocrImage.width == 5120 && big.ocrImage.height == 2880)
    }

    @Test func theOCRCopyHasTheStillsOwnPixels() throws {
        let still = try #require(ExplainKit.coordinateImage(width: 2000, height: 1200))
        let s = PolishKit.screens(still, size: CGSize(width: 1000, height: 600))
        // A box at (60.5, 30.25) pt: pixels from (121, 60).
        let box = CaptureRegion(displayID: 1, rect: CGRect(x: 60.5, y: 30.25, width: 300, height: 200))
        let p = try Self.ready(ExplainImageCrop.prepare(.box(box, figure: false), window: nil, frozen: s))
        #expect(ExplainKit.topLeft(p.ocrImage).map { [$0.0, $0.1] } == [121 % 256, 60])
        #expect(p.ocrImage.width == 600 && p.ocrImage.height == 401)
    }

    @Test func aFlatCaptureComesBackBlankAndIsNotSent() throws {
        // A protected window or a sleeping display: one flat colour, black or white.
        for gray in [0.0, 0.13, 1.0] as [CGFloat] {
            let s = PolishKit.screens(try #require(PolishKit.still(Self.size, fill: gray)), size: Self.size)
            let box = CaptureRegion(displayID: 1, rect: CGRect(x: 100, y: 100, width: 600, height: 400))
            #expect(Self.kind(ExplainImageCrop.prepare(.box(box, figure: false), window: nil, frozen: s)) == "blank", "\(gray)")
            #expect(Self.kind(ExplainImageCrop.prepare(.box(box, figure: true), window: nil, frozen: s)) == "blank", "\(gray)")
            let click = ExplainImageCrop.Gesture.click(CGPoint(x: 800, y: 500), displayID: 1, term: false, figure: false)
            #expect(Self.kind(ExplainImageCrop.prepare(click, window: nil, frozen: s)) == "blank", "\(gray)")
        }
        // A box with a single word in it is content.
        let word = PolishKit.screens(try #require(PolishKit.still(Self.size) { ctx in
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 400, y: 300, width: 30, height: 8))
        }), size: Self.size)
        let box = CaptureRegion(displayID: 1, rect: CGRect(x: 100, y: 100, width: 600, height: 400))
        #expect(Self.kind(ExplainImageCrop.prepare(.box(box, figure: false), window: nil, frozen: word)) == "ready")
    }

    // MARK: A click

    @Test func aClickHoldsTheReadAreaAroundItsBand() throws {
        let s = PolishKit.screens(try Self.page(), size: Self.size)
        let click = CGPoint(x: 500, y: 500)
        let p = try Self.ready(ExplainImageCrop.prepare(.click(click, displayID: 1, term: false, figure: false), window: nil, frozen: s))
        #expect(p.kind == .explain && p.click == click)
        // The band the panel opens beside, and the read area twice its size around the click.
        #expect(p.region.rect == CaptureGeometry.band(around: click, displaySize: Self.size), "\(p.region.rect)")
        #expect(p.readArea.rect == CGRect(x: 0, y: 140, width: 1400, height: 720), "\(p.readArea.rect)")
        #expect(p.readsBeyondRegion)
        #expect(p.ocrImage.width == 2800 && p.ocrImage.height == 1440)
        // What may be sent stays the band; the focus is a fraction of the read area, its band marked.
        #expect(p.image.pixelSize == CGSize(width: 1400, height: 720))
        let focus = try #require(p.focus)
        let px = CGSize(width: p.ocrImage.width, height: p.ocrImage.height)
        let clickPx = focus.pixel(in: px)
        #expect(abs(clickPx.x - (click.x - p.readArea.rect.minX) * 2) < 0.01 && abs(clickPx.y - (click.y - p.readArea.rect.minY) * 2) < 0.01)
        #expect(focus.bandPixels(in: px) == CGRect(x: 300, y: 360, width: 1400, height: 720))
        let fallback = try #require(focus.fallbackPixels(in: px))
        #expect(try #require(focus.bandPixels(in: px)).insetBy(dx: -1, dy: -1).contains(fallback))
        // ⇧: the term.
        let term = try Self.ready(ExplainImageCrop.prepare(.click(click, displayID: 1, term: true, figure: false), window: nil, frozen: s))
        #expect(term.kind == .defineTerms && term.focus?.term == true)
    }

    @Test func theReadAreaStaysInTheWindowUnderTheClick() throws {
        // The display left of the main one (global x −1600); the window under the click in global points.
        let s = PolishKit.screens(try Self.page(), size: Self.size, origin: CGPoint(x: -1600, y: 0))
        let window = CGRect(x: -1600 + 50, y: 50, width: 1000, height: 700)
        let click = CGPoint(x: 500, y: 500)
        let gesture = ExplainImageCrop.Gesture.click(click, displayID: 1, term: false, figure: false)
        #expect(ExplainImageCrop.probe(gesture, in: s) == CGPoint(x: -1100, y: 500))
        let p = try Self.ready(ExplainImageCrop.prepare(gesture, window: window, frozen: s))
        let local = CGRect(x: 50, y: 50, width: 1000, height: 700)
        #expect(local.contains(p.readArea.rect) && local.contains(p.region.rect), "\(p.readArea.rect)")
        #expect(p.readArea.rect == CGRect(x: 50, y: 140, width: 1000, height: 610), "\(p.readArea.rect)")
        #expect(p.ocrImage.width == 2000 && p.ocrImage.height == 1220)
        // A window no larger than the band: the capture is the band alone (no wider read).
        let band = p.region.rect
        let tight = try Self.ready(ExplainImageCrop.prepare(gesture, window: band.offsetBy(dx: -1600, dy: 0), frozen: s))
        #expect(tight.readArea == tight.region && !tight.readsBeyondRegion && tight.focus?.band == nil, "\(tight.readArea)")
    }

    @Test func anOptionClickSendsTheFigureAlone() throws {
        let s = PolishKit.screens(try Self.page(), size: Self.size)
        let gesture = ExplainImageCrop.Gesture.click(CGPoint(x: 1200, y: 600), displayID: 1, term: false, figure: true)
        let p = try Self.ready(ExplainImageCrop.prepare(gesture, window: nil, frozen: s))
        #expect(p.kind == .figure && p.focus == nil && p.readArea == p.region && !p.readsBeyondRegion)
        #expect(p.region.rect.contains(Self.chart.insetBy(dx: 1, dy: 1)) && p.region.rect.minX > Self.column.maxX, "\(p.region.rect)")
    }

    @Test func anEmptyMarginOfAPageIsNothingLegibleNotBlank() throws {
        let s = PolishKit.screens(try #require(PolishKit.still(Self.size) { ctx in
            UXKit.paragraph(ctx, CGRect(x: 100, y: 100, width: 600, height: 300))
        }), size: Self.size)
        let gesture = ExplainImageCrop.Gesture.click(CGPoint(x: 1300, y: 800), displayID: 1, term: false, figure: false)
        #expect(Self.kind(ExplainImageCrop.prepare(gesture, window: nil, frozen: s)) == "nothingLegible")
        // The same click on a page whose window is only that empty corner: the window is all one colour.
        let corner = CGRect(x: 1000, y: 600, width: 600, height: 400)
        #expect(Self.kind(ExplainImageCrop.prepare(gesture, window: corner, frozen: s)) == "blank")
    }

    @Test func anUnknownDisplayFails() throws {
        let s = PolishKit.screens(try Self.page(), size: Self.size)
        let box = CaptureRegion(displayID: 9, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(Self.kind(ExplainImageCrop.prepare(.box(box, figure: false), window: nil, frozen: s)) == "failed")
        let click = ExplainImageCrop.Gesture.click(.zero, displayID: 9, term: false, figure: false)
        #expect(Self.kind(ExplainImageCrop.prepare(click, window: nil, frozen: s)) == "failed")
        #expect(ExplainImageCrop.probe(click, in: s) == nil && ExplainImageCrop.probe(.box(box, figure: false), in: s) == nil)
        // A box off the display crops nothing.
        let off = CaptureRegion(displayID: 1, rect: CGRect(x: 2000, y: 0, width: 100, height: 100))
        #expect(Self.kind(ExplainImageCrop.prepare(.box(off, figure: false), window: nil, frozen: s)) == "failed")
    }

    @Test func aBoxProbesItsCentre() throws {
        let s = PolishKit.screens(try Self.page(), size: Self.size, origin: CGPoint(x: 0, y: -1000))
        let box = CaptureRegion(displayID: 1, rect: CGRect(x: 100, y: 100, width: 400, height: 200))
        #expect(ExplainImageCrop.probe(.box(box, figure: false), in: s) == CGPoint(x: 300, y: -800))
    }

    // MARK: Closing the overlay

    @Test func closingTheOverlayStopsTheWork() async throws {
        let s = PolishKit.screens(try Self.page(), size: Self.size)
        let box = CaptureRegion(displayID: 1, rect: CGRect(x: 120, y: 120, width: 400, height: 200))
        let click = ExplainImageCrop.Gesture.click(CGPoint(x: 500, y: 500), displayID: 1, term: false, figure: false)
        #expect(Self.kind(ExplainImageCrop.prepare(.box(box, figure: false), window: nil, frozen: s, cancelled: { true })) == "cancelled")
        #expect(Self.kind(ExplainImageCrop.prepare(click, window: nil, frozen: s, cancelled: { true })) == "cancelled")
        // Closed while a click on a blank area was planned: no "blank" notice either.
        let flat = PolishKit.screens(try #require(PolishKit.still(Self.size, fill: 0)), size: Self.size)
        #expect(Self.kind(ExplainImageCrop.prepare(click, window: nil, frozen: flat, cancelled: { true })) == "cancelled")
        // Cancelled after the plan but before the encoding: still nothing.
        final class Countdown: @unchecked Sendable { var left: Int; init(_ n: Int) { left = n } }
        let late = Countdown(1)
        let outcome = ExplainImageCrop.prepare(click, window: nil, frozen: s) { late.left -= 1; return late.left < 0 }
        #expect(Self.kind(outcome) == "cancelled")
        // The overlay's task cancelled: `run` (off the main actor) sees it.
        let task = Task { () -> ExplainImageCrop.Outcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await ExplainImageCrop.run(.box(box, figure: false), window: nil, frozen: s)
        }
        #expect(Self.kind(await task.value) == "cancelled")
        let live = await ExplainImageCrop.run(.box(box, figure: false), window: nil, frozen: s)
        #expect(Self.kind(live) == "ready")
    }

    // MARK: The still goes with the overlay

    /// Released when the still's pixels are freed.
    final class Freed: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isFreed: Bool { lock.withLock { value } }
        func free() { lock.withLock { value = true } }
    }

    /// A still whose pixel buffer reports when it is freed.
    static func trackedStill(width: Int, height: Int, freed: Freed) throws -> CGImage {
        let bytes = width * height * 4
        let buffer = try #require(malloc(bytes))
        // Text-like rows so the box is not blank.
        let px = buffer.bindMemory(to: UInt8.self, capacity: bytes)
        for y in 0..<height {
            let ink = (y / 8) % 3 == 0
            for x in 0..<width {
                let v: UInt8 = ink && x % 40 < 30 ? 20 : 255
                let i = (y * width + x) * 4
                px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255
            }
        }
        let info = Unmanaged.passRetained(freed).toOpaque()
        let provider = try #require(CGDataProvider(dataInfo: info, data: buffer, size: bytes) { info, data, _ in
            free(UnsafeMutableRawPointer(mutating: data))
            if let info { Unmanaged<Freed>.fromOpaque(info).takeRetainedValue().free() }
        })
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @Test func theOCRCopyDoesNotKeepTheStillAlive() throws {
        // A plain crop keeps its source's pixels (why the copy exists) …
        let kept = Freed()
        var crop: CGImage?
        try autoreleasepool {
            let still = try Self.trackedStill(width: 400, height: 300, freed: kept)
            crop = still.cropping(to: CGRect(x: 10, y: 10, width: 100, height: 100))
        }
        #expect(crop != nil && !kept.isFreed)
        crop = nil
        #expect(kept.isFreed)
        // … the capture's OCR copy doesn't: the still is freed with the overlay while the copy lives on.
        let freed = Freed()
        var ocrImage: CGImage?
        try autoreleasepool {
            let s = PolishKit.screens(try Self.trackedStill(width: 400, height: 300, freed: freed), size: CGSize(width: 400, height: 300),
                                      scale: 1)
            let box = CaptureRegion(displayID: 1, rect: CGRect(x: 10, y: 10, width: 200, height: 150))
            ocrImage = try Self.ready(ExplainImageCrop.prepare(.box(box, figure: false), window: nil, frozen: s)).ocrImage
        }
        #expect(ocrImage?.width == 200 && freed.isFreed)
        // Only a crop of at most half the still is copied: a full-screen box would copy as much as it frees.
        let still = try #require(PolishKit.still(CGSize(width: 400, height: 300), scale: 1))
        let display = FrozenDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 1, image: still)
        #expect(ExplainImageCrop.copyFreesTheStill(try #require(still.cropping(to: CGRect(x: 0, y: 0, width: 200, height: 300))), of: display))
        #expect(!ExplainImageCrop.copyFreesTheStill(try #require(still.cropping(to: CGRect(x: 0, y: 0, width: 201, height: 300))), of: display))
        #expect(!ExplainImageCrop.copyFreesTheStill(still, of: display) && !ExplainImageCrop.copyFreesTheStill(still, of: nil))
    }
}
