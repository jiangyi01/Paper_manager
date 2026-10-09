import Foundation

// Duplicate reviews (DQ §3, §8, §9; READING_ASSIST_PLAN §4, §6.3). Owned by Slice B.
// Nothing here acts on its own: a review only asks; every change to a paper is the user's
// choice, applied by `Engine.resolveDuplicate` and undoable for 30 s.

/// How sure the detector is: certain (an identifier or the bytes: the new file is parked),
/// likely (committed but held: no DDL, no AI, a ribbon), possible (committed normally, a chip).
package enum DupBand: String, Sendable, Codable, CaseIterable, Comparable {
    case certain, likely, possible

    /// certain 3 > likely 2 > possible 1.
    package var strength: Int {
        switch self {
        case .certain: return 3
        case .likely: return 2
        case .possible: return 1
        }
    }

    package static func < (a: DupBand, b: DupBand) -> Bool { a.strength < b.strength }
}

package enum DupReviewState: String, Sendable, Codable, CaseIterable { case open, resolved, expired, dismissed }

/// Where a review came from (`dup_review.origin`).
package enum DupOrigin: String, Sendable, Codable, CaseIterable { case intake, enrich, scan, mail }

/// Which side of a pair (`dup_review.newer_side`).
package enum DupSide: String, Sendable, Codable, CaseIterable { case new, existing }

/// How the new item relates to the paper it matched (`dup_review.relation`).
package enum DupRelation: String, Sendable, Codable, CaseIterable {
    /// The same bytes (a removed paper's tombstone; live copies never get a review).
    case sameFile = "same_file"
    /// The same version of the same work (publisher vs author copy).
    case sameVersion = "same_version"
    /// The new file is a newer version (preprint → journal, arXiv v1 → v3).
    case newerVersion = "newer_version"
    /// The new file is an older version than the one in the library.
    case olderVersion = "older_version"
    /// The same work; which version is newer is unknown.
    case sameWork = "same_work"
    /// A supplement (or a short insert) printing the paper's identifier.
    case supplement
    /// A correction / erratum / retraction notice of the paper.
    case correction
    /// A comment on or a reply to the paper.
    case comment

    /// The two are one work (not a related one).
    package var isSameWork: Bool {
        switch self {
        case .sameFile, .sameVersion, .newerVersion, .olderVersion, .sameWork: return true
        case .supplement, .correction, .comment: return false
        }
    }
}

/// What kind of document a title / file name / record says it is (vetoes, DQ §3.3).
package enum DupKind: String, Sendable, Codable, CaseIterable {
    case article, notice, comment, supplement, review, generic
}

/// One reason shown under "Why" (`dup_review.evidence_json`); `DupExplainer` words it.
package struct DupEvidence: Sendable, Codable, Equatable {
    package enum Code: String, Sendable, Codable, CaseIterable {
        case sameFile, sharedDOI, doiFamily, publishedDOI, preprintLink, arxiv, openAlex
        case title, firstAuthor, authors, year, text, abstract
        case supplement, notice, comment, history
    }

    package var code: Code
    /// A DOI, an id or a surname, when the reason names one.
    package var value: String?
    /// A rounded percentage (title / text overlap).
    package var percent: Int?
    /// Matching authors / total, or the two years.
    package var count: Int?
    package var total: Int?

    package init(_ code: Code, value: String? = nil, percent: Int? = nil, count: Int? = nil, total: Int? = nil) {
        self.code = code; self.value = value; self.percent = percent; self.count = count; self.total = total
    }
}

/// A pair decision written together with a commit ("keep both" of a parked file).
package struct DupPairIntent: Sendable, Equatable {
    package var existingPK: Int64
    /// `distinct` or `related`.
    package var decision: String
    package var relation: String?

    package init(existingPK: Int64, decision: String, relation: String? = nil) {
        self.existingPK = existingPK; self.decision = decision; self.relation = relation
    }
}

/// What a held paper would have done without the review, so "Keep both" can restore it
/// (`dup_review.held_schedule_json`).
package struct DupHeldIntent: Sendable, Codable, Equatable {
    /// The paper was committed unscheduled because of the review (place() it when released).
    package var scheduleHeld: Bool
    /// The batch's placement: "normal", "sequentialLow" or "unscheduled".
    package var placement: String
    /// The reading job would have been queued (not held) without the review.
    package var aiQueue: Bool?

    package init(scheduleHeld: Bool, placement: String = "normal", aiQueue: Bool? = nil) {
        self.scheduleHeld = scheduleHeld; self.placement = placement; self.aiQueue = aiQueue
    }
}

