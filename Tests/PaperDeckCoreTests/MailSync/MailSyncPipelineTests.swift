import Foundation
import Testing
@testable import PaperDeckCore

/// MAIL_DESIGN Part A §2 end to end with fake transports: allowlist before any body is read,
/// Message-ID dedupe, cursor after commit, attachments + library matching, manual .eml import,
/// cadence / backoff. Mode off everywhere: zero AI.
@Suite(.serialized) struct MailSyncPipelineTests {
    typealias K = MailSyncKit

    // MARK: Privacy

    @Test func nonAllowlistedSenderIsNeverFetchedNorStored() async throws {
        try await K.run { env in
            let src = env.source()
            await src.add("stranger.eml", try K.data("stranger-secret"))
            await src.add("advisor.eml", try K.data("advisor-request-pdf"))
            await src.add("alert.eml", try K.data("biorxiv-alert"))
            await env.sync()

            // Phase 2 only for allowlisted headers — the key privacy guarantee.
            #expect(await src.fetched == ["advisor.eml", "alert.eml"])
            #expect(await src.captured == ["advisor.eml", "alert.eml"])
            let all = try await env.messages()
            #expect(all.count == 2)
            #expect(!all.contains { $0.fromAddress.contains("evil") || $0.subject.contains("SECRET") })
            #expect(try await env.db.mailMessage(internetMessageID: "<secret-91c2@evil.example>") == nil)
            // Nothing about the stranger reached disk (DB, WAL, cursor, attachment store).
            try? await env.db.checkpoint()
            let bytes = K.persistedBytes(env.root)
            for marker in ["SECRET-SUBJECT-91c2", "SECRET-BODY-91c2", "attacker@evil.example", "secret-91c2"] {
                #expect(bytes.range(of: Data(marker.utf8)) == nil, "\(marker) persisted")
            }
            // The cursor still moved past the stranger's message.
            #expect(try await env.db.mailCursor(accountID: "acct-a")?.value == "3")
        }
    }

    @Test func displayNameSpoofDoesNotPassTheAllowlist() async throws {
        // "Prof. Jane Smith" <attacker@…> must not match the advisor rule (address part only).
        var mail = K.mailSettings()
        mail.senders = [SenderRule(id: "r", pattern: "Prof. Jane Smith", kind: .advisor)] + mail.senders
        try await K.run(mail: mail) { env in
            await env.source().add("stranger.eml", try K.data("stranger-secret"))
            await env.sync()
            #expect(await env.source().fetched.isEmpty)
            #expect(try await env.messages().isEmpty)
        }
    }

    // MARK: Dedupe / cursor

    @Test func sameMessageFromTwoSourcesIsCapturedOnce() async throws {
        let mail = K.mailSettings(accounts: [K.account("acct-a"), K.account("acct-b")])
        try await K.run(mail: mail, accounts: ["acct-a", "acct-b"]) { env in
            let a = env.source("acct-a"), b = env.source("acct-b")
            let alert = try K.data("biorxiv-alert")
            await a.add("a1.eml", alert)
            await b.add("b1.eml", alert)
            await b.add("b2.eml", try K.data("arxiv-listing"))
            await env.sync()

            #expect(try await env.messages().count == 2)
            #expect(await a.fetched == ["a1.eml"])
            #expect(await b.fetched == ["b2.eml"])                 // the duplicate's body is never re-read
            #expect(await b.captured == ["b1.eml", "b2.eml"])      // …but it counts as captured there too
            let m = try await env.message("<alert.20260930.998877@alerts.highwire.org>")
            #expect(m.accountID == "acct-a")
            #expect(m.sourceRef == "a1.eml")

            // Re-sync from scratch: idempotent.
            try await env.db.setMailCursor(accountID: "acct-a", nil)
            await env.sync()
            #expect(try await env.messages().count == 2)
            #expect(await a.fetched == ["a1.eml"])
        }
    }

