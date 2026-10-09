import Foundation
import PaperDeckCore

/// Round-3 checks of `--selftest app-rules` (app side of the contracts the Core tests can't reach):
/// - body (C-H): the inspector shows an email's text only from `Engine.mailCard(id:)`, loads it
///   again on that email's changes, and tells "not loaded yet" from "purged by retention";
/// - rows (C-G): Settings ▸ Mail ▸ Accounts read in the UI language, never an older one;
/// - unpark (C-O): Test & Save / an account saved retries only that account, 「立即同步」 all;
/// - launch (integrity-4): Retry on the database alert, app folders that can't be created are a
///   database-type failure (no ~/Papers), library.path never written for those.
/// Engines run on scratch roots with fake mail sources (no network, no keychain, mock AI off).
extension SelfTestAppRules {
    static func runRound3(scratch: URL, _ c: Checker) async {
        await launchRetry(scratch: scratch, c)
        await bodyLoading(scratch: scratch, c)
        await accountRows(scratch: scratch, c)
        await targetedUnpark(scratch: scratch, c)
    }

    // MARK: Engines with fake mail sources

    /// The engine's language (switched mid-check).
    typealias Shared = SharedValue

    nonisolated struct FakeSourceError: Error {}
    nonisolated struct TransientError: Error {}

    /// What a follower loaded and delivered (main actor).
    final class Recorder {
        var loads = 0
        var delivered: [MailCard?] = []
        var last: MailMessage? { delivered.last??.message }
    }

    /// A transport that only answers its status (and, when asked, fails the listing).
    actor FakeSource: MailSource {
        nonisolated let accountID: String
        private var statusValue: MailSourceStatus
        private let failListing: Bool
        private(set) var statusCalls = 0

        init(_ accountID: String, status: MailSourceStatus, failListing: Bool = false) {
            self.accountID = accountID
            self.statusValue = status
            self.failListing = failListing
        }

        func setStatus(_ s: MailSourceStatus) { statusValue = s }

        func status() async -> MailSourceStatus {
            statusCalls += 1
            return statusValue
        }

        func listHeaders(since: MailCursor?, limit: Int) async throws -> MailHeaderPage {
            if failListing { throw FakeSourceError() }
            return MailHeaderPage(headers: [], nextCursor: since, hasMore: false)
        }

        func fetchMessage(_ header: MailHeader, maxBytes: Int) async throws -> MailContent { throw FakeSourceError() }
    }

    static func fakeAccount(_ id: String) -> MailAccount {
        MailAccount(id: id, kind: .imap, displayName: "Fake \(id)", lookbackDays: 14, imapPreset: .gmail,
                    host: "imap.invalid", port: 993, username: "\(id)@example.org", mailbox: "INBOX")
    }

    static func mailEngine(_ root: URL, lang: Shared<UILang>, mail: MailSettings,
                           sources: [String: FakeSource]) async throws -> Engine {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let deps = Engine.Dependencies(
            loadSettings: {
                EngineSettings(plan: PlanSettings(), lang: lang.get, agentMode: .off, autoReadNewPapers: false,
                               metadataLookup: false)
            },
            fetcher: nil, claude: MockAgentProvider(behavior: .notLoggedIn), codex: MockAgentProvider(behavior: .notLoggedIn),
            mock: MockAgentProvider(), sidecarDelay: .milliseconds(10), cliFacts: .inMemory(),
            loadMailSettings: { mail }, mailSecrets: InMemoryMailSecretStore(),
            mailSources: { account in sources[account.id] ?? FakeSource(account.id, status: .needsSetup("none")) })
        return try await Engine.open(paths: AppPaths.rooted(at: root), deps: deps)
    }

    static func close(_ engine: Engine) async {
        await engine.shutdown()
        await engine.db.close()
    }

