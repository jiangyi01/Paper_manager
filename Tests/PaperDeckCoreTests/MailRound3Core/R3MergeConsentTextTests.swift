import Foundation
import Testing
@testable import PaperDeckCore

/// Round 3: r3-7 (an automatic merge onto a paper in 最近删除 leaves the trashed paper alone — no
/// provenance, no toast — and the row waiting), r3-8 (「让 AI 分析」 racing 「忽略」: the consent
/// write refuses a dismissed / merged card in the same transaction) and r3-9 (an import failure
/// stored by an email merge follows the UI language at display time).
@Suite(.serialized) struct R3MergeConsentTextTests {
    typealias Kit = MailMergeKit
    typealias K = MailSyncKit

    // MARK: r3-7

    private static func deletedPaper(_ env: Kit.Env, bytes: Data) async throws -> Paper {
        let src = env.root.appendingPathComponent("old-\(UUID().uuidString).pdf")
        try bytes.write(to: src)
        let id = try #require(await env.engine.intake.ingest([.file(src)], options: ImportOptions(origin: .drop, ai: .skip)).added.first)
        await env.settle()
        _ = try await env.engine.softDelete(paperID: id)
        let p = try await env.paper(id)
        #expect(p.isDeleted)
        return p
    }

    @Test func anAutomaticMergeNeverTouchesAPaperInRecentlyDeleted() async throws {
        try await Kit.run { env in
            let bytes = Kit.pdfData(title: "Deleted on purpose, twice")
            let old = try await Self.deletedPaper(env, bytes: bytes)
            await env.settle()
            env.events.clear()
            let (message, items) = try await Kit.insert(env, Kit.message(kind: .advisor), items: [Kit.item(1)],
                                                        attachments: [0: bytes])
            let produced = try await env.engine.mergeAllMailItems(messageID: message.id,
                                                                  options: MailMergeOptions(priority: .high, readWithAI: false),
                                                                  userAction: false)
            await env.settle()
            #expect(produced.isEmpty)
            #expect(try await env.db.paperSources(paperPK: old.pk).isEmpty)        // no provenance on the trashed paper
            #expect(env.events.toasts.isEmpty, "\(env.events.toasts.map(\.message))")   // no 「已在最近删除中」 toast
            let row = try await env.item(items[0].id)
            #expect(row.status == .pending && row.pdfState == .hasPDF)
            #expect(row.downloadError == MailOpsText.inRecentlyDeleted(.en))
            let p = try await env.paper(old.id)
            #expect(p.isDeleted && p.priority != .high)

            // The user's merge restores it and records the provenance once.
            #expect(try await env.engine.mergeMailItem(itemID: items[0].id, options: MailMergeOptions(readWithAI: false)) == old.id)
            await env.settle()
            #expect(try await env.paper(old.id).isLive)
            #expect(try await env.db.paperSources(paperPK: old.pk).map(\.internetMessageID) == [message.internetMessageID])
        }
    }

    // MARK: r3-8

    @Test func aDismissLandingInsideTheConsentClickLeavesNoConsentAndNoHandOff() async throws {
        let mock = MockAgentProvider()
        try await R3.run(mode: .mock, mail: K.mailSettings(), mock: mock, start: false) { env in
            let m = try await RFAKit.insertAlert(R3MergeConsentTextTests.asK(env), 1, state: .awaitingConsent)
            let dbPath = env.paths.database.path
            // The dismiss commits (another connection) between requestAI's read and its write.
            env.hook.arm {
                guard let raw = try? SQLiteConnection(path: dbPath) else { return }
                try? raw.exec("PRAGMA busy_timeout = 3000")
                try? raw.run("UPDATE mail_message SET state = 'dismissed', user_touched = 1 WHERE pk = ?", [.integer(m.pk)])
                raw.close()
            }
            await #expect(throws: MailTriageError.cardClosed) { try await env.engine.requestMailAI(messageID: m.id) }
            let row = try #require(try await env.db.mailMessage(pk: m.pk))
            #expect(row.state == .dismissed)
            #expect(!row.triageConsented && row.triageConsentProvider == nil)
            #expect(row.triageStdinBytes == nil && row.triageState == .awaitingConsent)
            #expect(await env.engine.mailTriage.laneMessagePKs().isEmpty)
            #expect(await env.engine.mailTriage.usage().used == 0)
            #expect(await mock.calls == 0)
            // …and a closed card no longer offers the button (reopen it first).
            let card = try #require(try await env.engine.mailCard(id: m.id))
            #expect(card.canRequestAI == false)
            #expect(MailTriageError.cardClosed.message(.zh).contains("待处理"))
        }
    }

    /// `RFAKit.insertAlert` takes a `MailSyncKit.Env`; only `db` is used.
    fileprivate static func asK(_ env: R3.Env) -> K.Env {
        K.Env(engine: env.engine, root: env.root, clock: env.clock, settings: env.settings, mail: env.mail, sources: [:])
    }

    // MARK: r3-9

    @Test func importFailureReasonsAreWordedInEitherLanguage() {
        let producers: [(UILang) -> String] = [
            { IntakeText.reasonNotPDF($0) }, { IntakeText.reasonNotPDFLink($0) }, { IntakeText.reasonBlocked($0) },
            { IntakeText.reasonLinkNotPDF($0) }, { IntakeText.reasonAborted($0) }, { IntakeText.reasonLibraryWrite($0) },
            { IntakeText.reason(for: .diskFull, $0) }, { IntakeText.reason(for: .timeout, $0) },
            { IntakeText.reason(for: .sourceMissing, $0) }, { IntakeText.reason(for: .libraryUnavailable, $0) },
            { IntakeText.reason(for: .hashMismatch(expected: "a", actual: "b"), $0) }, { IntakeText.reason(for: .io("x"), $0) },
            { IntakeText.downloadFailed(status: nil, $0) }, { IntakeText.downloadFailed(status: 403, $0) },
        ]
        for p in producers {
            #expect(MailMachineText.localized(p(.en), .zh) == p(.zh), "\(p(.en))")
            #expect(MailMachineText.localized(p(.zh), .en) == p(.en), "\(p(.zh))")
        }
    }

    @Test func aStoredMergeFailureFollowsTheCurrentLanguage() async throws {
        try await Kit.run { env in
            let (message, items) = try await Kit.insert(env, Kit.message(kind: .advisor), items: [Kit.item(1)],
                                                        attachments: [0: Data("not a pdf at all".utf8)])
            let merged = try await env.engine.mergeMailItem(itemID: items[0].id, options: MailMergeOptions(readWithAI: false))
            await env.settle()
            #expect(merged == nil)
            let stored = try await env.item(items[0].id)
            #expect(stored.downloadError == IntakeText.reasonNotPDF(.en))          // stored in the language of the merge

            var zh = env.settings.value
            zh.lang = .zh
            env.settings.value = zh
            let card = try #require(try await env.engine.mailCard(id: message.id))
            #expect(card.items.first?.downloadError == IntakeText.reasonNotPDF(.zh))
            let snap = try await env.engine.mailSnapshot()
            #expect(snap.card(id: message.id)?.items.first?.downloadError == IntakeText.reasonNotPDF(.zh))
            try #require(items.count > 0)          // no index past a failed expectation (QA-15)
            #expect(try await env.item(items[0].id).downloadError == IntakeText.reasonNotPDF(.en))   // the row itself unchanged
        }
    }
}
