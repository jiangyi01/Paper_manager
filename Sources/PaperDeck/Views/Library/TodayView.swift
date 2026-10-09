import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// The 今天 section (§8 今天分区): a centred list (max width 760) with the day header,
/// [今天跳过], and the groups 逾期 / 今天到期 / 今日计划 / 本周接下来.
struct TodayView: View {
    let state: AppState

    init(state: AppState) {
        self.state = state
    }

    var body: some View {
        if let snap = state.snapshot {
            if snap.rows.isEmpty {
                EmptyStateView(state: state, section: .today)
            } else {
                list(snap)
            }
        } else {
            EmptyStateView(state: state, section: .today)
        }
    }

    // MARK: List

    private func list(_ snap: LibrarySnapshot) -> some View {
        let plan = snap.today
        let lang = L.lang
        let filter = state.searchResults.map(Set.init)
        func entries(_ ids: [String], minutes: [String: Int] = [:]) -> [TodayEntry] {
            ids.compactMap { id in
                if let filter, !filter.contains(id) { return nil }
                return snap.row(id: id).map { TodayEntry(row: $0, minutes: minutes[id]) }
            }
        }
        let overdue = entries(plan.overdue)
        let dueToday = entries(plan.dueToday)
        let planned = entries(plan.plannedToday.map(\.id),
                              minutes: Dictionary(plan.plannedToday.map { ($0.id, $0.minutes) },
                                                  uniquingKeysWith: { a, _ in a }))
        let upcoming = entries(plan.upcoming)
        let searching = filter != nil
        let nothingShown = overdue.isEmpty && dueToday.isEmpty && planned.isEmpty && upcoming.isEmpty

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    // Getting Started: fresh installs only, until dismissed or the required items are done.
                    if let facts = state.facts, GettingStartedCard.isShown(facts) {
                        GettingStartedCard(facts: facts, runner: GuideActionRunner(settings: state.settings, state: state,
                                                                                  openTopic: { state.router.showHelp($0) }))
                            .padding(.bottom, 8)
                    }
                    TodayHeader(plan: plan, budget: state.settings.dailyBudgetMinutes, lang: lang,
                                onSkip: { state.skipToday() })
                        .padding(.bottom, 10)

                    if searching ? nothingShown : plan.isEmpty {
                        EmptyStateView(state: state, section: .today)
                            .padding(.vertical, 12)
                    }

                    group(.overdue, overdue, today: plan.today)
                    group(.dueToday, dueToday, today: plan.today)
                    group(.planned, planned, today: plan.today)
                    group(.upcoming, upcoming, today: plan.today)
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: state.selectedPaperID) { _, id in
                guard let id, plan.ids.contains(id) || plan.upcoming.contains(id) else { return }
                withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(id) }
            }
        }
        .agentBadgeActions(state)
    }

    @ViewBuilder
    private func group(_ kind: TodayGroup, _ items: [TodayEntry], today: LocalDate) -> some View {
        if !items.isEmpty {
            TodayGroupHeader(kind: kind, count: items.count,
                             minutes: kind == .planned ? items.reduce(0) { $0 + ($1.minutes ?? 0) } : nil)
                .padding(.top, 10)
            ForEach(items) { entry in
                todayRow(entry.row, minutes: entry.minutes, today: today)
            }
        }
    }

    private func todayRow(_ row: PaperRow, minutes: Int?, today: LocalDate) -> some View {
        let id = row.id
        return TodayRow(row: row, today: today, lang: L.lang, minutesToday: minutes,
                        onToggle: { itemID in state.toggleChecklistItem(paperID: id, itemID: itemID) },
                        onOpen: {
                            state.selectedPaperID = id
                            // showPaper() would leave 今天 for papers outside today's set (本周接下来);
                            // for those the selection alone opens the inspector.
                            if state.visibleRows.contains(where: { $0.id == id }) { state.router.showPaper(id) }
                        })
            .overlay {
                if state.selectedPaperID == id {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded { state.openPDF(row) })
            .contextMenu { PaperContextMenu(state: state, row: row) }
            .accessibilityAddTraits(state.selectedPaperID == id ? [.isSelected] : [])
            .id(id)
    }
}

private struct TodayEntry: Identifiable {
    let row: PaperRow
    let minutes: Int?
    var id: String { row.id }
}

private enum TodayGroup: Sendable {
    case overdue, dueToday, planned, upcoming

    var title: String {
        switch self {
        case .overdue: return L.cardsTodayGroupOverdue
        case .dueToday: return L.cardsTodayGroupDueToday
        case .planned: return L.cardsTodayGroupPlanned
        case .upcoming: return L.cardsTodayGroupUpcoming
        }
    }

    var symbol: String {
        switch self {
        case .overdue: return "exclamationmark.circle.fill"
        case .dueToday: return "flag.checkered"
        case .planned: return "book.pages"
        case .upcoming: return "calendar"
        }
    }
}

private struct TodayGroupHeader: View {
    let kind: TodayGroup
    let count: Int
    let minutes: Int?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(kind == .overdue ? AnyShapeStyle(ChipPalette.dynamic(light: 0xC62828, dark: 0xFF6B61))
                                                  : AnyShapeStyle(.secondary))
            Text(kind.title)
                .font(.system(size: 13, weight: .semibold))
            Text(minutes.map { "\(count) · " + L.cardsTodayMinutesShort($0) } ?? "\(count)")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.leading, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// `9月29日 周二` + `3 篇 · 约 70 分钟 / 预算 60 · 待读共 12 篇` + [今天跳过].
private struct TodayHeader: View {
    let plan: TodayPlan
    let budget: Int
    let lang: UILang
    let onSkip: () -> Void

    private static let overBudget = ChipPalette.dynamic(light: 0xB85A00, dark: 0xFFA94D)

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L.cardsTodayDate(plan.today))
                    .font(.system(size: 24, weight: .bold))
                summary
                    .font(.system(size: 13))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            Button(action: onSkip) {
                Label(L.cardsTodaySkip, systemImage: "arrow.turn.up.right")
            }
            .controlSize(.large)
            .disabled(plan.isEmpty)
            .help(L.cardsTodaySkipHelp)
        }
    }

    private var summary: some View {
        let over = plan.todayMinutes > budget && budget > 0
        return HStack(spacing: 0) {
            Text(L.cardsTodaySummaryCount(plan.count) + " · ")
                .foregroundStyle(.secondary)
            Text(SharedStrings.aboutMinutes(plan.todayMinutes, lang))
                .foregroundStyle(over ? AnyShapeStyle(Self.overBudget) : AnyShapeStyle(.secondary))
                .fontWeight(over ? .semibold : .regular)
            Text(" / " + L.cardsTodayBudget(budget) + " · " + L.cardsTodayBacklog(plan.backlogTotal))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .help(over ? L.cardsTodayOverBudgetHelp : "")
    }
}
