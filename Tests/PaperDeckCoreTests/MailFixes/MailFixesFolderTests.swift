import Foundation
import Testing
@testable import PaperDeckCore

/// Files in the watched folder that are not RFC 822 messages: never cards, never retried,
/// recorded in the ledger (hashed names only), counted for Settings ▸ Mail with a fix hint —
/// and judged only on stable bytes. Synthetic files only (Fixtures/mail/mail-fixes).
@Suite struct MailFixesFolderTests {
    private typealias Kit = MailFixesKit
    private let t0 = Date()

    /// Temp folder, removed when the test ends.
    private final class Folder {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("pd-mailfixes-folder-\(UUID().uuidString)",
                                                                                isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        func write(_ name: String, _ data: Data, mtime: Date) throws {
            let u = url.appendingPathComponent(name)
            try data.write(to: u)
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: u.path)
        }
        func remove(_ name: String) throws { try FileManager.default.removeItem(at: url.appendingPathComponent(name)) }
    }

    private static func account(_ folder: Folder) -> MailAccount {
        MailAccount(id: "acct-pa", kind: .folder, displayName: "WashU (Power Automate)", folderPath: folder.url.path)
    }

    private func source(_ folder: Folder) -> FolderMailSource {
        let now = t0
        // 120 s, not 10 (ENV-1): every folder source shares one serial read queue; on a loaded machine
        // other suites' reads queue ahead and a short timeout skipped files. Nothing here tests the timeout.
        return FolderMailSource(account: Self.account(folder), now: { now }, settleSeconds: 2, readTimeout: .seconds(120))
    }

    private static let minimal = Data("From: Jane Smith <jsmith@wustl.edu>\r\nSubject: Hi\r\n\r\nBody\r\n".utf8)

    @Test func snifferTellsEmailsFromOtherFiles() throws {
        #expect(MailFileSniffer.isMessage(try Kit.fixture("outlook-export")))
        #expect(MailFileSniffer.isMessage(Self.minimal))
        #expect(MailFileSniffer.isMessage(Data([0xEF, 0xBB, 0xBF]) + Self.minimal))              // UTF-8 BOM
        #expect(MailFileSniffer.isMessage(Data("From jsmith@wustl.edu Wed Sep 30 14:01:58 2026\n".utf8) + Self.minimal))

        #expect(!MailFileSniffer.isMessage(try Kit.fixture("html-only")))
        #expect(!MailFileSniffer.isMessage(Data()))
        #expect(!MailFileSniffer.isMessage(Data(#"{"from":"jsmith@wustl.edu","subject":"x"}"#.utf8)))
        #expect(!MailFileSniffer.isMessage(Data("{\n  \"From\": \"jsmith@wustl.edu\"\n}\n".utf8)))
        #expect(!MailFileSniffer.isMessage(Kit.pdfStub))                                          // a PDF renamed .eml
        #expect(!MailFileSniffer.isMessage(Data("Hello there: this is a note\nFrom: jsmith@wustl.edu\n".utf8)))
        #expect(!MailFileSniffer.isMessage(Data("Note: hi\r\n\r\nFrom: jsmith@wustl.edu\r\n".utf8)))   // From only in the body
        #expect(!MailFileSniffer.isMessage(Data("From: Jane Smith\r\nSubject: no address\r\n\r\n".utf8)))
        #expect(!MailFileSniffer.isMessage(Data((0..<512).map { UInt8(truncatingIfNeeded: $0 &* 37) })))
    }

