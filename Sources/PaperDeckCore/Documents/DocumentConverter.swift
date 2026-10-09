import AppKit
import Foundation
import PaperDeckShared

/// Why a document could not be converted (the UI shows `message(_:)`, en/zh). Never carries the
/// file's name or content.
package enum DocumentConversionError: Error, Sendable, Equatable {
    case unsupported        // slides / Pages / anything not a Word, RTF or ODT text document
    case encrypted          // password-protected
    case unreadable         // damaged, or not the format its name says
    case empty              // no text and nothing else to show
    case tooLarge           // over the size or page limit
    case renderFailed       // the PDF could not be written

    package func message(_ lang: UILang) -> String {
        let zh = lang == .zh
        switch self {
        case .unsupported:
            return zh ? "这种文件无法在本机转换：请打开它，导出 PDF 后拖到这一行"
                      : "This kind of file can't be converted here — open it, export a PDF and drop it on this row"
        case .encrypted:
            return zh ? "文档有密码保护：请打开它，导出 PDF 后拖到这一行"
                      : "The document is password-protected — open it, export a PDF and drop it on this row"
        case .unreadable:
            return zh ? "无法读取这个文档（可能已损坏或有密码保护）：请打开它，导出 PDF 后拖到这一行"
                      : "Couldn't read the document (it may be damaged or password-protected) — open it, export a PDF and drop it on this row"
        case .empty:
            return zh ? "文档中没有可转换的文字" : "The document has no text to convert"
        case .tooLarge:
            return zh ? "文档太大，无法在本机转换：请打开它，导出 PDF 后拖到这一行"
                      : "The document is too large to convert here — open it, export a PDF and drop it on this row"
        case .renderFailed:
            return zh ? "无法生成 PDF" : "Couldn't create the PDF"
        }
    }
}

/// Paper size of converted documents: US Letter where it is the norm, A4 elsewhere.
package enum PaperSize: String, Sendable, CaseIterable, Equatable {
    case a4, letter

    /// Width × height in PostScript points.
    package var points: CGSize {
        switch self {
        case .a4: return CGSize(width: 595.28, height: 841.89)
        case .letter: return CGSize(width: 612, height: 792)
        }
    }

    /// Regions whose standard paper is US Letter.
    package static let letterRegions: Set<String> = [
        "US", "CA", "MX", "CL", "CO", "CR", "DO", "SV", "GT", "PA", "PH", "PR", "VE", "NI", "BZ",
    ]

    /// Letter for `letterRegions`, A4 for every other (or an unknown) region.
    package static func forRegion(_ region: String?) -> PaperSize {
        guard let r = region?.uppercased(), letterRegions.contains(r) else { return .a4 }
        return .letter
    }

    /// The Mac's region (Settings ▸ General ▸ Language & Region).
    package static var current: PaperSize { forRegion(Locale.current.region?.identifier) }
}

