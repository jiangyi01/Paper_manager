import CoreGraphics
import Foundation
@testable import PaperDeckCore

/// Synthetic displays for the capture / panel fixes (fix-capture-ux): drawn in memory with
/// CoreGraphics in display-local points (top-left origin, y down) at a pixel scale — never a screen.
enum UXKit {
    /// A display of `size` points at `scale` pixels per point, white, with `draw` called in points.
    static func display(_ size: CGSize, scale: CGFloat = 2, fill: CGFloat = 1, _ draw: (CGContext) -> Void = { _ in }) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: fill, green: fill, blue: fill, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Points, top-left origin.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        draw(ctx)
        return ctx.makeImage()
    }

    /// "Text" lines: dark bars `lineHeight` tall with `gap` between them, filling `rect`.
    static func paragraph(_ ctx: CGContext, _ rect: CGRect, lineHeight: CGFloat = 10, gap: CGFloat = 6) {
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        var y = rect.minY
        while y + lineHeight <= rect.maxY {
            ctx.fill(CGRect(x: rect.minX, y: y, width: rect.width, height: lineHeight))
            y += lineHeight + gap
        }
    }

    /// A bar chart inside `rect`: two thin axes, four bars on the x axis.
    static func chart(_ ctx: CGContext, _ rect: CGRect) {
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height))            // y axis
        ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1))          // x axis
        ctx.setFillColor(CGColor(red: 0.3, green: 0.4, blue: 0.7, alpha: 1))
        let barW = rect.width / 9
        for (i, f) in [0.4, 0.9, 0.65, 0.25].enumerated() {
            let h = rect.height * f
            ctx.fill(CGRect(x: rect.minX + barW * (1 + 2 * CGFloat(i)), y: rect.maxY - 1 - h, width: barW, height: h))
        }
    }

    /// The still's pixels of a display-local rect (what `CaptureGeometry.crop` gives the overlay).
    static func cropper(_ image: CGImage, scale: CGFloat = 2) -> (CGRect) -> CGImage? {
        { r in
            let px = CaptureGeometry.snap(CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale),
                                          within: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return px.width >= 1 && px.height >= 1 ? image.cropping(to: px) : nil
        }
    }

    /// A unit rect of a band (`ExplainFocus.fallback`) back in display-local points.
    static func points(_ unit: CGRect, in band: CGRect) -> CGRect {
        CGRect(x: band.minX + unit.minX * band.width, y: band.minY + unit.minY * band.height,
               width: unit.width * band.width, height: unit.height * band.height)
    }

    /// The page the click tests use (1000 × 700 points): a paragraph top-left, a chart right.
    static let size = CGSize(width: 1000, height: 700)
    static let paragraphRect = CGRect(x: 60, y: 100, width: 420, height: 120)
    static let chartRect = CGRect(x: 560, y: 300, width: 340, height: 260)

    static func page() -> CGImage? {
        display(size) { ctx in
            paragraph(ctx, paragraphRect)
            chart(ctx, chartRect)
        }
    }
}
