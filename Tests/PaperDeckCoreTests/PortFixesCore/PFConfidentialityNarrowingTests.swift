import Foundation
import Testing
@testable import PaperDeckCore

/// Portability verification F3: the round-5 "asked as a question" wordings ("are you able to
/// review …", "would you be able to review …", "review the manuscript …") held ordinary reading
/// requests from a colleague — no automatic triage, title lookups held even after 「让 AI 分析」,
/// no auto-merge. They now count only for a manuscript / submission / paper (or no object) with reviewer /
/// editorial context — reviewer, referee, peer review or an editor in the text, an editor's or a
/// publisher's address, a manuscript system (a paper / article likewise; a preprint never). Both
/// directions, table-driven, pure (subject and first body lines, any case).
@Suite struct PFConfidentialityNarrowingTests {
    typealias Case = R4ConfidentialityTests.Case

    private static func guarded(_ c: Case) -> Bool {
        MailHeuristics.isConfidential(subject: c.subject, fromAddress: c.from, body: c.body)
    }

    /// Each phrase in the subject and in the body.
    static func both(_ label: String, _ phrase: String, from: String) -> [Case] {
        [Case(label + " [subject]", phrase, from, "Hi Yi,\nThanks!"),
         Case(label + " [body]", "Quick question", from, "Hi Yi,\n\(phrase)\nThanks!")]
    }

    static let colleague = "jsmith@lab.example.edu"

    /// A colleague's / an advisor's ordinary reading requests: never confidential.
    static let colleagueRequests: [Case] =
        both("able to review the paper before journal club",
             "Are you able to review the paper before journal club on Friday?", from: colleague)
        + both("would you be able to review this preprint",
               "Would you be able to review this preprint for lab meeting?", from: colleague)
        + both("could you review the manuscript draft before we submit",
               "Could you review the manuscript draft before we submit?", from: colleague)
        + both("review the manuscript draft before we submit it to the journal",
               "Could you review the manuscript draft before we submit it to the journal?", from: "pi@wustl.edu")
        + both("please review our manuscript", "Please review our manuscript and send comments.", from: colleague)
        + both("willing to review the paper", "Would you be willing to review the paper before journal club?", from: colleague)
        + both("available to review our manuscript draft", "Are you available to review our manuscript draft this week?",
               from: colleague)
        + both("able to review it before Friday", "Would you be able to review it before Friday?", from: colleague)
        + both("review this manuscript for lab meeting", "Can you review this manuscript for lab meeting?", from: colleague)
        // A society's personal alias domain is not a publisher's editorial address.
        + both("an @acm.org alias", "Could you review the manuscript draft before we submit?", from: "jsmith@acm.org")

    @Test(arguments: colleagueRequests)
    func aColleaguesReadingRequestIsNotConfidential(_ c: Case) {
        #expect(!Self.guarded(c), "\(c.label)")
        #expect(!Self.guarded(Case(c.label, c.subject.uppercased(), c.from, c.body.uppercased())), "\(c.label) (upper case)")
    }

    /// Digest titles the narrowed wordings must not newly catch (no object after "able to review").
    static let digests: [Case] = [
        Case("arXiv title: able to review?", "arXiv cs daily", "no-reply@arxiv.org",
             "Title: Are language models able to review? A study\nAuthors: A. Lee"),
        Case("Scholar title: available to review", "Scholar alert", "scholaralerts-noreply@google.com",
             "Reviewers available to review: a census of peer reviewing capacity"),
        // A preprint is never the object (it is public), even with reviewer words, from a publisher.
        Case("arXiv title: review the preprint flood", "arXiv cs daily", "no-reply@arxiv.org",
             "Title: Are reviewers able to review the preprint flood?\nAuthors: B. Chen"),
    ]

    @Test(arguments: digests)
    func digestTitlesStayOrdinary(_ c: Case) {
        #expect(!Self.guarded(c), "\(c.label)")
    }

