import Darwin
import Foundation
import Testing
@testable import PaperDeckCore

/// Review fix safety-3: email links are fetched only from public hosts, automatic downloads only
/// from arXiv / bioRxiv / medRxiv over https, decided on the unwrapped target and re-checked on
/// every redirect. The redirect test runs against a loopback fixture server (127.0.0.1 only).
@Suite struct RFADownloadPolicyTests {
    typealias Kit = MailMergeKit

    @Test func publicHostRules() {
        let user = DownloadPolicy.mailUserAction
        let auto = DownloadPolicy.mailAutomatic
        func u(_ s: String) -> URL { URL(string: s)! }
        // Private / local / literal addresses: never, for anyone.
        for s in ["http://192.168.1.10/lab/drafts/manuscript-v3.pdf", "http://10.0.0.5/x.pdf", "http://127.0.0.1/x.pdf",
                  "http://2130706433/x.pdf", "http://0x7f000001/x.pdf", "http://0177.0.0.1/x.pdf", "http://[::1]/x.pdf",
                  "http://[fe80::1]/x.pdf", "http://localhost/x.pdf", "http://printer.local/x.pdf",
                  "http://nas.home.arpa/x.pdf", "http://wiki.internal/x.pdf", "http://intranet/x.pdf",
                  "http://api.localhost/x.pdf", "https://user:pw@example.org/x.pdf", "ftp://example.org/x.pdf",
                  "file:///etc/passwd", "http://169.254.169.254/latest/x.pdf"] {
            #expect(!user.allows(u(s)), "\(s)")
            #expect(!auto.allows(u(s)), "\(s)")
        }
        // Public hosts: on the user's click.
        for s in ["https://lab.example.edu/drafts/manuscript-v3.pdf", "http://www.example.org/paper.pdf",
                  "https://tracker.example.com/u/123/paper.pdf", "https://example.org:8443/x.pdf",
                  "https://xn--80ak6aa92e.xn--p1ai/a.pdf"] {
            #expect(user.allows(u(s)), "\(s)")
            #expect(!auto.allows(u(s)), "\(s)")
        }
        // Automatic: https to the preprint servers (and their subdomains) on the default port.
        for s in ["https://arxiv.org/pdf/2606.24530", "https://export.arxiv.org/pdf/2606.24530",
                  "https://www.biorxiv.org/content/10.1101/2026.09.14.612345v1.full.pdf",
                  "https://www.medrxiv.org/content/10.1101/2026.09.14.26312345v1.full.pdf"] {
            #expect(auto.allows(u(s)), "\(s)")
        }
        for s in ["http://arxiv.org/pdf/2606.24530", "https://arxiv.org:8443/pdf/2606.24530", "https://notarxiv.org/x.pdf",
                  "https://arxiv.org.evil.com/x.pdf"] {
            #expect(!auto.allows(u(s)), "\(s)")
        }
    }

    // MARK: Engine

    private static func advisorCard(_ env: Kit.Env, rows: [MailItem]) async throws -> (MailMessage, [MailItem]) {
        try await Kit.insert(env, Kit.message(kind: .advisor), items: rows)
    }

