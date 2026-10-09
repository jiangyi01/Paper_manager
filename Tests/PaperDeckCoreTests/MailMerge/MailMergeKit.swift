import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import PaperDeckCore

/// Shared fixtures of the MailMerge suites: temp-rooted engines (clock, settings, fake link
/// downloader, event log), real generated PDFs (CoreText — the engine's PDFKit extractor
/// reads their title and DOI), and email cards inserted the way the sync leaves them.
/// Nothing touches the network, a mail server, an AI CLI or the user's library.
enum MailMergeKit {
    static let timeZone = TimeZone(identifier: "America/Chicago")!
    static var calendar: Calendar { LocalDate.gregorian(timeZone) }
    /// Tuesday 2026-09-29 10:00 local.
    static var start: Date { day(2026, 9, 29).date(hour: 10, minute: 0, calendar: calendar) }
    static func day(_ y: Int, _ m: Int, _ d: Int) -> LocalDate { LocalDate(year: y, month: m, day: d) }

    final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// Every engine event, drained on demand.
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [EngineEvent] = []
        private var task: Task<Void, Never>?
        private let hub: EventHub<EngineEvent>

        init(hub: EventHub<EngineEvent>) {
            self.hub = hub
            let stream = hub.subscribe()
            task = Task { [weak self] in for await e in stream { self?.append(e) } }
        }
        deinit { task?.cancel() }
        private func append(_ e: EngineEvent) { lock.withLock { items.append(e) } }