    /// Reviewer invitations in the same wordings: still caught.
    static let invitations: [Case] =
        // Reviewer / editorial context in the text, from any address.
        both("as a reviewer", "Would you be able to review this manuscript as a reviewer for Neuron?", from: colleague)
        + both("for peer review", "Could you review the manuscript? It was sent to me for peer review.", from: colleague)
        + both("a paper as a referee", "Are you able to review the paper as a referee for PRL?", from: colleague)
        + [Case("signed by an associate editor", "Neuron", colleague,
                "Dear Dr Jiang,\nWould you be able to review this manuscript for Neuron?\nJohn Smith\nAssociate Editor, Neuron")]
        + [Case("an editorial office's question", "Request", "office@journal.example.org",
                "On behalf of the editorial office: are you available to review a manuscript on cortical folding?")]
        // An editor's or a publisher's address.
        + both("an editor's address", "Would you be able to review the manuscript?", from: "jane.editor@journal.example.org")
        + both("eic@", "Are you willing to review a manuscript on cortical folding?", from: "eic@journal.example.org")
        + both("a publisher domain", "Would you be able to review the manuscript?", from: "jane.doe@cell.com")
        + both("a journal subdomain", "Please review the manuscript by Friday.", from: "neuro@neuroscience.nature.com")
        + both("an editor's paper", "Would you be able to review this paper for Nature Neuroscience?", from: "editor@nature.com")
        + both("a publisher's article", "Are you available to review an article on cortical folding?", from: "neuron@cell.com")
        + both("willing, no object", "Thank you for being willing to review.", from: "editor@cell.com")
        + both("bare manuscripts asked", "Would you be willing to review manuscripts for Neuron?", from: "neuron@cell.com")
        + both("review a submission", "Could you review a submission on cortical folding?", from: "editors@elifesciences.org")
        // A manuscript system (caught before any wording).
        + both("a manuscript system", "Could you review the manuscript draft before we submit?",
               from: "em@editorialmanager.com")
        // "Referee" / "peer review" are reviewer words on their own.
        + both("willing to referee", "Would you be willing to referee this preprint?", from: colleague)
        + both("able to peer review", "Are you able to peer review this paper?", from: colleague)

    @Test(arguments: invitations)
    func reviewerInvitationsAreStillCaught(_ c: Case) {
        #expect(Self.guarded(c), "\(c.label)")
        #expect(Self.guarded(Case(c.label, c.subject.uppercased(), c.from, c.body.uppercased())), "\(c.label) (upper case)")
    }

    @Test func editorialSenders() {
        for a in ["editor@journal.org", "Jane.Editor@cell.com", "eic@x.org", "neuron@cell.com", "a@neuroscience.nature.com",
                  "editors@elifesciences.org", "x@manuscriptcentral.com", "prl@aps.org"] {
            #expect(MailHeuristics.isEditorialSender(a), "\(a)")
        }
        for a in ["jsmith@lab.example.edu", "pi@wustl.edu", "me@acm.org", "me@ieee.org", "alerts@ncbi.nlm.nih.gov",
                  "journalclub@lab.example.edu", "not-an-address"] {
            #expect(!MailHeuristics.isEditorialSender(a), "\(a)")
        }
    }

    /// The person-rule path end to end: a colleague's "able to review the paper" is ordinary mail,
    /// so its title lookups run once the user agreed to 「让 AI 分析」.
    @Test func aColleaguesRequestReleasesItsTitlesAfterConsent() {
        let m = MailMessage(accountID: "a", internetMessageID: "<pf-f3@lab>", fromAddress: Self.colleague,
                            senderKind: .person, subject: "Journal club", receivedAt: Date(timeIntervalSince1970: 1_790_000_000),
                            bodyText: "Hi Yi,\nAre you able to review the paper before journal club on Friday?\nThanks",
                            triageState: .awaitingConsent, triageConsented: true)
        #expect(!MailHeuristics.isConfidential(m))
        #expect(MailSyncActor.mayLookUpTitles(m))
    }
}