    /// Polls `condition` every 50 ms for up to `seconds`.
    static func eventually(_ seconds: Double = 3, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    // MARK: Body (C-H, a-1)

    private static func bodyLoading(scratch: URL, _ c: Checker) async {
        // 1. Which text the inspector shows: never the list copy's.
        let base = MailMessage(pk: 7, accountID: "manual", internetMessageID: "<b@x>", fromAddress: "a@example.edu",
                               senderKind: .person, subject: "S", receivedAt: Date(), snippet: "Short", bodyText: nil)
        var listWithText = base
        listWithText.bodyText = "A stale copy of the text"
        var full = base
        full.bodyText = "Please read [c1 nature.com] before Friday."
        var fullEmpty = base
        fullEmpty.bodyText = "  \n"
        var purged = base
        purged.bodyPurged = true
        c.check("body: list copy only → loading", MailBodyDisplay.resolve(list: base, full: nil) == .loading)
        c.check("body: a list copy's text is never shown", MailBodyDisplay.resolve(list: listWithText, full: nil) == .loading)
        c.check("body: full card → its text", MailBodyDisplay.resolve(list: base, full: full) == .text(full.bodyText!))
        c.check("body: full card without text → no text", MailBodyDisplay.resolve(list: base, full: fullEmpty) == .empty)
        c.check("body: purged in the list → purged note at once", MailBodyDisplay.resolve(list: purged, full: nil) == .purged)
        c.check("body: purged in the full card → purged note", MailBodyDisplay.resolve(list: base, full: purged) == .purged)
        c.check("body: purged list wins over an older full card", MailBodyDisplay.resolve(list: purged, full: full) == .purged)

        // 2. The follower: loads at once, again on this email's changes (coalesced), not on others'.
        let (stream, feed) = AsyncStream<LibraryChange>.makeStream()
        let card = MailCard(message: full, items: [], rule: nil, account: nil)
        let rec = Recorder()
        let follower = Task {
            await MailFullCard.follow(id: base.id, changes: stream, load: { _ in
                rec.loads += 1
                return card
            }, deliver: { rec.delivered.append($0) })
        }
        let first = await eventually { rec.loads == 1 && rec.delivered.count == 1 }
        c.check("body: follower loads once at once", first && rec.last?.bodyText == full.bodyText, ["loads": rec.loads])
        for change in [LibraryChange.mail(pk: 8), .paper(pk: 7), .categories, .jobs] { feed.yield(change) }
        try? await Task.sleep(for: .milliseconds(200))
        c.check("body: other emails' changes don't reload", rec.loads == 1, ["loads": rec.loads])
        feed.yield(.mail(pk: 7))
        c.check("body: this email's change reloads", await eventually { rec.loads == 2 }, ["loads": rec.loads])
        feed.yield(.mailBulk)
        c.check("body: a bulk mail change reloads", await eventually { rec.loads == 3 }, ["loads": rec.loads])
        follower.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        feed.yield(.mail(pk: 7))
        try? await Task.sleep(for: .milliseconds(200))
        c.check("body: no load after the selection changed", rec.loads == 3, ["loads": rec.loads])
        feed.finish()

        // 3. A real engine: the list snapshot has no text, the follower brings it, a purge reloads it.
        let root = scratch.appendingPathComponent("body", isDirectory: true)
        let lang = Shared(UILang.en)
        let mail = MailSettings(enabled: false, aiMode: .heuristicOnly)
        guard let engine = try? await mailEngine(root, lang: lang, mail: mail, sources: [:]) else {
            c.check("body: engine fixture", false)
            return
        }
        do {
            let eml = root.appendingPathComponent("request.eml")
            let text = "Could you read this paper before Friday's journal club? https://www.nature.com/articles/s41586-024-00001-x"
            let lines = ["From: Jane Smith <jsmith@example.edu>", "To: me@example.edu", "Subject: Paper for Friday",
                         "Date: Tue, 29 Sep 2026 14:05:00 -0500", "Message-ID: <r3-body@example.edu>", "MIME-Version: 1.0",
                         "Content-Type: text/plain; charset=utf-8", "", text, ""]
            try Data(lines.joined(separator: "\r\n").utf8).write(to: eml)
            let ids = await engine.mail.importEML([eml])
            await engine.mail.waitUntilIdle()
            guard let id = ids.first else { throw FakeSourceError() }
            let listCard = try await engine.mailSnapshot().card(id: id)
            c.check("body: list snapshot carries no text (C-H)",
                    listCard != nil && (listCard?.message.bodyText ?? "").isEmpty && listCard?.message.bodyPurged == false)
            c.check("body: list copy → placeholder, not 'no text'",
                    MailBodyDisplay.resolve(list: listCard?.message, full: nil) == .loading)
            let rec = Recorder()
            let follow = Task {
                await MailFullCard.follow(id: id, changes: engine.changes.subscribe(), load: { wanted in
                    rec.loads += 1
                    return try? await engine.mailCard(id: wanted)
                }, deliver: { rec.delivered.append($0) })
            }
            let loaded = await eventually { rec.delivered.count == 1 }
            var shownText = ""
            if case .text(let t) = MailBodyDisplay.resolve(list: listCard?.message, full: rec.last) { shownText = t }
            c.check("body: the full card brings the text", loaded && shownText.contains("journal club"), ["loads": rec.loads])
            // Retention purges it after the card was handled: `.mailBulk` → reloaded → the purged note.
            try await engine.dismissMail(messageID: id)
            try await engine.db.purgeMailBodies(handledBefore: Date().addingTimeInterval(86_400))
            let reloaded = await eventually { rec.last?.bodyPurged == true }
            c.check("body: a purge reloads → purged note",
                    reloaded && MailBodyDisplay.resolve(list: listCard?.message, full: rec.last) == .purged, ["loads": rec.loads])
            follow.cancel()
        } catch {
            c.check("body: engine fixture", false, ["error": String(describing: type(of: error))])
        }
        await close(engine)
    }

    // MARK: Account rows (C-G, a-2)

    private static func accountRows(scratch: URL, _ c: Checker) async {
        // 1. Rows read in another language never show their sentences.
        let zhRows = [MailAccountSyncInfo(id: "a", displayName: "A", kind: .imap, enabled: true,
                                          status: .unavailable(MailSyncText.syncFailed(.zh))),
                      MailAccountSyncInfo(id: "b", displayName: "B", kind: .imap, enabled: true,
                                          status: .authFailed("应用专用密码被拒绝")),
                      MailAccountSyncInfo(id: "c", displayName: "C", kind: .folder, enabled: true,
                                          status: .ready(detail: "新增 3 个文件"), notEmailFiles: 1, notEmailHint: "不是完整的邮件")]
        let saved = LangStore.shared.lang
        LangStore.shared.lang = .en
        let shown = MailStatusText.current(zhRows, readIn: .zh, lang: .en)
        let texts = shown.compactMap { $0.status.map { MailStatusText.status($0).text } } + shown.compactMap(\.notEmailHint)
        c.check("rows: stale rows show no old-language sentence",
                texts.count == 3 && !texts.contains { $0.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF } },
                ["texts": texts])
        c.check("rows: stale rows keep each status kind",
                MailStatusText.status(shown[0].status!).kind == .warning && MailStatusText.status(shown[1].status!).kind == .error
                    && MailStatusText.status(shown[2].status!).kind == .ok && shown[2].notEmailFiles == 1)
        c.check("rows: same-language rows untouched", MailStatusText.current(zhRows, readIn: .zh, lang: .zh) == zhRows)
        LangStore.shared.lang = saved

        // 2. A real engine: a pipeline status worded in zh is read again in en after the switch.
        let root = scratch.appendingPathComponent("rows", isDirectory: true)
        let lang = Shared(UILang.zh)
        let failing = FakeSource("acct-r", status: .ready(detail: "ok"), failListing: true)
        let mail = MailSettings(enabled: true, accounts: [fakeAccount("acct-r")], syncMinutes: 0)
        guard let engine = try? await mailEngine(root, lang: lang, mail: mail, sources: ["acct-r": failing]) else {
            c.check("rows: engine fixture", false)
            return
        }
        await engine.mail.syncNow()
        let zh = await MailStatusText.read(engine.mail, lang: .zh).first?.status
        c.check("rows: fixture status worded in zh", zh == .unavailable(MailSyncText.syncFailed(.zh)), ["got": zh.map { "\($0)" }])
        lang.set(.en)                                   // Settings ▸ General ▸ Language → English
        let en = await MailStatusText.read(engine.mail, lang: .en).first?.status
        c.check("rows: read again in the new language (C-G)", en == .unavailable(MailSyncText.syncFailed(.en)),
                ["got": en.map { "\($0)" }])
        await close(engine)
    }

