import Foundation

// The confidentiality guard (institutional AI policies; review safety-7, round 3): manuscripts under
// review, reviewer invitations and the user's own unposted submissions must never go to an AI —
// or into the library — on their own. Sender presets are domain-wide (@*.nature.com, @arxiv.org,
// @biorxiv.org, @*.elsevier.com…), and the journals' manuscript systems and the preprint servers'
// submission / screening desks mail from those very domains, so the guard looks at the message
// itself: before any automatic triage (`MailTriageCoordinator.initialState` and the send gate
// `permission`) and before any automatic merge / download (`Engine.autoMergeMail`), for every
// sender kind. A guarded message waits for 「让 AI 分析」 (or stays local when the sender is
// `never`) and is merged only by the user. The email's own attachments are still stored locally
// (no network, no AI) so the user can merge them with one click.

extension MailHeuristics {
    /// How many leading non-empty body lines the guard reads (the rest of a digest is papers).
    static let confidentialBodyLines = 25
    /// …and at most this many characters of them.
    static let confidentialBodyChars = 3000

    /// True when the email is (or quotes, near its top) manuscript / peer-review / submission
    /// system mail. Pure, case-insensitive, English keywords over the subject and the first body
    /// lines (`leadingLines`): a reviewer invitation or review request in any common wording
    /// ("invite you to review", "Invitation to peer review", "Request for peer review", "thank
    /// you for agreeing to review", "review the attached manuscript", the handling editor, a
    /// reviewer assignment or reminder…; "would you be able to review", "review this manuscript"
    /// only with reviewer / editorial context — `isReviewRequest`), a
    /// manuscript id / number, the user's submission or manuscript, its acceptance or proofs
    /// (galley / page proofs), a decision letter, a revise-and-resubmit, referees' reports, an
    /// arXiv `submit/NNNNNNN` or bioRxiv / medRxiv tracking number, or a confidentiality notice
    /// ("… is confidential", "confidential information", "treat … as confidential", "strictly
    /// confidential", "confidential review", a "Confidential:" marker) — never the bare word, so
    /// a paper title like "Confidential computing for genomics" in a digest does not count.
    /// "Screening" counts only next to the user's own submission (`your preprint / manuscript /
    /// submission`, "your article has passed screening"), or as the posting's status ("is under
    /// screening") from a preprint server or about a submission — clinical titles ("outcomes
    /// after screening colonoscopy") don't; preprint moderation likewise. Or the sender is a
    /// manuscript system (Editorial Manager, ScholarOne / Manuscript Central, eJournalPress,
    /// Elsevier EES / EVISE, Springer Nature SNAPP, Nature's MTS) or a submission / moderation
    /// desk (arXiv moderation, a `submission@` / `editorial@` / `reviewer@` address).
    package static func isConfidential(subject: String, fromAddress: String, body: String?) -> Bool {
        if isManuscriptSystemSender(fromAddress) { return true }
        let text = subject + "\n" + leadingLines(body ?? "")
        func has(_ r: NSRegularExpression, _ s: String) -> Bool {
            r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
        }
        if has(confidentialRegex, text) || has(confidentialityNoticeRegex, text) { return true }
        if isReviewRequest(text, fromAddress: fromAddress) { return true }
        let ownSubmission = has(ownSubmissionRegex, text)
        // "screening" is a common word in paper titles (CRISPR screening, screening mammography…):
        // only next to the user's own submission, or as a posting's screening status.
        if has(screeningWordRegex, text) {
            if ownSubmission { return true }
            if has(screeningSubjectRegex, subject), has(submissionWordRegex, subject) { return true }
            if has(screeningStatusRegex, text), isPreprintServer(fromAddress) || has(submissionWordRegex, text) {
                return true
            }
        }
        // A preprint server's moderators write about the user's own submission.
        if has(moderationRegex, text) {
            if ownSubmission || has(submissionWordRegex, text) { return true }
            if isPreprintServer(fromAddress), has(moderationStatusRegex, text) { return true }
        }
        return false
    }

    /// A stored message: its capture-time verdict (`MailMessage.confidential`, which a retention
    /// purge or a cut history can't take back) or what the guard finds in the subject and the body
    /// as stored now. Every reader goes through here: the send gate (`permission`), the initial
    /// triage state of a re-evaluation, automatic merges, title lookups, the privacy inputs of
    /// Explain / Ask / the judge, tombstones (`mayRemember`), the merge options.
    package static func isConfidential(_ m: MailMessage) -> Bool {
        if m.confidential == true { return true }
        return isConfidential(subject: m.subject, fromAddress: m.fromAddress, body: m.bodyText)
    }