    @Test func cursorIsSavedOnlyAfterThePageCommitted() async throws {
        try await K.run { env in
            let src = env.source()
            await src.add("m1.eml", try K.data("biorxiv-alert"))
            await src.add("m2.eml", try K.data("arxiv-listing"))
            await src.failFetch("m2.eml", times: 1)
            await env.sync()

            // m1 committed, m2 failed transiently → the page is not done: no cursor, error status.
            #expect(try await env.messages().count == 1)
            #expect(try await env.db.mailCursor(accountID: "acct-a") == nil)
            #expect(await src.captured == ["m1.eml"])
            var info = try #require(await env.engine.mail.accountSyncInfo().first)
            #expect(info.consecutiveFailures == 1)
            #expect(info.nextRetryAt != nil)
            guard case .unavailable = info.status else { Issue.record("status \(String(describing: info.status))"); return }

            // Next pass: the page is listed again from the old cursor; m1 is not fetched twice.
            await env.sync()
            #expect(try await env.messages().count == 2)
            #expect(try await env.db.mailCursor(accountID: "acct-a")?.value == "2")
            #expect(await src.fetched == ["m1.eml", "m2.eml", "m2.eml"])
            #expect(await src.cursorsSeen == [nil, nil])
            info = try #require(await env.engine.mail.accountSyncInfo().first)
            #expect(info.consecutiveFailures == 0)
            #expect(info.lastCaptured == 1)
            #expect(info.totalCaptured == 2)
            guard case .ready = info.status else { Issue.record("status \(String(describing: info.status))"); return }
        }
    }

    /// Fallback for a transport that can't keep a message listable (`deferring` → nil, like this
    /// fake): the poison-message guard gives it up. The folder and IMAP sources defer it instead —
    /// retried on a long backoff and surfaced after a day (MailReviewFixesBSyncTests).
    @Test func aMessageThatKeepsFailingIsGivenUpSoTheCursorMoves() async throws {
        try await K.run { env in
            await env.engine.mail.configure(MailSyncActor.Tuning(maxFetchAttempts: 2))
            let src = env.source()
            await src.add("bad.eml", try K.data("biorxiv-alert"))
            await src.add("ok.eml", try K.data("arxiv-listing"))
            await src.failFetch("bad.eml", times: 10)
            await env.sync()
            #expect(try await env.db.mailCursor(accountID: "acct-a") == nil)
            await env.sync()                        // second failure: given up
            #expect(try await env.db.mailCursor(accountID: "acct-a")?.value == "2")
            #expect(try await env.messages().map(\.sourceRef) == ["ok.eml"])
        }
    }

    @Test func aMessageDeletedOnTheServerIsSkippedAtOnce() async throws {
        try await K.run { env in
            let src = env.source()
            await src.add("gone.eml", try K.data("biorxiv-alert"))
            await src.add("ok.eml", try K.data("arxiv-listing"))
            await src.vanish("gone.eml")
            await env.sync()
            #expect(try await env.db.mailCursor(accountID: "acct-a")?.value == "2")
            #expect(try await env.messages().map(\.sourceRef) == ["ok.eml"])
            #expect(await env.engine.mail.accountSyncInfo().first?.consecutiveFailures == 0)
        }
    }

    @Test func aLongBackfillContinuesWithoutWaitingForTheNextInterval() async throws {
        var mail = K.mailSettings()
        mail.syncMinutes = 60
        let env = try await K.make(mail: mail, start: false)
        do {
            await env.engine.mail.configure(MailSyncActor.Tuning(pageLimit: 1, maxPagesPerSync: 1, backfillPause: 0.05))
            let src = env.source()
            await src.add("m1.eml", try K.data("biorxiv-alert"))
            await src.add("m2.eml", try K.data("arxiv-listing"))
            await src.add("m3.eml", try K.data("colleague-share"))
            await env.engine.start()
            #expect(await K.eventually { (try await env.messages().count) == 3 })
            #expect(await src.cursorsSeen == [nil, "1", "2"])
            try await Task.sleep(for: .milliseconds(300))
            #expect(await src.listCalls == 3)                  // caught up: back to the hourly cadence
        } catch {
            await env.cleanup()
            throw error
        }
        await env.cleanup()
    }

