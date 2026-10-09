import Darwin
import Foundation
import Testing
@testable import PaperDeckCore

// End-to-end IMAPMailSource tests against a local fake IMAP server (plain TCP on
// 127.0.0.1, `.plainForTesting`). No real mail server is ever contacted.

// MARK: - Fake server (also used by the round-3 language tests, R3SyncLanguageTests)

final class FakeIMAPServer: @unchecked Sendable {
    struct Message {
        var uid: UInt32
        var internalDate: String            // IMAP date-time, e.g. "25-Sep-2026 10:00:00 +0000"
        var raw: Data
    }

    struct Config {
        var username = "me@gmail.com"
        var password = "abcd efgh ijkl mnop"
        var uidValidity: UInt32 = 777
        var messages: [Message] = []
        var mailboxes: Set<String> = ["INBOX"]          // names as sent on the wire (modified UTF-7)
        var silentAfterGreeting = false
        var advertiseUIDNext = true
        var loginFailureText = "[AUTHENTICATIONFAILED] Invalid credentials (Failure)"
    }

    private let lock = NSLock()
    private var config: Config
    // fd ownership: a client fd is closed only by its serve thread, under `lock`, after it
    // leaves `clientFDs`; the listen fd only by the accept loop. So shutdown() here never
    // hits a descriptor number the process has already reused for another socket.
    private var clientFDs: [Int32] = []
    private var stopped = false
    private let acceptLoopDone = DispatchSemaphore(value: 0)
    private var _commands: [String] = []
    private var _connections = 0
    private(set) var port: UInt16 = 0

    init(_ config: Config = Config()) throws {
        self.config = config
        try start()
    }

    deinit { stop() }

    var commands: [String] { lock.withLock { _commands } }
    var connections: Int { lock.withLock { _connections } }
    /// Command verbs ("LOGIN", "EXAMINE", "UID SEARCH", …) in order.
    var verbs: [String] {
        commands.compactMap { line in
            let t = Self.tokenize(line)
            guard t.count >= 2 else { return nil }
            return t[1].uppercased() == "UID" && t.count >= 3 ? "UID " + t[2].uppercased() : t[1].uppercased()
        }
    }

    func update(_ f: (inout Config) -> Void) { lock.withLock { f(&config) } }

    /// Drops every open client connection (server-side idle timeout / network change).
    func dropClients() {
        lock.withLock { for fd in clientFDs { shutdown(fd, SHUT_RDWR) } }
    }