    /// The email a paper came from: its stored message (`isConfidential(_ m:)`, the capture-time
    /// verdict first), or — the message is gone (「清除所有邮件数据」) — the subject and sender its
    /// provenance row kept.
    package static func isConfidential(source: PaperProvenance, message: MailMessage?) -> Bool {
        if let message { return isConfidential(message) }
        return isConfidential(subject: source.subject ?? "", fromAddress: source.fromAddress ?? "", body: nil)
    }

    /// A parsed email and its extracted body only (tests; capture and the triage preview use
    /// `isConfidential(_:extraction:)`, which also reads the history the body cut).
    package static func isConfidential(_ content: MailContent, bodyText: String) -> Bool {
        isConfidential(subject: content.header.subject, fromAddress: content.header.fromAddress, body: bodyText)
    }

    /// The capture-time verdict (stored as `mail_message.confidential`): the subject with the first
    /// lines of the body as kept — and, on their own, the first lines of the quoted history or
    /// forwarded section the body cut (`MailExtraction.historyHead`). An Outlook forward whose
    /// subject was edited (no "FW:") loses its forwarded text from the body, but the reviewer
    /// invitation it quotes is still what the email is. Also Settings ▸ Mail's triage preview, so
    /// both decide alike.
    package static func isConfidential(_ content: MailContent, extraction: MailExtraction) -> Bool {
        if isConfidential(content, bodyText: extraction.bodyText) { return true }
        guard let head = extraction.historyHead, !head.isEmpty else { return false }
        return isConfidential(subject: content.header.subject, fromAddress: content.header.fromAddress, body: head)
    }

    // MARK: - Pieces

