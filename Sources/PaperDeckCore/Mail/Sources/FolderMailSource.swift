import Foundation
import PaperDeckShared

// Watched folder of .eml files (Power Automate → OneDrive "PaperDeck Mail", Apple Mail
// rules, manual Save As…). Flat folder, `*.eml` only; dotfiles, `~…` temp names and
// AppleDouble files are ignored, as are files modified within the last `settleSeconds`
// (still being written). OneDrive/iCloud placeholders are materialized by coordinated
// reads with a timeout.
//
// Cursor = processed-file ledger JSON {"v":1,"floor":ms?,"files":[[key,size,mtimeMs(,1)],…],"retry":[key,…]?}.
// Keys are truncated SHA-256 of the file name, so names (often the subject) of mail that
// the engine drops as non-allowlisted never reach the database. A file is new when its
// (key, size, mtime) is not in the ledger; entries of vanished files are pruned; beyond
// 5000 entries the oldest are dropped and `floor` (their newest mtime) marks everything
// at or below it as seen. On the first sync, files older than the lookback are recorded
// as seen without being listed. `MailHeader.ref` is the file name. `retry`: keys of files the
// engine deferred (`deferring`) — listed again even below `floor`, up to `maxRetry` (past it
// the oldest are dropped and reported, `deferral`).
//
// Files that are not RFC 822 messages (`MailFileSniffer`: e.g. a flow whose Create file got
// the trigger's HTML Body instead of Export email's, an empty file, a PDF renamed .eml) are
// recorded with a trailing 1 and counted (`MailHeaderPage.notEmailFiles`) instead of being
// listed. That verdict is only taken on stable bytes: settled, unchanged across the
// (coordinated) read, and either a minute old or seen the same way on an earlier pass; any
// later change of size / mtime makes the file new again.

package enum FolderMailSourceError: Error, Sendable, Equatable, CustomStringConvertible {
    case notConfigured
    case folderMissing(String)
    case notAFolder(String)
    case unreadable(String)
    case invalidReference

    package var description: String {
        switch self {
        case .notConfigured: "no watched folder configured"
        case .folderMissing: "watched folder not found"
        case .notAFolder: "watched path is not a folder"
        case .unreadable: "watched folder not readable"
        case .invalidReference: "invalid file reference"
        }
    }

    package func message(lang: UILang) -> String {
        let zh = lang == .zh
        switch self {
        case .notConfigured:
            return zh ? "请选择存放 .eml 邮件文件的文件夹。" : "Choose the folder that receives .eml files."
        case .folderMissing(let p):
            // The sync app named after the folder's location (a OneDrive folder reads as it always
            // did); a folder outside a cloud root gets the neutral hint.
            if let app = CloudPathHint.providerName(forPath: (p as NSString).expandingTildeInPath) {
                return zh ? "找不到文件夹：\(p)。如果是 \(app) 文件夹，请确认 \(app) 正在运行并已同步。"
                          : "Folder not found: \(p). If it's a \(app) folder, make sure \(app) is running and syncing."
            }
            return zh ? "找不到文件夹：\(p)。如果它在云盘中（OneDrive、Dropbox、Google 云端硬盘、iCloud 云盘），请确认对应的应用正在运行并已同步。"
                      : "Folder not found: \(p). If it's in a cloud folder (OneDrive, Dropbox, Google Drive, iCloud Drive), make sure that app is running and syncing."
        case .notAFolder(let p):
            return zh ? "不是文件夹：\(p)" : "Not a folder: \(p)"
        case .unreadable(let p):
            return zh ? "PaperDeck 无法读取 \(p)（权限被拒绝）。" : "PaperDeck can't read \(p) (permission denied)."
        case .invalidReference:
            return zh ? "邮件文件引用无效。" : "Invalid mail file reference."
        }
    }
}

