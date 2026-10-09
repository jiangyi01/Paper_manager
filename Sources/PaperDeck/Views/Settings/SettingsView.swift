import ServiceManagement
import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// One settings tab (the window's toolbar switches between them).
struct SettingsView: View {
    let state: AppState
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettingsTab(state: state)
            case .profile: ProfileSettingsTab(state: state)
            case .plan: PlanSettingsTab(state: state)
            case .ai: AISettingsTab(state: state)
            case .assist: AssistSettingsTab(state: state)
            case .mail: MailSettingsTab(state: state)
            case .library: LibrarySettingsTab(state: state)
            case .widget: WidgetSettingsTab(state: state)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: SettingsTab.width, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
    }
}

// MARK: - 通用

struct GeneralSettingsTab: View {
    let state: AppState
    @State private var launchAtLogin = false
    @State private var loginStatus: SMAppService.Status = .notRegistered

    var body: some View {
        @Bindable var settings = state.settings
        Form {
            Section {
                Picker(L.Pref.languageLabel, selection: $settings.language) {
                    Text("中文").tag(UILang.zh)
                    Text("English").tag(UILang.en)
                }
                .pickerStyle(.segmented)

                Toggle(isOn: $launchAtLogin) {
                    Text(L.Pref.launchAtLogin)
                    if loginStatus == .requiresApproval {
                        Text(L.Pref.loginNeedsApproval)
                    }
                }
                .disabled(!settings.launchAtLoginAvailable)
                .onChange(of: launchAtLogin) { _, on in
                    guard on != LaunchAtLogin.wanted else { return }
                    LaunchAtLogin.set(on, settings: settings)
                    loginStatus = LaunchAtLogin.status
                }
                if loginStatus == .requiresApproval {
                    Button(L.Pref.openLoginItems) { SMAppService.openSystemSettingsLoginItems() }
                }
                if !settings.launchAtLoginAvailable {
                    NoteText(L.Pref.launchAtLoginUnavailable, symbol: "info.circle")
                }
            }

            Section {
                Toggle(L.Pref.menuBarCount, isOn: $settings.showMenuBarCount)
                Picker(L.Pref.pdfOpener, selection: $settings.pdfOpener) {
                    Text(L.Pref.openerPreview).tag("preview")
                    Text(L.Pref.openerDefault).tag("default")
                    ReaderOpenerOption()                        // the built-in reader (Slice C), once it ships
                }
            }

            Section {
                LabeledContent {
                    Button(L.Pref.setupAssistantButton) { state.router.showSetupAssistant() }
                } label: {
                    Text(L.Pref.setupAssistant)
                    Text(L.Pref.setupAssistantHint)
                }
                HStack {
                    Button(L.Pref.paperDeckHelp) { HelpCenter.openTopic(nil) }
                    Button(L.Pref.featureTour) { HelpCenter.openTour() }
                    Spacer()
                }
            } header: {
                Text(L.Pref.helpSetupSection)
            }

            TransferSection(settings: settings)

            Section {
            } footer: {
                Text(Self.versionLine)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .onAppear {
            launchAtLogin = LaunchAtLogin.wanted
            loginStatus = LaunchAtLogin.status
        }
    }

    private static var versionLine: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = info?["CFBundleVersion"] as? String ?? "0"
        return "PaperDeck \(v) (\(b))"
    }
}