    @Test func pagesAreFollowedAndACursorChangeOfAccountStartsOver() async throws {
        try await K.run { env in
            await env.engine.mail.configure(MailSyncActor.Tuning(pageLimit: 1))
            let src = env.source()
            await src.add("m1.eml", try K.data("biorxiv-alert"))
            await src.add("m2.eml", try K.data("arxiv-listing"))
            await src.add("m3.eml", try K.data("colleague-share"))
            await env.sync()
            #expect(await src.cursorsSeen == [nil, "1", "2"])
            #expect(try await env.messages().count == 3)

            // A different watched folder is a different mailbox: its cursor starts over.
            env.mail.update { $0.accounts[0].folderPath = "/elsewhere" }
            await env.sync()
            #expect(await src.cursorsSeen.suffix(3) == [nil, "1", "2"])
            #expect(try await env.messages().count == 3)
        }
    }

    // MARK: Attachments / library

    @Test func pdfAttachmentIsStoredAndMatchedToTheLibraryBySHA() async throws {
        try await K.run { env in
            let pdf = try K.advisorAttachment()
            let paper = try await K.addPaper(env, sha256: FileOps.sha256(of: pdf))
            await env.source().add("advisor.eml", try K.data("advisor-request-pdf"))
            await env.sync()

            let m = try await env.message("<caf3xyz+abc123@mail.gmail.com>")
            #expect(m.senderKind == .advisor)
            #expect(m.ruleID == K.advisorRule.id)
            #expect(m.authState == .pass)
            #expect(m.state == .pending)
            #expect(m.triageSource == .heuristic)
            #expect(m.triage?.hasReadingRequest == true)
            #expect(m.triageState == .awaitingConsent)          // a person: AI only after consent
            #expect(m.bodyText?.contains("555-0199") == false)  // redacted by the extractor

            let items = try await env.db.mailItems(messagePK: m.pk)
            let att = try #require(items.first { $0.origin == .attachment })
            let path = try #require(att.pdfPath)
            #expect(path == "\(m.id)/1.pdf")
            let stored = try Data(contentsOf: env.engine.paths.mailFiles.appendingPathComponent(path))
            #expect(stored == pdf)
            #expect(att.pdfSHA256 == FileOps.sha256(of: pdf))
            #expect(att.pdfBytes == Int64(pdf.count))
            #expect(att.pdfState == .inLibrary)
            #expect(att.paperID == paper.id)

            // The bioRxiv link is downloadable by the rules (never fetched here).
            let link = try #require(items.first { $0.ids.doi == "10.1101/2026.09.14.612345" })
            #expect(link.pdfState == .downloadable)
            #expect(link.urlOriginal?.contains("utm_source") == true)
        }
    }

    @Test func libraryMatchByDOICrossesTheBiorxivPrefixes() async throws {
        try await K.run { env in
            // The library knows the preprint under bioRxiv's new prefix.
            let paper = try await K.addPaper(env, doi: "10.64898/2026.09.25.614123")
            await env.source().add("alert.eml", try K.data("biorxiv-alert"))
            await env.sync()
            let m = try await env.message("<alert.20260930.998877@alerts.highwire.org>")
            let items = try await env.db.mailItems(messagePK: m.pk)
            let hit = try #require(items.first { $0.ids.doi?.hasSuffix("2026.09.25.614123") == true })
            #expect(hit.pdfState == .inLibrary)
            #expect(hit.paperID == paper.id)
            #expect(items.filter { $0.pdfState == .inLibrary }.count == 1)
        }
    }

