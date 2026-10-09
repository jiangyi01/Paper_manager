import SwiftUI
import PaperDeckCore

/// Settings ▸ Library ▸ Duplicates: the master switch, the sensitivity of the title-and-text
/// matches, the history of removed papers (with Clear History), a check of the library, and —
/// once Explain & Ask can be turned on — "Ask AI" (off by default: [Ask AI] then appears in the
/// decision sheets; it runs only on that click, `dedupe.ai.dailyCap` times a day at most).
/// Placed by `LibrarySettingsTab` after the import section. Owned by Slice B.
struct DedupeSettingsSection: View {
    let state: AppState
    /// Draw the AI judge's switch even before it ships (renders).
    var showsJudge = DedupeUIModel.judgeShips
    @State private var historyCount: Int?
    @State private var confirmClear = false

    var body: some View {
        if DedupeUIModel.isAvailable {
            @Bindable var settings = state.settings
            Section {
                Toggle(isOn: $settings.dedupe.enabled) {
                    Text(L.Dedupe.enabled)
                    Text(settings.dedupe.enabled ? L.Dedupe.enabledHint : L.Dedupe.offHint)
                }
                Picker(selection: $settings.dedupe.sensitivity) {
                    ForEach(DedupeSettings.Sensitivity.allCases, id: \.self) { s in
                        Text(L.Dedupe.sensitivityName(s)).tag(s)
                    }
                } label: {
                    Text(L.Dedupe.sensitivity)
                    Text(L.Dedupe.sensitivityHint)
                }
                .disabled(!settings.dedupe.enabled)
                Toggle(isOn: $settings.dedupe.history) {
                    Text(L.Dedupe.history)
                    Text(L.Dedupe.historyHint)
                }
                .disabled(!settings.dedupe.enabled)
                if showsJudge {
                    Toggle(isOn: Binding(get: { state.dedupe.judgeEnabled }, set: { state.dedupe.setJudgeEnabled($0) })) {
                        Text(L.Dedupe.judgeToggle)
                        Text(L.Dedupe.judgeToggleHint(settings.dedupe.aiDailyCap))
                    }
                    .disabled(!settings.dedupe.enabled)
                }
                HStack {
                    Button(L.Dedupe.checkLibraryEllipsis) { state.dedupe.checkSelected(ids: []) }
                        .disabled(!settings.dedupe.enabled)
                    Spacer()
                    if let n = historyCount, n > 0 {
                        Button(L.Dedupe.clearHistory(n)) { confirmClear = true }
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Text(L.Dedupe.section)
                    HelpButton(.duplicates)
                }
            }
            .task {
                historyCount = await state.engine.duplicateHistoryCount()
                await state.dedupe.loadJudgeSwitch()
            }
            .alert(L.Dedupe.clearHistoryTitle(historyCount ?? 0), isPresented: $confirmClear) {
                Button(L.Dedupe.clear, role: .destructive) { clearHistory() }
                Button(L.cancel, role: .cancel) {}
            } message: {
                Text(L.Dedupe.clearHistoryMessage)
            }
        }
    }

    private func clearHistory() {
        state.perform {
            _ = try await state.engine.clearDuplicateHistory()
            historyCount = await state.engine.duplicateHistoryCount()
        }
    }
}
