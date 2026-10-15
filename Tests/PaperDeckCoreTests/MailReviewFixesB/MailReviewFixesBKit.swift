import Foundation
import Testing
@testable import PaperDeckCore

/// Harness of the review-fix (sync) suites: engines with an injectable transport per account
/// (scripted fakes, or the real folder source on a temp folder), a controllable clock and
/// engine / mail settings. Nothing here touches a real mail server, the real library, the
/// Keychain, or spawns a CLI (agent mode off or mock).
enum RFB {
    typealias K = MailSyncKit

    // MARK: Engine

    struct Env: Sendable {
        let engine: Engine
        let root: URL
        let clock: K.Box<Date>
        let settings: K.Box<EngineSettings>
        let mail: K.Box<MailSettings>

        var db: Database { engine.db }
        func advance(_ seconds: TimeInterval) { clock.value = clock.value.addingTimeInterval(seconds) }

        func sync() async {
            await engine.mail.syncNow()
            await engine.mail.waitUntilIdle()
        }

        func messages() async throws -> [MailMessage] {
            try await db.mailMessages(states: Set(MailState.allCases), limit: 1000)
        }

        func close(removeRoot: Bool = true) async {
            await engine.shutdown()
            await engine.db.close()
            if removeRoot { try? FileManager.default.removeItem(at: root) }
        }
    }

    static func tempRoot(_ tag: String = "pd-rfb") throws -> URL {
        let r = FileManager.default.temporaryDirectory.appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        return r
    }

