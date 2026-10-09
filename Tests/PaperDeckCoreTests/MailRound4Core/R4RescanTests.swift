import Foundation
import Testing
@testable import PaperDeckCore

/// Round 4, r4-3 (r3-6 residual): 「立即同步」 on an account that had to skip messages never forgets
/// a deferred one. The re-list of the look-back keeps the cursor's retry list (IMAP retry UIDs,
/// folder retry keys — `MailSource.relisting`), an account without a look-back keeps its cursor
/// and retries its retry list, and the skipped count goes down only by the skipped messages that
/// were actually listed again. Scripted sources and a local fake IMAP server only.
@Suite(.serialized) struct R4RescanTests {
    typealias K = MailSyncKit

    private static func eml(_ name: String) -> Data {
        RFB.eml(from: "jsmith@wustl.edu", messageID: "<r4-\(name)@wustl.edu>", subject: "SECRET-\(name)")
    }

    private static func captured(_ env: R4.Env) async throws -> Set<String> {
        Set(try await env.db.mailMessages(states: Set(MailState.allCases), limit: 1000).compactMap(\.sourceRef))
    }

    private static func info(_ env: R4.Env) async throws -> MailAccountSyncInfo {
        try #require(await env.engine.mail.accountSyncInfo(lang: .en).first)
    }

    /// The verifier's probe (R3VerifierProbes.lookbackZeroRescanClearsTheSkippedCount): without a
    /// look-back, 立即同步 used to drop the cursor — for IMAP "only new mail from now on" — so the
    /// deferred message was forgotten and the count cleared.
    @Test func withoutALookBackSyncNowRetriesTheRetryListAndKeepsTheCount() async throws {
        let src = R4.LookbackSource(accountID: "acct-f", lookbackDays: 0, retryCap: 1)
        try await R4.run(mail: RFB.settings(accounts: [RFB.fakeAccount(lookback: 0)]),
                         sources: { $0.id == "acct-f" ? src : nil }, start: false) { env in
            await env.engine.mail.configure(MailSyncActor.Tuning(maxFetchAttempts: 1))
            await env.engine.start()
            await env.sync()                                    // the mailbox as it is: nothing old is listed
            await src.add("a.eml", daysAgo: 1, Self.eml("a"))
            await src.add("b.eml", daysAgo: 1, Self.eml("b"))
            await src.failFetch("a.eml", times: 1000)
            await src.failFetch("b.eml", times: 1000)
            await env.sync()                                    // a deferred (retry list), b over the cap
            var info = try await Self.info(env)
            #expect(info.skipped == 1)
            let stored = try #require(try await env.db.mailCursor(accountID: "acct-f"))

            await src.failFetch("a.eml", times: 0)
            await src.failFetch("b.eml", times: 0)
            await env.sync()                                    // 立即同步
            #expect(await src.cursorsSeen.last == .some(stored.value))       // the stored cursor, not nil
            #expect(try await Self.captured(env) == ["a.eml"])               // the retry list came back
            info = try await Self.info(env)
            #expect(info.skipped == 1)                                        // b was never listed again
            #expect(info.skippedHint == MailSyncText.skippedByCap(1, lookbackDays: 0, .en))
            #expect(try await env.db.mailCursor(accountID: MailSyncActor.skippedKey("acct-f"))?.value == "1")
        }
    }

    /// With a look-back, the re-list keeps the retry list: a deferred message older than the
    /// look-back is listed (and captured) together with the window.
    @Test func theRelistKeepsADeferredMessageOlderThanTheLookBack() async throws {
        let src = R4.LookbackSource(accountID: "acct-f", lookbackDays: 14, retryCap: 1)
        try await R4.run(mail: RFB.settings(accounts: [RFB.fakeAccount(lookback: 14)]),
                         sources: { $0.id == "acct-f" ? src : nil }, start: false) { env in
            await env.engine.mail.configure(MailSyncActor.Tuning(maxFetchAttempts: 1))
            await env.engine.start()
            await env.sync()
            await src.add("old.eml", daysAgo: 20, Self.eml("old"))           // older than the look-back by now
            await src.add("b.eml", daysAgo: 1, Self.eml("b"))
            await src.add("c.eml", daysAgo: 1, Self.eml("c"))
            for r in ["old.eml", "b.eml", "c.eml"] { await src.failFetch(r, times: 1000) }
            await env.sync()                                    // old deferred (retry list), b and c over the cap
            #expect(try await Self.info(env).skipped == 2)

            for r in ["old.eml", "b.eml", "c.eml"] { await src.failFetch(r, times: 0) }
            await env.sync()                                    // 立即同步: the look-back again, retry list kept
            #expect(try await Self.captured(env) == ["old.eml", "b.eml", "c.eml"])
            let info = try await Self.info(env)
            #expect(info.skipped == 0 && info.skippedHint == nil)
            #expect(try await env.db.mailCursor(accountID: MailSyncActor.skippedKey("acct-f")) == nil)
            #expect(try await env.db.mailCursor(accountID: MailSyncActor.skippedRefsKey("acct-f")) == nil)
        }
    }

