import Foundation
import PaperDeckShared

// IMAP account (Gmail / iCloud / Yahoo / Fastmail / custom) with an app password.
//
// Cursor JSON {"v":1,"mailbox":…,"uidvalidity":…,"lastUID":…,"since":"16-Sep-2026"?,"retry":[uid,…]?}:
//  - first sync (or UIDVALIDITY / mailbox change): `UID SEARCH SINCE <now − lookbackDays>`,
//    paged by `limit`; `since` stays in the cursor until that backfill is complete;
//  - afterwards: `UID SEARCH UID <lastUID+1>:*` (filtered locally to > lastUID);
//  - nextCursor.lastUID = the largest UID of the page (or UIDNEXT−1 once nothing is left);
//  - `retry`: allowlisted messages the engine could not fetch yet (`deferring`): listed again
//    (headers only) at the start of the next listing, then dropped from the cursor — the engine
//    defers them again while they keep failing. Vanished UIDs simply don't come back.
// Sender filtering is local (the engine's SenderMatcher), never a server-side FROM search.
// Read-only: EXAMINE + BODY.PEEK only. A session is reused across calls of one sync and
// closed after `idleClose` without use.

/// Resume point of an IMAP account (MailCursor.value is this struct as JSON).
package struct IMAPCursorState: Codable, Sendable, Equatable {
    package var v: Int = 1
    package var mailbox: String
    package var uidValidity: UInt32
    package var lastUID: UInt32
    package var since: String?          // IMAP date while the lookback backfill is still paging
    /// UIDs to list again: allowlisted messages whose fetch keeps failing. At most `lastUID`,
    /// except while a re-listed look-back (`relisting`) pages: a deferred UID its date search does
    /// not return (older than the look-back) is listed from this list.
    package var retry: [UInt32]?

    package static let maxRetry = 200

    package init(mailbox: String, uidValidity: UInt32, lastUID: UInt32, since: String? = nil, retry: [UInt32]? = nil) {
        self.mailbox = mailbox; self.uidValidity = uidValidity; self.lastUID = lastUID; self.since = since
        self.retry = retry
    }

    enum CodingKeys: String, CodingKey {
        case v, mailbox, uidValidity = "uidvalidity", lastUID, since, retry
    }

    package init?(_ cursor: MailCursor?) {
        guard let cursor, let data = cursor.value.data(using: .utf8),
              let s = try? JSONDecoder().decode(IMAPCursorState.self, from: data) else { return nil }
        self = s
    }

    package var cursor: MailCursor {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return MailCursor(String(decoding: (try? enc.encode(self)) ?? Data(), as: UTF8.self))
    }
}

/// `MailHeader.ref` / `MailMessage.sourceRef` of an IMAP message: "<mailbox>:<uidvalidity>:<uid>".
package struct IMAPMessageRef: Sendable, Equatable {
    package var mailbox: String
    package var uidValidity: UInt32
    package var uid: UInt32

    package init(mailbox: String, uidValidity: UInt32, uid: UInt32) {
        self.mailbox = mailbox; self.uidValidity = uidValidity; self.uid = uid
    }

    /// Parses from the right, so mailbox names containing ":" survive.
    package init?(_ ref: String) {
        let parts = ref.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, let uid = UInt32(parts[parts.count - 1]),
              let validity = UInt32(parts[parts.count - 2]) else { return nil }
        let mailbox = parts[..<(parts.count - 2)].joined(separator: ":")
        guard !mailbox.isEmpty else { return nil }
        self.init(mailbox: mailbox, uidValidity: validity, uid: uid)
    }

    package var string: String { "\(mailbox):\(uidValidity):\(uid)" }
}

