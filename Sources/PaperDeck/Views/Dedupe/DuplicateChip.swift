import SwiftUI
import PaperDeckCore

/// The inspector's duplicate chip (READING_ASSIST_PLAN §7), under the header: this paper is the
/// new side of an open review (certain / likely: "May duplicate X", possible: "Possibly the same
/// paper as X") or the earlier side of one ("A new file may duplicate this paper"). Its note and
/// tint say what the review actually holds back (`DupReview.hold`). [Review…] opens the decision
/// sheet. Placed by `PaperDetailView`. Owned by Slice B.
struct DuplicateChip: View {
    let state: AppState
    let row: PaperRow

    var body: some View {
        let dedupe = state.dedupe
        if DedupeUIModel.isAvailable, row.paper.isLive {
            if let item = dedupe.review(newPaper: row.id) {
                DuplicateChipContent(text: text(item), note: L.Dedupe.chipHeldNote(item.review.hold),
                                     held: item.review.hold != .none) {
                    dedupe.openReview(id: item.id)
                }
            } else if let first = dedupe.reviews(existingPaper: row.id).first {
                DuplicateChipContent(text: L.Dedupe.chipExisting(dedupe.reviews(existingPaper: row.id).count),
                                     note: nil, held: false) {
                    dedupe.openReview(id: first.id)
                }
            }
        }
    }

    private func text(_ item: DupReviewSummary) -> String {
        let title = Self.short(item.existingTitle)
        if item.review.matchesHistory { return L.Dedupe.chipRemoved(title) }
        return item.review.band != .possible ? L.Dedupe.chipHeld(title) : L.Dedupe.chipPossible(title)
    }

    static func short(_ s: String) -> String { s.count > 70 ? String(s.prefix(69)) + "…" : s }
}

/// The chip's look (also drawn by the renders).
struct DuplicateChipContent: View {
    let text: String
    let note: String?
    let held: Bool
    let review: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "square.on.square")
                .foregroundStyle(held ? .orange : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: text)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            Button(L.Dedupe.review, action: review).controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(held ? Color.orange.opacity(0.12) : Color.primary.opacity(0.05)))
        .accessibilityElement(children: .contain)
    }
}
