import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PaperDeckCore

private func makeTempDir(_ tag: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pd-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct TextStoreTests {
    private let id = "0f8fad5b-d9cb-469f-a165-70867728950e"

    @Test func roundTripCompressesAndRestores() throws {
        let dir = try makeTempDir("text")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TextStore(directory: dir.appendingPathComponent("text"))   // created on first save
        let page = "Single-cell atlas of the developing neocortex — 单细胞 🧬 \u{0C}"
        let text = String(repeating: page, count: 2_000)

        try store.save(text, id: id)
        let file = store.url(for: id)
        #expect(file.lastPathComponent == "\(id).txt.lzfse")
        #expect(store.exists(id: id))
        let onDisk = try #require(FileOps.fileSize(file))
        #expect(onDisk < Int64(text.utf8.count / 10))                    // repetitive text compresses well
        #expect(try store.load(id: id) == text)
        #expect(store.totalSize() == onDisk)

        try store.save("", id: "empty")
        #expect(try store.load(id: "empty") == "")

        #expect(store.delete(id: id))
        #expect(!store.delete(id: id))
        #expect(try store.load(id: id) == nil)
    }

    @Test func corruptOrHostileInput() throws {
        let dir = try makeTempDir("text")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TextStore(directory: dir)
        try Data("definitely not lzfse".utf8).write(to: store.url(for: id))
        #expect(throws: FileOpsError.self) { try store.load(id: id) }

        #expect(throws: FileOpsError.self) { try store.save("x", id: "../escape") }
        #expect(throws: FileOpsError.self) { try store.load(id: "a/b") }
        #expect(!FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("escape.txt.lzfse").path))
        #expect(TextStore(paths: .rooted(at: dir)).directory == dir.appendingPathComponent("Support/text", isDirectory: true))
    }
}

@Suite struct ThumbnailStoreTests {
    private let id = "0f8fad5b-d9cb-469f-a165-70867728950e"

    private static func jpeg(width: Int, height: Int) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 3))
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private static func pixelSize(_ url: URL) throws -> (Int, Int) {
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        return (try #require(props[kCGImagePropertyPixelWidth] as? Int), try #require(props[kCGImagePropertyPixelHeight] as? Int))
    }

    @Test func savesCardAndDerivesWidgetThumbnail() throws {
        let root = try makeTempDir("thumbs")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths.rooted(at: root)
        let store = ThumbnailStore(paths: paths)
        let card = try Self.jpeg(width: 560, height: 240)

        try store.save(cardJPEG: card, id: id)
        #expect(store.cardURL(for: id) == paths.thumbnails.appendingPathComponent("\(id)@2x.jpg"))
        #expect(store.widgetURL(for: id) == paths.widgetThumbs.appendingPathComponent("\(id).jpg"))
        #expect(try Data(contentsOf: store.cardURL(for: id)) == card)
        let (w, h) = try Self.pixelSize(store.widgetURL(for: id))
        #expect(w == 240)
        #expect((102...103).contains(h))
        #expect(store.existingCardURL(for: id) != nil)
        #expect(store.existingWidgetURL(for: id) != nil)
        let total = store.totalSize()
        #expect(total == (FileOps.fileSize(store.cardURL(for: id)) ?? 0) + (FileOps.fileSize(store.widgetURL(for: id)) ?? 0))

        try FileManager.default.removeItem(at: store.widgetURL(for: id))
        #expect(try store.regenerateWidgetThumbnail(id: id))
        #expect(store.existingWidgetURL(for: id) != nil)

        store.delete(id: id)
        #expect(store.existingCardURL(for: id) == nil)
        #expect(store.existingWidgetURL(for: id) == nil)
        #expect(store.totalSize() == 0)
        #expect(try store.regenerateWidgetThumbnail(id: id) == false)
    }

    @Test func widgetWidthCapAndNoUpscale() throws {
        let portrait = try #require(ThumbnailStore.downscaledJPEG(try Self.jpeg(width: 600, height: 900),
                                                                  maxWidth: 240, quality: 0.7))
        let src = try #require(CGImageSourceCreateWithData(portrait as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 240)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 360)

        let small = try #require(ThumbnailStore.downscaledJPEG(try Self.jpeg(width: 120, height: 60), maxWidth: 240, quality: 0.7))
        let s2 = try #require(CGImageSourceCreateWithData(small as CFData, nil))
        let p2 = try #require(CGImageSourceCopyPropertiesAtIndex(s2, 0, nil) as? [CFString: Any])
        #expect(p2[kCGImagePropertyPixelWidth] as? Int == 120)
    }

    @Test func rejectsGarbageAndBadIDs() throws {
        let root = try makeTempDir("thumbs")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ThumbnailStore(cardDirectory: root.appendingPathComponent("c"), widgetDirectory: root.appendingPathComponent("w"))
        #expect(throws: FileOpsError.self) { try store.save(cardJPEG: Data("nope".utf8), id: id) }
        #expect(!FileManager.default.fileExists(atPath: store.cardURL(for: id).path))
        #expect(throws: FileOpsError.self) { try store.save(cardJPEG: try Self.jpeg(width: 10, height: 10), id: "../x") }
        #expect(ThumbnailStore.downscaledJPEG(Data(), maxWidth: 240, quality: 0.7) == nil)
    }
}
