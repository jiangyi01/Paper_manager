import Foundation

/// Office-style documents a person's email may carry instead of a PDF — a lab manuscript as a Word
/// file, a talk as slides. Word / RTF / ODT text documents can be converted to a PDF on this Mac
/// (`DocumentConverter`); slides and Pages files can only be opened (the user exports a PDF).
/// Spreadsheets and macro-enabled formats are not reading material and are never candidates.
///
/// Mail is untrusted input: the kind comes from the file name's extension (else the MIME type),
/// and a stored file must also start with its format's signature (`hasValidSignature`).
package enum DocumentKind: String, Sendable, CaseIterable, Equatable {
    case docx, doc, rtf, odt          // text documents: converted locally
    case pptx, ppt, key, pages, odp   // slides / Pages: open & export a PDF

    /// Text documents NSAttributedString reads (docx, doc, rtf, odt).
    package var isConvertible: Bool {
        switch self {
        case .docx, .doc, .rtf, .odt: return true
        case .pptx, .ppt, .key, .pages, .odp: return false
        }
    }

    /// The row state of a stored original of this kind.
    package var pdfState: MailPDFState { isConvertible ? .convertible : .openOnly }

    /// The file extension used for the stored copy.
    package var fileExtension: String { rawValue }

    private static let contentTypes: [String: DocumentKind] = [
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": .docx,
        "application/msword": .doc,
        "application/rtf": .rtf,
        "text/rtf": .rtf,
        "application/x-rtf": .rtf,
        "text/richtext": .rtf,
        "application/vnd.oasis.opendocument.text": .odt,
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": .pptx,
        "application/vnd.ms-powerpoint": .ppt,
        "application/vnd.apple.keynote": .key,
        "application/x-iwork-keynote-sffkey": .key,
        "application/vnd.apple.pages": .pages,
        "application/x-iwork-pages-sffpages": .pages,
        "application/vnd.oasis.opendocument.presentation": .odp,
    ]

    /// The kind of an attachment: by its file name's extension, else (no usable extension) its
    /// MIME type. Nil for PDFs, spreadsheets, images, macro-enabled files and anything else.
    package static func detect(fileName: String?, contentType: String?) -> DocumentKind? {
        if let name = fileName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let ext = (name as NSString).pathExtension.lowercased()
            if !ext.isEmpty, ext.count <= 8, ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return DocumentKind(rawValue: ext)          // "pdf", "xlsx", "docm", "png"… → nil
            }
        }
        guard let type = contentType?.lowercased().split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces) }) else {
            return nil
        }
        return contentTypes[type]
    }

    /// The kind a URL path names by its extension (a Dropbox / Box link to "draft.docx"), any
    /// document kind or "pdf"; nil otherwise.
    package static func kind(ofPath path: String) -> String? {
        let ext = ((path.removingPercentEncoding ?? path) as NSString).pathExtension.lowercased()
        if ext == "pdf" { return "pdf" }
        return DocumentKind(rawValue: ext)?.rawValue
    }

    // MARK: - Signatures

    private static let zip: [UInt8] = [0x50, 0x4B, 0x03, 0x04]                              // PK\3\4
    private static let ole: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]      // OLE2 compound file
    private static let rtfMagic: [UInt8] = Array("{\\rtf".utf8)

    /// The first bytes match the format: a zip package (docx, pptx, odt, odp, key, pages), an OLE2
    /// compound file (doc, ppt — and a password-protected docx / pptx, which Office wraps in one),
    /// or `{\rtf`.
    package func hasValidSignature(_ head: Data) -> Bool {
        let bytes = [UInt8](head.prefix(16))
        func starts(_ magic: [UInt8]) -> Bool { bytes.count >= magic.count && Array(bytes.prefix(magic.count)) == magic }
        switch self {
        case .docx, .pptx: return starts(Self.zip) || starts(Self.ole)
        case .odt, .odp, .key, .pages: return starts(Self.zip)
        case .doc, .ppt: return starts(Self.ole)
        case .rtf: return starts(Self.rtfMagic)
        }
    }

    /// A docx / pptx that is an OLE2 compound file is Office's encrypted package (a password is
    /// needed to open it); for the other kinds this is unknowable from the bytes and false.
    package func isEncryptedPackage(_ head: Data) -> Bool {
        guard self == .docx || self == .pptx else { return false }
        return [UInt8](head.prefix(8)) == Self.ole
    }

    /// Whether a zip package is complete: its end-of-central-directory record ("PK\5\6") is in
    /// the last 64 KiB. Formats that are not zip packages cannot be checked and are complete.
    package func isComplete(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(8))
        guard bytes.count >= 4, Array(bytes.prefix(4)) == Self.zip else { return true }
        let tail = data.suffix(65_557)
        return tail.range(of: Data([0x50, 0x4B, 0x05, 0x06])) != nil
    }
}
