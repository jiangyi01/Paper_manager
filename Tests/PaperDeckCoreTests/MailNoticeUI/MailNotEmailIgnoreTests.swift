import Foundation
import Testing
@testable import PaperDeckCore

/// The "N files aren't complete emails" notice can now be resolved: Ignore remembers the files'
/// hashed names (kv `<id>.notmail.ignored`) — the counts the notices use go to zero, survive a
/// relaunch, and a NEW not-email file warns again (for itself); Move to Trash gets exactly the
/// files the ledger knows, re-checked at click time and never outside the watched folder; the
/// skipped-emails notice hides until the count grows. Real folder source on temp folders and a
/// fake transport — no mail server, no keychain, nothing is ever moved to the Trash here.
@Suite(.serialized) struct MailNotEmailIgnoreTests {
    private typealias Kit = MailFixesKit

    /// Temp folder for the watched mail folder, removed when the test ends.
    private final class Folder: @unchecked Sendable {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("pd-noticeui-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        @discardableResult
        func write(_ name: String, _ data: Data, age: TimeInterval = 3600) throws -> URL {
            let u = url.appendingPathComponent(name)
            try data.write(to: u)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: u.path)
            return u
        }
        func remove(_ name: String) throws { try FileManager.default.removeItem(at: url.appendingPathComponent(name)) }
    }

    private static func account(_ folder: Folder) -> MailAccount {
        MailAccount(id: "pa", kind: .folder, displayName: "Work (Power Automate)", lookbackDays: 14, folderPath: folder.url.path)
    }

    private static let sources: @Sendable (MailAccount) -> (any MailSource)? = { a in
        a.kind == .folder ? FolderMailSource(account: a, settleSeconds: 2, readTimeout: .seconds(120)) : nil   // load-tolerant
    }

    private static func info(_ env: RFB.Env) async throws -> MailAccountSyncInfo {
        try #require(await env.engine.mail.accountSyncInfo(lang: .en).first)
    }

    // MARK: Ignore

    @Test func ignoreQuietsTheNoticeSurvivesARelaunchAndANewFileWarnsAgain() async throws {
        let folder = try Folder()
        try folder.write("Body only.eml", try Kit.fixture("html-only"))
        try folder.write("real.eml", try Kit.fixture("outlook-export"))
        let account = Self.account(folder)
        let root = try RFB.tempRoot("pd-noticeui")
        defer { try? FileManager.default.removeItem(at: root) }
        var env = try await RFB.make(root: root, mail: RFB.settings(accounts: [account]), sources: Self.sources)
        do {
            await env.sync()
            var info = try await Self.info(env)
            #expect(info.notEmailFiles == 1 && info.ignoredNotEmailFiles == 0 && info.notEmailHint != nil)
            #expect(MailNoticePolicy.notices([info]).map(\.kind) == [.notEmail])

            await env.engine.mail.ignoreNotEmailFiles(accountID: "pa")
            info = try await Self.info(env)
            #expect(info.notEmailFiles == 0 && info.ignoredNotEmailFiles == 1 && info.notEmailHint == nil)
            #expect(MailNoticePolicy.notices([info]).isEmpty)
            #expect(MailNoticePolicy.pill([info], enabled: true) == .synced(info.lastSuccessAt))
            // Hashed names only in the store — never the file name (often a subject).
            let stored = try #require(try await env.db.mailCursor(accountID: MailSyncActor.ignoredNotEmailKey("pa"))?.value)
            #expect(stored.contains(FolderLedger.key(forFileName: "Body only.eml")) && !stored.contains("Body only"))
            // Another pass changes nothing.
            await env.sync()
            #expect(try await Self.info(env).notEmailFiles == 0)
        } catch {
            await env.close(removeRoot: false)
            throw error
        }
        await env.close(removeRoot: false)

        // Relaunch (same library): still ignored before and after the first pass.
        env = try await RFB.make(root: root, mail: RFB.settings(accounts: [account]), sources: Self.sources, start: false)
        do {
            env.mail.value.enabled = false
            await env.engine.mail.syncNow()                       // mail off: counts seeded from the store only
            var info = try await Self.info(env)
            #expect(info.notEmailFiles == 0 && info.ignoredNotEmailFiles == 1)
            env.mail.value.enabled = true
            await env.engine.mail.settingsDidChange()
            await env.sync()
            info = try await Self.info(env)
            #expect(info.notEmailFiles == 0 && info.ignoredNotEmailFiles == 1)

            // A new file that isn't an email: the notice is back — for that one only.
            try folder.write("Second body only.eml", try Kit.fixture("html-only"))
            await env.sync()
            info = try await Self.info(env)
            #expect(info.notEmailFiles == 1 && info.ignoredNotEmailFiles == 1)
            #expect(info.notEmailHint == MailSyncText.notEmailFiles(1, .en))
            let fresh = await env.engine.mail.notEmailFiles(accountID: "pa", ignored: false)
            #expect(fresh.files.map(\.name) == ["Second body only.eml"])
            let old = await env.engine.mail.notEmailFiles(accountID: "pa", ignored: true)
            #expect(old.files.map(\.name) == ["Body only.eml"])
            #expect(await env.engine.mail.notEmailFiles(accountID: "pa").files.count == 2)

            // Ignored again: both quiet. Stop Ignoring: both told about again.
            await env.engine.mail.ignoreNotEmailFiles(accountID: "pa")
            info = try await Self.info(env)
            #expect(info.notEmailFiles == 0 && info.ignoredNotEmailFiles == 2)
            await env.engine.mail.unignoreNotEmailFiles(accountID: "pa")
            info = try await Self.info(env)
            #expect(info.notEmailFiles == 2 && info.ignoredNotEmailFiles == 0)
            #expect(try await env.db.mailCursor(accountID: MailSyncActor.ignoredNotEmailKey("pa")) == nil)

            // Files gone (Trash, Finder): out of the counts at once, and the ledger forgets them next pass.
            await env.engine.mail.ignoreNotEmailFiles(accountID: "pa")
            try folder.remove("Body only.eml")
            try folder.remove("Second body only.eml")
            await env.engine.mail.recountNotEmailFiles(accountID: "pa")
            info = try await Self.info(env)
            #expect(info.notEmailFiles == 0 && info.ignoredNotEmailFiles == 0)
            await env.sync()
            #expect(try await Self.info(env).ignoredNotEmailFiles == 0)
            // One captured email, never a card from the other files.
            #expect(try await env.messages().count == 1)
        } catch {
            await env.close(removeRoot: false)
            throw error
        }
        await env.close(removeRoot: false)
    }

