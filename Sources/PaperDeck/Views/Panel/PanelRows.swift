import SwiftUI
import PaperDeckCore

// Import-progress rows shared by the floating panel (processing state) and the
// menu-bar popover that replaces it while the panel is hidden.

/// ≤ `maxRows` rows of `state.importRows`: every active row first, then the most
/// recently finished ones, shown in arrival order.
struct ImportProgressList: View {
    let state: AppState
    var maxRows: Int = 5
    /// A drop landed but DropIntake is still materializing file promises.
    var showsReceivingPlaceholder = false
    var onOpenPaper: (String) -> Void

    var body: some View {
        let rows = state.importRows
        let shown = Self.pick(rows, max: maxRows)
        let snapshot = state.snapshot
        let today = snapshot?.today.today ?? LocalDate.today()
        let lang = L.lang
        VStack(alignment: .leading, spacing: 4) {
            if showsReceivingPlaceholder && !rows.contains(where: { !$0.stage.isTerminal }) {
                ImportRowView(name: L.panelDroppedFiles,
                              display: ImportStageDisplay(icon: .spinner, text: L.panelStageReceiving),
                              onOpen: nil)
            }
            ForEach(shown) { row in
                let paper = row.paperID.flatMap { snapshot?.row(id: $0)?.paper }
                ImportRowView(name: Self.name(row, paper: paper),
                              display: ImportStageDisplay(row, paper: paper, today: today, lang: lang),
                              onOpen: row.openablePaperID.map { id in { onOpenPaper(id) } })
            }
            if rows.count > shown.count {
                Text(L.panelMoreRows(rows.count - shown.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 34)
            }
        }
    }

    static func pick(_ rows: [ImportRowUpdate], max: Int) -> [ImportRowUpdate] {
        guard rows.count > max else { return rows }
        let indexed = Array(rows.enumerated())
        let active = indexed.filter { !$0.element.stage.isTerminal }.prefix(max)
        let finished = indexed.filter { $0.element.stage.isTerminal }.suffix(max - active.count)
        return (Array(active) + Array(finished)).sorted { $0.offset < $1.offset }.map(\.element)
    }

    /// The paper's title once metadata replaced the file name; the dropped name before.
    private static func name(_ row: ImportRowUpdate, paper: Paper?) -> String {
        if let paper, paper.titleRank > .filename, !paper.title.isEmpty { return paper.title }
        return row.displayName
    }
}

extension ImportRowUpdate {
    /// The library paper this row refers to (new, duplicate or same-work original).
    var paperID: String? {
        switch stage {
        case .added(let id, _, _), .queuedForAI(let id), .duplicate(let id): return id
        case .sameWork(let existing, _): return existing
        default: return nil
        }
    }

    /// Rows that can be clicked to open the paper's detail.
    var openablePaperID: String? {
        switch stage {
        case .added, .queuedForAI, .duplicate: return paperID
        default: return nil
        }
    }
}

/// What one import row shows: icon, stage line and optional download progress.
struct ImportStageDisplay {
    enum Icon {
        case spinner
        case symbol(String, Color)
    }

    var icon: Icon
    var text: String
    var fraction: Double? = nil
    var isProblem = false
    var tint: Color = .secondary
}

extension ImportStageDisplay {
    init(_ row: ImportRowUpdate, paper: Paper?, today: LocalDate, lang: UILang) {
        switch row.stage {
        case .receiving:
            self.init(icon: .spinner, text: L.panelStageReceiving)
        case .downloading(let fraction):
            self.init(icon: .spinner, text: L.panelStageDownloading(fraction.map { Int(($0 * 100).rounded()) }),
                      fraction: fraction)
        case .waitingForCloud:
            self.init(icon: .symbol("icloud.and.arrow.down", .blue), text: L.panelStageCloud)
        case .verifying:
            self.init(icon: .spinner, text: L.panelStageVerifying)
        case .parsing:
            self.init(icon: .spinner, text: L.panelStageParsing)
        case .metadata:
            self.init(icon: .spinner, text: L.panelStageMetadata)
        case .filing:
            self.init(icon: .spinner, text: L.panelStageFiling)
        case .added(_, let deadline, let provisional):
            self.init(added: paper, deadline: deadline, provisional: provisional, queued: false, today: today, lang: lang)
        case .queuedForAI:
            self.init(added: paper, deadline: paper?.deadline, provisional: paper?.provisional ?? true,
                      queued: true, today: today, lang: lang)
        case .duplicate:
            self.init(icon: .symbol("doc.on.doc.fill", .secondary), text: L.panelStageDuplicate)
        case .sameWork:
            self.init(icon: .symbol("questionmark.circle.fill", .orange), text: L.panelStageSameWork,
                      isProblem: true, tint: .orange)
        case .rejected(let reason):
            self.init(icon: .symbol("minus.circle.fill", .orange), text: L.panelStageRejected(reason),
                      isProblem: true, tint: .orange)
        case .failed(let reason):
            self.init(icon: .symbol("exclamationmark.octagon.fill", .red), text: L.panelStageFailed(reason),
                      isProblem: true, tint: .red)
        }
    }