    @Test func nonEmailFilesAreRecordedCountedAndNeverListed() async throws {
        let folder = try Folder()
        let old = t0.addingTimeInterval(-600)
        try folder.write("20260930-140212-1b2c.eml", try Kit.fixture("html-only"), mtime: old)
        try folder.write("empty.eml", Data(), mtime: old)
        try folder.write("export.eml", Data(#"{"value":[{"subject":"x"}]}"#.utf8), mtime: old)
        try folder.write("paper.eml", Kit.pdfStub, mtime: old)
        try folder.write("notes.eml", Data("just some text\nnothing else\n".utf8), mtime: old)
        try folder.write("real.eml", try Kit.fixture("outlook-export"), mtime: old)
        let src = source(folder)

        let p1 = try await src.listHeaders(since: nil, limit: 50)
        #expect(p1.headers.map(\.ref) == ["real.eml"])
        #expect(p1.headers.first?.fromAddress == "jsmith@wustl.edu")
        #expect(p1.notEmailFiles == 5)
        let cursor = try #require(p1.nextCursor)
        let ledger = try #require(FolderLedger(cursor))
        #expect(ledger.files.count == 6 && ledger.notMailCount == 5)
        #expect(!cursor.value.contains(".eml") && !cursor.value.contains("notes") && !cursor.value.contains("20260930"))

        // Not retried: the next pass lists nothing and keeps the count.
        let p2 = try await src.listHeaders(since: cursor, limit: 50)
        #expect(p2.headers.isEmpty && p2.notEmailFiles == 5)

        // Deleting them makes the number drop; a file fixed in place is judged again.
        try folder.remove("20260930-140212-1b2c.eml")
        try folder.remove("empty.eml")
        try folder.write("notes.eml", Self.minimal, mtime: t0.addingTimeInterval(-300))
        let p3 = try await src.listHeaders(since: p2.nextCursor, limit: 50)
        #expect(p3.headers.map(\.ref) == ["notes.eml"])
        #expect(p3.notEmailFiles == 2)
        #expect(FolderLedger(p3.nextCursor)?.files.count == 4)
    }

    @Test func freshFilesNeedASecondLookBeforeTheVerdict() async throws {
        let folder = try Folder()
        try folder.write("fresh.eml", try Kit.fixture("html-only"), mtime: t0.addingTimeInterval(-5))   // settled, < 60 s
        let src = source(folder)
        let p1 = try await src.listHeaders(since: nil, limit: 10)
        #expect(p1.headers.isEmpty && p1.notEmailFiles == 0)
        #expect(FolderLedger(p1.nextCursor)?.files.isEmpty == true)               // not decided, not recorded
        let p2 = try await src.listHeaders(since: p1.nextCursor, limit: 10)       // same size and mtime again
        #expect(p2.headers.isEmpty && p2.notEmailFiles == 1)
        #expect(FolderLedger(p2.nextCursor)?.files.first?.notMail == true)
    }

    @Test func partialThenCompleteBecomesAnEmail() async throws {
        let folder = try Folder()
        let full = try Kit.fixture("outlook-export")
        try folder.write("partial.eml", full.prefix(40), mtime: t0.addingTimeInterval(-5))   // "Received: from SA1PR…" cut
        try folder.write("growing.eml", Data(), mtime: t0.addingTimeInterval(-5))
        let src = source(folder)
        let p1 = try await src.listHeaders(since: nil, limit: 10)
        #expect(p1.headers.isEmpty && p1.notEmailFiles == 0)

        // The writer (OneDrive, a flow) finishes both files.
        try folder.write("partial.eml", full, mtime: t0.addingTimeInterval(-4))
        try folder.write("growing.eml", Self.minimal, mtime: t0.addingTimeInterval(-4))
        let p2 = try await src.listHeaders(since: p1.nextCursor, limit: 10)
        #expect(Set(p2.headers.map(\.ref)) == ["partial.eml", "growing.eml"])
        #expect(p2.notEmailFiles == 0)
        #expect(FolderLedger(p2.nextCursor)?.notMailCount == 0)
    }

    @Test func aRecordedVerdictIsRevisitedWhenTheFileChanges() async throws {
        let folder = try Folder()
        try folder.write("flow.eml", try Kit.fixture("html-only"), mtime: t0.addingTimeInterval(-900))
        let src = source(folder)
        let p1 = try await src.listHeaders(since: nil, limit: 10)
        #expect(p1.notEmailFiles == 1)
        // The user fixed the flow and the next export overwrote the same name.
        try folder.write("flow.eml", try Kit.fixture("outlook-export"), mtime: t0.addingTimeInterval(-60))
        let p2 = try await src.listHeaders(since: p1.nextCursor, limit: 10)
        #expect(p2.headers.map(\.ref) == ["flow.eml"])
        #expect(p2.notEmailFiles == 0)
    }

    @Test func ledgerFlagRoundTripsAndOldCursorsStillDecode() throws {
        let old = try #require(FolderLedger(MailCursor(#"{"files":[["0123456789abcdef",10,100]],"v":1}"#)))
        #expect(old.files == [FolderLedger.Entry(key: "0123456789abcdef", size: 10, mtimeMs: 100)])
        #expect(old.notMailCount == 0)
        var l = FolderLedger()
        l.record(.init(key: "aaaaaaaaaaaaaaaa", size: 0, mtimeMs: 200, notMail: true))
        l.record(.init(key: "bbbbbbbbbbbbbbbb", size: 5, mtimeMs: 300))
        #expect(l.cursor.value.contains(#"["aaaaaaaaaaaaaaaa",0,200,1]"#))
        #expect(l.cursor.value.contains(#"["bbbbbbbbbbbbbbbb",5,300]"#))
        #expect(FolderLedger(l.cursor) == l && l.notMailCount == 1)
    }

    // MARK: Through the sync (Settings ▸ Mail ▸ Accounts)

    @Test func syncShowsTheCountAndTheFixAndCapturesTheRealExport() async throws {
        let folder = try Folder()
        let old = t0.addingTimeInterval(-600)
        try folder.write("20260930-140212-1b2c.eml", try Kit.fixture("html-only"), mtime: old)
        try folder.write("20260930-140530-9f8e.eml", try Kit.fixture("outlook-export"), mtime: old)
        let account = Self.account(folder)
        let mail = MailSettings(enabled: true, accounts: [account],
                                senders: [SenderRule(id: "rule-smith", pattern: "jsmith@wustl.edu", kind: .advisor)],
                                syncMinutes: 0)
        let factory: @Sendable (MailAccount) -> any MailSource = { a in
            FolderMailSource(account: a, settleSeconds: 2, readTimeout: .seconds(120))      // load-tolerant (ENV-1)
        }
        try await Kit.run(mail: mail, sources: factory) { env in
            await env.engine.mail.syncNow()
            await env.engine.mail.waitUntilIdle()
            var info = try #require(await env.engine.mail.accountSyncInfo().first)
            #expect(info.notEmailFiles == 1)
            #expect(info.notEmailHint == "1 file in this folder isn't a complete email. In Power Automate ▸ Create file, "
                    + "set File Content to body('Export_email_(V2)') — the Body of Export email (V2), not the trigger's Body.")

            // The good export became exactly one card: the PDF stored, the Safe Links unwrapped.
            let messages = try await env.allMessages()
            #expect(messages.count == 1)
            let m = try #require(messages.first)
            #expect(m.subject == "Paper for Friday's meeting" && m.senderKind == .advisor && m.state == .pending)
            #expect(m.authState == .pass)
            let items = try await env.db.mailItems(messagePK: m.pk)
            let pdf = try #require(items.first { $0.origin == .attachment })
            #expect(pdf.pdfState == .hasPDF && pdf.pdfPath != nil)
            let link = try #require(items.first { $0.ids.doi == "10.1101/2026.08.12.607788" })
            #expect(link.url?.hasPrefix("https://www.biorxiv.org/") == true)
            #expect(link.urlOriginal?.contains("safelinks.protection.outlook.com") == true)
            #expect(!items.contains { ($0.url ?? "").contains("aka.ms") })
            #expect(m.bodyText?.contains("safelinks") == false)

            env.settings.update { $0.lang = .zh }
            await env.engine.mail.syncNow()
            info = try #require(await env.engine.mail.accountSyncInfo().first)
            #expect(info.notEmailHint?.hasPrefix("此文件夹中有 1 个文件不是完整的邮件。") == true)
            #expect(info.notEmailHint?.contains("body('Export_email_(V2)')") == true)

            // Deleting the bad file clears the hint at the next sync; no card ever came from it.
            try folder.remove("20260930-140212-1b2c.eml")
            await env.engine.mail.syncNow()
            info = try #require(await env.engine.mail.accountSyncInfo().first)
            #expect(info.notEmailFiles == 0 && info.notEmailHint == nil)
            #expect(try await env.allMessages().count == 1)
        }
    }

    @Test func theCountSurvivesARelaunchFromTheStoredLedger() async throws {
        let folder = try Folder()
        try folder.write("bad.eml", try Kit.fixture("html-only"), mtime: t0.addingTimeInterval(-600))
        let account = Self.account(folder)
        let mail = MailSettings(enabled: true, accounts: [account], syncMinutes: 0)
        let env = try await Kit.make(mail: mail, sources: { a in FolderMailSource(account: a) })
        await env.engine.mail.syncNow()
        #expect(await env.engine.mail.accountSyncInfo().first?.notEmailFiles == 1)
        await env.engine.shutdown()
        await env.engine.db.close()

        // Same library, mail switched off: no sync runs, the stored ledger still tells.
        let off = MailSettings(enabled: false, accounts: [account], syncMinutes: 0)
        let reopened = try await Engine.open(paths: AppPaths.rooted(at: env.root), deps: Engine.Dependencies(
            loadSettings: { env.settings.value }, now: { env.clock.value }, calendar: Kit.calendar, fetcher: nil,
            claude: MockAgentProvider(), codex: MockAgentProvider(), mock: MockAgentProvider(),
            sidecarDelay: .milliseconds(5), cliFacts: .inMemory(), loadMailSettings: { off },
            mailSecrets: InMemoryMailSecretStore(), mailSources: { a in FolderMailSource(account: a) }, assistBackends: [MockAssistBackend()]))
        await reopened.mail.syncNow()
        let info = await reopened.mail.accountSyncInfo().first
        #expect(info?.notEmailFiles == 1 && info?.notEmailHint != nil)
        await reopened.shutdown()
        await reopened.db.close()
        try? FileManager.default.removeItem(at: env.root)
    }
}