    /// Stops accepting, drops clients and waits until the listening socket is closed.
    func stop() {
        let first = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            for fd in clientFDs { shutdown(fd, SHUT_RDWR) }
            return true
        }
        if first { _ = acceptLoopDone.wait(timeout: .now() + 2) }
    }

    // MARK: Socket plumbing

    private func start() throws {
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
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = UInt16(bigEndian: addr.sin_port)
        Thread { [self] in acceptLoop(fd) }.start()
    }

    private func acceptLoop(_ fd: Int32) {
        defer {
            close(fd)
            acceptLoopDone.signal()
        }
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 20)
            if lock.withLock({ stopped }) { return }
            guard ready > 0 else { continue }
            let c = accept(fd, nil, nil)
            guard c >= 0 else { continue }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let accepted = lock.withLock { () -> Bool in
                guard !stopped else { return false }
                _connections += 1
                clientFDs.append(c)
                return true
            }
            guard accepted else { close(c); return }
            Thread { [self] in serve(c) }.start()
        }
    }

    private final class Reader {
        let fd: Int32
        var buffer: [UInt8] = []
        init(_ fd: Int32) { self.fd = fd }
        private func fill() -> Bool {
            var tmp = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &tmp, tmp.count)
            guard n > 0 else { return false }
            buffer.append(contentsOf: tmp[0..<n])
            return true
        }
        func line() -> String? {
            while true {
                if let i = buffer.firstIndex(of: 0x0A) {
                    var l = Array(buffer[0..<i])
                    buffer.removeFirst(i + 1)
                    if l.last == 0x0D { l.removeLast() }
                    return String(decoding: l, as: UTF8.self)
                }
                guard fill() else { return nil }
            }
        }
        func bytes(_ n: Int) -> [UInt8]? {
            while buffer.count < n { guard fill() else { return nil } }
            let out = Array(buffer[0..<n])
            buffer.removeFirst(n)
            return out
        }
    }

    private func write(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var off = 0
            while off < p.count {
                let n = Darwin.write(fd, p.baseAddress! + off, p.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

    private func write(_ fd: Int32, _ s: String) { write(fd, Data(s.utf8)) }

    /// One client command: tokens (literals as tokens) and a loggable text (literals as {n}).
    private func readCommand(_ r: Reader, _ fd: Int32) -> (tokens: [String], text: String)? {
        var tokens: [String] = []
        var text = ""
        while true {
            guard var line = r.line() else { return nil }
            if let m = line.range(of: #"\{(\d+)\+?\}$"#, options: .regularExpression) {
                let marker = String(line[m])
                let n = Int(marker.filter(\.isNumber)) ?? 0
                line.removeSubrange(m)
                tokens += Self.tokenize(line)
                text += line + "{\(n)}"
                if !marker.contains("+") { write(fd, "+ Ready for literal data\r\n") }
                guard let lit = r.bytes(n) else { return nil }
                tokens.append(String(decoding: lit, as: UTF8.self))
                continue
            }
            tokens += Self.tokenize(line)
            text += line
            return (tokens, text)
        }
    }

    static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == " " { i += 1; continue }
            if chars[i] == "\"" {
                var tok = ""
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count { i += 1 }
                    tok.append(chars[i]); i += 1
                }
                i += 1
                out.append(tok)
                continue
            }
            var tok = ""
            var depth = 0
            while i < chars.count {
                let c = chars[i]
                if depth == 0, c == " " { break }
                if c == "(" || c == "[" { depth += 1 }
                if c == ")" || c == "]" { depth -= 1 }
                tok.append(c); i += 1
            }
            out.append(tok)
        }
        return out
    }

    // MARK: IMAP behaviour

    private func serve(_ fd: Int32) {
        defer {
            lock.withLock {
                clientFDs.removeAll { $0 == fd }
                close(fd)
            }
        }
        let r = Reader(fd)
        write(fd, "* OK [CAPABILITY IMAP4rev1 LITERAL+ AUTH=PLAIN ID] Fake IMAP ready.\r\n")
        var authenticated = false
        var selected: String?
        while let (tokens, text) = readCommand(r, fd) {
            lock.withLock { _commands.append(text) }
            let cfg = lock.withLock { config }
            if cfg.silentAfterGreeting { continue }
            guard tokens.count >= 2 else { write(fd, "* BAD Empty command\r\n"); continue }
            let tag = tokens[0]
            var verb = tokens[1].uppercased()
            var args = Array(tokens.dropFirst(2))
            if verb == "UID", let sub = args.first { verb = "UID " + sub.uppercased(); args.removeFirst() }
            switch verb {
            case "CAPABILITY":
                write(fd, "* CAPABILITY IMAP4rev1 LITERAL+ AUTH=PLAIN ID\r\n\(tag) OK Capability completed.\r\n")
            case "NOOP":
                write(fd, "\(tag) OK NOOP completed.\r\n")
            case "LOGIN":
                if args.count == 2, args[0] == cfg.username, args[1] == cfg.password {
                    authenticated = true
                    write(fd, "\(tag) OK [CAPABILITY IMAP4rev1 LITERAL+ UIDPLUS] Logged in\r\n")
                } else {
                    write(fd, "\(tag) NO \(cfg.loginFailureText)\r\n")
                }
            case "EXAMINE", "SELECT":
                guard authenticated, let name = args.first else { write(fd, "\(tag) BAD Not authenticated\r\n"); continue }
                guard cfg.mailboxes.contains(name) else {
                    write(fd, "\(tag) NO Mailbox doesn't exist: \(name)\r\n"); continue
                }
                selected = name
                let msgs = cfg.messages
                let uidNext = (msgs.map(\.uid).max() ?? 0) + 1
                var out = "* FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)\r\n"
                out += "* OK [PERMANENTFLAGS ()] Read-only mailbox.\r\n"
                out += "* \(msgs.count) EXISTS\r\n* 0 RECENT\r\n"
                out += "* OK [UIDVALIDITY \(cfg.uidValidity)] UIDs valid\r\n"
                if cfg.advertiseUIDNext { out += "* OK [UIDNEXT \(uidNext)] Predicted next UID\r\n" }
                out += verb == "EXAMINE" ? "\(tag) OK [READ-ONLY] Examine completed.\r\n"
                                         : "\(tag) OK [READ-WRITE] Select completed.\r\n"
                write(fd, out)
            case "UID SEARCH":
                guard selected != nil else { write(fd, "\(tag) BAD No mailbox selected\r\n"); continue }
                let hits = Self.search(cfg.messages, args)
                write(fd, "* SEARCH" + hits.map { " \($0)" }.joined() + "\r\n\(tag) OK Search completed.\r\n")
            case "UID FETCH":
                guard selected != nil, args.count >= 2 else { write(fd, "\(tag) BAD No mailbox selected\r\n"); continue }
                let uids = Set(Self.uidSet(args[0], cfg.messages))
                let items = args[1]
                let sorted = cfg.messages.sorted { $0.uid < $1.uid }
                for (i, m) in sorted.enumerated() where uids.contains(m.uid) {
                    write(fd, Self.fetchResponse(seq: i + 1, m, items: items))
                }
                write(fd, "\(tag) OK Fetch completed.\r\n")
            case "LIST":
                guard authenticated else { write(fd, "\(tag) BAD Not authenticated\r\n"); continue }
                var out = "* LIST (\\HasChildren \\Noselect) \"/\" \"[Gmail]\"\r\n"
                for name in cfg.mailboxes.sorted() { out += "* LIST (\\HasNoChildren) \"/\" \"\(name)\"\r\n" }
                write(fd, out + "\(tag) OK List completed.\r\n")
            case "LOGOUT":
                write(fd, "* BYE Logging out\r\n\(tag) OK Logout completed.\r\n")
                return
            default:
                write(fd, "\(tag) BAD Unknown command\r\n")
            }
        }
    }

    private static func uidSet(_ spec: String, _ messages: [Message]) -> [UInt32] {
        let maxUID = messages.map(\.uid).max() ?? 0
        var out: [UInt32] = []
        for part in spec.split(separator: ",") {
            let ends = part.split(separator: ":").map { $0 == "*" ? maxUID : (UInt32($0) ?? 0) }
            if ends.count == 2 {
                let lo = min(ends[0], ends[1]), hi = max(ends[0], ends[1])
                out += messages.map(\.uid).filter { $0 >= lo && $0 <= hi }
            } else if let u = ends.first {
                out += messages.map(\.uid).filter { $0 == u }
            }
        }
        return out
    }

    private static func search(_ messages: [Message], _ args: [String]) -> [UInt32] {
        var pool = messages
        var i = 0
        while i < args.count {
            switch args[i].uppercased() {
            case "UID" where i + 1 < args.count:
                let set = Set(uidSet(args[i + 1], messages))
                pool = pool.filter { set.contains($0.uid) }
                i += 2
            case "SINCE" where i + 1 < args.count:
                if let since = IMAPResponseParser.parseInternalDate(args[i + 1] + " 00:00:00 +0000") {
                    pool = pool.filter { (IMAPResponseParser.parseInternalDate($0.internalDate) ?? .distantPast) >= since }
                }
                i += 2
            default:
                i += 1
            }
        }
        return pool.map(\.uid).sorted()
    }

    private static func fetchResponse(seq: Int, _ m: Message, items: String) -> Data {
        var out = Data("* \(seq) FETCH (UID \(m.uid)".utf8)
        let upper = items.uppercased()
        if upper.contains("RFC822.SIZE") { out += Data(" RFC822.SIZE \(m.raw.count)".utf8) }
        if upper.contains("INTERNALDATE") { out += Data(" INTERNALDATE \"\(m.internalDate)\"".utf8) }
        if let r = upper.range(of: "HEADER.FIELDS (") {
            let rest = upper[r.upperBound...]
            let close = rest.firstIndex(of: ")") ?? rest.endIndex
            let fields = Set(rest[..<close].split(separator: " ").map(String.init))
            let spec = "HEADER.FIELDS (" + rest[..<close] + ")"
            let block = headerFields(m.raw, fields)
            out += Data(" BODY[\(spec)] {\(block.count)}\r\n".utf8) + block
        }
        if let r = upper.range(of: #"\[\]<0\.(\d+)>"#, options: .regularExpression) {
            let n = Int(upper[r].filter(\.isNumber).dropFirst()) ?? m.raw.count
            let part = m.raw.prefix(n)
            out += Data(" BODY[]<0> {\(part.count)}\r\n".utf8) + part
        } else if upper.contains("BODY[]") || upper.contains("BODY.PEEK[]") {
            out += Data(" BODY[] {\(m.raw.count)}\r\n".utf8) + m.raw
        }
        out += Data(")\r\n".utf8)
        return out
    }

    /// The requested header lines (with continuations) plus the terminating blank line.
    private static func headerFields(_ raw: Data, _ fields: Set<String>) -> Data {
        let text = String(decoding: raw, as: UTF8.self)
        let head = text.components(separatedBy: "\r\n\r\n").first ?? text
        var out: [String] = []
        var keep = false
        for line in head.components(separatedBy: "\r\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if keep { out.append(line) }
                continue
            }
            let name = line.split(separator: ":", maxSplits: 1).first.map { $0.uppercased() } ?? ""
            keep = fields.contains(name)
            if keep { out.append(line) }
        }
        return Data((out.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}

/// Collects the client's redacted protocol trace.
private final class TraceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.withLock { lines.append(s) } }
    var all: [String] { lock.withLock { lines } }
    var trace: IMAPClient.Trace { { [self] line in add(line) } }
}

