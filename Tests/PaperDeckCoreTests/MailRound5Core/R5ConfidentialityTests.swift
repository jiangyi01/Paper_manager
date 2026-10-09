import Foundation
import Testing
@testable import PaperDeckCore

/// Round 5 (b): the confidentiality guard also catches review requests asked as a question or a
/// favour — "would you be able to review this manuscript", "able to review", "review the
/// manuscript", the handling editor, a referee's / reviewer's report or comments, a reviewer's
/// reminder — while an advisor's "review this paper", paper titles and calls for review articles
/// stay ordinary mail. Pure and table-driven (subject and first body lines, any case); the round-4
/// tables (`R4ConfidentialityTests`) stay green unchanged.
@Suite struct R5ConfidentialityTests {
    typealias Case = R4ConfidentialityTests.Case

    private static func guarded(_ c: Case) -> Bool {
        MailHeuristics.isConfidential(subject: c.subject, fromAddress: c.from, body: c.body)
    }

    /// Each phrase in the subject and in the body of an email from a preset alert domain.
    static func both(_ label: String, _ phrase: String, from: String = "editor@nature.com") -> [Case] {
        [Case(label + " [subject]", phrase, from, "Dear Dr Jiang,\nBest wishes"),
         Case(label + " [body]", "Nature Neuroscience", from, "Dear Dr Jiang,\n\(phrase)\nBest wishes")]
    }

    static let mustCatch: [Case] =
        both("would you be able to review this manuscript", "Would you be able to review this manuscript?")
        + both("would you be able to review the manuscript", "Would you be able to review the manuscript for Neuron?")
        + both("able to review (question)", "Neuron: would you be able to review?", from: "neuron@cell.com")
        + both("be available to review a manuscript", "Would you be available to review a manuscript for Nature Neuroscience?")
        + both("are you willing to referee", "Are you willing to referee a submission for PRL?", from: "prl@aps.org")
        + both("able to review our revised manuscript", "We hope you are able to review our revised manuscript.")
        + both("review this manuscript", "I would be grateful if you could review this manuscript.")
        + both("review the manuscript", "Please review the manuscript by Friday.")
        + both("review a manuscript", "We need someone to review a manuscript on cortical folding.")
        + both("handling editor", "Message from the handling editor")
        + both("referee report", "Referee report on NN-A12345")
        + both("referee's report", "The referee's report is attached.")
        + both("reviewer's comments", "Please see the reviewer’s comments below.")
        + both("reviewer comments on your", "Reviewer comments on your submission NN-A12345")
        + both("comments of the reviewers", "Here are the comments of the reviewers.")
        + both("submit your review", "A reminder to submit your review of NN-A12345")
        + both("your review is overdue", "Your review is now overdue")

    @Test(arguments: mustCatch)
    func reviewRequestsAskedAsAQuestionAreCaught(_ c: Case) {
        #expect(Self.guarded(c), "\(c.label)")
        #expect(Self.guarded(Case(c.label, c.subject.uppercased(), c.from, c.body.uppercased())), "\(c.label) (upper case)")
    }

    /// Ordinary mail and digest titles the new wordings must not catch.
    static let mustNotCatch: [Case] = [
        Case("advisor: review this paper", "Journal club", "jsmith@lab.example.edu",
             "Hi,\nPlease review this paper before Friday's journal club.\nThanks"),
        Case("title: LLMs review code", "arXiv cs daily", "no-reply@arxiv.org",
             "Title: Large language models are able to review code at scale\nAuthors: A. Lee"),
        Case("title: can models review papers", "Scholar alert", "scholaralerts-noreply@google.com",
             "Can language models review papers? An empirical study"),
        Case("title: review of the manuscript tradition", "Scholar alert", "scholaralerts-noreply@google.com",
             "A review of the manuscript tradition of medieval herbals"),
        Case("call: submit your review article", "Annual Reviews", "alerts@annualreviews.example.org",
             "Submit your review article to the 2027 volume"),
        Case("title: editor handling", "TOC", "alerts@nature.com", "Editorial handling of retractions: a survey"),
        Case("TOC: peer review commentary", "Nature Neuroscience: Table of contents", "alerts@nature.com",
             "Peer review in neuroscience: a commentary\nScreening of neural organoids"),
    ]

    @Test(arguments: mustNotCatch)
    func ordinaryMailStaysOrdinary(_ c: Case) {
        #expect(!Self.guarded(c), "\(c.label)")
    }

    /// The round-3/4 tables: every confidential wording still caught, every digest still clear.
    @Test func theEarlierTablesStayGreen() {
        for c in R4ConfidentialityTests.probeConfidential + R4ConfidentialityTests.wordings {
            #expect(Self.guarded(c), "\(c.label)")
        }
        for c in R4ConfidentialityTests.digests { #expect(!Self.guarded(c), "\(c.label)") }
    }

    /// The verifier's missed wording end to end (round 4 gap probe "bulk invite"): a reviewer
    /// invitation from a preset alert domain with a List-Unsubscribe header waits for consent and
    /// its attachment's title never goes out.
    @Test func aListMailInvitationFromAnAlertDomainWaitsForConsent() async throws {
        let recorder = R4.Recorder()
        let cellRule = SenderRule(id: "rule-cell", pattern: "@cell.com", label: "Cell Press", kind: .alert)
        let mail = MailSyncKit.mailSettings(senders: [MailSyncKit.advisorRule, cellRule])
        try await R4.run(mode: .mock, mail: mail, fetcher: recorder,
                         pdf: MailSyncKit.FakePDF(title: "Manuscript title under review here", doi: nil)) { env in
            let eml = R4.emlWithPDF(from: "neuron@cell.com", messageID: "<r5-invite@cell.com>",
                                    subject: "Neuron: would you be able to review?",
                                    body: ["Dear Dr Jiang,", "Would you be able to review this manuscript for Neuron?",
                                           "The abstract is attached."],
                                    pdf: MailSyncKit.realPDF(title: "Abstract"),
                                    extraHeaders: ["List-Unsubscribe: <mailto:unsub@cell.com>"])
            await env.source.add("invite.eml", eml)
            await env.sync()
            let m = try await env.message("<r5-invite@cell.com>")
            #expect(MailHeuristics.isConfidential(m))
            #expect(m.triageState == .awaitingConsent && m.triageSource == .heuristic)
            #expect(recorder.titleSearches.isEmpty, "\(recorder.titleSearches)")
        }
    }
}
