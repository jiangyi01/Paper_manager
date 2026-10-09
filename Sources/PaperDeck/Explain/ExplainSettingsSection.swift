import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// Settings ▸ Explain & Ask ▸ Explain (next to Settings ▸ Ask): the shortcut (recorder), what it
/// opens, the explanation language (Chinese with English terms by default), the model depth (Quick by
/// default), the daily limit before asking (shared with Ask, `assist.dailySoftCap`), keeping Claude
/// ready while armed, "Ask before every send", how long history is kept, Screen Recording's status
/// with [Open System Settings], and the Services note. Nothing here sends anything or turns AI on
/// (the shared switch above does that). Hidden until Explain ships. Owned by the Explain UI lane.
struct ExplainSettingsSection: View {
    let state: AppState
    /// `--explain-render` only.
    static var previewOverride = false
    /// `--explain-render`: Screen Recording's status to draw (renders never ask macOS).
    static var previewScreenRecording: Bool?

    static var shown: Bool { ExplainCoordinator.isAvailable || previewOverride }
    static let historyChoices = [30, 90, 180, 365]

    @State private var screenOn: Bool?

    var body: some View {
        let a = state.settings.assist
        Section {
            LabeledContent(L.Explain.settingsShortcut) { HotKeyRecorderView(state: state) }
            Picker(L.Explain.settingsOpens, selection: binding(\.explainDefaultMode)) {
                Text(L.Explain.opensFrame).tag(AssistSettings.OverlayMode.frame)
                Text(L.Explain.opensLens).tag(AssistSettings.OverlayMode.lens)
            }
            Picker(L.Explain.settingsLanguage, selection: binding(\.explainLanguage)) {
                Text(L.Explain.langZhTerms).tag(AssistSettings.ExplainLanguage.zh)
                Text(L.Explain.langEnglish).tag(AssistSettings.ExplainLanguage.en)
                Text(L.Explain.langFollowUI).tag(AssistSettings.ExplainLanguage.ui)
            }
            Picker(L.Explain.settingsDepth, selection: binding(\.explainDepth)) {
                Text(L.Explain.depthQuick(models(.quick))).tag(AssistSettings.Depth.quick)
                Text(L.Explain.depthThorough(models(.thorough))).tag(AssistSettings.Depth.thorough)
            }
            LabeledContent(L.Explain.settingsDailyCap) {
                HStack(spacing: 6) {
                    Text(verbatim: L.Explain.dailyCapValue(a.dailySoftCap)).monospacedDigit()
                    Stepper(L.Explain.settingsDailyCap, value: softCap, in: 5...max(5, a.dailyHardCap), step: 5).labelsHidden()
                }
            }
            Toggle(isOn: keepWarm) {
                Text(L.Explain.settingsKeepWarm(AIProviderKind.claude.shortName))
                Text(L.Explain.keepWarmFooter)
            }
            Toggle(L.Explain.settingsAskBeforeSend, isOn: binding(\.explainAskBeforeSend))
            Picker(L.Explain.settingsHistory, selection: binding(\.explainHistoryDays)) {
                ForEach(historyChoices, id: \.self) { d in Text(L.Explain.historyDays(d)).tag(d) }
            }
            LabeledContent(L.Explain.settingsScreen) {
                HStack(spacing: 8) {
                    Text(screenOn == true ? L.Explain.screenOn : L.Explain.screenOff)
                        .foregroundStyle(screenOn == true ? Color.green : Color.secondary)
                        .multilineTextAlignment(.trailing)
                    Button(L.Explain.openSystemSettings) { ScreenPermission.openSystemSettings() }
                    HelpButton(.screenRecording)
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Text(L.Explain.settingsServices).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(L.Explain.openKeyboardShortcuts) { ScreenPermission.openKeyboardShortcuts() }.controlSize(.small)
            }
        } header: {
            Text(L.Explain.settingsSection)
        } footer: {
            HStack(alignment: .top, spacing: 6) {
                Text(L.Explain.settingsFooter).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HelpButton(.explain)
            }
        }
        .onAppear { refreshScreenStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshScreenStatus()
        }
    }

    /// Screen Recording's status: the capturer's preflight (never asks), or the render's value.
    private func refreshScreenStatus() {
        screenOn = Self.previewScreenRecording ?? ExplainBootstrap.coordinator?.capturer.preflight()
    }

    private var historyChoices: [Int] {
        let current = state.settings.assist.explainHistoryDays
        return Self.historyChoices.contains(current) ? Self.historyChoices : (Self.historyChoices + [current]).sorted()
    }

    private func models(_ depth: AssistSettings.Depth) -> String {
        let a = state.settings.assist
        let p = a.mode.providerKind ?? state.settings.agentProvider
        return a.model(p, depth)
    }

    private var softCap: Binding<Int> {
        Binding(get: { state.settings.assist.dailySoftCap },
                set: { state.settings.assist.dailySoftCap = min(max($0, 1), state.settings.assist.dailyHardCap) })
    }

    /// On: an idle process may wait 3 minutes (`assist.keepWarm` 180 s); off: 0.
    private var keepWarm: Binding<Bool> {
        Binding(get: { state.settings.assist.keepWarmSeconds > 0 },
                set: { state.settings.assist.keepWarmSeconds = $0 ? 180 : 0 })
    }

    private func binding<T>(_ key: WritableKeyPath<AssistSettings, T>) -> Binding<T> {
        Binding(get: { state.settings.assist[keyPath: key] }, set: { state.settings.assist[keyPath: key] = $0 })
    }
}
