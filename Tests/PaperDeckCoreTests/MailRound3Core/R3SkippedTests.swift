import Foundation
import Testing
@testable import PaperDeckCore

/// Round 3, r3-6: the deferral caps (IMAP retry list 200 UIDs, folder ledger floor past 5000
/// entries) never drop an allowlisted message silently. A drop is reported by the transport
/// (`deferral`), counted on the account (`skipped`, en + zh hint, status suffix, kv), and
/// 「立即同步」 lists the look-back again to pick it up. The folder's floor no longer hides a
/// deferred file at all.
@Suite(.serialized) struct R3SkippedTests {
    typealias K = MailSyncKit

    @Test func messagesDroppedByARetryCapAreCountedAndPickedUpBySyncNow() async throws {
        let src = R3.CapSource(accountID: "acct-f", retryCap: 1)
        try await R3.run(mail: RFB.settings(accounts: [RFB.fakeAccount()]), sources: { $0.id == "acct-f" ? src : nil },
                         start: false) { env in
            await env.engine.mail.configure(MailSyncActor.Tuning(maxFetchAttempts: 1))
            await src.add("a.eml", RFB.eml(from: "jsmith@wustl.edu", messageID: "<r3-skip-a@wustl.edu>", subject: "SECRET-A"))
            await src.add("b.eml", RFB.eml(from: "jsmith@wustl.edu", messageID: "<r3-skip-b@wustl.edu>", subject: "SECRET-B"))
            await src.add("ok.eml", try K.data("biorxiv-alert"))
            await src.failFetch("a.eml", times: 1000)
            await src.failFetch("b.eml", times: 1000)
            await env.engine.start()
            await env.sync()
            #expect(try await env.messages().compactMap(\.sourceRef) == ["ok.eml"])

            var info = try #require(await env.engine.mail.accountSyncInfo(lang: .en).first)
            #expect(info.skipped == 1)
            #expect(info.skippedHint == MailSyncText.skippedByCap(1, lookbackDays: 14, .en))
            #expect(info.skippedHint?.contains("Sync Now") == true && info.skippedHint?.contains("14 days") == true)
            guard case .unavailable(let text) = info.status else { Issue.record("status \(String(describing: info.status))"); return }
            #expect(text.contains("skipped") && !text.contains("SECRET"))
            let zh = try #require(await env.engine.mail.accountSyncInfo(lang: .zh).first)
            #expect(zh.skippedHint?.contains("立即同步") == true && zh.skippedHint?.contains("跳过") == true)
            guard case .unavailable(let zhText) = zh.status else { Issue.record("status \(String(describing: zh.status))"); return }
            #expect(zhText.contains("跳过"))
            #expect(try await env.db.mailCursor(accountID: MailSyncActor.skippedKey("acct-f"))?.value == "1")

            // 立即同步 (the server answers again): the look-back is listed from the start, the skipped
            // email arrives, and the count is cleared.
            await src.failFetch("a.eml", times: 0)
            await src.failFetch("b.eml", times: 0)
            await env.sync()
            #expect(Set(try await env.messages().compactMap(\.sourceRef)) == ["ok.eml", "a.eml", "b.eml"])
            #expect(await src.cursorsSeen.last == .some(nil))                    // listed from scratch
            info = try #require(await env.engine.mail.accountSyncInfo(lang: .en).first)
            #expect(info.skipped == 0 && info.skippedHint == nil)
            guard case .ready = info.status else { Issue.record("status \(String(describing: info.status))"); return }
            #expect(try await env.db.mailCursor(accountID: MailSyncActor.skippedKey("acct-f")) == nil)
        }
    }

    @Test func aSourceThatCannotDeferCountsWhatItGivesUp() async throws {
        let src = RFB.LedgerSource(accountID: "acct-f", supportsDeferral: false)
        try await R3.run(mail: RFB.settings(accounts: [RFB.fakeAccount()]), sources: { $0.id == "acct-f" ? src : nil },
                         start: false) { env in
            await env.engine.mail.configure(MailSyncActor.Tuning(maxFetchAttempts: 1))
            await src.add("bad.eml", RFB.eml(from: "jsmith@wustl.edu", messageID: "<r3-gone@wustl.edu>"))
            await src.failFetch("bad.eml", times: 1000)
            await env.engine.start()
            await env.sync()
            #expect(await env.engine.mail.accountSyncInfo().first?.skipped == 1)
        }
    }

    @Test func theIMAPRetryListReportsWhatItsCapDrops() async throws {
        let source = IMAPMailSource(account: RFB.fakeIMAPAccount(), secrets: InMemoryMailSecretStore(),
                                    connector: .plainForTesting(host: "127.0.0.1", port: 9))
        let cursor = IMAPCursorState(mailbox: "INBOX", uidValidity: 7, lastUID: 1000).cursor
        let refs = (1...(IMAPCursorState.maxRetry + 5)).map { IMAPMessageRef(mailbox: "INBOX", uidValidity: 7, uid: UInt32($0)).string }
        let kept = try #require(await source.deferral(refs, in: cursor))
        #expect(kept.dropped == Array(refs.prefix(5)))
        let state = try #require(IMAPCursorState(kept.cursor))
        #expect(state.retry?.count == IMAPCursorState.maxRetry && state.retry?.first == 6)
        #expect(await source.deferring(refs, in: cursor) == kept.cursor)
        let few = try #require(await source.deferral(Array(refs.prefix(3)), in: cursor))
        #expect(few.dropped.isEmpty && IMAPCursorState(few.cursor)?.retry == [1, 2, 3])
    }

    /// A deferred folder file older than the ledger's floor (a folder past 5000 entries) is listed
    /// again; the retry list's own cap reports what it drops.
    @Test func aDeferredFolderFileBelowTheLedgerFloorIsListedAgain() async throws {
        let dir = try RFB.tempRoot("pd-r3-floor")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Re- hello.eml")
        try RFB.eml(from: "jsmith@wustl.edu", messageID: "<r3-floor@wustl.edu>").write(to: file)
        let mtime = K.start.addingTimeInterval(-2 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        let account = MailAccount(id: "f", kind: .folder, displayName: "F", lookbackDays: 14, folderPath: dir.path)
        let source = FolderMailSource(account: account, now: { K.start }, settleSeconds: 0)

        let first = try await source.listHeaders(since: nil, limit: 50)
        #expect(first.headers.map(\.ref) == ["Re- hello.eml"])
        // The engine defers it, and the ledger's floor has meanwhile risen above the file.
        let firstCursor = try #require(first.nextCursor)
        let deferred = try #require(await source.deferral(["Re- hello.eml"], in: firstCursor))
        #expect(deferred.dropped.isEmpty)
        var ledger = try #require(FolderLedger(deferred.cursor))
        ledger.floor = Int64(mtime.timeIntervalSince1970 * 1000) + 60_000
        #expect(!ledger.cursor.value.contains("hello"))                        // keys only, never the name

        let again = try await source.listHeaders(since: ledger.cursor, limit: 50)
        #expect(again.headers.map(\.ref) == ["Re- hello.eml"])
        #expect(FolderLedger(again.nextCursor)?.retry == nil)                   // listed: back in the ledger

        // The retry list's cap.
        let many = (0...FolderLedger.maxRetry).map { "m\($0).eml" }
        let capped = try #require(await source.deferral(many, in: FolderLedger().cursor))
        #expect(capped.dropped.count == 1 && FolderLedger(capped.cursor)?.retry?.count == FolderLedger.maxRetry)
    }
}
