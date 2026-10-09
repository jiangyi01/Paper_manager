import Foundation
import PDFKit

/// A PDF opened for the reader off the main actor (RD-3): the document, its page labels and the
/// bytes it was read from (the find's own document is made from them). Built on a background thread
/// and handed over whole — nothing else holds the document until the window takes it — hence
/// `@unchecked Sendable`.
package final class ReaderOpenedDocument: @unchecked Sendable {
    package let document: PDFDocument
    package let labels: [String?]
    package let data: Data

    init(document: PDFDocument, labels: [String?], data: Data) {
        self.document = document; self.labels = labels; self.data = data
    }

    package var pageCount: Int { document.pageCount }
}

/// How opening a PDF for the reader ended.
package enum ReaderOpenResult: Sendable {
    case opened(ReaderOpenedDocument)
    /// No file at the path.
    case missing
    /// Not a PDF PDFKit can read (or the read failed).
    case unreadable
    /// Password-protected.
    case locked
    /// The file wasn't readable within the time limit (an iCloud / OneDrive file still downloading,
    /// or another app holding it).
    case timedOut
    /// The window closed (or the open was replaced) first.
    case cancelled
}

/// Opens a paper's PDF for the reader without touching the main actor (RD-3): a coordinated read
/// (like `FileOps.coordinatedRead` for imports — an iCloud / OneDrive placeholder is downloaded
/// first, with a time limit, and the wait is cancellable), then `PDFDocument` and the page labels
/// built on the read's own queue. `PDFDocument(url:)` on the main actor used to freeze the window
/// while a not-yet-downloaded file materialized. Owned by Slice C (reader).
package enum ReaderDocumentLoader {
    /// How long the reader waits for the file (a cloud download included).
    package static let timeout: Duration = .seconds(90)

    /// Where the reader's reads run (never behind the import's two ingest slots).
    package static let readQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "\(Log.subsystem).reader-open"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    package static func open(_ url: URL, timeout: Duration = ReaderDocumentLoader.timeout) async -> ReaderOpenResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            return try await FileOps.coordinatedRead(source: url, timeout: timeout, queue: readQueue) { readURL in
                // Mapped when the volume allows it (a local file): pages are read as they are drawn.
                let data = try Data(contentsOf: readURL, options: [.mappedIfSafe])
                return opened(data)
            }
        } catch is CancellationError {
            return .cancelled
        } catch let e as FileOpsError {
            switch e {
            case .timeout: return .timedOut
            case .sourceMissing: return .missing
            default: return .unreadable
            }
        } catch {
            return Task.isCancelled ? .cancelled : .unreadable
        }
    }

    /// The document from bytes already read (and the renders' fixtures), built inside `PDFKitGate`
    /// (a refused document is released there too). The window takes the document over afterwards.
    package static func opened(_ data: Data) -> ReaderOpenResult {
        PDFKitGate.shared.run {
            guard let document = PDFDocument(data: data) else { return .unreadable }
            guard !document.isLocked else { return .locked }
            return .opened(ReaderOpenedDocument(document: document, labels: ReaderPDF.labels(of: document), data: data))
        }
    }
}
