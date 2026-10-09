import SwiftUI
import PaperDeckCore

/// Settings ▸ Explain & Ask (`SettingsTab.assist`, between AI and Mail). Owned by Slice A (Slice C
/// supplies `QASettingsSection` as a subview). `SettingsTab.shown` leaves the tab out while
/// `isAvailable` is false.
///
/// The shared switch (`assist.mode`, off by default — only the user turns it on, and turning it on
/// sends nothing), then Settings ▸ Explain (once `ExplainCoordinator.isAvailable` flips; the switch
/// section places it, so the tab's two lines stay as they are), then Settings ▸ Ask.
struct AssistSettingsTab: View {
    /// The tab ships (with Ask; Explain's sections are Slice A's to add).
    static let isAvailable = true

    let state: AppState

    var body: some View {
        Form {
            AssistSwitchSection(state: state)
            QASettingsSection(state: state)
        }
    }
}

/// The one switch every assist surface shares (`assist.mode`): off, or the subscription CLI that
/// answers. Independent of AI reading (`agent.mode`). Turning it on records the first-use explanation
/// this section shows (`assist.consentVersion`, like the Ask tab's own card); nothing is sent.
struct AssistSwitchSection: View {
    let state: AppState

    /// The version of the explanation shown here and on the Ask tab's card (they say the same).
    static var consentVersion: Int { AskEnableCard.consentVersion }

    var body: some View {
        switchSection
        if ExplainSettingsSection.shown { ExplainSettingsSection(state: state) }
    }

    private var switchSection: some View {
        let assist = state.settings.assist
        return Section {
            Toggle(isOn: Binding(get: { assist.mode != .off }, set: { setOn($0) })) {
                Text(L.Assist.switchTitle)
                Text(Self.caption(mode: assist.mode, provider: provider))
            }
            .toggleStyle(.switch)
            if assist.mode != .off {
                Picker(selection: Binding(get: { provider }, set: { choose($0) })) {
                    ForEach(AIProviderKind.allCases, id: \.self) { kind in
                        Text(verbatim: kind.shortName).tag(kind)
                    }
                } label: {
                    Text(L.Assist.providerPicker)
                }
                .pickerStyle(.segmented)
            }
        } footer: {
            HStack(alignment: .top, spacing: 6) {
                NoteText(L.Assist.switchFooter, symbol: "lock.shield")
                Spacer(minLength: 0)
                HelpButton(.ask)
            }
        }
    }

    /// The provider that answers: the mode's, else (off, or a test mode) the AI reading provider.
    private var provider: AIProviderKind {
        state.settings.assist.mode.providerKind ?? state.settings.agentProvider
    }

    /// The toggle's second line.
    static func caption(mode: AssistMode, provider: AIProviderKind) -> String {
        if mode == .off { return L.Assist.switchOff }
        return ExplainSettingsSection.shown ? L.Assist.switchOnWithExplain(provider.shortName) : L.Assist.switchOn(provider.shortName)
    }

    private func setOn(_ on: Bool) {
        var a = state.settings.assist
        if on {
            guard a.mode == .off else { return }
            a.mode = provider.assistMode
            a.consentVersion = max(a.consentVersion, Self.consentVersion)
        } else {
            a.mode = .off
        }
        state.settings.assist = a
    }

    private func choose(_ kind: AIProviderKind) {
        var a = state.settings.assist
        guard a.mode != .off, a.mode != kind.assistMode else { return }
        a.mode = kind.assistMode
        state.settings.assist = a
    }
}