/// One detected duplicate situation (`dup_review` row).
package struct DupReview: Sendable, Equatable, Identifiable {
    package var id: String
    /// The new paper (nil while it is parked, not committed).
    package var newPaperID: String?
    package var existingPaperID: String?
    package var band: DupBand
    package var score: Double
    package var state: DupReviewState
    /// The AI judge's state (`none` until someone asks; `DupJudge.answeredState` once it answered).
    package var aiState: String
    /// What the AI judge said (only after the user asked it, `Engine.askDuplicateJudge`).
    package var aiVerdict: DupAIVerdict?
    package var createdAt: Date

    package var newPaperPK: Int64?
    package var existingPaperPK: Int64?
    /// A removed paper's tombstone (`paper_history.pk`) when that is what matched.
    package var historyPK: Int64?
    package var relation: DupRelation
    package var evidence: [DupEvidence]
    package var newerSide: DupSide?
    package var origin: DupOrigin
    package var batchID: String?
    /// The parked file's pending id (`IntakeActor`), while it is parked.
    package var pendingID: String?
    /// The parked file's original name.
    package var stagedName: String?
    package var held: DupHeldIntent?
    /// The applied choice (`DupChoice.code`).
    package var choice: String?
    package var resolvedAt: Date?

    package init(id: String = UUID().uuidString.lowercased(), newPaperID: String?, existingPaperID: String?,
                 band: DupBand, score: Double, state: DupReviewState = .open, aiState: String = "none", createdAt: Date,
                 newPaperPK: Int64? = nil, existingPaperPK: Int64? = nil, historyPK: Int64? = nil,
                 relation: DupRelation = .sameWork, evidence: [DupEvidence] = [], newerSide: DupSide? = nil,
                 origin: DupOrigin = .intake, batchID: String? = nil, pendingID: String? = nil,
                 stagedName: String? = nil, held: DupHeldIntent? = nil, choice: String? = nil, resolvedAt: Date? = nil,
                 aiVerdict: DupAIVerdict? = nil) {
        self.id = id; self.newPaperID = newPaperID; self.existingPaperID = existingPaperID; self.band = band
        self.score = score; self.state = state; self.aiState = aiState; self.createdAt = createdAt
        self.newPaperPK = newPaperPK; self.existingPaperPK = existingPaperPK; self.historyPK = historyPK
        self.relation = relation; self.evidence = evidence; self.newerSide = newerSide; self.origin = origin
        self.batchID = batchID; self.pendingID = pendingID; self.stagedName = stagedName; self.held = held
        self.choice = choice; self.resolvedAt = resolvedAt; self.aiVerdict = aiVerdict
    }

    /// The new file waits in `.partial/` (not committed).
    package var isParked: Bool { newPaperPK == nil && pendingID != nil }
    /// The new paper is committed and may be held until the user decides (certain or likely);
    /// what is actually held back is `hold`.
    package var holdsNewPaper: Bool { newPaperPK != nil && band != .possible }
    /// What matched is a removed paper's tombstone.
    package var matchesHistory: Bool { historyPK != nil && existingPaperPK == nil }

    /// What the review holds back on its new paper — the ribbon, the chip and the sheet say only
    /// that: a paper held at import has no DDL and no AI reading; one the enrichment matched keeps
    /// its DDL (no AI reading); a library check's question (or a possible match) holds nothing.
    /// Read from the hold itself, not the band: a held paper the AI judge moved to "possible"
    /// stays held until the user decides (the judge never releases anything).
    package var hold: DupHold {
        guard newPaperPK != nil, let held else { return .none }
        return held.scheduleHeld ? .scheduleAndAI : .aiOnly
    }
}

/// What an open review holds back on its new paper (`DupReview.hold`).
package enum DupHold: Sendable, Equatable, CaseIterable {
    /// Nothing: the paper is scheduled and read as usual.
    case none
    /// No AI reading until the user decides (the DDL stays).
    case aiOnly
    /// No DDL and no AI reading until the user decides.
    case scheduleAndAI
}

/// What to do with the checklist when re-reading an earlier paper.
package enum ChecklistReset: String, Sendable, Codable, CaseIterable {
    /// Ticks stay.
    case keepProgress
    /// Every item stays, unticked.
    case uncheckAll
    /// Rebuilt from the paper's reading card (no AI call); ticks are dropped.
    case regenerate
}

