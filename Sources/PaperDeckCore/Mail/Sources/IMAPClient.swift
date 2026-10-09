import Foundation
import Network
import os
import PaperDeckShared

// Minimal read-only IMAP4rev1 client (RFC 3501) over Network.framework.
//
// Read-only by construction: the only mailbox command is EXAMINE (never SELECT) and
// the only body fetches are BODY.PEEK[…] (never BODY[…], which would set \Seen).
// Implicit TLS on 993 (no STARTTLS); `.plainForTesting` is plain TCP for the local
// fake server in tests. Never logs passwords, header or body bytes: traces redact
// LOGIN and summarize literals by size.

/// How to reach the server.
package enum IMAPConnector: Sendable, Equatable {
    case tls                                          // account host/port, implicit TLS
    case plainForTesting(host: String, port: UInt16)  // plain TCP to a local fake server (tests only)
}

package enum IMAPError: Error, Sendable, Equatable, CustomStringConvertible {
    case notConfigured(String)                 // missing host / user / password (message is user-facing)
    case connectFailed(String)                 // DNS, refused, TLS, no network (system text, no secrets)
    case timeout(String)                       // "connect" or the command verb
    case connectionClosed
    case authenticationFailed(String)          // LOGIN NO — sanitized server text
    case loginDisabled                         // server advertises LOGINDISABLED
    case mailboxUnavailable(String)            // EXAMINE NO — sanitized server text
    case commandFailed(command: String, text: String)   // other NO/BAD
    case protocolError(String)
    case uidValidityChanged                    // header ref is from an older UIDVALIDITY
    case messageNotFound
    case invalidReference

    package var description: String {
        switch self {
        case .notConfigured(let m): "IMAP not configured: \(m)"
        case .connectFailed(let m): "IMAP connect failed: \(m)"
        case .timeout(let what): "IMAP timeout (\(what))"
        case .connectionClosed: "IMAP connection closed"
        case .authenticationFailed(let t): "IMAP LOGIN rejected: \(t)"
        case .loginDisabled: "IMAP LOGIN disabled by server"
        case .mailboxUnavailable(let t): "IMAP EXAMINE failed: \(t)"
        case .commandFailed(let c, let t): "IMAP \(c) failed: \(t)"
        case .protocolError(let m): "IMAP protocol error: \(m)"
        case .uidValidityChanged: "IMAP UIDVALIDITY changed"
        case .messageNotFound: "IMAP message not found"
        case .invalidReference: "invalid IMAP message reference"
        }
    }

    /// Transport-level failure: the session is unusable and a fresh connection may work.
    package var isConnectionLevel: Bool {
        switch self {
        case .connectFailed, .timeout, .connectionClosed, .protocolError: true
        default: false
        }
    }

    /// User-facing text (zh / en) for Settings ▸ Mail and sync toasts.
    package func message(host: String, lang: UILang) -> String {
        let zh = lang == .zh
        switch self {
        case .notConfigured(let m): return m
        case .connectFailed(let d):
            return zh ? "无法连接 \(host)——\(d)" : "Can't reach \(host) — \(d)"
        case .timeout:
            return zh ? "\(host) 响应超时。" : "\(host) didn't respond in time."
        case .connectionClosed:
            return zh ? "\(host) 断开了连接。" : "\(host) closed the connection."
        case .authenticationFailed(let t):
            let server = t.isEmpty ? "" : (zh ? "（服务器：\(t)）" : " (Server: \(t))")
            if Self.isMicrosoftHost(host) {
                // Outlook.com / Microsoft 365 mailboxes refuse app-password (basic) sign-in.
                return zh
                    ? "\(host) 拒绝登录：Microsoft 不接受这个邮箱的应用专用密码。请查看「帮助 ▸ Outlook.com」了解其他收取方式。\(server)"
                    : "\(host) rejected the sign-in. Microsoft doesn't accept app passwords for this mailbox — see Help ▸ Outlook.com for other ways to get this mail in.\(server)"
            }
            return zh
                ? "\(host) 拒绝登录：应用专用密码可能已被撤销，或两步验证已关闭。请重新生成应用专用密码并保存。\(server)"
                : "\(host) rejected the sign-in. The app password may have been revoked, or 2-Step Verification was turned off — create a new app password and save it again.\(server)"
        case .loginDisabled:
            return zh ? "\(host) 不允许密码登录（LOGINDISABLED）。" : "\(host) doesn't allow password sign-in (LOGINDISABLED)."
        case .mailboxUnavailable(let t):
            let server = t.isEmpty ? "" : (zh ? "（服务器：\(t)）" : " (Server: \(t))")
            return zh ? "\(host) 上无法打开该邮箱文件夹。Gmail 可填标签名（例如「PaperDeck」）。\(server)"
                      : "\(host) can't open that mailbox. For Gmail, a label name works (e.g. “PaperDeck”).\(server)"
        case .commandFailed(let c, let t):
            return zh ? "\(host) 拒绝了 \(c) 命令：\(t)" : "\(host) rejected \(c): \(t)"
        case .protocolError:
            return zh ? "\(host) 返回了无法识别的响应。" : "Unexpected response from \(host)."
        case .uidValidityChanged:
            return zh ? "邮箱已在服务器上重建，将重新同步。" : "The mailbox was rebuilt on the server; it will be re-synced."
        case .messageNotFound:
            return zh ? "这封邮件已不在服务器上。" : "This message is no longer on the server."
        case .invalidReference:
            return zh ? "邮件引用无效。" : "Invalid message reference."
        }
    }

    /// Microsoft's IMAP endpoints (Outlook.com / Hotmail and Microsoft 365), which sign in with
    /// OAuth only — an app password is rejected whatever the user types.
    package static let microsoftHosts: Set<String> = ["outlook.office365.com", "imap-mail.outlook.com"]

    package static func isMicrosoftHost(_ host: String) -> Bool {
        microsoftHosts.contains(host.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Server text safe to show: control characters removed, capped.
    static func sanitize(_ text: String) -> String {
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }))
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 160 ? String(trimmed.prefix(160)) + "…" : trimmed
    }
}

