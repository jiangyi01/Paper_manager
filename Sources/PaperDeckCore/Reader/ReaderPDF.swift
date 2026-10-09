import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// The reader's PDFKit-facing helpers that need no window: page labels, the tolerant quote finder
/// (citations, saved excerpts) and the region render handed to Explain. Each runs inside
/// `PDFKitGate` (re-entrant), whichever thread calls it. Owned by Slice C (reader).
package enum ReaderPDF {
    /// The printed label of every page (`labels[i]` = physical page i + 1; nil: none).
    package static func labels(of document: PDFDocument) -> [String?] {
        PDFKitGate.shared.run { (0..<document.pageCount).map { document.page(at: $0)?.label } }
    }

    /// PNG of `rect` (page space) on `page`, drawn from the PDF itself at `ReaderAnchor.renderScale`
    /// (sharper than any screen capture; long edge ≤ `AssistImage.maxLongEdge`) on white — as the
    /// page is shown (RD-2): turned by the page's /Rotate like PDFKit displays it, and only what lies
    /// inside its crop box (the rest of `rect` is cut off, as on screen). `rect` is in the page's
    /// unrotated space, like the anchor. nil when nothing of the box is on the page or drawing fails.
    package static func renderRegion(_ rect: CGRect, of page: PDFPage) -> AssistImage? {
        PDFKitGate.shared.run {
            guard let ref = page.pageRef else { return nil }
            return renderRegion(rect, of: ref, cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        }
    }

    /// The same from a `CGPDFPage` with its crop box and rotation (degrees clockwise, a multiple of 90).
    /// Drawing resolves the page's fonts, so it runs inside `PDFKitGate` too.
    package static func renderRegion(_ rect: CGRect, of ref: CGPDFPage, cropBox: CGRect, rotation: Int) -> AssistImage? {
        PDFKitGate.shared.run { drawRegion(rect, of: ref, cropBox: cropBox, rotation: rotation) }
    }

    private static func drawRegion(_ rect: CGRect, of ref: CGPDFPage, cropBox: CGRect, rotation: Int) -> AssistImage? {
        let visible = rect.standardized.intersection(cropBox.standardized)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        let turn = displayTransform(for: visible, rotation: rotation)
        let shown = CGRect(origin: .zero, size: turn.size)
        let scale = ReaderAnchor.renderScale(for: shown)
        let px = ReaderAnchor.pixelSize(for: shown, scale: scale)
        guard let ctx = CGContext(data: nil, width: Int(px.width), height: Int(px.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: px))
        ctx.scaleBy(x: px.width / shown.width, y: px.height / shown.height)
        ctx.concatenate(turn.transform)
        ctx.clip(to: visible)
        ctx.drawPDFPage(ref)
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return AssistImage(data: data as Data, mediaType: "image/png", pixelSize: px)
    }

    /// How `rect` (unrotated page space, y up) appears on screen for a page turned `rotation`
    /// degrees clockwise (PDF /Rotate): the size it is shown at (width and height swapped for 90 /
    /// 270) and the transform from page space onto that box (origin bottom-left, y up). Pure.
    package static func displayTransform(for rect: CGRect, rotation: Int) -> (size: CGSize, transform: CGAffineTransform) {
        let w = rect.width, h = rect.height
        let toOrigin = CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
        let turn: CGAffineTransform
        let size: CGSize
        switch normalizedRotation(rotation) {
        case 90:   // the left edge becomes the top: (x, y) → (y, w − x)
            turn = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
            size = CGSize(width: h, height: w)
        case 180:  // (x, y) → (w − x, h − y)
            turn = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
            size = CGSize(width: w, height: h)
        case 270:  // the top edge becomes the left: (x, y) → (h − y, x)
            turn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
            size = CGSize(width: h, height: w)
        default:
            turn = .identity
            size = CGSize(width: w, height: h)
        }
        return (size, toOrigin.concatenating(turn))
    }

    /// 0, 90, 180 or 270 (a /Rotate of -90 or 450 is 270 or 90; anything else, 0).
    package static func normalizedRotation(_ degrees: Int) -> Int {
        let r = ((degrees % 360) + 360) % 360
        return r % 90 == 0 ? r : 0
    }
}

/// Where a quote was found: the physical page and the range in that page's text (`PDFPage.string`,
/// UTF-16) — `PDFPage.selection(for:)` turns it into a highlight.
package struct ReaderQuoteMatch: Sendable, Equatable {
    package var page: Int
    package var range: NSRange
    /// The whole quote matched (not just a run of its words).
    package var exact: Bool
}

/// Finds a quote on or near a page (READING_ASSIST_PLAN §6.4: "go(to page) with quote highlight").
/// Only the target page and its neighbours are read (no whole-document search) unless there is no
/// target page. Owned by Slice C (reader).
package enum ReaderQuoteFinder {
    /// Searches `page` (physical; nil: the whole document, first match) and the pages within
    /// `tolerance`, for each of `ReaderQuote.candidates(quote)` in turn — joined-hyphen text first,
    /// then the text as printed. Each page's text is read inside `PDFKitGate`.
    package static func locate(_ quote: String, near page: Int?, in document: PDFDocument,
                               tolerance: Int = 1) -> ReaderQuoteMatch? {
        let candidates = ReaderQuote.candidates(quote)
        guard !candidates.isEmpty, document.pageCount > 0 else { return nil }
        let pages: [Int]
        if let page, let p = ReaderPages.clamp(page, pageCount: document.pageCount) {
            pages = Array(max(1, p - tolerance)...min(document.pageCount, p + tolerance))
        } else {
            pages = Array(1...document.pageCount)
        }
        var indexes: [Int: [ReaderTextIndex]] = [:]
        func index(_ n: Int) -> [ReaderTextIndex] {
            if let cached = indexes[n] { return cached }
            let text = PDFKitGate.shared.run { document.page(at: n - 1)?.string ?? "" }
            let built = [ReaderTextIndex(text, joinHyphens: true), ReaderTextIndex(text, joinHyphens: false)]
            indexes[n] = built
            return built
        }
        for (rank, candidate) in candidates.enumerated() {
            var hits: [(page: Int, range: NSRange)] = []
            for n in pages {
                if let r = index(n).lazy.compactMap({ $0.find(candidate) }).first { hits.append((n, r)) }
                if page == nil, !hits.isEmpty { break }
            }
            if let i = ReaderQuote.pick(matchPages: hits.map(\.page), target: page.flatMap {
                ReaderPages.clamp($0, pageCount: document.pageCount)
            }, tolerance: tolerance) {
                return ReaderQuoteMatch(page: hits[i].page, range: hits[i].range, exact: rank == 0)
            }
        }
        return nil
    }
}
