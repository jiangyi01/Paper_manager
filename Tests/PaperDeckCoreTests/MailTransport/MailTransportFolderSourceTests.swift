import Darwin
import Foundation
import Testing
@testable import PaperDeckCore

// MARK: - Helpers (private to this file)

/// Temp folder removed (after restoring permissions) when the test ends.
private final class MailTempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-mailfolder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit {
        chmod(url.path, 0o755)
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ name: String, _ data: Data, mtime: Date) throws -> URL {
        let u = url.appendingPathComponent(name)
        try data.write(to: u)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: u.path)
        return u
    }
}

private func eml(_ id: String, from: String = "bioRxiv <alerts@biorxiv.org>", subject: String? = nil) -> Data {
    Data([
        "From: \(from)",
        "To: me@wustl.edu",
        "Subject: \(subject ?? "Alert \(id)")",
        "Date: Tue, 29 Sep 2026 14:04:31 +0000",
        "Message-ID: <\(id)@example.org>",
        "Content-Type: text/plain; charset=utf-8",
        "",
        "Body of \(id).",
        "",
    ].joined(separator: "\r\n").utf8)
}

private func folderAccount(_ path: String?, lookback: Int = 14, delete: Bool = false) -> MailAccount {
    MailAccount(id: "acct-folder-test", kind: .folder, displayName: "WashU (Power Automate)",
                lookbackDays: lookback, folderPath: path, deleteProcessedFiles: delete)
}

@Suite struct MailTransportFolderSourceTests {
    private let t0 = Date()

    private func source(_ dir: MailTempDir?, lookback: Int = 14, delete: Bool = false,
                        lang: UILang = .en) -> FolderMailSource {
        let now = t0
        return FolderMailSource(account: folderAccount(dir?.url.path, lookback: lookback, delete: delete),
                                lang: lang, now: { now }, settleSeconds: 2, readTimeout: .seconds(120))
        // 120 s, not 10 (ENV-1): every folder source shares one serial read queue, so on a loaded
        // machine other suites' reads queue ahead and a short timeout skipped files (two timeouts end
        // a listing early). Nothing here tests the timeout itself.
    }

    @Test func listsNewEmlFilesByMtimeAndIgnoresPartialOrHiddenOnes() async throws {
        let dir = try MailTempDir()
        try dir.write("a.eml", eml("a"), mtime: t0.addingTimeInterval(-3 * 3600))
        try dir.write("b.eml", eml("b"), mtime: t0.addingTimeInterval(-1 * 3600))
        try dir.write("C.EML", eml("c"), mtime: t0.addingTimeInterval(-2 * 3600))
        for ignored in [".hidden.eml", "~$draft.eml", "._a.eml", "d.eml.partial", "e.eml.tmp", "f.partial.eml",
                        "notes.txt", "g.msg"] {
            try dir.write(ignored, eml(ignored), mtime: t0.addingTimeInterval(-3600))
        }
        try dir.write("empty.eml", Data(), mtime: t0.addingTimeInterval(-3600))
        try FileManager.default.createDirectory(at: dir.url.appendingPathComponent("sub.eml"), withIntermediateDirectories: false)
        try dir.write("fresh.eml", eml("fresh"), mtime: t0.addingTimeInterval(-0.5))      // still being written

        let src = source(dir)
        let page = try await src.listHeaders(since: nil, limit: 50)
        #expect(page.headers.map(\.ref) == ["a.eml", "C.EML", "b.eml"])
        #expect(!page.hasMore)
        try #require(page.headers.count > 0)          // no index past a failed expectation (QA-15)
        #expect(page.headers[0].fromAddress == "alerts@biorxiv.org")
        #expect(page.headers[0].internetMessageID == "<a@example.org>")
        #expect(page.headers[0].sizeBytes == eml("a").count)

        // Ledger: nothing is listed twice…
        let again = try await src.listHeaders(since: page.nextCursor, limit: 50)
        #expect(again.headers.isEmpty)
        // …except the settled fresh file, once the settle window has passed.
        let laterNow = t0.addingTimeInterval(5)
        let later = FolderMailSource(account: folderAccount(dir.url.path), now: { laterNow })
        let settled = try await later.listHeaders(since: again.nextCursor, limit: 50)
        #expect(settled.headers.map(\.ref) == ["fresh.eml"])
    }