/// The folder source's cursor value.
package struct FolderLedger: Codable, Sendable, Equatable {
    package struct Entry: Codable, Sendable, Equatable {
        package var key: String         // 16 hex chars of SHA-256(file name)
        package var size: Int64
        package var mtimeMs: Int64
        /// Read, and not an RFC 822 message (never listed; counted for the Settings hint).
        package var notMail: Bool

        package init(key: String, size: Int64, mtimeMs: Int64, notMail: Bool = false) {
            self.key = key; self.size = size; self.mtimeMs = mtimeMs; self.notMail = notMail
        }

        package init(from decoder: any Decoder) throws {
            var c = try decoder.unkeyedContainer()
            key = try c.decode(String.self); size = try c.decode(Int64.self); mtimeMs = try c.decode(Int64.self)
            notMail = c.isAtEnd ? false : (try c.decode(Int.self)) != 0
        }

        package func encode(to encoder: any Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(key); try c.encode(size); try c.encode(mtimeMs)
            if notMail { try c.encode(1) }
        }
    }

    package var v: Int = 1
    package var floor: Int64?
    package var files: [Entry] = []
    /// Deferred files (allowlisted, failing): listed again whatever `floor` says.
    package var retry: [String]?

    package init(floor: Int64? = nil, files: [Entry] = [], retry: [String]? = nil) {
        self.floor = floor; self.files = files; self.retry = retry
    }

    package static let cap = 5000
    package static let maxRetry = 1000

    /// Files in the folder that were read and are not emails (vanished ones are pruned).
    package var notMailCount: Int { files.reduce(0) { $0 + ($1.notMail ? 1 : 0) } }

    package init?(_ cursor: MailCursor?) {
        guard let cursor, let data = cursor.value.data(using: .utf8),
              let l = try? JSONDecoder().decode(FolderLedger.self, from: data) else { return nil }
        self = l
    }

    package var cursor: MailCursor {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return MailCursor(String(decoding: (try? enc.encode(self)) ?? Data(), as: UTF8.self))
    }

    package static func key(forFileName name: String) -> String {
        String(FileOps.sha256(of: Data(name.precomposedStringWithCanonicalMapping.utf8)).prefix(16))
    }

    mutating func record(_ e: Entry) {
        if let i = files.firstIndex(where: { $0.key == e.key }) { files[i] = e } else { files.append(e) }
    }

    /// Keeps the newest `cap` entries; the newest dropped mtime becomes the floor.
    mutating func enforceCap(_ cap: Int = FolderLedger.cap) {
        guard files.count > cap else { return }
        files.sort { ($0.mtimeMs, $0.key) < ($1.mtimeMs, $1.key) }
        let dropped = files.prefix(files.count - cap)
        if let newest = dropped.map(\.mtimeMs).max() { floor = max(floor ?? newest, newest) }
        files.removeFirst(files.count - cap)
    }
}

