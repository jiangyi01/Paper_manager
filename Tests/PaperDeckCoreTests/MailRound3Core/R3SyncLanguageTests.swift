import Foundation
import Testing
@testable import PaperDeckCore

/// Round 3: r3-5 (a language switch never rebuilds a source or signs in again — statuses are
/// worded at display time), C-G (`accountSyncInfo(lang:)` words every status / detail / hint in
/// the language asked, IMAP "Signed in as …" and the pipeline's own texts included) and C-O
/// (`settingsDidChange(unpark:accountIDs:)` un-parks only the edited account). Local fake IMAP
/// server on 127.0.0.1 and scripted sources only.
@Suite(.serialized) struct R3SyncLanguageTests {
    typealias K = MailSyncKit

    private static let password = "abcd efgh ijkl mnop"

    private static func info(_ env: R3.Env, _ lang: UILang) async throws -> MailAccountSyncInfo {
        try #require(await env.engine.mail.accountSyncInfo(lang: lang).first)
    }

    @Test func aLanguageSwitchRewordsTheIMAPStatusWithoutASignInOrARebuild() async throws {
        let server = try FakeIMAPServer()
        defer { server.stop() }
        let store = InMemoryMailSecretStore()
        let account = MailAccount(id: "gmail-r3", kind: .imap, displayName: "Gmail", lookbackDays: 14, imapPreset: .gmail,
                                  host: "imap.gmail.com", port: 993, username: "me@gmail.com", mailbox: "INBOX")
        try await store.setSecret(Self.password, for: account.secretKey)
        let port = server.port
        try await R3.run(mail: RFB.settings(accounts: [account]), sources: { a in
            IMAPMailSource(account: a, secrets: store, connector: .plainForTesting(host: "127.0.0.1", port: port),
                           lang: .en, timeouts: IMAPClient.Timeouts(connect: .seconds(5), command: .seconds(5)))
        }) { env in
            await env.sync()
            #expect(try await Self.info(env, .en).status == .ready(detail: "Signed in as me@gmail.com · INBOX (0 messages)"))
            let logins = server.verbs.filter { $0 == "LOGIN" }.count
            let made = env.made.value
            #expect(logins >= 1)

            env.settings.update { $0.lang = .zh }
            await env.engine.mail.settingsDidChange()
            let snap = try await env.engine.mailSnapshot()
            let zh = MailSourceStatus.ready(detail: "已登录 me@gmail.com · INBOX（0 封邮件）")
            #expect(snap.accounts.first?.status == zh)
            #expect(try await Self.info(env, .zh).status == zh)
            #expect(try await Self.info(env, .en).status == .ready(detail: "Signed in as me@gmail.com · INBOX (0 messages)"))
            try await Task.sleep(for: .milliseconds(300))
            #expect(env.made.value == made)                                       // the source was not rebuilt
            #expect(server.verbs.filter { $0 == "LOGIN" }.count == logins)        // and nobody signed in again
        }
    }

    @Test func aLanguageSwitchDuringASyncNeitherRebuildsNorInterruptsIt() async throws {
        let src = R3.CapSource(accountID: "acct-f")
        try await R3.run(mail: RFB.settings(accounts: [RFB.fakeIMAPAccount()]), sources: { $0.id == "acct-f" ? src : nil }) { env in
            await src.add("a.eml", RFB.eml(from: "jsmith@wustl.edu", messageID: "<r3-lang-a@wustl.edu>"))
            await src.holdFetch()
            let sync = Task { await env.sync() }
            #expect(await RFB.eventually { await src.fetchHeld })
            let made = env.made.value
            env.settings.update { $0.lang = .zh }
            await env.engine.mail.settingsDidChange()
            _ = try await env.engine.mailSnapshot()
            #expect(env.made.value == made)
            await src.releaseFetch()
            await sync.value
            #expect(try await env.messages().count == 1)
            #expect(await src.statusCalls == 1)                                   // one sign-in for the pass
            #expect(try await Self.info(env, .zh).status == .ready(detail: "已连接（1 封）"))
            #expect(try await Self.info(env, .en).status == .ready(detail: "Connected (1 messages)"))
        }
    }

