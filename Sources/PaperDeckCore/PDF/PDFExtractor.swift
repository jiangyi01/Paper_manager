import AppKit
import CoreGraphics
import Foundation
@preconcurrency import PDFKit

/// PDFKit extraction for one file (§3.4, §6.1 [抽取]): per-page text, attributes, outline,
/// lock/scan state, local title, identifiers, section structure and the card thumbnail.
///
/// Every call opens its own document on `BlockingIO` (PDFKit is not documented as thread-safe, so
/// a document is never shared with a view or another task) and uses it inside `PDFKitGate` one step
/// at a time: each page's text, the title, the thumbnail. Other PDFKit work (another import, the
/// reader's find, Q&A) runs between those steps, never at the same moment (the "nil NSFont" crash).
package struct PDFExtractor: Sendable {

    package enum ExtractError: Error, Sendable, Equatable {
        case notPDF                     // no "%PDF-" in the first 1 KB
        case unreadable                 // PDFKit could not open it
        case fileUnavailable(String)    // could not read the file at all
    }

    /// Bytes read up front: the %PDF- check uses the first 1 KB, the XMP DOI scan all of it.
    package static let headLength = 256 * 1024

    /// Card thumbnail size in pixels (2× a 280×120 pt card area).
    package static let thumbnailSize = (width: 560, height: 240)

    package init() {}

    /// PDFs may carry junk before the header; readers accept "%PDF-" anywhere in the first 1 KB.
    package static func isPDF(fileHead: Data) -> Bool {
        fileHead.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
    }

    /// Throws `ExtractError`. A password-protected file is not an error: it comes back with
    /// `isLocked == true` and no text.
    package func extract(url: URL, fileName: String) async throws -> ExtractedPDF {
        try await BlockingIO.run { try Self.extractBlocking(url: url, fileName: fileName) }
    }

    static func extractBlocking(url: URL, fileName: String) throws -> ExtractedPDF {
        let head: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            head = try handle.read(upToCount: headLength) ?? Data()
        } catch {
            throw ExtractError.fileUnavailable(error.localizedDescription)
        }
        guard isPDF(fileHead: head) else { throw ExtractError.notPDF }
        // A zero-page document can't produce a card; locked ones may report 0 until unlocked.
        guard let doc = GatedPDFDocument(url: url),
              let opened = doc.with({ d -> (encrypted: Bool, locked: Bool, pages: Int, title: String?, author: String?)? in
                  guard d.pageCount > 0 || d.isLocked else { return nil }
                  let isEncrypted = d.isEncrypted
                  if d.isLocked { _ = d.unlock(withPassword: "") }
                  let attributes = d.documentAttributes ?? [:]
                  return (isEncrypted, d.isLocked, d.pageCount, attributes[PDFDocumentAttribute.titleAttribute] as? String,
                          authorString(attributes[PDFDocumentAttribute.authorAttribute]))
              })
        else { throw ExtractError.unreadable }

        let isEncrypted = opened.encrypted
        let isLocked = opened.locked
        let pageCount = opened.pages
        let rawTitle = opened.title
        let author = opened.author

        guard !isLocked else {
            return ExtractedPDF(pageCount: pageCount, pageTexts: [], charCount: 0, isEncrypted: isEncrypted,
                                isLocked: true, isScanned: false,
                                attributeTitle: TitleHeuristic.cleanAttributeTitle(rawTitle), attributeAuthor: author,
                                fontTitle: nil,
                                ids: Identifiers.detect(fileName: fileName, firstPagesText: "", attributeTitle: rawTitle, xmpHead: head),
                                structure: DocumentStructure(), cardThumbnailJPEG: nil)
        }

        var pageTexts: [String] = []
        pageTexts.reserveCapacity(pageCount)
        for i in 0..<pageCount {
            pageTexts.append(doc.with { $0.page(at: i)?.string ?? "" })      // one page per turn at the gate
        }
        let charCount = pageTexts.reduce(0) { $0 + $1.count }
        let isScanned = pageCount > 0 && Double(charCount) / Double(pageCount) < 200

        let attributeTitle = TitleHeuristic.cleanAttributeTitle(rawTitle)
        var fontTitle: String? = doc.with { $0.page(at: 0).flatMap(TitleHeuristic.title(of:)) }
        // Same words as the attribute title → keep the attribute's punctuation, which the font
        // run loses at line breaks ("LABBench2\nAn Improved…" vs "LABBench2: An Improved…").
        if let f = fontTitle, let a = attributeTitle, TitleHeuristic.sameWords(f, a) { fontTitle = a }
        let thumbnail: Data? = doc.with { $0.page(at: 0).flatMap(cardThumbnailJPEG(page:)) }
        let outline = doc.with { topLevelOutline($0) }

        let ids = Identifiers.detect(fileName: fileName, firstPagesText: pageTexts.prefix(2).joined(separator: "\n"),
                                     attributeTitle: rawTitle, xmpHead: head)
        let structure = Sections.analyze(pageTexts: pageTexts, outline: outline.isEmpty ? nil : outline)

        return ExtractedPDF(pageCount: pageCount, pageTexts: pageTexts, charCount: charCount,
                            isEncrypted: isEncrypted, isLocked: false, isScanned: isScanned,
                            attributeTitle: attributeTitle, attributeAuthor: author,
                            fontTitle: fontTitle, ids: ids, structure: structure, cardThumbnailJPEG: thumbnail)
    }

    /// Top-level outline as (label, 1-based page). Journal PDFs often nest every section under
    /// one entry holding the title; then that entry's children are the real top level. Inside `PDFKitGate`.
    static func topLevelOutline(_ doc: PDFDocument) -> [(title: String, page: Int)] {
        PDFKitGate.shared.run { outline(doc) }
    }

    private static func outline(_ doc: PDFDocument) -> [(title: String, page: Int)] {
        guard var level = doc.outlineRoot else { return [] }
        if level.numberOfChildren == 1, let only = level.child(at: 0), only.numberOfChildren >= 3 { level = only }
        var out: [(title: String, page: Int)] = []
        for i in 0..<level.numberOfChildren {
            guard let item = level.child(at: i),
                  let label = item.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
                  let page = item.destination?.page ?? (item.action as? PDFActionGoTo)?.destination.page
            else { continue }
            let index = doc.index(for: page)
            guard index >= 0, index < doc.pageCount else { continue }
            out.append((label, index + 1))
        }
        return out
    }

    /// Page 1 rendered 560 px wide at its own aspect ratio, top 240 px kept, JPEG q0.75. Drawing
    /// resolves the page's fonts, so it runs inside `PDFKitGate`.
    static func cardThumbnailJPEG(page: PDFPage) -> Data? {
        PDFKitGate.shared.run { thumbnailJPEG(page) }
    }

    private static func thumbnailJPEG(_ page: PDFPage) -> Data? {
        var box = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { box = NSSize(width: box.height, height: box.width) }
        guard box.width > 1, box.height > 1 else { return nil }
        let (width, height) = thumbnailSize
        let fullHeight = (CGFloat(width) * box.height / box.width).rounded()
        let image = page.thumbnail(of: NSSize(width: CGFloat(width), height: fullHeight), for: .cropBox)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        // CoreGraphics' origin is bottom-left: shift the page down so its top edge is kept.
        ctx.draw(cg, in: CGRect(x: 0, y: CGFloat(height) - fullHeight, width: CGFloat(width), height: fullHeight))
        guard let cropped = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cropped).representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }

    private static func authorString(_ value: Any?) -> String? {
        let raw: String?
        if let s = value as? String { raw = s }
        else if let list = value as? [String] { raw = list.joined(separator: "; ") }
        else { raw = nil }
        let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }
}
