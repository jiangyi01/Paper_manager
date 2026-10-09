import Foundation
import Testing
@testable import PaperDeckCore

/// Pure pieces of the sync slice: attachment validation and paths, PDF availability rules,
/// cursor fingerprints, web links, the triage policy tables and the inbox filter mapping.
@Suite struct MailSyncUnitTests {
    private let uuid = "0f3c2a4e-8d1b-4c5e-9a7f-1234567890ab"

    @Test func storedPathsCannotEscapeTheMailFilesFolder() {
        let files = MailPDFFetcher(root: URL(fileURLWithPath: "/tmp/pd-mail-files", isDirectory: true))
        #expect(files.url(forRelative: "\(uuid)/1.pdf")?.path == "/tmp/pd-mail-files/\(uuid)/1.pdf")
        for bad in ["../1.pdf", "\(uuid)/../../x.pdf", "\(uuid)/1.txt", "not-a-uuid/1.pdf", "\(uuid)/.hidden.pdf",
                    "\(uuid.uppercased())/1.pdf", "\(uuid)/a/1.pdf", "/\(uuid)/1.pdf", ""] {
            #expect(files.url(forRelative: bad) == nil, "\(bad)")
        }
        #expect(files.directory(messageID: "../etc") == nil)
        #expect(files.directory(messageID: uuid) != nil)
    }

    @Test func attachmentValidation() {
        let pdf = Data("%PDF-1.7\nbody\n%%EOF\n".utf8)
        func att(_ d: Data?, size: Int? = nil) -> MailAttachment {
            MailAttachment(filename: "a.pdf", contentType: "application/pdf", isInline: false, data: d,
                           sizeBytes: size ?? d?.count ?? 0)
        }
        #expect(MailPDFFetcher.validate(att(pdf), maxBytes: 1000, truncated: false) == nil)
        #expect(MailPDFFetcher.validate(att(nil, size: 9_000_000), maxBytes: 1000, truncated: false) == .notFetched(sizeBytes: 9_000_000))
        #expect(MailPDFFetcher.validate(att(pdf), maxBytes: 5, truncated: false) == .tooLarge(sizeBytes: pdf.count))
        #expect(MailPDFFetcher.validate(att(Data("<html>login</html>".utf8)), maxBytes: 1000, truncated: false) == .notPDF)
        let cut = Data("%PDF-1.7\nhalf a file".utf8)
        #expect(MailPDFFetcher.validate(att(cut), maxBytes: 1000, truncated: true) == .incomplete)
        #expect(MailPDFFetcher.validate(att(cut), maxBytes: 1000, truncated: false) == nil)
        #expect(MailPDFFetcher.Rejection.tooLarge(sizeBytes: 3 << 20).message(.en, capMB: 1).contains("3 MB (limit 1 MB)"))
        #expect(MailPDFFetcher.Rejection.notPDF.message(.zh, capMB: 1) == "附件不是 PDF 文件")
    }