    @Test func automaticMergesFetchOnlyKnownPreprintHosts() async throws {
        try await Kit.run { env in
            env.downloader.route("https://arxiv.org/pdf/2606.24530",
                                 .init(status: 200, mime: "application/pdf", body: Kit.pdfData(title: "NatureBench")))
            let (message, items) = try await Self.advisorCard(env, rows: [
                Kit.item(1, origin: .link, pdf: .downloadable, url: "http://192.168.1.10/lab/drafts/manuscript-v3.pdf",
                         host: "192.168.1.10"),
                Kit.item(2, origin: .link, pdf: .downloadable, url: "https://tracker.example.com/u/123/paper.pdf",
                         host: "tracker.example.com"),
                Kit.item(3, origin: .link, pdf: .downloadable, arxiv: "2606.24530",
                         url: "https://arxiv.org/abs/2606.24530", host: "arxiv.org"),
            ])
            _ = try await env.engine.mergeAllMailItems(messageID: message.id, options: MailMergeOptions(readWithAI: false),
                                                       userAction: false)
            await env.settle()
            #expect(env.downloader.requested.map(\.absoluteString) == ["https://arxiv.org/pdf/2606.24530"])
            for item in items.prefix(2) {
                let row = try await env.item(item.id)
                #expect(row.status == .pending && row.pdfState == .downloadable && row.downloadError == nil)
            }
            #expect(try await env.item(items[2].id).status == .merged)
            #expect(try await !env.message(message.id).userTouched)

            // A single-row automatic merge waits for the user as well.
            #expect(try await env.engine.mergeMailItem(itemID: items[1].id, options: MailMergeOptions(readWithAI: false),
                                                       userAction: false) == nil)
            #expect(env.downloader.requested.count == 1)
        }
    }

    @Test func autoDownloadOffMeansNoDownloadAtAll() async throws {
        try await Kit.run { env in
            env.downloader.route("https://arxiv.org/pdf/2606.24530",
                                 .init(status: 200, mime: "application/pdf", body: Kit.pdfData(title: "NatureBench")))
            let (message, _) = try await Self.advisorCard(env, rows: [
                Kit.item(1, origin: .link, pdf: .downloadable, arxiv: "2606.24530", url: "https://arxiv.org/abs/2606.24530",
                         host: "arxiv.org"),
            ])
            _ = try await env.engine.mergeAllMailItems(messageID: message.id, options: MailMergeOptions(readWithAI: false),
                                                       userAction: false, allowDownloads: false)
            #expect(env.downloader.requested.isEmpty)
        }
    }

    @Test func theUsersClickNeverReachesAPrivateAddressEvenThroughSafeLinks() async throws {
        try await Kit.run { env in
            let wrapped = "https://nam02.safelinks.protection.outlook.com/?url=http%3A%2F%2F10.0.0.5%2Fdrafts%2Fx.pdf&data=05%7C02&reserved=0"
            let (_, items) = try await Self.advisorCard(env, rows: [
                Kit.item(1, origin: .link, pdf: .downloadable, url: "http://192.168.1.10/lab/x.pdf", host: "192.168.1.10"),
                Kit.item(2, origin: .link, pdf: .downloadable, url: wrapped, host: "nam02.safelinks.protection.outlook.com"),
                Kit.item(3, origin: .link, pdf: .downloadable, url: "https://tracker.example.com/u/123/paper.pdf",
                         host: "tracker.example.com"),
            ])
            for item in items { try await env.engine.downloadMailItem(itemID: item.id) }
            for item in items.prefix(2) {
                let row = try await env.item(item.id)
                #expect(row.pdfState == .needsPDF)
                #expect(row.downloadError == "The link points to a local or private network address — PaperDeck doesn't download it")
            }
            // A public host is fetched on the user's click (the fake answers 404).
            #expect(env.downloader.requested.map(\.absoluteString) == ["https://tracker.example.com/u/123/paper.pdf"])
            #expect(MailOpsText.privateAddress(.zh) == "链接指向本地或内网地址，PaperDeck 不会下载")
        }
    }

    // MARK: Redirects (URLSession transport against a loopback fixture)

    @Test func redirectsAreCheckedAgainstThePolicy() async throws {
        let server = try RFAHTTPServer()
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)"
        let policy = DownloadPolicy(httpsOnly: false, allowedDomains: nil, exemptHosts: ["127.0.0.1"])
        let downloader = URLSessionPDFDownloader()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-rfa-redirect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Redirect to another (non-exempt, local) host: refused, never requested.
        await #expect(throws: DownloadBlockedError.self) {
            _ = try await downloader.download(URL(string: "\(base)/start.pdf")!, into: dir, policy: policy) { _ in }
        }
        #expect(!server.paths.contains("/evil.pdf"))
        let importer = URLImporter(downloader: downloader)
        let blocked = await importer.fetch(URL(string: "\(base)/start.pdf")!, incoming: dir, policy: policy) { _ in }
        #expect(blocked == .blocked)

        // A redirect the policy allows is followed.
        let ok = try await downloader.download(URL(string: "\(base)/ok-start.pdf")!, into: dir, policy: policy) { _ in }
        #expect(ok.status == 200 && ok.file != nil)
        #expect(server.paths.contains("/ok.pdf"))
        #expect(!server.paths.contains("/evil.pdf"))

        // The initial URL is checked before anything is sent.
        await #expect(throws: DownloadBlockedError.self) {
            _ = try await downloader.download(URL(string: "\(base)/ok.pdf")!, into: dir, policy: .mailUserAction) { _ in }
        }
    }
}

/// A one-request-per-connection HTTP/1.1 fixture on 127.0.0.1: `/start.pdf` redirects to
/// `localhost` (another host), `/ok-start.pdf` to `/ok.pdf` (same host), `/ok.pdf` and
/// `/evil.pdf` answer a tiny PDF. Records the requested paths.
final class RFAHTTPServer: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var _paths: [String] = []
    private let done = DispatchSemaphore(value: 0)
    private(set) var port: UInt16 = 0

    var paths: [String] { lock.withLock { _paths } }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = UInt16(bigEndian: addr.sin_port)
        Thread { [self] in acceptLoop(fd) }.start()
    }

    func stop() {
        let first = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        if first { _ = done.wait(timeout: .now() + 2) }
    }

    private func acceptLoop(_ fd: Int32) {
        defer { close(fd); done.signal() }
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 20)
            if lock.withLock({ stopped }) { return }
            guard ready > 0 else { continue }
            let c = accept(fd, nil, nil)
            guard c >= 0 else { continue }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            serve(c)
            close(c)
        }
    }

    private func serve(_ c: Int32) {
        var request: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while !request.suffix(4).elementsEqual([13, 10, 13, 10]) && request.count < 65_536 {
            var pfd = pollfd(fd: c, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 2000) > 0 else { return }
            let n = read(c, &buf, buf.count)
            guard n > 0 else { return }
            request.append(contentsOf: buf[0..<n])
        }
        let line = String(decoding: request.prefix { $0 != 13 }, as: UTF8.self)
        let parts = line.split(separator: " ")
        let path = parts.count >= 2 ? String(parts[1]) : "/"
        lock.withLock { _paths.append(path) }
        let pdf = Data("%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n".utf8)
        let response: Data
        switch path {
        case "/start.pdf":
            response = Self.head("302 Found", ["Location": "http://localhost:\(port)/evil.pdf", "Content-Length": "0"])
        case "/ok-start.pdf":
            response = Self.head("302 Found", ["Location": "/ok.pdf", "Content-Length": "0"])
        case "/ok.pdf", "/evil.pdf":
            response = Self.head("200 OK", ["Content-Type": "application/pdf", "Content-Length": "\(pdf.count)"]) + pdf
        default:
            response = Self.head("404 Not Found", ["Content-Length": "0"])
        }
        response.withUnsafeBytes { p in
            var off = 0
            while off < p.count {
                let n = write(c, p.baseAddress! + off, p.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    private static func head(_ status: String, _ headers: [String: String]) -> Data {
        var s = "HTTP/1.1 \(status)\r\nConnection: close\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { s += "\(k): \(v)\r\n" }
        return Data((s + "\r\n").utf8)
    }
}
