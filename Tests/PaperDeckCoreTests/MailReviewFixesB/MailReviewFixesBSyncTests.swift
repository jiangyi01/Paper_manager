import Foundation
import Testing
@testable import PaperDeckCore

/// Review fixes of the mail sync pipeline (integrity-1/2/3/9, runtime-3/6, safety-5, K4 call
/// site, the folder status count): fake transports or the real folder source on temp folders.
@Suite(.serialized) struct MailReviewFixesBSyncTests {
    typealias K = MailSyncKit

    // MARK: integrity-1 — a sender added later still gets its look-back mail

    @Test func aSenderAddedAfterTheFirstSyncGetsItsLookbackMailFromTheWatchedFolder() async throws {
        let root = try RFB.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("PaperDeck Mail", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Re reading for Thursday.eml")
        try K.data("advisor-request-pdf").write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: file.path)
        let account = MailAccount(id: "pa", kind: .folder, displayName: "PA", lookbackDays: 14, folderPath: folder.path)
        // The account is turned on before any sender is on the list (MailAddAccountSheet «Turn on & close»).
        let env = try await RFB.make(root: root.appendingPathComponent("lib", isDirectory: true),
                                     mail: RFB.settings(accounts: [account], senders: [K.biorxivRule]))
        do {
            await env.sync()
            #expect(try await env.messages().isEmpty)
            #expect(try await env.db.mailCursor(accountID: "pa") != nil)        // the file was listed (headers only)

            env.mail.update { $0.senders.append(K.advisorRule) }
            await env.engine.mail.settingsDidChange()
            await env.sync()
            let all = try await env.messages()
            #expect(all.map(\.internetMessageID) == ["<caf3xyz+abc123@mail.gmail.com>"])
            // The stored sender fingerprint is patterns only.
            let fp = try #require(try await env.db.mailCursor(accountID: MailSyncActor.sendersKey("pa"))).value
            #expect(fp.contains("a:jsmith@wustl.edu") && fp.contains("d:alerts.highwire.org"))
            #expect(!fp.contains("Thursday"))
        } catch {
            await env.close(removeRoot: false)
            throw error
        }
        await env.close(removeRoot: false)
    }

    @Test func onlyAGrowingSenderListReListsTheLookback() async throws {
        let src = RFB.LedgerSource(accountID: "acct-f")
        try await RFB.run(mail: RFB.settings(accounts: [RFB.fakeAccount()], senders: [K.biorxivRule]),
                          sources: { $0.id == "acct-f" ? src : nil }) { env in
            await src.add("adv.eml", try K.data("advisor-request-pdf"))
            await src.add("alert.eml", try K.data("biorxiv-alert"))
            await env.sync()
            #expect(await src.cursorsSeen == [nil])
            #expect(try await env.messages().count == 1)

            // Added → re-listed from the look-back; the alert is not fetched twice (dedupe).
            env.mail.update { $0.senders.append(K.advisorRule) }
            await env.sync()
            #expect(await src.cursorsSeen.last == .some(nil))
            #expect(try await env.messages().count == 2)
            #expect(await src.fetched == ["alert.eml", "adv.eml"])

            // Removed / narrowed / unchanged → the stored cursor is used.
            env.mail.update { $0.senders.removeAll { $0.id == K.biorxivRule.id } }
            await env.sync()
            #expect(await src.cursorsSeen.last != .some(nil))
            // A broader rule covering a listed address does not re-list either…
            env.mail.update { $0.senders = [SenderRule(id: "wustl", pattern: "@wustl.edu", kind: .person)] }
            await env.sync()
            #expect(await src.cursorsSeen.last == .some(nil))          // …the domain is broader: re-listed
            let listed = await src.cursorsSeen.count
            env.mail.update { $0.senders.append(K.advisorRule) }      // address under the listed domain
            await env.sync()
            #expect(await src.cursorsSeen.count == listed + 1)
            #expect(await src.cursorsSeen.last != .some(nil))
        }
    }

    @Test func withoutALookbackASenderAddedLaterOnlyAffectsNewMail() async throws {
        let src = RFB.LedgerSource(accountID: "acct-f")
        try await RFB.run(mail: RFB.settings(accounts: [RFB.fakeAccount(lookback: 0)], senders: [K.biorxivRule]),
                          sources: { $0.id == "acct-f" ? src : nil }) { env in
            await src.add("adv.eml", try K.data("advisor-request-pdf"))
            await env.sync()
            env.mail.update { $0.senders.append(K.advisorRule) }
            await env.sync()
            #expect(await src.cursorsSeen.last != .some(nil))       // nothing earlier to re-list
            #expect(try await env.messages().isEmpty)
        }
    }

