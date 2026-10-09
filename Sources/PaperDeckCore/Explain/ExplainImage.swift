import CoreGraphics
import Foundation
import ImageIO

/// A capture as the one image of a turn (dive-cli §7): downscaled to ≤ 1568 px on the long edge
/// and ≤ 1.15 MP — never upscaled, so a small formula keeps its native (Retina) pixels — then PNG
/// (sharp text and lines), or JPEG q 0.85 on white when the PNG is over 1.5 MB, shrinking further
/// until it fits. In memory only: the backend writes it to its job directory and deletes it.
package enum ExplainImage {
    package static let maxLongEdge = Int(AssistImage.maxLongEdge)
    package static let maxPixels = 1_150_000
    package static let maxBytes = 1_500_000
    package static let jpegQuality = 0.85

    /// The size an image of `size` pixels is sent at (the same size when it already fits).
    package static func targetSize(for size: CGSize) -> CGSize {
        let w = max(size.width.rounded(.down), 1), h = max(size.height.rounded(.down), 1)
        var f = min(1, CGFloat(maxLongEdge) / max(w, h))
        f = min(f, (CGFloat(maxPixels) / (w * h)).squareRoot())
        guard f < 1 else { return CGSize(width: w, height: h) }
        return CGSize(width: max((w * f).rounded(.down), 1), height: max((h * f).rounded(.down), 1))
    }

    /// The turn's image, or nil when it can't be encoded within the limits.
    package static func prepare(_ image: CGImage) -> AssistImage? {
        let target = targetSize(for: CGSize(width: image.width, height: image.height))
        guard var current = target.width == CGFloat(image.width) && target.height == CGFloat(image.height)
                ? image : scaled(image, to: target) else { return nil }
        if let png = png(current), png.count <= maxBytes {
            return AssistImage(data: png, mediaType: "image/png", pixelSize: CGSize(width: current.width, height: current.height))
        }
        for _ in 0..<5 {
            if let jpeg = jpeg(current, quality: jpegQuality), jpeg.count <= maxBytes {
                return AssistImage(data: jpeg, mediaType: "image/jpeg",
                                   pixelSize: CGSize(width: current.width, height: current.height))
            }
            let smaller = CGSize(width: max((CGFloat(current.width) * 0.8).rounded(.down), 1),
                                 height: max((CGFloat(current.height) * 0.8).rounded(.down), 1))
            guard let next = scaled(current, to: smaller) else { return nil }
            current = next
        }
        return nil
    }

    /// `image` redrawn at `size` (sRGB, high-quality interpolation, on white: no alpha survives).
    package static func scaled(_ image: CGImage, to size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    package static func png(_ image: CGImage) -> Data? { encode(image, type: "public.png", options: nil) }

    package static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        // JPEG has no alpha: flatten on white first.
        guard let flat = scaled(image, to: CGSize(width: image.width, height: image.height)) else { return nil }
        return encode(flat, type: "public.jpeg", options: [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    }

    private static func encode(_ image: CGImage, type: String, options: CFDictionary?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, options)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Mean and standard deviation of the luminance (0…1) on a small sample grid: a protected
    /// (DRM) window or a sleeping display comes back as one flat colour (deviation ≈ 0).
    package static func luminance(_ image: CGImage, grid: Int = 32) -> (mean: Double, deviation: Double)? {
        let n = max(2, grid)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let raw = ctx.data else { return nil }
        let px = raw.bindMemory(to: UInt8.self, capacity: n * n * 4)
        var values: [Double] = []
        values.reserveCapacity(n * n)
        for i in 0..<(n * n) {
            let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
            values.append((0.2126 * r + 0.7152 * g + 0.0722 * b) / 255)
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return (mean, variance.squareRoot())
    }

    /// One flat colour: nothing legible was captured (CUX-8) — a protected (DRM) window comes back
    /// black, a sleeping display too; the overlay says so and sends nothing (`ExplainImageCrop`).
    /// Every pixel is checked against the background (`InkMap`), so a single word in a large white box
    /// still counts as content — the 32-cell average deviation used before could call a sparse
    /// capture blank.
    package static func isBlank(_ image: CGImage) -> Bool { CaptureFigure.isBlank(image) }

    /// `image`'s pixels in a bitmap of their own (CUX-7). A crop (`CGImage.cropping`) keeps its whole
    /// source alive — a display's still, about 60 MB at 5K — for as long as the crop lives; a capture's
    /// OCR copy is kept with its panel, so it is copied out and the still goes with the overlay. Its
    /// own RGB colour space when it has one (else sRGB); nil for an empty image.
    package static func detached(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let own = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        for space in [own, CGColorSpace(name: CGColorSpace.sRGB)].compactMap({ $0 }) {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: info) else { continue }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()
        }
        return nil
    }
}