    /// The count goes down only by what was listed again: a skipped message outside the look-back
    /// stays counted after a successful re-list (it used to be cleared).
    @Test func onlyWhatIsListedAgainLeavesTheSkippedCount() async throws {
        let src = R4.LookbackSource(accountID: "acct-f", lookbackDays: 14, retryCap: 1)
        try await R4.run(mail: RFB.settings(accounts: [RFB.fakeAccount(lookback: 14)]),
                         sources: { $0.id == "acct-f" ? src : nil }, start: false) { env in
            await env.engine.mail.configure(MailSyncActor.Tuning(maxFetchAttempts: 1))
            await env.engine.start()
            await env.sync()
            await src.add("a.eml", daysAgo: 1, Self.eml("a"))
            await src.add("far.eml", daysAgo: 30, Self.eml("far"))           // dropped, and outside the look-back
            await src.add("c.eml", daysAgo: 1, Self.eml("c"))
            for r in ["a.eml", "far.eml", "c.eml"] { await src.failFetch(r, times: 1000) }
            await env.sync()
            #expect(try await Self.info(env).skipped == 2)                   // far and c
            let refs = try #require(try await env.db.mailCursor(accountID: MailSyncActor.skippedRefsKey("acct-f"))?.value)
            #expect(!refs.contains("far") && !refs.contains(".eml"))         // hashes only, never a file name

            for r in ["a.eml", "far.eml", "c.eml"] { await src.failFetch(r, times: 0) }
            await env.sync()                                    // 立即同步
            #expect(try await Self.captured(env) == ["a.eml", "c.eml"])
            var info = try await Self.info(env)
            #expect(info.skipped == 1)                                        // far: not listed again
            guard case .unavailable(let text) = info.status else { Issue.record("status \(String(describing: info.status))"); return }
            #expect(text.contains("skipped") && !text.contains("SECRET"))

            // Sync Now again: still nothing lists it, still counted.
            await env.sync()
            info = try await Self.info(env)
            #expect(info.skipped == 1)
        }
    }

    /// A transport without `relisting` (no retry list in its cursor) still re-lists from scratch.
    @Test func aSourceWithoutRelistingStartsFromScratch() async throws {
        let src = R4.LookbackSource(accountID: "acct-f", lookbackDays: 14, retryCap: 1, supportsRelisting: false)
        try await R4.run(mail: RFB.settings(accounts: [RFB.fakeAccount(lookback: 14)]),
                         sources: { $0.id == "acct-f" ? src : nil }, start: false) { env in
            await env.engine.mail.configure(MailSyncActor.Tuning(maxFetchAttempts: 1))
            await env.engine.start()
            await env.sync()
            await src.add("a.eml", daysAgo: 1, Self.eml("a"))
            await src.add("b.eml", daysAgo: 1, Self.eml("b"))
            for r in ["a.eml", "b.eml"] { await src.failFetch(r, times: 1000) }
            await env.sync()
            let before = try await Self.info(env)
            #expect(before.skipped == 1)
            for r in ["a.eml", "b.eml"] { await src.failFetch(r, times: 0) }
            await env.sync()
            #expect(await src.cursorsSeen.last == .some(nil))
            let captured = try await Self.captured(env)
            #expect(captured == ["a.eml", "b.eml"])
            let after = try await Self.info(env)
            #expect(after.skipped == 0)
        }
    }

    // MARK: The transports