    // MARK: integrity-2 — captured but not post-processed before a quit

    /// Metadata transport that never answers (until cancelled).
    final class HangingFetcher: HTTPFetching, @unchecked Sendable {
        func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResult {
            try await Task.sleep(for: .seconds(60))
            return HTTPResult(status: 404, body: Data())
        }
    }

    @Test func messagesCapturedButNotPostProcessedAreFinishedAtTheNextStartWithinTheDailyCap() async throws {
        let root = try RFB.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mail = RFB.settings(accounts: [RFB.fakeAccount()], dailyMax: 1)
        let first = RFB.LedgerSource(accountID: "acct-f")
        for n in 1...3 {
            await first.add("a\(n).eml", try K.variant("biorxiv-alert", messageID: "<pp-\(n)@alerts.highwire.org>"))
        }
        let mock1 = MockAgentProvider()
        let env1 = try await RFB.make(root: root, mode: .mock, mail: mail, mock: mock1, fetcher: HangingFetcher(),
                                      metadata: true, sources: { $0.id == "acct-f" ? first : nil })
        await env1.engine.mail.syncNow()                      // captured; post-processing hangs on metadata
        let pks = try await env1.messages().map(\.pk)
        #expect(pks.count == 3)
        let marker = try await env1.db.mailCursor(accountID: MailSyncActor.pendingPostKey)?.value
        #expect(Set(MailSyncActor.decodePKs(marker)) == Set(pks))
        await env1.close(removeRoot: false)                    // quit before post-processing finished
        #expect(await mock1.calls == 0)

        let mock2 = MockAgentProvider()
        let env2 = try await RFB.make(root: root, mode: .mock, mail: mail, mock: mock2,
                                      sources: { $0.id == "acct-f" ? RFB.LedgerSource(accountID: "acct-f") : nil })
        #expect(await RFB.eventually {
            let states = try await env2.messages().map(\.triageState)
            return states.filter { $0 == .done }.count == 1 && states.filter { $0 == .held }.count == 2
        })
        #expect(await mock2.calls == 1)                        // the daily cap holds the other two
        #expect(await env2.engine.mailTriage.usage().used == 1)
        #expect(await RFB.eventually { (try await env2.db.mailCursor(accountID: MailSyncActor.pendingPostKey)) == nil })
        await env2.close(removeRoot: false)
    }

    // MARK: integrity-3 — a missing watched folder is retried, not parked

    @Test func aWatchedFolderThatAppearsLaterIsPickedUpWithoutTouchingSettings() async throws {
        let root = try RFB.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("PaperDeck Mail", isDirectory: true)
        let account = MailAccount(id: "pa", kind: .folder, displayName: "PA", lookbackDays: 14, folderPath: folder.path)
        let env = try await RFB.make(root: root.appendingPathComponent("lib", isDirectory: true),
                                     mail: RFB.settings(accounts: [account], syncMinutes: 15))
        do {
            #expect(await RFB.eventually { (await env.engine.mail.accountSyncInfo().first?.consecutiveFailures) == 1 })
            var info = try #require(await env.engine.mail.accountSyncInfo().first)
            guard case .unavailable = info.status else { Issue.record("status \(String(describing: info.status))"); return }
            #expect(!info.waitingForSettings)
            // Repeated failures back off, but never beyond the sync cadence for a folder.
            for _ in 0..<6 { await env.sync() }
            info = try #require(await env.engine.mail.accountSyncInfo().first)
            let wait = try #require(info.nextRetryAt).timeIntervalSince(env.clock.value)
            #expect(wait <= 15 * 60 + 1 && wait > 0)

            // OneDrive mounts / the flow creates the folder: the next due pass syncs by itself.
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("advisor.eml")
            try K.data("advisor-request-pdf").write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: file.path)
            env.advance(wait + 1)
            await env.engine.mail.appDidBecomeActive()
            #expect(await RFB.eventually { (try await env.messages().count) == 1 })
            #expect(await RFB.eventually {
                if case .ready? = await env.engine.mail.accountSyncInfo().first?.status { return true }
                return false
            })
        } catch {
            await env.close(removeRoot: false)
            throw error
        }
        await env.close(removeRoot: false)
    }

    // MARK: integrity-9 — an allowlisted message that keeps failing is not dropped

    /// One non-forced pass of the loop (`syncMinutes` > 0): advance the clock past the cadence and nudge.
    private static func loopPass(_ env: RFB.Env, _ src: RFB.LedgerSource, advance: TimeInterval) async -> Bool {
        let before = await src.listCalls
        env.advance(advance)
        await env.engine.mail.appDidBecomeActive()
        return await RFB.eventually {
            guard await src.listCalls > before else { return false }
            return await env.engine.mail.accountSyncInfo().first?.isSyncing == false
        }
    }

    @Test func aMessageThatKeepsFailingIsRetriedForDaysAndSurfacedNotDropped() async throws {
        let src = RFB.LedgerSource(accountID: "acct-f")
        let mail = RFB.settings(accounts: [RFB.fakeAccount()], syncMinutes: 15)
        let env = try await RFB.make(mail: mail, sources: { $0.id == "acct-f" ? src : nil }, start: false)
        do {
            await env.engine.mail.configure(MailSyncActor.Tuning(maxFetchAttempts: 3))
            await src.add("bad.eml", RFB.eml(from: "jsmith@wustl.edu", messageID: "<bad-1@wustl.edu>",
                                             subject: "SECRET-SUBJECT-rf9"))
            await src.add("ok.eml", try K.data("biorxiv-alert"))
            await src.failFetch("bad.eml", times: 1000)
            await env.engine.start()
            #expect(await RFB.eventually { await src.fetched.count == 1 })      // launch pass: attempt 1
            await env.sync()                                                    // attempt 2
            #expect(try await env.messages().isEmpty)                           // the page waits for it
            await env.sync()                                                    // attempt 3: deferred
            #expect(try await env.messages().map(\.sourceRef) == ["ok.eml"])    // …and the cursor moved on
            var info = try #require(await env.engine.mail.accountSyncInfo().first)
            #expect(info.consecutiveFailures == 0)
            #expect(info.undownloadable == 0)
            guard case .ready = info.status else { Issue.record("status \(String(describing: info.status))"); return }
            let record = try #require(try await env.db.mailCursor(accountID: MailSyncActor.retryKey("acct-f"))).value
            #expect(!record.contains("bad") && !record.contains("SECRET"))     // hashed ref only

            // Not due yet: listed again but not fetched.
            let fetches = await src.fetched.count
            #expect(await Self.loopPass(env, src, advance: 16 * 60))
            #expect(await src.fetched.count == fetches)
            // Its long backoff elapsed: fetched again.
            #expect(await Self.loopPass(env, src, advance: 3600))
            #expect(await src.fetched.count == fetches + 1)
            // Still failing a day later: still retried, and the account says so.
            #expect(await Self.loopPass(env, src, advance: 25 * 3600))
            #expect(await src.fetched.count == fetches + 2)
            info = try #require(await env.engine.mail.accountSyncInfo().first)
            #expect(info.undownloadable == 1)
            guard case .unavailable(let text) = info.status else { Issue.record("status \(String(describing: info.status))"); return }
            #expect(text.contains("couldn't be downloaded for over a day") && text.contains("Sync Now"))
            #expect(!text.contains("SECRET"))

            // 立即同步 retries it at once (whatever its backoff); it arrives.
            await src.failFetch("bad.eml", times: 0)
            await env.sync()
            #expect(Set(try await env.messages().compactMap(\.sourceRef)) == ["ok.eml", "bad.eml"])
            info = try #require(await env.engine.mail.accountSyncInfo().first)
            #expect(info.undownloadable == 0)
            guard case .ready = info.status else { Issue.record("status \(String(describing: info.status))"); return }
            #expect(try await env.db.mailCursor(accountID: MailSyncActor.retryKey("acct-f")) == nil)
        } catch {
            await env.close()
            throw error
        }
        await env.close()
    }

    @Test func aDeferredMessageInTheRealFolderIsListedAgain() async throws {
        let dir = try RFB.tempRoot("pd-rfb-folder")
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.eml", "b.eml"] {
            let url = dir.appendingPathComponent(name)
            try RFB.eml(from: "jsmith@wustl.edu", messageID: "<\(name)@wustl.edu>").write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: url.path)
        }
        let source = FolderMailSource(account: MailAccount(id: "f", kind: .folder, displayName: "F", lookbackDays: 14,
                                                           folderPath: dir.path))
        let p1 = try await source.listHeaders(since: nil, limit: 10)
        #expect(Set(p1.headers.map(\.ref)) == ["a.eml", "b.eml"])
        let next = try #require(p1.nextCursor)
        #expect(try await source.listHeaders(since: next, limit: 10).headers.isEmpty)
        let kept = try #require(await source.deferring(["a.eml"], in: next))
        #expect(!kept.value.contains("a.eml"))                                   // hashed names only
        #expect(try await source.listHeaders(since: kept, limit: 10).headers.map(\.ref) == ["a.eml"])
    }

    // MARK: runtime-3 / K1 — Settings edits never retry a rejected password

    @Test func unrelatedSettingsEditsDoNotRetryARejectedPassword() async throws {
        let src = RFB.LedgerSource(accountID: "acct-f")
        try await RFB.run(mail: RFB.settings(accounts: [RFB.fakeIMAPAccount()]), sources: { $0.id == "acct-f" ? src : nil }) { env in
            await src.setStatus(.authFailed("rejected"))
            await env.sync()
            #expect(await src.statusCalls == 1)
            for n in 0..<3 {
                env.mail.update { $0.criteria.researchInterests = "cortex \(n)" }   // typing in Settings ▸ Mail
                await env.engine.mail.settingsDidChange()
            }
            try await Task.sleep(for: .milliseconds(200))
            #expect(await src.statusCalls == 1)                   // no new sign-in
            var info = try #require(await env.engine.mail.accountSyncInfo().first)
            #expect(info.waitingForSettings)
            #expect(info.consecutiveFailures == 1)

            // Test & Save (a new app password) → one new attempt.
            await src.setStatus(.ready(detail: "Signed in"))
            await env.engine.mail.settingsDidChange(unpark: true)
            #expect(await RFB.eventually { await src.statusCalls == 2 })
            #expect(await RFB.eventually { await env.engine.mail.accountSyncInfo().first?.waitingForSettings == false })

            // Rejected again → parked again; 立即同步 un-parks.
            await src.setStatus(.authFailed("rejected"))
            await env.sync()
            info = try #require(await env.engine.mail.accountSyncInfo().first)
            #expect(info.waitingForSettings)
            await src.setStatus(.ready(detail: "Signed in"))
            await env.sync()
            info = try #require(await env.engine.mail.accountSyncInfo().first)
            #expect(!info.waitingForSettings)
            #expect(await src.statusCalls == 4)
        }
    }

    @Test func anEditedAccountGetsAFreshAttemptWithoutUnpark() async throws {
        let src = RFB.LedgerSource(accountID: "acct-f")
        try await RFB.run(mail: RFB.settings(accounts: [RFB.fakeAccount()]), sources: { $0.id == "acct-f" ? src : nil }) { env in
            await src.setStatus(.authFailed("rejected"))
            await env.sync()
            #expect(await env.engine.mail.accountSyncInfo().first?.waitingForSettings == true)
            env.mail.update { $0.accounts[0].displayName = "Renamed" }
            await env.engine.mail.settingsDidChange()
            #expect(await env.engine.mail.accountSyncInfo().first?.waitingForSettings == false)
        }
    }

    // MARK: runtime-6 — 清除所有邮件数据 during a sync

    @Test func clearAllDuringASyncStartsOverAndKeepsLaterAttachments() async throws {
        let src = RFB.LedgerSource(accountID: "acct-f")
        try await RFB.run(mail: RFB.settings(accounts: [RFB.fakeAccount()]), sources: { $0.id == "acct-f" ? src : nil }) { env in
            await env.engine.mail.configure(MailSyncActor.Tuning(pageLimit: 1))
            await src.setFetchDelay(.milliseconds(120))
            for n in 1...6 {
                let pdf = K.realPDF(title: "Clear test paper \(n)")
                await src.add("m\(n).eml", MailSyncPipelineTests.emlWithAttachment(pdf, from: "jsmith@wustl.edu",
                                                                                    messageID: "<clear-\(n)@wustl.edu>"))
            }
            let running = Task { await env.engine.mail.syncNow() }
            #expect(await RFB.eventually { (try await env.messages().count) >= 2 })
            try await env.engine.mail.deleteAllMailData()
            #expect(try await env.messages().isEmpty)
            #expect(try await env.db.mailCursor(accountID: "acct-f") == nil)
            await running.value
            #expect(try await env.db.mailCursor(accountID: "acct-f") == nil)   // the stopped sync wrote nothing back
            #expect(try await env.messages().isEmpty)

            // Every account starts over with its look-back; each card keeps its attachment.
            await src.setFetchDelay(.zero)
            await env.sync()
            let all = try await env.messages()
            #expect(all.count == 6)
            for m in all {
                let items = try await env.db.mailItems(messagePK: m.pk)
                let path = try #require(items.first { $0.origin == .attachment }?.pdfPath)
                #expect(FileManager.default.fileExists(atPath: env.engine.paths.mailFiles.appendingPathComponent(path).path))
            }
        }
    }

    // MARK: K4 — bulk / authentication facts reach the triage decision

    @Test func alertMailIsAutoTriagedOnlyWhenBulkAndAuthenticated() async throws {
        let src = RFB.LedgerSource(accountID: "acct-f")
        try await RFB.run(mail: RFB.settings(accounts: [RFB.fakeAccount()]), sources: { $0.id == "acct-f" ? src : nil }) { env in
            let bulk = String(decoding: try K.variant("biorxiv-alert", messageID: "<k4-bulk@alerts.highwire.org>"), as: UTF8.self)
            let personal = bulk.replacingOccurrences(of: "<k4-bulk@", with: "<k4-plain@")
                .replacingOccurrences(of: #"List-Unsubscribe: <mailto:unsubscribe@alerts.highwire.org?subject=unsubscribe>"# + "\r\n",
                                      with: "")
            let spoofed = bulk.replacingOccurrences(of: "<k4-bulk@", with: "<k4-spoof@")
                .replacingOccurrences(of: "MIME-Version: 1.0\r\n",
                                      with: "Authentication-Results: mx.google.com; dkim=fail; spf=fail; dmarc=fail\r\nMIME-Version: 1.0\r\n")
            #expect(personal != bulk && spoofed != bulk)
            await src.add("bulk.eml", Data(bulk.utf8))
            await src.add("plain.eml", Data(personal.utf8))
            await src.add("spoof.eml", Data(spoofed.utf8))
            await env.sync()
            let byID = Dictionary(uniqueKeysWithValues: try await env.messages().map { ($0.internetMessageID, $0) })
            #expect(byID["<k4-bulk@alerts.highwire.org>"]?.triageState != .awaitingConsent)
            #expect(byID["<k4-plain@alerts.highwire.org>"]?.triageState == .awaitingConsent)
            #expect(byID["<k4-spoof@alerts.highwire.org>"]?.triageState == .awaitingConsent)
            #expect(byID["<k4-spoof@alerts.highwire.org>"]?.authState == .fail)
        }
    }

    // MARK: Folder status counts real emails only

    @Test func theFolderStatusCountsEmailsNotOtherFiles() async throws {
        let root = try RFB.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("PaperDeck Mail", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mailFile = folder.appendingPathComponent("alert.eml")
        let htmlFile = folder.appendingPathComponent("Body only.eml")
        try K.data("biorxiv-alert").write(to: mailFile)
        try Data("<html><head><meta charset=\"utf-8\"></head><body>Hi</body></html>".utf8).write(to: htmlFile)
        for f in [mailFile, htmlFile] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: f.path)
        }
        let account = MailAccount(id: "pa", kind: .folder, displayName: "PA", lookbackDays: 14, folderPath: folder.path)
        let env = try await RFB.make(root: root.appendingPathComponent("lib", isDirectory: true),
                                     mail: RFB.settings(accounts: [account]))
        do {
            await env.sync()
            let info = try #require(await env.engine.mail.accountSyncInfo().first)
            #expect(info.status == .ready(detail: "Watching “PaperDeck Mail” · 1 email"))
            #expect(info.notEmailFiles == 1)
            // A new source (relaunch) primed with the stored ledger counts the same before listing.
            let fresh = FolderMailSource(account: account)
            await fresh.prime(cursor: try await env.db.mailCursor(accountID: "pa"))
            #expect(await fresh.status() == .ready(detail: "Watching “PaperDeck Mail” · 1 email"))
            #expect(await FolderMailSource(account: account).status() == .ready(detail: "Watching “PaperDeck Mail” · 2 emails"))
        } catch {
            await env.close(removeRoot: false)
            throw error
        }
        await env.close(removeRoot: false)
    }

    // MARK: safety-5 — an isolated run never deletes the user's files

    @Test func isolatedAccountsNeverDeleteProcessedFiles() async throws {
        let root = try RFB.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("PaperDeck Mail", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("alert.eml")
        try K.data("biorxiv-alert").write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: file.path)
        let real = MailAccount(id: "pa", kind: .folder, displayName: "PA", lookbackDays: 14, folderPath: folder.path,
                               deleteProcessedFiles: true)
        let isolated = MailSourceFactory.isolated([real])
        #expect(isolated.map(\.deleteProcessedFiles) == [false])
        #expect(isolated.first?.folderPath == real.folderPath)
        let env = try await RFB.make(root: root.appendingPathComponent("lib", isDirectory: true),
                                     mail: RFB.settings(accounts: isolated))
        do {
            await env.sync()
            #expect(try await env.messages().count == 1)
            #expect(FileManager.default.fileExists(atPath: file.path))
        } catch {
            await env.close(removeRoot: false)
            throw error
        }
        await env.close(removeRoot: false)
    }
}
