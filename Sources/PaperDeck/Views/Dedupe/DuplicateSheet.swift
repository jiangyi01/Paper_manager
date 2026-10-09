import SwiftUI
import PaperDeckCore

/// The decision sheet of one duplicate review, or of a queue of them ("1 of 3"), DQ §4.1:
/// the two sides, the reasons, and the choices that apply (the default preselected, never
/// applied by itself). [Apply] goes through `DedupeUIModel.resolve` (a toast with Undo for 30 s);
/// [Decide Later] moves on to the next review of the queue (or closes) and leaves this one open.
@Observable
final class DuplicateSheetModel {
    enum Phase: Equatable {
        case loading, ready, applying
        case failed(String)
        /// Nothing (left) to decide: the sheet closes.
        case finished
    }

    enum DeadlineKind: String, CaseIterable, Identifiable {
        case auto, date, none
        var id: String { rawValue }
    }

    /// [Ask AI] (B3): hidden (the judge is off, or nothing for it to weigh), offered, blocked with a
    /// reason the user can act on, running, or failed (the review is unchanged).
    enum JudgePhase: Equatable {
        case hidden
        case ready(DupJudgeStatus)
        case blocked(String)
        case asking
        case failed(String)
    }

    @ObservationIgnored private weak var state: AppState?
    private(set) var queue: [String]
    private(set) var index = 0
    private(set) var detail: DupReviewDetail?
    private(set) var phase: Phase = .loading

    var choice: DupChoiceKind = .skip
    /// The user picked `choice` themselves (even the preselected default): an [Ask AI] answer that
    /// moves the default keeps it (B3-2).
    private(set) var choicePicked = false
    var moveBackToRead = false
    var checklist: ChecklistReset = .keepProgress
    var deadline: DeadlineKind = .auto
    var deadlineDate: Date
    var useNewFile = false
    var linkAsRelated = false
    private(set) var judge: JudgePhase = .hidden
    @ObservationIgnored let today: LocalDate

    init(state: AppState, queue: [String]) {
        self.state = state
        self.queue = queue
        today = state.snapshot?.today.today ?? LocalDate.today()
        deadlineDate = today.adding(days: 7).date(hour: 12, minute: 0)
    }

    /// A sheet showing `detail` without an engine (renders; `--dedupe-render`).
    init(fixture detail: DupReviewDetail, queueCount: Int = 1, today: LocalDate, judge: JudgePhase = .hidden) {
        queue = [detail.id] + (1..<max(1, queueCount)).map { "fixture-\($0)" }
        self.today = today
        deadlineDate = today.adding(days: 7).date(hour: 12, minute: 0)
        show(detail)
        self.judge = judge
    }

    /// "1 of 3" when the sheet walks a queue.
    var position: (Int, Int)? { queue.count > 1 ? (index + 1, queue.count) : nil }

    var isBusy: Bool { phase == .loading || phase == .applying }

    /// The review at `index` (skipping ones that were answered meanwhile). Nothing to do when
    /// it is on screen already (the sheet appearing again keeps the user's choice).
    func load() async {
        guard let state else { return }
        if index < queue.count, detail?.id == queue[index], phase == .ready { return }
        phase = .loading
        while index < queue.count {
            if let d = try? await state.engine.duplicateReviewDetail(id: queue[index]), d.review.state == .open {
                show(d)
                await loadJudge()
                return
            }
            index += 1
        }
        phase = .finished
    }

    private func show(_ d: DupReviewDetail) {
        detail = d
        choice = d.defaultChoice
        choicePicked = false
        moveBackToRead = false
        checklist = .keepProgress
        deadline = .auto
        useNewFile = false
        linkAsRelated = !d.review.relation.isSameWork
        phase = .ready
    }

