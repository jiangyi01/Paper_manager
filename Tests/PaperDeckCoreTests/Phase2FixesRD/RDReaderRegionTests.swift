import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import PaperDeckCore

/// Phase 2 fix RD-2: a region image (Copy Image now, Explain's picture later) shows the box the way
/// the page is displayed — turned by the page's /Rotate — and only what lies in its crop box. The
/// render drew the unrotated page: on a page shown rotated 90° the image came out sideways.
@Suite("Phase 2 fixes RD: region image orientation")
struct RDReaderRegionTests {
    /// A one-page PDF: media `media`, crop `crop`, a red square `marker` (page space), turned `rotation`.
    static func pdf(media: CGRect, crop: CGRect? = nil, marker: CGRect, rotation: Int = 0) throws -> PDFDocument {
        let data = NSMutableData()
        var box = media
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let ctx = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        var info: [CFString: Any] = [kCGPDFContextMediaBox: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)]
        if var c = crop { info[kCGPDFContextCropBox] = NSData(bytes: &c, length: MemoryLayout<CGRect>.size) }
        ctx.beginPDFPage(info as CFDictionary)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(media)
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(marker)
        ctx.endPDFPage()
        ctx.closePDF()
        let doc0 = try #require(PDFDocument(data: data as Data))
        guard rotation != 0 else { return doc0 }
        doc0.page(at: 0)?.rotation = rotation
        // Written and read back: the /Rotate is in the file, as in a real paper.
        let written = try #require(doc0.dataRepresentation())
        let doc = try #require(PDFDocument(data: written))
        #expect(doc.page(at: 0).map { ReaderPDF.normalizedRotation($0.rotation) } == ReaderPDF.normalizedRotation(rotation))
        return doc
    }

    /// Red-dominant pixel fraction per quadrant (top-left, top-right, bottom-left, bottom-right).
    static func redQuadrants(_ cg: CGImage) -> [Double] {
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var red = [0, 0, 0, 0], total = [0, 0, 0, 0]
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            let q = (y < h / 2 ? 0 : 2) + (x < w / 2 ? 0 : 1)        // row 0 is the top of the image
            total[q] += 1
            if px[i] > 200 && px[i + 1] < 60 && px[i + 2] < 60 { red[q] += 1 }
        } }
        return (0..<4).map { Double(red[$0]) / Double(max(total[$0], 1)) }
    }

    static func image(_ a: AssistImage) throws -> CGImage {
        let src = try #require(CGImageSourceCreateWithData(a.data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    }

    static func corner(_ q: [Double]) -> Int? { q.indices.max { q[$0] < q[$1] } }

    /// A landscape page with the marker in its unrotated top-left corner, at every rotation: the
    /// whole-page region looks like PDFKit's own drawing of the page (what the reader shows) —
    /// same orientation, the marker in the same corner.
    @MainActor @Test(arguments: [0, 90, 180, 270, -90, 450])
    func theWholePageMatchesWhatIsShown(_ rotation: Int) throws {
        let media = CGRect(x: 0, y: 0, width: 400, height: 200)
        let doc = try Self.pdf(media: media, marker: CGRect(x: 0, y: 100, width: 100, height: 100), rotation: rotation)
        let page = try #require(doc.page(at: 0))
        let crop = page.bounds(for: .cropBox)
        let region = try #require(ReaderPDF.renderRegion(crop, of: page))
        let shownTurned = ReaderPDF.normalizedRotation(rotation) % 180 != 0
        let r = try Self.image(region)
        #expect((r.width < r.height) == shownTurned, "rotation \(rotation): image \(r.width)×\(r.height)")
        let thumb = page.thumbnail(of: NSSize(width: shownTurned ? 200 : 400, height: shownTurned ? 400 : 200), for: .cropBox)
        let shown = try #require(thumb.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let seen = Self.redQuadrants(shown), got = Self.redQuadrants(r)
        #expect(Self.corner(seen) == Self.corner(got), "rotation \(rotation): marker on screen \(seen) vs image \(got)")
        #expect(got[Self.corner(got) ?? 0] > 0.4)           // the marker fills half of its quadrant
    }

    /// The verifier's probe: on a page displayed rotated 90°, the user boxes the top quarter of what
    /// they see (through the real `PDFView` geometry); the image is that box, not the box sideways.
    @MainActor @Test func aBoxOnARotatedPageIsTheBoxTheUserSaw() throws {
        let doc = try Self.pdf(media: CGRect(x: 0, y: 0, width: 400, height: 200),
                               marker: CGRect(x: 0, y: 100, width: 100, height: 100), rotation: 90)
        let page = try #require(doc.page(at: 0))
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 900))
        view.autoScales = true
        view.displayMode = .singlePage
        view.document = doc
        view.layoutDocumentView()
        let shown = view.convert(page.bounds(for: .cropBox), from: page)
        #expect(shown.height > shown.width, "a 90° landscape page is displayed portrait")
        let a = view.convert(CGPoint(x: shown.minX + 1, y: shown.maxY - 1), to: page)
        let b = view.convert(CGPoint(x: shown.maxX - 1, y: shown.maxY - shown.height / 4), to: page)
        let anchor = try #require(ReaderAnchor.region(paperID: "p", page: 1, from: a, to: b, pageBounds: page.bounds(for: .cropBox)))
        let boxed = view.convert(anchor.rect, from: page)
        #expect(boxed.width > boxed.height, "on screen the box is wider than tall")
        let image = try #require(ReaderPDF.renderRegion(anchor.rect, of: page))
        #expect(image.pixelSize.width > image.pixelSize.height, "the region image is sideways: \(image.pixelSize)")
        #expect(abs(image.pixelSize.width / image.pixelSize.height - boxed.width / boxed.height) < 0.05)
        // What the user sees in the box (PDFKit's drawing of the page, its top quarter) vs the image.
        let thumb = page.thumbnail(of: NSSize(width: shown.width, height: shown.height), for: .cropBox)
        let full = try #require(thumb.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let quarter = try #require(full.cropping(to: CGRect(x: 0, y: 0, width: full.width, height: full.height / 4)))
        #expect(Self.corner(Self.redQuadrants(quarter)) == Self.corner(Self.redQuadrants(try Self.image(image))))
    }

    /// Crop box offset (100, 150): a box around a marker inside it is the marker; a box that reaches
    /// outside the crop box is cut to it (what the reader shows), also on a rotated page.
    @Test func theCropBoxIsRespected() throws {
        let media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let crop = CGRect(x: 100, y: 150, width: 400, height: 500)
        let inside = CGRect(x: 120, y: 600, width: 60, height: 40)
        for rotation in [0, 90] {
            let doc = try Self.pdf(media: media, crop: crop, marker: inside, rotation: rotation)
            let page = try #require(doc.page(at: 0))
            #expect(page.bounds(for: .cropBox) == crop)
            let marker = try Self.image(try #require(ReaderPDF.renderRegion(inside, of: page)))
            #expect(Self.redQuadrants(marker).allSatisfy { $0 > 0.9 }, "rotation \(rotation)")
        }
        // Red outside the crop box only: the whole media box renders as the crop box, all white.
        let outside = try Self.pdf(media: media, crop: crop, marker: CGRect(x: 10, y: 10, width: 60, height: 60))
        let page = try #require(outside.page(at: 0))
        let whole = try #require(ReaderPDF.renderRegion(media, of: page))
        let scale = ReaderAnchor.renderScale(for: crop)
        #expect(whole.pixelSize == ReaderAnchor.pixelSize(for: crop, scale: scale), "\(whole.pixelSize)")
        #expect(Self.redQuadrants(try Self.image(whole)).allSatisfy { $0 == 0 })
        // Nothing of the box on the page: no image.
        #expect(ReaderPDF.renderRegion(CGRect(x: 0, y: 0, width: 50, height: 50), of: page) == nil)
    }

    /// The pure transform: the box's corners land where a clockwise /Rotate puts them.
    @Test func theDisplayTransformTurnsClockwise() {
        let r = CGRect(x: 10, y: 20, width: 40, height: 30)
        func map(_ p: CGPoint, _ rot: Int) -> CGPoint { p.applying(ReaderPDF.displayTransform(for: r, rotation: rot).transform) }
        let topLeft = CGPoint(x: r.minX, y: r.maxY), bottomLeft = CGPoint(x: r.minX, y: r.minY)
        #expect(ReaderPDF.displayTransform(for: r, rotation: 0).size == CGSize(width: 40, height: 30))
        #expect(map(topLeft, 0) == CGPoint(x: 0, y: 30))
        // 90° clockwise: the top-left corner goes to the top-right, the left edge becomes the top.
        #expect(ReaderPDF.displayTransform(for: r, rotation: 90).size == CGSize(width: 30, height: 40))
        #expect(map(topLeft, 90) == CGPoint(x: 30, y: 40) && map(bottomLeft, 90) == CGPoint(x: 0, y: 40))
        #expect(map(topLeft, 180) == CGPoint(x: 40, y: 0))
        #expect(map(topLeft, 270) == CGPoint(x: 0, y: 0) && ReaderPDF.displayTransform(for: r, rotation: 270).size == CGSize(width: 30, height: 40))
        #expect(ReaderPDF.normalizedRotation(-90) == 270 && ReaderPDF.normalizedRotation(450) == 90 && ReaderPDF.normalizedRotation(45) == 0)
    }
}