    @Test func firstPageOfAStoredPDFEnrichesItsRow() async throws {
        let pdf = K.FakePDF(title: "Molecular and cellular dynamics of the developing human neocortex",
                            doi: "10.1038/s41586-024-08351-7")
        try await K.run(pdf: pdf) { env in
            let paper = try await K.addPaper(env, doi: "10.1038/s41586-024-08351-7")
            await env.source().add("advisor.eml", try K.data("advisor-request-pdf"))
            await env.sync()
            let m = try await env.message("<caf3xyz+abc123@mail.gmail.com>")
            let att = try #require(try await env.db.mailItems(messagePK: m.pk).first { $0.origin == .attachment })
            #expect(att.title == "Molecular and cellular dynamics of the developing human neocortex")
            #expect(att.ids.doi == "10.1038/s41586-024-08351-7")
            #expect(att.metaSource == .pdf)
            #expect(att.pdfState == .inLibrary)
            #expect(att.paperID == paper.id)
        }
    }

    @Test func attachmentsOverTheCapAreNotStored() async throws {
        var mail = K.mailSettings()
        mail.maxAttachmentMB = 1
        try await K.run(mail: mail) { env in
            // A 1.5 MB "PDF": over the 1 MB cap.
            let big = Data("%PDF-1.4\n".utf8) + Data(repeating: 0x41, count: 1_500_000) + Data("\n%%EOF\n".utf8)
            let eml = Self.emlWithAttachment(big, from: "jsmith@wustl.edu", messageID: "<big-1@wustl.edu>")
            await env.source().add("big.eml", eml)
            await env.sync()
            let m = try await env.message("<big-1@wustl.edu>")
            let att = try #require(try await env.db.mailItems(messagePK: m.pk).first { $0.origin == .attachment })
            #expect(att.pdfPath == nil)
            #expect(att.pdfState == .needsPDF)
            #expect(att.downloadError?.contains("1 MB") == true, "\(String(describing: att.downloadError)) \(att.pdfBytes ?? -1)")
            let dir = env.engine.paths.mailFiles.appendingPathComponent(m.id)
            #expect(!FileManager.default.fileExists(atPath: dir.path))
        }
    }

    @Test func aNonPDFPretendingToBeAPDFIsRejected() async throws {
        try await K.run { env in
            let eml = Self.emlWithAttachment(Data("MZ this is not a pdf".utf8), from: "jsmith@wustl.edu",
                                             messageID: "<fake-pdf@wustl.edu>")
            await env.source().add("fake.eml", eml)
            await env.sync()
            let m = try await env.message("<fake-pdf@wustl.edu>")
            let att = try #require(try await env.db.mailItems(messagePK: m.pk).first { $0.origin == .attachment })
            #expect(att.pdfPath == nil)
            #expect(att.pdfState == .needsPDF)
            #expect(att.downloadError == "The attachment isn't a PDF file")
            #expect(att.pdfBytes == Int64("MZ this is not a pdf".utf8.count))
        }
    }

    // MARK: Heuristic state

