import Foundation

/// A finished download: the HTTP status, what the server said it sent, and the body on
/// disk (inside the directory the caller passed). Non-2xx statuses are values, not errors.
package struct PDFDownload: Sendable, Equatable {
    package var status: Int
    package var mimeType: String?
    package var file: URL?
    package var suggestedFilename: String?

    package init(status: Int, mimeType: String? = nil, file: URL? = nil, suggestedFilename: String? = nil) {
        self.status = status; self.mimeType = mimeType; self.file = file; self.suggestedFilename = suggestedFilename
    }
}

/// Transport for dropped links, so the importer can be tested offline with a fake.
/// Implementations throw only for transport failures (DNS, TLS, timeout, cancellation).
package protocol PDFDownloading: Sendable {
    /// Downloads `url` into `directory` (which exists), reporting progress in 0…1
    /// (nil while the size is unknown).
    func download(_ url: URL, into directory: URL,
                  progress: @escaping @Sendable (Double?) -> Void) async throws -> PDFDownload
    /// The same, with every redirect target checked against `policy` (nil = no check): a
    /// redirect it refuses is not followed and the call throws `DownloadBlockedError`.
    func download(_ url: URL, into directory: URL, policy: DownloadPolicy?,
                  progress: @escaping @Sendable (Double?) -> Void) async throws -> PDFDownload
}

extension PDFDownloading {
    /// Transports that never redirect (test fakes): the policy only applies to `url`.
    package func download(_ url: URL, into directory: URL, policy: DownloadPolicy?,
                          progress: @escaping @Sendable (Double?) -> Void) async throws -> PDFDownload {
        if let policy, !policy.allows(url) { throw DownloadBlockedError() }
        return try await download(url, into: directory, progress: progress)
    }
}

