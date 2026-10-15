import Foundation

/// How a paper came in, as far as privacy is concerned: one entry per email source
/// (`paper_source` row joined with its message's sender kind). Built by `Engine.privacyInputs`.
package struct PaperSourceSummary: Sendable, Equatable {
    /// The email was from a person (advisor, collaborator, a dropped .eml) — not an alert.
    package var personSourced: Bool
    /// The paper has a DOI or an arXiv id (published / posted work, not a manuscript).
    package var identified: Bool
    /// The email is confidential (`MailHeuristics.isConfidential`: a manuscript under review, a
    /// reviewer invitation, a submission system's mail) — from any sender, an alert preset's domain too.
    package var confidential: Bool

    package init(personSourced: Bool, identified: Bool, confidential: Bool = false) {
        self.personSourced = personSourced; self.identified = identified; self.confidential = confidential
    }
}

/// The one privacy rule for every assist surface (Explain, Q&A, the judge; plan §2). Pure; returns
/// reason codes only — the App words them through its policy-text adapter (no institution text in
/// Core). `blocked` means the paper is marked "never use AI": no turn at all. `confirm` needs the
/// user's acknowledgement (the confidential sheet) before the same ticket proceeds.
package enum AssistPrivacy {
    package enum Reason: String, Sendable, CaseIterable {
        /// The user marked the paper unpublished / confidential (`paper_policy.confidential`).
        case markedConfidential
        /// A person's or a confidential email's PDF held as possibly unpublished (`ai_note = mail_unpublished`).
        case mailUnpublished
        /// Came from a confidential email (`PaperSourceSummary.confidential`: a manuscript under
        /// review, a reviewer invitation…), whoever sent it — identified or not.
        case mailConfidential
        /// Came from a person's email and has no DOI / arXiv id.
        case personSourcedNoID
        /// The capture comes from a mail or chat app.
        case messagingHost
        /// Captured in a browser (or a browser's web app) whose page can't be told — its window
        /// title is unreadable without Screen Recording — so it may be webmail
        /// (`MailWindow.isUnidentifiedBrowserPage`).
        case unknownBrowserPage
    }

    package enum Verdict: Sendable, Equatable {
        case ok
        case confirm([Reason])
        /// `never_ai`.
        case blocked
    }

    /// Mail and chat apps: content captured there may be someone else's private message.
    package static let messagingHosts: Set<String> = [
        "com.apple.mail", "com.apple.MobileSMS", "com.apple.iChat",
        "com.microsoft.Outlook", "com.microsoft.teams", "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap", "com.tencent.xinWeChat", "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram", "com.hnc.Discord", "org.mozilla.thunderbird",
        "com.readdle.smartemail-Mac", "com.superhuman.electron", "com.facebook.archon",
    ]

    /// Reasons in a fixed order (`Reason.allCases`); duplicates collapse.
    package static func verdict(policy: PaperPolicy?, aiNote: String?, provenance: [PaperSourceSummary],
                                hostBundleID: String?) -> Verdict {
        if policy?.neverAI == true { return .blocked }
        var reasons: Set<Reason> = []
        if policy?.confidential == true { reasons.insert(.markedConfidential) }
        if aiNote == ImportAnnotation.unpublishedHoldNote { reasons.insert(.mailUnpublished) }
        if provenance.contains(where: \.confidential) { reasons.insert(.mailConfidential) }
        if provenance.contains(where: { $0.personSourced && !$0.identified }) { reasons.insert(.personSourcedNoID) }
        if let host = hostBundleID?.lowercased(), messagingHosts.contains(where: { $0.lowercased() == host }) {
            reasons.insert(.messagingHost)
        }
        let ordered = Reason.allCases.filter(reasons.contains)
        return ordered.isEmpty ? .ok : .confirm(ordered)
    }
}