/// Converts a Word (.docx / .doc), RTF or OpenDocument text file to a paginated PDF on this Mac —
/// nothing goes to the network or to an AI. Reading is Cocoa's document importer
/// (`NSAttributedString`), layout is TextKit 1 (`NSLayoutManager` with one text container per page),
/// drawing is Core Graphics' PDF context. The importer keeps text, fonts, colours, paragraph
/// styles, lists and tables; it drops what it cannot import — notably Word's inline figures
/// (DrawingML): for a .docx those pictures are read from the package (`DocxMedia`) and appended
/// after the text under a "Figures" heading, in document order; formats NSImage can't draw (EMF,
/// charts) are lost — the UI says so (`MailDocumentText.conversionCaveat`). Images are scaled
/// down to fit the page.
///
/// Everything happens in one synchronous call on the caller's thread: run it off the main thread
/// (`convert(fileAt:…)` uses `BlockingIO`). The AppKit objects it creates never leave the call.
/// Objective-C exceptions from the frameworks are caught (a damaged file must not crash the app).
package enum DocumentConverter {
    package struct Options: Sendable, Equatable {
        package var paper: PaperSize
        /// Page margin on every side (points).
        package var margin: CGFloat
        /// A document needing more pages is refused (`tooLarge`).
        package var maxPages: Int
        /// A file larger than this is refused (`tooLarge`).
        package var maxBytes: Int
        /// Heading of the appended figures of a .docx (`MailDocumentText.figuresHeading`).
        package var figuresHeading: String

        package init(paper: PaperSize = .current, margin: CGFloat = 72, maxPages: Int = 1_500,
                     maxBytes: Int = 100 << 20, figuresHeading: String = "Figures from the original document") {
            self.paper = paper; self.margin = margin; self.maxPages = max(1, maxPages); self.maxBytes = maxBytes
            self.figuresHeading = figuresHeading
        }
    }

    package struct Output: Sendable, Equatable {
        package var pdf: Data
        package var pageCount: Int
        /// Images / attachments the importer provided (and that were drawn).
        package var images: Int
    }

    /// Reads `url` and converts it (off the caller's executor).
    package static func convert(fileAt url: URL, kind: DocumentKind, options: Options = Options()) async throws -> Output {
        try await BlockingIO.run {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= options.maxBytes else { throw DocumentConversionError.tooLarge }
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                throw DocumentConversionError.unreadable
            }
            return try convert(data, kind: kind, options: options)
        }
    }

    /// The conversion itself (synchronous; call it off the main thread).
    package static func convert(_ data: Data, kind: DocumentKind, options: Options = Options()) throws -> Output {
        guard kind.isConvertible else { throw DocumentConversionError.unsupported }
        guard data.count <= options.maxBytes else { throw DocumentConversionError.tooLarge }
        guard !data.isEmpty, kind.hasValidSignature(data) else { throw DocumentConversionError.unreadable }
        if kind.isEncryptedPackage(data) || (kind == .doc && isEncryptedWordBinary(data)) {
            throw DocumentConversionError.encrypted
        }
        var attributed = try read(data, kind: kind)
        let hasText = !attributed.string.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            .replacingOccurrences(of: "\u{FFFC}", with: "").isEmpty
        var images = attachmentCount(attributed)
        if kind == .docx, images == 0 {
            // The importer dropped Word's figures: bring them back after the text.
            let figures = DocxMedia.images(data).compactMap(NSImage.init(data:)).filter { $0.size.width > 0 && $0.size.height > 0 }
            if !figures.isEmpty {
                attributed = appendFigures(figures, to: attributed, heading: options.figuresHeading)
                images = figures.count
            }
        }
        guard hasText || images > 0 else { throw DocumentConversionError.empty }
        return try render(attributed, options: options, images: images)
    }

    /// The text, a page break, the heading and one picture per paragraph.
    static func appendFigures(_ figures: [NSImage], to text: NSAttributedString, heading: String) -> NSAttributedString {
        let s = NSMutableAttributedString(attributedString: text)
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11)]
        if !s.string.hasSuffix("\n") { s.append(NSAttributedString(string: "\n", attributes: body)) }
        s.append(NSAttributedString(string: "\u{000C}", attributes: body))                // next page
        s.append(NSAttributedString(string: heading + "\n\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]))
        for image in figures {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(origin: .zero, size: image.size)
            s.append(NSAttributedString(attachment: attachment))
            s.append(NSAttributedString(string: "\n\n", attributes: body))
        }
        return s
    }

    // MARK: - Reading

    private static func documentType(_ kind: DocumentKind) -> NSAttributedString.DocumentType? {
        switch kind {
        case .docx: return .officeOpenXML
        case .doc: return .docFormat
        case .rtf: return .rtf
        case .odt: return .openDocument
        case .pptx, .ppt, .key, .pages, .odp: return nil
        }
    }

    private static func read(_ data: Data, kind: DocumentKind) throws -> NSAttributedString {
        guard let type = documentType(kind) else { throw DocumentConversionError.unsupported }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        let caught = ObjCException.catching { () -> NSAttributedString? in
            try? NSAttributedString(data: data, options: options, documentAttributes: nil)
        }
        guard case .success(let value) = caught, let attributed = value else {
            throw DocumentConversionError.unreadable
        }
        return attributed
    }

    private static func attachmentCount(_ s: NSAttributedString) -> Int {
        var n = 0
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { value, _, _ in
            if value is NSTextAttachment { n += 1 }
        }
        return n
    }

    // MARK: - Layout and drawing

    /// Lays out and draws `attributed` (internal for tests: an image attachment larger than a page).
    static func render(_ attributed: NSAttributedString, options: Options, images: Int) throws -> Output {
        let page = options.paper.points
        let margin = min(max(0, options.margin), min(page.width, page.height) / 4)
        let content = CGSize(width: page.width - 2 * margin, height: page.height - 2 * margin)

        let storage = NSTextStorage(attributedString: attributed)
        fitAttachments(storage, into: content)
        let layout = NSLayoutManager()
        layout.backgroundLayoutEnabled = false
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)

        // One container per page until every glyph is placed.
        let paged = ObjCException.catching { () -> Int? in
            var containers = 0
            var emptyRun = 0
            while true {
                let container = NSTextContainer(size: content)
                container.lineFragmentPadding = 0
                layout.addTextContainer(container)
                containers += 1
                let range = layout.glyphRange(for: container)
                emptyRun = range.length == 0 ? emptyRun + 1 : 0
                if NSMaxRange(range) >= layout.numberOfGlyphs { return containers }
                // Something that never fits (a page-sized unbreakable element) or a runaway document.
                if emptyRun >= 3 || containers >= options.maxPages { return nil }
            }
        }
        guard case .success(let pageCount) = paged else { throw DocumentConversionError.unreadable }
        guard pageCount != nil else { throw DocumentConversionError.tooLarge }

        // Pages that ended up with nothing on them (trailing empty containers) are not drawn.
        let ranges = layout.textContainers.map { layout.glyphRange(for: $0) }
        var last = ranges.count - 1
        while last > 0, ranges[last].length == 0 { last -= 1 }
        let drawn = Array(layout.textContainers.prefix(last + 1))

        let out = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: page)
        let info: [CFString: Any] = [kCGPDFContextCreator: "PaperDeck"]
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let cg = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else {
            throw DocumentConversionError.renderFailed
        }
        let previous = NSGraphicsContext.current
        let graphics = NSGraphicsContext(cgContext: cg, flipped: true)
        var failed = false
        for container in drawn {
            cg.beginPDFPage(nil)
            cg.saveGState()
            cg.translateBy(x: 0, y: page.height)
            cg.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = graphics
            let origin = CGPoint(x: margin, y: margin)
            let drew = ObjCException.catching { () -> Bool in
                let range = layout.glyphRange(for: container)
                layout.drawBackground(forGlyphRange: range, at: origin)
                layout.drawGlyphs(forGlyphRange: range, at: origin)
                return true
            }
            NSGraphicsContext.current = previous
            cg.restoreGState()
            cg.endPDFPage()
            if case .failure = drew { failed = true; break }
        }
        cg.closePDF()
        guard !failed, out.length > 0 else { throw DocumentConversionError.renderFailed }
        return Output(pdf: out as Data, pageCount: drawn.count, images: images)
    }

    /// Images wider or taller than a page would never fit a container: they are scaled down to the
    /// text width and 90 % of the text height, keeping their aspect ratio.
    private static func fitAttachments(_ storage: NSTextStorage, into content: CGSize) {
        let maxW = content.width, maxH = content.height * 0.9
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            var size = attachment.bounds.size
            if size.width <= 0 || size.height <= 0 { size = attachment.attachmentCell?.cellSize() ?? .zero }
            if size.width <= 0 || size.height <= 0 { size = attachment.image?.size ?? .zero }
            guard size.width > 0, size.height > 0, size.width > maxW || size.height > maxH else { return }
            let k = min(maxW / size.width, maxH / size.height)
            let fitted = CGSize(width: max(1, floor(size.width * k)), height: max(1, floor(size.height * k)))
            if let image = attachment.image ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:)) {
                image.size = fitted
                attachment.image = image
            }
            attachment.bounds = CGRect(origin: .zero, size: fitted)
        }
    }

    // MARK: - Encrypted Word 97–2003 files

    /// A Word 97–2003 (.doc) file whose FIB says `fEncrypted`: the OLE2 directory's "WordDocument"
    /// stream starts with the FIB (wIdent 0xA5EC); bit 0x0100 of its flags word at offset 0x0A is
    /// the encryption flag. False when the structure can't be read (the importer then decides).
    package static func isEncryptedWordBinary(_ data: Data) -> Bool {
        let b = [UInt8](data)
        guard b.count >= 512, Array(b.prefix(8)) == [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] else { return false }
        func u16(_ o: Int) -> Int? { o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : nil }
        func u32(_ o: Int) -> Int? {
            o + 4 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 : nil
        }
        guard let shift = u16(0x1E), (9...12).contains(shift), let dirStart = u32(0x30) else { return false }
        let sector = 1 << shift
        let dirOffset = (dirStart + 1) * sector
        let name = Array("WordDocument".utf16)
        for entry in 0..<(sector / 128) {
            let e = dirOffset + entry * 128
            guard let nameBytes = u16(e + 0x40), e + 128 <= b.count else { break }
            let chars = (0..<max(0, nameBytes / 2 - 1)).compactMap { u16(e + $0 * 2).map(UInt16.init) }
            guard chars == name, let start = u32(e + 0x74) else { continue }
            let fib = (start + 1) * sector
            guard let ident = u16(fib), ident == 0xA5EC, let flags = u16(fib + 0x0A) else { return false }
            return flags & 0x0100 != 0
        }
        return false
    }
}
