import Foundation
import Testing
@testable import PaperDeckCore

/// Harness of the MailFixes suites: temp-rooted engines with a controllable clock and settings,
/// zero-quota mock providers, no metadata transport, and an event log whose waits are driven by
/// the events themselves (a sentinel event marks "everything sent so far was seen"; timeouts only
/// guard against a hang). Nothing touches the network, a mail server, an AI CLI, the Keychain
/// or the user's library.
enum MailFixesKit {
    static let calendar = LocalDate.gregorian(TimeZone(identifier: "America/Chicago")!)
    /// Wednesday 2026-09-30 10:00 America/Chicago.
    static let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 10))!
    static let day: TimeInterval = 86_400

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

    // MARK: Events

    /// Every engine event in order; `first(after:where:)` resumes when a matching one arrives.
    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [EngineEvent] = []
        private var waiters: [UUID: (from: Int, match: @Sendable (EngineEvent) -> Bool,
                                     cont: CheckedContinuation<EngineEvent?, Never>)] = [:]
        private var task: Task<Void, Never>?
        private let hub: EventHub<EngineEvent>
        private static let sentinelPrefix = "mailfixes-sentinel-"

        init(hub: EventHub<EngineEvent>) {
            self.hub = hub
            let stream = hub.subscribe()
            task = Task { [weak self] in for await e in stream { self?.append(e) } }
        }
        deinit { task?.cancel() }

        var count: Int { lock.withLock { items.count } }

        private func append(_ e: EngineEvent) {
            let ready = lock.withLock { () -> [CheckedContinuation<EngineEvent?, Never>] in
                items.append(e)
                let index = items.count - 1
                let hits = waiters.filter { index >= $0.value.from && $0.value.match(e) }
                for id in hits.keys { waiters[id] = nil }
                return hits.values.map(\.cont)
            }
            for c in ready { c.resume(returning: e) }
        }

        /// The first event at index ≥ `from` matching `match` (already seen or still to come);
        /// nil only when none arrives within `timeout` (a failing test, never a pacing device).
        func first(after from: Int = 0, timeout: Duration = .seconds(20),
                   where match: @escaping @Sendable (EngineEvent) -> Bool) async -> EngineEvent? {
            let id = UUID()
            return await withCheckedContinuation { (c: CheckedContinuation<EngineEvent?, Never>) in
                let seen = lock.withLock { () -> EngineEvent? in
                    if let e = items.indices.first(where: { $0 >= from && match(items[$0]) }).map({ items[$0] }) { return e }
                    waiters[id] = (from, match, c)
                    return nil
                }
                if let seen { c.resume(returning: seen); return }
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.expire(id)
                }
            }
        }

        private func expire(_ id: UUID) {
            let c = lock.withLock { waiters.removeValue(forKey: id)?.cont }
            c?.resume(returning: nil)
        }

        /// Returns once every event sent before the call has been collected.
        func drain() async {
            let marker = Self.sentinelPrefix + UUID().uuidString
            hub.send(.toast(Toast(id: marker, kind: .info, message: marker)))
            _ = await first { if case .toast(let t) = $0 { return t.id == marker }; return false }
        }

        var toasts: [Toast] {
            lock.withLock {
                items.compactMap { if case .toast(let t) = $0, !t.id.hasPrefix(Self.sentinelPrefix) { return t }; return nil }
            }
        }
        var matchedToasts: [Toast] { toasts.filter { $0.message.hasPrefix("Matched an email request") } }
        var statuses: [AgentQueueStatus] {
            lock.withLock { items.compactMap { if case .agentStatus(let s) = $0 { return s }; return nil } }
        }
    }

    // MARK: Engine

    struct Env: Sendable {
        let engine: Engine
        let root: URL
        let clock: Box<Date>
        let settings: Box<EngineSettings>
        let mail: Box<MailSettings>
        let events: EventLog

        var db: Database { engine.db }
        var ctx: EngineContext { engine.ctx }
        var mailFiles: URL { engine.paths.mailFiles }
        func advance(_ seconds: TimeInterval) { clock.value = clock.value.addingTimeInterval(seconds) }

        func cleanup() async {
            await engine.shutdown()
            await engine.db.close()
            try? FileManager.default.removeItem(at: root)
        }

        func item(_ id: String) async throws -> MailItem { try #require(try await db.mailItem(id: id)) }
        func message(_ id: String) async throws -> MailMessage { try #require(try await db.mailMessage(id: id)) }
        func allMessages() async throws -> [MailMessage] {
            try await db.mailMessages(states: Set(MailState.allCases), limit: 1000)
        }
    }

    static func make(mode: AgentMode = .off, lang: UILang = .en, mail: MailSettings = MailSettings(),
                     mock: any AgentProvider = MockAgentProvider(),
                     sources: (@Sendable (MailAccount) -> any MailSource)? = nil) async throws -> Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-mailfixes-\(UUID().uuidString)",
                                                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clock = Box(start)
        let settings = Box(EngineSettings(plan: PlanSettings(dailyBudgetMinutes: 60), lang: lang, agentMode: mode,
                                          metadataLookup: false))
        let mailBox = Box(mail)
        let deps = Engine.Dependencies(
            loadSettings: { settings.value }, now: { clock.value }, calendar: calendar, fetcher: nil,
            claude: MockAgentProvider(), codex: MockAgentProvider(), mock: mock, sidecarDelay: .milliseconds(5),
            cliFacts: .inMemory(), loadMailSettings: { mailBox.value }, mailSecrets: InMemoryMailSecretStore(),
            mailSources: sources ?? { account in MailFixesKit.NoSource(accountID: account.id) }, assistBackends: [MockAssistBackend()])
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: deps)
        return Env(engine: engine, root: root, clock: clock, settings: settings, mail: mailBox,
                   events: EventLog(hub: engine.events))
    }

    /// Runs `body` with a fresh (not started) engine and always cleans up.
    static func run(mode: AgentMode = .off, lang: UILang = .en, mail: MailSettings = MailSettings(),
                    mock: any AgentProvider = MockAgentProvider(),
                    sources: (@Sendable (MailAccount) -> any MailSource)? = nil,
                    _ body: (Env) async throws -> Void) async throws {
        let env = try await make(mode: mode, lang: lang, mail: mail, mock: mock, sources: sources)
        do { try await body(env) } catch {
            await env.cleanup()
            throw error
        }
        await env.cleanup()
    }

    /// A transport that never has anything (the loop's housekeeping runs without mail traffic).
    struct NoSource: MailSource {
        let accountID: String
        func status() async -> MailSourceStatus { .ready(detail: "none") }
        func listHeaders(since: MailCursor?, limit: Int) async throws -> MailHeaderPage {
            MailHeaderPage(headers: [], nextCursor: since, hasMore: false)
        }
        func fetchMessage(_ header: MailHeader, maxBytes: Int) async throws -> MailContent {
            throw FolderMailSourceError.invalidReference
        }
    }

    // MARK: Library and cards

    /// A ready library paper (row + folder; no PDF needed for matching).
    @discardableResult
    static func addPaper(_ env: Env, doi: String? = nil, arxiv: String? = nil, title: String = "Library paper") async throws -> Paper {
        let sha = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let folder = "Papers/2026_Fix_\(sha.prefix(8))"
        try FileManager.default.createDirectory(at: env.engine.paths.library.appendingPathComponent(folder),
                                                withIntermediateDirectories: true)
        let paper = Paper(sha256: sha, fileSize: 100, ids: PaperIDs(doi: doi, arxivID: arxiv), title: title,
                          titleRank: .api, metaSource: .crossref, folder: folder, pdfName: "paper.pdf",
                          originalName: "paper.pdf", stage: .ready, addedAt: env.clock.value, updatedAt: env.clock.value)
        return try await env.db.insertPaper(paper, checklist: [])
    }

    static func message(kind: SenderKind = .advisor, subject: String = "Papers for Friday", state: MailState = .pending,
                        handledAt: Date? = nil, snoozedUntil: Date? = nil, body: String? = "Please read [c1].") -> MailMessage {
        MailMessage(accountID: "acct-1", internetMessageID: "<\(UUID().uuidString.lowercased())@wustl.edu>",
                    fromAddress: "jsmith@wustl.edu", fromName: "Jane Smith", senderKind: kind, subject: subject,
                    receivedAt: start.addingTimeInterval(-3_600), snippet: body == nil ? nil : "Please read",
                    bodyText: body, state: state, snoozedUntil: snoozedUntil,
                    triageSource: .heuristic,
                    triage: MailTriage(hasReadingRequest: true, requestKind: .advisorRequest, summary: "Read it.",
                                       requester: nil, dueDate: nil, dueEvidence: nil, dueConfidence: nil,
                                       priority: .normal, confidence: 0.9),
                    createdAt: start, updatedAt: start, handledAt: handledAt)
    }

    static func item(_ ord: Int, origin: MailItemOrigin = .link, relevance: MailItemRelevance? = .requested,
                     pdf: MailPDFState = .needsPDF, doi: String? = nil, arxiv: String? = nil,
                     downloadError: String? = nil) -> MailItem {
        MailItem(ord: ord, cand: "c\(ord)", origin: origin, title: "Row \(ord)", ids: PaperIDs(doi: doi, arxivID: arxiv),
                 url: doi.map { "https://doi.org/\($0)" }, urlOriginal: doi.map { "https://doi.org/\($0)" },
                 host: "doi.org", relevance: relevance, pdfState: pdf, downloadError: downloadError,
                 createdAt: start, updatedAt: start)
    }

    /// Inserts a card; `files[i]` (by item index) is stored as that row's attachment copy.
    @discardableResult
    static func insert(_ env: Env, _ m: MailMessage, items: [MailItem],
                       files: [Int: Data] = [:]) async throws -> (MailMessage, [MailItem]) {
        let (saved, rows) = try await env.db.insertMailMessage(m, items: items)
        var out: [MailItem] = []
        for (i, var row) in rows.enumerated() {
            if let data = files[i] {
                let rel = "\(saved.id)/\(row.id).pdf"
                let url = env.mailFiles.appendingPathComponent(rel)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
                row.pdfPath = rel
                row.pdfState = .hasPDF
                row = try await env.db.upsertMailItem(row, now: start)
            }
            out.append(row)
        }
        return (saved, out)
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: Fixtures

    static func fixture(_ name: String, _ ext: String = "eml") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext,
                                                 subdirectory: "Fixtures/mail/mail-fixes"))
        return try Data(contentsOf: url)
    }

    static let pdfStub = Data("%PDF-1.4\n1 0 obj << >> endobj\ntrailer << >>\n%%EOF\n".utf8)
}
