import SwiftUI
import PaperDeckCore
import PaperDeckShared

/// The inspector while two or more papers are selected (READING_ASSIST_PLAN §6.4 C1, §7
/// "Selection"; DQ §5.3): a summary (count, status breakdown, reading time left, AI cards, overdue,
/// DDL range), the selection bar's actions as full-width rows (better for VoiceOver), and the list
/// of papers — [Show only this paper] / [−] per row. The library window's inspector shows it in place
/// of the paper detail. Owned by Slice C.
struct MultiInspector: View {
    let state: AppState

    /// The list shows this many papers, then "+N more" (all of them are in the grid): a ⌘A over
    /// thousands of papers stays light.
    static let listLimit = 50

    var body: some View {
        let rows = state.selection.targetRows
        let menus = BatchMenus(state: state, rows: rows)
        let today = state.snapshot?.today.today ?? LocalDate.today()
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(rows)
                summary(rows, today: today)
                actions(menus)
                list(rows)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Header

    private func header(_ rows: [PaperRow]) -> some View {
        HStack(alignment: .center, spacing: 14) {
            StackedThumbnails(rows: Array(rows.prefix(3)))
            VStack(alignment: .leading, spacing: 3) {
                Text(L.Select.inspectorTitle(rows.count))
                    .font(.title3.weight(.semibold))
                Button(L.Select.none) { state.selection.clear() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Summary

    private func summary(_ rows: [PaperRow], today: LocalDate) -> some View {
        let lang = L.lang
        let byStatus = PaperStatus.allCases.compactMap { s -> String? in
            let n = rows.count { $0.paper.status == s }
            return n == 0 ? nil : "\(L.cardsMenuStatusName(s)) \(n)"
        }
        let minutes = rows.filter { $0.paper.status != .done }.reduce(0) { $0 + $1.remainingMinutes }
        let cards = rows.count { $0.paper.card != nil }
        let overdue = rows.count { r in
            r.paper.status != .done && r.paper.scheduleMode != .none && (r.paper.deadline.map { $0 < today } ?? false)
        }
        let deadlines = rows.compactMap { $0.paper.scheduleMode == .none ? nil : $0.paper.deadline }.sorted()
        return VStack(alignment: .leading, spacing: 6) {
            SummaryLine(symbol: "circle.lefthalf.filled", text: byStatus.joined(separator: " · "))
            if minutes > 0 { SummaryLine(symbol: "clock", text: L.Select.minutesLeft(minutes)) }
            SummaryLine(symbol: "sparkles", text: L.Select.withCards(cards))
            if overdue > 0 { SummaryLine(symbol: "exclamationmark.circle", text: L.Select.overdue(overdue), tint: .red) }
            if let first = deadlines.first, let last = deadlines.last {
                SummaryLine(symbol: "calendar",
                            text: L.Select.ddlRange(SharedStrings.relativeDay(first, today: today, lang: lang),
                                                    SharedStrings.relativeDay(last, today: today, lang: lang)))
            } else {
                SummaryLine(symbol: "calendar", text: L.Select.noDDL)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
    }

    // MARK: Actions

    @ViewBuilder private func actions(_ menus: BatchMenus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if menus.allDeleted {
                menus.restoreButton()
                menus.deleteNowButton()
            } else {
                menus.statusMenu
                menus.priorityMenu
                menus.deadlineMenu
                menus.categoryMenu
                menus.tagsMenu
                menus.rereadButton()
                AskAcrossButton(state: state, rows: menus.rows)
                menus.duplicatesButton
                menus.exportMenu
                menus.trashButton()
            }
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .menuStyle(.button)
        .controlSize(.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Papers

    private func list(_ rows: [PaperRow]) -> some View {
        let listed = SelectionLogic.capped(rows, limit: Self.listLimit)
        return LazyVStack(alignment: .leading, spacing: 4) {
            Text(L.Select.papersHeader)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(listed.shown) { row in
                HStack(spacing: 8) {
                    Button { state.selection.showOnly(row.id) } label: {
                        Text(CardText.displayTitle(row.paper))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help(L.Select.showOnly)
                    Button { state.selection.deselect(row.id) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(L.Select.removeFromSelection)
                    .accessibilityLabel(L.Select.removeFromSelection)
                }
                .font(.callout)
                .padding(.vertical, 4)
                Divider()
            }
            if listed.more > 0 {
                Text(L.Select.morePapers(listed.more))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
    }
}

private struct SummaryLine: View {
    let symbol: String
    let text: String
    var tint: Color? = nil

    var body: some View {
        Label {
            Text(text).monospacedDigit()
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        }
        .font(.callout)
    }
}

/// The first three thumbnails, fanned.
private struct StackedThumbnails: View {
    let rows: [PaperRow]

    var body: some View {
        ZStack {
            ForEach(Array(rows.enumerated().reversed()), id: \.element.id) { i, row in
                Thumb(url: row.thumbnailURL)
                    .frame(width: 54, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .rotationEffect(.degrees(Double(i) * 6 - 6))
                    .offset(x: CGFloat(i) * 8)
            }
        }
        .frame(width: 80, height: 80)
        .accessibilityHidden(true)
    }
}

private struct Thumb: View {
    let url: URL?
    @State private var image: NSImage?

    init(url: URL?) {
        self.url = url
        _image = State(initialValue: url.flatMap { CardThumbnailCache.shared.cached($0) })
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .controlBackgroundColor))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "doc.text").font(.system(size: 20, weight: .light)).foregroundStyle(.tertiary)
            }
        }
        // A new (versioned) URL — the thumbnail was rewritten — loads again, never keeps the old image.
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = CardThumbnailCache.shared.cached(url) { image = hit; return }
            image = await CardThumbnailCache.shared.load(url)
        }
    }
}