    /// [Ask AI]'s state for the review on screen (`DedupeUIModel.judgeShips` and the switch first).
    func loadJudge() async {
        guard let state, let d = detail, DedupeUIModel.judgeShips, state.dedupe.judgeEnabled else {
            judge = .hidden
            return
        }
        judge = Self.phase(await state.engine.duplicateJudgeStatus(reviewID: d.id))
    }

    /// What the sheet shows for a status: the button, a reason worth showing, or nothing.
    static func phase(_ s: DupJudgeStatus) -> JudgePhase {
        guard let block = s.block else { return .ready(s) }
        return L.Dedupe.judgeBlocked(block).map(JudgePhase.blocked) ?? .hidden
    }

    /// The user picks a choice (a row's click): explicit, even when it is the default.
    func pick(_ kind: DupChoiceKind) {
        choice = kind
        choicePicked = true
    }

    /// The click's judge turn; the review comes back re-banded (or unchanged) with the AI's answer.
    /// The user's own pick is kept — also one equal to the old default (B3-2: the AI only re-bands,
    /// it never changes what the user chose); without one the sheet preselects the new default.
    func askJudge(_ ticket: ConsentTicket) async {
        guard let state, let d = detail else { return }
        judge = .asking
        do {
            _ = try await state.dedupe.askJudge(d.id, ticket: ticket)
            let picked = choicePicked ? choice : nil
            if let fresh = try? await state.engine.duplicateReviewDetail(id: d.id), fresh.review.state == .open {
                let options = (moveBackToRead, checklist, deadline, deadlineDate, useNewFile, linkAsRelated)
                show(fresh)
                if let kept = DupBatch.carry(picked, into: fresh) { pick(kept) }
                (moveBackToRead, checklist, deadline, deadlineDate, useNewFile, linkAsRelated) = options
            }
            await loadJudge()
        } catch let e as DupJudgeError {
            judge = .failed(L.Dedupe.judgeFailed(e))
        } catch {
            judge = .failed(String(describing: error))
        }
    }

    /// The choice with its options, as the engine takes it.
    var dupChoice: DupChoice {
        switch choice {
        case .keepNew: return .keepNew(reread: moveBackToRead)
        case .rereadEarlier:
            let d: DeadlineChoice
            switch deadline {
            case .auto: d = .auto
            case .date: d = .date(LocalDate(deadlineDate))
            case .none: d = .unscheduled
            }
            return .rereadEarlier(checklist: checklist, deadline: d, useNewFile: useNewFile)
        case .keepBoth: return .keepBoth(linkAsRelated: linkAsRelated)
        case .skip: return .skip
        case .attachSupplement: return .attachSupplement
        case .addAgain: return .addAgain
        }
    }

    /// [Apply]: then the next review of the queue, or `.finished`.
    func apply() async {
        guard let d = detail, let dedupe = state?.dedupe else { return }
        phase = .applying
        do {
            _ = try await dedupe.resolve(d.id, dupChoice)
        } catch let e as DupResolutionError {
            switch e {
            case .reviewClosed, .reviewNotFound, .fileExpired:
                // Answered elsewhere (a toast) or lost with a relaunch: nothing left to do here.
                index += 1
                await load()
            default:
                phase = .failed(e.message(L.lang))
            }
            return
        } catch {
            phase = .failed(String(describing: error))
            return
        }
        index += 1
        await load()
    }

    /// [Decide Later]: this one stays open; on to the next.
    func later() async {
        index += 1
        if state == nil || index >= queue.count { phase = .finished; return }
        await load()
    }
}

struct DuplicateSheet: View {
    @Bindable var model: DuplicateSheetModel
    let close: () -> Void