    /// An engine whose accounts use `sources(account)` (nil → the real factory: folder / IMAP
    /// with an in-memory secret store).
    static func make(root: URL? = nil, mode: AgentMode = .off, mail: MailSettings,
                     lang: UILang = .en, mock: any AgentProvider = MockAgentProvider(),
                     fetcher: (any HTTPFetching)? = nil, metadata: Bool = false,
                     clock: K.Box<Date> = K.Box(K.start),
                     sources: (@Sendable (MailAccount) -> (any MailSource)?)? = nil,
                     start: Bool = true) async throws -> Env {
        let root = try root ?? tempRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings = K.Box(EngineSettings(plan: PlanSettings(dailyBudgetMinutes: 60), lang: lang, agentMode: mode,
                                            metadataLookup: metadata))
        let mailBox = K.Box(mail)
        let secrets = InMemoryMailSecretStore()
        let factory: @Sendable (MailAccount) -> any MailSource = { account in
            if let s = sources?(account) { return s }
            return MailSourceFactory.make(account, secrets: secrets, lang: settings.value.lang)
        }
        let deps = Engine.Dependencies(
            loadSettings: { settings.value }, now: { clock.value }, calendar: K.calendar, fetcher: fetcher,
            claude: MockAgentProvider(), codex: MockAgentProvider(), mock: mock, sidecarDelay: .milliseconds(10),
            cliFacts: .inMemory(), loadMailSettings: { mailBox.value }, mailSecrets: secrets,
            mailSources: factory, hostGate: HostGate(clock: K.VirtualClock()), assistBackends: [MockAssistBackend()])
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: deps)
        await engine.agents.configure(AgentQueue.Tuning(jobTimeout: .seconds(5), testTimeout: .seconds(5),
                                                        maxNap: .seconds(1), idleNap: .seconds(1),
                                                        loginRecheck: .seconds(1), shutdownWait: .seconds(2),
                                                        detectThrottle: .zero))
        if start { await engine.start() }
        return Env(engine: engine, root: root, clock: clock, settings: settings, mail: mailBox)
    }

    /// Runs `body` with a fresh engine and always cleans up.
    static func run(mode: AgentMode = .off, mail: MailSettings, lang: UILang = .en,
                    mock: any AgentProvider = MockAgentProvider(),
                    sources: (@Sendable (MailAccount) -> (any MailSource)?)? = nil,
                    _ body: (Env) async throws -> Void) async throws {
        let env = try await make(mode: mode, mail: mail, lang: lang, mock: mock, sources: sources)
        do {
            try await body(env)
        } catch {
            await env.close()
            throw error
        }
        await env.close()
    }

    static func settings(accounts: [MailAccount], senders: [SenderRule] = [K.advisorRule, K.biorxivRule, K.arxivRule],
                         aiMode: MailSettings.AIMode = .ai, syncMinutes: Int = 0, dailyMax: Int = 30) -> MailSettings {
        MailSettings(enabled: true, accounts: accounts, senders: senders, syncMinutes: syncMinutes, aiMode: aiMode,
                     triageDailyMax: dailyMax)
    }

    static func fakeAccount(_ id: String = "acct-f", lookback: Int = 14) -> MailAccount {
        MailAccount(id: id, kind: .folder, displayName: "Fake \(id)", lookbackDays: lookback, folderPath: "/nonexistent/\(id)")
    }

    /// An IMAP-kind account served by a fake (no network): sign-in problems are its concern.
    static func fakeIMAPAccount(_ id: String = "acct-f") -> MailAccount {
        MailAccount(id: id, kind: .imap, displayName: "Fake IMAP \(id)", lookbackDays: 14, imapPreset: .gmail,
                    host: "imap.invalid", port: 993, username: "me@example.org", mailbox: "INBOX")
    }

    /// A plain synthetic email (CRLF).
    static func eml(from: String, messageID: String, subject: String = "Hello", body: String = "Please read the paper.",
                    extraHeaders: [String] = []) -> Data {
        let lines = ["From: Sender <\(from)>", "To: yi@wustl.edu", "Subject: \(subject)",
                     "Date: Tue, 29 Sep 2026 14:05:00 -0500", "Message-ID: \(messageID)"] + extraHeaders
            + ["MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8", "", body, ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    static func eventually(_ timeout: Duration = .seconds(20), _ condition: () async throws -> Bool) async -> Bool {      // generous on a loaded machine (ENV-1)
        await K.eventually(timeout, condition)
    }

    // MARK: Fake transport with a folder-like ledger cursor

    /// Scripted source whose cursor is the set of refs already listed (like the folder ledger):
    /// `listHeaders` returns the messages not listed yet, `deferring` makes refs new again.
    /// Counts `status()` calls (each one would be a sign-in for IMAP).
    actor LedgerSource: MailSource {
        nonisolated let accountID: String
        private var messages: [(ref: String, data: Data)] = []
        private var failures: [String: Int] = [:]
        private var fetchDelay: Duration = .zero
        private(set) var statusCalls = 0
        private(set) var listCalls = 0
        private(set) var fetched: [String] = []
        private(set) var cursorsSeen: [String?] = []
        var statusValue: MailSourceStatus = .ready(detail: "ledger ready")
        let supportsDeferral: Bool

        init(accountID: String, supportsDeferral: Bool = true) {
            self.accountID = accountID
            self.supportsDeferral = supportsDeferral
        }

        func add(_ ref: String, _ data: Data) { messages.append((ref, data)) }
        func failFetch(_ ref: String, times: Int) { failures[ref] = times }
        func setStatus(_ s: MailSourceStatus) { statusValue = s }
        func setFetchDelay(_ d: Duration) { fetchDelay = d }

        func status() async -> MailSourceStatus {
            statusCalls += 1
            return statusValue
        }

        private static func seen(_ c: MailCursor?) -> [String] {
            guard let c, !c.value.isEmpty else { return [] }
            return c.value.components(separatedBy: "\n")
        }

        private static func cursor(_ refs: [String]) -> MailCursor { MailCursor(refs.joined(separator: "\n")) }

        func listHeaders(since: MailCursor?, limit: Int) async throws -> MailHeaderPage {
            listCalls += 1
            cursorsSeen.append(since?.value)
            var seen = Self.seen(since)
            let fresh = messages.filter { !seen.contains($0.ref) }
            let page = Array(fresh.prefix(max(1, limit)))
            var headers: [MailHeader] = []
            for m in page {
                var h = try MIMEParser.parseHeaders(m.data)
                h.ref = m.ref
                h.sizeBytes = m.data.count
                headers.append(h)
                seen.append(m.ref)
            }
            return MailHeaderPage(headers: headers, nextCursor: Self.cursor(seen), hasMore: fresh.count > page.count)
        }

        func fetchMessage(_ header: MailHeader, maxBytes: Int) async throws -> MailContent {
            fetched.append(header.ref)
            if fetchDelay > .zero { try await Task.sleep(for: fetchDelay) }
            if let n = failures[header.ref], n > 0 {
                failures[header.ref] = n - 1
                throw URLError(.timedOut)
            }
            guard let m = messages.first(where: { $0.ref == header.ref }) else { throw IMAPError.messageNotFound }
            var content = try MIMEParser.parse(m.data, maxAttachmentBytes: maxBytes)
            content.header.ref = header.ref
            return content
        }

        func deferring(_ refs: [String], in cursor: MailCursor) async -> MailCursor? {
            guard supportsDeferral else { return nil }
            return Self.cursor(Self.seen(cursor).filter { !refs.contains($0) })
        }
    }

    /// A one-way gate: `wait()` returns once the test calls `open()` (at once after that).
    /// Cancellation does not open it.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let now = lock.withLock { () -> Bool in
                    if opened { return true }
                    waiting.append(c)
                    return false
                }
                if now { c.resume() }
            }
        }

        func open() {
            let resume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                opened = true
                defer { waiting = [] }
                return waiting
            }
            resume.forEach { $0.resume() }
        }
    }

    /// Ignores cancellation: finishes only once `gate` is opened, whatever happens meanwhile.
    /// `finished` turns true once the task is done.
    static func stubbornTask(until gate: Gate, finished: K.Box<Bool>? = nil) -> Task<Void, Never> {
        Task.detached {
            await gate.wait()
            finished?.value = true
        }
    }

    /// A join deadline that has already passed: returns at once, noting the wait it was asked for.
    static func deadlinePassed(_ asked: K.Box<[Duration]>) -> MailSyncActor.JoinSleep {
        { d in asked.update { $0.append(d) } }
    }

    /// A join deadline that never passes: returns only when its timer is cancelled (every task
    /// finished first).
    static let deadlineNeverPasses: MailSyncActor.JoinSleep = { _ in
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        await withTaskCancellationHandler {
            for await _ in stream {}
        } onCancel: {
            continuation.finish()
        }
    }
}
