import Foundation
import Testing
@testable import PaperDeckCore

/// Round 5 (a): an alert rule's message that isn't mailing-list mail — an editor's or a person's
/// own email from a preset publisher domain (@cell.com) without List-Id / List-Unsubscribe — is
/// not a published digest: its title-only metadata lookups wait for 「让 AI 分析」 like a person's.
/// The capture records `isBulk` on the message (an additive, nullable column; older rows read nil
/// and keep today's digest behavior). A fake metadata transport records every request; nothing
/// leaves the machine and no CLI runs (mock provider).
@Suite(.serialized) struct R5TitleLookupTests {
    typealias K = MailSyncKit
    static let cellRule = SenderRule(id: "rule-cell", pattern: "@cell.com", label: "Cell Press", kind: .alert)
    static let title = "Unpublished results on cortical folding in ferrets"

    static func message(kind: SenderKind, bulk: Bool?, consented: Bool = false, subject: String = "Quick look?") -> MailMessage {
        MailMessage(accountID: "a", internetMessageID: "<\(UUID().uuidString)@x>", fromAddress: "jane.editor@cell.com",
                    senderKind: kind, subject: subject, receivedAt: K.start, bodyText: "Would you look over the attached draft?",
                    triageConsented: consented, triageConsentProvider: consented ? "claude" : nil, isBulk: bulk)
    }

