import Foundation
import Testing
@testable import PaperDeckCore

/// Harness of the round-4 core suites: temp-rooted engines like `MailSyncKit.make`, plus a hook
/// inside the mail-settings read (to act between two steps of a triage hand-off), a metadata
/// transport that records every request, and a scripted source that models a look-back the way
/// IMAP does (no cursor + look-back 0 = only mail that arrives from now on). Nothing touches a
/// real mail or metadata server, the user's library, the Keychain, or spawns a CLI (agent mode
/// off / mock).
enum R4 {
    typealias K = MailSyncKit

    /// Runs `action` inside the `n`-th mail-settings read after `arm` (once).
    final class MailHook: @unchecked Sendable {
        private let lock = NSLock()
        private var countdown = 0
        private var action: (@Sendable () -> Void)?
        func arm(onRead n: Int, _ a: @escaping @Sendable () -> Void) {
            lock.withLock { countdown = n; action = a }
        }
        func fire() {
            let a = lock.withLock { () -> (@Sendable () -> Void)? in
                guard action != nil else { return nil }
                countdown -= 1
                guard countdown <= 0 else { return nil }
                defer { action = nil }
                return action
            }
            a?()
        }
    }

    /// Records every metadata request; answers like `MailSyncKit.Fetcher` (one known DOI, empty
    /// title searches, nothing else found).
    final class Recorder: HTTPFetching, @unchecked Sendable {
        private let inner = K.Fetcher()
        func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResult {
            try await inner.get(url, headers: headers, timeout: timeout)
        }
        var requested: [String] { inner.requested }
        var titleSearches: [String] { requested.filter { $0.contains("query.bibliographic") || $0.contains("search=") } }
    }

    struct Env: Sendable {
        let engine: Engine
        let root: URL
        let clock: K.Box<Date>
        let settings: K.Box<EngineSettings>
        let mail: K.Box<MailSettings>
        let hook: MailHook
        let source: K.FakeSource

        var db: Database { engine.db }
        var paths: AppPaths { AppPaths.rooted(at: root) }
        var kEnv: K.Env { K.Env(engine: engine, root: root, clock: clock, settings: settings, mail: mail, sources: ["acct-a": source]) }

        func sync() async {
            await engine.mail.syncNow()
            await engine.mail.waitUntilIdle()
        }

        func message(_ mid: String) async throws -> MailMessage {
            try #require(try await db.mailMessage(internetMessageID: mid))
        }

        func close() async {
            await engine.shutdown()
            await engine.db.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func run(mode: AgentMode = .off, mail: MailSettings = K.mailSettings(), fetcher: (any HTTPFetching)? = nil,
                    mock: any AgentProvider = MockAgentProvider(), pdf: (any PDFExtracting)? = nil,
                    sources: (@Sendable (MailAccount) -> (any MailSource)?)? = nil, start: Bool = true,
                    _ body: (Env) async throws -> Void) async throws {
        let root = try RFB.tempRoot("pd-r4")
        let clock = K.Box(K.start)
        let settings = K.Box(EngineSettings(plan: PlanSettings(dailyBudgetMinutes: 60), lang: .en, agentMode: mode,
                                            metadataLookup: fetcher != nil))
        let mailBox = K.Box(mail)
        let hook = MailHook()
        let source = K.FakeSource(accountID: "acct-a")
        let factory: @Sendable (MailAccount) -> any MailSource = { account in
            if let s = sources?(account) { return s }
            return account.id == "acct-a" ? source : K.FakeSource(accountID: account.id)
        }
        let deps = Engine.Dependencies(
            loadSettings: { settings.value }, now: { clock.value }, calendar: K.calendar, fetcher: fetcher,
            claude: MockAgentProvider(), codex: MockAgentProvider(), mock: mock, sidecarDelay: .milliseconds(10),
            cliFacts: .inMemory(), loadMailSettings: {
                hook.fire()
                return mailBox.value
            }, mailSecrets: InMemoryMailSecretStore(), mailSources: factory, mailPDFExtractor: pdf,
            hostGate: HostGate(clock: K.VirtualClock()), assistBackends: [MockAssistBackend()])
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: deps)
        await engine.agents.configure(AgentQueue.Tuning(jobTimeout: .seconds(5), testTimeout: .seconds(5),
                                                        maxNap: .seconds(1), idleNap: .seconds(1),
                                                        loginRecheck: .seconds(1), shutdownWait: .seconds(2),
                                                        detectThrottle: .zero))
        if start { await engine.start() }
        let env = Env(engine: engine, root: root, clock: clock, settings: settings, mail: mailBox, hook: hook, source: source)
        do { try await body(env) } catch {
            await env.close()
            throw error
        }
        await env.close()
    }