    /// IMAP: the re-list cursor starts the look-back again (lastUID 0 + its date) with the old
    /// retry UIDs, and a retry UID the date search does not return is listed with the window.
    @Test func theIMAPRelistListsRetryUIDsOlderThanTheLookBack() async throws {
        func msg(_ uid: UInt32, _ date: String) -> FakeIMAPServer.Message {
            FakeIMAPServer.Message(uid: uid, internalDate: date,
                                   raw: Data(["From: Prof <jsmith@wustl.edu>", "To: me@gmail.com", "Subject: M\(uid)",
                                              "Date: Tue, 29 Sep 2026 14:04:31 +0000", "Message-ID: <r4-imap-\(uid)@wustl.edu>",
                                              "MIME-Version: 1.0", "Content-Type: text/plain; charset=utf-8", "", "Body", ""]
                                       .joined(separator: "\r\n").utf8))
        }
        let server = try FakeIMAPServer(.init(messages: [msg(101, "10-Sep-2026 10:00:00 +0000"),
                                                        msg(102, "25-Sep-2026 10:00:00 +0000"),
                                                        msg(103, "29-Sep-2026 08:15:00 +0000")]))
        defer { server.stop() }
        let now = Date(timeIntervalSince1970: 1_790_856_000)              // 2026-10-01 12:00 UTC
        let account = MailAccount(id: "acct-r4-imap", kind: .imap, displayName: "Gmail test", lookbackDays: 14,
                                  imapPreset: .gmail, host: "imap.gmail.com", port: 993, username: "me@gmail.com",
                                  mailbox: "INBOX")
        let store = InMemoryMailSecretStore()
        try await store.setSecret("abcd efgh ijkl mnop", for: account.secretKey)
        let source = IMAPMailSource(account: account, secrets: store,
                                    connector: .plainForTesting(host: "127.0.0.1", port: server.port),
                                    timeouts: IMAPClient.Timeouts(connect: .seconds(5), command: .seconds(5)), now: { now })
        let old = IMAPCursorState(mailbox: "INBOX", uidValidity: 777, lastUID: 103, retry: [101]).cursor
        let relist = try #require(await source.relisting(old))
        let state = try #require(IMAPCursorState(relist))
        #expect(state.lastUID == 0 && state.since == "17-Sep-2026" && state.retry == [101])

        let page = try await source.listHeaders(since: relist, limit: 50)
        #expect(Set(page.headers.map(\.ref)) == ["INBOX:777:101", "INBOX:777:102", "INBOX:777:103"])
        // Without the re-list cursor (the old behaviour) the deferred UID is gone.
        let scratch = try await source.listHeaders(since: nil, limit: 50)
        #expect(Set(scratch.headers.map(\.ref)) == ["INBOX:777:102", "INBOX:777:103"])

        // A deferred UID above the cursor's lastUID (a re-list still paging) stays listable.
        let paging = IMAPCursorState(mailbox: "INBOX", uidValidity: 777, lastUID: 50, since: "17-Sep-2026").cursor
        let kept = try #require(await source.deferral(["INBOX:777:101"], in: paging))
        #expect(kept.dropped.isEmpty && IMAPCursorState(kept.cursor)?.retry == [101])

        // No look-back: no re-list cursor (the engine keeps the stored one).
        let noLookback = IMAPMailSource(account: MailAccount(id: "acct-r4-imap0", kind: .imap, displayName: "G", lookbackDays: 0,
                                                             imapPreset: .gmail, host: "imap.gmail.com", port: 993,
                                                             username: "me@gmail.com", mailbox: "INBOX"),
                                        secrets: store, connector: .plainForTesting(host: "127.0.0.1", port: server.port),
                                        now: { now })
        #expect(await noLookback.relisting(old) == nil)
    }

    /// Folder: the re-list ledger forgets the look-back's emails (a floor inside it moves below
    /// it) and keeps the retry keys, so a deferred file older than the look-back is still listed.
    @Test func theFolderRelistKeepsADeferredFileOlderThanTheLookBack() async throws {
        let dir = try RFB.tempRoot("pd-r4-folder")
        defer { try? FileManager.default.removeItem(at: dir) }
        let nowMs = Int64(K.start.timeIntervalSince1970 * 1000)
        var files: [(String, Date)] = []
        for (name, days) in [("Re- old.eml", 20.0), ("Re- recent.eml", 2.0)] {
            let url = dir.appendingPathComponent(name)
            try RFB.eml(from: "jsmith@wustl.edu", messageID: "<r4-folder-\(days)@wustl.edu>").write(to: url)
            let mtime = K.start.addingTimeInterval(-days * 86_400)
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
            files.append((name, mtime))
        }
        let account = MailAccount(id: "f", kind: .folder, displayName: "F", lookbackDays: 14, folderPath: dir.path)
        let source = FolderMailSource(account: account, now: { K.start }, settleSeconds: 0)
        // As the engine left it: the recent file listed (in the ledger, below a floor), the old one
        // deferred (no entry, its key in `retry`).
        let recentSize = Int64(try Data(contentsOf: dir.appendingPathComponent("Re- recent.eml")).count)
        let ledger = FolderLedger(floor: nowMs - 86_400_000,
                                  files: [FolderLedger.Entry(key: FolderLedger.key(forFileName: "Re- recent.eml"), size: recentSize,
                                                             mtimeMs: Int64(files[1].1.timeIntervalSince1970 * 1000))],
                                  retry: [FolderLedger.key(forFileName: "Re- old.eml")])
        let relist = try #require(await source.relisting(ledger.cursor))
        let relisted = try #require(FolderLedger(relist))
        #expect(relisted.retry == ledger.retry && relisted.files.isEmpty)
        #expect((relisted.floor ?? 0) < nowMs - 14 * 86_400_000)
        let page = try await source.listHeaders(since: relist, limit: 50)
        #expect(page.headers.map(\.ref) == ["Re- old.eml", "Re- recent.eml"])

        // Without it (the old behaviour: no cursor) the old file is recorded as seen, never listed.
        let fresh = FolderMailSource(account: account, now: { K.start }, settleSeconds: 0)
        let scratch = try await fresh.listHeaders(since: nil, limit: 50)
        #expect(scratch.headers.map(\.ref) == ["Re- recent.eml"])

        let noLookback = FolderMailSource(account: MailAccount(id: "f0", kind: .folder, displayName: "F", lookbackDays: 0,
                                                               folderPath: dir.path), now: { K.start }, settleSeconds: 0)
        #expect(await noLookback.relisting(ledger.cursor) == nil)
    }
}