package enum MailTransportLog {
    package static let logger = Logger(subsystem: Log.subsystem, category: "mail")

    /// Log-safe reason for a mail transport / file error: a category, never system or server
    /// text (an NSError's localized description quotes the file name — often the subject of a
    /// mail that was never allowlisted; IMAP errors can carry server text).
    package static func reason(_ error: any Error) -> String {
        if let e = error as? IMAPError {
            switch e {
            case .notConfigured: return "imap not configured"
            case .connectFailed: return "imap connect failed"
            case .timeout: return "imap timeout"
            case .connectionClosed: return "imap connection closed"
            case .authenticationFailed: return "imap login rejected"
            case .loginDisabled: return "imap login disabled"
            case .mailboxUnavailable: return "imap mailbox unavailable"
            case .commandFailed: return "imap command failed"
            case .protocolError: return "imap protocol error"
            case .uidValidityChanged: return "imap uidvalidity changed"
            case .messageNotFound: return "imap message not found"
            case .invalidReference: return "imap invalid reference"
            }
        }
        if let e = error as? FolderMailSourceError { return e.description }      // no paths in it
        if error is MIMEParser.ParseError { return "not an email" }
        if error is CancellationError { return "cancelled" }
        let e = FileOps.classify(error)
        switch e {
        case .io: return "I/O error"
        case .hashMismatch: return "hash mismatch"
        default: return e.description
        }
    }
}

// MARK: - Transport

/// Byte transport under the client (Network.framework in production).
package protocol IMAPTransport: Sendable {
    func send(_ data: Data, timeout: Duration) async throws
    /// Some bytes (≥ 1); throws `IMAPError.connectionClosed` at EOF, `.timeout` when idle.
    func receive(timeout: Duration) async throws -> Data
    func close() async
}