    static let width: CGFloat = 580

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let d = model.detail {
                sides(d)
                reasons(d)
                DupJudgeSection(review: d.review, phase: model.judge, busy: model.isBusy) { ticket in
                    Task { await model.askJudge(ticket) }
                }
                choices(d)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L.Dedupe.loading).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }
            if case .failed(let message) = model.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(22)
        .frame(width: Self.width)
        .task { await model.load() }
        .onChange(of: model.phase) { _, phase in if phase == .finished { close() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "square.on.square")
                .font(.system(size: 26))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.detail?.explanation.headline ?? L.Dedupe.sheetTitle)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let (i, n) = model.position {
                        Text(L.Dedupe.counter(i, n))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    HelpButton(.duplicates)
                }
                if let line = model.detail?.explanation.versionLine {
                    Text(line).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Sides

    private func sides(_ d: DupReviewDetail) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // "Newer" only between versions of one work (a supplement isn't an older paper).
            let versions = d.review.relation.isSameWork
            SideCard(caption: L.Dedupe.newSide, summary: d.new, newer: versions && d.review.newerSide == .new,
                     lines: newLines(d))
            SideCard(caption: existingCaption(d), summary: d.existing, newer: versions && d.review.newerSide == .existing,
                     lines: existingLines(d))
        }
    }

    private func existingCaption(_ d: DupReviewDetail) -> String {
        if d.existing.purgedAt != nil { return L.Dedupe.existingRemoved }
        if d.existing.deletedAt != nil { return L.Dedupe.existingDeleted }
        return L.Dedupe.existingSide
    }

    private func newLines(_ d: DupReviewDetail) -> [String] {
        var out: [String] = []
        if let v = versionLine(d.new) { out.append(v) }
        if let name = d.new.fileName, name != d.new.title { out.append(name) }
        if d.new.checklistDone > 0 { out.append(L.Dedupe.checklist(d.new.checklistDone, d.new.checklistTotal)) }
        if d.new.notesChars > 0 { out.append(L.Dedupe.notes(d.new.notesChars)) }
        return out
    }

    private func existingLines(_ d: DupReviewDetail) -> [String] {
        var out: [String] = []
        if let v = versionLine(d.existing) { out.append(v) }
        if let h = d.explanation.historyLine { out.append(h) }
        if d.existing.purgedAt == nil {
            var parts: [String] = []
            if d.existing.notesChars > 0 { parts.append(L.Dedupe.notes(d.existing.notesChars)) }
            if d.existing.hasCard { parts.append(L.Dedupe.readingCard) }
            if !parts.isEmpty { out.append(parts.joined(separator: " · ")) }
        }
        return out
    }

    private func versionLine(_ s: DupSideSummary) -> String? {
        var parts: [String] = []
        if let v = s.versionLabel { parts.append(v) }
        if let y = s.year, !(s.versionLabel ?? "").contains(String(y)) { parts.append(String(y)) }
        if let p = s.pages { parts.append(L.Dedupe.pages(p)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Reasons

    @ViewBuilder private func reasons(_ d: DupReviewDetail) -> some View {
        if !d.explanation.evidence.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(L.Dedupe.why).font(.callout.weight(.semibold))
                ForEach(Array(d.explanation.evidence.enumerated()), id: \.offset) { _, line in
                    Label {
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    // MARK: Choices

    private func choices(_ d: DupReviewDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.Dedupe.whatToDo).font(.callout.weight(.semibold))
            ForEach(d.choices, id: \.self) { kind in
                ChoiceRow(title: title(kind, d), detail: detail(kind, d), selected: model.choice == kind,
                          disabled: model.isBusy) {
                    model.pick(kind)
                } options: {
                    if model.choice == kind { options(kind, d) }
                }
            }
        }
    }

    private func title(_ kind: DupChoiceKind, _ d: DupReviewDetail) -> String { DupChoiceWords.title(kind, d) }

    private func detail(_ kind: DupChoiceKind, _ d: DupReviewDetail) -> String { DupChoiceWords.detail(kind, d) }

    @ViewBuilder private func options(_ kind: DupChoiceKind, _ d: DupReviewDetail) -> some View {
        switch kind {
        case .keepNew:
            if d.existing.status == .done {
                Toggle(L.Dedupe.moveBackToRead, isOn: $model.moveBackToRead).disabled(model.isBusy)
            }
        case .rereadEarlier:
            VStack(alignment: .leading, spacing: 6) {
                Picker(L.Dedupe.checklistLabel, selection: $model.checklist) {
                    Text(L.Dedupe.keepProgress).tag(ChecklistReset.keepProgress)
                    Text(L.Dedupe.uncheckAll).tag(ChecklistReset.uncheckAll)
                    if d.canRegenerateChecklist { Text(L.Dedupe.regenerate).tag(ChecklistReset.regenerate) }
                }
                .fixedSize()
                HStack(spacing: 8) {
                    Picker(L.Dedupe.deadlineLabel, selection: $model.deadline) {
                        Text(L.Dedupe.deadlineAuto).tag(DuplicateSheetModel.DeadlineKind.auto)
                        Text(L.Dedupe.deadlinePick).tag(DuplicateSheetModel.DeadlineKind.date)
                        Text(L.Dedupe.deadlineNone).tag(DuplicateSheetModel.DeadlineKind.none)
                    }
                    .fixedSize()
                    if model.deadline == .date {
                        DatePicker("", selection: $model.deadlineDate, in: model.today.startOfDay()...,
                                   displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.field)
                            .fixedSize()
                    }
                }
                if d.review.relation.isSameWork, d.review.relation != .sameFile {
                    Toggle(L.Dedupe.useNewFile, isOn: $model.useNewFile)
                }
            }
            .disabled(model.isBusy)
        case .keepBoth:
            if d.review.relation.isSameWork {
                Toggle(L.Dedupe.linkAsRelated, isOn: $model.linkAsRelated).disabled(model.isBusy)
            }
        case .skip, .attachSupplement, .addAgain:
            EmptyView()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            if let d = model.detail {
                Text(d.review.isParked ? L.Dedupe.parkedHint : L.Dedupe.heldHint(d.review.hold))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if model.phase == .applying { ProgressView().controlSize(.small) }
            Button(model.detail == nil ? L.Dedupe.close : L.Dedupe.decideLater) {
                if model.detail == nil { close() } else { Task { await model.later() } }
            }
            .keyboardShortcut(.cancelAction)
            .disabled(model.phase == .applying)
            Button(L.Dedupe.apply) { Task { await model.apply() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.detail == nil || model.isBusy)
        }
    }
}

/// One side of the pair: caption (with "newer"), title, a few facts.
private struct SideCard: View {
    let caption: String
    let summary: DupSideSummary
    let newer: Bool
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(caption.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if newer {
                    Label(L.Dedupe.newer, systemImage: "arrow.up.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                }
            }
            Text(verbatim: summary.title.isEmpty ? (summary.fileName ?? "—") : summary.title)
                .font(.callout.weight(.medium))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.5)))
        .accessibilityElement(children: .combine)
    }
}

/// A radio row: the title and its one-line consequence; the chosen row shows its options.
private struct ChoiceRow<Options: View>: View {
    let title: String
    let detail: String
    let selected: Bool
    let disabled: Bool
    let select: () -> Void
    @ViewBuilder let options: () -> Options

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: select) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.callout.weight(selected ? .semibold : .regular))
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            options()
                .padding(.leading, 26)
                .font(.callout)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.08) : .clear))
    }
}