    /// The pipeline's own statuses (fetch failure) and suffixes (undownloadable) follow the
    /// language asked, without a new sync.
    @Test func pipelineStatusesFollowTheLanguageAskedFor() async throws {
        let src = R3.CapSource(accountID: "acct-f", retryCap: 10)
        try await R3.run(mail: RFB.settings(accounts: [RFB.fakeAccount()]), sources: { $0.id == "acct-f" ? src : nil },
                         start: false) { env in
            await env.engine.mail.configure(MailSyncActor.Tuning(maxFetchAttempts: 2, undownloadableAfter: 0))
            await src.add("bad.eml", RFB.eml(from: "jsmith@wustl.edu", messageID: "<r3-bad@wustl.edu>"))
            await src.failFetch("bad.eml", times: 1000)
            await env.engine.start()
            await env.sync()                                                      // attempt 1: the page waits
            guard case .unavailable(let en) = try await Self.info(env, .en).status,
                  case .unavailable(let zh) = try await Self.info(env, .zh).status else {
                Issue.record("expected unavailable"); return
            }
            #expect(en == MailSyncText.fetchFailed(.en) && zh == MailSyncText.fetchFailed(.zh))

            await env.sync()                                                      // attempt 2: deferred
            env.advance(3 * 3600)
            await env.sync()                                                      // retried (Sync Now), still failing
            let enInfo = try await Self.info(env, .en), zhInfo = try await Self.info(env, .zh)
            #expect(enInfo.undownloadable == 1)
            guard case .unavailable(let enText) = enInfo.status, case .unavailable(let zhText) = zhInfo.status else {
                Issue.record("expected the undownloadable suffix"); return
            }
            #expect(enText == "Connected (1 messages) · " + MailSyncText.undownloadable(1, .en))
            #expect(zhText == "已连接（1 封） · " + MailSyncText.undownloadable(1, .zh))
        }
    }

    @Test func transportStatusTextsAreWordedPerLanguage() {
        let account = RFB.fakeIMAPAccount()
        let auth = MailSyncActor.localizedStatus(for: IMAPError.authenticationFailed("[AUTHENTICATIONFAILED]"), account: account)
        guard case .authFailed(let en) = auth.render(.en), case .authFailed(let zh) = auth.render(.zh) else {
            Issue.record("expected authFailed"); return
        }
        #expect(en != zh && zh.unicodeScalars.contains { $0.value >= 0x4E00 })
        // A setup problem raised in English is worded again in Chinese (and back).
        let noPasswordEN = "No app password saved for me@example.org. Create one with your provider, then choose Test & Save."
        let setup = MailSyncActor.localizedStatus(for: IMAPError.notConfigured(noPasswordEN), account: account)
        #expect(setup.render(.en) == .needsSetup(noPasswordEN))
        guard case .needsSetup(let zhSetup) = setup.render(.zh) else { Issue.record("expected needsSetup"); return }
        #expect(zhSetup.contains("me@example.org") && zhSetup.contains("测试并保存"))
        let read = MailSyncActor.localizedStatus(for: FileOpsError.io("x"), account: account)
        #expect(read.render(.zh) == .unavailable(MailSyncText.readFailed("I/O error", .zh)))
        #expect(MailSyncActor.localizedStatus(for: CocoaError(.fileReadUnknown), account: account).render(.zh)
                == .unavailable(MailSyncText.syncFailed(.zh)))
        let folder = MailSyncActor.localizedStatus(for: FolderMailSourceError.folderMissing("~/OneDrive/PaperDeck Mail"),
                                              account: account)
        #expect(folder.render(.zh) == FolderMailSource.status(for: .folderMissing("~/OneDrive/PaperDeck Mail"), lang: .zh))
    }

    // MARK: C-O

    @Test func testAndSaveUnparksOnlyTheEditedAccount() async throws {
        let a = RFB.LedgerSource(accountID: "acct-a"), b = RFB.LedgerSource(accountID: "acct-b")
        let mail = RFB.settings(accounts: [RFB.fakeIMAPAccount("acct-a"), RFB.fakeIMAPAccount("acct-b")])
        try await R3.run(mail: mail, sources: { $0.id == "acct-a" ? a : $0.id == "acct-b" ? b : nil }) { env in
            await a.setStatus(.authFailed("rejected"))
            await b.setStatus(.authFailed("rejected"))
            await env.sync()
            let callsA = await a.statusCalls, callsB = await b.statusCalls
            #expect(callsA == 1 && callsB == 1)
            await a.setStatus(.ready(detail: "Signed in"))
            await b.setStatus(.ready(detail: "Signed in"))

            await env.engine.mail.settingsDidChange(unpark: true, accountIDs: ["acct-a"])
            #expect(await RFB.eventually { await a.statusCalls == 2 })
            try await Task.sleep(for: .milliseconds(200))
            #expect(await b.statusCalls == 1)                                     // B stays parked: no sign-in
            let infos = await env.engine.mail.accountSyncInfo()
            #expect(infos.first { $0.id == "acct-a" }?.waitingForSettings == false)
            #expect(infos.first { $0.id == "acct-b" }?.waitingForSettings == true)

            // nil = every account (立即同步's path).
            await env.engine.mail.settingsDidChange(unpark: true)
            #expect(await RFB.eventually { await b.statusCalls == 2 })
        }
    }
}
