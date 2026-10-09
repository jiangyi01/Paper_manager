import Foundation
import Testing
@testable import PaperDeckCore

/// Review fixes without a sync loop: sender precedence (integrity-7), the sender-set coverage of
/// a cursor (integrity-1), bulk detection (K4), log-safe error text (safety-11), stored machine
/// text in the current language (runtime-7), bounded joins (runtime-5).
@Suite struct MailReviewFixesBUnitTests {

    // MARK: integrity-7

    @Test func aSpecificDomainRuleBeatsABroadWildcardPreset() {
        let preset = SenderRule(id: "preset-elsevier", pattern: "@*.elsevier.com", kind: .alert, aiPolicy: .always)
        let strict = SenderRule(id: "notification", pattern: "@notification.elsevier.com", kind: .alert, aiPolicy: .never)
        #expect(SenderMatcher.match(address: "x@notification.elsevier.com", rules: [preset, strict])?.id == "notification")
        #expect(SenderMatcher.match(address: "x@notification.elsevier.com", rules: [strict, preset])?.id == "notification")
        #expect(SenderMatcher.match(address: "x@mail.elsevier.com", rules: [preset, strict])?.id == "preset-elsevier")
        let wustl = SenderRule(id: "wustl", pattern: "@*.wustl.edu", kind: .person)
        let med = SenderRule(id: "med", pattern: "@med.wustl.edu", kind: .person, aiPolicy: .never)
        let prof = SenderRule(id: "prof", pattern: "prof@med.wustl.edu", kind: .advisor)
        #expect(SenderMatcher.match(address: "a@med.wustl.edu", rules: [wustl, med])?.id == "med")
        #expect(SenderMatcher.match(address: "prof@med.wustl.edu", rules: [wustl, med, prof])?.id == "prof")
    }

    // MARK: integrity-1

    @Test func senderCoverageDecidesWhetherTheLookbackIsListedAgain() {
        func fp(_ patterns: [String]) -> String {
            MailSyncActor.sendersFingerprint(patterns.map { SenderRule(pattern: $0, kind: .person) })
        }
        let saved = fp(["prof@wustl.edu", "@biorxiv.org", "@*.nature.com"])
        #expect(saved == "a:prof@wustl.edu\nd:biorxiv.org\nw:nature.com")
        #expect(MailSyncActor.sendersCovered(saved: saved, current: saved))
        #expect(MailSyncActor.sendersCovered(saved: saved, current: fp(["@biorxiv.org"])))              // removed
        #expect(MailSyncActor.sendersCovered(saved: saved, current: fp(["x@biorxiv.org"])))             // narrowed
        #expect(MailSyncActor.sendersCovered(saved: saved, current: fp(["@mail.nature.com", "@nature.com"])))
        #expect(MailSyncActor.sendersCovered(saved: saved, current: fp(["@*.alerts.nature.com"])))
        #expect(!MailSyncActor.sendersCovered(saved: saved, current: fp(["@wustl.edu"])))               // broadened
        #expect(!MailSyncActor.sendersCovered(saved: saved, current: fp(["@*.biorxiv.org"])))
        #expect(!MailSyncActor.sendersCovered(saved: saved, current: fp(["new@lab.org"])))              // added
        #expect(!MailSyncActor.sendersCovered(saved: nil, current: fp(["@biorxiv.org"])))               // unknown
        #expect(MailSyncActor.sendersCovered(saved: "", current: ""))
        var off = SenderRule(pattern: "new@lab.org", kind: .person)
        off.enabled = false
        #expect(MailSyncActor.sendersFingerprint([off]) == "")                                       // disabled: not listed
    }

    // MARK: K4

    /// Round 3 (safety-7 residual): only the list headers make mail "bulk". Precedence and
    /// Auto-Submitted alone no longer count — manuscript systems send confidential, automated mail
    /// with them (intended behaviour change; `R3ConfidentialityTests` covers the rest).
    @Test func bulkMailIsRecognizedByItsListHeaders() {
        #expect(MailSyncActor.isBulk(["list-id": "<q-bio.arxiv.org>"]))
        #expect(MailSyncActor.isBulk(["list-unsubscribe": "<mailto:u@x.org>"]))
        #expect(MailSyncActor.isBulk(["list-id": "<a.b>", "precedence": "bulk"]))
        #expect(!MailSyncActor.isBulk(["precedence": " Bulk "]))
        #expect(!MailSyncActor.isBulk(["precedence": "list"]))
        #expect(!MailSyncActor.isBulk(["auto-submitted": "auto-generated"]))
        #expect(!MailSyncActor.isBulk(["auto-submitted": "auto-replied; owner-email=x@y"]))
        #expect(!MailSyncActor.isBulk(["auto-submitted": "no"]))
        #expect(!MailSyncActor.isBulk(["auto-submitted": "No (comment)"]))
        #expect(!MailSyncActor.isBulk(["precedence": "first-class", "list-id": "  "]))
        #expect(!MailSyncActor.isBulk([:]))
    }