/// The choices' titles and one-line consequences (the decision sheet and the batch review).
enum DupChoiceWords {
    static func title(_ kind: DupChoiceKind, _ d: DupReviewDetail) -> String {
        let deleted = d.existing.deletedAt != nil
        switch kind {
        case .keepNew: return deleted ? L.Dedupe.restoreWithNew : L.Dedupe.keepNew
        case .rereadEarlier: return deleted ? L.Dedupe.restoreEarlier : L.Dedupe.rereadEarlier
        case .keepBoth: return d.review.relation.isSameWork ? L.Dedupe.keepBoth : L.Dedupe.keepBothRelated
        case .skip: return d.review.isParked ? L.Dedupe.skip : L.Dedupe.skipCommitted
        case .attachSupplement: return L.Dedupe.attachSupplement
        case .addAgain: return L.Dedupe.addAgain
        }
    }

    static func detail(_ kind: DupChoiceKind, _ d: DupReviewDetail) -> String {
        let deleted = d.existing.deletedAt != nil
        switch kind {
        case .keepNew: return deleted ? L.Dedupe.restoreWithNewDetail : L.Dedupe.keepNewDetail
        case .rereadEarlier: return deleted ? L.Dedupe.restoreEarlierDetail : L.Dedupe.rereadEarlierDetail
        case .keepBoth: return d.review.relation.isSameWork ? L.Dedupe.keepBothDetail : L.Dedupe.keepBothRelatedDetail
        case .skip: return d.review.isParked ? L.Dedupe.skipParkedDetail : L.Dedupe.skipCommittedDetail
        case .attachSupplement: return L.Dedupe.attachSupplementDetail
        case .addAgain: return L.Dedupe.addAgainDetail
        }
    }
}