    @Test func ledgerStoresHashedNamesAndRelistsChangedFiles() async throws {
        let dir = try MailTempDir()
        try dir.write("Re Papers for Thursday.eml", eml("p1"), mtime: t0.addingTimeInterval(-600))
        let src = source(dir)
        let p1 = try await src.listHeaders(since: nil, limit: 10)
        #expect(p1.headers.count == 1)
        let cursor = try #require(p1.nextCursor)
        #expect(!cursor.value.contains("Thursday") && !cursor.value.contains(".eml"))
        let ledger = try #require(FolderLedger(cursor))
        #expect(ledger.files.map(\.key) == [FolderLedger.key(forFileName: "Re Papers for Thursday.eml")])
        let first = try #require(ledger.files.first)                      // no index past a failed expectation
        #expect(first.key.count == 16)

        // Same name, new content and mtime (e.g. Power Automate overwrote it) → listed again.
        try dir.write("Re Papers for Thursday.eml", eml("p2", subject: "Updated"), mtime: t0.addingTimeInterval(-300))
        let p2 = try await src.listHeaders(since: cursor, limit: 10)
        #expect(p2.headers.map(\.internetMessageID) == ["<p2@example.org>"])
        let p3 = try await src.listHeaders(since: p2.nextCursor, limit: 10)
        #expect(p3.headers.isEmpty)
    }

    @Test func pagesByLimit() async throws {
        let dir = try MailTempDir()
        for i in 0..<5 { try dir.write("m\(i).eml", eml("m\(i)"), mtime: t0.addingTimeInterval(Double(-600 + i))) }
        let src = source(dir)
        let p1 = try await src.listHeaders(since: nil, limit: 2)
        #expect(p1.headers.map(\.ref) == ["m0.eml", "m1.eml"])
        #expect(p1.hasMore)
        let p2 = try await src.listHeaders(since: p1.nextCursor, limit: 2)
        #expect(p2.headers.map(\.ref) == ["m2.eml", "m3.eml"])
        let p3 = try await src.listHeaders(since: p2.nextCursor, limit: 2)
        #expect(p3.headers.map(\.ref) == ["m4.eml"])
        #expect(!p3.hasMore)
        // A page that was not committed can be re-read from the old cursor.
        let replay = try await src.listHeaders(since: p1.nextCursor, limit: 2)
        #expect(replay.headers.map(\.ref) == ["m2.eml", "m3.eml"])
    }

    @Test func firstSyncSkipsFilesOlderThanLookbackForever() async throws {
        let dir = try MailTempDir()
        try dir.write("old.eml", eml("old"), mtime: t0.addingTimeInterval(-20 * 86_400))
        try dir.write("new.eml", eml("new"), mtime: t0.addingTimeInterval(-86_400))
        let src = source(dir)
        let p1 = try await src.listHeaders(since: nil, limit: 10)
        #expect(p1.headers.map(\.ref) == ["new.eml"])
        let p2 = try await src.listHeaders(since: p1.nextCursor, limit: 10)
        #expect(p2.headers.isEmpty)
        // After the first sync, an old file that is newly copied in is still picked up.
        try dir.write("copied-old.eml", eml("copied"), mtime: t0.addingTimeInterval(-30 * 86_400))
        let p3 = try await src.listHeaders(since: p2.nextCursor, limit: 10)
        #expect(p3.headers.map(\.ref) == ["copied-old.eml"])

        // Lookback 0: files present at the first sync are recorded, not listed.
        let zero = source(dir, lookback: 0)
        let z1 = try await zero.listHeaders(since: nil, limit: 10)
        #expect(z1.headers.isEmpty)
        try dir.write("after.eml", eml("after"), mtime: t0.addingTimeInterval(-60))
        let z2 = try await zero.listHeaders(since: z1.nextCursor, limit: 10)
        #expect(z2.headers.map(\.ref) == ["after.eml"])
    }