// MARK: - Helpers

/// 2026-10-01 12:00:00 UTC — lookback 14 days starts on 17-Sep-2026.
private let imapNow = Date(timeIntervalSince1970: 1_790_856_000)
private let testPassword = "abcd efgh ijkl mnop"

private func message(_ uid: UInt32, _ date: String, from: String = "bioRxiv <alerts@biorxiv.org>",
                     subject: String? = nil, body: String = "Body text for the message.") -> FakeIMAPServer.Message {
    let raw = [
        "Return-Path: <bounce@example.org>",
        "From: \(from)",
        "To: me@gmail.com",
        "Subject: \(subject ?? "Message \(uid)")",
        "Date: Tue, 29 Sep 2026 14:04:31 +0000",
        "Message-ID: <msg-\(uid)@example.org>",
        "MIME-Version: 1.0",
        "Content-Type: text/plain; charset=utf-8",
        "",
        body,
        "",
    ].joined(separator: "\r\n")
    return FakeIMAPServer.Message(uid: uid, internalDate: date, raw: Data(raw.utf8))
}

private func standardMessages() -> [FakeIMAPServer.Message] {
    [
        message(101, "25-Sep-2026 10:00:00 +0000"),
        message(102, "10-Sep-2026 10:00:00 +0000"),     // older than the 14-day lookback
        message(103, "29-Sep-2026 08:15:00 +0000", from: "\"Prof. X\" <x@wustl.edu>", subject: "Journal club",
                body: "Please read this before the journal club on Thursday."),
        message(104, " 1-Oct-2026 09:00:00 +0000"),
    ]
}