/// The DDL of a paper moved back to To Read.
package enum DeadlineChoice: Sendable, Equatable, Codable {
    /// place() picks it (`restoreAutoDeadline`).
    case auto
    /// The user's date (`pinDeadline`).
    case date(LocalDate)
    /// No DDL.
    case unscheduled
}

/// The four choices of the decision sheet (plus the two special cases).
package enum DupChoice: Sendable, Equatable {
    /// Keep the new file: it replaces the earlier paper's PDF; the earlier paper keeps its
    /// checklist, notes, history and provenance, adopts the newer version's identifiers, and
    /// (`reread`) goes back to To Read.
    case keepNew(reread: Bool)
    /// Re-read (or keep) the earlier one: it goes back to To Read (restored first when it was
    /// deleted); the new file is dropped unless `useNewFile` (then it also replaces the PDF).
    case rereadEarlier(checklist: ChecklistReset, deadline: DeadlineChoice, useNewFile: Bool)
    /// Keep both as separate papers; remembered, never asked again (`linkAsRelated`: a
    /// correction, comment or companion paper rather than an unrelated one).
    case keepBoth(linkAsRelated: Bool)
    /// Don't add the new file (a parked one is deleted; a committed one goes to Recently Deleted).
    case skip
    /// A supplement: stored as `<paper folder>/supplements/<name>.pdf` of the earlier paper.
    case attachSupplement
    /// A removed paper read before: keep the new one as a paper (its reading counts as another read).
    case addAgain

    /// The code stored in `dup_review.choice`.
    package var code: String {
        switch self {
        case .keepNew(let reread): return reread ? "keep_new_reread" : "keep_new"
        case .rereadEarlier: return "reread_earlier"
        case .keepBoth(let related): return related ? "keep_both_related" : "keep_both"
        case .skip: return "skip"
        case .attachSupplement: return "attach_supplement"
        case .addAgain: return "add_again"
        }
    }

    package var kind: DupChoiceKind {
        switch self {
        case .keepNew: return .keepNew
        case .rereadEarlier: return .rereadEarlier
        case .keepBoth: return .keepBoth
        case .skip: return .skip
        case .attachSupplement: return .attachSupplement
        case .addAgain: return .addAgain
        }
    }
}

/// The choices without their options (what the sheet lists, the default).
package enum DupChoiceKind: String, Sendable, Codable, CaseIterable {
    case keepNew, rereadEarlier, keepBoth, skip, attachSupplement, addAgain
}

/// One side of a review as the decision sheet shows it.
package struct DupSideSummary: Sendable, Equatable {
    package var paperID: String?
    package var title: String
    package var fileName: String?
    package var venue: String?
    package var year: Int?
    package var pages: Int?
    /// "bioRxiv v2", "Nature", "arXiv v3" (`DupExplainer.versionLabel`).
    package var versionLabel: String?
    package var status: PaperStatus?
    package var addedAt: Date?
    package var doneAt: Date?
    package var checklistDone: Int
    package var checklistTotal: Int
    package var notesChars: Int
    package var hasCard: Bool
    package var deletedAt: Date?
    /// A removed paper (tombstone): when it was purged and how often it had been read.
    package var purgedAt: Date?
    package var readCount: Int

    package init(paperID: String? = nil, title: String, fileName: String? = nil, venue: String? = nil, year: Int? = nil,
                 pages: Int? = nil, versionLabel: String? = nil, status: PaperStatus? = nil, addedAt: Date? = nil,
                 doneAt: Date? = nil, checklistDone: Int = 0, checklistTotal: Int = 0, notesChars: Int = 0,
                 hasCard: Bool = false, deletedAt: Date? = nil, purgedAt: Date? = nil, readCount: Int = 0) {
        self.paperID = paperID; self.title = title; self.fileName = fileName; self.venue = venue; self.year = year
        self.pages = pages; self.versionLabel = versionLabel; self.status = status; self.addedAt = addedAt
        self.doneAt = doneAt; self.checklistDone = checklistDone; self.checklistTotal = checklistTotal
        self.notesChars = notesChars; self.hasCard = hasCard; self.deletedAt = deletedAt; self.purgedAt = purgedAt
        self.readCount = readCount
    }
}