    @Test func anotherFolderStartsOverAndOnlyFolderAccountsCanIgnore() async throws {
        let folder = try Folder()
        let other = try Folder()
        try folder.write("bad.eml", try Kit.fixture("html-only"))
        try other.write("bad.eml", try Kit.fixture("html-only"))   // same name, another folder
        var account = Self.account(folder)
        let imap = RFB.fakeIMAPAccount("imap")
        let source = RFB.LedgerSource(accountID: "imap")
        try await RFB.run(mail: RFB.settings(accounts: [account, imap]),
                          sources: { a in a.id == "imap" ? source : Self.sources(a) }) { env in
            await env.sync()
            await env.engine.mail.ignoreNotEmailFiles(accountID: "pa")
            await env.engine.mail.ignoreNotEmailFiles(accountID: "imap")            // not a folder: nothing
            await env.engine.mail.ignoreNotEmailFiles(accountID: "nobody")
            #expect(try await env.db.mailCursor(accountID: MailSyncActor.ignoredNotEmailKey("imap")) == nil)
            #expect(await env.engine.mail.notEmailFiles(accountID: "imap") == MailNotEmailFiles())
            #expect(try await Self.info(env).ignoredNotEmailFiles == 1)

            // The account now watches another folder: its ignored names don't carry over.
            account.folderPath = other.url.path
            env.mail.value.accounts = [account, imap]
            await env.engine.mail.settingsDidChange()
            await env.sync()
            let info = try await Self.info(env)
            #expect(info.notEmailFiles == 1 && info.ignoredNotEmailFiles == 0)
        }
    }

    // MARK: Click-time check and the Trash guard