private func imapAccount(_ mailbox: String = "INBOX", lookback: Int = 14, user: String? = "me@gmail.com",
                         host: String? = "imap.gmail.com") -> MailAccount {
    MailAccount(id: "acct-imap-\(UUID().uuidString.prefix(8).lowercased())", kind: .imap, displayName: "Gmail test",
                lookbackDays: lookback, imapPreset: .gmail, host: host, port: 993, username: user, mailbox: mailbox)
}

private let fastTimeouts = IMAPClient.Timeouts(connect: .seconds(5), command: .seconds(5))

private func makeSource(_ server: FakeIMAPServer, _ account: MailAccount, password: String? = testPassword,
                        lang: UILang = .en, timeouts: IMAPClient.Timeouts = fastTimeouts,
                        trace: TraceLog? = nil) async -> (IMAPMailSource, InMemoryMailSecretStore) {
    let store = InMemoryMailSecretStore()
    if let password { try? await store.setSecret(password, for: account.secretKey) }
    let source = IMAPMailSource(account: account, secrets: store,
                                connector: .plainForTesting(host: "127.0.0.1", port: server.port),
                                lang: lang, timeouts: timeouts, now: { imapNow }, trace: trace?.trace)
    return (source, store)
}

/// Every command the client sent keeps the mailbox read-only.
private func assertReadOnly(_ commands: [String], sourceLocation: SourceLocation = #_sourceLocation) {
    for c in commands {
        let t = FakeIMAPServer.tokenize(c)
        let verb = t.count > 1 ? t[1].uppercased() : ""
        #expect(!["SELECT", "STORE", "EXPUNGE", "COPY", "MOVE", "APPEND", "DELETE", "CREATE", "RENAME"].contains(verb),
                "mutating command \(verb)", sourceLocation: sourceLocation)
        if t.count > 2, verb == "UID" {
            #expect(!["STORE", "COPY", "MOVE", "EXPUNGE"].contains(t[2].uppercased()), sourceLocation: sourceLocation)
        }
        let upper = c.uppercased().replacingOccurrences(of: "BODY.PEEK[", with: "")
        #expect(!upper.contains("BODY["), "non-PEEK body fetch: \(c)", sourceLocation: sourceLocation)
        #expect(!upper.contains("RFC822 ") && !upper.contains("RFC822)") && !upper.contains("RFC822.TEXT"),
                sourceLocation: sourceLocation)
    }
}

private func headersCursor(_ page: MailHeaderPage) throws -> IMAPCursorState {
    try #require(IMAPCursorState(page.nextCursor))
}

// MARK: - Tests

@Suite struct MailTransportIMAPSourceTests {