/// Turns a dropped http(s) link into a local PDF under `caches/incoming/<uuid>/` (§6.1 [接收]).
/// Only direct PDF links are fetched, plus arXiv abs/html pages rewritten to their PDF; the
/// response must be HTTP 200 and either `application/pdf` or start with `%PDF-` (first KB).
package struct URLImporter: Sendable {
    package enum Outcome: Sendable, Equatable {
        /// A PDF on disk (`file` lives in its own incoming folder; delete that folder after ingest).
        case downloaded(file: URL, name: String)
        /// Not a PDF link we download (web page, unsupported scheme) — nothing was fetched.
        case notPDFLink
        /// Downloaded, but the server sent something else (HTML login wall, viewer page…).
        case notPDF
        /// Non-200 status (403 paywall, 404…).
        case httpError(Int)
        /// Transport failure (offline, timeout, too large).
        case failed(String)
        /// The `DownloadPolicy` refused the link or one of its redirects — nothing was kept.
        case blocked
    }

    /// Larger bodies are cancelled mid-download.
    package static let maxBytes: Int64 = 300 << 20

    private let downloader: any PDFDownloading

    package init(downloader: any PDFDownloading) {
        self.downloader = downloader
    }

    /// The URL to download for a dropped link, nil when the link is not a PDF link.
    /// `arxiv.org/abs|html|pdf/<id>(vN)` → `https://arxiv.org/pdf/<id>(vN)`; `*.pdf` paths
    /// (and `…/pdf?id=` style endpoints such as OpenReview) are used as they are.
    package static func pdfURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        if let arxiv = arxivPDF(url) { return arxiv.url }
        let path = url.path.lowercased()
        if path.hasSuffix(".pdf") || url.lastPathComponent.lowercased() == "pdf" { return url }
        return nil
    }

    /// arXiv links → the canonical PDF URL plus the file name that keeps the id detectable
    /// (`2606.24530v2.pdf`). Covers new-style and old-style ids.
    package static func arxivPDF(_ url: URL) -> (url: URL, fileName: String)? {
        guard let host = url.host?.lowercased(),
              host == "arxiv.org" || host.hasSuffix(".arxiv.org") else { return nil }
        let path = url.path
        guard let m = path.firstMatch(of: /^\/(?:abs|html|pdf)\/((?:\d{4}\.\d{4,5})|(?:[A-Za-z\-]+(?:\.[A-Za-z]{2})?\/\d{7}))(v\d+)?(?:\.pdf)?\/?$/) else {
            return nil
        }
        let id = String(m.1)
        let version = m.2.map(String.init) ?? ""
        guard !id.contains("/") ? Identifiers.isValidArxivID(id) : true,
              let pdf = URL(string: "https://arxiv.org/pdf/\(id)\(version)") else { return nil }
        let fileName = id.replacingOccurrences(of: "/", with: "_") + version + ".pdf"
        return (pdf, fileName)
    }

    /// Downloads `url` into a fresh `incoming/<uuid>/` folder. On every outcome other than
    /// `.downloaded` the folder is already removed. With a `policy` (email links) the download
    /// URL and every redirect must pass it (`.blocked` otherwise).
    package func fetch(_ url: URL, incoming: URL, policy: DownloadPolicy? = nil,
                       progress: @escaping @Sendable (Double?) -> Void) async -> Outcome {
        guard let target = Self.pdfURL(for: url) else { return .notPDFLink }
        if let policy, !policy.allows(target) { return .blocked }
        let fm = FileManager.default
        let dir = incoming.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            return .failed(FileOps.classify(error).description)
        }
        func discard() { try? fm.removeItem(at: dir) }

        let result: PDFDownload
        do {
            result = try await downloader.download(target, into: dir, policy: policy, progress: progress)
        } catch {
            discard()
            if error is DownloadBlockedError { return .blocked }
            if error is CancellationError { return .failed("cancelled") }
            return .failed((error as NSError).localizedDescription)
        }
        guard result.status == 200 else { discard(); return .httpError(result.status) }
        guard let body = result.file, fm.fileExists(atPath: body.path) else { discard(); return .failed("empty response") }

        let head = (try? FileOps.readHead(body)) ?? Data()
        let mime = result.mimeType?.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
        guard mime == "application/pdf" || FileOps.isPDF(head: head) else { discard(); return .notPDF }

        let name = Self.fileName(for: url, target: target, suggested: result.suggestedFilename)
        let dest = dir.appendingPathComponent(name)
        if body.standardizedFileURL != dest.standardizedFileURL {
            do { try fm.moveItem(at: body, to: dest) } catch {
                discard()
                return .failed(FileOps.classify(error).description)
            }
        }
        return .downloaded(file: dest, name: name)
    }

    /// arXiv ids become `<id>vN.pdf` so the importer detects them from the name; otherwise
    /// the server's suggested name, else the URL's last path component, sanitized, `.pdf`.
    private static func fileName(for url: URL, target: URL, suggested: String?) -> String {
        if let arxiv = arxivPDF(url) ?? arxivPDF(target) { return arxiv.fileName }
        let candidates = [suggested, target.lastPathComponent, url.lastPathComponent]
        for raw in candidates {
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
                  raw != "/", raw.lowercased() != "pdf" else { continue }
            return FileNamer.inboxPDFName(originalName: raw)
        }
        return "Download.pdf"
    }
}

// MARK: - URLSession transport