    /// `✓ 已添加 · DDL ≈周五` (+ ` · Claude 排队中` / `Claude 阅读中…`), live from the snapshot.
    private init(added paper: Paper?, deadline: LocalDate?, provisional: Bool, queued: Bool,
                 today: LocalDate, lang: UILang) {
        let live = paper.map { $0.scheduleMode == .none ? nil : $0.deadline } ?? deadline
        let chip = live.map {
            DeadlineLabel.chip(deadline: $0, done: false, doneAt: nil, pinned: false,
                               provisional: paper?.provisional ?? provisional, atRisk: false,
                               today: today, lang: lang).text
        }
        var text = L.panelStageAdded(chip: chip)
        var icon = Icon.symbol("checkmark.circle.fill", .green)
        switch paper?.aiState {
        case .running?:
            text += " · " + L.panelStageClaudeReading
            icon = .spinner
        case .queued?:
            text += " · " + L.panelStageClaudeQueued
        case .done?:
            text += " · " + L.panelStageClaudeDone
        case nil where queued:
            text += " · " + L.panelStageClaudeQueued
        default:
            break
        }
        self.init(icon: icon, text: text)
    }
}

struct ImportRowView: View {
    let name: String
    let display: ImportStageDisplay
    let onOpen: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            iconView
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(display.text)
                    .font(.caption)
                    .foregroundStyle(display.isProblem ? AnyShapeStyle(display.tint) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let fraction = display.fraction {
                    ProgressView(value: min(max(fraction, 0), 1))
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if onOpen != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onOpen != nil ? .isButton : [])
    }

    @ViewBuilder private var iconView: some View {
        switch display.icon {
        case .spinner:
            ProgressView().controlSize(.small)
        case .symbol(let name, let color):
            Image(systemName: name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
        }
    }
}

// MARK: - Feedback rules shared by the panel and the menu-bar popover

enum PanelFeedback {
    /// Nothing left to show: every row reached a terminal stage and every toast is gone
    /// (plain ones expire in AppState, convenience ones via ToastJanitor).
    static func isSettled(_ state: AppState) -> Bool {
        !state.hasActiveImports && state.toasts.isEmpty
    }

    /// Errors / decisions waiting for the user.
    static func needsAttention(_ state: AppState) -> Bool {
        state.toasts.contains(where: \.requiresAttention)
    }
}

/// Detects new import rows / toasts between observations (by id).
struct FeedbackActivity {
    private var seenRows: Set<String> = []
    private var seenToasts: Set<String> = []
    private var lastRows: [ImportRowUpdate] = []

    struct Change {
        var newRows = false
        var newToasts = false
        var rowsChanged = false
    }

    mutating func update(rows: [ImportRowUpdate], toasts: [Toast]) -> Change {
        var change = Change()
        let rowIDs = Set(rows.map(\.id))
        let toastIDs = Set(toasts.map(\.id))
        change.newRows = !rowIDs.isSubset(of: seenRows)
        change.newToasts = !toastIDs.isSubset(of: seenToasts)
        change.rowsChanged = rows != lastRows
        seenRows = rowIDs
        seenToasts = toastIDs
        lastRows = rows
        return change
    }
}