    @Test func theRuleWaitsForConsentOnAlertMailThatIsntListMail() {
        #expect(!MailSyncActor.mayLookUpTitles(Self.message(kind: .alert, bulk: false)))
        #expect(MailSyncActor.mayLookUpTitles(Self.message(kind: .alert, bulk: false, consented: true)))
        #expect(MailSyncActor.mayLookUpTitles(Self.message(kind: .alert, bulk: true)))
        // Captured before isBulk was recorded: a digest, as it always was.
        #expect(MailSyncActor.mayLookUpTitles(Self.message(kind: .alert, bulk: nil)))
        // Confidential mail never, whatever the rest.
        #expect(!MailSyncActor.mayLookUpTitles(Self.message(kind: .alert, bulk: true, consented: true,
                                                            subject: "Invitation to review manuscript CELL-D-1")))
        for kind in [SenderKind.person, .advisor, .manual] {
            #expect(!MailSyncActor.mayLookUpTitles(Self.message(kind: kind, bulk: true)), "\(kind)")
        }
    }

    /// The verifier's gap probe (round 4, "alert-domain personal mail"): no title search before
    /// consent; `isBulk` stored false; after 「让 AI 分析」 the held lookup runs like a person's.
    @Test func aPersonalEmailFromAnAlertDomainKeepsItsAttachmentTitleHeld() async throws {
        let recorder = R4.Recorder()
        let mail = K.mailSettings(senders: [K.advisorRule, Self.cellRule])
        try await R4.run(mode: .mock, mail: mail, fetcher: recorder, pdf: K.FakePDF(title: Self.title, doi: nil)) { env in
            let eml = R4.emlWithPDF(from: "jane.editor@cell.com", messageID: "<r5-gap-1@cell.com>", subject: "Quick look?",
                                    body: ["Dear Dr Jiang,", "Would you look over the attached draft before we decide?", "Jane"],
                                    pdf: K.realPDF(title: "Draft"))
            await env.source.add("gap1.eml", eml)
            await env.sync()
            let m = try await env.message("<r5-gap-1@cell.com>")
            #expect(m.senderKind == .alert && m.isBulk == false && !MailHeuristics.isConfidential(m))
            #expect(m.triageState == .awaitingConsent)
            let attachment = try #require(try await env.db.mailItems(messagePK: m.pk).first { $0.origin == .attachment })
            #expect(attachment.title == Self.title)
            #expect(recorder.titleSearches.isEmpty, "\(recorder.titleSearches)")
            #expect(!recorder.requested.contains { $0.contains("Unpublished") })

            try await env.engine.requestMailAI(messageID: m.id)
            #expect(await K.eventually {
                await env.engine.mail.waitUntilIdle()
                return recorder.titleSearches.contains { $0.contains("Unpublished%20results%20on%20cortical%20folding") }
            }, "\(recorder.requested)")
        }
    }

    /// A published digest (List-Unsubscribe) still looks its titles up at once.
    @Test func aDigestStillLooksItsTitlesUp() async throws {
        let recorder = R4.Recorder()
        let mail = K.mailSettings(senders: [K.advisorRule, Self.cellRule])
        try await R4.run(mode: .mock, mail: mail, fetcher: recorder,
                         pdf: K.FakePDF(title: "Published atlas of the developing ferret cortex", doi: nil)) { env in
            let eml = R4.emlWithPDF(from: "alerts@cell.com", messageID: "<r5-digest@cell.com>", subject: "Cell Press: new issue",
                                    body: ["New this week in Neuron", "See the attached table of contents."],
                                    pdf: K.realPDF(title: "TOC"), extraHeaders: ["List-Unsubscribe: <mailto:unsub@cell.com>"])
            await env.source.add("digest.eml", eml)
            await env.sync()
            let m = try await env.message("<r5-digest@cell.com>")
            #expect(m.isBulk == true)
            #expect(recorder.titleSearches.contains { $0.contains("Published%20atlas") }, "\(recorder.requested)")
        }
    }

    @Test func isBulkRoundTripsThroughTheDatabase() async throws {
        try await MailSyncKit.run { env in
            for (n, bulk) in [(1, Bool?.some(true)), (2, Bool?.some(false)), (3, Bool?.none)] {
                var m = Self.message(kind: .alert, bulk: bulk)
                m.internetMessageID = "<r5-bulk-\(n)@x>"
                let saved = try await env.db.insertMailMessage(m, items: []).0
                #expect(try await env.db.mailMessage(pk: saved.pk)?.isBulk == bulk, "\(n)")
                // An update keeps it.
                let touched = try await env.db.modifyMailMessage(pk: saved.pk, now: K.start) { $0.seen = true }
                #expect(touched.isBulk == bulk)
            }
        }
    }

    /// A database whose mail tables predate the column gets it at open (no backup, rows kept and
    /// read as nil) — and the file stays readable by a build that doesn't know the column.
    @Test func anOlderMailSchemaGainsTheColumnAtOpen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-r5-schema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.sqlite")
        do {
            let raw = try SQLiteConnection(path: url.path)
            try Migrations.prepare(raw, backupsDir: nil)
            try raw.exec("ALTER TABLE mail_message DROP COLUMN is_bulk")
            try raw.run("""
                INSERT INTO mail_message(id, internet_message_id, from_address, received_at, created_at, updated_at)
                VALUES('m1', '<old@x>', 'a@x', '2026-09-30T10:00:00.000Z', '2026-09-30T10:00:00.000Z', '2026-09-30T10:00:00.000Z')
                """)
            raw.close()
        }
        let backups = dir.appendingPathComponent("Backups")
        let db = try await Database.open(url: url, backupsDir: backups)
        let old = try #require(try await db.mailMessage(id: "m1"))
        #expect(old.isBulk == nil)
        _ = try await db.insertMailMessage(Self.message(kind: .alert, bulk: false), items: [])
        await db.close()
        #expect(!FileManager.default.fileExists(atPath: backups.path))
        let raw = try SQLiteConnection(path: url.path)
        let columns = try raw.query("SELECT name FROM pragma_table_info('mail_message')") { $0.string(0) }
        #expect(columns.contains("is_bulk"))
        // What an older build runs: its own column list, without is_bulk.
        let n = try raw.scalarInt("SELECT count(*) FROM mail_message WHERE internet_message_id IS NOT NULL")
        #expect(n == 2)
        try raw.run("""
            INSERT INTO mail_message(id, internet_message_id, from_address, received_at, created_at, updated_at, triage_consented)
            VALUES('m3', '<older-build@x>', 'a@x', '2026-09-30T10:00:00.000Z', '2026-09-30T10:00:00.000Z', '2026-09-30T10:00:00.000Z', 0)
            """)
        raw.close()
    }
}