package actor FolderMailSource: MailSource {
    package nonisolated let accountID: String

    private let account: MailAccount
    private let lang: UILang
    private let now: @Sendable () -> Date
    private let settleSeconds: TimeInterval
    private let readTimeout: Duration
    /// Transient read failures (placeholder not downloadable, timeouts) are retried after this.
    private let retryAfter: TimeInterval
    /// A file that does not read as an email is only recorded as "not an email" once its mtime
    /// is this old, or after a second pass saw the same size and mtime (`suspects`).
    private let notMailSettleSeconds: TimeInterval
    private var failedUntil: [String: Date] = [:]
    /// key → (size, mtime) of files that did not read as emails but were not stable enough yet.
    private var suspects: [String: (size: Int64, mtimeMs: Int64)] = [:]
    /// key → (size, mtime) of files the ledger knows are not emails (the latest ledger seen:
    /// `prime(cursor:)` or `listHeaders`), so `status()` counts real messages only.
    private var notMailFiles: [String: (size: Int64, mtimeMs: Int64)] = [:]

    package static let headerReadBytes = 64 * 1024
    /// Coordinated reads of mail files: one at a time, separate from the import queue.
    private static let readQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "\(Log.subsystem).mail.folder"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()

    package init(account: MailAccount, lang: UILang = .en, now: @escaping @Sendable () -> Date = { Date() },
                 settleSeconds: TimeInterval = 2, readTimeout: Duration = .seconds(60), retryAfter: TimeInterval = 300,
                 notMailSettleSeconds: TimeInterval = 60) {
        self.accountID = account.id
        self.account = account; self.lang = lang; self.now = now
        self.settleSeconds = settleSeconds; self.readTimeout = readTimeout; self.retryAfter = retryAfter
        self.notMailSettleSeconds = max(settleSeconds, notMailSettleSeconds)
    }

    // MARK: Folder facts

    struct FileFact: Sendable {
        var name: String
        var url: URL
        var size: Int64
        var mtimeMs: Int64
    }

    private var folderURL: URL? {
        guard let p = account.folderPath?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// True for names the folder source may read.
    package static func isCandidateName(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasSuffix(".eml"), lower.count > 4 else { return false }
        if name.hasPrefix(".") || name.hasPrefix("~") || name.hasPrefix("._") { return false }
        for marker in [".partial", ".tmp", ".download", ".crdownload", ".part."] where lower.contains(marker) {
            return false
        }
        return true
    }

    /// Lists candidate files (flat, sorted by mtime then name; empty ones included — they are
    /// judged like any other file). Throws FolderMailSourceError.
    static func scan(_ folder: URL) throws -> [FileFact] {
        let fm = FileManager.default
        let shown = (folder.path as NSString).abbreviatingWithTildeInPath
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir) else { throw FolderMailSourceError.folderMissing(shown) }
        guard isDir.boolValue else { throw FolderMailSourceError.notAFolder(shown) }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        } catch {
            throw FolderMailSourceError.unreadable(shown)
        }
        var out: [FileFact] = []
        for url in urls {
            let name = url.lastPathComponent
            guard isCandidateName(name),
                  let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isRegularFile == true, let size = v.fileSize, size >= 0,
                  let mtime = v.contentModificationDate else { continue }
            out.append(FileFact(name: name, url: url, size: Int64(size),
                                mtimeMs: Int64((mtime.timeIntervalSince1970 * 1000).rounded())))
        }
        return out.sorted { ($0.mtimeMs, $0.name) < ($1.mtimeMs, $1.name) }
    }

    /// The header block (through the first blank line) of a message head.
    package static func headerBlock(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A {
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { return Data(bytes[0...(i + 1)]) }
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { return Data(bytes[0...(i + 2)]) }
            }
            i += 1
        }
        return data
    }

    /// Size and mtime of one file now (nil when it is gone or not a regular file). Blocking.
    static func stat(_ url: URL) -> (size: Int64, mtimeMs: Int64)? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var u = url
        u.removeAllCachedResourceValues()
        guard let v = try? u.resourceValues(forKeys: keys), v.isRegularFile == true,
              let size = v.fileSize, let mtime = v.contentModificationDate else { return nil }
        return (Int64(size), Int64((mtime.timeIntervalSince1970 * 1000).rounded()))
    }

    /// URL of a ref inside the folder; nil for anything but a plain candidate file name.
    private func fileURL(for ref: String) -> URL? {
        guard let folder = folderURL, !ref.isEmpty, !ref.contains("/"), !ref.contains("\0"),
              ref != ".", ref != "..", Self.isCandidateName(ref) else { return nil }
        return folder.appendingPathComponent(ref, isDirectory: false)
    }

    // MARK: MailSource

    package func status() async -> MailSourceStatus { await localizedStatus().render(lang) }

    /// A local scan; the result is worded in the language asked for later.
    package func localizedStatus() async -> MailLocalizedStatus {
        guard let folder = folderURL else {
            return MailLocalizedStatus { .needsSetup(FolderMailSourceError.notConfigured.message(lang: $0)) }
        }
        do {
            let files = try await BlockingIO.run { try Self.scan(folder) }
            let notMail = notMailFiles
            // Files the ledger knows are not emails (an HTML-only export…) are not counted; files
            // not read yet count as emails until a sync says otherwise.
            let messages = files.filter { f in
                guard let e = notMail[FolderLedger.key(forFileName: f.name)] else { return true }
                return e.size != f.size || e.mtimeMs != f.mtimeMs
            }.count
            let name = folder.lastPathComponent
            return MailLocalizedStatus { .ready(detail: Self.watchingDetail(folder: name, messages: messages, lang: $0)) }
        } catch let e as FolderMailSourceError {
            return MailLocalizedStatus { Self.status(for: e, lang: $0) }
        } catch {
            let path = folder.path
            return MailLocalizedStatus { .unavailable(FolderMailSourceError.unreadable(path).message(lang: $0)) }
        }
    }

    /// "Watching “PaperDeck Mail” · 3 emails".
    package static func watchingDetail(folder name: String, messages n: Int, lang: UILang) -> String {
        lang == .zh ? "正在监视「\(name)」· \(n) 封邮件"
                    : "Watching “\(name)” · \(n) email\(n == 1 ? "" : "s")"
    }

    /// Settings-facing status of a folder problem. A missing folder is a transient condition
    /// (OneDrive not mounted yet, the flow has not created it yet): retried with backoff, never
    /// parked like a rejected password. Only a missing configuration or a path that is not a
    /// folder waits for new settings.
    package static func status(for error: FolderMailSourceError, lang: UILang) -> MailSourceStatus {
        switch error {
        case .unreadable, .folderMissing, .invalidReference: return .unavailable(error.message(lang: lang))
        case .notConfigured, .notAFolder: return .needsSetup(error.message(lang: lang))
        }
    }

    package func prime(cursor: MailCursor?) async {
        guard let ledger = FolderLedger(cursor) else { return }
        rememberNotMail(ledger)
    }

    private func rememberNotMail(_ ledger: FolderLedger) {
        var out: [String: (size: Int64, mtimeMs: Int64)] = [:]
        for e in ledger.files where e.notMail { out[e.key] = (e.size, e.mtimeMs) }
        notMailFiles = out
    }

    /// The ledger without the deferred files: they are new again, so the next listing returns them.
    package func deferring(_ refs: [String], in cursor: MailCursor) async -> MailCursor? {
        await deferral(refs, in: cursor)?.cursor
    }

    /// `deferring`: the files' ledger entries go, and their keys join `retry` so a file older than
    /// the ledger's floor is listed again too. Past `FolderLedger.maxRetry` keys the oldest are
    /// dropped and reported (`dropped`, counted on the account), never lost silently.
    package func deferral(_ refs: [String], in cursor: MailCursor) async -> MailDeferral? {
        guard var ledger = FolderLedger(cursor) else { return nil }
        var refByKey: [String: String] = [:]
        for ref in refs { refByKey[FolderLedger.key(forFileName: ref)] = ref }
        ledger.files.removeAll { refByKey[$0.key] != nil }
        var retry = ledger.retry ?? []
        for key in refByKey.keys.sorted() where !retry.contains(key) { retry.append(key) }
        var dropped: [String] = []
        if retry.count > FolderLedger.maxRetry {
            let gone = retry.prefix(retry.count - FolderLedger.maxRetry)
            dropped = gone.map { refByKey[$0] ?? $0 }
            retry.removeFirst(retry.count - FolderLedger.maxRetry)
        }
        ledger.retry = retry.isEmpty ? nil : retry
        return MailDeferral(cursor: ledger.cursor, dropped: dropped)
    }

    /// The look-back listed again from its start: the ledger forgets the emails of the look-back
    /// (and a floor inside it moves below it), so they are new again; older entries, files known
    /// not to be emails and the `retry` keys stay — a deferred file older than the look-back is
    /// still listed. Nil without a look-back or for an unreadable ledger.
    package func relisting(_ cursor: MailCursor) async -> MailCursor? {
        guard account.lookbackDays > 0, var ledger = FolderLedger(cursor) else { return nil }
        let nowMs = Int64((now().timeIntervalSince1970 * 1000).rounded())
        let cutoff = nowMs - Int64(account.lookbackDays) * 86_400_000
        ledger.files.removeAll { !$0.notMail && $0.mtimeMs >= cutoff }
        if let floor = ledger.floor, floor >= cutoff { ledger.floor = cutoff - 1 }
        return ledger.cursor
    }

    package func listHeaders(since: MailCursor?, limit: Int) async throws -> MailHeaderPage {
        guard let folder = folderURL else { throw FolderMailSourceError.notConfigured }
        let files = try await BlockingIO.run { try Self.scan(folder) }
        let prior = FolderLedger(since)
        let firstSync = prior == nil
        var ledger = prior ?? FolderLedger()
        let nowDate = now()
        let nowMs = Int64((nowDate.timeIntervalSince1970 * 1000).rounded())

        let keyed = files.map { (fact: $0, key: FolderLedger.key(forFileName: $0.name)) }
        let present = Set(keyed.map(\.key))
        ledger.files.removeAll { !present.contains($0.key) }
        // Deferred files come back whatever the floor says; vanished ones are forgotten.
        let retryKeys = Set((ledger.retry ?? []).filter(present.contains))
        let known = Dictionary(ledger.files.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let settleCutoff = nowMs - Int64(settleSeconds * 1000)
        let lookbackCutoff: Int64? = account.lookbackDays > 0
            ? nowMs - Int64(account.lookbackDays) * 86_400_000 : nil
        failedUntil = failedUntil.filter { $0.value > nowDate }
        suspects = suspects.filter { present.contains($0.key) }

        var candidates: [(fact: FileFact, key: String)] = []
        for item in keyed {
            let f = item.fact
            if let e = known[item.key], e.size == f.size, e.mtimeMs == f.mtimeMs { continue }
            if known[item.key] == nil, let floor = ledger.floor, f.mtimeMs <= floor, !retryKeys.contains(item.key) { continue }
            let entry = FolderLedger.Entry(key: item.key, size: f.size, mtimeMs: f.mtimeMs)
            if firstSync, lookbackCutoff.map({ f.mtimeMs < $0 }) ?? true {
                ledger.record(entry)            // present before the first sync and outside the lookback
                continue
            }
            if f.mtimeMs > settleCutoff { continue }     // still being written — next sync
            if failedUntil[item.key] != nil { continue }
            candidates.append(item)
        }

        var headers: [MailHeader] = []
        var processed = 0
        var timeouts = 0
        var index = 0
        while index < candidates.count, processed < max(1, limit), timeouts < 2 {
            let (f, key) = candidates[index]
            index += 1
            let head: Data
            do {
                head = try await FileOps.coordinatedRead(source: f.url, timeout: readTimeout, queue: Self.readQueue) { url in
                    try FileOps.readHead(url, bytes: Self.headerReadBytes)
                }
            } catch {
                let e = FileOps.classify(error)
                if e == .timeout { timeouts += 1 }
                if e != .sourceMissing { failedUntil[key] = nowDate.addingTimeInterval(retryAfter) }
                // Read before the allowlist: never the system text (it quotes the file name).
                MailTransportLog.logger.info("mail folder: read failed (\(MailTransportLog.reason(error), privacy: .public)) — retry later")
                continue
            }
            let block = Self.headerBlock(head)
            let parsed = await BlockingIO.run { MailFileSniffer.isMessage(head) ? try? MIMEParser.parseHeaders(block) : nil }
            guard var h = parsed else {
                // Not an email — but only a stable file gets that verdict (a OneDrive download or a
                // writer still busy shows other bytes next time; any change makes it new again).
                let url = f.url
                let after = await BlockingIO.run { Self.stat(url) }
                let unchanged = (after.map { $0.size == f.size && $0.mtimeMs == f.mtimeMs } ?? false)
                    && Int64(head.count) == min(f.size, Int64(Self.headerReadBytes))
                let seen = suspects[key].map { $0.size == f.size && $0.mtimeMs == f.mtimeMs } ?? false
                let settled = nowMs - f.mtimeMs >= Int64(notMailSettleSeconds * 1000)
                guard unchanged, settled || seen else {
                    suspects[key] = unchanged ? (f.size, f.mtimeMs) : nil
                    MailTransportLog.logger.info("mail folder: a file is not a complete email yet — checked again later")
                    continue
                }
                suspects[key] = nil
                ledger.record(FolderLedger.Entry(key: key, size: f.size, mtimeMs: f.mtimeMs, notMail: true))
                processed += 1
                MailTransportLog.logger.info("mail folder: a file that is not an email was skipped")
                continue
            }
            suspects[key] = nil
            ledger.record(FolderLedger.Entry(key: key, size: f.size, mtimeMs: f.mtimeMs))
            processed += 1
            h.ref = f.name
            h.sizeBytes = Int(f.size)
            headers.append(h)
        }
        let hasMore = timeouts < 2 && index < candidates.count
        // A deferred file read in this pass has its ledger entry again (the engine defers it
        // once more if it still fails); the others keep waiting in `retry`.
        let recorded = Set(ledger.files.map(\.key))
        let waiting = (ledger.retry ?? []).filter { present.contains($0) && !recorded.contains($0) }
        ledger.retry = waiting.isEmpty ? nil : waiting
        ledger.enforceCap()
        rememberNotMail(ledger)
        let notMail = ledger.notMailCount
        MailTransportLog.logger.info("mail folder listHeaders: \(headers.count, privacy: .public) header(s), \(notMail, privacy: .public) not email, hasMore=\(hasMore, privacy: .public)")
        return MailHeaderPage(headers: headers, nextCursor: ledger.cursor, hasMore: hasMore, notEmailFiles: notMail)
    }

    package func fetchMessage(_ header: MailHeader, maxBytes: Int) async throws -> MailContent {
        guard folderURL != nil else { throw FolderMailSourceError.notConfigured }
        guard let url = fileURL(for: header.ref) else { throw FolderMailSourceError.invalidReference }
        let cap = max(1, maxBytes)
        let data = try await FileOps.coordinatedRead(source: url, timeout: readTimeout, queue: Self.readQueue) { u in
            try FileOps.readHead(u, bytes: cap)
        }
        var content = try await BlockingIO.run { try MIMEParser.parse(data, maxAttachmentBytes: cap) }
        content.header.ref = header.ref
        content.header.sizeBytes = header.sizeBytes ?? data.count
        return content
    }

    /// Deletes the captured file when the account says so — only if it is still the same
    /// message (same Message-ID, or same sender + subject when there is none).
    package func didCapture(_ header: MailHeader) async {
        guard account.deleteProcessedFiles, let url = fileURL(for: header.ref) else { return }
        guard let head = try? await FileOps.coordinatedRead(source: url, timeout: readTimeout, queue: Self.readQueue, { u in
            try FileOps.readHead(u, bytes: Self.headerReadBytes)
        }) else { return }
        let block = Self.headerBlock(head)
        let current = await BlockingIO.run { try? MIMEParser.parseHeaders(block) }
        guard let current else { return }
        let same: Bool
        if let id = header.internetMessageID, let cid = current.internetMessageID {
            same = id == cid
        } else {
            same = current.fromAddress == header.fromAddress && current.subject == header.subject
        }
        guard same else {
            MailTransportLog.logger.info("mail folder: file changed since capture — kept")
            return
        }
        let removed = await BlockingIO.run { () -> Bool in
            do { try FileManager.default.removeItem(at: url); return true } catch { return false }
        }
        MailTransportLog.logger.info("mail folder: processed file \(removed ? "deleted" : "could not be deleted", privacy: .public)")
    }
}