/// NWConnection-backed transport (implicit TLS or plain TCP).
package final class NWIMAPTransport: IMAPTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    private init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection; self.queue = queue
    }

    deinit { connection.cancel() }

    package static func connect(host: String, port: UInt16, useTLS: Bool, timeout: Duration) async throws -> NWIMAPTransport {
        guard let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else {
            throw IMAPError.connectFailed("invalid port \(port)")
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(timeout.components.seconds))
        tcp.enableKeepalive = true
        let params: NWParameters
        if useTLS {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        let transport = NWIMAPTransport(connection: conn, queue: DispatchQueue(label: "\(Log.subsystem).imap"))
        try await transport.start(timeout: timeout)
        return transport
    }

    private func start(timeout: Duration) async throws {
        let once = OnceResume<Void>()
        let connection = self.connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                guard once.install(cont) else { return }
                connection.stateUpdateHandler = { [weak connection] state in
                    switch state {
                    case .ready:
                        once.resume(.success(()))
                    case .failed(let e):
                        if once.resume(.failure(IMAPError.connectFailed(Self.describe(e)))) { connection?.cancel() }
                    case .waiting(let e):
                        // Refused / no route / DNS: fail fast instead of waiting for a better path.
                        if once.resume(.failure(IMAPError.connectFailed(Self.describe(e)))) { connection?.cancel() }
                    case .cancelled:
                        once.resume(.failure(IMAPError.connectionClosed))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + Self.interval(timeout)) { [weak connection] in
                    if once.resume(.failure(IMAPError.timeout("connect"))) { connection?.cancel() }
                }
            }
        } onCancel: {
            if once.resume(.failure(CancellationError())) { connection.cancel() }
        }
    }

    package func send(_ data: Data, timeout: Duration) async throws {
        let once = OnceResume<Void>()
        let connection = self.connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                guard once.install(cont) else { return }
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        once.resume(.failure(Self.isClosure(error) ? IMAPError.connectionClosed
                                                                   : IMAPError.connectFailed(Self.describe(error))))
                    } else {
                        once.resume(.success(()))
                    }
                })
                queue.asyncAfter(deadline: .now() + Self.interval(timeout)) { [weak connection] in
                    if once.resume(.failure(IMAPError.timeout("send"))) { connection?.cancel() }
                }
            }
        } onCancel: {
            if once.resume(.failure(CancellationError())) { connection.cancel() }
        }
    }

    package func receive(timeout: Duration) async throws -> Data {
        let once = OnceResume<Data>()
        let connection = self.connection
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, any Error>) in
                guard once.install(cont) else { return }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        once.resume(.success(data))
                    } else if let error {
                        once.resume(.failure(Self.isClosure(error) ? IMAPError.connectionClosed
                                                                   : IMAPError.connectFailed(Self.describe(error))))
                    } else {
                        _ = isComplete
                        once.resume(.failure(IMAPError.connectionClosed))
                    }
                }
                queue.asyncAfter(deadline: .now() + Self.interval(timeout)) { [weak connection] in
                    if once.resume(.failure(IMAPError.timeout("read"))) { connection?.cancel() }
                }
            }
        } onCancel: {
            if once.resume(.failure(CancellationError())) { connection.cancel() }
        }
    }

    package func close() async {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private static func isClosure(_ error: NWError) -> Bool {
        if case .posix(let code) = error {
            return code == .ECANCELED || code == .ECONNRESET || code == .ENOTCONN || code == .EPIPE
        }
        return false
    }

    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return "connection refused"
            case .ETIMEDOUT: return "timed out"
            case .ENETUNREACH, .EHOSTUNREACH: return "network unreachable"
            case .ENETDOWN: return "network down"
            default: return "\(code)"
            }
        case .dns(let code):
            return "DNS lookup failed (\(code))"
        case .tls(let status):
            return "TLS/certificate error (\(status))"
        default:
            return "\(error)"
        }
    }

    private static func interval(_ d: Duration) -> DispatchTimeInterval {
        let (s, atto) = d.components
        let ns = max(0, s) &* 1_000_000_000 &+ max(0, atto) / 1_000_000_000
        return .nanoseconds(Int(clamping: ns))
    }
}

/// Exactly-once resumption shared by a completion handler, a timer and cancellation.
private final class OnceResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var done = false
    private var early: Result<T, any Error>?

    /// False when already resolved (cancelled before install) — the continuation is resumed here.
    func install(_ cont: CheckedContinuation<T, any Error>) -> Bool {
        lock.lock()
        if done {
            let result = early ?? .failure(CancellationError())
            lock.unlock()
            cont.resume(with: result)
            return false
        }
        continuation = cont
        lock.unlock()
        return true
    }

    /// True if this call won.
    @discardableResult
    func resume(_ result: Result<T, any Error>) -> Bool {
        lock.lock()
        guard !done else { lock.unlock(); return false }
        done = true
        let cont = continuation
        continuation = nil
        if cont == nil { early = result }
        lock.unlock()
        cont?.resume(with: result)
        return true
    }
}

