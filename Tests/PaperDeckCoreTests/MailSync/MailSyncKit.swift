import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import PaperDeckCore

/// Shared harness of the MailSync suites: temp-rooted engines with a controllable clock, engine
/// and mail settings, fake transports (headers + contents from the mail-sync fixtures), a fake
/// metadata transport and zero-quota agent providers. Nothing here touches a real mail server,
/// the real library, the Keychain, or spawns a CLI.
enum MailSyncKit {
    static let calendar = LocalDate.gregorian(TimeZone(identifier: "America/Chicago")!)
    /// Wednesday 2026-09-30 10:00 America/Chicago.
    static let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 10))!

    // MARK: Boxes

    final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
        func update(_ f: (inout T) -> Void) { lock.withLock { f(&stored) } }
    }

    // MARK: Fixtures

    static func data(_ name: String, _ ext: String = "eml") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext,
                                                 subdirectory: "Fixtures/mail/mail-sync"))
        return try Data(contentsOf: url)
    }

    /// The fixture with its Message-ID (and optionally subject) replaced — distinct copies of one mail.
    static func variant(_ name: String, messageID: String, subject: String? = nil) throws -> Data {
        var text = String(decoding: try data(name), as: UTF8.self)
        guard let r = text.range(of: #"(?m)^Message-ID: .*$"#, options: .regularExpression) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text.replaceSubrange(r, with: "Message-ID: \(messageID)\r")
        if let subject, let s = text.range(of: #"(?m)^Subject: .*$"#, options: .regularExpression) {
            text.replaceSubrange(s, with: "Subject: \(subject)\r")
        }
        return Data(text.utf8)
    }

    /// The decoded PDF attachment of advisor-request-pdf.eml.
    static func advisorAttachment() throws -> Data {
        let content = try MIMEParser.parse(try data("advisor-request-pdf"), maxAttachmentBytes: 1 << 20)
        return try #require(content.attachments.first { $0.looksLikePDF }?.data)
    }

    /// A real one-page PDF (title line + body) with distinct bytes per call.
    static func realPDF(title: String) -> Data {
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        var y: CGFloat = 720
        let body = "Radial glia divide and give rise to cortical neurons over the course of development."
        for (text, size) in [(title, CGFloat(22)), ("Ada Lovelace, Grace Hopper", 11), ("Abstract", 12)]
            + Array(repeating: (body, CGFloat(10)), count: 8) + [("tag \(UUID().uuidString)", 8)] {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            ctx.textPosition = CGPoint(x: 54, y: y)
            CTLineDraw(line, ctx)
            y -= size * 1.8
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return out as Data
    }

    // MARK: Rules / settings

    static let advisorRule = SenderRule(id: "rule-advisor", pattern: "jsmith@wustl.edu", label: "Prof. Smith", kind: .advisor)
    static let colleagueRule = SenderRule(id: "rule-colleague", pattern: "@wustl.edu", label: "WashU", kind: .person)
    static let biorxivRule = SenderRule(id: "rule-biorxiv", pattern: "@alerts.highwire.org", label: "bioRxiv", kind: .alert)
    static let arxivRule = SenderRule(id: "rule-arxiv", pattern: "@arxiv.org", label: "arXiv", kind: .alert)

    static func account(_ id: String) -> MailAccount {
        MailAccount(id: id, kind: .folder, displayName: "Fake \(id)", folderPath: "/nonexistent/\(id)")
    }

    static func mailSettings(accounts: [MailAccount] = [account("acct-a")],
                             senders: [SenderRule] = [advisorRule, colleagueRule, biorxivRule, arxivRule],
                             aiMode: MailSettings.AIMode = .ai, dailyMax: Int = 30) -> MailSettings {
        MailSettings(enabled: true, accounts: accounts, senders: senders, syncMinutes: 0, aiMode: aiMode,
                     triageDailyMax: dailyMax)
    }

    // MARK: Fake transport

    /// Scripted MailSource: an ordered list of messages; the cursor is the index of the next one.
    actor FakeSource: MailSource {
        nonisolated let accountID: String
        private var messages: [(ref: String, data: Data)] = []
        private var failures: [String: Int] = [:]
        private var gone: Set<String> = []
        private(set) var listCalls = 0
        private(set) var fetched: [String] = []
        private(set) var captured: [String] = []
        private(set) var cursorsSeen: [String?] = []
        var statusValue: MailSourceStatus = .ready(detail: "fake ready")
        var listError: (any Error)?

        init(accountID: String) { self.accountID = accountID }

        func add(_ ref: String, _ data: Data) { messages.append((ref, data)) }
        /// The next `times` fetches of `ref` fail with a transient error.
        func failFetch(_ ref: String, times: Int) { failures[ref] = times }
        func setStatus(_ s: MailSourceStatus) { statusValue = s }
        /// `ref` was deleted on the server between listing and fetching.
        func vanish(_ ref: String) { gone.insert(ref) }
        func setListError(_ e: (any Error)?) { listError = e }

        func status() async -> MailSourceStatus { statusValue }

        func listHeaders(since: MailCursor?, limit: Int) async throws -> MailHeaderPage {
            listCalls += 1
            cursorsSeen.append(since?.value)
            if let e = listError { throw e }
            let start = since.flatMap { Int($0.value) } ?? 0
            let end = min(messages.count, start + max(1, limit))
            var headers: [MailHeader] = []
            if start < end {
                for m in messages[start..<end] {
                    var h = try MIMEParser.parseHeaders(m.data)
                    h.ref = m.ref
                    h.sizeBytes = m.data.count
                    headers.append(h)
                }
            }
            return MailHeaderPage(headers: headers, nextCursor: MailCursor("\(max(start, end))"), hasMore: end < messages.count)
        }

        func fetchMessage(_ header: MailHeader, maxBytes: Int) async throws -> MailContent {
            fetched.append(header.ref)
            if gone.contains(header.ref) { throw IMAPError.messageNotFound }
            if let n = failures[header.ref], n > 0 {
                failures[header.ref] = n - 1
                throw URLError(.timedOut)
            }
            guard let m = messages.first(where: { $0.ref == header.ref }) else { throw URLError(.fileDoesNotExist) }
            var content = try MIMEParser.parse(Data(m.data.prefix(maxBytes)), maxAttachmentBytes: maxBytes)
            content.header.ref = header.ref
            return content
        }

        func didCapture(_ header: MailHeader) async { captured.append(header.ref) }
    }

    // MARK: Fake metadata transport

    final class Fetcher: HTTPFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResult {
            lock.withLock { urls.append(url) }
            switch url.host {
            case "api.crossref.org":
                if url.path == "/works/10.1038/s41586-024-08351-7" {
                    return HTTPResult(status: 200, body: (try? MailSyncKit.data("crossref-s41586-024-08351-7", "json")) ?? Data())
                }
                if url.path == "/works" {
                    return HTTPResult(status: 200, body: Data(#"{"status":"ok","message":{"items":[]}}"#.utf8))
                }
                return HTTPResult(status: 404, body: Data("Resource not found.".utf8))
            case "api.biorxiv.org":
                return HTTPResult(status: 200, body: Data(#"{"messages":[{"status":"no posts found"}],"collection":[]}"#.utf8))
            case "export.arxiv.org":
                return HTTPResult(status: 200, body: Data(#"<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"></feed>"#.utf8))
            default:
                return HTTPResult(status: 404, body: Data())
            }
        }
        var requested: [String] { lock.withLock { urls.map(\.absoluteString) } }
    }

    final class VirtualClock: HostGate.Clock, @unchecked Sendable {
        private let lock = NSLock()
        private var t: TimeInterval = 1000
        func now() -> TimeInterval { lock.withLock { t } }
        func sleep(seconds: TimeInterval) async throws {
            try Task.checkCancellation()
            lock.withLock { t += max(0, seconds) }
        }
    }

    /// First-page reader returning a fixed title / DOI for every stored PDF.
    struct FakePDF: PDFExtracting {
        var title: String
        var doi: String?
        func extract(url: URL, fileName: String) async throws -> ExtractedPDF {
            ExtractedPDF(pageCount: 3, pageTexts: ["\(title)\nAbstract\nWe study cortex.", "p2", "p3"], charCount: 900,
                         isEncrypted: false, isLocked: false, isScanned: false, attributeTitle: nil, attributeAuthor: nil,
                         fontTitle: title, ids: PaperIDs(doi: doi), structure: DocumentStructure(), cardThumbnailJPEG: nil)
        }
    }

    // MARK: Scripted triage provider

    /// Answers triage requests with a fixed JSON (mode mock); records calls.
    actor ScriptedTriage: AgentProvider {
        nonisolated let id = "mock"
        private let answer: JSONValue
        private(set) var calls = 0
        init(_ answer: JSONValue) { self.answer = answer }
        func detect() async -> ProviderStatus { .ready(plan: "mock", version: "0.0.0-mock", path: "mock") }
        func generateCard(_ r: CardRequest, jobDir: URL) async -> AgentOutcome {
            calls += 1
            return .success(card: answer, meta: RunMeta(model: "mock", durationMs: 5, costUSD: 0, inputTokens: 10,
                                                        outputTokens: 10, numTurns: 1, variant: nil))
        }
    }

    // MARK: Engine

    struct Env: Sendable {
        let engine: Engine
        let root: URL
        let clock: Box<Date>
        let settings: Box<EngineSettings>
        let mail: Box<MailSettings>
        let sources: [String: FakeSource]

        var db: Database { engine.db }
        func source(_ id: String = "acct-a") -> FakeSource { sources[id]! }
        func advance(_ seconds: TimeInterval) { clock.value = clock.value.addingTimeInterval(seconds) }

        func cleanup() async {
            await engine.shutdown()
            await engine.db.close()
            try? FileManager.default.removeItem(at: root)
        }

        /// Sync now, then wait for post-processing (and whatever it enqueued) to settle.
        func sync() async {
            await engine.mail.syncNow()
            await engine.mail.waitUntilIdle()
        }

        func messages() async throws -> [MailMessage] {
            try await db.mailMessages(states: Set(MailState.allCases), limit: 1000)
        }

        func message(_ internetMessageID: String) async throws -> MailMessage {
            try #require(try await db.mailMessage(internetMessageID: internetMessageID))
        }
    }

    static func make(mode: AgentMode = .off, mail: MailSettings = mailSettings(), accounts: [String] = ["acct-a"],
                     fetcher: (any HTTPFetching)? = nil, mock: any AgentProvider = MockAgentProvider(),
                     pdf: (any PDFExtracting)? = nil, metadata: Bool = false, root: URL? = nil,
                     realSources: Bool = false, start: Bool = true) async throws -> Env {
        let root = try root ?? {
            let r = FileManager.default.temporaryDirectory.appendingPathComponent("pd-mailsync-\(UUID().uuidString)",
                                                                                  isDirectory: true)
            try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
            return r
        }()
        let clock = Box(MailSyncKit.start)
        let settings = Box(EngineSettings(plan: PlanSettings(dailyBudgetMinutes: 60), lang: .en, agentMode: mode,
                                          metadataLookup: metadata))
        let mailBox = Box(mail)
        var sources: [String: FakeSource] = [:]
        for id in accounts { sources[id] = FakeSource(accountID: id) }
        let lookup = sources
        let real: @Sendable (MailAccount) -> any MailSource = { account in
            MailSourceFactory.make(account, secrets: InMemoryMailSecretStore())
        }
        let fake: @Sendable (MailAccount) -> any MailSource = { account in
            lookup[account.id] ?? FakeSource(accountID: account.id)
        }
        let deps = Engine.Dependencies(
            loadSettings: { settings.value }, now: { clock.value }, calendar: calendar, fetcher: fetcher,
            claude: MockAgentProvider(), codex: MockAgentProvider(), mock: mock, sidecarDelay: .milliseconds(10),
            cliFacts: .inMemory(), loadMailSettings: { mailBox.value }, mailSecrets: InMemoryMailSecretStore(),
            mailSources: realSources ? real : fake,
            mailPDFExtractor: pdf, hostGate: HostGate(clock: VirtualClock()), assistBackends: [MockAssistBackend()])
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: deps)
        // Enqueue / wake poke the queue at once, so long naps keep ~40 parallel engines quiet.
        await engine.agents.configure(AgentQueue.Tuning(jobTimeout: .seconds(5), testTimeout: .seconds(5),
                                                        maxNap: .seconds(1), idleNap: .seconds(1),
                                                        loginRecheck: .seconds(1), shutdownWait: .seconds(2),
                                                        detectThrottle: .zero))
        if start { await engine.start() }
        return Env(engine: engine, root: root, clock: clock, settings: settings, mail: mailBox, sources: sources)
    }

    /// Runs `body` with a fresh engine and always cleans up.
    static func run(mode: AgentMode = .off, mail: MailSettings = mailSettings(), accounts: [String] = ["acct-a"],
                    fetcher: (any HTTPFetching)? = nil, mock: any AgentProvider = MockAgentProvider(),
                    pdf: (any PDFExtracting)? = nil, metadata: Bool = false,
                    _ body: (Env) async throws -> Void) async throws {
        let env = try await make(mode: mode, mail: mail, accounts: accounts, fetcher: fetcher, mock: mock, pdf: pdf,
                                 metadata: metadata)
        do {
            try await body(env)
        } catch {
            await env.cleanup()
            throw error
        }
        await env.cleanup()
    }

    /// Inserts a library paper (row only; the file is not needed for matching).
    @discardableResult
    static func addPaper(_ env: Env, sha256: String? = nil, doi: String? = nil, title: String = "Library paper") async throws -> Paper {
        let sha = sha256 ?? (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let folder = "Papers/2026_Test_\(sha.prefix(8))"
        try FileManager.default.createDirectory(at: env.engine.paths.library.appendingPathComponent(folder),
                                                withIntermediateDirectories: true)
        let paper = Paper(sha256: sha, fileSize: 100, ids: PaperIDs(doi: doi), title: title, titleRank: .api,
                          metaSource: .crossref, folder: folder, pdfName: "paper.pdf", originalName: "paper.pdf",
                          stage: .ready, addedAt: env.clock.value, updatedAt: env.clock.value)
        return try await env.db.insertPaper(paper, checklist: [])
    }

    /// Polls `condition` every 10 ms for up to `timeout`.
    static func eventually(_ timeout: Duration = .seconds(20), _ condition: () async throws -> Bool) async -> Bool {      // generous on a loaded machine (ENV-1)
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if (try? await condition()) == true { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return (try? await condition()) == true
    }

    /// Every byte PaperDeck persisted under the root (DB + WAL + files), for privacy scans.
    static func persistedBytes(_ root: URL) -> Data {
        var out = Data()
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        for case let url as URL in e {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
               let d = try? Data(contentsOf: url) { out.append(d) }
        }
        return out
    }
}
