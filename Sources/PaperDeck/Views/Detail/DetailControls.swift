import SwiftUI
import PaperDeckCore

/// 控件: 状态 / 优先级 / DDL / 预计 (§8 详情页). Choices show immediately (optimistic) and
/// fall back to the snapshot once it arrives or when the operation fails.
struct DetailControls: View {
    let state: AppState
    let row: PaperRow
    let today: LocalDate
    let lang: UILang

    @State private var statusOverride: PaperStatus?
    @State private var priorityOverride: Priority?
    @State private var offerReplan = false

    private var paper: Paper { row.paper }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                label(L.Detail.status)
                Picker(L.Detail.status, selection: statusBinding) {
                    ForEach(PaperStatus.allCases, id: \.self) { s in
                        Text(DetailFormat.statusName(s)).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                label(L.Detail.priority)
                VStack(alignment: .leading, spacing: 6) {
                    Picker(L.Detail.priority, selection: priorityBinding) {
                        ForEach(Priority.allCases, id: \.self) { p in
                            Text(DetailFormat.priorityName(p)).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    if offerReplan { replanHint }
                }
            }
            GridRow {
                label("DDL")
                DetailDeadlineControl(state: state, row: row, today: today, lang: lang)
            }
            GridRow {
                label(L.Detail.estimate)
                DetailEstimateControl(state: state, row: row)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onChange(of: paper.status) { statusOverride = nil }
        .onChange(of: paper.priority) { priorityOverride = nil }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private var statusBinding: Binding<PaperStatus> {
        Binding(
            get: { statusOverride ?? paper.status },
            set: { new in
                guard new != (statusOverride ?? paper.status) else { return }
                statusOverride = new
                let id = row.id
                state.detailRun({ _ = try await state.engine.setStatus(paperID: id, new) },
                                onError: { statusOverride = nil })
            })
    }

    private var priorityBinding: Binding<Priority> {
        Binding(
            get: { priorityOverride ?? paper.priority },
            set: { new in
                guard new != (priorityOverride ?? paper.priority) else { return }
                priorityOverride = new
                // The DDL is a commitment: priority alone never moves it (§6.3). Offer the replan.
                withAnimation(.snappy(duration: 0.2)) {
                    offerReplan = paper.status != .done && paper.scheduleMode == .auto
                }
                let id = row.id
                state.detailRun({ _ = try await state.engine.setPriority(paperID: id, new) },
                                onError: { priorityOverride = nil; offerReplan = false })
            })
    }

    private var replanHint: some View {
        Button {
            let id = row.id
            withAnimation(.snappy(duration: 0.2)) { offerReplan = false }
            state.perform { _ = try await state.engine.replan(paperID: id) }
        } label: {
            Label(L.Detail.replanWithPriority, systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.link)
        .font(.caption)
        .help(L.Detail.replanHelp)
        .transition(.opacity)
    }
}

// MARK: - DDL

/// `[DatePicker] (自动|📌固定)`, `[推迟一天] [⋯]`, the chip preview and the at-risk line.
struct DetailDeadlineControl: View {
    let state: AppState
    let row: PaperRow
    let today: LocalDate
    let lang: UILang

    /// DatePicker value not yet committed (debounced so stepping through days pins once).
    @State private var draft: Date?
    @State private var commitTask: Task<Void, Never>?
    @State private var showDatePopover = false
    @State private var popoverDate = Date()

    private var paper: Paper { row.paper }
    private var isDone: Bool { paper.status == .done }
    private var deadline: LocalDate? { paper.scheduleMode == .none ? nil : paper.deadline }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if isDone {
                DDLChip(spec: chipSpec).fixedSize()
            } else if let deadline {
                HStack(spacing: 8) {
                    DatePicker(L.Detail.deadline, selection: dateBinding(deadline), displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .fixedSize()
                    modeIndicator
                }
                DetailFlowLayout(spacing: 8, lineSpacing: 6) {
                    DDLChip(spec: chipSpec).fixedSize()
                    Button(L.Detail.postponeDay) { run { try await $0.postponeDay(paperID: $1) } }
                        .help(L.Detail.postponeDayHelp)
                    moreMenu
                }
                .controlSize(.small)
            } else {
                DetailFlowLayout(spacing: 8, lineSpacing: 6) {
                    DDLChip(spec: chipSpec).fixedSize()
                    Button(L.Detail.setDate) {
                        popoverDate = today.adding(days: 7).date(hour: 12, minute: 0)
                        showDatePopover = true
                    }
                    .popover(isPresented: $showDatePopover, arrowEdge: .bottom) { datePopover }
                    moreMenu
                }
                .controlSize(.small)
            }
            if row.atRisk, !isDone { atRiskLine }
        }
        .onChange(of: paper.deadline) { draft = nil }
        .onChange(of: paper.scheduleMode) { draft = nil }
    }

    // Chip preview (DeadlineLabel + SharedStrings, same as the card and the widget).
    private var chipSpec: ChipSpec {
        let shown = draft.map { LocalDate($0) } ?? deadline
        return DeadlineLabel.chip(deadline: shown, done: isDone, doneAt: paper.doneAt.map { LocalDate($0) },
                                  pinned: draft != nil || paper.scheduleMode == .pinned,
                                  provisional: draft == nil && paper.provisional, atRisk: row.atRisk,
                                  today: today, lang: lang)
    }

    @ViewBuilder private var modeIndicator: some View {
        switch paper.scheduleMode {
        case .pinned:
            DetailCapsuleTag(text: L.Detail.modePinned, systemImage: "pin.fill", tint: .orange)
                .help(L.Detail.modePinnedHelp)
        case .auto:
            DetailCapsuleTag(text: paper.provisional ? L.Detail.modeAutoProvisional : L.Detail.modeAuto,
                             systemImage: "calendar.badge.clock")
                .help(paper.provisional ? L.Detail.modeAutoProvisionalHelp : L.Detail.modeAutoHelp)
        case .none:
            EmptyView()
        }
    }

    private var moreMenu: some View {
        Menu {
            if deadline != nil {
                Button(L.Detail.postponeWeek) { run { try await $0.postponeWeek(paperID: $1) } }
                Divider()
                Button(L.Detail.restoreAuto) { run { try await $0.restoreAutoDeadline(paperID: $1) } }
                    .disabled(paper.scheduleMode == .auto)
                Button(L.Detail.unschedule) { run { try await $0.unschedule(paperID: $1) } }
            } else {
                Button(L.Detail.scheduleAutomatically) { run { try await $0.restoreAutoDeadline(paperID: $1) } }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L.Detail.moreDeadlineActions)
        .accessibilityLabel(L.Detail.moreDeadlineActions)
    }

    private var datePopover: some View {
        VStack(alignment: .trailing, spacing: 10) {
            DatePicker(L.Detail.deadline, selection: $popoverDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Button(L.cancel) { showDatePopover = false }
                    .keyboardShortcut(.cancelAction)
                Button(L.Detail.pinThisDate) {
                    showDatePopover = false
                    let day = LocalDate(popoverDate)
                    run { try await $0.pinDeadline(paperID: $1, date: day) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private var atRiskLine: some View {
        Label {
            Text(DeadlineLabel.atRiskHint(finish: row.finish, today: today, lang: lang))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func dateBinding(_ deadline: LocalDate) -> Binding<Date> {
        Binding(
            get: { draft ?? deadline.date(hour: 12, minute: 0) },
            set: { new in
                draft = new
                scheduleCommit(new)
            })
    }

    /// 设定日期 = pin (mode pinned, origin user). Debounced: typing/stepping pins once.
    private func scheduleCommit(_ date: Date) {
        commitTask?.cancel()
        let id = row.id
        let current = paper.deadline, mode = paper.scheduleMode
        commitTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let day = LocalDate(date)
            if day == current, mode == .pinned {
                draft = nil
                return
            }
            do { _ = try await state.engine.pinDeadline(paperID: id, date: day) } catch {
                draft = nil
                state.report(error)
            }
        }
    }

    private func run(_ op: @escaping (Engine, String) async throws -> Paper) {
        let engine = state.engine, id = row.id
        state.perform { _ = try await op(engine, id) }
    }
}

// MARK: - Estimate

/// `预计 65′ (stepper ±5) · 剩 40′ · 今天计划 25′`.
struct DetailEstimateControl: View {
    let state: AppState
    let row: PaperRow

    @State private var draft: Int?
    @State private var commitTask: Task<Void, Never>?

    private var paper: Paper { row.paper }
    /// nil until the paper has an estimate (the stepper then starts from a rounded guess).
    private var shown: Int? { draft ?? paper.estMinutes }
    private var value: Int { shown ?? DetailFormat.fallbackEstimate(row.remainingMinutes) }
    /// Without a checklist the remaining time *is* the estimate.
    private var remaining: Int? { row.totalCount == 0 ? shown : row.remainingMinutes }

    var body: some View {
        DetailFlowLayout(spacing: 6, lineSpacing: 4) {
            Stepper(value: binding, in: 5...(24 * 60), step: 5) {
                Text(shown.map { L.Detail.minutes($0) } ?? "—").monospacedDigit()
            }
            .fixedSize()
            .disabled(paper.status == .done)
            .help(L.Detail.estimateHelp)
            .accessibilityLabel(L.Detail.estimate)
            .accessibilityValue(shown.map { L.Detail.minutes($0) } ?? "—")
            if let source = sourceLabel {
                DetailCapsuleTag(text: source)
            }
            if let remaining {
                DetailDot()
                Text(L.Detail.remaining(remaining)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
            }
            if let today = row.minutesToday {
                DetailDot()
                Text(L.Detail.plannedToday(today)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
            }
        }
        .font(.callout)
        .onChange(of: paper.estMinutes) { draft = nil }
    }

    private var sourceLabel: String? {
        if draft != nil { return L.Detail.estimateByUser }
        guard paper.estMinutes != nil else { return nil }
        switch paper.estSource {
        case .user: return L.Detail.estimateByUser
        case .agent: return "AI"       // Claude or ChatGPT
        case .heuristic: return L.Detail.estimateHeuristic
        }
    }

    private var binding: Binding<Int> {
        Binding(
            get: { value },
            set: { new in
                draft = new
                commitTask?.cancel()
                let id = row.id
                commitTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    do { _ = try await state.engine.setEstimate(paperID: id, minutes: new) } catch {
                        draft = nil
                        state.report(error)
                    }
                }
            })
    }
}