/// FIFO mutual exclusion across suspension points (actors are reentrant).
package final class IMAPSerialGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    package init() {}

    package func acquire() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if busy {
                waiters.append(cont)
                lock.unlock()
            } else {
                busy = true
                lock.unlock()
                cont.resume()
            }
        }
    }

    package func release() {
        lock.lock()
        if waiters.isEmpty {
            busy = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}

// MARK: - Client

package actor IMAPClient {
    package struct Timeouts: Sendable, Equatable {
        package var connect: Duration
        /// Longest wait for the next bytes from the server while a command runs.
        package var command: Duration
        package init(connect: Duration, command: Duration) { self.connect = connect; self.command = command }
        package static let standard = Timeouts(connect: .seconds(15), command: .seconds(60))
    }

    /// State of the mailbox opened with EXAMINE.
    package struct Mailbox: Sendable, Equatable {
        package var name: String
        package var uidValidity: UInt32?
        package var uidNext: UInt32?
        package var exists: Int
        package var readOnly: Bool
    }

    /// Phase-1 record from `uidFetchHeaders`.
    package struct HeaderRecord: Sendable, Equatable {
        package var uid: UInt32
        package var size: Int?
        package var internalDate: Date?
        package var data: Data
    }

    /// Redacted protocol trace ("C: A001 LOGIN <redacted>", "S: * 3 FETCH (… 412 literal bytes)").
    package typealias Trace = @Sendable (String) -> Void

    package struct Completion: Sendable {
        package var status: IMAPStatus
        package var code: IMAPResponseCode?
        package var text: String
        package var untagged: [IMAPResponse]
    }

    private enum Part {
        case text(String)
        case string(String)        // astring: quoted when possible, literal otherwise
    }

    /// Fields fetched in phase 1 (headers only — never the body).
    package static let headerFields = ["FROM", "SENDER", "SUBJECT", "DATE", "MESSAGE-ID",
                                       "AUTHENTICATION-RESULTS", "CONTENT-TYPE"]
    static let headerLiteralLimit = 1 << 20

    private let transport: any IMAPTransport
    private let timeouts: Timeouts
    private let trace: Trace?
    private var framer = IMAPFramer(maxLiteral: IMAPClient.headerLiteralLimit, maxLine: 8 << 20)
    private var tagCounter = 0
    private let gate = IMAPSerialGate()
    package private(set) var capabilities: Set<String> = []
    package private(set) var selected: Mailbox?
    package private(set) var isClosed = false

    package init(transport: any IMAPTransport, timeouts: Timeouts = .standard, trace: Trace? = nil) {
        self.transport = transport; self.timeouts = timeouts; self.trace = trace
    }

    /// Connects and reads the greeting.
    package static func connect(host: String, port: UInt16, connector: IMAPConnector,
                                timeouts: Timeouts = .standard, trace: Trace? = nil) async throws -> IMAPClient {
        let target: (host: String, port: UInt16, tls: Bool)
        switch connector {
        case .tls: target = (host, port, true)
        case .plainForTesting(let h, let p): target = (h, p, false)
        }
        MailTransportLog.logger.info("imap connect \(target.host, privacy: .private):\(target.port, privacy: .public) tls=\(target.tls, privacy: .public)")
        let transport = try await NWIMAPTransport.connect(host: target.host, port: target.port, useTLS: target.tls,
                                                          timeout: timeouts.connect)
        let client = IMAPClient(transport: transport, timeouts: timeouts, trace: trace)
        do {
            try await client.readGreeting()
        } catch {
            await client.close()
            throw error
        }
        return client
    }

    /// Reads the server greeting (`* OK`, `* PREAUTH` or `* BYE`).
    package func readGreeting() async throws {
        await gate.acquire()
        defer { gate.release() }
        let r = try await readResponse(verb: "greeting")
        switch r {
        case .status(.ok, let code, _), .status(.preauth, let code, _):
            if let code, code.name == "CAPABILITY" { setCapabilities(code.arguments) }
        case .status(.bye, _, let text):
            await shutdown()
            throw IMAPError.connectFailed("server said BYE: \(IMAPError.sanitize(text))")
        default:
            await shutdown()
            throw IMAPError.protocolError("unexpected greeting")
        }
    }

    // MARK: Commands

    package func capability() async throws -> Set<String> {
        let c = try await run("CAPABILITY", [.text("CAPABILITY")])
        try requireOK(c, "CAPABILITY")
        for case .capability(let caps) in c.untagged { setCapabilities(caps.joined(separator: " ")) }
        return capabilities
    }

    /// LOGIN with quoted-string (or literal) arguments. The trace shows `LOGIN <redacted>`.
    package func login(username: String, password: String) async throws {
        if capabilities.isEmpty { _ = try await capability() }
        if capabilities.contains("LOGINDISABLED") { throw IMAPError.loginDisabled }
        let c = try await run("LOGIN", [.text("LOGIN "), .string(username), .text(" "), .string(password)],
                              traceText: "LOGIN <redacted>")
        switch c.status {
        case .ok:
            if let code = c.code, code.name == "CAPABILITY" { setCapabilities(code.arguments) }
            for case .capability(let caps) in c.untagged { setCapabilities(caps.joined(separator: " ")) }
            MailTransportLog.logger.info("imap LOGIN ok")
        case .no:
            MailTransportLog.logger.error("imap LOGIN rejected: \(c.text, privacy: .private)")
            let codeText = c.code.map { "[\($0.name)] " } ?? ""
            throw IMAPError.authenticationFailed(IMAPError.sanitize(codeText + c.text))
        default:
            throw IMAPError.commandFailed(command: "LOGIN", text: IMAPError.sanitize(c.text))
        }
    }

    /// EXAMINE (read-only open). Never SELECT.
    package func examine(_ mailbox: String) async throws -> Mailbox {
        let encoded = IMAPResponseParser.encodeMailboxName(mailbox)
        let c = try await run("EXAMINE", [.text("EXAMINE "), .string(encoded)])
        guard c.status == .ok else {
            selected = nil
            if c.status == .no { throw IMAPError.mailboxUnavailable(IMAPError.sanitize(c.text)) }
            throw IMAPError.commandFailed(command: "EXAMINE", text: IMAPError.sanitize(c.text))
        }
        var box = Mailbox(name: mailbox, uidValidity: nil, uidNext: nil, exists: 0,
                          readOnly: c.code?.name == "READ-ONLY")
        for r in c.untagged {
            switch r {
            case .exists(let n): box.exists = n
            case .status(.ok, let code?, _):
                if code.name == "UIDVALIDITY" { box.uidValidity = code.number }
                if code.name == "UIDNEXT" { box.uidNext = code.number }
            default: break
            }
        }
        selected = box
        MailTransportLog.logger.info("imap EXAMINE ok exists=\(box.exists, privacy: .public) uidvalidity=\(box.uidValidity ?? 0, privacy: .public)")
        return box
    }

    /// `UID SEARCH [UID from:*] [SINCE d-Mon-yyyy]` (ALL when both are nil). Returns sorted UIDs.
    package func uidSearch(fromUID: UInt32?, since: Date?) async throws -> [UInt32] {
        guard selected != nil else { throw IMAPError.protocolError("no mailbox examined") }
        var criteria: [String] = []
        if let fromUID { criteria.append("UID \(fromUID):*") }
        if let since { criteria.append("SINCE \(IMAPResponseParser.searchDate(since))") }
        if criteria.isEmpty { criteria.append("ALL") }
        let c = try await run("UID SEARCH", [.text("UID SEARCH " + criteria.joined(separator: " "))])
        try requireOK(c, "UID SEARCH")
        var out = Set<UInt32>()
        for case .search(let uids) in c.untagged { out.formUnion(uids) }
        return out.sorted()
    }

    /// Phase 1: UID, size, INTERNALDATE and selected header fields (BODY.PEEK — never sets \Seen).
    package func uidFetchHeaders(_ uids: [UInt32], fields: [String] = IMAPClient.headerFields) async throws -> [HeaderRecord] {
        guard !uids.isEmpty else { return [] }
        guard selected != nil else { throw IMAPError.protocolError("no mailbox examined") }
        let wanted = Set(uids)
        let items = "(UID RFC822.SIZE INTERNALDATE BODY.PEEK[HEADER.FIELDS (\(fields.joined(separator: " ")))])"
        let c = try await run("UID FETCH", [.text("UID FETCH \(IMAPResponseParser.uidSet(uids)) \(items)")],
                              maxLiteral: Self.headerLiteralLimit, discardOversized: true)
        try requireOK(c, "UID FETCH")
        var out: [UInt32: HeaderRecord] = [:]
        for case .fetch(let f) in c.untagged {
            guard let uid = f.uid, wanted.contains(uid), let data = f.headerFields, !data.isEmpty else { continue }
            out[uid] = HeaderRecord(uid: uid, size: f.size, internalDate: f.internalDate, data: data)
        }
        return out.values.sorted { $0.uid < $1.uid }
    }

    /// Phase 2: the first `maxBytes` of the whole message via BODY.PEEK[]<0.maxBytes>.
    /// nil when the server has no such message.
    package func uidFetchMessage(_ uid: UInt32, maxBytes: Int) async throws -> Data? {
        guard selected != nil else { throw IMAPError.protocolError("no mailbox examined") }
        let cap = max(1, maxBytes)
        let c = try await run("UID FETCH", [.text("UID FETCH \(uid) (UID BODY.PEEK[]<0.\(cap)>)")],
                              maxLiteral: cap + 4096)
        try requireOK(c, "UID FETCH")
        for case .fetch(let f) in c.untagged where f.uid == uid {
            if let body = f.body { return body }
        }
        return nil
    }

    /// Selectable mailboxes (`LIST "" "*"`), names decoded from modified UTF-7 — for the
    /// Settings picker (Gmail labels are mailboxes, e.g. "PaperDeck", "[Gmail]/All Mail").
    package func listMailboxes() async throws -> [String] {
        let c = try await run("LIST", [.text(#"LIST "" "*""#)])
        try requireOK(c, "LIST")
        var names: [String] = []
        for case .other("LIST", let values) in c.untagged where values.count >= 3 {
            let flags = Set((values[0].list ?? []).compactMap { $0.string?.uppercased() })
            if flags.contains("\\NOSELECT") || flags.contains("\\NONEXISTENT") { continue }
            guard let raw = values[2].string else { continue }
            names.append(IMAPResponseParser.decodeMailboxName(raw) ?? raw)
        }
        return names
    }

    /// Best-effort LOGOUT, then close.
    package func logout() async {
        if !isClosed {
            _ = try? await run("LOGOUT", [.text("LOGOUT")], expectBye: true)
        }
        await close()
    }

    package func close() async {
        await shutdown()
    }

    // MARK: Engine

    private func shutdown() async {
        guard !isClosed else { return }
        isClosed = true
        selected = nil
        await transport.close()
    }

    private func setCapabilities(_ text: String) {
        capabilities = Set(text.split(separator: " ").map { $0.uppercased() })
    }

    private func requireOK(_ c: Completion, _ verb: String) throws {
        guard c.status == .ok else {
            throw IMAPError.commandFailed(command: verb, text: IMAPError.sanitize(c.text))
        }
    }

    private func nextTag() -> String {
        tagCounter += 1
        let n = String(tagCounter)
        return "A" + String(repeating: "0", count: max(0, 3 - n.count)) + n
    }

    /// Sends one tagged command (with synchronizing literals where needed) and collects
    /// untagged responses until its tagged completion.
    private func run(_ verb: String, _ parts: [Part], traceText: String? = nil,
                     maxLiteral: Int = IMAPClient.headerLiteralLimit, discardOversized: Bool = false,
                     expectBye: Bool = false) async throws -> Completion {
        await gate.acquire()
        defer { gate.release() }
        guard !isClosed else { throw IMAPError.connectionClosed }
        let tag = nextTag()
        framer.maxLiteral = maxLiteral
        framer.discardOversizedLiterals = discardOversized
        let discardedBefore = framer.discardedLiterals
        defer {
            let dropped = framer.discardedLiterals - discardedBefore
            if dropped > 0 {
                MailTransportLog.logger.error("imap \(verb, privacy: .public): \(dropped, privacy: .public) oversized literal(s) dropped")
            }
        }

        // Split into chunks; the server must answer "+" before each literal's bytes.
        var chunks: [Data] = []
        var current = Data((tag + " ").utf8)
        var shown = tag + " "
        for part in parts {
            switch part {
            case .text(let t):
                current.append(Data(t.utf8)); shown += t
            case .string(let s):
                if let q = IMAPResponseParser.quoted(s) {
                    current.append(Data(q.utf8)); shown += q
                } else {
                    let bytes = Data(s.utf8)
                    current.append(Data("{\(bytes.count)}\r\n".utf8))
                    shown += "{\(bytes.count)}"
                    chunks.append(current)
                    current = bytes
                }
            }
        }
        current.append(Data("\r\n".utf8))
        chunks.append(current)
        emit("C: " + (traceText.map { tag + " " + $0 } ?? shown))
        MailTransportLog.logger.debug("imap \(tag, privacy: .public) \(verb, privacy: .public)")

        var untagged: [IMAPResponse] = []
        do {
            for (i, chunk) in chunks.enumerated() {
                try await transport.send(chunk, timeout: timeouts.command)
                guard i < chunks.count - 1 else { break }
                // Wait for the continuation request before sending the literal.
                waitContinuation: while true {
                    let r = try await readResponse(verb: verb)
                    switch r {
                    case .continuation:
                        break waitContinuation
                    case .tagged(let t, let status, let code, let text) where t == tag:
                        return Completion(status: status, code: code, text: text, untagged: untagged)
                    default:
                        untagged.append(r)
                    }
                }
            }
            while true {
                let r: IMAPResponse
                do {
                    r = try await readResponse(verb: verb)
                } catch IMAPError.connectionClosed where expectBye {
                    return Completion(status: .ok, code: nil, text: "", untagged: untagged)
                }
                switch r {
                case .tagged(let t, let status, let code, let text) where t == tag:
                    return Completion(status: status, code: code, text: text, untagged: untagged)
                case .tagged:
                    continue                                    // stray tag: ignore
                case .status(.bye, _, _):
                    untagged.append(r)
                    if !expectBye {
                        await shutdown()
                        throw IMAPError.connectionClosed
                    }
                case .continuation:
                    continue
                default:
                    untagged.append(r)
                }
            }
        } catch let e as IMAPError {
            if e.isConnectionLevel { await shutdown() }
            if case .timeout = e { throw IMAPError.timeout(verb) }
            throw e
        } catch {
            await shutdown()
            throw error
        }
    }

    private func readResponse(verb: String) async throws -> IMAPResponse {
        while true {
            let raw: IMAPRawResponse?
            do {
                raw = try framer.next()
            } catch let e as IMAPParseError {
                throw IMAPError.protocolError(e.description)
            }
            if let raw {
                let parsed: IMAPResponse
                do {
                    parsed = try IMAPResponseParser.parse(raw)
                } catch {
                    // An untagged response we can't parse is skipped; a broken tagged line is fatal.
                    if raw.segments.first?.first == UInt8(ascii: "*") {
                        MailTransportLog.logger.error("imap: skipped unparseable untagged response during \(verb, privacy: .public)")
                        emit("S: * <unparseable>")
                        continue
                    }
                    throw IMAPError.protocolError("\(error)")
                }
                emit("S: " + Self.summary(parsed))
                return parsed
            }
            let chunk = try await transport.receive(timeout: timeouts.command)
            framer.append(chunk)
        }
    }

    private func emit(_ line: String) {
        trace?(line)
    }

    /// Trace line without header/body bytes.
    static func summary(_ r: IMAPResponse) -> String {
        func codeText(_ c: IMAPResponseCode?) -> String {
            guard let c else { return "" }
            // Response-code arguments are protocol data (UIDVALIDITY, CAPABILITY…).
            return "[\(c.name)\(c.arguments.isEmpty ? "" : " " + c.arguments)] "
        }
        switch r {
        case .tagged(let tag, let status, let code, let text):
            return "\(tag) \(status.rawValue) \(codeText(code))\(IMAPError.sanitize(text))"
        case .status(let status, let code, let text):
            return "* \(status.rawValue) \(codeText(code))\(IMAPError.sanitize(text))"
        case .continuation:
            return "+"
        case .capability(let caps):
            return "* CAPABILITY \(caps.joined(separator: " "))"
        case .exists(let n): return "* \(n) EXISTS"
        case .recent(let n): return "* \(n) RECENT"
        case .expunge(let n): return "* \(n) EXPUNGE"
        case .flags(let f): return "* FLAGS (\(f.joined(separator: " ")))"
        case .search(let uids): return "* SEARCH (\(uids.count) results)"
        case .fetch(let f):
            return "* \(f.sequence) FETCH (UID \(f.uid.map(String.init) ?? "?") … \(f.sectionBytes) literal bytes)"
        case .other(let name, _):
            return "* \(name) …"
        }
    }
}