/// One open review as the Duplicates list, the ribbon and the chip show it.
package struct DupReviewSummary: Sendable, Equatable, Identifiable {
    package var review: DupReview
    /// The new paper's title (or the parked file's title / name).
    package var newTitle: String
    /// The earlier paper's title (or the removed paper's, from its tombstone).
    package var existingTitle: String
    /// The earlier paper is in Recently Deleted.
    package var existingDeleted: Bool
    package var headline: String

    package init(review: DupReview, newTitle: String, existingTitle: String, existingDeleted: Bool = false,
                 headline: String) {
        self.review = review; self.newTitle = newTitle; self.existingTitle = existingTitle
        self.existingDeleted = existingDeleted; self.headline = headline
    }

    package var id: String { review.id }
}

/// Everything the decision sheet shows for one review.
package struct DupReviewDetail: Sendable, Equatable, Identifiable {
    package var review: DupReview
    package var new: DupSideSummary
    package var existing: DupSideSummary
    package var explanation: DupExplanation
    /// In display order; the first is never one that throws something away.
    package var choices: [DupChoiceKind]
    package var defaultChoice: DupChoiceKind
    /// "Regenerate from the reading card" is possible (the earlier paper has a card with steps).
    package var canRegenerateChecklist: Bool

    package init(review: DupReview, new: DupSideSummary, existing: DupSideSummary, explanation: DupExplanation,
                 choices: [DupChoiceKind], defaultChoice: DupChoiceKind, canRegenerateChecklist: Bool) {
        self.review = review; self.new = new; self.existing = existing; self.explanation = explanation
        self.choices = choices; self.defaultChoice = defaultChoice; self.canRegenerateChecklist = canRegenerateChecklist
    }

    package var id: String { review.id }
}

/// The words of one review (`DupExplainer`), in the UI language.
package struct DupExplanation: Sendable, Equatable {
    package var headline: String
    /// "bioRxiv v2 (2024) → Nature (2025)".
    package var versionLine: String?
    /// "In your library since Mar 3 · finished Apr 12 · read once" / "Removed on Jun 2 — you had finished it".
    package var historyLine: String?
    package var evidence: [String]

    package init(headline: String, versionLine: String? = nil, historyLine: String? = nil, evidence: [String] = []) {
        self.headline = headline; self.versionLine = versionLine; self.historyLine = historyLine; self.evidence = evidence
    }
}

/// What `Engine.resolveDuplicate` did.
package struct DupResolution: Sendable, Equatable {
    package var reviewID: String
    package var choice: DupChoiceKind
    /// The paper the user keeps reading (nil after "skip" of a parked file).
    package var keptPaperID: String?
    /// The paper that went to Recently Deleted (a committed new paper skipped or merged).
    package var removedPaperID: String?
    /// `Engine.undoDuplicateResolution(token:)` reverts it for `UndoToken.lifetime` (nil: nothing to undo).
    package var undoToken: String?
    /// One line for the toast, in the UI language.
    package var message: String

    package init(reviewID: String, choice: DupChoiceKind, keptPaperID: String? = nil, removedPaperID: String? = nil,
                 undoToken: String? = nil, message: String) {
        self.reviewID = reviewID; self.choice = choice; self.keptPaperID = keptPaperID
        self.removedPaperID = removedPaperID; self.undoToken = undoToken; self.message = message
    }
}

/// Why a choice was refused.
package enum DupResolutionError: Error, Equatable, Sendable {
    case reviewNotFound(String)
    /// Resolved, dismissed or expired already.
    case reviewClosed(String)
    /// The parked file is gone (a relaunch since; drop it again).
    case fileExpired(String)
    /// The choice doesn't apply to this review.
    case choiceUnavailable(String)
    /// Both would be live with the same DOI / arXiv id.
    case identifierConflict(String)
    case failed(String)

    package func message(_ lang: UILang) -> String {
        let zh = lang == .zh
        switch self {
        case .reviewNotFound, .reviewClosed:
            return zh ? "这条重复提醒已处理" : "This duplicate check was already handled"
        case .fileExpired:
            return zh ? "新文件已不在暂存区（重新启动过），请重新拖入" : "The new file is no longer waiting (PaperDeck was restarted) — drop it again"
        case .choiceUnavailable:
            return zh ? "这个选项不适用于这两篇论文" : "That option doesn't apply to these two papers"
        case .identifierConflict:
            return zh ? "两篇论文的 DOI/arXiv 编号相同，不能同时保留" : "Both have the same DOI/arXiv ID, so both can't be kept"
        case .failed(let why):
            return zh ? "处理失败：\(why)" : "Couldn't apply it: \(why)"
        }
    }
}