    @Test func onlyTheLedgersUnchangedNonEmailFilesInsideTheFolderAreOffered() async throws {
        let folder = try Folder()
        try folder.write("a body only.eml", try Kit.fixture("html-only"))
        try folder.write("b body only.eml", try Kit.fixture("html-only"))
        try folder.write("real.eml", try Kit.fixture("outlook-export"))
        let account = Self.account(folder)
        try await RFB.run(mail: RFB.settings(accounts: [account]), sources: Self.sources) { env in
            await env.sync()
            let first = await env.engine.mail.notEmailFiles(accountID: "pa")
            #expect(first.folder?.standardizedFileURL == folder.url.standardizedFileURL)
            #expect(first.files.map(\.name).sorted() == ["a body only.eml", "b body only.eml"])
            #expect(first.files.allSatisfy { $0.sha256.count == 64 && $0.key == FolderLedger.key(forFileName: $0.name) })

            // "b" changes after the confirmation was shown; "a" stays: only "a" may go.
            try folder.write("b body only.eml", Data("<html><body>edited</body></html>".utf8), age: 7200)
            let again = await env.engine.mail.notEmailFiles(accountID: "pa")
            #expect(again.files.map(\.name) == ["a body only.eml"])                 // size / mtime no longer the ledger's
            #expect(again.unchanged(since: first).map(\.name) == ["a body only.eml"])

            // Same name, size and mtime but other bytes (or it became an email): not offered.
            let a = folder.url.appendingPathComponent("a body only.eml")
            let attrs = try FileManager.default.attributesOfItem(atPath: a.path)
            var bytes = try Data(contentsOf: a)
            bytes[bytes.startIndex] = UInt8(ascii: "X")
            try bytes.write(to: a)
            try FileManager.default.setAttributes([.modificationDate: attrs[.modificationDate]!], ofItemAtPath: a.path)
            let third = await env.engine.mail.notEmailFiles(accountID: "pa")
            #expect(third.unchanged(since: first).isEmpty)
            #expect(again.unchanged(since: MailNotEmailFiles(folder: URL(fileURLWithPath: "/tmp"), files: first.files)).isEmpty)
        }
    }

