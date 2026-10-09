import SwiftUI
import PaperDeckCore

/// The "Duplicate?" ribbon on a card that is the new side of an open certain / likely review
/// (READING_ASSIST_PLAN §7). Its help says what the review actually holds back (`DupReview.hold`):
/// no DDL and no AI reading (held at import), no AI reading (matched by the enrichment), or
/// nothing (a library check's question). Placed by `PaperCardView` over the thumbnail's
/// top-leading corner; a click opens the decision sheet. Possible matches get no ribbon (only the
/// inspector chip), so they don't clutter the grid. Owned by Slice B.
struct DuplicateRibbon: View {
    let row: PaperRow

    var body: some View {
        if row.paper.isLive, let model = DedupeUIModel.current, model.showsRibbon(row.id) {
            let help = L.Dedupe.ribbonHelp(model.review(newPaper: row.id)?.review.hold ?? .none)
            Button { model.openReview(forPaper: row.id) } label: {
                DuplicateRibbonLabel()
            }
            .buttonStyle(.plain)
            .padding(8)
            .help(help)
            .accessibilityLabel(L.Dedupe.ribbon)
            .accessibilityHint(help)
        }
    }
}

/// The ribbon's capsule (also drawn by the renders).
struct DuplicateRibbonLabel: View {
    var body: some View {
        Label(L.Dedupe.ribbon, systemImage: "square.on.square")
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.orange))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }
}