/// `Engine.checkDuplicates(paperIDs:)`: what a check of the library (or a selection) found.
package struct DupCheckSummary: Sendable, Equatable {
    package var checked: Int
    /// Reviews opened by this check.
    package var opened: [String]
    /// Pairs already under review or decided before (not asked again).
    package var known: Int

    package init(checked: Int = 0, opened: [String] = [], known: Int = 0) {
        self.checked = checked; self.opened = opened; self.known = known
    }
}

/// A removed paper's tombstone (`paper_history`): metadata only — no text, no notes — so a
/// re-download months later can say "you finished this in May".
package struct DupHistoryRow: Sendable, Equatable {
    package var pk: Int64
    package var paperID: String
    package var sha256: String?
    package var doi: String?
    package var arxivID: String?
    package var publishedDOI: String?
    /// Identity tokens (`DupKey.value`).
    package var keys: [String]
    package var title: String
    package var titleNorm: String
    package var firstSurname: String?
    package var year: Int?
    package var page: [UInt32]?
    package var abstract: [UInt32]?
    package var lastStatus: PaperStatus
    package var readCount: Int
    package var doneAt: Date?
    package var addedAt: Date?
    package var purgedAt: Date

    package init(pk: Int64 = 0, paperID: String, sha256: String?, doi: String?, arxivID: String?, publishedDOI: String?,
                 keys: [String], title: String, titleNorm: String, firstSurname: String?, year: Int?,
                 page: [UInt32]?, abstract: [UInt32]?, lastStatus: PaperStatus, readCount: Int, doneAt: Date?,
                 addedAt: Date?, purgedAt: Date) {
        self.pk = pk; self.paperID = paperID; self.sha256 = sha256; self.doi = doi; self.arxivID = arxivID
        self.publishedDOI = publishedDOI; self.keys = keys; self.title = title; self.titleNorm = titleNorm
        self.firstSurname = firstSurname; self.year = year; self.page = page; self.abstract = abstract
        self.lastStatus = lastStatus; self.readCount = readCount; self.doneAt = doneAt; self.addedAt = addedAt
        self.purgedAt = purgedAt
    }

    /// The detector's view of it.
    package var subject: DupSubject {
        var s = DupSubject(historyPK: pk, sha256: sha256, doi: doi, title: title,
                           surnames: firstSurname.map { [$0] } ?? [], year: year,
                           rank: VersionRank.of(ids: PaperIDs(doi: doi, arxivID: arxivID, publishedDOI: publishedDOI),
                                                venue: nil),
                           page: page, abstract: abstract, addedAt: addedAt)
        for k in keys { s.keys[k, default: []].insert(k.hasPrefix("arxiv:") ? .arxiv : .doi) }
        return s
    }
}

/// One reading of a paper (`reading_cycle`): "Re-read the earlier one" starts the next.
package struct ReadingCycle: Sendable, Equatable {
    package var n: Int
    package var startedAt: Date
    package var doneAt: Date?
    package var reason: String?

    package init(n: Int, startedAt: Date, doneAt: Date? = nil, reason: String? = nil) {
        self.n = n; self.startedAt = startedAt; self.doneAt = doneAt; self.reason = reason
    }

    /// How often a paper was read: its finished cycles, the readings before its first recorded
    /// cycle (a removed paper read before it was added again), and the current one when the paper
    /// is done (`doneAt`). A cycle that was only started — a re-read under way, or an unread paper
    /// restored — is no reading.
    package static func readCount(_ cycles: [ReadingCycle], doneAt: Date?) -> Int {
        let sorted = cycles.sorted { $0.n < $1.n }
        guard let first = sorted.first else { return doneAt != nil ? 1 : 0 }
        let earlier = max(0, first.n - 1)
        let finished = sorted.count(where: { $0.doneAt != nil })
        let current = doneAt != nil && sorted.last?.doneAt == nil ? 1 : 0
        return earlier + finished + current
    }
}

/// One pair `--dedupe-report` prints (nothing is written).
package struct DupReportPair: Sendable, Equatable {
    package var newPaperID: String
    package var existingPaperID: String
    package var band: DupBand
    package var relation: DupRelation
    package var score: Double
    package var evidence: [DupEvidence]
    /// Already reviewed or decided (`dup_review` / `dup_pair`).
    package var known: Bool
}