    @Test func firstSyncSearchesSinceLookbackThenPagesByUID() async throws {
        let server = try FakeIMAPServer(.init(messages: standardMessages()))
        defer { server.stop() }
        let account = imapAccount()
        let (source, _) = await makeSource(server, account)

        let p1 = try await source.listHeaders(since: nil, limit: 2)
        #expect(p1.headers.map(\.ref) == ["INBOX:777:101", "INBOX:777:103"])
        #expect(p1.hasMore)
        let c1 = try headersCursor(p1)
        #expect(c1 == IMAPCursorState(mailbox: "INBOX", uidValidity: 777, lastUID: 103, since: "17-Sep-2026"))
        try #require(p1.headers.count > 1)          // no index past a failed expectation (QA-15)
        let h = p1.headers[0]
        #expect(h.fromAddress == "alerts@biorxiv.org")
        #expect(h.subject == "Message 101")
        #expect(h.internetMessageID == "<msg-101@example.org>")
        #expect(h.receivedAt == IMAPResponseParser.parseInternalDate("25-Sep-2026 10:00:00 +0000"))   // INTERNALDATE
        #expect(h.sizeBytes == standardMessages()[0].raw.count)
        #expect(p1.headers[1].fromAddress == "x@wustl.edu")

        let p2 = try await source.listHeaders(since: p1.nextCursor, limit: 2)
        #expect(p2.headers.map(\.ref) == ["INBOX:777:104"])
        #expect(!p2.hasMore)
        #expect(try headersCursor(p2) == IMAPCursorState(mailbox: "INBOX", uidValidity: 777, lastUID: 104))

        // Nothing new: UIDNEXT says so, no SEARCH is sent.
        let searchesBefore = server.verbs.filter { $0 == "UID SEARCH" }.count
        let p3 = try await source.listHeaders(since: p2.nextCursor, limit: 2)
        #expect(p3.headers.isEmpty && !p3.hasMore)
        #expect(server.verbs.filter { $0 == "UID SEARCH" }.count == searchesBefore)

        // New mail arrives → incremental UID range search.
        server.update { $0.messages.append(message(105, " 1-Oct-2026 11:00:00 +0000")) }
        let p4 = try await source.listHeaders(since: p3.nextCursor, limit: 10)
        #expect(p4.headers.map(\.ref) == ["INBOX:777:105"])
        #expect(try headersCursor(p4).lastUID == 105)
        await source.close()

        let searches = server.commands.filter { $0.uppercased().contains("UID SEARCH") }
        #expect(searches.count == 3)
        #expect(searches[0].hasSuffix("UID SEARCH SINCE 17-Sep-2026"))
        #expect(searches[1].hasSuffix("UID SEARCH UID 104:* SINCE 17-Sep-2026"))
        #expect(searches[2].hasSuffix("UID SEARCH UID 105:*"))
        #expect(server.verbs.contains("EXAMINE"))
        #expect(!server.verbs.contains("SELECT"))
        let fetches = server.commands.filter { $0.uppercased().contains("UID FETCH") }
        #expect(fetches.allSatisfy { $0.contains("BODY.PEEK[HEADER.FIELDS (FROM SENDER SUBJECT DATE MESSAGE-ID AUTHENTICATION-RESULTS CONTENT-TYPE)]") })
        assertReadOnly(server.commands)
        #expect(server.connections == 1)                     // one session reused across calls
        #expect(server.verbs.last == "LOGOUT")
    }

    @Test func fetchMessageUsesPartialBodyPeek() async throws {
        let server = try FakeIMAPServer(.init(messages: standardMessages()))
        defer { server.stop() }
        let (source, _) = await makeSource(server, imapAccount())
        let page = try await source.listHeaders(since: nil, limit: 10)
        let advisor = try #require(page.headers.first { $0.fromAddress == "x@wustl.edu" })

        let content = try await source.fetchMessage(advisor, maxBytes: 200_000)
        #expect(content.header.ref == advisor.ref)
        #expect(content.header.receivedAt == advisor.receivedAt)
        #expect(content.header.fromAddress == "x@wustl.edu")
        #expect(content.plainText?.contains("journal club on Thursday") == true)
        await source.close()

        let bodyFetch = try #require(server.commands.first { $0.contains("<0.") })
        #expect(bodyFetch.hasSuffix("UID FETCH 103 (UID BODY.PEEK[]<0.200000>)"))
        assertReadOnly(server.commands)
    }