    @Test func theTrashGuardStaysInsideTheWatchedFolder() throws {
        let folder = try Folder()
        let file = try folder.write("Body only.eml", Data("<html></html>".utf8))
        let sub = folder.url.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let nested = sub.appendingPathComponent("nested.eml")
        try Data("<html></html>".utf8).write(to: nested)
        let outside = try Folder()
        let away = try outside.write("away.eml", Data("<html></html>".utf8))
        let link = folder.url.appendingPathComponent("link.eml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: away)
        let notMail = try folder.write("notes.txt", Data("x".utf8))

        #expect(FolderMailSource.mayTrash(file, folder: folder.url))
        #expect(!FolderMailSource.mayTrash(nested, folder: folder.url))                         // a subfolder's file
        #expect(!FolderMailSource.mayTrash(away, folder: folder.url))                           // outside
        #expect(!FolderMailSource.mayTrash(link, folder: folder.url))                           // a link to outside
        #expect(!FolderMailSource.mayTrash(notMail, folder: folder.url))                        // not a mail file name
        #expect(!FolderMailSource.mayTrash(sub, folder: folder.url))                            // a folder
        #expect(!FolderMailSource.mayTrash(folder.url.appendingPathComponent("sub/../../away.eml"), folder: folder.url))
        #expect(!FolderMailSource.mayTrash(file, folder: URL(fileURLWithPath: "/")))           // never "/"
        #expect(!FolderMailSource.mayTrash(URL(string: "https://example.org/x.eml")!, folder: folder.url))
        // The folder named through a symlink (/var → /private/var) is the same folder.
        let resolved = folder.url.resolvingSymlinksInPath()
        #expect(FolderMailSource.mayTrash(file, folder: resolved))
        #expect(FolderMailSource.mayTrash(resolved.appendingPathComponent("Body only.eml"), folder: folder.url))
    }

    // MARK: Move to Trash (a fake recycler — nothing is ever moved)

    /// Records what Move to Trash would hand to `NSWorkspace.recycle`; moves nothing.
    private actor FakeRecycler {
        private(set) var calls: [[String]] = []
        private var fails = false
        func setFails(_ on: Bool) { fails = on }
        func recycle(_ urls: [URL]) throws -> Int {
            calls.append(urls.map { $0.resolvingSymlinksInPath().path })
            if fails { throw CocoaError(.fileWriteNoPermission) }
            return urls.count
        }
    }

    @Test func moveToTrashHandsTheRecyclerOnlyConfirmedUnchangedFilesInsideTheFolder() async throws {
        let folder = try Folder()
        let bad = try folder.write("Body only.eml", try Kit.fixture("html-only"))
        let real = try folder.write("real.eml", try Kit.fixture("outlook-export"))
        let sub = folder.url.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let nested = sub.appendingPathComponent("nested.eml")
        try Kit.fixture("html-only").write(to: nested)
        let outside = try Folder()
        let away = try outside.write("away.eml", try Kit.fixture("html-only"))
        let badPath = bad.resolvingSymlinksInPath().path
        try await RFB.run(mail: RFB.settings(accounts: [Self.account(folder)]), sources: Self.sources) { env in
            await env.sync()
            let fake = FakeRecycler()
            let recycle: @Sendable ([URL]) async throws -> Int = { try await fake.recycle($0) }
            let confirmed = await env.engine.mail.notEmailFiles(accountID: "pa")
            #expect(confirmed.files.map { $0.url.resolvingSymlinksInPath().path } == [badPath])   // not real.eml, not sub/, not outside

            // The click: found again, unchanged → exactly that one file.
            var now = await env.engine.mail.notEmailFiles(accountID: "pa")
            #expect(await MailNotEmailTrash.perform(confirmed: confirmed, now: now, recycle: recycle) == .moved(1))
            #expect(await fake.calls == [[badPath]])
            // A recycler that fails is reported as such.
            await fake.setFails(true)
            #expect(await MailNotEmailTrash.perform(confirmed: confirmed, now: now, recycle: recycle) == .failed)
            await fake.setFails(false)
            let calls = await fake.calls.count

            // A forged list naming a subfolder's file and one outside the folder: never offered.
            let forged = MailNotEmailFiles(folder: folder.url, files: [nested, away].map { u in
                MailNotEmailFile(url: u, key: FolderLedger.key(forFileName: u.lastPathComponent), size: 1, mtimeMs: 1,
                                 sha256: String(repeating: "0", count: 64))
            })
            #expect(await MailNotEmailTrash.perform(confirmed: forged, now: forged, recycle: recycle) == .nothing)
            // The confirmation was for another folder.
            let elsewhere = MailNotEmailFiles(folder: outside.url, files: confirmed.files)
            #expect(await MailNotEmailTrash.perform(confirmed: elsewhere, now: now, recycle: recycle) == .nothing)
            #expect(await MailNotEmailTrash.perform(confirmed: confirmed, now: MailNotEmailFiles(), recycle: recycle) == .nothing)
            // Edited after the confirmation was shown: not the file that was confirmed.
            try folder.write("Body only.eml", Data("<html><body>edited</body></html>".utf8), age: 7200)
            now = await env.engine.mail.notEmailFiles(accountID: "pa")
            #expect(await MailNotEmailTrash.perform(confirmed: confirmed, now: now, recycle: recycle) == .nothing)
            #expect(await fake.calls.count == calls)                                   // never called with an empty list
        }
        // The fake moved nothing: every file is still where it was.
        for u in [bad, real, nested, away] { #expect(FileManager.default.fileExists(atPath: u.path), "\(u.lastPathComponent)") }
    }

    // MARK: Skipped emails

    @Test func theSkippedNoticeHidesUntilMoreAreSkippedAndTheMarkFollowsTheCountDown() async throws {
        let source = RFB.LedgerSource(accountID: "k")
        let account = RFB.fakeIMAPAccount("k")
        let env = try await RFB.make(mail: RFB.settings(accounts: [account], syncMinutes: 60),
                                     sources: { $0.id == "k" ? source : nil }, start: false)
        do {
            // The count a pass stored (retry list full), read at the next pass — the timer's first
            // pass (due, not a re-list), so it stays.
            try await env.db.setMailCursor(accountID: MailSyncActor.skippedKey("k"), MailCursor("3"))
            _ = await env.engine.start()
            #expect(await RFB.eventually { await env.engine.mail.accountSyncInfo(lang: .en).first?.lastSuccessAt != nil })
            var info = try await Self.info(env)
            #expect(info.skipped == 3 && MailNoticePolicy.skippedNoticeDue(info, active: true))

            await env.engine.mail.dismissSkippedNotice(accountID: "k")
            info = try await Self.info(env)
            #expect(info.skippedDismissed == 3 && !MailNoticePolicy.skippedNoticeDue(info, active: true))
            #expect(MailNoticePolicy.notices([info]).isEmpty)
            #expect(try await env.db.mailCursor(accountID: MailSyncActor.skippedDismissedKey("k"))?.value == "3")

            // Sync Now lists the look-back again and gets through: nothing skipped, the mark follows to 0,
            // so the next skipped emails (whatever their number) warn again.
            await env.sync()
            info = try await Self.info(env)
            #expect(info.skipped == 0 && info.skippedDismissed == 0)
            #expect(try await env.db.mailCursor(accountID: MailSyncActor.skippedDismissedKey("k")) == nil)
        } catch {
            await env.close()
            throw error
        }
        await env.close()
    }
}
