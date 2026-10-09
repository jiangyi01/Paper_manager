import SwiftUI
import PaperDeckCore

/// Settings ▸ Explain & Ask ▸ Ask (a section of Slice A's `AssistSettingsTab`): the default answer
/// depth (Quick — Haiku / Luna — unless the user picks Thorough), the answer language (Auto: the
/// question's), how much paper text one question sends, the papers per Ask window, the models.
/// Owned by Slice C. Nothing here sends anything or turns AI on.
struct QASettingsSection: View {
    let state: AppState

    static let budgets = [40_000, 80_000, 120_000, 200_000]

    var body: some View {
        Section {
            Picker(L.QA.settingsDepth, selection: binding(\.qaDepth)) {
                Text(L.QA.depthQuick).tag(AssistSettings.Depth.quick)
                Text(L.QA.depthThorough).tag(AssistSettings.Depth.thorough)
            }
            .help(L.QA.depthHelp)
            Picker(L.QA.settingsLanguage, selection: binding(\.qaLanguage)) {
                Text(L.QA.langAuto).tag(AssistSettings.AnswerLanguage.auto)
                Text(verbatim: "English").tag(AssistSettings.AnswerLanguage.en)
                Text(verbatim: "中文").tag(AssistSettings.AnswerLanguage.zh)
            }
            .help(L.QA.langHelp)
            Picker(L.QA.settingsBudget, selection: binding(\.qaTextBudget)) {
                ForEach(budgetChoices, id: \.self) { b in Text(L.QA.settingsBudgetValue(b)).tag(b) }
            }
            // The number and its stepper at the trailing edge, like the pickers above. One range
            // everywhere (`AssistSettings.qaMultiMaxRange`): a stored value outside it shows clamped.
            LabeledContent(L.QA.settingsMultiMax) {
                HStack(spacing: 6) {
                    Text(verbatim: "\(multiMax.wrappedValue)").monospacedDigit()
                    Stepper(L.QA.settingsMultiMax, value: multiMax, in: AssistSettings.qaMultiMaxRange).labelsHidden()
                }
            }
            LabeledContent(L.QA.settingsModels) {
                Text(verbatim: models).foregroundStyle(.secondary)
            }
        } header: {
            Text(L.QA.settingsSection)
        } footer: {
            Text(L.QA.settingsFooter).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The fixed choices, plus the stored value when it is another one.
    private var budgetChoices: [Int] {
        let current = state.settings.assist.qaTextBudget
        return Self.budgets.contains(current) ? Self.budgets : (Self.budgets + [current]).sorted()
    }

    private var models: String {
        let a = state.settings.assist
        let p = a.mode.providerKind ?? state.settings.agentProvider
        return L.QA.settingsModelsValue(a.model(p, .quick), a.model(p, .thorough))
    }

    /// `assist.qa.multiMax` within `AssistSettings.qaMultiMaxRange`.
    private var multiMax: Binding<Int> {
        let range = AssistSettings.qaMultiMaxRange
        return Binding(get: { min(max(state.settings.assist.qaMultiMax, range.lowerBound), range.upperBound) },
                       set: { state.settings.assist.qaMultiMax = min(max($0, range.lowerBound), range.upperBound) })
    }

    private func binding<T>(_ key: WritableKeyPath<AssistSettings, T>) -> Binding<T> {
        Binding(get: { state.settings.assist[keyPath: key] }, set: { state.settings.assist[keyPath: key] = $0 })
    }
}