    static func leadingLines(_ body: String) -> String {
        var out: [Substring] = []
        var chars = 0
        for line in body.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            out.append(line)
            chars += line.count + 1
            if out.count >= confidentialBodyLines || chars >= confidentialBodyChars { break }
        }
        return String(out.joined(separator: "\n").prefix(confidentialBodyChars))
    }

    private static let systemDomains = [
        "editorialmanager.com", "aries-sys.com", "manuscriptcentral.com", "scholarone.com", "ejournalpress.com",
        "evise.com", "ees.elsevier.com", "eesserver.com", "manuscriptmanager.net", "snapp.springernature.com",
    ]
    private static let systemLocalTokens: Set<String> = [
        "submission", "submissions", "submit", "manuscript", "manuscripts", "editorial", "editorialoffice",
        "peerreview", "reviewer", "reviewers", "referee", "referees", "moderation", "moderator", "moderators",
        "screening", "snapp", "evise", "ejp", "ejpress",
    ]

    /// Manuscript systems by domain (any subdomain), Nature's tracking system (`mts-*.nature.com`),
    /// and submission / editorial / review / moderation desks by their address' local part.
    static func isManuscriptSystemSender(_ address: String) -> Bool {
        let a = address.lowercased().trimmingCharacters(in: .whitespaces)
        guard let at = a.lastIndex(of: "@") else { return false }
        let local = a[..<at], domain = String(a[a.index(after: at)...])
        for d in systemDomains where domain == d || domain.hasSuffix("." + d) { return true }
        let labels = domain.split(separator: ".")
        if domain.hasSuffix("nature.com"), labels.contains(where: { $0.hasPrefix("mts-") || $0 == "mts" }) { return true }
        if labels.contains(where: { $0 == "snapp" || $0 == "ejpress" }) { return true }
        let tokens = local.split(whereSeparator: { "._+-".contains($0) }).map(String.init)
        return tokens.contains(where: systemLocalTokens.contains)
    }

    static func isPreprintServer(_ address: String) -> Bool {
        guard let domain = address.lowercased().split(separator: "@").last.map(String.init) else { return false }
        return ["arxiv.org", "biorxiv.org", "medrxiv.org"].contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    /// The soft review requests (round 5, narrowed after the portability verification F3): "would
    /// you be able / available / willing to review …", "able to review our revised manuscript",
    /// "review the / this manuscript". A colleague asks exactly this about a paper, a preprint or
    /// the lab's own draft ("Are you able to review the paper before journal club?", "Would you be
    /// able to review this preprint for lab meeting?", "Could you review the manuscript draft
    /// before we submit?") — that is ordinary mail. So these count only for a manuscript,
    /// submission, paper or article (or no object at all: "would you be able to review?"; a
    /// preprint never — it is public) and only when the email has reviewer / editorial context:
    /// reviewer, referee, peer review or an editor in the text (`reviewContextRegex`), or an
    /// editor's / a publisher's address (`isEditorialSender`; manuscript systems are caught
    /// before). "Review the / this …" stays limited to a manuscript / submission (an advisor's
    /// "review this paper"). "Referee" and "peer review" are reviewer words on their own: those
    /// wordings stay in `confidentialRegex`.
    static func isReviewRequest(_ text: String, fromAddress: String) -> Bool {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var asked = false
        func classify(_ m: NSTextCheckingResult, implicitAllowed: Bool) {
            let tail = ns.substring(from: m.range.location + m.range.length)
            let range = NSRange(location: 0, length: (tail as NSString).length)
            if reviewObjectRegex.firstMatch(in: tail, range: range) != nil { asked = true }
            else if implicitAllowed, reviewNoObjectRegex.firstMatch(in: tail, range: range) != nil
                        || reviewBareManuscriptRegex.firstMatch(in: tail, range: range) != nil { asked = true }
        }
        // Asked as a question: an object may be left out ("Neuron: would you be able to review?").
        for m in reviewQuestionRegex.matches(in: text, range: all) { classify(m, implicitAllowed: true) }
        // "able / available / willing to review": an object must follow — but "thank you for being
        // willing to review." names none either.
        for m in reviewAbleRegex.matches(in: text, range: all) {
            classify(m, implicitAllowed: ns.substring(with: m.range(at: 1)).lowercased() == "willing")
        }
        if reviewTheManuscriptRegex.firstMatch(in: text, range: all) != nil { asked = true }
        guard asked else { return false }
        return reviewContextRegex.firstMatch(in: text, range: all) != nil || isEditorialSender(fromAddress)
    }

    /// Publisher / journal domains (any subdomain) whose editors send review requests: the
    /// publisher hosts of the link classifier minus registries, search engines and societies whose
    /// members carry personal addresses at that domain (@acm.org, @ieee.org aliases).
    static let editorialDomains: [String] = {
        let notPublishers: Set<String> = ["doi.org", "ncbi.nlm.nih.gov", "europepmc.org", "semanticscholar.org",
                                          "huggingface.co", "alphaxiv.org", "acm.org", "ieee.org", "osf.io"]
        return PaperLinkClassifier.paperHosts.filter { !notPublishers.contains($0) }
    }()
    private static let editorialLocalTokens: Set<String> = ["editor", "editors", "eic", "editorinchief", "editorialteam"]

    /// An editor's or a publisher's address: a manuscript system, an editor's / editorial office's
    /// local part (`editor@`, `eic@`, `jane.editor@…`), or a publisher / journal domain.
    static func isEditorialSender(_ address: String) -> Bool {
        if isManuscriptSystemSender(address) { return true }
        let a = address.lowercased().trimmingCharacters(in: .whitespaces)
        guard let at = a.lastIndex(of: "@") else { return false }
        let local = a[..<at], domain = String(a[a.index(after: at)...])
        if local.split(whereSeparator: { "._+-".contains($0) }).contains(where: { editorialLocalTokens.contains(String($0)) }) {
            return true
        }
        return editorialDomains.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    private static func ci(_ p: String) -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
        catch { preconditionFailure("MailHeuristics: bad pattern \(p)") }
    }

    static let confidentialRegex = ci(
        // Reviewer invitations and review requests, in their common wordings.
        #"\binvit(?:e|es|ed|ing|ation)\s+(?:you\s+)?to\s+(?:peer[\s-]*)?(?:review|referee)\b"#
        + #"|\binvit(?:e|es|ed|ing|ation)\s+(?:you\s+)?to\s+(?:act|serve)\s+as\s+(?:an?\s+)?(?:peer[\s-]*)?(?:reviewer|referee)\b"#
        + #"|\b(?:peer[\s-]*)?(?:reviewer|review|referee)\s+(?:invitation|assignment|request)s?\b"#
        + #"|\brequest(?:s|ed)?\s+(?:for|to)\s+(?:a\s+)?(?:peer[\s-]*)?(?:review|referee)\b"#
        + #"|\bagree(?:s|d|ing)?\s+to\s+(?:peer[\s-]*)?(?:review|referee)\b|\bwilling\s+to\s+(?:peer[\s-]*(?:review|referee)|referee)\b"#
        + #"|\breview\s+(?:the\s+|this\s+)?(?:attached|enclosed)\s+(?:manuscript|paper|submission|article)\b"#
        // …asked as a question or a favour (round 5) to referee / peer-review: "would you be able
        // to referee", "able to peer review this manuscript", "referee the manuscript"; the
        // handling editor, a reviewer's reminder. The same wordings with plain "review" need
        // reviewer / editorial context (`isReviewRequest`): "Review this paper" (an advisor's
        // reading request) and "could you review the manuscript draft before we submit" are not.
        + #"|\b(?:would|could|will|can|might|are|were)\s+you\s+(?:be\s+)?(?:able|available|willing|interested|happy|free)\s+to\s+(?:peer[\s-]*(?:review|referee)|referee)\b"#
        + #"|\b(?:able|available)\s+to\s+(?:peer[\s-]*(?:review|referee)|referee)\s+(?:this|the|a|an|our|my|his|her|their)\s+(?:[\w-]+\s+){0,2}?(?:manuscript|paper|submission|article)s?\b"#
        + #"|\breferee\s+(?:this|the|a|an|our|my)\s+(?:revised\s+|new\s+|submitted\s+)?(?:manuscript|submission)s?\b"#
        + #"|\bhandling\s+editor\b"#
        + #"|\b(?:submit|complete|finish|return)\s+your\s+(?:peer[\s-]*)?(?:review|referee\s+report)\b(?!\s+(?:article|paper)s?\b)"#
        + #"|\byour\s+(?:peer[\s-]*)?review\s+(?:is\s+|was\s+)?(?:now\s+)?(?:due|overdue)\b"#
        // Manuscript ids, the user's own submission, its acceptance and proofs.
        + #"|\bmanuscript\s+(?:id|number|no\.?|#|ref(?:erence)?)\b"#
        + #"|\byour\s+(?:recent\s+)?(?:submission|manuscript|revised\s+manuscript|preprint\s+submission|article\s+submission)\b"#
        + #"|\bsubmission\s+(?:received|confirmation|confirmed|acknowledg(?:e)?ment|id|number|no\.?|#)\b"#
        + #"|\byour\s+(?:article|paper|manuscript|submission|preprint)\s+(?:has\s+been|was|is)\s+(?:now\s+|formally\s+)?accepted\b"#
        + #"|\b(?:pleased|happy|delighted)\s+to\s+accept\s+your\b"#
        + #"|\bproofs?\s+(?:of|for)\s+your\s+(?:article|paper|manuscript|submission)\b|\b(?:galley|page)\s+proofs?\b"#
        // Decisions, revisions, referees' reports.
        + #"|\bdecision\s+letter\b|\bdecision\s+on\s+your\b|\bdecision\s+on\s+(?:the\s+)?(?:manuscript|submission|paper)\b"#
        + #"|\brevise\s+and\s+resubmit\b|\brevision\s+of\s+your\s+(?:manuscript|paper|article|submission)\b"#
        + #"|\b(?:referee|reviewer)(?:s|'s|’s|s'|s’)?\s+(?:report|reports|comment|comments)\b"#
        + #"|\bcomments\s+(?:from|of|by)\s+the\s+(?:referee|reviewer)s?\b"#
        // Submission tracking numbers and manuscript systems named in the text.
        + #"|\bsubmit/\d{5,}\b|\b(?:bio|med)rxiv/\d{4}/\d{5,}\b"#
        + #"|\beditorial\s+manager\b|\bscholarone\b|\bmanuscript\s+central\b|\bejournalpress\b|\belsevier\s+editorial\s+system\b|\bevise\b"#)

    // The soft review requests (`isReviewRequest`): the request, then what follows "review".
    static let reviewQuestionRegex = ci(
        #"\b(?:would|could|will|can|might|are|were)\s+you\s+(?:be\s+)?(?:able|available|willing|interested|happy|free)\s+to\s+review\b"#)
    static let reviewAbleRegex = ci(#"\b(able|available|willing)\s+to\s+review\b"#)
    static let reviewTheManuscriptRegex = ci(
        #"\breview\s+(?:this|the|a|an|our|my)\s+(?:revised\s+|new\s+|submitted\s+)?(?:manuscript|submission)s?\b"#)
    /// "… review | this / the / our … manuscript / submission / paper / article" (up to two words
    /// between; not "this preprint").
    static let reviewObjectRegex = ci(
        #"\A\s+(?:this|the|a|an|our|my|his|her|their)\s+(?:[\w-]+\s+){0,2}?(?:manuscript|submission|paper|article)s?\b"#)
    /// "… review manuscripts / a few submissions" without a determiner (asked as a question).
    static let reviewBareManuscriptRegex = ci(#"\A\s+(?:[\w-]+\s+)?(?:manuscript|submission)s?\b"#)
    /// "… review?" / "review it" / "review for Neuron" — nothing named.
    static let reviewNoObjectRegex = ci(
        #"\A(?:[ \t]*(?:[?.!,;:)]|\n|\z)|\s+(?:it|for|by|before|within|on|in|at|and|or)\b)"#)
    /// Reviewer / editorial context in the text (not "journal": "journal club", "before we submit
    /// it to the journal").
    static let reviewContextRegex = ci(
        #"\b(?:reviewers?|referee(?:s|d|ing)?|editors?)\b|\bpeer[\s-]*review|\beditor[\s-]+in[\s-]+chief\b|\beditorial\s+(?:office|board|team)\b"#)

    /// A confidentiality notice — never the bare word ("Confidential computing for genomics" is
    /// a paper title): "… is / be kept / remain confidential" ending the clause, "strictly /
    /// highly / privileged and confidential", "confidential information / material / review /
    /// report / comments…", "treat … as confidential", a "Confidential:" / "[Confidential]" /
    /// "CONFIDENTIAL –" marker, a confidentiality notice / agreement, "maintain confidentiality".
    static let confidentialityNoticeRegex = ci(
        #"\b(?:is|are|was|were|be|been|being|remain|remains|stay|stays|kept|keep|held|treated)\s+(?:strictly\s+|highly\s+|entirely\s+|fully\s+)?confidential\b(?=[ \t]*(?:[.,;:!)\]\n]|$)|\s+(?:and|or|to|until|unless|for|in|at|by)\b)"#
        + #"|\b(?:strictly|highly|privileged\s+and|private\s+and)\s+confidential\b"#
        + #"|\bconfidential\s+(?:and\s+(?:privileged|proprietary)|information|material|materials|document|documents|manuscript|manuscripts|review|peer[\s-]*review|report|reports|comment|comments|communication|correspondence)\b"#
        + #"|\btreat(?:s|ed|ing)?\b[^\n.]{0,80}?\bas\s+(?:strictly\s+|highly\s+)?confidential\b"#
        + #"|\bconfidential\s*[:\])]|[\[(]\s*confidential\b|\bconfidential\s+[-–—]\s"#
        + #"|\bconfidentiality\s+(?:notice|statement|agreement|policy|clause|requirements?|obligations?)\b"#
        + #"|\b(?:maintain|maintains|maintaining|preserve|preserving|respect|respecting|protect|protecting|breach\s+of|duty\s+of)\s+(?:the\s+|strict\s+)?confidentiality\b"#
        + #"|\bconfidentiality\s+of\s+(?:the|this|your)\s+(?:manuscript|review|submission|paper|article|document|material|process)\b"#)

    /// The user's own posting or submission ("your preprint / manuscript / submission", "your
    /// article has …") — not "your preprint alert" / "your article recommendations".
    static let ownSubmissionRegex = ci(
        #"\byour\s+(?:[\w-]+\s+)?(?:submission|preprint|manuscript|posting)s?\b(?!\s+(?:alerts?|digests?|feeds?|recommendations?|updates?|searches|search|notifications?|newsletters?)\b)"#
        + #"|\byour\s+(?:[\w-]+\s+)?(?:article|paper)s?\s+(?:has|have|is|are|was|were|will|had|did|passed|failed|cleared|completed)\b"#)

    static let screeningWordRegex = ci(#"\bscreen(?:ing|ed)\b"#)
    static let screeningSubjectRegex = screeningWordRegex
    /// A submission word for the screening / moderation checks ("preprint" and "submitted" are
    /// not: alert digests print "medRxiv preprint", arXiv listings "Comments: submitted to …").
    static let submissionWordRegex = ci(#"\b(?:submission|manuscript|posting|submit/\d+)\b"#)
    /// A posting's screening status ("is under screening", "has passed screening", "being screened").
    static let screeningStatusRegex = ci(
        #"\b(?:is|are|was|currently|now|still|remains?)\s+(?:being\s+)?(?:under|in|undergoing)\s+(?:our\s+|the\s+)?(?:initial\s+)?screening\b"#
        + #"|\b(?:has|have)\s+(?:passed|failed|cleared|completed)\s+(?:our\s+|the\s+)?(?:initial\s+)?screening\b"#
        + #"|\bscreening\s+(?:process|check|checks|stage|procedure)\b|\b(?:has|have)\s+been\s+screened\b|\bbeing\s+screened\b"#)
    static let moderationRegex = ci(#"\bmoderat(?:ion|ors?)\b|\bon\s+hold\b|\breclassif(?:y|ied|ication)\b"#)
    /// A preprint server's moderation status ("our moderators", "put on hold", "reclassified").
    static let moderationStatusRegex = ci(
        #"\b(?:our|the|arxiv)\s+moderators?\b|\b(?:put|placed|is|been|remains?|currently)\s+on\s+hold\b|\breclassified\b"#)
}