    /// A synthetic email with one PDF attachment (CRLF).
    static func emlWithPDF(from: String, messageID: String, subject: String, body: [String], pdf: Data,
                           fileName: String = "draft.pdf", extraHeaders: [String] = []) -> Data {
        let b64 = pdf.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let lines = ["From: Sender <\(from)>", "To: yi@wustl.edu", "Subject: \(subject)",
                     "Date: Tue, 29 Sep 2026 14:05:00 -0500", "Message-ID: \(messageID)"] + extraHeaders
            + ["MIME-Version: 1.0", "Content-Type: multipart/mixed; boundary=\"r4b\"", "",
               "--r4b", "Content-Type: text/plain; charset=utf-8", ""] + body
            + ["", "--r4b", "Content-Type: application/pdf; name=\"\(fileName)\"",
               "Content-Disposition: attachment; filename=\"\(fileName)\"", "Content-Transfer-Encoding: base64", "",
               b64, "--r4b--", ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// Scripted source with an IMAP-like look-back: each message has an arrival day; without a
    /// cursor it lists the look-back (look-back 0: nothing that is already there), with one it
    /// lists what arrived after the cursor's mark plus the cursor's retry refs. Its retry list
    /// keeps at most `retryCap` refs (the rest are reported dropped). `relisting` keeps the
    /// retry list and lists the look-back again (when `supportsRelisting`).
    actor LookbackSource: MailSource {
        nonisolated let accountID: String
        private let lookbackDays: Int
        private let retryCap: Int
        private let supportsRelisting: Bool
        private var messages: [(ref: String, day: Int, data: Data)] = []      // day: days before "today"
        private var failures: [String: Int] = [:]
        private(set) var cursorsSeen: [String?] = []
        private(set) var listed: [[String]] = []

        init(accountID: String, lookbackDays: Int, retryCap: Int = 1, supportsRelisting: Bool = true) {
            self.accountID = accountID; self.lookbackDays = lookbackDays; self.retryCap = retryCap
            self.supportsRelisting = supportsRelisting
        }

        func add(_ ref: String, daysAgo: Int, _ data: Data) { messages.append((ref, daysAgo, data)) }
        func failFetch(_ ref: String, times: Int) { failures[ref] = times }
        func status() async -> MailSourceStatus { .ready(detail: "lookback source") }

        /// Cursor: "mark|retry1,retry2" — mark = index of the next message to list (arrival order).
        private struct State { var mark: Int; var retry: [String]; var since: Int? }
        private static func parse(_ c: MailCursor?) -> State? {
            guard let c else { return nil }
            let parts = c.value.components(separatedBy: "|")
            guard parts.count == 3, let mark = Int(parts[0]) else { return nil }
            let retry = parts[1].isEmpty ? [] : parts[1].components(separatedBy: ",")
            return State(mark: mark, retry: retry, since: Int(parts[2]))
        }
        private static func cursor(_ s: State) -> MailCursor {
            MailCursor("\(s.mark)|\(s.retry.joined(separator: ","))|\(s.since.map(String.init) ?? "")")
        }

        func listHeaders(since: MailCursor?, limit: Int) async throws -> MailHeaderPage {
            cursorsSeen.append(since?.value)
            var state = Self.parse(since) ?? State(mark: lookbackDays > 0 ? 0 : messages.count, retry: [],
                                                   since: lookbackDays > 0 ? lookbackDays : nil)
            var refs: [String] = state.retry
            // A look-back being listed: the messages of the window from `mark` on; else the new ones.
            for (i, m) in messages.enumerated() where i >= state.mark {
                if let window = state.since, m.day > window { continue }
                if !refs.contains(m.ref) { refs.append(m.ref) }
            }
            state.mark = messages.count
            state.retry = []
            state.since = nil
            listed.append(refs)
            var headers: [MailHeader] = []
            for ref in refs {
                guard let m = messages.first(where: { $0.ref == ref }) else { continue }
                var h = try MIMEParser.parseHeaders(m.data)
                h.ref = m.ref
                h.sizeBytes = m.data.count
                headers.append(h)
            }
            return MailHeaderPage(headers: headers, nextCursor: Self.cursor(state), hasMore: false)
        }

        func fetchMessage(_ header: MailHeader, maxBytes: Int) async throws -> MailContent {
            if let n = failures[header.ref], n > 0 {
                failures[header.ref] = n - 1
                throw URLError(.timedOut)
            }
            guard let m = messages.first(where: { $0.ref == header.ref }) else { throw IMAPError.messageNotFound }
            var content = try MIMEParser.parse(m.data, maxAttachmentBytes: maxBytes)
            content.header.ref = header.ref
            return content
        }

        func deferral(_ refs: [String], in cursor: MailCursor) async -> MailDeferral? {
            guard var state = Self.parse(cursor) else { return nil }
            var retry = state.retry
            for r in refs where !retry.contains(r) { retry.append(r) }
            let dropped = retry.count > retryCap ? Array(retry.dropFirst(retryCap)) : []
            state.retry = Array(retry.prefix(retryCap))
            return MailDeferral(cursor: Self.cursor(state), dropped: dropped)
        }

        func relisting(_ cursor: MailCursor) async -> MailCursor? {
            guard supportsRelisting, lookbackDays > 0, let old = Self.parse(cursor) else { return nil }
            return Self.cursor(State(mark: 0, retry: old.retry, since: lookbackDays))
        }
    }
}
