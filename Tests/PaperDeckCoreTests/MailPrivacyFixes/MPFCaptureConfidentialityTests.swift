import Foundation
import Testing
@testable import PaperDeckCore

/// Mail privacy fixes, mail-ai-privacy-3 and its extra 1: the confidentiality guard used to run on
/// the stored body after the quoted history was cut — an Outlook forward whose subject lost its
/// "FW:" kept no forwarded text, so the reviewer invitation it quoted escaped — and it was judged
/// again from that body later, so a retention purge made a confidential email look harmless
/// (tombstones, title lookups and the duplicate judge loosened). Now the capture judges the uncut
/// text (`MailHeuristics.isConfidential(_:extraction:)`) and stores the verdict on the message
/// (`MailMessage.confidential`, sticky), and every reader prefers it. Fake sources and generated
/// mail only: no mail server, no metadata service, no AI (agent mode off).
@Suite(.timeLimit(.minutes(2))) struct MPFCaptureConfidentialityTests {
    typealias K = MailSyncKit

    static let advisorAlways = SenderRule(id: "rule-advisor-always", pattern: "advisor@lab.example.edu",
                                          label: "Advisor", kind: .advisor, aiPolicy: .always)
    static let natureAlert = SenderRule(id: "rule-nature", pattern: "@*.nature.com", label: "Nature", kind: .alert,
                                        aiPolicy: .always)

    /// The advisor's note, then Outlook's underscores and header block of the invitation it forwards
    /// — with the subject edited (no "FW:").
    static let forwardBody = [
        "Could you take this one? Thanks.",
        "",
        "________________________________",
        "From: Neuron Editorial Office <neuron@journal.example.org>",
        "Sent: Monday, September 28, 2026 9:12 AM",
        "To: Pat Advisor <advisor@lab.example.edu>",
        "Subject: Invitation to review manuscript NEURON-D-26-01234",
        "",
        "Dear Dr. Advisor,",
        "I would like to invite you to review the attached manuscript for Neuron.",
        "Please treat the manuscript as confidential.",
    ]

    static func editedForward(_ messageID: String) -> Data {
        R4.emlWithPDF(from: "advisor@lab.example.edu", messageID: messageID, subject: "Could you take this one?",
                      body: forwardBody, pdf: K.realPDF(title: "Manuscript under review"), fileName: "manuscript.pdf")
    }

    // MARK: Capture-time verdict on the uncut text

    @Test func anEditedSubjectOutlookForwardIsGuardedOnItsCutHistory() throws {
        let content = try MIMEParser.parse(Self.editedForward("<mpf-pure@lab.example.edu>"), maxAttachmentBytes: 50 << 20)
        let x = MailExtractor.extract(content, senderKind: .advisor, bodyCap: MailExtractor.defaultBodyCap)
        // The body keeps only the note (the history is cut as a reply's: no "FW:" in the subject)…
        #expect(!x.bodyText.contains("Invitation to review"), "\(x.bodyText)")
        #expect(!MailHeuristics.isConfidential(content, bodyText: x.bodyText), "the old check, on the cut body")
        // …but the capture's verdict reads the cut history's first lines too.
        #expect(x.historyHead?.contains("Invitation to review manuscript") == true)
        #expect(MailHeuristics.isConfidential(content, extraction: x))
        // A plain note without history stays ordinary.
        let plain = try MIMEParser.parse(R4.emlWithPDF(from: "advisor@lab.example.edu", messageID: "<mpf-plain@lab.example.edu>",
                                                       subject: "Paper for Thursday", body: ["Please read this before lab meeting."],
                                                       pdf: K.realPDF(title: "A published paper")),
                                         maxAttachmentBytes: 50 << 20)
        let px = MailExtractor.extract(plain, senderKind: .advisor, bodyCap: MailExtractor.defaultBodyCap)
        #expect(px.historyHead == nil && !MailHeuristics.isConfidential(plain, extraction: px))
    }

    @Test func theCaptureStoresTheVerdictAndTheForwardWaitsForConsent() async throws {
        let mail = K.mailSettings(senders: [Self.advisorAlways])
        try await R4.run(mail: mail) { env in
            await env.source.add("fw.eml", Self.editedForward("<mpf-fw@lab.example.edu>"))
            await env.sync()
            let m = try await env.message("<mpf-fw@lab.example.edu>")
            #expect(m.confidential == true)
            #expect(MailHeuristics.isConfidential(m))
            // An advisor set to "Always" is overridden by the guard: no automatic triage.
            #expect(m.triageState == .awaitingConsent, "\(m.triageState)")
            #expect(MailTriageCoordinator.permission(m, settings: mail, provider: .claude) == .needsConsent)
            #expect(!MailSyncActor.mayLookUpTitles(m))
            // An ordinary advisor email beside it is still triaged automatically.
            await env.source.add("plain.eml", R4.emlWithPDF(from: "advisor@lab.example.edu", messageID: "<mpf-ok@lab.example.edu>",
                                                            subject: "Paper for Thursday",
                                                            body: ["Please read this before lab meeting."],
                                                            pdf: K.realPDF(title: "A published paper")))
            await env.sync()
            let ok = try await env.message("<mpf-ok@lab.example.edu>")
            #expect(ok.confidential == false && ok.triageState != .awaitingConsent)
        }
    }

    // MARK: Retention purge (extra 1)

    @Test func aPurgedConfidentialAlertEmailStaysConfidential() async throws {
        let mail = K.mailSettings(senders: [Self.natureAlert])
        try await R4.run(mail: mail) { env in
            // Confidential by its body only: the subject alone looks like any journal mail.
            let eml = R4.emlWithPDF(from: "editor@neuroscience.nature.com", messageID: "<mpf-purge@nature.com>",
                                    subject: "Request from Nature Neuroscience",
                                    body: ["Dear Dr. Example,",
                                           "I would like to invite you to review the attached manuscript for Nature Neuroscience.",
                                           "Best wishes"],
                                    pdf: K.realPDF(title: "Manuscript under review"), fileName: "manuscript.pdf")
            #expect(!MailHeuristics.isConfidential(subject: "Request from Nature Neuroscience",
                                                   fromAddress: "editor@neuroscience.nature.com", body: nil))
            await env.source.add("purge.eml", eml)
            await env.sync()
            var m = try await env.message("<mpf-purge@nature.com>")
            #expect(m.confidential == true && MailHeuristics.isConfidential(m))

            // A paper merged from it (unidentified, an alert sender's).
            let paper = try await env.db.insertPaper(Paper(sha256: String(repeating: "7", count: 64), fileSize: 1,
                                                           title: "Manuscript under review", folder: "Papers/m",
                                                           pdfName: "m.pdf", originalName: "manuscript.pdf"))
            try await env.db.insertPaperSource(paperPK: paper.pk, PaperProvenance(
                mailMessageID: m.id, internetMessageID: m.internetMessageID, subject: m.subject, addedAt: K.start))
            #expect(try await env.db.mayRemember(paper) == false)

            // Handled 40 days ago; retention purges its body.
            m.state = .dismissed
            m.userTouched = true
            m.handledAt = K.start.addingTimeInterval(-40 * 86_400)
            _ = try await env.db.updateMailMessage(m, now: K.start)
            #expect(try await env.db.purgeMailBodies(handledBefore: K.start.addingTimeInterval(-30 * 86_400), now: K.start) == 1)
            let purged = try await env.message("<mpf-purge@nature.com>")
            #expect(purged.bodyPurged && purged.bodyText == nil)
            #expect(purged.confidential == true)
            #expect(MailHeuristics.isConfidential(purged), "the purge took the verdict away")
            #expect(!MailSyncActor.mayLookUpTitles(purged))
            #expect(try await env.db.mayRemember(paper) == false, "a tombstone would keep the manuscript's title")
            #expect(try await env.engine.assistPrivacy(paperID: paper.id, hostBundleID: nil) == .confirm([.mailConfidential]))
        }
    }

    // MARK: The stored verdict is sticky

    @Test func theStoredVerdictSurvivesStaleWritesAndIsReadBack() async throws {
        let db = try Database.inMemory()
        let base = MailMessage(accountID: "acct", internetMessageID: "<mpf-sticky@example.org>", fromAddress: "a@example.org",
                               senderKind: .alert, subject: "Digest", receivedAt: K.start, bodyText: "New papers this week")
        var confidential = base
        confidential.confidential = true
        let (saved, _) = try await db.insertMailMessage(confidential, items: [])
        #expect(try await db.mailMessage(pk: saved.pk)?.confidential == true)
        // A copy that says false, or that has no verdict (an older reader's), can't clear it.
        for stale in [false, nil] as [Bool?] {
            var copy = saved
            copy.confidential = stale
            _ = try await db.updateMailMessage(copy, now: K.start)
            #expect(try await db.mailMessage(pk: saved.pk)?.confidential == true, "\(String(describing: stale))")
        }
        // No verdict yet → a verdict is recorded; false → true is recorded.
        var other = base
        other.id = UUID().uuidString.lowercased()
        other.internetMessageID = "<mpf-sticky-2@example.org>"
        let (open, _) = try await db.insertMailMessage(other, items: [])
        #expect(try await db.mailMessage(pk: open.pk)?.confidential == nil)
        var judged = open
        judged.confidential = false
        _ = try await db.updateMailMessage(judged, now: K.start)
        #expect(try await db.mailMessage(pk: open.pk)?.confidential == false)
        judged.confidential = true
        _ = try await db.updateMailMessage(judged, now: K.start)
        #expect(try await db.mailMessage(pk: open.pk)?.confidential == true)
        // The inbox heads carry it too.
        let heads = try await db.mailMessageHeads(states: [.pending], limit: 10)
        #expect(heads.allSatisfy { $0.message.confidential == true })
    }
}
