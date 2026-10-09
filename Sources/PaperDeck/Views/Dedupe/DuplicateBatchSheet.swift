import SwiftUI
import PaperDeckCore

/// The batch review (DQ §4.2; READING_ASSIST_PLAN §6.3 B3): the open reviews of a folder import,
/// of a library check, or all of them, one row each — each row on its suggested choice, which
/// the user may override; "Set all to …" applies a preset to every row that offers it. [Apply N]
/// resolves them (`DedupeUIModel.resolveBatch`: one toast, one Undo for all); [Decide Later]
/// leaves every row open. [Details…] opens a row's own decision sheet (its options: checklist,
/// DDL, moving back to To Read). Nothing changes before [Apply].
@Observable
final class DuplicateBatchModel {
    enum Origin: Equatable {
        /// One import's reviews.
        case importBatch
        /// A library check's.
        case check
        /// Every open review (Duplicates ▸ Review All).
        case all
    }

    enum Phase: Equatable { case loading, ready, applying, finished }

    @ObservationIgnored private weak var state: AppState?
    @ObservationIgnored private let ids: [String]
    let origin: Origin
    private(set) var rows: [DupBatchRow] = []
    private(set) var phase: Phase = .loading
    /// [Ask AI] per row (review id → state; absent = hidden).
    private(set) var judges: [String: DuplicateSheetModel.JudgePhase] = [:]
    private(set) var failedCount = 0

    init(state: AppState, ids: [String], origin: Origin) {
        self.state = state
        self.ids = ids
        self.origin = origin
    }

    /// A sheet over fixed rows without an engine (renders, the self-test).
    init(fixture rows: [DupBatchRow], origin: Origin = .importBatch,
         judges: [String: DuplicateSheetModel.JudgePhase] = [:]) {
        ids = rows.map(\.id)
        self.origin = origin
        self.rows = rows
        self.judges = judges
        phase = .ready
    }

    var appliesCount: Int { rows.count }
    var changedCount: Int { rows.count(where: \.isOverridden) }
    var isBusy: Bool { phase == .loading || phase == .applying }

    func load() async {
        guard let state, phase == .loading else { return }
        rows = await state.engine.duplicateBatchRows(ids: ids)
        phase = rows.isEmpty ? .finished : .ready
        await loadJudges()
    }

    private func loadJudges() async {
        guard let state, DedupeUIModel.judgeShips, state.dedupe.judgeEnabled else {
            judges = [:]
            return
        }
        var out: [String: DuplicateSheetModel.JudgePhase] = [:]
        for row in rows { out[row.id] = DuplicateSheetModel.phase(await state.engine.duplicateJudgeStatus(reviewID: row.id)) }
        judges = out
    }

    /// A row's choice — an explicit pick even when it is the suggestion (B3-2: an [Ask AI] answer
    /// that later moves the suggestion doesn't move it).
    func set(_ kind: DupChoiceKind, for id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].detail.choices.contains(kind) else { return }
        rows[i].override = kind
    }

    func setAll(_ preset: DupBatchPreset) {
        rows = DupBatch.applying(preset, to: rows)
    }

    /// The engine items of [Apply], in the rows' order.
    var items: [(reviewID: String, choice: DupChoice)] { rows.map { ($0.id, $0.dupChoice) } }

    func apply() async {
        guard let state, phase == .ready else { return }
        phase = .applying
        let result = await state.dedupe.resolveBatch(items)
        failedCount = result.failed.count
        phase = .finished
    }

    /// One row's judge turn (its own click and ticket); the row is re-read with the answer. The
    /// user's explicit pick (a picker or a preset, even one equal to the old suggestion) is kept
    /// (`DupBatchRow.refreshed`, B3-2); only a row without one follows the AI-moved suggestion.
    func askJudge(_ id: String, ticket: ConsentTicket) async {
        guard let state else { return }
        judges[id] = .asking
        do {
            _ = try await state.dedupe.askJudge(id, ticket: ticket)
            if let fresh = try? await state.engine.duplicateReviewDetail(id: id), fresh.review.state == .open,
               let i = rows.firstIndex(where: { $0.id == id }) {
                rows[i] = rows[i].refreshed(with: fresh)
            }
            judges[id] = DuplicateSheetModel.phase(await state.engine.duplicateJudgeStatus(reviewID: id))
        } catch let e as DupJudgeError {
            judges[id] = .failed(L.Dedupe.judgeFailed(e))
        } catch {
            judges[id] = .failed(String(describing: error))
        }
    }
}