// MARK: - Is this file an email?

/// Whether the first bytes of a file are an RFC 822 / 5322 message: after an optional UTF-8 BOM
/// and mbox "From " line, the first line is a header field (`name:` with a printable-ASCII name
/// and no spaces), and the header block names a From (or Sender) address. An HTML-only export
/// ("<html><head><meta …"), JSON, a PDF renamed .eml, an empty file or random text is not.
/// Looks at bytes only; never logs them.
package enum MailFileSniffer {
    package static func isMessage(_ head: Data) -> Bool {
        var bytes = [UInt8](head.prefix(FolderMailSource.headerReadBytes))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        if bytes.starts(with: Array("From ".utf8)) {                       // mbox separator line
            guard let lf = bytes.firstIndex(of: 0x0A) else { return false }
            bytes.removeSubrange(...lf)
        }
        guard startsWithHeaderField(bytes) else { return false }
        let block = FolderMailSource.headerBlock(Data(bytes))
        guard let header = try? MIMEParser.parseHeaders(block) else { return false }
        return header.fromAddress.contains("@")
    }

    /// `field-name ":"` at the very start: 1…76 printable ASCII characters other than ":".
    static func startsWithHeaderField(_ bytes: [UInt8]) -> Bool {
        var n = 0
        for b in bytes {
            if b == 0x3A { return n > 0 }                                   // ":"
            guard b > 0x20, b < 0x7F, n < 76 else { return false }
            n += 1
        }
        return false
    }
}