    @Test func alertWithoutPapersGoesToNoRequestAndIsNotSentToAI() async throws {
        try await K.run(mode: .mock) { env in
            let text = """
                From: bioRxiv <biorxiv@alerts.highwire.org>
                Subject: Your bioRxiv account
                Date: Wed, 30 Sep 2026 05:00:00 +0000
                Message-ID: <acct-notice@alerts.highwire.org>
                List-Unsubscribe: <mailto:unsubscribe@alerts.highwire.org>
                Content-Type: text/plain; charset=utf-8

                Your password was changed. No papers today.
                """
            await env.source().add("notice.eml", Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8))
            await env.sync()
            let m = try await env.message("<acct-notice@alerts.highwire.org>")
            #expect(m.state == .noRequest)
            #expect(m.handledAt != nil)
            #expect(m.triageState == .skipped)
        }
    }

    // MARK: Ready hook (sender auto-merge)

    @Test func readyHookRunsOnceForPendingCardsAfterPostProcessing() async throws {
        final class Calls: @unchecked Sendable {
            let lock = NSLock()
            var list: [(String, String?, Bool)] = []
        }
        let calls = Calls()
        try await K.run { env in
            await env.engine.mail.setOnMessageReady { message, rule in
                let enriched = ((try? await env.db.mailItems(messagePK: message.pk)) ?? []).contains { $0.pdfState == .inLibrary }
                calls.lock.withLock { calls.list.append((message.internetMessageID, rule?.id, enriched)) }
            }
            try await K.addPaper(env, doi: "10.1101/2026.09.14.612345")
            await env.source().add("advisor.eml", try K.data("advisor-request-pdf"))
            let notice = """
                From: bioRxiv <biorxiv@alerts.highwire.org>
                Subject: Account notice
                Date: Wed, 30 Sep 2026 05:00:00 +0000
                Message-ID: <notice-3@alerts.highwire.org>
                List-Unsubscribe: <mailto:unsubscribe@alerts.highwire.org>
                Content-Type: text/plain; charset=utf-8

                Nothing to read today.
                """
            await env.source().add("notice.eml", Data(notice.replacingOccurrences(of: "\n", with: "\r\n").utf8))
            await env.sync()
            let got = calls.lock.withLock { calls.list }
            #expect(got.count == 1)                           // the no-request notice is not offered
            #expect(got.first?.0 == "<caf3xyz+abc123@mail.gmail.com>")
            #expect(got.first?.1 == K.advisorRule.id)
            #expect(got.first?.2 == true)                     // after library matching
        }
    }

    @Test func senderAutoMergeImportsPDFReadyRowsWithoutTouchingTheCard() async throws {
        var mail = K.mailSettings()
        var advisor = K.advisorRule
        advisor.autoMerge = true
        mail.senders = [advisor] + mail.senders.filter { $0.id != advisor.id }
        try await K.run(mail: mail) { env in
            let pdf = K.realPDF(title: "Cortical progenitor dynamics in the developing human brain")
            await env.source().add("auto.eml", Self.emlWithAttachment(pdf, from: "jsmith@wustl.edu",
                                                                      messageID: "<auto-1@wustl.edu>"))
            await env.sync()
            let m = try await env.message("<auto-1@wustl.edu>")
            let att = try #require(try await env.db.mailItems(messagePK: m.pk).first { $0.origin == .attachment })
            #expect(await K.eventually { (try await env.db.mailItem(id: att.id))?.status == .merged })
            let paper = try #require(try await env.db.livePapers().first)
            #expect(try await env.db.livePapers().count == 1)
            #expect(paper.priority == .high)                    // the advisor rule's default
            #expect(try await env.db.paperSources(paperPK: paper.pk).first?.internetMessageID == m.internetMessageID)
            #expect(try await env.message(m.internetMessageID).userTouched == false)
        }
    }

    // MARK: Manual .eml

    @Test func importEMLRunsThePipelineWithoutTheAllowlist() async throws {
        var mail = K.mailSettings()
        mail.enabled = false                                  // manual import works even with sync off
        try await K.run(mail: mail) { env in
            let dir = env.root.appendingPathComponent("drops", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stranger = dir.appendingPathComponent("stranger.eml")
            let advisor = dir.appendingPathComponent("advisor.eml")
            let junk = dir.appendingPathComponent("junk.eml")
            try K.data("stranger-secret").write(to: stranger)
            try K.data("advisor-request-pdf").write(to: advisor)
            try Data().write(to: junk)

            let ids = await env.engine.mail.importEML([stranger, advisor, junk])
            #expect(ids.count == 2)
            await env.engine.mail.waitUntilIdle()
            let s = try await env.message("<secret-91c2@evil.example>")
            #expect(s.senderKind == .manual)
            #expect(s.accountID == MailSyncActor.manualAccountID)
            #expect(s.ruleID == nil)
            #expect(s.state == .pending)                        // explicit intent: always visible
            #expect(s.triageState == .awaitingConsent)
            let a = try await env.message("<caf3xyz+abc123@mail.gmail.com>")
            #expect(a.senderKind == .advisor)                   // the matching rule's kind
            #expect(a.ruleID == K.advisorRule.id)
            #expect(try await env.db.mailItems(messagePK: a.pk).contains { $0.pdfPath != nil })

            // Dropping the same file again returns the existing card.
            #expect(await env.engine.mail.importEML([advisor]) == [a.id])
            #expect(try await env.messages().count == 2)
            #expect(await env.source().listCalls == 0)          // sync is off
        }
    }

    // MARK: Status / backoff / cadence

    @Test func signInProblemsWaitForNewSettingsInsteadOfRetrying() async throws {
        try await K.run { env in
            let src = env.source()
            await src.setStatus(.authFailed("Gmail rejected the app password"))
            await env.sync()
            var info = try #require(await env.engine.mail.accountSyncInfo().first)
            #expect(info.waitingForSettings)
            #expect(info.status == .authFailed("Gmail rejected the app password"))
            #expect(await env.engine.mail.accountStatuses()["acct-a"] == .authFailed("Gmail rejected the app password"))
            #expect(await src.listCalls == 0)

            // New app password saved → 立即同步 works again.
            await src.setStatus(.ready(detail: "Signed in"))
            await env.sync()
            info = try #require(await env.engine.mail.accountSyncInfo().first)
            #expect(!info.waitingForSettings)
            #expect(info.status == .ready(detail: "Signed in"))
            #expect(await src.listCalls == 1)
        }
    }

    @Test func listErrorsBackOffExponentially() async throws {
        var mail = K.mailSettings()
        mail.syncMinutes = 15
        let env = try await K.make(mail: mail, start: false)
        do {
            let src = env.source()
            await src.setListError(URLError(.notConnectedToInternet))
            await env.engine.start()                          // the launch pass syncs the due account
            #expect(await K.eventually { (await env.engine.mail.accountSyncInfo().first?.consecutiveFailures) == 1 })
            let first = try #require(await env.engine.mail.accountSyncInfo().first)
            let retry1 = try #require(first.nextRetryAt)
            #expect(abs(retry1.timeIntervalSince(env.clock.value) - 60) < 1)
            await env.sync()                                  // forced: counts as another failure
            let second = try #require(await env.engine.mail.accountSyncInfo().first)
            #expect(second.consecutiveFailures == 2)
            #expect(abs(try #require(second.nextRetryAt).timeIntervalSince(env.clock.value) - 120) < 1)

            // Not due while backing off.
            await src.setListError(nil)
            await env.engine.mail.appDidBecomeActive()
            try await Task.sleep(for: .milliseconds(100))
            #expect(await env.engine.mail.accountSyncInfo().first?.consecutiveFailures == 2)
            // Recovered: the next due pass clears the backoff.
            env.advance(121)
            await env.engine.mail.appDidBecomeActive()
            #expect(await K.eventually { (await env.engine.mail.accountSyncInfo().first?.consecutiveFailures) == 0 })
        } catch {
            await env.cleanup()
            throw error
        }
        await env.cleanup()
    }

    @Test func manualModeNeverSyncsByItself() async throws {
        try await K.run { env in                              // syncMinutes 0
            await env.source().add("m1.eml", try K.data("biorxiv-alert"))
            await env.engine.mail.appDidBecomeActive()
            await env.engine.mail.settingsDidChange()
            try await Task.sleep(for: .milliseconds(150))
            #expect(await env.source().listCalls == 0)
            await env.sync()
            #expect(await env.source().listCalls == 1)
        }
    }

    @Test func dueAccountsSyncOnTheirCadence() async throws {
        var mail = K.mailSettings()
        mail.syncMinutes = 15
        try await K.run(mail: mail) { env in
            // The launch pass syncs a due account by itself.
            #expect(await K.eventually { await env.source().listCalls == 1 })
            env.advance(10 * 60)
            await env.engine.mail.settingsDidChange()
            try await Task.sleep(for: .milliseconds(100))
            #expect(await env.source().listCalls == 1)        // not due yet
            env.advance(6 * 60)
            await env.engine.mail.settingsDidChange()
            #expect(await K.eventually { await env.source().listCalls == 2 })
        }
    }

    // MARK: Real folder source

    @Test func watchedFolderEndToEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-mailsync-\(UUID().uuidString)",
                                                                                 isDirectory: true)
        let folder = root.appendingPathComponent("PaperDeck Mail", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try K.data("stranger-secret").write(to: folder.appendingPathComponent("SECRET-SUBJECT-91c2.eml"))
        try K.data("biorxiv-alert").write(to: folder.appendingPathComponent("bioRxiv alert.eml"))
        // Written "a minute ago" so the settle window has passed.
        let past = Date().addingTimeInterval(-60)
        for name in ["SECRET-SUBJECT-91c2.eml", "bioRxiv alert.eml"] {
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: folder.appendingPathComponent(name).path)
        }
        let account = MailAccount(id: "washu-pa", kind: .folder, displayName: "WashU (Power Automate)",
                                  folderPath: folder.path, deleteProcessedFiles: true)
        let env = try await K.make(mail: K.mailSettings(accounts: [account]), accounts: [], root: root, realSources: true)
        do {
            await env.sync()
            let all = try await env.messages()
            #expect(all.map(\.internetMessageID) == ["<alert.20260930.998877@alerts.highwire.org>"])
            #expect(all.first?.accountID == "washu-pa")
            #expect(all.first?.sourceRef == "bioRxiv alert.eml")
            // Captured files are deleted (the account says so); the stranger's file is left alone.
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("bioRxiv alert.eml").path))
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("SECRET-SUBJECT-91c2.eml").path))
            // The cursor ledger stores hashed names only.
            let cursor = try #require(try await env.db.mailCursor(accountID: "washu-pa")).value
            #expect(!cursor.contains("SECRET") && !cursor.contains("bioRxiv"))
            guard case .ready = await env.engine.mail.accountStatuses()["washu-pa"] else {
                Issue.record("status not ready")
                await env.cleanup()
                return
            }
            // Idempotent: nothing new on the next pass.
            await env.sync()
            #expect(try await env.messages().count == 1)
        } catch {
            await env.cleanup()
            throw error
        }
        await env.cleanup()
    }

    @Test func missingWatchedFolderIsRetriedNotParked() async throws {
        let account = MailAccount(id: "gone", kind: .folder, displayName: "Gone", folderPath: "/nonexistent/pd-mail-\(UUID().uuidString)")
        let env = try await K.make(mail: K.mailSettings(accounts: [account]), accounts: [], realSources: true)
        do {
            await env.sync()
            let info = try #require(await env.engine.mail.accountSyncInfo().first)
            guard case .unavailable(let why) = info.status else {
                Issue.record("status \(String(describing: info.status))")
                await env.cleanup()
                return
            }
            #expect(why.contains("Folder not found"))
            #expect(!info.waitingForSettings)               // OneDrive may not be there yet: backoff, not parked
            #expect(info.nextRetryAt != nil)
        } catch {
            await env.cleanup()
            throw error
        }
        await env.cleanup()
    }

    // MARK: Helpers

    static func emlWithAttachment(_ pdf: Data, from: String, messageID: String) -> Data {
        let b64 = pdf.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        let text = """
            From: Jane Smith <\(from)>
            To: yi@wustl.edu
            Subject: Paper for you
            Date: Tue, 29 Sep 2026 14:05:00 -0500
            Message-ID: \(messageID)
            MIME-Version: 1.0
            Content-Type: multipart/mixed; boundary="b1"

            --b1
            Content-Type: text/plain; charset=utf-8

            Please read the attached paper.

            --b1
            Content-Type: application/pdf; name="paper.pdf"
            Content-Disposition: attachment; filename="paper.pdf"
            Content-Transfer-Encoding: base64

            """
        // The literal ends right after the part headers: one CRLF more makes the blank separator line.
        return Data((text.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n" + b64 + "\r\n--b1--\r\n").utf8)
    }
}
