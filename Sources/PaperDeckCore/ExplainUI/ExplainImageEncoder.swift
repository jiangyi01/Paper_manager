import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image for one Explain turn (`AssistImage`: PNG or JPEG, long edge ≤ 1568 px — plan §4): a
/// dropped or pasted image, a ⌃⇧⌘4 screenshot from the clipboard. Larger images are scaled down
/// (never up: a small formula stays sharp at its native size); PNG keeps text and line art crisp,
/// JPEG (q 0.85) is used only when the PNG would pass `pngLimit`. Pure (CoreGraphics + ImageIO, no
/// screen); owned by the Explain UI lane (A2).
package enum ExplainImageEncoder {
    /// A PNG larger than this is re-encoded as JPEG.
    package static let pngLimit = 1_000_000
    package static let jpegQuality = 0.85
    /// Files larger than this are not read for Explain (a drop of a huge photo).
    package static let maxInputBytes = 40_000_000

    /// The pixel size an image of `size` is sent at.
    package static func targetSize(for size: CGSize, maxLongEdge: CGFloat = AssistImage.maxLongEdge) -> CGSize {
        let long = max(size.width, size.height)
        guard long > maxLongEdge, long > 0 else { return CGSize(width: size.width.rounded(), height: size.height.rounded()) }
        let s = maxLongEdge / long
        return CGSize(width: max(1, min(maxLongEdge, (size.width * s).rounded())),
                      height: max(1, min(maxLongEdge, (size.height * s).rounded())))
    }

    /// `image` as a turn's image; nil for an empty one or when encoding fails.
    package static func encode(_ image: CGImage) -> AssistImage? {
        guard image.width > 0, image.height > 0 else { return nil }
        let target = targetSize(for: CGSize(width: image.width, height: image.height))
        let scaled = (Int(target.width) == image.width && Int(target.height) == image.height) ? image : scale(image, to: target)
        guard let scaled else { return nil }
        let size = CGSize(width: scaled.width, height: scaled.height)
        if let png = data(scaled, type: .png, quality: nil), png.count <= pngLimit {
            return AssistImage(data: png, mediaType: "image/png", pixelSize: size)
        }
        guard let jpeg = data(scaled, type: .jpeg, quality: jpegQuality) else { return nil }
        return AssistImage(data: jpeg, mediaType: "image/jpeg", pixelSize: size)
    }

    /// Image file bytes (PNG, JPEG, TIFF, HEIC, GIF — the first frame) as a turn's image.
    package static func encode(data: Data) -> AssistImage? {
        guard !data.isEmpty, data.count <= maxInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        // Let ImageIO build a thumbnail at the target size (honours the EXIF orientation, cheap for huge files).
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(AssistImage.maxLongEdge),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encode(image)
    }

    private static func scale(_ image: CGImage, to size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func data(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

/// Which drops go to Explain (LN §3 T7, plan §6.2): a drag whose every file is an image (a
/// screenshot thumbnail, PNG / JPEG / TIFF / HEIC files) is explained instead of imported. A PDF, a
/// folder, an email or any other file anywhere in the drag keeps today's import (and its toasts)
/// exactly. Pure; owned by the Explain UI lane (A2).
package enum ExplainDropRules {
    /// At most this many images in one drop (one turn takes one image: the first is explained).
    package static let maxImages = 1

    /// True when `types` (one per dragged file, nil when unknown) are all images — and there is one.
    package static func isAllImages(_ types: [UTType?]) -> Bool {
        !types.isEmpty && types.allSatisfy { t in
            guard let t else { return false }
            return t.conforms(to: .image) && !t.conforms(to: .pdf)
        }
    }

    /// The type of a file name (by extension) — for promised files that arrive without a content type.
    package static func type(ofFileNamed name: String) -> UTType? {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : UTType(filenameExtension: ext)
    }

    /// Raw image data on a drag pasteboard (no file URLs, no promises): the types Explain reads.
    package static let imageDataTypes: [String] = ["public.png", "public.tiff", "public.jpeg"]
}