package actor IMAPMailSource: MailSource {
    package nonisolated let accountID: String

    private let account: MailAccount
    private let secrets: any MailSecretStore
    private let connector: IMAPConnector
    private let lang: UILang
    private let timeouts: IMAPClient.Timeouts
    private let idleClose: Duration
    private let now: @Sendable () -> Date
    private let trace: IMAPClient.Trace?
    private let gate = IMAPSerialGate()

    private var client: IMAPClient?
    private var generation = 0
    private var idleTask: Task<Void, Never>?
    /// `shutdown()` ran: no new session is ever opened again.
    private var isShutDown = false
    /// A session still signing in (closed by `shutdown()` so a silent server can't hold the quit).
    private var signingIn: IMAPClient?

    package init(account: MailAccount, secrets: any MailSecretStore, connector: IMAPConnector = .tls,
                 lang: UILang = .en, timeouts: IMAPClient.Timeouts = .standard, idleClose: Duration = .seconds(30),
                 now: @escaping @Sendable () -> Date = { Date() }, trace: IMAPClient.Trace? = nil) {
        self.accountID = account.id
        self.account = account; self.secrets = secrets; self.connector = connector; self.lang = lang
        self.timeouts = timeouts; self.idleClose = idleClose; self.now = now; self.trace = trace
    }

    // MARK: Account facts

    private struct Endpoint: Sendable {
        var host: String
        var port: UInt16
        var username: String
        var mailbox: String
    }

    private static func endpoint(_ a: MailAccount, lang: UILang) -> Result<Endpoint, IMAPError> {
        let zh = lang == .zh
        let host = (a.host?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            ?? a.imapPreset.flatMap { $0.host.isEmpty ? nil : $0.host }
        guard let host else {
            return .failure(.notConfigured(zh ? "请填写 IMAP 服务器（例如 imap.gmail.com）。"
                                              : "Enter the IMAP server (e.g. imap.gmail.com)."))
        }
        let rawPort = a.port ?? a.imapPreset?.port ?? 993
        guard rawPort > 0, rawPort <= Int(UInt16.max) else {
            return .failure(.notConfigured(zh ? "端口无效：\(rawPort)" : "Invalid port: \(rawPort)"))
        }
        guard let user = (a.username?.trimmingCharacters(in: .whitespaces)).flatMap({ $0.isEmpty ? nil : $0 }) else {
            return .failure(.notConfigured(zh ? "请填写邮箱地址（用户名）。" : "Enter the mailbox address (user name)."))
        }
        let mailbox = (a.mailbox?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "INBOX"
        return .success(Endpoint(host: host, port: UInt16(rawPort), username: user, mailbox: mailbox))
    }

    private static func noPassword(_ user: String, lang: UILang) -> String {
        lang == .zh ? "尚未保存 \(user) 的应用专用密码。请在邮箱服务商处生成后点「测试并保存」。"
                    : "No app password saved for \(user). Create one with your provider, then choose Test & Save."
    }

    private static func readyDetail(_ e: Endpoint, _ box: IMAPClient.Mailbox, lang: UILang) -> String {
        lang == .zh ? "已登录 \(e.username) · \(e.mailbox)（\(box.exists) 封邮件）"
                    : "Signed in as \(e.username) · \(e.mailbox) (\(box.exists) messages)"
    }

    /// MailSourceStatus for a failure while connecting / signing in / opening the mailbox.
    package static func status(for error: any Error, host: String, lang: UILang) -> MailSourceStatus {
        guard let e = error as? IMAPError else { return .unavailable(unreachable(host, lang)) }
        switch e {
        case .notConfigured(let m): return .needsSetup(m)
        case .authenticationFailed, .loginDisabled: return .authFailed(e.message(host: host, lang: lang))
        case .mailboxUnavailable: return .needsSetup(e.message(host: host, lang: lang))
        default: return .unavailable(e.message(host: host, lang: lang))
        }
    }

    private static func unreachable(_ host: String, _ lang: UILang) -> String {
        lang == .zh ? "\(host) 暂时不可用。" : "\(host) is unavailable right now."
    }

    /// `status(for:host:lang:)` in either language. A setup problem (`notConfigured`) carries
    /// the text of the language it was raised in: it is worded again when it is one of this
    /// account's own setup texts (no server, bad port, no user name, no app password saved).
    package static func localizedStatus(for error: any Error, account: MailAccount) -> MailLocalizedStatus {
        let host = account.host ?? account.imapPreset?.host ?? ""
        guard let e = error as? IMAPError else { return MailLocalizedStatus { .unavailable(unreachable(host, $0)) } }
        if case .notConfigured(let m) = e {
            return MailLocalizedStatus { .needsSetup(setupText(m, account: account, lang: $0)) }
        }
        return MailLocalizedStatus { status(for: e, host: host, lang: $0) }
    }

    /// `text` (a setup problem of `account`, worded in any language) in `lang`; unknown text unchanged.
    static func setupText(_ text: String, account: MailAccount, lang: UILang) -> String {
        for from in [UILang.en, .zh] {
            if case .failure(.notConfigured(let m)) = endpoint(account, lang: from), m == text,
               case .failure(.notConfigured(let worded)) = endpoint(account, lang: lang) {
                return worded
            }
            if case .success(let ep) = endpoint(account, lang: from), noPassword(ep.username, lang: from) == text {
                return noPassword(ep.username, lang: lang)
            }
        }
        return text
    }

    // MARK: MailSource

    package func status() async -> MailSourceStatus { await localizedStatus().render(lang) }

    /// One sign-in (EXAMINE of the mailbox); the result is worded in the language asked for later.
    package func localizedStatus() async -> MailLocalizedStatus {
        await gate.acquire()
        defer { gate.release() }
        let account = self.account
        let ep: Endpoint
        switch Self.endpoint(account, lang: lang) {
        case .success(let e): ep = e
        case .failure:
            return MailLocalizedStatus { l in
                guard case .failure(let e) = Self.endpoint(account, lang: l) else { return .needsSetup("") }
                return Self.status(for: e, host: "", lang: l)
            }
        }
        guard let pw = await secrets.secret(for: account.secretKey), !pw.isEmpty else {
            let user = ep.username
            return MailLocalizedStatus { .needsSetup(Self.noPassword(user, lang: $0)) }
        }
        do {
            let box = try await withSession(ep, password: pw) { c in try await c.examine(ep.mailbox) }
            return MailLocalizedStatus { .ready(detail: Self.readyDetail(ep, box, lang: $0)) }
        } catch {
            let host = ep.host
            let e = error as? IMAPError
            return MailLocalizedStatus { l in e.map { Self.status(for: $0, host: host, lang: l) } ?? .unavailable(Self.unreachable(host, l)) }
        }
    }

    package func listHeaders(since: MailCursor?, limit: Int) async throws -> MailHeaderPage {
        await gate.acquire()
        defer { gate.release() }
        let ep = try Self.endpoint(account, lang: lang).get()
        guard let pw = await secrets.secret(for: account.secretKey), !pw.isEmpty else {
            throw IMAPError.notConfigured(Self.noPassword(ep.username, lang: lang))
        }
        let lookback = account.lookbackDays
        let nowDate = now()
        let pageLimit = max(1, limit)
        return try await withSession(ep, password: pw) { c in
            let box = try await c.examine(ep.mailbox)
            guard let validity = box.uidValidity else { throw IMAPError.protocolError("no UIDVALIDITY") }
            let uidNextMinus1 = box.uidNext.map { $0 > 0 ? $0 - 1 : 0 }

            var state: IMAPCursorState
            if let prior = IMAPCursorState(since), prior.uidValidity == validity, prior.mailbox == ep.mailbox {
                state = prior
            } else {
                if since != nil {
                    MailTransportLog.logger.info("imap: UIDVALIDITY/mailbox changed — resync by date")
                }
                if lookback <= 0 {
                    // No backfill: only mail that arrives from now on.
                    state = IMAPCursorState(mailbox: ep.mailbox, uidValidity: validity, lastUID: uidNextMinus1 ?? 0)
                    if uidNextMinus1 == nil {
                        state.since = IMAPResponseParser.searchDate(nowDate)
                    }
                } else {
                    let from = nowDate.addingTimeInterval(-Double(lookback) * 86_400)
                    state = IMAPCursorState(mailbox: ep.mailbox, uidValidity: validity, lastUID: 0,
                                            since: IMAPResponseParser.searchDate(from))
                }
            }

            var uids: [UInt32] = []
            let nothingNew = state.since == nil && box.uidNext.map { state.lastUID &+ 1 >= $0 } == true
            if !nothingNew, state.lastUID < UInt32.max {
                let from: UInt32? = (state.since != nil && state.lastUID == 0) ? nil : state.lastUID + 1
                let sinceDate = state.since.flatMap(Self.parseSearchDate)
                uids = try await c.uidSearch(fromUID: from, since: sinceDate).filter { $0 > state.lastUID }
            }
            let page = Array(uids.prefix(pageLimit))
            let hasMore = uids.count > page.count
            // Deferred messages first (headers only; the engine decides whether they are due) —
            // those above `lastUID` too when the search does not return them (a re-listed look-back
            // that does not reach back to them); the others come with their page.
            let pageSet = Set(page), searched = Set(uids)
            let retry = (state.retry ?? []).filter {
                !pageSet.contains($0) && ($0 <= state.lastUID || !searched.contains($0))
            }
            let wanted = retry + page

            var headers: [MailHeader] = []
            if !wanted.isEmpty {
                let records = try await c.uidFetchHeaders(wanted)
                let mailbox = ep.mailbox
                headers = await BlockingIO.run { () -> [MailHeader] in
                    records.compactMap { r in
                        guard var h = try? MIMEParser.parseHeaders(r.data) else { return nil }
                        h.ref = IMAPMessageRef(mailbox: mailbox, uidValidity: validity, uid: r.uid).string
                        if let d = r.internalDate { h.receivedAt = d }
                        if let s = r.size { h.sizeBytes = s }
                        return h
                    }
                }
                if headers.count < records.count {
                    MailTransportLog.logger.info("imap: \(records.count - headers.count, privacy: .public) header block(s) unparseable — skipped")
                }
            }

            var next = state
            next.retry = nil
            if let m = page.last { next.lastUID = max(next.lastUID, m) }
            if !hasMore {
                if let n = uidNextMinus1 {
                    next.lastUID = max(next.lastUID, n)
                    next.since = nil
                } else if next.lastUID > 0 {
                    next.since = nil
                }
            }
            MailTransportLog.logger.info("imap listHeaders: \(headers.count, privacy: .public) header(s), hasMore=\(hasMore, privacy: .public)")
            return MailHeaderPage(headers: headers, nextCursor: next.cursor, hasMore: hasMore)
        }
    }

    /// Keeps the deferred messages listable: their UIDs go into the cursor's retry list.
    package func deferring(_ refs: [String], in cursor: MailCursor) async -> MailCursor? {
        await deferral(refs, in: cursor)?.cursor
    }

    /// The look-back listed again from its start (`lastUID` 0 + the look-back date, like a first
    /// sync) with `cursor`'s retry UIDs kept: a deferred message older than the look-back is still
    /// listed (`listHeaders`). Nil without a look-back or for an unreadable cursor.
    package func relisting(_ cursor: MailCursor) async -> MailCursor? {
        guard account.lookbackDays > 0, let old = IMAPCursorState(cursor) else { return nil }
        let from = now().addingTimeInterval(-Double(account.lookbackDays) * 86_400)
        return IMAPCursorState(mailbox: old.mailbox, uidValidity: old.uidValidity, lastUID: 0,
                               since: IMAPResponseParser.searchDate(from), retry: old.retry).cursor
    }

    /// `deferring`; past `IMAPCursorState.maxRetry` UIDs the oldest are dropped — returned as
    /// `dropped` (the engine counts them on the account and lists the look-back again on
    /// 「立即同步」), never lost silently.
    package func deferral(_ refs: [String], in cursor: MailCursor) async -> MailDeferral? {
        guard var state = IMAPCursorState(cursor) else { return nil }
        var retry = state.retry ?? []
        var refByUID: [UInt32: String] = [:]
        for ref in refs {
            // Only refs of this mailbox / UIDVALIDITY that were listed (≤ `lastUID`; a newer UID
            // comes with the next search anyway) — or any UID while a look-back still pages
            // (`since`): a re-listed look-back's retry UID older than its window is listed from
            // the retry list alone (`listHeaders`).
            guard let r = IMAPMessageRef(ref), r.mailbox == state.mailbox, r.uidValidity == state.uidValidity,
                  r.uid <= state.lastUID || state.since != nil else { continue }
            refByUID[r.uid] = ref
            if !retry.contains(r.uid) { retry.append(r.uid) }
        }
        var dropped: [String] = []
        if retry.count > IMAPCursorState.maxRetry {
            let gone = retry.prefix(retry.count - IMAPCursorState.maxRetry)
            dropped = gone.map { refByUID[$0] ?? IMAPMessageRef(mailbox: state.mailbox, uidValidity: state.uidValidity, uid: $0).string }
            retry.removeFirst(retry.count - IMAPCursorState.maxRetry)
        }
        state.retry = retry.isEmpty ? nil : retry
        return MailDeferral(cursor: state.cursor, dropped: dropped)
    }

    package func fetchMessage(_ header: MailHeader, maxBytes: Int) async throws -> MailContent {
        await gate.acquire()
        defer { gate.release() }
        guard let ref = IMAPMessageRef(header.ref) else { throw IMAPError.invalidReference }
        let ep = try Self.endpoint(account, lang: lang).get()
        guard let pw = await secrets.secret(for: account.secretKey), !pw.isEmpty else {
            throw IMAPError.notConfigured(Self.noPassword(ep.username, lang: lang))
        }
        let cap = max(1, maxBytes)
        let data: Data = try await withSession(ep, password: pw) { c in
            var box = await c.selected
            if box?.name != ref.mailbox { box = try await c.examine(ref.mailbox) }
            guard box?.uidValidity == ref.uidValidity else { throw IMAPError.uidValidityChanged }
            guard let data = try await c.uidFetchMessage(ref.uid, maxBytes: cap) else {
                throw IMAPError.messageNotFound
            }
            return data
        }
        var content = try await BlockingIO.run { try MIMEParser.parse(data, maxAttachmentBytes: cap) }
        content.header.ref = header.ref
        content.header.receivedAt = header.receivedAt
        if let s = header.sizeBytes { content.header.sizeBytes = s }
        return content
    }

    /// Logs out and drops the cached session (account removed / changed).
    package func close() async {
        await gate.acquire()
        defer { gate.release() }
        idleTask?.cancel()
        idleTask = nil
        await dropSession(logout: true)
    }

    /// App quitting: never opens a session again and closes the cached one without waiting on
    /// the server — LOGOUT gets at most `logoutWithin`, then the connection is dropped. Does not
    /// wait for an operation in flight (it fails at once when its connection closes).
    package func shutdown(logoutWithin limit: Duration = .seconds(1)) async {
        isShutDown = true
        idleTask?.cancel()
        idleTask = nil
        if let pending = signingIn {
            signingIn = nil
            await pending.close()
        }
        guard let c = client else { return }
        client = nil
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await c.logout() }
            group.addTask {
                try? await Task.sleep(for: limit)
                await c.close()                     // unblocks a LOGOUT (or a command) still waiting
            }
            await group.next()
            group.cancelAll()
        }
        await c.close()
    }

    // MARK: 「测试并保存」

    /// LOGIN + EXAMINE + LOGOUT with a password that is not saved yet (Settings ▸ Mail ▸ Test & Save).
    package static func test(account: MailAccount, password: String, connector: IMAPConnector = .tls,
                             lang: UILang = .en, timeouts: IMAPClient.Timeouts = .standard,
                             trace: IMAPClient.Trace? = nil) async -> MailSourceStatus {
        let ep: Endpoint
        switch endpoint(account, lang: lang) {
        case .success(let e): ep = e
        case .failure(let e): return status(for: e, host: "", lang: lang)
        }
        guard !password.isEmpty else { return .needsSetup(noPassword(ep.username, lang: lang)) }
        var client: IMAPClient?
        do {
            let c = try await IMAPClient.connect(host: ep.host, port: ep.port, connector: connector,
                                                 timeouts: timeouts, trace: trace)
            client = c
            try await c.login(username: ep.username, password: password)
            let box = try await c.examine(ep.mailbox)
            await c.logout()
            return .ready(detail: readyDetail(ep, box, lang: lang))
        } catch {
            await client?.close()
            return status(for: error, host: ep.host, lang: lang)
        }
    }

    /// Mailbox names for the Settings picker (LOGIN + LIST + LOGOUT with an unsaved password).
    package static func listMailboxes(account: MailAccount, password: String, connector: IMAPConnector = .tls,
                                      lang: UILang = .en, timeouts: IMAPClient.Timeouts = .standard) async throws -> [String] {
        let ep = try endpoint(account, lang: lang).get()
        guard !password.isEmpty else { throw IMAPError.notConfigured(noPassword(ep.username, lang: lang)) }
        let c = try await IMAPClient.connect(host: ep.host, port: ep.port, connector: connector, timeouts: timeouts)
        do {
            try await c.login(username: ep.username, password: password)
            let names = try await c.listMailboxes()
            await c.logout()
            return names
        } catch {
            await c.close()
            throw error
        }
    }

    // MARK: Session

    /// Runs `body` on a logged-in session, reusing the cached one. A reused session that
    /// fails at the transport level is replaced once by a fresh connection.
    private func withSession<T: Sendable>(_ ep: Endpoint, password: String,
                                          _ body: (IMAPClient) async throws -> T) async throws -> T {
        guard !isShutDown else { throw IMAPError.connectionClosed }
        idleTask?.cancel()
        idleTask = nil
        defer { scheduleIdleClose() }
        if let c = client, !(await c.isClosed) {
            do {
                return try await body(c)
            } catch let e as IMAPError where e.isConnectionLevel {
                MailTransportLog.logger.info("imap: cached session failed (\(MailTransportLog.reason(e), privacy: .public)) — reconnecting")
                await dropSession(logout: false)
            } catch {
                throw error
            }
        }
        guard !isShutDown else { throw IMAPError.connectionClosed }
        let fresh = try await openSession(ep, password: password)
        do {
            return try await body(fresh)
        } catch let e as IMAPError where e.isConnectionLevel {
            await dropSession(logout: false)
            throw e
        }
    }

    private func openSession(_ ep: Endpoint, password: String) async throws -> IMAPClient {
        let c = try await IMAPClient.connect(host: ep.host, port: ep.port, connector: connector,
                                             timeouts: timeouts, trace: trace)
        guard !isShutDown else {                    // quit while connecting
            await c.close()
            throw IMAPError.connectionClosed
        }
        signingIn = c
        defer { signingIn = nil }
        do {
            try await c.login(username: ep.username, password: password)
        } catch {
            await c.close()
            throw error
        }
        guard !isShutDown else {                    // quit while signing in
            await c.close()
            throw IMAPError.connectionClosed
        }
        client = c
        return c
    }

    private func dropSession(logout: Bool) async {
        guard let c = client else { return }
        client = nil
        if logout { await c.logout() } else { await c.close() }
    }

    private func scheduleIdleClose() {
        guard !isShutDown else { return }
        generation += 1
        let gen = generation
        let delay = idleClose
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.closeIfIdle(generation: gen)
        }
    }

    private func closeIfIdle(generation gen: Int) async {
        await gate.acquire()
        defer { gate.release() }
        guard gen == generation else { return }
        await dropSession(logout: true)
    }

    private static func parseSearchDate(_ s: String) -> Date? {
        IMAPResponseParser.parseInternalDate(s + " 12:00:00 +0000")
    }
}
