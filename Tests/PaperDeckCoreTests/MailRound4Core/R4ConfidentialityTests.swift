import Foundation
import Testing
@testable import PaperDeckCore

/// Round 4, r4-1: the confidentiality guard (`MailHeuristics.isConfidential`) catches the common
/// wordings of reviewer invitations, review requests, acceptances / proofs, decisions and
/// revisions (false negatives of round 3), and no longer flags alert digests whose paper titles
/// merely contain "screening" or start with "Confidential …" (false positives). Pure and
/// table-driven: every phrase of the round-3 verifier's probe (scratchpad r3v-probes.log) is here.
@Suite struct R4ConfidentialityTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var label: String
        var subject: String
        var from: String
        var body: String
        var testDescription: String { label }
        init(_ label: String, _ subject: String, _ from: String = "editor@journal.org", _ body: String = "") {
            self.label = label; self.subject = subject; self.from = from; self.body = body
        }
    }

    private static func guarded(_ c: Case) -> Bool {
        MailHeuristics.isConfidential(subject: c.subject, fromAddress: c.from, body: c.body)
    }

    // MARK: Must be confidential

    /// The round-3 verifier's probe cases (labelled "C …").
    static let probeConfidential: [Case] = [
        Case("C invite you to review", "Nature Neuroscience", "editor@nature.com",
             "Dear Dr Jiang,\nWe would like to invite you to review the attached manuscript."),
        Case("C agreeing to review", "Thank you for agreeing to review", "neuro@nature.com",
             "Dear Dr. Jiang, thank you for agreeing to review manuscript NN-A12345."),
        Case("C invitation to peer review", "Invitation to peer review: NN-A12345", "neuro@nature.com"),
        Case("C request for peer review", "Request for peer review", "neuro@nature.com"),
        Case("C referees' reports", "Revision requested", "neuro@nature.com", "Please find the referees' reports below."),
        Case("C scholarone invite", "Manuscript CELL-D-26-01 - Invitation to Review", "onbehalfof@manuscriptcentral.com"),
        Case("C springer manuscript number", "Submission to Nature Communications - manuscript number NCOMMS-26-1234",
             "ncomms@nature.com"),
        Case("C arxiv scheduled", "[arXiv] Your article is scheduled", "no-reply@arxiv.org",
             "Your submission has been accepted and is scheduled to be announced."),
        Case("C your paper accepted (proofs)", "Your paper has been accepted", "editor@cell.com",
             "Dear author, we are pleased to accept your paper. Proofs will follow."),
    ]

    /// Every wording r4-1 names, in the subject or in the first body lines, in several forms.
    static let wordings: [Case] = [
        // invite(d) you to review | referee
        Case("invite you to review (body)", "Nature Methods", "editor@nature.com", "Dear Dr Jiang,\n\nI invite you to review NMETH-A1."),
        Case("invited you to review", "Cell Reports", "editor@cell.com", "The editor has invited you to review a manuscript."),
        Case("invited you to referee", "PRL", "prl@aps.org", "We have invited you to referee the paper below."),
        Case("inviting you to review", "Neuron", "editor@cell.com", "I am writing to ask… inviting you to review."),
        // invitation to (peer[- ])review | referee
        Case("invitation to review", "Invitation to review"),
        Case("invitation to peer-review", "INVITATION TO PEER-REVIEW: eLife-2026-77"),
        Case("invitation to referee", "Invitation to referee a submission"),
        Case("invitation to act as reviewer", "Nature", "editor@nature.com", "This is an invitation to act as a reviewer."),
        // request(ed) (for|to) (peer[- ])review
        Case("request for peer review", "Request for Peer Review – Genome Research"),
        Case("request to review", "A request to review for Bioinformatics"),
        Case("requested to review", "Neuron", "editor@cell.com", "You have been requested to review manuscript NEURON-D-1."),
        Case("request for peer-review", "Journal of Neuroscience", "jneuro@sfn.org", "Request for peer-review of JN-RM-1234-26"),
        // agree(d|ing) to review
        Case("agreed to review", "Re: your review", "editor@journal.org", "Thank you, you agreed to review this paper by 12 Oct."),
        Case("agreeing to review", "Thanks for agreeing to review"),
        Case("agree to review", "Neuron", "editor@cell.com", "If you agree to review, please click the link below."),
        // peer[- ]review (invitation|request)
        Case("peer review invitation", "Peer review invitation from eLife"),
        Case("peer-review request", "PLOS Biology peer-review request"),
        // reviewer (invitation|assignment)
        Case("reviewer invitation", "Reviewer Invitation: Nature Neuroscience"),
        Case("reviewer assignment", "Reviewer assignment for manuscript"),
        // review (the )?(attached|enclosed) manuscript
        Case("review the attached manuscript", "Could you help?", "colleague@lab.org", "Could you review the attached manuscript this week?"),
        Case("review the enclosed manuscript", "Bioinformatics", "editor@oup.com", "Please review the enclosed manuscript."),
        Case("review attached manuscript", "Quick favour", "pi@wustl.edu", "would you review attached manuscript before Friday"),
        // your (article|paper|manuscript) (has been|was) accepted
        Case("your article has been accepted", "Your article has been accepted for publication"),
        Case("your manuscript was accepted", "Genome Biology", "editor@biomedcentral.com", "Your manuscript was accepted on 30 September."),
        Case("your paper has been accepted", "Your paper has been accepted"),
        // proof(s) (of|for) your (article|paper|manuscript)
        Case("proofs of your article", "Proofs of your article are ready"),
        Case("proof for your paper", "Cell Systems", "proofs@cell.com", "Here is the proof for your paper."),
        Case("proofs for your manuscript", "Proofs for your manuscript NN-A1"),
        // galley proof
        Case("galley proof", "Galley proof ready for checking"),
        Case("galley proofs (body)", "PNAS", "pnas@nas.edu", "Attached are the galley proofs; please return corrections."),
        // decision (letter|on your)
        Case("decision letter", "Decision letter for eLife-2026-77"),
        Case("decision on your", "Decision on your submission to Nature Methods"),
        Case("decision on your article", "Cell", "editor@cell.com", "Please find below the decision on your article."),
        // revis(e|ion) (and resubmit|of your manuscript)
        Case("revise and resubmit", "Revise and resubmit: GR-2026-1"),
        Case("revision of your manuscript", "Molecular Cell", "molcell@cell.com", "We invite a revision of your manuscript."),
        // A confidentiality notice
        Case("is confidential", "Neuron", "editor@cell.com", "This manuscript is confidential and must not be shared."),
        Case("is confidential (end of line)", "Draft", "pi@wustl.edu", "The attached draft is confidential\nThanks"),
        Case("confidential information", "Lab update", "pi@wustl.edu", "This message contains confidential information."),
        Case("treat as confidential", "Neuron", "editor@cell.com", "Please treat this manuscript and its contents as confidential."),
        Case("strictly confidential", "STRICTLY CONFIDENTIAL – grant draft"),
        Case("confidential review", "Nature", "editor@nature.com", "Thank you for your confidential review."),
        Case("Confidential: marker", "Confidential: draft for the grant"),
        Case("[Confidential] marker", "[Confidential] tenure letter"),
        // Screening next to the user's own submission / as the posting's status
        Case("your preprint in screening", "Your preprint is in screening", "no-reply@medrxiv.org"),
        Case("your submission under screening", "medRxiv", "no-reply@medrxiv.org", "Your submission is under screening."),
        Case("your article passed screening", "bioRxiv", "no-reply@biorxiv.org", "Hello,\nyour article has passed screening and is now posted."),
        Case("posting under screening (server)", "medRxiv update", "no-reply@medrxiv.org", "This preprint is currently under screening."),
        Case("manuscript under screening", "Update", "editor@journal.org", "The manuscript is currently under screening."),
        // Tracking numbers
        Case("biorxiv tracking number", "BIORXIV/2026/614555 update", "no-reply@biorxiv.org"),
        Case("arxiv submit id", "[arXiv] submit/5812345 received", "no-reply@arxiv.org"),
        // Moderation of the user's own submission
        Case("moderators put on hold", "arXiv notice", "no-reply@arxiv.org", "Our moderators have put your article on hold."),
    ]

    @Test(arguments: probeConfidential + wordings)
    func confidentialWordingsAreCaught(_ c: Case) {
        #expect(Self.guarded(c), "\(c.label)")
        // Case-insensitive.
        let upper = Case(c.label, c.subject.uppercased(), c.from, c.body.uppercased())
        #expect(Self.guarded(upper), "\(c.label) (upper case)")
    }

    // MARK: Must not be confidential

    /// The round-3 verifier's probe cases labelled "F …", plus more alert digests whose titles
    /// contain "screening", "Confidential …" or a moderation word.
    static let digests: [Case] = [
        Case("F medRxiv 'after screening' title", "medRxiv alert: colorectal cancer", "medrxiv@alerts.highwire.org",
             "New results\nOutcomes after screening colonoscopy in a national cohort\nmedRxiv preprint"),
        Case("F PubMed 'in screening' title", "What's new for 'mammography' in PubMed", "efback@ncbi.nlm.nih.gov",
             "Deep learning in screening mammography: a prospective study"),
        Case("F TOC 'confidential' title", "Nature Methods: Table of contents", "alerts@nature.com",
             "Confidential computing for genomic data sharing\nA new method for single-cell profiling"),
        Case("TOC 'Is confidential computing…' title", "Nature Biotechnology: Table of contents", "alerts@nature.com",
             "Is confidential computing ready for clinical genomics?\nBase editing in primates"),
        Case("TOC 'Confidentiality and privacy' title", "Genome Research: Online first", "alerts@cshlp.org",
             "Confidentiality and privacy in genomic research\nA pangenome of maize"),
        Case("medRxiv 'cancer screening' digest", "medRxiv: Oncology", "medrxiv@alerts.highwire.org",
             "Cancer screening uptake during the pandemic\nmedRxiv preprint\nScreening intervals for lung cancer"),
        Case("PubMed 'during screening' title", "PubMed: screening", "efback@ncbi.nlm.nih.gov",
             "Adverse events during screening colonoscopy\nPolyp detection after screening"),
        Case("'under screening' without a status verb", "medRxiv alert", "medrxiv@alerts.highwire.org",
             "Outcomes of women under screening mammography\nmedRxiv preprint"),
        Case("bioRxiv CRISPR screening digest", "bioRxiv alert: CRISPR screening", "biorxiv@alerts.highwire.org",
             "New results\nGenome-wide CRISPR screening identifies cortical regulators\nbioRxiv preprint"),
        Case("'your preprint alert' with screening", "Your weekly preprint alert: screening", "medrxiv@alerts.highwire.org",
             "Screening for atrial fibrillation in primary care"),
        Case("'your article recommendations' with screening", "Your article recommendations", "alerts@sciencedirect.com",
             "Screening of drug libraries in organoids"),
        Case("arXiv listing with a 'moderation' title", "q-bio daily Subj-class mailing 25 1", "no-reply@arxiv.org",
             "Submissions received from Mon 28 Sep 26 to Tue 29 Sep 26\nModeration analysis of neural tuning\nComments: submitted to PRL"),
        Case("Peer review commentary title", "Nature Neuroscience: Table of contents", "alerts@nature.com",
             "Peer review in neuroscience: a commentary\nScreening of neural organoids"),
        Case("listed submissions", "q-bio daily Subj-class mailing 25 1", "no-reply@arxiv.org",
             "Submissions received from Mon 28 Sep 26 to Tue 29 Sep 26"),
    ]

    @Test(arguments: digests)
    func alertDigestTitlesAreNotConfidential(_ c: Case) {
        #expect(!Self.guarded(c), "\(c.label)")
    }

    // MARK: Scope and purity

    /// The guard reads the subject and the first 25 non-empty lines / 3000 characters only.
    @Test func onlyTheTopOfTheBodyCounts() {
        let filler = (1...30).map { "line \($0) of a digest about cortex" }
        let late = filler.joined(separator: "\n") + "\nWe would like to invite you to review the attached manuscript."
        #expect(!MailHeuristics.isConfidential(subject: "Digest", fromAddress: "alerts@nature.com", body: late))
        let early = Array(filler.prefix(10)).joined(separator: "\n") + "\nWe would like to invite you to review it."
        #expect(MailHeuristics.isConfidential(subject: "Digest", fromAddress: "alerts@nature.com", body: early))
        let long = String(repeating: "x", count: 3100) + "\nThis manuscript is confidential."
        #expect(!MailHeuristics.isConfidential(subject: "Digest", fromAddress: "alerts@nature.com", body: long))
        // Pure: the same answer every time, and for the stored message.
        let m = MailMessage(accountID: "a", internetMessageID: "<x@y>", fromAddress: "editor@nature.com", ruleID: nil,
                            senderKind: .alert, subject: "Invitation to peer review: NN-A12345", receivedAt: Date(),
                            bodyText: nil)
        #expect(MailHeuristics.isConfidential(m) && MailHeuristics.isConfidential(m))
    }
}
