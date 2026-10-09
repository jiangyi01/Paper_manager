import Foundation
import Testing
@testable import PaperDeckCore

/// One retention path: launch maintenance and the sync loop both run `Maintenance.mailRetention`
/// (the loop once per local day, `unsnoozeDue` on its other ticks). Handled cards past the
/// retention lose body and attachment copies; open cards never do; nothing outside
/// `AppPaths.mailFiles` is touched; `retentionDays ≤ 0` keeps everything.
@Suite struct MailFixesRetentionTests {
    private typealias Kit = MailFixesKit

    private static func settings(retention: Int) -> MailSettings {
        MailSettings(enabled: true, accounts: [], syncMinutes: 0, retentionDays: retention)
    }

    /// A card with one stored attachment copy; returns the card and the copy's URL.
    private static func card(_ env: Kit.Env, state: MailState, handledDaysAgo: Double?, snoozedUntil: Date? = nil,
                             subject: String = "Card") async throws -> (MailMessage, URL) {
        let handled = handledDaysAgo.map { Kit.start.addingTimeInterval(-$0 * Kit.day) }
        let (m, items) = try await Kit.insert(env, Kit.message(subject: subject, state: state, handledAt: handled,
                                                               snoozedUntil: snoozedUntil),
                                              items: [Kit.item(1, origin: .attachment, pdf: .hasPDF)], files: [0: Kit.pdfStub])
        return (m, env.mailFiles.appendingPathComponent(try #require(items[0].pdfPath)))
    }

    @Test func theLoopRunsTheEngineRetentionOncePerDayAndWakesSnoozedCardsEachTick() async throws {
        try await Kit.run(mail: Self.settings(retention: 30)) { env in
            let (merged, mergedFile) = try await Self.card(env, state: .merged, handledDaysAgo: 40, subject: "Old merged")
            let (dismissed, dismissedFile) = try await Self.card(env, state: .dismissed, handledDaysAgo: 31)
            let (recent, recentFile) = try await Self.card(env, state: .noRequest, handledDaysAgo: 10)
            let (pending, pendingFile) = try await Self.card(env, state: .pending, handledDaysAgo: nil)
            let (snoozed, snoozedFile) = try await Self.card(env, state: .snoozed, handledDaysAgo: nil,
                                                             snoozedUntil: Kit.start.addingTimeInterval(-60))

            await env.engine.mail.syncNow()                    // first pass today: the engine's retention
            #expect(!Kit.exists(mergedFile) && !Kit.exists(mergedFile.deletingLastPathComponent()))
            #expect(!Kit.exists(dismissedFile))
            let m = try await env.message(merged.id)
            #expect(m.bodyText == nil && m.bodyPurged && m.subject == "Old merged")
            let row = try #require(try await env.db.mailItems(messagePK: merged.pk).first)
            #expect(row.pdfPath == nil && row.pdfState == .needsPDF)
            #expect(try await env.message(dismissed.id).bodyPurged)
            #expect(Kit.exists(recentFile) && Kit.exists(pendingFile) && Kit.exists(snoozedFile))
            #expect(try await env.message(recent.id).bodyText != nil)
            #expect(try await env.message(pending.id).bodyText != nil)
            #expect(try await env.message(snoozed.id).state == .pending)       // woken by the same pass

            // Later the same day: retention does not run again, the snooze wake-up does.
            let (late, lateFile) = try await Self.card(env, state: .merged, handledDaysAgo: 45)
            let (nap, _) = try await Self.card(env, state: .snoozed, handledDaysAgo: nil,
                                               snoozedUntil: Kit.start.addingTimeInterval(3_600))
            env.advance(2 * 3_600)
            await env.engine.mail.syncNow()
            #expect(Kit.exists(lateFile))
            #expect(try await env.message(late.id).bodyText != nil)
            #expect(try await env.message(nap.id).state == .pending)

            // The next local day: it runs again.
            env.advance(Kit.day)
            await env.engine.mail.syncNow()
            #expect(!Kit.exists(lateFile))
            #expect(try await env.message(late.id).bodyPurged)
            #expect(Kit.exists(pendingFile) && Kit.exists(snoozedFile))
        }
    }

    @Test func retentionZeroOrLessKeepsEverything() async throws {
        for days in [0, -1] {
            try await Kit.run(mail: Self.settings(retention: days)) { env in
                let (merged, file) = try await Self.card(env, state: .merged, handledDaysAgo: 400)
                let orphan = env.mailFiles.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
                try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * Kit.day)],
                                                      ofItemAtPath: orphan.path)
                let (snoozed, _) = try await Self.card(env, state: .snoozed, handledDaysAgo: nil,
                                                       snoozedUntil: Kit.start.addingTimeInterval(-1))
                await env.engine.mail.syncNow()
                #expect(Kit.exists(file) && Kit.exists(orphan))
                #expect(try await env.message(merged.id).bodyText != nil)
                #expect(try await env.message(snoozed.id).state == .pending)    // the wake-up still runs
            }
        }
    }

    @Test func nothingOutsideTheMailFilesFolderIsEverDeleted() async throws {
        try await Kit.run(mail: Self.settings(retention: 7)) { env in
            // A stored path that tries to leave mailFiles (a corrupted / hostile row).
            let outside = env.mailFiles.deletingLastPathComponent().appendingPathComponent("outside.pdf")
            try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Kit.pdfStub.write(to: outside)
            let (m, items) = try await Kit.insert(env, Kit.message(state: .merged, handledAt: Kit.start.addingTimeInterval(-30 * Kit.day)),
                                                  items: [Kit.item(1, origin: .attachment, pdf: .hasPDF)])
            var row = items[0]
            row.pdfPath = "../outside.pdf"
            _ = try await env.db.upsertMailItem(row, now: Kit.start)
            // Non-message folders under mailFiles are left alone too.
            let stray = env.mailFiles.appendingPathComponent("not-a-message", isDirectory: true)
            try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * Kit.day)],
                                                  ofItemAtPath: stray.path)

            await env.engine.mail.syncNow()
            #expect(Kit.exists(outside) && Kit.exists(stray))
            #expect(try await env.db.mailItems(messagePK: m.pk).first?.pdfPath == nil)   // the row no longer points anywhere
        }
    }

    @Test func leftoverFoldersOfVanishedCardsGoOnceOld() async throws {
        try await Kit.run(mail: Self.settings(retention: 30)) { env in
            func folder(_ id: String, ageDays: Double) throws -> URL {
                let dir = env.mailFiles.appendingPathComponent(id, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Kit.pdfStub.write(to: dir.appendingPathComponent("0.pdf"))
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ageDays * Kit.day)],
                                                      ofItemAtPath: dir.path)
                return dir
            }
            let oldOrphan = try folder(UUID().uuidString.lowercased(), ageDays: 3)
            let youngOrphan = try folder(UUID().uuidString.lowercased(), ageDays: 0.1)    // a capture in progress
            let (pending, pendingFile) = try await Self.card(env, state: .pending, handledDaysAgo: nil)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-5 * Kit.day)],
                                                  ofItemAtPath: pendingFile.deletingLastPathComponent().path)

            await env.engine.mail.syncNow()
            #expect(!Kit.exists(oldOrphan))
            #expect(Kit.exists(youngOrphan))
            #expect(Kit.exists(pendingFile))
            #expect(try await env.message(pending.id).state == .pending)
        }
    }

    @Test func launchMaintenanceCountsAsTodaysRetention() async throws {
        try await Kit.run(mail: Self.settings(retention: 30)) { env in
            await env.engine.start()                           // onLaunch ran the retention for today
            let (late, lateFile) = try await Self.card(env, state: .merged, handledDaysAgo: 60)
            await env.engine.mail.syncNow()
            #expect(Kit.exists(lateFile))
            env.advance(Kit.day)
            await env.engine.mail.syncNow()
            #expect(!Kit.exists(lateFile))
            #expect(try await env.message(late.id).bodyPurged)
        }
    }
}