/// [Ask AI] — the one place a duplicate-judge ticket is minted: in this button's action, at the
/// moment of the click (`AssistContractGrepTests.mintAllowlist`). One click = one judge turn.
struct DupAskAIButton: View {
    let again: Bool
    let disabled: Bool
    let ask: (ConsentTicket) -> Void

    var body: some View {
        Button {
            ask(ConsentTicket.mint(.judge, surface: .dupJudge))
        } label: {
            Label(again ? L.Dedupe.askAIAgain : L.Dedupe.askAI, systemImage: "sparkles")
        }
        .controlSize(.small)
        .disabled(disabled)
    }
}

/// The AI judge's line in a decision sheet (or a batch review row): its answer when it gave one,
/// then [Ask AI] with the cost and today's count — or why it can't run, or nothing at all while
/// the judge is off (the default).
struct DupJudgeSection: View {
    let review: DupReview
    let phase: DuplicateSheetModel.JudgePhase
    var busy = false
    var compact = false
    let ask: (ConsentTicket) -> Void

    var body: some View {
        let verdict = review.aiVerdict
        if verdict != nil || phase != .hidden {
            VStack(alignment: .leading, spacing: 4) {
                if let v = verdict { DupVerdictLine(verdict: v, compact: compact) }
                switch phase {
                case .hidden:
                    EmptyView()
                case .ready(let status):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        DupAskAIButton(again: verdict != nil, disabled: busy, ask: ask)
                        if !compact {
                            Text(L.Dedupe.judgeCost(status.usedToday, status.dailyCap))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .blocked(let why):
                    Label(why, systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .asking:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L.Dedupe.askingAI).font(.caption).foregroundStyle(.secondary)
                    }
                case .failed(let why):
                    Label(why, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// "AI: same paper, another version (90%) — reason · Moved from … to …".
struct DupVerdictLine: View {
    let verdict: DupAIVerdict
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(verbatim: L.Dedupe.judgeLine(verdict.verdict, Int((verdict.confidence * 100).rounded())))
                    .font(.callout.weight(.medium))
            } icon: {
                Image(systemName: "sparkles").foregroundStyle(.purple)
            }
            if !verdict.reason.isEmpty, !compact {
                Text(verbatim: verdict.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }
            if let note = Self.note(verdict) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The band it moved, or that it moved nothing because it wasn't sure (a sure answer that
    /// agrees with the band needs no note).
    static func note(_ v: DupAIVerdict) -> String? {
        if v.bandAfter != v.bandBefore { return L.Dedupe.judgeMoved(v.bandBefore, v.bandAfter) }
        return v.isConfident ? nil : L.Dedupe.judgeUnsure
    }
}
