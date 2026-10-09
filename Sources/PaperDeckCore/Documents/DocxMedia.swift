import Compression
import Foundation

/// The pictures of a Word (.docx) package, in the order the document shows them — what Cocoa's
/// importer drops (Word's inline figures are DrawingML, which `NSAttributedString` doesn't read),
/// so a converted manuscript can still carry its figures (`DocumentConverter` appends them).
///
/// A minimal, read-only zip reader for untrusted input: the central directory is bounds-checked,
/// only stored and deflated entries are read, sizes are capped (a "zip bomb" is skipped, not
/// expanded), Zip64 and encrypted entries are ignored. Pure and synchronous.
package enum DocxMedia {
    /// Largest single entry inflated (a figure; document.xml of a long manuscript).
    package static let maxEntryBytes = 40 << 20
    /// Picture formats NSImage reads (EMF / WMF and the like are skipped).
    private static let pictureExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp", "heic", "webp"]

    /// The document's pictures (bytes), first appearance first, each at most once; at most
    /// `maxImages`, together at most `maxTotalBytes`. Empty for anything that isn't a readable package.
    package static func images(_ docx: Data, maxImages: Int = 60, maxTotalBytes: Int = 120 << 20) -> [Data] {
        let bytes = [UInt8](docx)
        guard let entries = centralDirectory(bytes) else { return [] }
        func read(_ name: String) -> Data? {
            guard let e = entries[name] else { return nil }
            return inflate(e, bytes)
        }
        guard let xml = read("word/document.xml").map({ String(decoding: $0, as: UTF8.self) }),
              let rels = read("word/_rels/document.xml.rels").map({ String(decoding: $0, as: UTF8.self) }) else { return [] }
        let targets = relationshipTargets(rels)
        var out: [Data] = []
        var seen = Set<String>()
        var total = 0
        for id in embeddedIDs(xml) {
            guard out.count < maxImages, let target = targets[id] else { continue }
            let name = resolve(target)
            guard pictureExtensions.contains((name as NSString).pathExtension.lowercased()), seen.insert(name).inserted,
                  let data = read(name), total + data.count <= maxTotalBytes else { continue }
            total += data.count
            out.append(data)
        }
        return out
    }

    // MARK: - Relationships

    /// `r:embed="rId5"` / `r:id="rId5"` in document order.
    static func embeddedIDs(_ xml: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"\br:(?:embed|id)="([^"]{1,64})""#)
        let ns = xml as NSString
        return re.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// Id → Target of the image relationships (`Type` ending in "/image"), external targets excluded.
    static func relationshipTargets(_ rels: String) -> [String: String] {
        let element = try! NSRegularExpression(pattern: #"<Relationship\b[^>]*>"#)
        let ns = rels as NSString
        var out: [String: String] = [:]
        for m in element.matches(in: rels, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            guard let id = attribute("Id", in: tag), let target = attribute("Target", in: tag),
                  let type = attribute("Type", in: tag), type.hasSuffix("/image"),
                  attribute("TargetMode", in: tag)?.lowercased() != "external" else { continue }
            out[id] = target
        }
        return out
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let r = tag.range(of: #"\b"# + name + #"="([^"]*)""#, options: .regularExpression) else { return nil }
        let value = tag[r].dropFirst(name.count + 2).dropLast()
        return String(value)
    }

    /// A relationship target of word/document.xml as a package path: relative to "word/"
    /// ("media/image1.png" → "word/media/image1.png"), or absolute ("/word/media/…"); "." and ".."
    /// resolved (never above the package root).
    static func resolve(_ target: String) -> String {
        let t = target.removingPercentEncoding ?? target
        let base = t.hasPrefix("/") ? String(t.dropFirst()) : "word/" + t
        var parts: [Substring] = []
        for c in base.split(separator: "/") {
            if c == "." { continue }
            if c == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(c)
        }
        return parts.joined(separator: "/")
    }

    // MARK: - Zip

    struct Entry {
        var method: Int
        var compressedSize: Int
        var size: Int
        var localOffset: Int
        var flags: Int
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> Int? { o >= 0 && o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : nil }
    private static func u32(_ b: [UInt8], _ o: Int) -> Int? {
        o >= 0 && o + 4 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 : nil
    }

    /// Name → entry, from the end-of-central-directory record (searched in the last 64 KiB + 22).
    static func centralDirectory(_ b: [UInt8]) -> [String: Entry]? {
        guard b.count >= 22 else { return nil }
        var eocd: Int?
        var i = b.count - 22
        let floor = max(0, b.count - 65_557)
        while i >= floor {
            if b[i] == 0x50, b[i + 1] == 0x4B, b[i + 2] == 0x05, b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard let e = eocd, let count = u16(b, e + 10), let cdSize = u32(b, e + 12), let cdOffset = u32(b, e + 16),
              count != 0xFFFF, cdOffset != 0xFFFF_FFFF, cdOffset + cdSize <= b.count else { return nil }
        var entries: [String: Entry] = [:]
        var p = cdOffset
        for _ in 0..<min(count, 20_000) {
            guard u32(b, p) == 0x0201_4B50, let flags = u16(b, p + 8), let method = u16(b, p + 10),
                  let csize = u32(b, p + 20), let size = u32(b, p + 24), let n = u16(b, p + 28),
                  let extra = u16(b, p + 30), let comment = u16(b, p + 32), let local = u32(b, p + 42),
                  p + 46 + n <= b.count else { break }
            let name = String(decoding: b[(p + 46)..<(p + 46 + n)], as: UTF8.self)
            entries[name] = Entry(method: method, compressedSize: csize, size: size, localOffset: local, flags: flags)
            p += 46 + n + extra + comment
        }
        return entries.isEmpty ? nil : entries
    }

    /// The entry's bytes: stored or deflated, not encrypted, within `maxEntryBytes`.
    static func inflate(_ e: Entry, _ b: [UInt8]) -> Data? {
        guard e.flags & 0x1 == 0, e.size <= maxEntryBytes, e.compressedSize <= b.count,
              u32(b, e.localOffset) == 0x0403_4B50, let n = u16(b, e.localOffset + 26),
              let extra = u16(b, e.localOffset + 28) else { return nil }
        let start = e.localOffset + 30 + n + extra
        guard start >= 0, start + e.compressedSize <= b.count else { return nil }
        let src = b[start..<(start + e.compressedSize)]
        switch e.method {
        case 0:
            return e.compressedSize == e.size ? Data(src) : nil
        case 8:
            guard e.size > 0 else { return Data() }
            var out = [UInt8](repeating: 0, count: e.size)
            let written = src.withUnsafeBufferPointer { s -> Int in
                out.withUnsafeMutableBufferPointer { d -> Int in
                    guard let sb = s.baseAddress, let db = d.baseAddress else { return 0 }
                    return compression_decode_buffer(db, e.size, sb, e.compressedSize, nil, COMPRESSION_ZLIB)
                }
            }
            return written == e.size ? Data(out) : nil
        default:
            return nil
        }
    }
}
