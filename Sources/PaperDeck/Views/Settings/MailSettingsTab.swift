import AppKit
import SwiftUI
import PaperDeckCore

// MARK: - 邮件 / Mail (MAIL_DESIGN: everything DIY)
//
// 1. 总开关 + status + 立即同步 + interval   2. Accounts (the portal)   3. Senders
// 4. What counts as a reading request       5. AI triage              6. Merge & reminders
//
// The settings live in SettingsStore (the same UserDefaults keys MailSettings.load reads);
// every write reaches the engine through `SettingsStore.connectMail(to:)`. Account status
// comes from `MailSyncActor.accountSyncInfo(lang:)` in the UI language (polled while the tab is
// visible; read again at once after a language switch).

struct MailSettingsTab: View {
    let state: AppState
    @State private var infos: [MailAccountSyncInfo] = []
    /// The language `infos` were worded in.
    @State private var infosLang: UILang?
    @State private var usage: MailTriageUsage?
    @State private var syncing = false
    @State private var sheet: MailSettingsSheet?
    @State private var categories: [String] = []
    @State private var confirmClear = false
    @State private var clearing = false

    /// The rows in the current language (`MailStatusText.current`).
    private var shownInfos: [MailAccountSyncInfo] { MailStatusText.current(infos, readIn: infosLang, lang: L.lang) }

    var body: some View {
        @Bindable var settings = state.settings
        Form {
            masterSection(settings)
            MailAccountsSection(state: state, infos: shownInfos, sheet: $sheet, syncing: syncing, onSyncNow: syncNow)
            MailSenderRulesEditor(state: state, sheet: $sheet)
            MailReadingCriteriaSection(settings: settings)
            MailTriageSection(state: state, usage: usage, sheet: $sheet)
            MailMergeSection(state: state, clearing: clearing, confirmClear: $confirmClear)
        }
        .sheet(item: $sheet) { which in
            sheetContent(which)
        }
        .alert(L.MailPref.clearConfirmTitle, isPresented: $confirmClear) {
            Button(L.MailPref.clearConfirm, role: .destructive) { clearAll() }
            Button(L.cancel, role: .cancel) {}
        } message: {
            Text(L.MailPref.clearConfirmBody)
        }
        .onChange(of: state.mailGuideRequest, initial: true) { _, request in
            // 「Power Automate 设置指南…」 from the inbox's 「不是完整的邮件」 notice.
            guard let request else { return }
            state.mailGuideRequest = nil
            sheet = .powerAutomateGuide(state.settings.mailAccounts.first { $0.id == request })
        }
        .task {
            settings.connectMail(to: state.engine)
            settings.reloadMail()                   // the CLI (or another process) may have written keys
            categories = Self.categoryNames(state)
        }
        // A language switch restarts the poll: the rows are read again in the new language at once.
        .task(id: L.lang) {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(syncing || infos.contains(where: \.isSyncing) ? 1 : 3))
            }
        }
    }

    // MARK: 1. 总开关

    private func masterSection(_ settings: SettingsStore) -> some View {
        Section {
            Toggle(isOn: Bindable(settings).mailEnabled) {
                Text(L.MailPref.enable)
                Text(L.MailPref.enableHint)
            }
            .toggleStyle(.switch)
            let summary = MailStatusText.summary(settings: settings, infos: shownInfos)
            StatusLine(summary.kind, summary.text)
            LabeledContent {
                Button {
                    syncNow()
                } label: {
                    if syncing { ProgressView().controlSize(.small) } else { Text(L.MailPref.syncNow) }
                }
                .disabled(syncing || !settings.mailEnabled || !settings.mailAccounts.contains(where: \.enabled))
            } label: {
                Text(L.MailPref.syncNowLabel)
                Text(settings.mailEnabled ? L.MailPref.syncNowHint : L.MailPref.syncNowOffHint)
            }
            Picker(L.MailPref.syncInterval, selection: Bindable(settings).mailSyncMinutes) {
                Text(L.MailPref.manualOnly).tag(0)
                ForEach(MailSettingsFormat.options([5, 15, 30, 60], including: settings.mailSyncMinutes).filter { $0 > 0 },
                        id: \.self) { m in
                    Text(L.MailPref.every(minutes: m)).tag(m)
                }
            }
            .disabled(!settings.mailEnabled)
        } header: {
            Text(L.MailPref.sectionMail)
        } footer: {
            NoteText(L.MailPref.dropAlwaysWorks, symbol: "tray.and.arrow.down")
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ which: MailSettingsSheet) -> some View {
        switch which {
        case .addAccount:
            MailAddAccountSheet(state: state, editing: nil) { sheet = nil }
        case .editAccount(let account):
            MailAddAccountSheet(state: state, editing: account) { sheet = nil }
        case .sender(let rule):
            MailSenderRuleSheet(rule: rule, existing: state.settings.mailSenders, categories: categories) { saved in
                if let saved { state.settings.upsertSender(saved) }
                sheet = nil
            }
        case .triageSample:
            MailTriageSampleSheet(state: state) { sheet = nil }
        case .powerAutomateGuide(let account):
            MailPowerAutomateGuideSheet(state: state, account: account,
                                        notEmailFiles: infos.first { $0.id == account?.id }?.notEmailFiles ?? 0) { sheet = nil }
        }
    }

    // MARK: Actions

    private func refresh() async {
        let lang = L.lang
        let fresh = await MailStatusText.read(state.engine.mail, lang: lang)
        if fresh != infos || infosLang != lang {
            infos = fresh
            infosLang = lang
        }
        let u = await state.engine.mailTriage.usage()
        if u != usage { usage = u }
        let names = Self.categoryNames(state)
        if names != categories { categories = names }
    }

    private func syncNow() {
        syncing = true
        let mail = state.engine.mail
        Task {
            await MailSyncCommands.syncAll(mail)            // an explicit retry: every parked account
            await refresh()
            syncing = false
        }
    }

    private func clearAll() {
        clearing = true
        let mail = state.engine.mail
        Task {
            do {
                try await mail.deleteAllMailData()
                state.post(Toast(kind: .success, message: L.MailPref.cleared))
            } catch {
                state.report(error)
            }
            clearing = false
        }
    }

    static func categoryNames(_ state: AppState) -> [String] {
        (state.snapshot?.categories ?? []).map(\.category.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
