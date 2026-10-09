import SwiftUI
import PaperDeckCore

/// The inspector's per-paper AI policy (READING_ASSIST_PLAN §5 `paper_policy`): "Unpublished /
/// confidential" (every assist surface asks first) and "Never use AI" (no assist turn at all).
/// Shown only once a surface that can send a paper's content ships (`AssistRollout.policyToggles`).
/// Lead-owned (Slice 0).
struct PaperPolicyToggles: View {
    let state: AppState
    let row: PaperRow

    @State private var confidential = false
    @State private var neverAI = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.Policy.section)
                .font(.headline)
            Toggle(isOn: Binding(get: { confidential }, set: { confidential = $0; save() })) {
                Text(L.Policy.confidential)
                Text(L.Policy.confidentialHint)
            }
            Toggle(isOn: Binding(get: { neverAI }, set: { neverAI = $0; save() })) {
                Text(L.Policy.neverAI)
                Text(L.Policy.neverAIHint)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!loaded || row.paper.isDeleted)
        .task(id: row.id) { await load() }
    }

    private func load() async {
        let policy = try? await state.engine.paperPolicy(paperID: row.id)
        confidential = policy?.confidential ?? false
        neverAI = policy?.neverAI ?? false
        loaded = true
    }

    private func save() {
        let id = row.id, c = confidential, n = neverAI
        state.perform { _ = try await state.engine.setPaperPolicy(paperID: id, confidential: c, neverAI: n) }
    }
}
