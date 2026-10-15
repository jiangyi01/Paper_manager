import Foundation
import ImageIO

/// Card thumbnails (`caches/thumbs/<id>@2x.jpg`, the extractor's 560×240 q0.75 crop) and
/// the widget's smaller copies (`support/widget/thumbs/<id>.jpg`, ≤ 240 px wide, q0.7),
/// which the sandboxed widget can read (§5, §6.6). Both are regenerable from the PDF.
/// Synchronous file I/O and ImageIO work: call from `BlockingIO.run`.
package struct ThumbnailStore: Sendable {
    package static let widgetMaxWidth = 240
    package static let widgetQuality = 0.7

    package let cardDirectory: URL
    package let widgetDirectory: URL

    package init(cardDirectory: URL, widgetDirectory: URL) {
        self.cardDirectory = cardDirectory
        self.widgetDirectory = widgetDirectory
    }

    package init(paths: AppPaths) {
        self.init(cardDirectory: paths.thumbnails, widgetDirectory: paths.widgetThumbs)
    }

    package func cardURL(for id: String) -> URL { cardDirectory.appendingPathComponent("\(id)@2x.jpg") }
    package func widgetURL(for id: String) -> URL { widgetDirectory.appendingPathComponent("\(id).jpg") }

    // MARK: Versioned card URLs (the card grid's in-memory image cache is keyed by URL)

    /// A replace, a duplicate merge or their Undo rewrites `<id>@2x.jpg` in place: the version (the
    /// file's modification time in µs and its size) tells the copies apart.
    package static func version(modified: Date?, size: Int?) -> String {
        let micros = modified.map { Int64(($0.timeIntervalSince1970 * 1_000_000).rounded()) } ?? 0
        return "\(micros)-\(size ?? 0)"
    }

    /// `url` with `version` as its fragment (`…/<id>@2x.jpg#v=<version>`): what `PaperRow.thumbnailURL`
    /// carries, so a rewritten thumbnail is a new URL (a new cache key, a new `.task(id:)`).
    package static func versioned(_ url: URL, version: String) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.fragment = "v=" + version
        return c.url ?? url
    }

    /// The file a (versioned) thumbnail URL names: the same path without the fragment.
    package static func unversioned(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        return URL(fileURLWithPath: url.path, isDirectory: false)
    }

    /// Stores the card JPEG and derives the widget thumbnail from it. Rejects data that
    /// ImageIO can't decode before writing anything.
    package func save(cardJPEG: Data, id: String) throws {
        try Self.checkID(id)
        guard let widget = Self.downscaledJPEG(cardJPEG, maxWidth: Self.widgetMaxWidth, quality: Self.widgetQuality) else {
            throw FileOpsError.io("thumbnail is not a decodable image")
        }
        try Self.write(cardJPEG, to: cardURL(for: id), in: cardDirectory)
        try Self.write(widget, to: widgetURL(for: id), in: widgetDirectory)
    }

    /// Re-derives the widget thumbnail from an existing card thumbnail (e.g. after the
    /// widget folder was cleared). False if there is no usable card thumbnail.
    @discardableResult
    package func regenerateWidgetThumbnail(id: String) throws -> Bool {
        try Self.checkID(id)
        guard let card = try? Data(contentsOf: cardURL(for: id)),
              let widget = Self.downscaledJPEG(card, maxWidth: Self.widgetMaxWidth, quality: Self.widgetQuality)
        else { return false }
        try Self.write(widget, to: widgetURL(for: id), in: widgetDirectory)
        return true
    }

    package func existingCardURL(for id: String) -> URL? {
        guard (try? Self.checkID(id)) != nil else { return nil }
        let url = cardURL(for: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    package func existingWidgetURL(for id: String) -> URL? {
        guard (try? Self.checkID(id)) != nil else { return nil }
        let url = widgetURL(for: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Removes both thumbnails; missing files are fine.
    package func delete(id: String) {
        guard (try? Self.checkID(id)) != nil else { return }
        try? FileManager.default.removeItem(at: cardURL(for: id))
        try? FileManager.default.removeItem(at: widgetURL(for: id))
    }

    /// Σ logical size of card and widget thumbnails.
    package func totalSize() -> Int64 {
        Self.directorySize(cardDirectory) + Self.directorySize(widgetDirectory)
    }

    /// JPEG at most `maxWidth` pixels wide (aspect preserved, never upscaled); nil if
    /// `data` is not a decodable image.
    package static func downscaledJPEG(_ data: Data, maxWidth: Int, quality: Double) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, maxWidth > 0
        else { return nil }

        let targetWidth = min(width, maxWidth)
        let targetHeight = max(1, Int((Double(height) * Double(targetWidth) / Double(width)).rounded()))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(targetWidth, targetHeight),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private static func write(_ data: Data, to url: URL, in directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw FileOps.classify(error)
        }
    }

    private static func directorySize(_ dir: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        return files.reduce(Int64(0)) { sum, file in
            sum + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    /// Ids become file names, so only [A-Za-z0-9_-] is allowed (no "..", no "/").
    private static func checkID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 128,
              id.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") })
        else { throw FileOpsError.io("invalid paper id \(id.debugDescription)") }
    }
}
