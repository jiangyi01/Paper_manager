import Foundation
import Testing
@testable import PaperDeckCore

/// What the app side of round 3 relies on from Core (the app code itself is checked by
/// `PaperDeck --selftest app-rules`, which these tests can't reach):
/// - C-H: the inbox list snapshot carries no email text (the inspector loads it with
///   `Engine.mailCard(id:)`), and a body purged by retention still reads as purged in the list;
/// - C-G: `accountSyncInfo(lang:)` words the pipeline's statuses in the language asked for;
/// - C-O: `settingsDidChange(unpark:accountIDs:)` un-parks only the accounts named (nil: all);
/// - integrity-4: an app folder that can't be created fails `Engine.open` with a bare
///   `FileOpsError` (no path), which is why the app's launch classifier probes its own folders.
/// Fakes only: no mail server, no keychain, agent mode off.
@Suite struct MailRound3AppContractTests {
    /// A transport whose sign-in works and whose listing always fails (→ 「同步失败」).
    actor ListingFails: MailSource {
        nonisolated let accountID: String
        init(_ accountID: String) { self.accountID = accountID }
        struct Failure: Error {}
        func status() async -> MailSourceStatus { .ready(detail: "ok") }
        func listHeaders(since: MailCursor?, limit: Int) async throws -> MailHeaderPage { throw Failure() }
        func fetchMessage(_ header: MailHeader, maxBytes: Int) async throws -> MailContent { throw Failure() }
    }

    // MARK: C-H

    @Test func theListSnapshotCarriesNoTextButTheCardDoes() async throws {
        try await RFB.run(mail: RFB.settings(accounts: [])) { env in
            let url = env.root.appendingPathComponent("request.eml")
            try RFB.eml(from: "jsmith@wustl.edu", messageID: "<r3-app-body@wustl.edu>", subject: "Paper for Friday",
                        body: "Could you read this before Friday's journal club?").write(to: url)
            let id = try #require(await env.engine.mail.importEML([url]).first)
            await env.engine.mail.waitUntilIdle()

            let listed = try #require(try await env.engine.mailSnapshot().card(id: id))
            #expect((listed.message.bodyText ?? "").isEmpty)
            #expect(!listed.message.bodyPurged)
            let full = try #require(try await env.engine.mailCard(id: id))
            #expect(full.message.bodyText?.contains("journal club") == true)
            #expect(!full.message.bodyPurged)

            // Retention after the card was handled: purged in both copies (the inspector's purged note).
            try await env.engine.dismissMail(messageID: id)
            try await env.db.purgeMailBodies(handledBefore: env.clock.value.addingTimeInterval(86_400), now: env.clock.value)
            let purgedList = try #require(try await env.engine.mailSnapshot().card(id: id))
            #expect(purgedList.message.bodyPurged)
            let purgedFull = try #require(try await env.engine.mailCard(id: id))
            #expect(purgedFull.message.bodyPurged)
            #expect((purgedFull.message.bodyText ?? "").isEmpty)
        }
    }

    // MARK: C-G

    @Test func accountRowsAreWordedInTheLanguageAskedFor() async throws {
        let source = ListingFails("acct-g")
        try await RFB.run(mail: RFB.settings(accounts: [RFB.fakeIMAPAccount("acct-g")]), lang: .zh,
                          sources: { $0.id == "acct-g" ? source : nil }) { env in
            await env.sync()
            let zh = try #require(await env.engine.mail.accountSyncInfo(lang: .zh).first)
            #expect(zh.status == .unavailable(MailSyncText.syncFailed(.zh)))
            env.settings.value.lang = .en                       // Settings ▸ General ▸ Language → English
            let en = try #require(await env.engine.mail.accountSyncInfo(lang: .en).first)
            #expect(en.status == .unavailable(MailSyncText.syncFailed(.en)))
        }
    }

    // MARK: C-O

    @Test func anExplicitRetryUnparksOnlyTheNamedAccount() async throws {
        let a = RFB.LedgerSource(accountID: "acct-a"), b = RFB.LedgerSource(accountID: "acct-b")
        let accounts = [RFB.fakeIMAPAccount("acct-a"), RFB.fakeIMAPAccount("acct-b")]
        try await RFB.run(mail: RFB.settings(accounts: accounts),
                          sources: { $0.id == "acct-a" ? a : ($0.id == "acct-b" ? b : nil) }) { env in
            await a.setStatus(.authFailed("rejected"))
            await b.setStatus(.authFailed("rejected"))
            await env.sync()
            func parked(_ id: String) async -> Bool {
                await env.engine.mail.accountSyncInfo(lang: .en).first { $0.id == id }?.waitingForSettings == true
            }
            let aParked = await parked("acct-a"), bParked = await parked("acct-b")
            #expect(aParked && bParked)
            await a.setStatus(.ready(detail: "Signed in"))
            await b.setStatus(.ready(detail: "Signed in"))

            // Test & Save of account A: A signs in again, B stays parked (no new sign-in).
            await env.engine.mail.settingsDidChange(unpark: true, accountIDs: ["acct-a"])
            #expect(await RFB.eventually { await a.statusCalls == 2 })
            try await Task.sleep(for: .milliseconds(200))
            let bCalls = await b.statusCalls
            let bStill = await parked("acct-b"), aStill = await parked("acct-a")
            #expect(bCalls == 1)
            #expect(bStill)
            #expect(!aStill)

            // 立即同步's un-park (nil): every account.
            await env.engine.mail.settingsDidChange(unpark: true, accountIDs: nil)
            #expect(await RFB.eventually { await b.statusCalls == 2 })
            #expect(await RFB.eventually { await parked("acct-b") == false })
        }
    }

    // MARK: integrity-4

    @Test func anAppFolderThatCannotBeCreatedFailsWithABareFileOpsError() async throws {
        let root = try RFB.tempRoot("pd-r3-appdata")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths.rooted(at: root)
        try FileManager.default.createDirectory(at: paths.library, withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: paths.support)           // Application Support's folder is taken
        let es = EngineSettings(plan: PlanSettings(), lang: .en, agentMode: .off, autoReadNewPapers: false,
                                metadataLookup: false)
        let deps = Engine.Dependencies(loadSettings: { es }, fetcher: nil, claude: MockAgentProvider(behavior: .notLoggedIn),
                                       codex: MockAgentProvider(behavior: .notLoggedIn), mock: MockAgentProvider(),
                                       sidecarDelay: .milliseconds(10), cliFacts: .inMemory(),
                                       loadMailSettings: { MailSettings() }, mailSecrets: InMemoryMailSecretStore(), assistBackends: [MockAssistBackend()])
        var thrown: (any Error)?
        do {
            let engine = try await Engine.open(paths: paths, deps: deps)
            await engine.shutdown()
            await engine.db.close()
        } catch {
            thrown = error
        }
        let error = try #require(thrown)
        #expect(error is FileOpsError)                                    // like a library folder problem…
        #expect(!(error is SQLiteError) && !(error is DatabaseError))
        // …so only probing the app's own folders tells them apart: the library folder itself is fine.
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: paths.papers.path, isDirectory: &isDir) && isDir.boolValue)
        #expect((try? FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)) == nil)
    }
}