    @Test func pdfAvailabilityFollowsTheRulesOnly() {
        #expect(MailPDFFetcher.availability(ids: PaperIDs(arxivID: "2609.20001"), url: nil, host: nil) == .downloadable)
        #expect(MailPDFFetcher.availability(ids: PaperIDs(doi: "10.1101/2026.09.14.612345"), url: nil, host: "biorxiv.org") == .downloadable)
        #expect(MailPDFFetcher.availability(ids: PaperIDs(doi: "10.1038/s41586-024-08351-7"),
                                            url: "https://www.nature.com/articles/s41586-024-08351-7", host: "nature.com") == .needsPDF)
        #expect(MailPDFFetcher.availability(ids: PaperIDs(), url: "https://example.org/files/paper.pdf", host: "example.org") == .downloadable)
    }

    @Test func cursorFingerprintTracksTheMailboxNotCosmetics() {
        var a = MailAccount(id: "x", kind: .imap, displayName: "Gmail", imapPreset: .gmail, username: "Me@Gmail.com")
        let base = MailSyncActor.fingerprint(a)
        #expect(base == "imap|imap.gmail.com|993|me@gmail.com|INBOX")
        a.displayName = "Renamed"; a.lookbackDays = 90; a.enabled = false
        #expect(MailSyncActor.fingerprint(a) == base)
        a.mailbox = "PaperDeck"
        #expect(MailSyncActor.fingerprint(a) != base)
        let f = MailAccount(id: "y", kind: .folder, displayName: "PA", folderPath: "/a")
        var g = f
        g.folderPath = "/b"
        #expect(MailSyncActor.fingerprint(f) != MailSyncActor.fingerprint(g))
        #expect(MailSyncActor.fingerprintKey("y") == "y.config")
    }

    @Test func gmailWebLinkSearchesTheMessageID() {
        let gmail = MailAccount(id: "g", kind: .imap, displayName: "Gmail", imapPreset: .gmail, username: "me@gmail.com")
        let link = MailSyncActor.webLink(gmail, messageID: "<caf3xyz+abc/123=@mail.gmail.com>")
        #expect(link == "https://mail.google.com/mail/u/0/#search/rfc822msgid:caf3xyz%2Babc%2F123%3D@mail.gmail.com")
        #expect(MailSyncActor.webLink(gmail, messageID: "<0123abcd@paperdeck.invalid>") == nil)
        let icloud = MailAccount(id: "i", kind: .imap, displayName: "iCloud", imapPreset: .icloud)
        #expect(MailSyncActor.webLink(icloud, messageID: "<a@b>") == nil)
        #expect(MailSyncActor.webLink(MailAccount(id: "f", kind: .folder, displayName: "F"), messageID: "<a@b>") == nil)
    }

    @Test func fetchLimitLeavesRoomForBase64() {
        var s = MailSettings()
        s.maxAttachmentMB = 50
        #expect(MailSyncActor.attachmentCap(s) == 50 << 20)
        #expect(MailSyncActor.fetchLimit(s) >= (50 << 20) * 4 / 3)
        s.maxAttachmentMB = 0
        #expect(MailSyncActor.attachmentCap(s) == 1 << 20)
        #expect(MailSyncActor.attachmentTitle("Smith2026_neocortex.PDF") == "Smith2026 neocortex")
        #expect(MailSyncActor.attachmentTitle("  ") == nil)
    }

    @Test func initialTriageStatePolicy() {
        let ai = MailSettings(aiMode: .ai)
        let local = MailSettings(aiMode: .heuristicOnly)
        let alert = SenderRule(pattern: "@arxiv.org", kind: .alert)                 // always
        let person = SenderRule(pattern: "a@b.org", kind: .person)                  // ask
        let never = SenderRule(pattern: "c@b.org", kind: .person, aiPolicy: .never)
        let alwaysPerson = SenderRule(pattern: "d@b.org", kind: .advisor, aiPolicy: .always)
        typealias C = MailTriageCoordinator
        #expect(C.initialState(senderKind: .alert, rule: alert, candidates: 3, settings: ai) == .queued)
        #expect(C.initialState(senderKind: .alert, rule: alert, candidates: 0, settings: ai) == .skipped)
        #expect(C.initialState(senderKind: .person, rule: person, candidates: 1, settings: ai) == .awaitingConsent)
        #expect(C.initialState(senderKind: .person, rule: never, candidates: 1, settings: ai) == MailTriageState.none)
        #expect(C.initialState(senderKind: .advisor, rule: alwaysPerson, candidates: 0, settings: ai) == .queued)
        #expect(C.initialState(senderKind: .manual, rule: nil, candidates: 0, settings: ai) == .awaitingConsent)
        #expect(C.initialState(senderKind: .alert, rule: alert, candidates: 3, settings: local) == MailTriageState.none)
        #expect(C.initialState(senderKind: .manual, rule: nil, candidates: 3, settings: local) == MailTriageState.none)
    }

    @Test func aiResultKeepRule() {
        let criteria = ReadingCriteria()                                            // minConfidence 0.5
        typealias C = MailTriageCoordinator
        func t(_ kind: MailRequestKind, _ has: Bool, _ conf: Double) -> MailTriage {
            MailTriage(hasReadingRequest: has, requestKind: kind, summary: "", confidence: conf)
        }
        #expect(C.keepsPending(t(.advisorRequest, true, 0.8), criteria: criteria))
        #expect(!C.keepsPending(t(.advisorRequest, true, 0.3), criteria: criteria))
        #expect(!C.keepsPending(t(.advisorRequest, false, 0.2), criteria: criteria))
        #expect(C.keepsPending(t(.fyi, false, 0.2), criteria: criteria))
        #expect(!C.keepsPending(t(.alertDigest, false, 0.2), criteria: criteria))
        #expect(C.keepsPending(t(.alertDigest, false, 0.2), criteria: criteria, focusPapers: 2))
        #expect(!C.keepsPending(t(.notPaper, true, 0.9), criteria: criteria))
        #expect(!C.keepsPending(t(.other, true, 0.9), criteria: criteria))           // not a kept kind by default
        let strict = ReadingCriteria(keepKinds: [.advisorRequest])
        #expect(!C.keepsPending(t(.fyi, false, 0.2), criteria: strict))
    }

    @Test func inboxFilterMapsEveryState() {
        for state in MailState.allCases { #expect(MailInboxFilter(state).state == state) }
        #expect(MailInboxFilter(.merged) == .handled)
    }
}