    @Test func vanishedFilesArePrunedFromTheLedger() async throws {
        let dir = try MailTempDir()
        try dir.write("x.eml", eml("x"), mtime: t0.addingTimeInterval(-600))
        try dir.write("y.eml", eml("y"), mtime: t0.addingTimeInterval(-500))
        let src = source(dir)
        let p1 = try await src.listHeaders(since: nil, limit: 10)
        #expect(FolderLedger(p1.nextCursor)?.files.count == 2)
        try FileManager.default.removeItem(at: dir.url.appendingPathComponent("x.eml"))
        let p2 = try await src.listHeaders(since: p1.nextCursor, limit: 10)
        #expect(p2.headers.isEmpty)
        #expect(FolderLedger(p2.nextCursor)?.files.map(\.key) == [FolderLedger.key(forFileName: "y.eml")])
    }

    @Test func ledgerCapKeepsNewestAndSetsFloor() {
        var l = FolderLedger()
        for i in 0..<6 { l.record(.init(key: "k\(i)", size: 1, mtimeMs: Int64(100 + i))) }
        l.record(.init(key: "k2", size: 9, mtimeMs: 102))     // update in place
        l.enforceCap(3)
        #expect(l.files.map(\.key) == ["k3", "k4", "k5"])
        #expect(l.floor == 102)
        #expect(FolderLedger(l.cursor) == l)
        #expect(l.cursor.value.contains(#"["k3",1,103]"#))
    }

    @Test func floorTreatsOlderUnknownFilesAsSeen() async throws {
        let dir = try MailTempDir()
        let oldMs = Int64((t0.addingTimeInterval(-3600).timeIntervalSince1970 * 1000).rounded())
        try dir.write("below.eml", eml("below"), mtime: t0.addingTimeInterval(-7200))
        try dir.write("above.eml", eml("above"), mtime: t0.addingTimeInterval(-60))
        let cursor = FolderLedger(floor: oldMs).cursor
        let page = try await source(dir).listHeaders(since: cursor, limit: 10)
        #expect(page.headers.map(\.ref) == ["above.eml"])
    }

    @Test func deleteAfterCaptureOnlyWhenEnabledAndUnchanged() async throws {
        let dir = try MailTempDir()
        try dir.write("keep.eml", eml("keep"), mtime: t0.addingTimeInterval(-600))
        let keeper = source(dir, delete: false)
        let kp = try await keeper.listHeaders(since: nil, limit: 10)
        await keeper.didCapture(try #require(kp.headers.first))
        #expect(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("keep.eml").path))

        let del = try MailTempDir()
        try del.write("gone.eml", eml("gone"), mtime: t0.addingTimeInterval(-600))
        try del.write("swapped.eml", eml("first"), mtime: t0.addingTimeInterval(-500))
        let deleter = source(del, delete: true)
        let dp = try await deleter.listHeaders(since: nil, limit: 10)
        #expect(dp.headers.map(\.ref) == ["gone.eml", "swapped.eml"])
        // swapped.eml was replaced by a different message after it was listed → kept.
        try del.write("swapped.eml", eml("second"), mtime: t0.addingTimeInterval(-100))
        for h in dp.headers { await deleter.didCapture(h) }
        #expect(!FileManager.default.fileExists(atPath: del.url.appendingPathComponent("gone.eml").path))
        #expect(FileManager.default.fileExists(atPath: del.url.appendingPathComponent("swapped.eml").path))
        // A ref that isn't a plain file name is never touched.
        let evil = MailHeader(ref: "../keep.eml", internetMessageID: "<keep@example.org>", fromAddress: "alerts@biorxiv.org",
                              fromName: nil, subject: "Alert keep", receivedAt: t0)
        await deleter.didCapture(evil)
        #expect(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("keep.eml").path))
    }

    @Test func fetchMessageReadsTheWholeFileByRef() async throws {
        let dir = try MailTempDir()
        let fixture = try #require(Bundle.module.url(forResource: "advisor-request", withExtension: "eml",
                                                     subdirectory: "Fixtures/mail/mail-transport"))
        try dir.write("advisor.eml", Data(contentsOf: fixture), mtime: t0.addingTimeInterval(-600))
        let src = source(dir)
        let page = try await src.listHeaders(since: nil, limit: 10)
        let header = try #require(page.headers.first)
        #expect(header.fromAddress == "x@wustl.edu")
        let content = try await src.fetchMessage(header, maxBytes: 1_000_000)
        #expect(content.header.ref == "advisor.eml")
        #expect(content.plainText?.contains("journal club") == true)

