import Foundation

// Batch operations on a multi-selection (DQ §5.4; READING_ASSIST_PLAN §4, §6.4 C1). Owned by
// Slice C. `Engine.applyBatch` (Engine/OperationsBatch.swift) runs one in one transaction with one
// undo token.

/// One action applied to every selected paper in one transaction with one undo token.
package enum BatchOperation: Sendable, Equatable {
    case setStatus(PaperStatus)
    case setPriority(Priority)
    case setCategory(Int64?)
    case addTags([String])
    case removeTags([String])
    case moveToTrash
    /// Set Date…: every paper's DDL pinned to the day.
    case pinDeadline(LocalDate)
    case postponeDay
    case postponeWeek
    /// Move to Unscheduled.
    case unschedule
    /// Restore Automatic Scheduling (placed one after another, in the order given).
    case restoreAuto
    /// Recently Deleted ▸ Restore (each paper on its own: one that conflicts stays deleted).
    case restore

    /// The code `BatchNotice.operation` carries; the App words the toast from it. Stable strings
    /// (`setStatus.done`, `setPriority.high`, `pinDeadline`, …).
    package var code: String {
        switch self {
        case .setStatus(let s): return "setStatus." + s.rawValue
        case .setPriority(let p): return "setPriority." + Self.priorityCode(p)
        case .setCategory: return "setCategory"
        case .addTags: return "addTags"
        case .removeTags: return "removeTags"
        case .moveToTrash: return "moveToTrash"
        case .pinDeadline: return "pinDeadline"
        case .postponeDay: return "postponeDay"
        case .postponeWeek: return "postponeWeek"
        case .unschedule: return "unschedule"
        case .restoreAuto: return "restoreAuto"
        case .restore: return "restore"
        }
    }

    /// The code of `Engine.requestReread(paperIDs:)`'s notice (not a `BatchOperation`: it queues
    /// card jobs and changes no field, so it has no undo).
    package static let rereadCode = "reread"

    /// The DDL operations (they skip papers marked done, like the single-paper menu).
    package var isSchedule: Bool {
        switch self {
        case .pinDeadline, .postponeDay, .postponeWeek, .unschedule, .restoreAuto: return true
        default: return false
        }
    }

    /// Works on papers in Recently Deleted (every other operation needs a live paper).
    package var targetsDeleted: Bool { self == .restore }

    private static func priorityCode(_ p: Priority) -> String {
        switch p {
        case .high: return "high"
        case .normal: return "normal"
        case .low: return "low"
        }
    }
}

package struct BatchOutcome: Sendable, Equatable {
    /// Papers the operation reached (including ones that already had the value).
    package var applied: [String]
    /// Papers left alone (unknown, deleted meanwhile, done for a DDL operation, a restore conflict).
    package var skipped: [String]
    /// `Engine.undo(token:)` reverts the whole batch (nil: nothing changed, or not undoable).
    package var undoToken: String?
    /// "Read with AI" only: live papers left out because each needs the user's own confirmation on
    /// that paper (`RereadHold`), in the order given. Not in `applied` or `skipped`.
    package var held: [RereadHeld]

    package init(applied: [String] = [], skipped: [String] = [], undoToken: String? = nil, held: [RereadHeld] = []) {
        self.applied = applied; self.skipped = skipped; self.undoToken = undoToken; self.held = held
    }

    /// How many papers were held for `reason`.
    package func heldCount(_ reason: RereadHold) -> Int { held.count { $0.reason == reason } }
}

/// Why batch "Read with AI" (`Engine.requestReread(paperIDs:)`) leaves a paper out: the paper waits
/// for a confirmation the single-paper path asks for (or the user said never), so a multi-selection
/// never sends it to the AI. One reason per paper, the strongest first (the order of the cases).
package enum RereadHold: String, Sendable, Equatable, CaseIterable {
    /// Marked "Never use AI" (`paper_policy.never_ai`).
    case neverAI
    /// Held as possibly unpublished (`ai_note = mail_unpublished`: a person's emailed PDF with no
    /// DOI / arXiv id) — "confirm before AI reading".
    case possiblyUnpublished
    /// Marked "Unpublished / confidential" (`paper_policy.confidential`): asks before any AI use.
    case confidential
    /// Under duplicate review: an open review holds this new paper's AI reading until it is decided.
    case duplicateReview
}

/// One paper batch "Read with AI" left out, and why.
package struct RereadHeld: Sendable, Equatable {
    package var paperID: String
    package var reason: RereadHold

    package init(paperID: String, reason: RereadHold) { self.paperID = paperID; self.reason = reason }
}