/// Production downloader: an ephemeral session (no cookies, no cache) whose download
/// tasks report progress through a delegate and stream the body to disk.
package final class URLSessionPDFDownloader: PDFDownloading {
    private let session: URLSession
    private let router: DownloadRouter

    package init(userAgent: String = MetadataClients.userAgent(mailto: nil)) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 15 * 60
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = ["User-Agent": userAgent, "Accept": "application/pdf, */*;q=0.5"]
        let router = DownloadRouter(maxBytes: URLImporter.maxBytes)
        let queue = OperationQueue()
        queue.name = "\(Log.subsystem).download"
        queue.maxConcurrentOperationCount = 1
        self.router = router
        self.session = URLSession(configuration: cfg, delegate: router, delegateQueue: queue)
    }

    deinit { session.invalidateAndCancel() }

    package func download(_ url: URL, into directory: URL,
                          progress: @escaping @Sendable (Double?) -> Void) async throws -> PDFDownload {
        try await download(url, into: directory, policy: nil, progress: progress)
    }

    package func download(_ url: URL, into directory: URL, policy: DownloadPolicy?,
                          progress: @escaping @Sendable (Double?) -> Void) async throws -> PDFDownload {
        if let policy, !policy.allows(url) { throw DownloadBlockedError() }
        let task = session.downloadTask(with: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                                         timeoutInterval: 60))
        let router = self.router
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PDFDownload, any Error>) in
                router.register(task.taskIdentifier, directory: directory, policy: policy, progress: progress,
                                continuation: cont)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// Session delegate that routes callbacks to the waiting `download` call by task id.
private final class DownloadRouter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Entry {
        var directory: URL
        var policy: DownloadPolicy?
        var progress: @Sendable (Double?) -> Void
        var continuation: CheckedContinuation<PDFDownload, any Error>
        var file: URL?
        var tooLarge = false
        var redirectRefused = false
    }

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]
    private let maxBytes: Int64

    init(maxBytes: Int64) { self.maxBytes = maxBytes }

    func register(_ id: Int, directory: URL, policy: DownloadPolicy?, progress: @escaping @Sendable (Double?) -> Void,
                  continuation: CheckedContinuation<PDFDownload, any Error>) {
        lock.withLock {
            entries[id] = Entry(directory: directory, policy: policy, progress: progress, continuation: continuation)
        }
    }

    /// Every redirect is checked against the task's policy; a refused one is not followed (the
    /// task is cancelled and the caller gets `DownloadBlockedError`).
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let policy = lock.withLock { entries[task.taskIdentifier]?.policy }
        guard let policy else {
            completionHandler(request)
            return
        }
        if let next = request.url, policy.allows(next) {
            completionHandler(request)
            return
        }
        lock.withLock { entries[task.taskIdentifier]?.redirectRefused = true }
        Log.importer.info("download: a redirect was refused by the download policy")
        completionHandler(nil)
        task.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let limit = maxBytes
        let tooLarge = totalBytesWritten > limit || totalBytesExpectedToWrite > limit
        let progress: (@Sendable (Double?) -> Void)? = lock.withLock {
            if tooLarge { entries[downloadTask.taskIdentifier]?.tooLarge = true }
            return entries[downloadTask.taskIdentifier]?.progress
        }
        if tooLarge { downloadTask.cancel(); return }
        let fraction = totalBytesExpectedToWrite > 0
            ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil
        progress?(fraction)
    }

    /// The temporary file is deleted when this returns, so move it right here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let dir = lock.withLock({ entries[downloadTask.taskIdentifier]?.directory }) else { return }
        let dest = dir.appendingPathComponent(UUID().uuidString.lowercased() + ".download")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            lock.withLock { entries[downloadTask.taskIdentifier]?.file = dest }
        } catch {
            Log.importer.error("download: could not keep body: \(FileOps.classify(error).description, privacy: .public)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let entry = lock.withLock({ entries.removeValue(forKey: task.taskIdentifier) }) else { return }
        if entry.redirectRefused {
            if let file = entry.file { try? FileManager.default.removeItem(at: file) }
            entry.continuation.resume(throwing: DownloadBlockedError())
            return
        }
        if entry.tooLarge {
            entry.continuation.resume(throwing: URLError(.dataLengthExceedsMaximum))
            return
        }
        if let error {
            entry.continuation.resume(throwing: error)
            return
        }
        let http = task.response as? HTTPURLResponse
        entry.continuation.resume(returning: PDFDownload(status: http?.statusCode ?? 0, mimeType: task.response?.mimeType,
                                                         file: entry.file,
                                                         suggestedFilename: task.response?.suggestedFilename))
    }
}