    @Test func uidValidityChangeResyncsByDate() async throws {
        let server = try FakeIMAPServer(.init(messages: standardMessages()))
        defer { server.stop() }
        let (source, _) = await makeSource(server, imapAccount())
        let first = try await source.listHeaders(since: nil, limit: 10)
        #expect(first.headers.count == 3)
        let stale = first.headers[0]

        // The server rebuilt the mailbox: new UIDVALIDITY, renumbered UIDs.
        server.update { cfg in
            cfg.uidValidity = 9001
            cfg.messages = standardMessages().enumerated().map { i, m in
                var m = m; m.uid = UInt32(i + 1); return m
            }
        }
        let again = try await source.listHeaders(since: first.nextCursor, limit: 10)
        #expect(again.headers.map(\.ref) == ["INBOX:9001:1", "INBOX:9001:3", "INBOX:9001:4"])
        #expect(try headersCursor(again) == IMAPCursorState(mailbox: "INBOX", uidValidity: 9001, lastUID: 4))
        #expect(server.commands.filter { $0.uppercased().contains("UID SEARCH") }.last?.hasSuffix("UID SEARCH SINCE 17-Sep-2026") == true)

        await #expect(throws: IMAPError.uidValidityChanged) {
            _ = try await source.fetchMessage(stale, maxBytes: 100_000)
        }
        // A changed mailbox setting also resyncs by date.
        let (other, _) = await makeSource(server, imapAccount("INBOX"))
        let fromForeignCursor = try await other.listHeaders(
            since: IMAPCursorState(mailbox: "Old", uidValidity: 9001, lastUID: 4).cursor, limit: 10)
        #expect(fromForeignCursor.headers.count == 3)
        await source.close()
        await other.close()
    }

    @Test func authFailureMapsToAuthFailedAndNeverLeaksThePassword() async throws {
        let server = try FakeIMAPServer(.init(password: "the-real-app-password"))
        defer { server.stop() }
        let log = TraceLog()
        let account = imapAccount()
        let wrong = "wrong pass\"word\\1"
        let (source, _) = await makeSource(server, account, password: wrong, trace: log)

        let status = await source.status()
        guard case .authFailed(let msg) = status else { Issue.record("expected authFailed, got \(status)"); return }
        #expect(msg.contains("app password") && msg.contains("2-Step Verification"))
        #expect(msg.contains("AUTHENTICATIONFAILED"))
        await #expect(throws: IMAPError.self) { _ = try await source.listHeaders(since: nil, limit: 5) }

        let tested = await IMAPMailSource.test(account: account, password: wrong,
                                               connector: .plainForTesting(host: "127.0.0.1", port: server.port),
                                               lang: .zh, timeouts: fastTimeouts, trace: log.trace)
        guard case .authFailed(let zh) = tested else { Issue.record("expected authFailed, got \(tested)"); return }
        #expect(zh.contains("应用专用密码"))

        // The server did receive the (escaped) password…
        #expect(server.commands.contains { $0.contains(#""wrong pass\"word\\1""#) })
        // …but the client's trace and messages never contain it.
        let trace = log.all
        #expect(!trace.isEmpty)
        #expect(trace.allSatisfy { !$0.contains("wrong pass") && !$0.contains("word\\1") })
        #expect(trace.contains { $0.hasSuffix("LOGIN <redacted>") })
        #expect(!msg.contains("wrong pass") && !zh.contains("wrong pass"))
        await source.close()
    }

    @Test func nonASCIIPasswordIsSentAsLiteral() async throws {
        let pw = "pässwörd ✓"
        let server = try FakeIMAPServer(.init(password: pw, messages: standardMessages()))
        defer { server.stop() }
        let log = TraceLog()
        let (source, _) = await makeSource(server, imapAccount(), password: pw, trace: log)
        let status = await source.status()
        #expect(status == .ready(detail: "Signed in as me@gmail.com · INBOX (4 messages)"))
        let login = try #require(server.commands.first { $0.uppercased().contains("LOGIN") })
        #expect(login.hasSuffix(#"LOGIN "me@gmail.com" {\#(pw.utf8.count)}"#))
        #expect(log.all.allSatisfy { !$0.contains("pässwörd") })
        await source.close()
    }

    @Test func missingPasswordOrSettingsNeedSetupWithoutConnecting() async throws {
        let server = try FakeIMAPServer()
        defer { server.stop() }
        let (noPassword, store) = await makeSource(server, imapAccount(), password: nil)
        guard case .needsSetup(let msg) = await noPassword.status() else { Issue.record("needsSetup"); return }
        #expect(msg.contains("me@gmail.com"))
        await #expect(throws: IMAPError.self) { _ = try await noPassword.listHeaders(since: nil, limit: 5) }
        #expect(await store.reads >= 2)

        let (noHost, _) = await makeSource(server, MailAccount(kind: .imap, displayName: "custom", imapPreset: .custom,
                                                               host: " ", username: "me@example.org"))
        guard case .needsSetup(let hostMsg) = await noHost.status() else { Issue.record("needsSetup host"); return }
        #expect(hostMsg.contains("IMAP server"))
        let (noUser, _) = await makeSource(server, imapAccount(user: nil), lang: .zh)
        #expect(await noUser.status() == .needsSetup("请填写邮箱地址（用户名）。"))
        #expect(await IMAPMailSource.test(account: imapAccount(), password: "") ==
                .needsSetup("No app password saved for me@gmail.com. Create one with your provider, then choose Test & Save."))
        #expect(server.connections == 0)
    }

    @Test func testAndSaveRunsLoginExamineLogout() async throws {
        let server = try FakeIMAPServer(.init(messages: standardMessages()))
        defer { server.stop() }
        let result = await IMAPMailSource.test(account: imapAccount(), password: testPassword,
                                               connector: .plainForTesting(host: "127.0.0.1", port: server.port),
                                               timeouts: fastTimeouts)
        #expect(result == .ready(detail: "Signed in as me@gmail.com · INBOX (4 messages)"))
        #expect(server.verbs == ["LOGIN", "EXAMINE", "LOGOUT"])
        #expect(server.commands[1].hasSuffix(#"EXAMINE "INBOX""#))

        let missing = await IMAPMailSource.test(account: imapAccount("PaperDeck"), password: testPassword,
                                                connector: .plainForTesting(host: "127.0.0.1", port: server.port),
                                                timeouts: fastTimeouts)
        guard case .needsSetup(let msg) = missing else { Issue.record("expected needsSetup, got \(missing)"); return }
        #expect(msg.contains("label"))
    }

    @Test func gmailLabelWithNonASCIINameIsExaminedInModifiedUTF7() async throws {
        let label = "论文/PaperDeck"
        let server = try FakeIMAPServer(.init(messages: standardMessages(),
                                              mailboxes: [IMAPResponseParser.encodeMailboxName(label)]))
        defer { server.stop() }
        let (source, _) = await makeSource(server, imapAccount(label))
        let page = try await source.listHeaders(since: nil, limit: 10)
        #expect(page.headers.first?.ref == "\(label):777:101")
        #expect(server.commands.contains { $0.hasSuffix(#"EXAMINE "&i7plhw-/PaperDeck""#) })
        try #require(page.headers.count > 0)          // no index past a failed expectation (QA-15)
        let content = try await source.fetchMessage(page.headers[0], maxBytes: 50_000)
        #expect(content.header.ref == "\(label):777:101")
        await source.close()
    }

    @Test func listMailboxesDecodesNamesAndSkipsNoselect() async throws {
        let server = try FakeIMAPServer(.init(mailboxes: ["INBOX", "PaperDeck", IMAPResponseParser.encodeMailboxName("论文")]))
        defer { server.stop() }
        let names = try await IMAPMailSource.listMailboxes(account: imapAccount(), password: testPassword,
                                                           connector: .plainForTesting(host: "127.0.0.1", port: server.port),
                                                           timeouts: fastTimeouts)
        #expect(Set(names) == ["INBOX", "PaperDeck", "论文"])
        #expect(server.verbs == ["LOGIN", "LIST", "LOGOUT"])
    }

    @Test func droppedSessionReconnectsOnce() async throws {
        let server = try FakeIMAPServer(.init(messages: standardMessages()))
        defer { server.stop() }
        let (source, _) = await makeSource(server, imapAccount())
        let p1 = try await source.listHeaders(since: nil, limit: 10)
        server.dropClients()
        try await Task.sleep(for: .milliseconds(100))
        let content = try await source.fetchMessage(p1.headers[0], maxBytes: 50_000)
        #expect(content.header.fromAddress == "alerts@biorxiv.org")
        #expect(server.connections == 2)
        await source.close()
    }

    @Test func silentServerTimesOut() async throws {
        let server = try FakeIMAPServer(.init(silentAfterGreeting: true))
        defer { server.stop() }
        let quick = IMAPClient.Timeouts(connect: .seconds(5), command: .milliseconds(300))
        let (source, _) = await makeSource(server, imapAccount(), timeouts: quick)
        let start = ContinuousClock.now
        let status = await source.status()
        #expect(status == .unavailable("imap.gmail.com didn't respond in time."))
        #expect(ContinuousClock.now - start < .seconds(20))        // load-tolerant (ENV-1): a silent server never answers
    }

    @Test func refusedConnectionIsUnavailable() async throws {
        // Grab a free port, then close it so nothing listens there.
        let server = try FakeIMAPServer()
        let port = server.port
        server.stop()                                   // returns once the listening socket is closed
        let result = await IMAPMailSource.test(account: imapAccount(), password: testPassword,
                                               connector: .plainForTesting(host: "127.0.0.1", port: port),
                                               timeouts: IMAPClient.Timeouts(connect: .seconds(3), command: .seconds(3)))
        // The kind is the contract; the wording depends on how the OS reports the refusal
        // (connect failed vs. timed out while waiting).
        guard case .unavailable(let msg) = result else { Issue.record("expected unavailable, got \(result)"); return }
        #expect(!msg.isEmpty)
    }

    @Test func zeroLookbackStartsFromNewMailOnly() async throws {
        let server = try FakeIMAPServer(.init(messages: standardMessages()))
        defer { server.stop() }
        let (source, _) = await makeSource(server, imapAccount(lookback: 0))
        let p1 = try await source.listHeaders(since: nil, limit: 10)
        #expect(p1.headers.isEmpty)
        #expect(try headersCursor(p1) == IMAPCursorState(mailbox: "INBOX", uidValidity: 777, lastUID: 104))
        server.update { $0.messages.append(message(110, " 1-Oct-2026 11:30:00 +0000")) }
        let p2 = try await source.listHeaders(since: p1.nextCursor, limit: 10)
        #expect(p2.headers.map(\.ref) == ["INBOX:777:110"])
        await source.close()
    }

    @Test func missingUIDNextKeepsTheDateBoundUntilAUIDIsKnown() async throws {
        let server = try FakeIMAPServer(.init(messages: [message(102, "10-Sep-2026 10:00:00 +0000")],
                                              advertiseUIDNext: false))
        defer { server.stop() }
        let (source, _) = await makeSource(server, imapAccount())
        let p1 = try await source.listHeaders(since: nil, limit: 10)
        #expect(p1.headers.isEmpty)
        // No UID seen and no UIDNEXT: never fall back to "UID 1:*" (the whole mailbox).
        #expect(try headersCursor(p1) == IMAPCursorState(mailbox: "INBOX", uidValidity: 777, lastUID: 0, since: "17-Sep-2026"))
        server.update { $0.messages.append(message(120, " 1-Oct-2026 11:30:00 +0000")) }
        let p2 = try await source.listHeaders(since: p1.nextCursor, limit: 10)
        #expect(p2.headers.map(\.ref) == ["INBOX:777:120"])
        #expect(try headersCursor(p2) == IMAPCursorState(mailbox: "INBOX", uidValidity: 777, lastUID: 120))
        await source.close()
    }

    @Test func invalidReferencesAreRejectedLocally() async throws {
        let server = try FakeIMAPServer()
        defer { server.stop() }
        let (source, _) = await makeSource(server, imapAccount())
        let bogus = MailHeader(ref: "not-a-ref", internetMessageID: nil, fromAddress: "a@b.c", fromName: nil,
                               subject: "", receivedAt: imapNow)
        await #expect(throws: IMAPError.invalidReference) { _ = try await source.fetchMessage(bogus, maxBytes: 10) }
        #expect(server.connections == 0)
    }
}