    // MARK: Targeted un-park (C-O, a-3)

    private static func targetedUnpark(scratch: URL, _ c: Checker) async {
        let root = scratch.appendingPathComponent("unpark", isDirectory: true)
        let lang = Shared(UILang.en)
        let a = FakeSource("acct-a", status: .authFailed("rejected"))
        let b = FakeSource("acct-b", status: .authFailed("rejected"))
        let mail = MailSettings(enabled: true, accounts: [fakeAccount("acct-a"), fakeAccount("acct-b")], syncMinutes: 0)
        let suite = scratch.appendingPathComponent("defaults-unpark/defaults").path
        try? FileManager.default.createDirectory(atPath: (suite as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let defaults = UserDefaults(suiteName: suite) else {
            c.check("unpark: scratch defaults", false)
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let savedLang = LangStore.shared.lang, savedProvider = LangStore.shared.provider
        defer { LangStore.shared.lang = savedLang; LangStore.shared.provider = savedProvider }
        guard let engine = try? await mailEngine(root, lang: lang, mail: mail, sources: ["acct-a": a, "acct-b": b]) else {
            c.check("unpark: engine fixture", false)
            return
        }
        do {
            await engine.mail.syncNow()
            func parked() async -> [String: Bool] {
                Dictionary(await engine.mail.accountSyncInfo(lang: .en).map { ($0.id, $0.waitingForSettings) }, uniquingKeysWith: { x, _ in x })
            }
            c.check("unpark: both accounts parked on a rejected password", await parked() == ["acct-a": true, "acct-b": true])
            await a.setStatus(.ready(detail: "Signed in"))
            await b.setStatus(.ready(detail: "Signed in"))
            // Test & Save of account A through the app's wiring (SettingsStore → engine).
            let store = SettingsStore(defaults: defaults)
            store.connectMail(to: engine)
            store.notifyMailNow(accountID: "acct-a")
            let aFree = await eventually { await parked()["acct-a"] == false }
            try? await Task.sleep(for: .milliseconds(200))
            let state = await parked()
            c.check("unpark: test & save retries only that account", aFree && state["acct-b"] == true, ["parked": state])
            let bCalls = await b.statusCalls
            c.check("unpark: the other account isn't signed in again", bCalls == 1, ["calls": bCalls])
            // 「立即同步」: every parked account.
            await MailSyncCommands.syncAll(engine.mail)
            let after = await parked()
            let bAfter = await b.statusCalls
            c.check("unpark: sync now retries every account", after == ["acct-a": false, "acct-b": false] && bAfter == 2,
                    ["parked": after, "calls": bAfter])
        }
        await close(engine)
    }

    // MARK: Launch (integrity-4, a-4)

    private static func launchRetry(scratch: URL, _ c: Checker) async {
        let fm = FileManager.default

        // 1. App folders that can't be created: a database-type failure, never the ~/Papers offer.
        // a) Application Support's folder is taken by a file.
        let taken = AppPaths.rooted(at: scratch.appendingPathComponent("taken", isDirectory: true))
        var result: LibraryOpenFailure?
        do {
            try fm.createDirectory(at: taken.library, withIntermediateDirectories: true)
            try Data("not a folder".utf8).write(to: taken.support)
            result = await openFailure(taken)
        } catch {
            c.check("launch: app folder fixture", false, ["error": String(describing: error)])
        }
        c.check("launch: app folder taken by a file → app-data alert",
                result == .appData(folder: taken.support) && result?.offersAnotherLibrary == false, ["got": result?.logName])
        // b) Its parent can't be written (permission), the library folder is fine.
        let locked = scratch.appendingPathComponent("locked", isDirectory: true)
        let lockedPaths = AppPaths.rooted(at: locked)
        result = nil
        do {
            try fm.createDirectory(at: lockedPaths.library, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
            result = await openFailure(lockedPaths)
        } catch {
            c.check("launch: locked fixture", false, ["error": String(describing: error)])
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        c.check("launch: app folder without permission → app-data alert",
                result == .appData(folder: lockedPaths.support) && result?.offersAnotherLibrary == false, ["got": result?.logName])
        // c) Synthetic: the probe decides between the library folder and the app's folders.
        let synthetic = AppPaths.rooted(at: scratch.appendingPathComponent("synthetic", isDirectory: true))
        let blocked = LibraryOpenFailure.classify(FileOpsError.permissionDenied, paths: synthetic,
                                                  createFolder: { $0 != synthetic.backups })
        c.check("launch: classify app folder blocked", blocked == .appData(folder: synthetic.backups), ["got": blocked.logName])
        let fine = LibraryOpenFailure.classify(FileOpsError.libraryUnavailable, paths: synthetic, createFolder: { _ in true })
        c.check("launch: classify library folder when app folders are fine", fine == .libraryFolder, ["got": fine.logName])
        c.check("launch: app folders are outside the library",
                !LibraryOpenFailure.appFolders(synthetic).contains { $0.path.hasPrefix(synthetic.library.path + "/") })

        // 2. Buttons: Retry for a failed database / app folder, never ~/Papers but for the folder.
        let table: [(LibraryOpenFailure, [LaunchAlert.Button])] = [
            (.libraryFolder, [.useAlternative, .retry, .quit]),
            (.newerVersion(found: 3, supported: 2), [.quit, .showBackups]),
            (.database(diskFull: false), [.quit, .retry, .showBackups]),
            (.database(diskFull: true), [.quit, .retry, .showBackups]),
            (.appData(folder: synthetic.support), [.quit, .retry, .showFolder]),
        ]
        for (failure, expected) in table {
            let got = LaunchAlert.buttons(for: failure)
            c.check("launch: buttons \(failure.logName)",
                    got == expected && got.contains(.useAlternative) == failure.offersAnotherLibrary)
        }

        // 3. The open loop (`AppDelegate.bootstrap`): scripted failures and clicks.
        let start = AppPaths.rooted(at: scratch.appendingPathComponent("loop", isDirectory: true))
        let alternative = scratch.appendingPathComponent("Papers", isDirectory: true)
        func run(_ errors: [any Error], clicks: [LaunchAlert.Button])
            async -> (result: Int?, opens: Int, asked: [LibraryOpenFailure], libraryPath: [URL], revealed: [URL]) {
            var opens = 0, asked: [LibraryOpenFailure] = [], written: [URL] = [], revealed: [URL] = []
            var script = clicks
            let result = await LaunchAlert.open(
                start, alternative: alternative,
                open: { _ in
                    opens += 1
                    if opens <= errors.count { throw errors[opens - 1] }
                    return opens
                },
                ask: { failure, _ in
                    asked.append(failure)
                    return script.isEmpty ? .quit : script.removeFirst()
                },
                useLibrary: { url in
                    written.append(url)
                    return AppPaths.rooted(at: url)
                },
                reveal: { revealed.append($0) },
                classify: { error, _ in LibraryOpenFailure.classify(error) })
            return (result, opens, asked, written, revealed)
        }
        let dbError = SQLiteError(code: 14, message: "unable to open database file")
        var r = await run([dbError], clicks: [.retry])
        c.check("launch: retry opens again and continues", r.result == 2 && r.opens == 2 && r.asked == [.database(diskFull: false)]
                && r.libraryPath.isEmpty, ["opens": r.opens])
        r = await run([dbError, dbError, dbError], clicks: [.retry, .retry, .quit])
        c.check("launch: a failed retry shows the same alert again", r.result == nil && r.opens == 3
                && r.asked == Array(repeating: .database(diskFull: false), count: 3) && r.libraryPath.isEmpty, ["opens": r.opens])
        r = await run([dbError], clicks: [.quit])
        c.check("launch: quit stops at once", r.result == nil && r.opens == 1 && r.libraryPath.isEmpty)
        r = await run([dbError], clicks: [.showBackups])
        c.check("launch: show backups reveals and quits", r.result == nil && r.opens == 1
                && r.revealed == [LibraryOpenFailure.revealTarget(backups: start.backups)] && r.libraryPath.isEmpty)
        r = await run([dbError], clicks: [.useAlternative])
        c.check("launch: ~/Papers is never honoured for a database failure", r.result == nil && r.opens == 1 && r.libraryPath.isEmpty)
        r = await run([DatabaseError.newerSchema(found: 3, supported: 2)], clicks: [.retry])
        c.check("launch: no retry for a newer database", r.result == nil && r.opens == 1 && r.libraryPath.isEmpty)
        r = await run([FileOpsError.permissionDenied], clicks: [.useAlternative])
        c.check("launch: library folder → ~/Papers retried there", r.result == 2 && r.libraryPath == [alternative])
        r = await run([TransientError(), FileOpsError.libraryUnavailable], clicks: [.retry, .retry])
        c.check("launch: retry after a transient error, then the folder alert", r.result == 3
                && r.asked == [.database(diskFull: false), .libraryFolder] && r.libraryPath.isEmpty)
        // An app folder that can't be created, through the real classifier and probe.
        func runAppData(_ clicks: [LaunchAlert.Button]) async -> (result: Int?, opens: Int, asked: [LibraryOpenFailure],
                                                                   written: Int, revealed: [URL]) {
            var opens = 0, asked: [LibraryOpenFailure] = [], written = 0, revealed: [URL] = []
            var script = clicks
            let result: Int? = await LaunchAlert.open(
                taken, alternative: alternative,
                open: { paths in
                    opens += 1
                    try LibraryPaths.ensureLayout(paths: paths)
                    return 1
                },
                ask: { failure, _ in
                    asked.append(failure)
                    return script.isEmpty ? .quit : script.removeFirst()
                },
                useLibrary: { _ in written += 1; return taken },
                reveal: { revealed.append($0) })
            return (result, opens, asked, written, revealed)
        }
        var a = await runAppData([.useAlternative])
        c.check("launch: app folder failure never writes library.path",
                a.result == nil && a.written == 0 && a.opens == 1 && a.asked == [.appData(folder: taken.support)],
                ["asked": a.asked.map(\.logName)])
        a = await runAppData([.retry, .showFolder])
        c.check("launch: app folder failure → retry, then show in Finder",
                a.result == nil && a.written == 0 && a.opens == 2 && a.asked.count == 2
                    && a.revealed.map { $0.resolvingSymlinksInPath().path } == [taken.support.resolvingSymlinksInPath().path],
                ["revealed": a.revealed.map(\.lastPathComponent)])

        // 4. Texts of the app-data alert (both languages): the folder, Retry, never ~/Papers.
        let folder = synthetic.support
        for l in [UILang.en, .zh] {
            let saved = LangStore.shared.lang
            LangStore.shared.lang = l
            let title = L.databaseFailureTitle(.appData(folder: folder)), body = L.databaseFailureBody(.appData(folder: folder))
            let dbBody = L.databaseFailureBody(.database(diskFull: false))
            let buttons = LaunchAlert.buttons(for: .appData(folder: folder)).map(L.launchButton)
            LangStore.shared.lang = saved
            let cjk = { (s: String) in s.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF } }
            c.check("launch: app-data alert text \(l.rawValue)",
                    !title.isEmpty && body.contains(folder.path) && !body.contains("~/Papers") && (l == .zh) == cjk(title)
                        && body.contains(l == .zh ? "重试" : "Retry") && dbBody.contains(l == .zh ? "重试" : "Retry")
                        && buttons.count == 3 && buttons.allSatisfy { !$0.isEmpty },
                    ["title": title, "buttons": buttons])
        }
        c.check("launch: show in finder reveals the nearest existing folder",
                LibraryOpenFailure.existingAncestor(of: scratch.appendingPathComponent("no/such/folder")) == scratch.standardizedFileURL)
    }

    /// What the launch would show for this library (classified with the real probe): nil when it opened.
    static func openFailure(_ paths: AppPaths) async -> LibraryOpenFailure? {
        do {
            let engine = try await Engine.open(paths: paths, deps: deps())
            await close(engine)
            return nil
        } catch {
            return LibraryOpenFailure.classify(error, paths: paths)
        }
    }
}