struct DuplicateBatchSheet: View {
    @Bindable var model: DuplicateBatchModel
    /// Closes the sheet; a review id: then open that row's own decision sheet.
    let close: (_ details: String?) -> Void

    static let width: CGFloat = 700

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.phase == .loading && model.rows.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L.Dedupe.loading).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                presets
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.rows) { row in
                            DuplicateBatchRowView(row: row, judge: model.judges[row.id] ?? .hidden, busy: model.isBusy,
                                                  choose: { model.set($0, for: row.id) },
                                                  details: { close(row.id) },
                                                  ask: { ticket in Task { await model.askJudge(row.id, ticket: ticket) } })
                        }
                    }
                }
                .frame(maxHeight: 440)
                .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(22)
        .frame(width: Self.width)
        .task { await model.load() }
        .onChange(of: model.phase) { _, phase in if phase == .finished { close(nil) } }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 24))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L.Dedupe.batchTitle(model.rows.count)).font(.title3.weight(.semibold))
                    Spacer(minLength: 8)
                    HelpButton(.duplicates)
                }
                Text(L.Dedupe.batchSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var presets: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(DupBatchPreset.allCases, id: \.self) { p in
                    Button(L.Dedupe.preset(p)) { model.setAll(p) }
                }
            } label: {
                Text(L.Dedupe.setAll)
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(model.isBusy)
            if model.changedCount > 0 {
                Text(L.Dedupe.changed(model.changedCount)).font(.caption).foregroundStyle(.secondary)
                Button(L.Dedupe.preset(.suggested)) { model.setAll(.suggested) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(model.isBusy)
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(L.Dedupe.batchUndoHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if model.phase == .applying { ProgressView().controlSize(.small) }
            Button(L.Dedupe.decideLater) { close(nil) }
                .keyboardShortcut(.cancelAction)
                .disabled(model.phase == .applying)
            Button(L.Dedupe.applyN(model.appliesCount)) { Task { await model.apply() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.rows.isEmpty || model.isBusy)
        }
    }
}

/// One review: the new file, what it matched, why, the band and AI answer, the choice.
struct DuplicateBatchRowView: View {
    let row: DupBatchRow
    let judge: DuplicateSheetModel.JudgePhase
    let busy: Bool
    let choose: (DupChoiceKind) -> Void
    let details: () -> Void
    let ask: (ConsentTicket) -> Void

    private var d: DupReviewDetail { row.detail }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: d.explanation.headline).font(.callout.weight(.semibold)).lineLimit(1)
                    if d.review.relation.isSameWork {
                        Text(L.Dedupe.band(d.review.band))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                    if d.review.hold != .none {
                        Image(systemName: "pause.circle.fill").foregroundStyle(.orange).font(.caption)
                            .help(L.Dedupe.heldHint(d.review.hold))
                    }
                }
                Text(verbatim: L.Dedupe.newLine(newTitle))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(verbatim: d.review.matchesHistory ? L.Dedupe.removedLine(existingTitle) : L.Dedupe.libraryLine(existingTitle))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let line = d.explanation.versionLine ?? d.explanation.historyLine {
                    Text(verbatim: line).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                DupJudgeSection(review: d.review, phase: judge, busy: busy, compact: true, ask: ask)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Picker(selection: Binding(get: { row.choice }, set: { choose($0) })) {
                    ForEach(d.choices, id: \.self) { kind in
                        Text(kind == row.suggested ? "\(DupChoiceWords.title(kind, d)) · \(L.Dedupe.suggestedMark)"
                             : DupChoiceWords.title(kind, d)).tag(kind)
                    }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .fixedSize()
                .disabled(busy)
                .help(DupChoiceWords.detail(row.choice, d))
                Button(L.Dedupe.details, action: details)
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(busy)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(row.isOverridden ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035)))
        .accessibilityElement(children: .contain)
    }

    private var newTitle: String {
        let t = d.new.title.isEmpty ? (d.new.fileName ?? "") : d.new.title
        return t.isEmpty ? L.Dedupe.waitingFile : t
    }

    private var existingTitle: String { d.existing.title }
}