        var traversal = header
        traversal.ref = "../advisor.eml"
        await #expect(throws: FolderMailSourceError.invalidReference) { _ = try await src.fetchMessage(traversal, maxBytes: 100) }
        var missing = header
        missing.ref = "missing.eml"
        await #expect(throws: (any Error).self) { _ = try await src.fetchMessage(missing, maxBytes: 100) }
    }

    @Test func nonMailFilesDoNotBreakListingAndAreNotRetried() async throws {
        let dir = try MailTempDir()
        try dir.write("junk.eml", Data([0xFF, 0x00, 0x13, 0x37]), mtime: t0.addingTimeInterval(-900))
        try dir.write("real.eml", eml("real"), mtime: t0.addingTimeInterval(-600))
        let src = source(dir)
        let p1 = try await src.listHeaders(since: nil, limit: 10)
        #expect(p1.headers.contains { $0.ref == "real.eml" })
        #expect(FolderLedger(p1.nextCursor)?.files.count == 2)
        let p2 = try await src.listHeaders(since: p1.nextCursor, limit: 10)
        #expect(p2.headers.isEmpty)
    }

    @Test func statusReflectsTheFolder() async throws {
        #expect(await source(nil).status() == .needsSetup("Choose the folder that receives .eml files."))

        // A missing folder is transient (OneDrive not mounted yet): retried, never parked.
        let missing = FolderMailSource(account: folderAccount("/nonexistent-\(UUID().uuidString)/PaperDeck Mail"))
        guard case .unavailable(let m) = await missing.status() else { Issue.record("unavailable"); return }
        #expect(m.hasPrefix("Folder not found:") && m.contains("OneDrive"))
        await #expect(throws: FolderMailSourceError.self) { _ = try await missing.listHeaders(since: nil, limit: 1) }

        let dir = try MailTempDir()
        let file = try dir.write("file.eml", eml("f"), mtime: t0.addingTimeInterval(-600))
        let notDir = FolderMailSource(account: folderAccount(file.path))
        guard case .needsSetup(let nd) = await notDir.status() else { Issue.record("not a folder"); return }
        #expect(nd.hasPrefix("Not a folder:"))

        #expect(await source(dir).status() == .ready(detail: "Watching “\(dir.url.lastPathComponent)” · 1 email"))
        #expect(await source(dir, lang: .zh).status() == .ready(detail: "正在监视「\(dir.url.lastPathComponent)」· 1 封邮件"))

        chmod(dir.url.path, 0o000)
        defer { chmod(dir.url.path, 0o755) }
        guard case .unavailable(let u) = await source(dir).status() else { Issue.record("unavailable"); return }
        #expect(u.contains("permission denied"))
    }

    @Test func candidateNames() {
        #expect(FolderMailSource.isCandidateName("PaperDeck – Re: papers.eml"))
        #expect(FolderMailSource.isCandidateName("X.EML"))
        for bad in [".eml", ".x.eml", "~x.eml", "._x.eml", "x.eml.part", "x.part.eml", "x.tmp.eml", "x.emlx", "x"] {
            #expect(!FolderMailSource.isCandidateName(bad), "\(bad)")
        }
    }

    @Test func headerBlockStopsAtTheFirstBlankLine() {
        let crlf = Data("A: 1\r\nB: 2\r\n\r\nbody\r\n".utf8)
        #expect(FolderMailSource.headerBlock(crlf) == Data("A: 1\r\nB: 2\r\n\r\n".utf8))
        let lf = Data("A: 1\n\nbody".utf8)
        #expect(FolderMailSource.headerBlock(lf) == Data("A: 1\n\n".utf8))
        let none = Data("A: 1\r\nB: 2".utf8)
        #expect(FolderMailSource.headerBlock(none) == none)
    }
}
