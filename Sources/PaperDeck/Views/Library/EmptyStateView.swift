import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// Friendly empty states per sidebar section. An empty library always shows the big
/// drop target with 添加 PDF… / 导入文件夹… (through `state.router`).
struct EmptyStateView: View {
    let state: AppState
    let section: SidebarItem

    init(state: AppState, section: SidebarItem) {
        self.state = state
        self.section = section
    }

    var body: some View {
        Group {
            if let snap = state.snapshot {
                content(snap)
            } else {
                ProgressView(L.cardsEmptyLoading)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    @ViewBuilder private func content(_ snap: LibrarySnapshot) -> some View {
        let query = state.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty, state.searchResults != nil {
            EmptyMessage(symbol: "magnifyingglass", title: L.cardsEmptySearchTitle(query), message: L.cardsEmptySearchMessage)
        } else if snap.rows.isEmpty && section != .recentlyDeleted {
            VStack(spacing: 18) {
                // A fresh install's checklist sits above the drop target (never for an existing install).
                if let facts = state.facts, GettingStartedCard.isShown(facts) {
                    GettingStartedCard(facts: facts, runner: GuideActionRunner(settings: state.settings, state: state,
                                                                              openTopic: { state.router.showHelp($0) }))
                        .frame(maxWidth: 600)
                }
                LibraryDropTarget(state: state)
            }
        } else {
            sectionMessage(snap)
        }
    }

    @ViewBuilder private func sectionMessage(_ snap: LibrarySnapshot) -> some View {
        switch section {
        case .today:
            todayEmpty(snap.today, snap: snap)
        case .toRead:
            EmptyMessage(symbol: "checkmark.circle", tint: .green, title: L.cardsEmptyToReadTitle, message: L.cardsEmptyToReadMessage)
        case .reading:
            EmptyMessage(symbol: "book", title: L.cardsEmptyReadingTitle, message: L.cardsEmptyReadingMessage)
        case .done:
            EmptyMessage(symbol: "checkmark.seal", title: L.cardsEmptyDoneTitle, message: L.cardsEmptyDoneMessage)
        case .all:
            LibraryDropTarget(state: state)
        case .needsAttention:
            EmptyMessage(symbol: "checkmark.shield", tint: .green, title: L.cardsEmptyAttentionTitle, message: L.cardsEmptyAttentionMessage)
        case .uncategorized:
            EmptyMessage(symbol: "square.grid.2x2", title: L.cardsEmptyUncategorizedTitle, message: L.cardsEmptyUncategorizedMessage)
        case .recentlyDeleted:
            EmptyMessage(symbol: "trash", title: L.cardsEmptyDeletedTitle, message: L.cardsEmptyDeletedMessage)
        case .category:
            EmptyMessage(symbol: "folder", title: L.cardsEmptyCategoryTitle, message: L.cardsEmptyCategoryMessage)
        case .mail:
            // LibraryRootView shows MailInboxView for 邮件; this only covers a stray call.
            EmptyMessage(symbol: "envelope", title: L.Mail.emptyInboxTitle, message: L.Mail.emptyInboxMessage)
        }
    }

    @ViewBuilder private func todayEmpty(_ plan: TodayPlan, snap: LibrarySnapshot) -> some View {
        if plan.backlogTotal == 0 {
            EmptyMessage(symbol: "sun.max", tint: .orange, title: L.cardsEmptyTodayTitle, message: L.cardsEmptyTodayAllDone)
        } else {
            let next = plan.nextDeadline.flatMap { nd in
                snap.row(id: nd.id).map { row in
                    L.cardsEmptyTodayNext(day: SharedStrings.relativeDay(nd.date, today: plan.today, lang: L.lang, calendar: .current),
                                     title: CardText.displayTitle(row.paper))
                }
            }
            EmptyMessage(symbol: "sun.max", tint: .orange, title: L.cardsEmptyTodayTitle,
                         message: SharedStrings.backlogLine(total: plan.backlogTotal, unscheduled: plan.unscheduled, L.lang),
                         detail: next) {
                Button(L.cardsEmptyShowToRead) { state.sidebar = .toRead }
                    .controlSize(.large)
            }
        }
    }
}

/// Icon + title + message (+ optional detail and actions), centred.
private struct EmptyMessage<Actions: View>: View {
    let symbol: String
    var tint: Color = .secondary
    let title: String
    let message: String
    var detail: String?
    let actions: () -> Actions

    init(symbol: String, tint: Color = .secondary, title: String, message: String, detail: String? = nil,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.message = message
        self.detail = detail
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            HStack(spacing: 10) { actions() }
                .padding(.top, 6)
        }
        .frame(maxWidth: 420)
        .accessibilityElement(children: .contain)
    }
}

extension EmptyMessage where Actions == EmptyView {
    init(symbol: String, tint: Color = .secondary, title: String, message: String, detail: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, message: message, detail: detail) { EmptyView() }
    }
}

/// Empty library: a large dashed drop target (the window-level drop overlay does the work).
private struct LibraryDropTarget: View {
    let state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bob = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Image(systemName: "doc.fill")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(Color.accentColor.opacity(0.25))
                    .rotationEffect(.degrees(-12))
                    .offset(x: -26, y: 6)
                Image(systemName: "doc.fill")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(Color.accentColor.opacity(0.4))
                    .rotationEffect(.degrees(10))
                    .offset(x: 26, y: 6)
                Image(systemName: "doc.richtext.fill")
                    .font(.system(size: 54, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
                    .offset(y: bob ? -5 : 0)
            }
            .frame(height: 84)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { bob = true }
            }

            VStack(spacing: 6) {
                Text(L.cardsEmptyLibraryTitle)
                    .font(.title2.weight(.semibold))
                Text(L.cardsEmptyLibrarySubtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                Button {
                    state.router.pickAndImportFiles()
                } label: {
                    Label(L.cardsEmptyAddPDF, systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    state.router.pickAndImportFolder()
                } label: {
                    Label(L.cardsEmptyImportFolder, systemImage: "folder.badge.plus")
                }
            }
            .controlSize(.large)
            .padding(.top, 4)

            Text(L.cardsEmptyLibraryHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Button(L.Help.newHereTour) { HelpCenter.openTour() }
                .buttonStyle(.link)
                .font(.callout)
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 44)
        .frame(maxWidth: 600)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.accentColor.opacity(0.04))
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L.cardsEmptyLibraryTitle)
    }
}
