import Foundation
import PaperDeckShared

/// Local PDF handling for captured mail (MAIL_DESIGN Part A §2 steps 7 + 9): stores PDF
/// attachments under `AppPaths.mailFiles/<message-id>/<n>.pdf` — and a person's document
/// attachments (Word, RTF, ODT, slides) as `<n>.<ext>` —, reads their first page for
/// title / identifiers, and decides whether a candidate's PDF is `downloadable` by the rules.
///
/// Nothing here goes to the network. Attachment bytes come from the already-fetched message;
/// the downloadable decision is pure string work on locally extracted URLs / ids (never on
/// anything an AI returned). Mail is untrusted input: a file is stored only when it starts with
/// `%PDF-`, is within the size cap, and — for a truncated message — still ends with `%%EOF`.
package struct MailPDFFetcher: Sendable {
    /// `AppPaths.mailFiles`.
    package let root: URL
    private let extractor: any PDFExtracting

    package init(root: URL, extractor: any PDFExtracting = PDFExtractor()) {
        self.root = root
        self.extractor = extractor
    }

    /// Why an attachment was not stored (shown on its row via `MailItem.downloadError`).
    package enum Rejection: Error, Sendable, Equatable {
        case notFetched(sizeBytes: Int)     // over the cap: the parser kept only its size
        case tooLarge(sizeBytes: Int)
        case notPDF
        case incomplete                     // the message was cut at the fetch limit
        case writeFailed

        package func message(_ lang: UILang, capMB: Int) -> String {
            let zh = lang == .zh
            switch self {
            case .notFetched(let size), .tooLarge(let size):
                let mb = max(1, Int((Double(size) / 1_048_576).rounded(.up)))
                return zh ? "附件 \(mb) MB，超过 \(capMB) MB 上限，请从邮件中下载后拖到这里"
                          : "The attachment is \(mb) MB (limit \(capMB) MB). Download it from the email and drop it here."
            case .notPDF:
                return zh ? "附件不是 PDF 文件" : "The attachment isn't a PDF file"
            case .incomplete:
                return zh ? "邮件过大，附件未完整下载，请从邮件中下载后拖到这里"
                          : "The email was too large to fetch completely. Download the PDF from the email and drop it here."
            case .writeFailed:
                return zh ? "无法保存附件" : "Couldn't save the attachment"
            }
        }

        /// The wording for a document attachment (Word / slides): the user opens it in the email,
        /// exports a PDF and drops it on the row.
        package func documentMessage(_ lang: UILang, capMB: Int) -> String {
            let zh = lang == .zh
            switch self {
            case .notFetched(let size), .tooLarge(let size):
                let mb = max(1, Int((Double(size) / 1_048_576).rounded(.up)))
                return zh ? "文档 \(mb) MB，超过 \(capMB) MB 上限：请在邮件中打开它，导出 PDF 后拖到这里"
                          : "The document is \(mb) MB (limit \(capMB) MB). Open it from the email, export a PDF and drop it here."
            case .notPDF:
                return zh ? "附件不是有效的文档文件" : "The attachment isn't a valid document file"
            case .incomplete:
                return zh ? "邮件过大，文档未完整下载：请在邮件中打开它，导出 PDF 后拖到这里"
                          : "The email was too large to fetch completely. Open the document from the email, export a PDF and drop it here."
            case .writeFailed:
                return zh ? "无法保存附件" : "Couldn't save the attachment"
            }
        }
    }

    /// A stored document original (`<message-id>/<n>.<ext>`).
    package struct SavedDocument: Sendable, Equatable {
        package var relativePath: String
        package var sha256: String
        package var bytes: Int64
        /// Office's password-protected package (a docx / pptx that is an OLE2 file): opened in Word /
        /// PowerPoint with its password, never converted here.
        package var encrypted: Bool
    }

    /// A stored attachment.
    package struct Saved: Sendable, Equatable {
        package var relativePath: String        // "<message-id>/<n>.pdf" (relative to `root`)
        package var sha256: String
        package var bytes: Int64
    }

    /// What the first page of a stored PDF says (title / ids for the row, text for the AI).
    package struct FirstPage: Sendable, Equatable {
        package var title: String?
        package var ids: PaperIDs
        package var text: String                // first page, ≤ `firstPageTextLimit` characters
        package var pageCount: Int
    }

    package static let firstPageTextLimit = 2_000

    // MARK: - Paths

    /// Directory of one message's files. Nil unless `messageID` is a plain lowercase UUID.
    package func directory(messageID: String) -> URL? {
        guard Self.isSafeID(messageID) else { return nil }
        return root.appendingPathComponent(messageID, isDirectory: true)
    }

    /// Absolute URL of a stored file; nil for anything that is not `<uuid>/<name>.pdf`.
    package func url(forRelative path: String) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, Self.isSafeID(String(parts[0])) else { return nil }
        let name = String(parts[1])
        guard !name.isEmpty, !name.hasPrefix("."), name.lowercased().hasSuffix(".pdf"),
              !name.contains("\0"), !name.contains("\\") else { return nil }
        return root.appendingPathComponent(String(parts[0]), isDirectory: true).appendingPathComponent(name)
    }

    /// Absolute URL of a stored document original; nil for anything that is not
    /// `<uuid>/<name>.<document extension>`.
    package func documentURL(forRelative path: String) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, Self.isSafeID(String(parts[0])) else { return nil }
        let name = String(parts[1])
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("\0"), !name.contains("\\"),
              DocumentKind(rawValue: (name as NSString).pathExtension.lowercased()) != nil else { return nil }
        return root.appendingPathComponent(String(parts[0]), isDirectory: true).appendingPathComponent(name)
    }

    static func isSafeID(_ s: String) -> Bool {
        s.count == 36 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) || $0 == "-" }
    }

    // MARK: - Attachments

    /// Validates one attachment's bytes. `truncated` = the fetched message was cut at `maxBytes`.
    package static func validate(_ attachment: MailAttachment, maxBytes: Int, truncated: Bool) -> Rejection? {
        guard let data = attachment.data else { return .notFetched(sizeBytes: attachment.sizeBytes) }
        guard data.count <= maxBytes else { return .tooLarge(sizeBytes: data.count) }
        guard PDFExtractor.isPDF(fileHead: data.prefix(1024)) else { return .notPDF }
        if truncated, data.suffix(8 * 1024).range(of: Data("%%EOF".utf8)) == nil { return .incomplete }
        return nil
    }

    /// Stores `attachment` as `<message-id>/<index + 1>.pdf` (atomic write; blocking I/O on BlockingIO).
    package func save(_ attachment: MailAttachment, index: Int, messageID: String, maxBytes: Int,
                      truncated: Bool) async -> Result<Saved, Rejection> {
        if let r = Self.validate(attachment, maxBytes: maxBytes, truncated: truncated) { return .failure(r) }
        guard let dir = directory(messageID: messageID), let data = attachment.data else { return .failure(.writeFailed) }
        let name = "\(index + 1).pdf"
        let relative = messageID + "/" + name
        return await BlockingIO.run { () -> Result<Saved, Rejection> in
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: dir.appendingPathComponent(name), options: [.atomic])
                return .success(Saved(relativePath: relative, sha256: FileOps.sha256(of: data), bytes: Int64(data.count)))
            } catch {
                Log.storage.error("mail attachment write failed: \(MailSyncActor.logText(error), privacy: .public)")
                return .failure(.writeFailed)
            }
        }
    }

    /// Validates a document attachment: bytes present, within the cap, the format's signature
    /// (`DocumentKind.hasValidSignature`), and — for a truncated message — a complete zip package
    /// (formats that can't be checked are refused then).
    package static func validateDocument(_ attachment: MailAttachment, kind: DocumentKind, maxBytes: Int,
                                         truncated: Bool) -> Rejection? {
        guard let data = attachment.data else { return .notFetched(sizeBytes: attachment.sizeBytes) }
        guard data.count <= maxBytes else { return .tooLarge(sizeBytes: data.count) }
        guard kind.hasValidSignature(data) else { return .notPDF }
        if truncated {
            let zip = [UInt8](data.prefix(4)) == [0x50, 0x4B, 0x03, 0x04]
            guard zip, kind.isComplete(data) else { return .incomplete }
        }
        return nil
    }

    /// Stores a document attachment as `<message-id>/<index + 1>.<ext>` (atomic write, marked as
    /// downloaded from an email — macOS's quarantine attribute — like Mail's own attachments).
    package func saveDocument(_ attachment: MailAttachment, kind: DocumentKind, index: Int, messageID: String,
                              maxBytes: Int, truncated: Bool) async -> Result<SavedDocument, Rejection> {
        if let r = Self.validateDocument(attachment, kind: kind, maxBytes: maxBytes, truncated: truncated) {
            return .failure(r)
        }
        guard let dir = directory(messageID: messageID), let data = attachment.data else { return .failure(.writeFailed) }
        let name = "\(index + 1).\(kind.fileExtension)"
        let relative = messageID + "/" + name
        let encrypted = kind.isEncryptedPackage(data)
        return await BlockingIO.run { () -> Result<SavedDocument, Rejection> in
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var url = dir.appendingPathComponent(name)
                try data.write(to: url, options: [.atomic])
                Self.markQuarantined(&url)
                return .success(SavedDocument(relativePath: relative, sha256: FileOps.sha256(of: data),
                                              bytes: Int64(data.count), encrypted: encrypted))
            } catch {
                Log.storage.error("mail attachment write failed: \(MailSyncActor.logText(error), privacy: .public)")
                return .failure(.writeFailed)
            }
        }
    }

    /// Best effort: the quarantine attribute a browser or Mail sets on downloaded files, so the
    /// system treats the stored attachment as coming from the internet when it is opened.
    static func markQuarantined(_ url: inout URL) {
        var values = URLResourceValues()
        values.quarantineProperties = ["LSQuarantineAgentName": "PaperDeck",
                                       "LSQuarantineType": "LSQuarantineTypeOtherAttachment"]
        try? url.setResourceValues(values)
    }

    /// Removes every file of one message (failed insert, clear-all). Idempotent.
    package func removeFiles(messageID: String) async {
        guard let dir = directory(messageID: messageID) else { return }
        await BlockingIO.run { try? FileManager.default.removeItem(at: dir) }
    }

    /// Removes the whole `mail/files` tree (「清除所有邮件数据」).
    package func removeAll() async {
        let root = self.root
        await BlockingIO.run { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - First page

    /// PDFKit on a stored file (off the caller's executor). Nil when the file can't be read.
    package func firstPage(relativePath: String) async -> FirstPage? {
        guard let url = url(forRelative: relativePath) else { return nil }
        guard let pdf = try? await extractor.extract(url: url, fileName: url.lastPathComponent) else { return nil }
        let text = pdf.pageTexts.first.map { HTMLText.collapse($0) } ?? ""
        return FirstPage(title: pdf.bestLocalTitle?.0, ids: pdf.ids,
                         text: String(text.prefix(Self.firstPageTextLimit)), pageCount: pdf.pageCount)
    }

    // MARK: - PDF availability (rules only, no network)

    /// `downloadable` when the rules know a direct PDF URL for the locally extracted ids / URL
    /// (arXiv, direct `.pdf`, bioRxiv/medRxiv try-once), otherwise `needsPDF`.
    package static func availability(ids: PaperIDs, url: String?, host: String?) -> MailPDFState {
        let probe = MailCandidate(cand: "", origin: .link, ids: ids, url: url, host: host)
        return PaperLinkClassifier.pdfURL(for: probe) != nil ? .downloadable : .needsPDF
    }
}
