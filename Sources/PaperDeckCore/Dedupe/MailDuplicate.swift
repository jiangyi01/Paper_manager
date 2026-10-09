import Foundation

// The email merge popover's duplicate question (DQ §3.7 "Mail merges", dive-dedupe §6.3;
// READING_ASSIST_PLAN §6.3 B3): before a row is merged, the popover shows the library paper the
// email's paper looks like — from the row's own metadata (title, authors, year, DOI / arXiv id),
// nothing downloaded or sent anywhere — and offers the four answers of the decision sheet in
// email words. The merge itself happens only on the popover's button.

/// The four answers (the decision sheet's keep-new / re-read / keep-both / skip, for an email row).
package enum MailDupChoice: String, Sendable, CaseIterable {
    /// Don't add the email's file: the email is linked to the library paper (restored first when it
    /// is in Recently Deleted — then undoable for 30 s: Undo puts it back there). The paper's
    /// priority, category and DDL stay as they are.
    case link
    /// Link, and move the library paper back to To Read (its checklist kept; the popover's due date
    /// pinned, else an automatic DDL). Undoable for 30 s (a paper restored from Recently Deleted
    /// goes back there).
    case reread
    /// The email's PDF replaces the library paper's file; the paper keeps its checklist, notes and
    /// history and adopts the newer version's identifiers. Undoable for 30 s.
    case useThisVersion
    /// Add the email's paper as a paper of its own; the pair is remembered as different (or
    /// related) and not asked about again.
    case addSeparately

    /// The decision sheet's choice this answer is.
    package var kind: DupChoiceKind {
        switch self {
        case .link: return .skip
        case .reread: return .rereadEarlier
        case .useThisVersion: return .keepNew
        case .addSeparately: return .keepBoth
        }
    }
}

/// What the popover shows for one email row that looks like a library paper.
package struct MailDupMatch: Sendable, Equatable {
    package var itemID: String
    package var existingPaperID: String
    package var existing: DupSideSummary
    package var band: DupBand
    package var relation: DupRelation
    package var newerSide: DupSide?
    /// The match was an identifier (DOI / arXiv / published version): the email can't be a
    /// separate paper (two papers can't hold one identifier).
    package var identity: Bool
    package var headline: String
    /// "In your library since Mar 3 · finished Apr 12 · read once".
    package var historyLine: String?
    /// The email's version vs the library's ("bioRxiv v2 (2024) → Nature (2025)").
    package var versionLine: String?
    package var evidence: [String]
    package var choices: [MailDupChoice]
    package var defaultChoice: MailDupChoice

    package init(itemID: String, existingPaperID: String, existing: DupSideSummary, band: DupBand, relation: DupRelation,
                 newerSide: DupSide?, identity: Bool, headline: String, historyLine: String? = nil,
                 versionLine: String? = nil, evidence: [String] = [], choices: [MailDupChoice],
                 defaultChoice: MailDupChoice) {
        self.itemID = itemID; self.existingPaperID = existingPaperID; self.existing = existing; self.band = band
        self.relation = relation; self.newerSide = newerSide; self.identity = identity; self.headline = headline
        self.historyLine = historyLine; self.versionLine = versionLine; self.evidence = evidence; self.choices = choices
        self.defaultChoice = defaultChoice
    }
}

/// What a popover answer did (`Engine.resolveMailDuplicate`).
package struct MailDupOutcome: Sendable, Equatable {
    /// The paper the email ends up with (nil: nothing was produced — the row says why).
    package var paperID: String?
    /// A duplicate review the answer resolved (its toast can go).
    package var reviewID: String?
    /// `Engine.undo(token:)` reverts the answer's library change within `UndoToken.lifetime`.
    package var undoToken: String?
    package var message: String

    package init(paperID: String?, reviewID: String? = nil, undoToken: String? = nil, message: String) {
        self.paperID = paperID; self.reviewID = reviewID; self.undoToken = undoToken; self.message = message
    }
}

/// Which answers an email row gets and which is preselected (pure).
package enum MailDupRules {
    /// - link: always (the email belongs to that paper);
    /// - re-read: when the library paper was finished or is in Recently Deleted;
    /// - use this version: for one work in two versions (not a correction, comment or supplement);
    /// - add separately: unless an identifier matched.
    /// Default (never one that replaces or moves anything on a weak match): a merely possible
    /// match or a related notice / comment → add separately (what a merge did before); a newer
    /// email version → use it; a finished (or deleted) paper of the same work → re-read;
    /// otherwise → link.
    package static func choices(existing e: Paper, band: DupBand, relation: DupRelation, newerSide: DupSide?,
                                identity: Bool) -> (choices: [MailDupChoice], default: MailDupChoice) {
        var list: [MailDupChoice] = [.link]
        if relation.isSameWork, e.status == .done || e.isDeleted { list.append(.reread) }
        if relation.isSameWork { list.append(.useThisVersion) }
        if !identity { list.append(.addSeparately) }
        let preferred: MailDupChoice
        if band == .possible || !relation.isSameWork { preferred = list.contains(.addSeparately) ? .addSeparately : .link }
        else if newerSide == .new { preferred = .useThisVersion }
        else if list.contains(.reread) { preferred = .reread }
        else { preferred = .link }
        return ([preferred] + list.filter { $0 != preferred }, preferred)
    }
}

enum MailDupText {
    static func linked(_ title: String, _ l: UILang) -> String {
        l == .zh ? "邮件已关联到：\(short(title))" : "Linked the email to: \(short(title))"
    }
    static func sameAfterAll(_ title: String, _ l: UILang) -> String {
        l == .zh ? "邮件中的 PDF 就是这篇，已关联：\(short(title))" : "The email's PDF is that paper — linked: \(short(title))"
    }
    static func failed(_ l: UILang) -> String {
        l == .zh ? "没能取得邮件中的 PDF，这一行仍在等待" : "Couldn't get the email's PDF — the row is still waiting"
    }
    private static func short(_ s: String) -> String { s.count > 60 ? String(s.prefix(59)) + "…" : s }
}
