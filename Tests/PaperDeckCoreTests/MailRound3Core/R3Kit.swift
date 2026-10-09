import Foundation
import Testing
@testable import PaperDeckCore

/// Harness of the round-3 core suites: temp-rooted engines like `RFB.make`, plus a counted
/// source factory, a hook inside the engine-settings read (to act between two steps of an
/// engine operation) and a scripted source whose retry list has a small cap. Nothing touches a
/// real mail server, the user's library, the Keychain, or spawns a CLI (agent mode off / mock).
enum R3 {
    typealias K = MailSyncKit

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    /// A one-shot action run inside the next engine-settings read after `arm`.
    final class SettingsHook: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (@Sendable () -> Void)?
        func arm(_ a: @escaping @Sendable () -> Void) { lock.withLock { action = a } }
        func fire() {
            let a = lock.withLock { () -> (@Sendable () -> Void)? in
                defer { action = nil }
                return action
            }
            a?()
        }
    }

    struct Env: Sendable {
        let engine: Engine
        let root: URL
        let clock: K.Box<Date>
        let settings: K.Box<EngineSettings>
        let mail: K.Box<MailSettings>
        let made: Counter
        let hook: SettingsHook

        var db: Database { engine.db }
        var paths: AppPaths { AppPaths.rooted(at: root) }
        func advance(_ seconds: TimeInterval) { clock.value = clock.value.addingTimeInterval(seconds) }

        func sync() async {
            await engine.mail.syncNow()
            await engine.mail.waitUntilIdle()
        }

        func messages() async throws -> [MailMessage] {
            try await db.mailMessages(states: Set(MailState.allCases), limit: 1000)
        }

        func close() async {
            await engine.shutdown()
            await engine.db.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func make(mode: AgentMode = .off, mail: MailSettings, lang: UILang = .en,
                     mock: any AgentProvider = MockAgentProvider(), pdf: (any PDFExtracting)? = nil,
                     sources: (@Sendable (MailAccount) -> (any MailSource)?)? = nil,
                     start: Bool = true) async throws -> Env {
        let root = try RFB.tempRoot("pd-r3")
        let clock = K.Box(K.start)
        let settings = K.Box(EngineSettings(plan: PlanSettings(dailyBudgetMinutes: 60), lang: lang, agentMode: mode,
                                            metadataLookup: false))
        let mailBox = K.Box(mail)
        let secrets = InMemoryMailSecretStore()
        let made = Counter()
        let hook = SettingsHook()
        let factory: @Sendable (MailAccount) -> any MailSource = { account in
            made.bump()
            if let s = sources?(account) { return s }
            return MailSourceFactory.make(account, secrets: secrets, lang: settings.value.lang)
        }
        let deps = Engine.Dependencies(
            loadSettings: {
                hook.fire()
                return settings.value
            }, now: { clock.value }, calendar: K.calendar, fetcher: nil,
            claude: MockAgentProvider(), codex: MockAgentProvider(), mock: mock, sidecarDelay: .milliseconds(10),
            cliFacts: .inMemory(), loadMailSettings: { mailBox.value }, mailSecrets: secrets,
            mailSources: factory, mailPDFExtractor: pdf, hostGate: HostGate(clock: K.VirtualClock()), assistBackends: [MockAssistBackend()])
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: deps)
        await engine.agents.configure(AgentQueue.Tuning(jobTimeout: .seconds(5), testTimeout: .seconds(5),
                                                        maxNap: .seconds(1), idleNap: .seconds(1),
                                                        loginRecheck: .seconds(1), shutdownWait: .seconds(2),
                                                        detectThrottle: .zero))
        if start { await engine.start() }
        return Env(engine: engine, root: root, clock: clock, settings: settings, mail: mailBox, made: made, hook: hook)
    }

    static func run(mode: AgentMode = .off, mail: MailSettings, lang: UILang = .en,
                    mock: any AgentProvider = MockAgentProvider(), pdf: (any PDFExtracting)? = nil,
                    sources: (@Sendable (MailAccount) -> (any MailSource)?)? = nil, start: Bool = true,
                    _ body: (Env) async throws -> Void) async throws {
        let env = try await make(mode: mode, mail: mail, lang: lang, mock: mock, pdf: pdf, sources: sources, start: start)
        do { try await body(env) } catch {
            await env.close()
            throw error
        }
        await env.close()
    }

    /// Scripted source with a folder-like cursor (the refs listed so far) whose retry list keeps
    /// at most `retryCap` deferred refs: the others are reported dropped (and stay "listed", so
    /// only a re-list from scratch brings them back). Its status is worded in the language asked.
    actor CapSource: MailSource {
        nonisolated let accountID: String
        private let retryCap: Int
        private var messages: [(ref: String, data: Data)] = []
        private var failures: [String: Int] = [:]
        private(set) var statusCalls = 0
        private(set) var cursorsSeen: [String?] = []
        private var fetchGate: CheckedContinuation<Void, Never>?
        private var holdNextFetch = false
        private(set) var fetchHeld = false

        init(accountID: String, retryCap: Int = 1) { self.accountID = accountID; self.retryCap = retryCap }

        func add(_ ref: String, _ data: Data) { messages.append((ref, data)) }
        func failFetch(_ ref: String, times: Int) { failures[ref] = times }
        /// The next fetch waits until `releaseFetch()`.
        func holdFetch() { holdNextFetch = true }
        func releaseFetch() {
            holdNextFetch = false
            fetchGate?.resume()
            fetchGate = nil
        }

        func status() async -> MailSourceStatus { await localizedStatus().render(.en) }

        func localizedStatus() async -> MailLocalizedStatus {
            statusCalls += 1
            let n = messages.count
            return MailLocalizedStatus { l in .ready(detail: l == .zh ? "已连接（\(n) 封）" : "Connected (\(n) messages)") }
        }

        private static func seen(_ c: MailCursor?) -> [String] {
            guard let c, !c.value.isEmpty else { return [] }
            return c.value.components(separatedBy: "\n")
        }

        func listHeaders(since: MailCursor?, limit: Int) async throws -> MailHeaderPage {
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
            return MailHeaderPage(headers: headers, nextCursor: MailCursor(seen.joined(separator: "\n")),
                                  hasMore: fresh.count > page.count)
        }

        func fetchMessage(_ header: MailHeader, maxBytes: Int) async throws -> MailContent {
            if holdNextFetch {
                holdNextFetch = false
                fetchHeld = true
                await withCheckedContinuation { fetchGate = $0 }
            }
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
            let kept = Array(refs.prefix(retryCap)), dropped = Array(refs.dropFirst(retryCap))
            let seen = Self.seen(cursor).filter { !kept.contains($0) }
            return MailDeferral(cursor: MailCursor(seen.joined(separator: "\n")), dropped: dropped)
        }
    }
}
