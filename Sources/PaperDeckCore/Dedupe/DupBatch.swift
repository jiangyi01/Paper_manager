import Foundation

// The batch review (DQ §4.2, dive-dedupe §6.3; READING_ASSIST_PLAN §6.3 B3): one sheet for the
// reviews of a folder import or a library check. Every row starts on its suggested choice (the
// decision sheet's default); the user may override any row, or set every row at once to a preset
// that each row takes only when it offers that choice. [Apply] resolves the rows one by one (each
// in its own transaction — file swaps can't share one) and returns a single undo token for all of
// them. Nothing is applied before that click.

/// A whole-sheet preset of the batch review ("Set all to …").
package enum DupBatchPreset: String, Sendable, CaseIterable {
    /// Each row's suggested choice (the decision sheet's default).
    case suggested
    /// Keep the new file wherever that's offered (a newer version replaces the earlier file).
    case keepNew
    /// Keep both wherever that's offered (two different papers).
    case keepBoth
    /// Don't add (or remove) the new copy wherever that's offered.
    case skip
}

/// One row of the batch review: the review, its choices, the suggestion and the user's pick.
package struct DupBatchRow: Sendable, Equatable, Identifiable {
    package var detail: DupReviewDetail
    /// The user's explicit pick — a row's picker or a "Set all to …" preset — kept even when it is the
    /// row's suggestion (nil: follow the suggestion). An [Ask AI] answer re-bands the review and may
    /// move the suggestion; an explicit pick never moves with it (B3-2: the AI only re-bands).
    package var override: DupChoiceKind?

    package init(detail: DupReviewDetail, override: DupChoiceKind? = nil) {
        self.detail = detail; self.override = override
    }

    package var id: String { detail.id }
    package var suggested: DupChoiceKind { detail.defaultChoice }
    /// What [Apply] does for this row.
    package var choice: DupChoiceKind { override.flatMap { detail.choices.contains($0) ? $0 : nil } ?? suggested }
    package var isOverridden: Bool { choice != suggested }

    /// The row rebuilt from a fresh read of its review (after an [Ask AI] answer): the user's
    /// explicit pick stays when the review still offers it, even when it was the old suggestion
    /// and the answer moved the suggestion elsewhere; a row without a pick follows the new one.
    package func refreshed(with fresh: DupReviewDetail) -> DupBatchRow {
        DupBatchRow(detail: fresh, override: DupBatch.carry(override, into: fresh))
    }

    /// The row's choice with the sheet's default options: keep the new file without moving the
    /// paper back to To Read; re-read with the checklist kept and an automatic DDL; keep both
    /// linked as related when the two aren't one work. (The decision sheet sets them one by one.)
    package var dupChoice: DupChoice { DupBatch.choice(choice, for: detail.review) }
}

package enum DupBatch {
    /// The engine choice of `kind` with the batch's default options.
    package static func choice(_ kind: DupChoiceKind, for r: DupReview) -> DupChoice {
        switch kind {
        case .keepNew: return .keepNew(reread: false)
        case .rereadEarlier: return .rereadEarlier(checklist: .keepProgress, deadline: .auto, useNewFile: false)
        case .keepBoth: return .keepBoth(linkAsRelated: !r.relation.isSameWork)
        case .skip: return .skip
        case .attachSupplement: return .attachSupplement
        case .addAgain: return .addAgain
        }
    }

    /// `rows` after "Set all to `preset`": a row that doesn't offer the preset's choice keeps its
    /// suggestion (never a choice the row can't take); `.suggested` clears every override. The
    /// preset is an explicit pick even on a row it doesn't change (B3-2): a later [Ask AI] answer
    /// that moves that row's suggestion doesn't move what [Apply] does.
    package static func applying(_ preset: DupBatchPreset, to rows: [DupBatchRow]) -> [DupBatchRow] {
        rows.map { row in
            var r = row
            switch preset {
            case .suggested: r.override = nil
            case .keepNew: r.override = row.detail.choices.contains(.keepNew) ? .keepNew : nil
            case .keepBoth: r.override = row.detail.choices.contains(.keepBoth) ? .keepBoth : nil
            case .skip: r.override = row.detail.choices.contains(.skip) ? .skip : nil
            }
            return r
        }
    }

    /// An explicit pick carried over to a fresh read of its review: kept when the review still
    /// offers it (whatever the new suggestion), else nil (the row follows its suggestion).
    package static func carry(_ pick: DupChoiceKind?, into fresh: DupReviewDetail) -> DupChoiceKind? {
        guard let pick, fresh.choices.contains(pick) else { return nil }
        return pick
    }

    /// How many rows a preset would change from their suggestion (the menu shows it).
    package static func changes(_ preset: DupBatchPreset, in rows: [DupBatchRow]) -> Int {
        applying(preset, to: rows).count(where: \.isOverridden)
    }

    /// The order the sheet lists rows: the reviews that hold a paper back first, then by band
    /// (certain → likely → possible), then oldest first — the import's order.
    package static func ordered(_ details: [DupReviewDetail]) -> [DupReviewDetail] {
        details.enumerated().sorted { a, b in
            let ha = a.element.review.hold != .none, hb = b.element.review.hold != .none
            if ha != hb { return ha }
            if a.element.review.band != b.element.review.band { return a.element.review.band > b.element.review.band }
            return a.offset < b.offset
        }.map(\.element)
    }
}

/// What `Engine.resolveDuplicates` did with a batch.
package struct DupBatchResolution: Sendable, Equatable {
    package var resolved: [DupResolution]
    /// Rows that were not applied (answered elsewhere meanwhile, the file gone, a conflict), by review id.
    package var failed: [String: DupResolutionError]
    /// Reverts every applied row at once for `UndoToken.lifetime` (nil: nothing to undo).
    package var undoToken: String?
    /// One line for the toast, in the UI language.
    package var message: String

    package init(resolved: [DupResolution] = [], failed: [String: DupResolutionError] = [:], undoToken: String? = nil,
                 message: String = "") {
        self.resolved = resolved; self.failed = failed; self.undoToken = undoToken; self.message = message
    }
}

extension DupBatchResolution {
    /// "Applied 6 duplicate decisions" / "Applied 5 — 1 couldn't be applied".
    package static func message(applied: Int, failed: Int, lang: UILang) -> String {
        let zh = lang == .zh
        let head = zh ? "已处理 \(applied) 个重复提醒"
            : (applied == 1 ? "Applied 1 duplicate decision" : "Applied \(applied) duplicate decisions")
        guard failed > 0 else { return head }
        return head + (zh ? "，\(failed) 个未能处理" : (failed == 1 ? " — 1 couldn't be applied" : " — \(failed) couldn't be applied"))
    }
}
