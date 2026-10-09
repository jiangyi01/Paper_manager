import SwiftUI
import PaperDeckCore

/// The detail inspector's collapsible "Explanations" section (READING_ASSIST_PLAN §6.0 slot, LN §7.6):
/// this paper's explanations, pinned first, each with its page chip (the reader opens there and marks
/// a reader explanation's exact place), Copy, Pin and Save to Notes. Hidden while Explain doesn't ship
/// and while the paper has none, so the inspector looks exactly as before. Owned by the Explain UI
/// lane (Slice A).
struct ExplanationsSection: View {
    let state: AppState
    let row: PaperRow
    /// `--explain-render`: draws the section while Explain is hidden.
    static var previewOverride = false

    @State private var model: ExplainHistoryModel?
    @State private var showAll = false

    private var shown: Bool { ExplainCoordinator.isAvailable || Self.previewOverride }

    var body: some View {
        if shown {
            content
                .task(id: row.id) { await reload() }
                .onReceive(NotificationCenter.default.publisher(for: .explainHistoryChanged)) { _ in
                    Task { await reload() }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let model, model.paperID == row.id, !model.threads.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                DetailSection(L.Explain.sectionTitle, key: "explanations", accessory: { expanded in
                    if !expanded { Text(verbatim: "\(model.threads.count)").monospacedDigit() }
                }) {
                    VStack(alignment: .leading, spacing: 8) {
                        ExplainHistoryList(model: model, app: state,
                                           limit: showAll ? nil : ExplainHistory.inspectorLimit)
                        if model.threads.count > ExplainHistory.inspectorLimit {
                            Button(showAll ? L.Explain.collapseQuote : L.Explain.showAll(model.threads.count)) {
                                showAll.toggle()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                }
            }
        } else {
            // Loads in the background; nothing to show yet.
            Color.clear.frame(height: 0)
        }
    }

    private func reload() async {
        let m: ExplainHistoryModel
        if let existing = model, existing.paperID == row.id {
            m = existing
        } else {
            m = ExplainHistoryModel(paperID: row.id, app: state)
            showAll = false
        }
        await m.load()
        model = m
    }

    /// `--explain-render`: the section over fixture records.
    static func preview(state: AppState, row: PaperRow, records: [ExplanationRecord]) -> some View {
        let m = ExplainHistoryModel(paperID: row.id, app: state)
        m.applyRenderFixture(records, expanded: Set(records.prefix(1).map(\.threadID)))
        return ExplanationsSectionPreview(model: m, state: state)
    }
}

/// The section's look over a given model (renders).
private struct ExplanationsSectionPreview: View {
    let model: ExplainHistoryModel
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            DetailSection(L.Explain.sectionTitle, key: "explanations-preview") {
                ExplainHistoryList(model: model, app: state, limit: ExplainHistory.inspectorLimit)
            }
        }
    }
}
