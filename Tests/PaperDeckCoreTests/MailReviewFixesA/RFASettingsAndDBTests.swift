import Foundation
import Testing
@testable import PaperDeckCore

/// Review fix integrity-8 (contract K6): saved mail settings decode leniently, element by
/// element. Contract K5 storage: the consent columns of schema v2 (amended in place), the
/// pre-release v2 repair, and 「清除所有邮件数据」 dropping per-message kv bookkeeping.
@Suite struct RFASettingsAndDBTests {
    // MARK: integrity-8

    private static let goodRule = #"{"id":"r1","pattern":"jsmith@wustl.edu","label":"Prof. Smith","kind":"advisor","enabled":true,"aiPolicy":"ask","useDueDateAsDDL":true,"autoMerge":false,"autoDownload":true}"#

    @Test func oneUnreadableSenderDoesNotWipeTheList() throws {
        let missingKey = #"{"id":"r2","pattern":"@biorxiv.org","kind":"alert"}"#                 // only the identity
        let unknownPolicy = #"{"id":"r3","pattern":"c@b.org","kind":"person","aiPolicy":"sometimes","enabled":false}"#
        let unknownKind = #"{"id":"r4","pattern":"lab@b.org","kind":"robot","aiPolicy":"always"}"#
        let noPattern = #"{"id":"r5","kind":"person"}"#
        let notAnObject = #""just a string""#
        let json = "[" + [Self.goodRule, missingKey, unknownPolicy, unknownKind, noPattern, notAnObject].joined(separator: ",") + "]"
        let rules = MailSettings.list(json, SenderRule.self, what: "sender")
        #expect(rules.map(\.id) == ["r1", "r2", "r3", "r4"])
        try #require(rules.count == 4)
        #expect(rules[0] == SenderRule(id: "r1", pattern: "jsmith@wustl.edu", label: "Prof. Smith", kind: .advisor,
                                       aiPolicy: .ask))
        #expect(rules[1] == SenderRule(id: "r2", pattern: "@biorxiv.org", kind: .alert))      // memberwise defaults
        #expect(rules[1].aiPolicy == .always && rules[1].autoDownload && !rules[1].autoMerge)
        #expect(rules[2].aiPolicy == .ask && !rules[2].enabled)                                // unknown → ask
        #expect(rules[3].kind == .person && rules[3].aiPolicy == .always)                       // unknown kind → person
        #expect(MailSettings.list("{not json", SenderRule.self, what: "sender").isEmpty)
        #expect(MailSettings.list(nil, SenderRule.self, what: "sender").isEmpty)
        // Round trip of a full rule is unchanged.
        let rule = SenderRule(id: "r9", pattern: "@cell.com", label: "Cell", kind: .alert, enabled: false, aiPolicy: .never,
                              defaultPriority: .high, defaultCategory: "Neuro", useDueDateAsDDL: false, autoMerge: true,
                              autoDownload: false)
        #expect(MailSettings.list(MailSettings.encode([rule]), SenderRule.self, what: "sender") == [rule])
    }

    @Test func accountsAndCriteriaDecodeLeniently() throws {
        let folder = #"{"id":"a1","kind":"folder","displayName":"WashU","folderPath":"/tmp/x"}"#
        let future = #"{"id":"a2","kind":"graph","displayName":"Outlook"}"#                      // unknown transport
        let imap = #"{"id":"a3","kind":"imap","imapPreset":"proton","host":"imap.example.org","port":993,"username":"me@example.org"}"#
        let accounts = MailSettings.list("[" + [folder, future, imap].joined(separator: ",") + "]", MailAccount.self,
                                         what: "account")
        #expect(accounts.map(\.id) == ["a1", "a3"])
        try #require(accounts.count == 2)
        #expect(accounts[0].enabled && accounts[0].lookbackDays == 14 && !accounts[0].deleteProcessedFiles
                && accounts[0].mailbox == nil)
        #expect(accounts[1].imapPreset == .custom && accounts[1].host == "imap.example.org")
        let full = MailAccount(id: "a9", kind: .imap, displayName: "Gmail", enabled: false, lookbackDays: 3,
                               imapPreset: .gmail, host: "imap.gmail.com", port: 993, username: "x@gmail.com", mailbox: nil)
        #expect(MailSettings.list(MailSettings.encode([full]), MailAccount.self, what: "account") == [full])

        let criteria = try? JSONDecoder().decode(ReadingCriteria.self,
                                                 from: Data(#"{"keepKinds":["advisor_request","podcast"],"minConfidence":0.7}"#.utf8))
        #expect(criteria?.keepKinds == [.advisorRequest])
        #expect(criteria?.minConfidence == 0.7 && criteria?.maxAlertPapers == 8)
    }

    @Test func loadKeepsTheReadableSenders() throws {
        let scratch = ScratchDefaults("rfa-mail-settings")
        defer { scratch.drop() }
        let d = scratch.defaults
        d.set("[" + Self.goodRule + #",{"id":"r2","pattern":"@x.org","kind":"alert","aiPolicy":"sometimes"}]"#,
              forKey: MailSettings.Keys.senders)
        d.set(#"[{"id":"a1","kind":"folder","displayName":"F"},{"id":"a2"}]"#, forKey: MailSettings.Keys.accounts)
        let s = MailSettings.load(from: d)
        #expect(s.senders.map(\.id) == ["r1", "r2"])
        try #require(s.senders.count == 2)
        #expect(s.senders[1].aiPolicy == .ask)
        #expect(s.accounts.map(\.id) == ["a1"])
    }

    // MARK: K5 storage

    private static func message(_ n: Int) -> MailMessage {
        MailMessage(accountID: "acct", internetMessageID: "<rfa-\(n)@example.org>", fromAddress: "a@example.org",
                    senderKind: .person, subject: "S \(n)", receivedAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func consentColumnsRoundTrip() async throws {
        let db = try Database.inMemory()
        var m = Self.message(1)
        m.triageConsented = true
        m.triageConsentProvider = "codex"
        let saved = try await db.insertMailMessage(m, items: []).0
        #expect(saved.triageConsented && saved.triageConsentProvider == "codex")
        let cleared = try await db.modifyMailMessage(pk: saved.pk) { $0.triageConsented = false; $0.triageConsentProvider = nil }
        #expect(!cleared.triageConsented && cleared.triageConsentProvider == nil)
        let plain = try await db.insertMailMessage(Self.message(2), items: []).0
        #expect(!plain.triageConsented && plain.triageConsentProvider == nil)
    }

    /// A database a development build created at v2 before the consent columns existed gets
    /// them at open; nothing else changes and no v3 is introduced.
    @Test func aPrereleaseV2DatabaseGainsTheNewColumns() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-rfa-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        do {
            let raw = try SQLiteConnection(path: url.path)
            defer { raw.close() }
            try Migrations.prepare(raw, backupsDir: nil)
            try raw.exec("ALTER TABLE mail_message DROP COLUMN triage_consent_provider")
            try raw.exec("ALTER TABLE mail_message DROP COLUMN triage_consented")
            try raw.run("""
                INSERT INTO mail_message(id, internet_message_id, from_address, received_at, created_at, updated_at)
                VALUES('m1', '<old@x>', 'a@x', '2026-09-30T10:00:00.000Z', '2026-09-30T10:00:00.000Z', '2026-09-30T10:00:00.000Z')
                """)
        }
        let db = try await Database.open(url: url, backupsDir: dir.appendingPathComponent("backups"))
        #expect(try await db.schemaVersion() == 2)
        let old = try #require(try await db.mailMessage(id: "m1"))
        #expect(!old.triageConsented && old.triageConsentProvider == nil)
        var m = Self.message(3)
        m.triageConsented = true
        m.triageConsentProvider = "claude"
        #expect(try await db.insertMailMessage(m, items: []).0.triageConsentProvider == "claude")
        await db.close()
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("backups").path)) ?? []).isEmpty)
    }

    /// Round 3 (r3-3): one post-processing key only — the sync's real marker
    /// `mail.cursor.~postprocess` (the dead `mail.postprocess.*` prefix is gone).
    @Test func clearingMailDataDropsPerMessageBookkeeping() async throws {
        let db = try Database.inMemory()
        _ = try await db.insertMailMessage(Self.message(1), items: [])
        try await db.setMailCursor(accountID: MailSyncActor.pendingPostKey, MailCursor("1"))
        try await db.setMailCursor(accountID: MailSyncActor.skippedKey("acct"), MailCursor("3"))
        try await db.setKV(MailTriageCoordinator.dayKey, #"{"day":"2026-09-30","n":2}"#)
        try await db.deleteAllMailData()
        #expect(try await db.kv(Database.mailCursorPrefix + MailSyncActor.pendingPostKey) == nil)
        #expect(try await db.mailCursor(accountID: MailSyncActor.skippedKey("acct")) == nil)
        #expect(try await db.kv(MailTriageCoordinator.dayKey) != nil)       // today's count is not mail data
    }
}