        func drain() async {
            let marker = "mailmerge-sentinel-" + UUID().uuidString
            hub.send(.toast(Toast(id: marker, kind: .info, message: marker)))
            for _ in 0..<500 {
                let seen = lock.withLock { items.contains { if case .toast(let t) = $0 { return t.id == marker }; return false } }
                if seen { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        var toasts: [Toast] {
            lock.withLock {
                items.compactMap { if case .toast(let t) = $0, !t.id.hasPrefix("mailmerge-sentinel-") { return t }; return nil }
            }
        }
        var batches: [ImportBatchSummary] {
            lock.withLock { items.compactMap { if case .batchFinished(let s) = $0 { return s }; return nil } }
        }
        func clear() { lock.withLock { items.removeAll() } }
    }

    /// Offline link transport: a reply per URL (default 404); records every request.
    final class Downloader: PDFDownloading, @unchecked Sendable {
        struct Reply: Sendable {
            var status: Int
            var mime: String?
            var body: Data
        }
        private let lock = NSLock()
        private var urls: [URL] = []
        private var routes: [String: Reply] = [:]

        func route(_ url: String, _ reply: Reply) { lock.withLock { routes[url] = reply } }
        var requested: [URL] { lock.withLock { urls } }

        func download(_ url: URL, into directory: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> PDFDownload {
            let reply = lock.withLock { () -> Reply in
                urls.append(url)
                return routes[url.absoluteString] ?? Reply(status: 404, mime: "text/html", body: Data("<html>".utf8))
            }
            let file = directory.appendingPathComponent("body.download")
            try reply.body.write(to: file)
            return PDFDownload(status: reply.status, mimeType: reply.mime, file: file, suggestedFilename: nil)
        }
    }

    struct Env: Sendable {
        let engine: Engine
        let root: URL
        let clock: Box<Date>
        let settings: Box<EngineSettings>
        let mail: Box<MailSettings>
        let events: Events
        let downloader: Downloader

        var db: Database { engine.db }
        var paths: AppPaths { engine.paths }

        /// Enrichment finished, sidecars written, events delivered.
        func settle() async {
            await engine.enrich.waitUntilIdle()
            await engine.ctx.sidecars.flush()
            await events.drain()
        }

        func cleanup() async {
            await engine.shutdown()
            await engine.db.close()
            try? FileManager.default.removeItem(at: root)
        }

        func paper(_ id: String) async throws -> Paper { try #require(try await db.paper(id: id)) }
        func item(_ id: String) async throws -> MailItem { try #require(try await db.mailItem(id: id)) }
        func message(_ id: String) async throws -> MailMessage { try #require(try await db.mailMessage(id: id)) }

        func sidecar(_ p: Paper) throws -> CardSidecar {
            try CardSidecar.decoded(from: Data(contentsOf: engine.ctx.folderURL(p).appendingPathComponent(CardSidecar.fileName)))
        }
    }

    static func settings(lang: UILang = .en, autoRead: Bool = true, importMode: EngineSettings.ImportMode = .copy,
                         remindWhenEmpty: Bool = false) -> EngineSettings {
        EngineSettings(plan: PlanSettings(dailyBudgetMinutes: 60, readingWeekdays: [2, 3, 4, 5, 6],
                                          remindWhenEmpty: remindWhenEmpty),
                       lang: lang, agentMode: .off, autoReadNewPapers: autoRead, importMode: importMode,
                       metadataLookup: false)
    }

    static func make(_ settings: EngineSettings = MailMergeKit.settings(), mail: MailSettings = MailSettings(),
                     root: URL? = nil, now: Date = MailMergeKit.start) async throws -> Env {
        let root = try root ?? {
            let r = FileManager.default.temporaryDirectory.appendingPathComponent("pd-mailmerge-\(UUID().uuidString)",
                                                                                  isDirectory: true)
            try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
            return r
        }()
        let clock = Box(now)
        let box = Box(settings)
        let mailBox = Box(mail)
        let deps = Engine.Dependencies(loadSettings: { box.value }, now: { clock.value }, calendar: calendar,
                                       fetcher: nil, claude: MockAgentProvider(), codex: MockAgentProvider(),
                                       mock: MockAgentProvider(), sidecarDelay: .milliseconds(5),
                                       loadMailSettings: { mailBox.value }, assistBackends: [MockAssistBackend()])
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: deps)
        let downloader = Downloader()
        await engine.intake.useDownloader(downloader)
        return Env(engine: engine, root: root, clock: clock, settings: box, mail: mailBox,
                   events: Events(hub: engine.events), downloader: downloader)
    }

    static func run(_ settings: EngineSettings = MailMergeKit.settings(), mail: MailSettings = MailSettings(),
                    now: Date = MailMergeKit.start, _ body: (Env) async throws -> Void) async throws {
        let env = try await make(settings, mail: mail, now: now)
        do { try await body(env) } catch {
            await env.cleanup()
            throw error
        }
        await env.cleanup()
    }

    // MARK: PDFs

    /// A real 2-page PDF: a big title line, an author line, an optional labeled DOI, body text
    /// and a unique tag (distinct bytes per call).
    static func pdfData(title: String, doi: String? = nil, tag: String = UUID().uuidString) -> Data {
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: out as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
        let body = "Cortical progenitors divide and differentiate into neurons over development and beyond."
        var lines: [(String, CGFloat)] = [(title, 24), ("Ada Lovelace and Grace Hopper", 11)]
        if let doi { lines.append(("DOI: \(doi)", 9)) }
        lines += [("Abstract", 12)] + Array(repeating: (body, 10), count: 6) + [("tag \(tag)", 8)]
        for page in [lines, [("1 Introduction", 12)] + Array(repeating: (body, 10), count: 8)] {
            ctx.beginPDFPage(nil)
            var y: CGFloat = 730
            for (text, size) in page {
                let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
                ctx.textPosition = CGPoint(x: 54, y: y)
                CTLineDraw(line, ctx)
                y -= size * 1.8
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return out as Data
    }

    /// Writes a PDF outside the library (the user's own download).
    static func writeUserPDF(_ env: Env, name: String, title: String, doi: String? = nil) throws -> URL {
        let dir = env.root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try pdfData(title: title, doi: doi).write(to: url)
        return url
    }

    // MARK: Email cards

    static func triage(request: Bool = true, kind: MailRequestKind = .advisorRequest, summary: String = "Please read the attached paper before Friday.",
                       due: LocalDate? = nil, dueConfidence: Double? = nil, priority: Priority = .normal) -> MailTriage {
        MailTriage(hasReadingRequest: request, requestKind: kind, summary: summary, requester: nil, dueDate: due,
                   dueEvidence: due == nil ? nil : "before Friday", dueConfidence: dueConfidence, priority: priority,
                   confidence: 0.9)
    }

    static func message(kind: SenderKind = .advisor, subject: String = "Papers for Thursday",
                        from: String = "prof.x@wustl.edu", name: String? = "Prof. X", triage: MailTriage? = MailMergeKit.triage(),
                        state: MailState = .pending, received: Date = MailMergeKit.start.addingTimeInterval(-3_600)) -> MailMessage {
        MailMessage(accountID: "acct-1", internetMessageID: "<\(UUID().uuidString.lowercased())@wustl.edu>",
                    fromAddress: from, fromName: name, ruleID: nil, senderKind: kind, subject: subject,
                    receivedAt: received, webLink: "https://mail.google.com/mail/u/0/#search/rfc822msgid:x",
                    snippet: "Please read", bodyText: "Please read [c1] before Friday.", state: state,
                    triageSource: triage == nil ? nil : .heuristic, triage: triage,
                    createdAt: MailMergeKit.start, updatedAt: MailMergeKit.start)
    }

    static func item(_ ord: Int, origin: MailItemOrigin = .attachment, relevance: MailItemRelevance? = .requested,
                     pdf: MailPDFState = .hasPDF, title: String? = nil, doi: String? = nil, arxiv: String? = nil,
                     url: String? = nil, host: String? = nil, foundBy: MailItemFoundBy = .local, year: Int? = nil,
                     authors: [String] = [], paperID: String? = nil) -> MailItem {
        MailItem(ord: ord, cand: "c\(ord)", origin: origin, foundBy: foundBy, title: title, authors: authors, year: year,
                 ids: PaperIDs(doi: doi, arxivID: arxiv), url: url, urlOriginal: url, host: host, relevance: relevance,
                 pdfState: pdf, paperID: paperID, createdAt: MailMergeKit.start, updatedAt: MailMergeKit.start)
    }

    /// Inserts the card; `attachments[i]` (by item index) is stored as that item's PDF copy
    /// under `mailFiles/<message id>/<item id>.pdf`.
    @discardableResult
    static func insert(_ env: Env, _ m: MailMessage, items: [MailItem],
                       attachments: [Int: Data] = [:]) async throws -> (MailMessage, [MailItem]) {
        let (saved, rows) = try await env.db.insertMailMessage(m, items: items)
        var out: [MailItem] = []
        for (i, var row) in rows.enumerated() {
            if let data = attachments[i] {
                let rel = "\(saved.id)/\(row.id).pdf"
                let url = env.paths.mailFiles.appendingPathComponent(rel)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
                row.pdfPath = rel
                row.pdfState = .hasPDF
                row.pdfBytes = Int64(data.count)
                row = try await env.db.upsertMailItem(row, now: MailMergeKit.start)
            }
            out.append(row)
        }
        return (saved, out)
    }

    static func mailFileExists(_ env: Env, _ relative: String?) -> Bool {
        guard let relative else { return false }
        return FileManager.default.fileExists(atPath: env.paths.mailFiles.appendingPathComponent(relative).path)
    }
}
