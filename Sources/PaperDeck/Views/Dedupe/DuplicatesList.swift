import SwiftUI
import PaperDeckCore

/// Sidebar ▸ Duplicates and Library ▸ Check for Duplicates… (DQ §4.3–4.4, v1): the open
/// reviews (newest first) with [Review…] each and [Review All], plus a check of the library
/// with its progress and [Stop]. Nothing here changes a paper; the decision sheet does, one
/// [Apply] at a time.
struct DuplicatesList: View {
    let state: AppState
    let close: () -> Void

    static let width: CGFloat = 520

    private var dedupe: DedupeUIModel { state.dedupe }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            checkLine
            if dedupe.open.isEmpty {
                Text(L.Dedupe.listEmpty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(dedupe.open) { item in
                            DuplicateListRow(item: item) { review(item.id) }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(22)
        .frame(width: Self.width)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "square.on.square")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(L.Dedupe.listTitle).font(.title3.weight(.semibold))
            Spacer()
            if !dedupe.open.isEmpty {
                Text(L.Dedupe.listCount(dedupe.openCount)).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var checkLine: some View {
        if let check = dedupe.check {
            HStack(spacing: 8) {
                if check.running {
                    ProgressView(value: Double(check.done), total: Double(max(check.total, 1)))
                        .frame(width: 140)
                    Text(L.Dedupe.checking(check.done, check.total))
                        .font(.callout)
                        .monospacedDigit()
                    Spacer()
                    Button(L.Dedupe.stop) { dedupe.stopCheck() }.controlSize(.small)
                } else {
                    Image(systemName: check.stopped ? "stop.circle" : "checkmark.circle.fill")
                        .foregroundStyle(check.stopped ? Color.secondary : Color.green)
                    Text(check.stopped ? L.Dedupe.checkStopped : L.Dedupe.checkFound(check.found ?? 0)).font(.callout)
                    Spacer()
                    if !check.stopped, let found = check.found, found > 0 {
                        // The check's questions in one batch review (each row on its suggestion).
                        Button(L.Dedupe.reviewFound(found)) { reviewCheck() }.controlSize(.small)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.5)))
        }
    }

    private var footer: some View {
        HStack {
            Button(L.Dedupe.checkLibrary) { dedupe.startCheck() }
                .disabled(dedupe.check?.running == true)
            Spacer()
            if !dedupe.open.isEmpty {
                Button(L.Dedupe.reviewAll) { reviewAll() }
            }
            Button(L.Dedupe.done) {
                dedupe.clearFinishedCheck()
                close()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }

    // A sheet can't open over this one: close first, then the decision sheet.
    private func review(_ id: String) {
        dedupe.clearFinishedCheck()
        close()
        Task { @MainActor in dedupe.openReview(id: id) }
    }

    private func reviewCheck() {
        dedupe.clearFinishedCheck()
        close()
        Task { @MainActor in dedupe.reviewCheckResults() }
    }

    private func reviewAll() {
        dedupe.clearFinishedCheck()
        close()
        Task { @MainActor in dedupe.reviewAll() }
    }
}

/// One open review: headline, the two titles, the band.
struct DuplicateListRow: View {
    let item: DupReviewSummary
    let review: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: item.review.hold != .none ? "pause.circle.fill" : "questionmark.circle")
                .font(.title3)
                .foregroundStyle(item.review.hold != .none ? .orange : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.headline).font(.callout.weight(.semibold)).lineLimit(1)
                    if item.review.relation.isSameWork {
                        Text(L.Dedupe.band(item.review.band))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                Text(verbatim: L.Dedupe.newLine(item.newTitle.isEmpty ? L.Dedupe.waitingFile : item.newTitle))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(verbatim: item.review.matchesHistory ? L.Dedupe.removedLine(item.existingTitle)
                     : L.Dedupe.libraryLine(item.existingTitle))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(L.Dedupe.review, action: review).controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.35)))
        .accessibilityElement(children: .contain)
    }
}