    // MARK: safety-11

    @Test func transportLogReasonsNeverQuoteFileNamesOrServerText() {
        let url = URL(fileURLWithPath: "/tmp/PaperDeck Mail/Re: Confidential – tenure letter.eml")
        let placeholder = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                                  userInfo: [NSURLErrorKey: url, NSFilePathErrorKey: url.path])
        #expect(placeholder.localizedDescription.contains("Confidential"))      // what used to be logged
        let reason = MailTransportLog.reason(placeholder)
        #expect(reason == "I/O error")
        #expect(MailSyncActor.logText(placeholder) == "I/O error")
        #expect(MailTransportLog.reason(IMAPError.authenticationFailed("[ALERT] user jane@wustl.edu locked")) == "imap login rejected")
        #expect(MailTransportLog.reason(IMAPError.protocolError("bad bytes 'Subject: secret'")) == "imap protocol error")
        #expect(MailTransportLog.reason(FolderMailSourceError.folderMissing("~/Secret Folder")) == "watched folder not found")
        #expect(MailTransportLog.reason(FileOpsError.timeout) == "timed out")
        #expect(MailTransportLog.reason(MIMEParser.ParseError.notAMessage) == "not an email")
        // The Settings status of an I/O error doesn't quote it either.
        let account = MailAccount(id: "f", kind: .folder, displayName: "F", folderPath: "/tmp/x")
        guard case .unavailable(let text) = MailSyncActor.status(for: FileOpsError.io("“Re: Confidential.eml” couldn’t be opened"),
                                                                 account: account, lang: .en) else {
            Issue.record("unavailable"); return
        }
        #expect(!text.contains("Confidential"))
    }

    // MARK: integrity-3

    @Test func folderProblemsMapToRetryOrSetup() {
        #expect(FolderMailSource.status(for: .folderMissing("~/OneDrive/PaperDeck Mail"), lang: .en)
                == .unavailable(FolderMailSourceError.folderMissing("~/OneDrive/PaperDeck Mail").message(lang: .en)))
        guard case .unavailable = FolderMailSource.status(for: .unreadable("x"), lang: .zh) else { Issue.record("unreadable"); return }
        guard case .needsSetup = FolderMailSource.status(for: .notConfigured, lang: .en) else { Issue.record("notConfigured"); return }
        guard case .needsSetup = FolderMailSource.status(for: .notAFolder("x"), lang: .en) else { Issue.record("notAFolder"); return }
        let account = MailAccount(id: "f", kind: .folder, displayName: "F", folderPath: "/tmp/x")
        guard case .unavailable = MailSyncActor.status(for: FolderMailSourceError.folderMissing("x"), account: account, lang: .en) else {
            Issue.record("sync status"); return
        }
        #expect(FolderMailSource.watchingDetail(folder: "PaperDeck Mail", messages: 1, lang: .en) == "Watching “PaperDeck Mail” · 1 email")
        #expect(FolderMailSource.watchingDetail(folder: "PaperDeck Mail", messages: 3, lang: .zh) == "正在监视「PaperDeck Mail」· 3 封邮件")
    }

    // MARK: integrity-9 text

    @Test func undownloadableTextIsWordedInBothLanguages() {
        #expect(MailSyncText.undownloadable(1, .en).hasPrefix("1 allowlisted email couldn't"))
        #expect(MailSyncText.undownloadable(2, .en).hasPrefix("2 allowlisted emails couldn't"))
        #expect(MailSyncText.undownloadable(2, .zh).contains("立即同步"))
        #expect(MailSyncText.undownloadable(2, .zh).hasPrefix("2 封"))
    }

    // MARK: runtime-7

    @Test func storedMachineTextFollowsTheCurrentLanguage() {
        let pairs: [(String, String)] = [
            (MailSyncText.dailyCapReached(used: 30, limit: 30, .en), MailSyncText.dailyCapReached(used: 30, limit: 30, .zh)),
            (MailPDFFetcher.Rejection.tooLarge(sizeBytes: 31 * 1_048_576).message(.en, capMB: 25),
             MailPDFFetcher.Rejection.tooLarge(sizeBytes: 31 * 1_048_576).message(.zh, capMB: 25)),
            (MailPDFFetcher.Rejection.notPDF.message(.en, capMB: 1), MailPDFFetcher.Rejection.notPDF.message(.zh, capMB: 1)),
            (MailSyncText.attachmentNotStored(.en), MailSyncText.attachmentNotStored(.zh)),
            (MailSyncText.triageFailed(.timeout, .en), MailSyncText.triageFailed(.timeout, .zh)),
            (MailSyncText.usageLimited(nil, .en), MailSyncText.usageLimited(nil, .zh)),
            (MailTriageRoute.modeOff(wanted: .claude).heldText(.en)!, MailTriageRoute.modeOff(wanted: .claude).heldText(.zh)!),
            (MailHeuristics.alertSummary(total: 12, highlighted: 3, lang: .en), MailHeuristics.alertSummary(total: 12, highlighted: 3, lang: .zh)),
            (MailHeuristics.alertSummary(total: 7, highlighted: 0, lang: .en), MailHeuristics.alertSummary(total: 7, highlighted: 0, lang: .zh)),
            (MailHeuristics.alertSummary(total: 1, highlighted: 1, lang: .en), MailHeuristics.alertSummary(total: 1, highlighted: 1, lang: .zh)),
            (MailHeuristics.alertSummary(total: 1, highlighted: 0, lang: .en), MailHeuristics.alertSummary(total: 1, highlighted: 0, lang: .zh)),
            (MailHeuristics.noRequestSummary(.en), MailHeuristics.noRequestSummary(.zh)),
            (MailHeuristics.containsPapersSummary(4, .en), MailHeuristics.containsPapersSummary(4, .zh)),
            (MailOpsText.downloadFailed(status: 403, .en), MailOpsText.downloadFailed(status: 403, .zh)),
        ]
        for (en, zh) in pairs {
            #expect(en != zh)
            #expect(MailMachineText.localized(en, .zh) == zh, "\(en)")
            #expect(MailMachineText.localized(zh, .en) == en, "\(zh)")
            #expect(MailMachineText.localized(en, .en) == en)
            #expect(MailMachineText.localized(zh, .zh) == zh)
        }
        // Anything else (an AI summary, a sentence of the email) is left alone.
        for other in ["Please read the attached paper before Thursday.", "请周四前读一下附件里的论文。",
                      "Alert digest with many papers.", "The attachment is big (limit 25 MB)."] {
            #expect(MailMachineText.localized(other, .zh) == other)
            #expect(MailMachineText.localized(other, .en) == other)
        }
    }

    @Test func cardsShowOnlyMachineFieldsInTheCurrentLanguage() {
        var m = MailMessage(accountID: "a", internetMessageID: "<x@y>", fromAddress: "a@b.org", senderKind: .alert,
                            subject: "Alert digest with 3 papers.", receivedAt: Date(), triageState: .held,
                            triageSource: .heuristic,
                            triage: MailTriage(hasReadingRequest: false, requestKind: .alertDigest,
                                               summary: MailHeuristics.alertSummary(total: 3, highlighted: 1, lang: .en),
                                               priority: .normal, confidence: 0.8))
        m.triageError = MailSyncText.dailyCapReached(used: 5, limit: 5, .en)
        let zh = MailMachineText.localized(m, .zh)
        #expect(zh.triage?.summary == MailHeuristics.alertSummary(total: 3, highlighted: 1, lang: .zh))
        #expect(zh.triageError == MailSyncText.dailyCapReached(used: 5, limit: 5, .zh))
        #expect(zh.subject == m.subject)                                         // mail content untouched
        // An AI summary is the model's text: never reworded.
        var ai = m
        ai.triageSource = .ai
        #expect(MailMachineText.localized(ai, .zh).triage?.summary == m.triage?.summary)
        let item = MailItem(ord: 1, cand: "c1", origin: .attachment, pdfState: .needsPDF,
                            downloadError: MailSyncText.attachmentNotStored(.zh))
        #expect(MailMachineText.localized([item], .en).first?.downloadError == MailSyncText.attachmentNotStored(.en))
        let info = MailAccountSyncInfo(id: "a", displayName: "A", kind: .imap, enabled: true,
                                       status: .unavailable(MailSyncText.fetchFailed(.en)))
        #expect(MailMachineText.localized(info, .zh).status == .unavailable(MailSyncText.fetchFailed(.zh)))
    }

    // MARK: runtime-5

    @Test func joinNeverWaitsOnATaskThatIgnoresCancellation() async {
        let clock = ContinuousClock()
        let t0 = clock.now
        // Load-tolerant (ENV-1): the stubborn tasks run 20 s, so finishing well before that proves the
        // join didn't wait for them, however slow the machine is.
        await MailSyncActor.join(RFB.stubbornTask(20), within: .milliseconds(400))
        #expect(clock.now - t0 < .seconds(10))
        // A cooperative task is waited for until it finished.
        let quick = Task<Void, Never> { try? await Task.sleep(for: .milliseconds(50)) }
        let t1 = clock.now
        await MailSyncActor.join(quick, within: .seconds(15))
        #expect(clock.now - t1 < .seconds(10))
        // Several tasks share one deadline.
        let t2 = clock.now
        await MailSyncActor.joinAll([RFB.stubbornTask(20), RFB.stubbornTask(20)], within: .milliseconds(400))
        #expect(clock.now - t2 < .seconds(10))
    }
}