// MARK: - Review fixes (sync): deferred messages stay listable, quitting is bounded

extension MailTransportIMAPSourceTests {
    @Test func deferredUIDsAreListedAgainFromTheCursor() async throws {
        let server = try FakeIMAPServer(.init(messages: standardMessages()))
        defer { server.stop() }
        let (source, _) = await makeSource(server, imapAccount())
        let p1 = try await source.listHeaders(since: nil, limit: 10)
        #expect(p1.headers.map(\.ref) == ["INBOX:777:101", "INBOX:777:103", "INBOX:777:104"])
        let next = try #require(p1.nextCursor)
        // Only refs of this mailbox / UIDVALIDITY that were already listed are kept.
        let kept = try #require(await source.deferring(["INBOX:777:103", "INBOX:999:5", "Other:777:101", "INBOX:777:900"],
                                                       in: next))
        #expect(IMAPCursorState(kept)?.retry == [103])
        let p2 = try await source.listHeaders(since: kept, limit: 10)
        #expect(p2.headers.map(\.ref) == ["INBOX:777:103"])          // headers only, listed once
        #expect(try headersCursor(p2).retry == nil)
        #expect(try headersCursor(p2).lastUID == 104)
        // A deferred message deleted on the server simply doesn't come back.
        server.update { $0.messages.removeAll { $0.uid == 103 } }
        #expect(try await source.listHeaders(since: kept, limit: 10).headers.isEmpty)
        // An older cursor without a retry list still decodes (and encodes without one).
        #expect(IMAPCursorState(MailCursor(#"{"lastUID":104,"mailbox":"INBOX","uidvalidity":777,"v":1}"#))?.retry == nil)
        #expect(!(try #require(p2.nextCursor)).value.contains("retry"))
        await source.close()
        assertReadOnly(server.commands)
    }

    @Test func shutdownDoesNotWaitForAnUnresponsiveServer() async throws {
        let server = try FakeIMAPServer(.init(messages: standardMessages()))
        defer { server.stop() }
        let slow = IMAPClient.Timeouts(connect: .seconds(5), command: .seconds(20))
        let (source, _) = await makeSource(server, imapAccount(), timeouts: slow)
        _ = try await source.listHeaders(since: nil, limit: 10)          // a cached session
        server.update { $0.silentAfterGreeting = true }                  // LOGOUT is never answered
        let clock = ContinuousClock()
        let t0 = clock.now
        await source.shutdown(logoutWithin: .milliseconds(500))
        #expect(clock.now - t0 < .seconds(15))                  // load-tolerant (ENV-1); the command timeout is 20 s
        // Quitting: no session is opened again.
        let connections = server.connections
        await #expect(throws: IMAPError.self) { _ = try await source.listHeaders(since: nil, limit: 10) }
        guard case .unavailable = await source.status() else { Issue.record("status after shutdown"); return }
        #expect(server.connections == connections)
    }

    @Test func mailShutdownIsBoundedWhileASyncWaitsOnASilentServer() async throws {
        let server = try FakeIMAPServer(.init(messages: standardMessages(), silentAfterGreeting: true))
        defer { server.stop() }
        let account = imapAccount()
        let store = InMemoryMailSecretStore()
        try await store.setSecret(testPassword, for: account.secretKey)
        let port = server.port
        let mail = MailSettings(enabled: true, accounts: [account], senders: [], syncMinutes: 0)
        let env = try await RFB.make(mail: mail, sources: { a in
            IMAPMailSource(account: a, secrets: store, connector: .plainForTesting(host: "127.0.0.1", port: port),
                           timeouts: IMAPClient.Timeouts(connect: .seconds(5), command: .seconds(30)), now: { imapNow })
        })
        let syncing = Task { await env.engine.mail.syncNow() }
        #expect(await RFB.eventually { server.verbs.contains("LOGIN") })  // signing in; the server never answers
        let clock = ContinuousClock()
        let t0 = clock.now
        await env.engine.mail.shutdown()
        #expect(clock.now - t0 < .seconds(20))                  // load-tolerant (ENV-1); the command timeout is 30 s
        await syncing.value
        await env.close()
    }
}
