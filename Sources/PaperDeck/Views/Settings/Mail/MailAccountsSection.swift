import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// Settings ▸ Mail ▸ Accounts — the "portal": every configured mailbox / watched folder with
/// its live status from the engine, enable / pause, first-sync lookback, edit, remove.
struct MailAccountsSection: View {
    let state: AppState
    let infos: [MailAccountSyncInfo]
    @Binding var sheet: MailSettingsSheet?
    /// 「立即同步」 of a row's skipped notice and whether it runs: the tab's own Sync Now (its
    /// spinner) — the app's (`AppState.syncMailNow`) when not given.
    var syncing: Bool?
    var onSyncNow: (() -> Void)?
    @State private var removing: MailAccount?

    static let lookbackChoices = [3, 7, 14, 30, 90]

    var body: some View {
        let settings = state.settings
        let byID = Dictionary(infos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        Section {
            if settings.mailAccounts.isEmpty {
                NoteText(L.MailPref.noAccounts, symbol: "envelope.badge")
            }
            ForEach(settings.mailAccounts) { account in
                MailAccountRow(state: state, account: account, info: byID[account.id], masterOn: settings.mailEnabled,
                               enabled: enabledBinding(account.id), lookback: lookbackBinding(account.id),
                               onEdit: { sheet = .editAccount(account) },
                               onRemove: { removing = account },
                               onGuide: { sheet = .powerAutomateGuide(account) },
                               syncing: syncing ?? state.mailSyncing,
                               onSyncNow: onSyncNow ?? { state.syncMailNow() })
            }
            HStack {
                Button(L.MailPref.addAccount) { sheet = .addAccount }
                Spacer()
            }
        } header: {
            HStack(spacing: 6) {
                Text(L.MailPref.accountsSection)
                HelpButton(.connectMail)
            }
        } footer: {
            NoteText(L.MailPref.accountsFooter, symbol: "lock.shield")
        }
        .alert(L.MailPref.removeAccountTitle(removing?.displayName ?? ""),
               isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L.MailPref.removeAccount, role: .destructive) {
                if let a = removing { remove(a) }
                removing = nil
            }
            Button(L.cancel, role: .cancel) { removing = nil }
        } message: {
            Text(removing?.kind == .imap ? L.MailPref.removeIMAPBody : L.MailPref.removeFolderBody)
        }
    }

    private func enabledBinding(_ id: String) -> Binding<Bool> {
        let settings = state.settings
        return Binding {
            settings.mailAccounts.first { $0.id == id }?.enabled ?? false
        } set: { on in
            guard let i = settings.mailAccounts.firstIndex(where: { $0.id == id }),
                  settings.mailAccounts[i].enabled != on else { return }
            settings.mailAccounts[i].enabled = on
        }
    }

    private func lookbackBinding(_ id: String) -> Binding<Int> {
        let settings = state.settings
        return Binding {
            settings.mailAccounts.first { $0.id == id }?.lookbackDays ?? 14
        } set: { days in
            guard let i = settings.mailAccounts.firstIndex(where: { $0.id == id }),
                  settings.mailAccounts[i].lookbackDays != days else { return }
            settings.mailAccounts[i].lookbackDays = days
        }
    }

    /// Forgets the account; an IMAP account's app password leaves the keychain too.
    private func remove(_ account: MailAccount) {
        state.settings.removeMailAccount(id: account.id)
        guard account.kind == .imap else { return }
        let store = MailSecrets.store
        let key = account.secretKey
        Task {
            do { try await store.setSecret(nil, for: key) } catch { state.report(error) }
        }
    }
}

private struct MailAccountRow: View {
    let state: AppState
    let account: MailAccount
    let info: MailAccountSyncInfo?
    let masterOn: Bool
    @Binding var enabled: Bool
    @Binding var lookback: Int
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onGuide: () -> Void
    let syncing: Bool
    let onSyncNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: MailSettingsFormat.symbol(account))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName.isEmpty ? L.MailPref.unnamedAccount : account.displayName)
                        .fontWeight(.medium)
                    Text(MailSettingsFormat.accountDetail(account))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Toggle(L.MailPref.accountEnabled, isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(enabled ? L.MailPref.pauseHelp : L.MailPref.resumeHelp)
            }
            let line = MailStatusText.line(account: account, info: info, masterOn: masterOn)
            StatusLine(line.kind, line.text)
                .font(.callout)
                .padding(.leading, 28)
            if let detail = MailStatusText.detail(info: info, account: account, masterOn: masterOn) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
            // Its notices (`MailAccountNotice`): files the flow wrote that aren't emails (Create
            // file got the trigger's Body) → Move to Trash… · Ignore · the guide; allowlisted emails
            // skipped because the retry list was full (the engine's `skippedHint`) → 「立即同步」 · hide
            // until more are skipped. What the user ignored / hid stays as a quiet line.
            ForEach(MailAccountNotice.notices(info, active: masterOn && account.enabled), id: \.kind) { notice in
                VStack(alignment: .leading, spacing: 6) {
                    StatusLine(.warning, notice.text)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    DetailFlowLayout(spacing: 8, lineSpacing: 6) {
                        switch notice.action {
                        case .openGuide:
                            MailNotEmailActions(state: state, accountID: account.id, ignored: false)
                            Button(L.MailPref.openGuide, action: onGuide)
                                .controlSize(.small)
                        case .syncNow:
                            Button(syncing ? L.Mail.syncing : L.MailPref.syncNow, action: onSyncNow)
                                .controlSize(.small)
                                .disabled(syncing)
                            Button(L.Mail.hideNotice) { state.dismissSkippedNotice(accountID: account.id) }
                                .controlSize(.small)
                                .help(L.Mail.ignoreSkippedHelp)
                        }
                    }
                }
                .padding(.leading, 28)
            }
            if let info, info.kind == .folder, info.ignoredNotEmailFiles > 0 {
                MailIgnoredFilesLine(state: state, accountID: account.id, count: info.ignoredNotEmailFiles)
                    .padding(.leading, 28)
            }
            if let info, masterOn, account.enabled, info.skipped > 0, info.skippedDismissed >= info.skipped {
                Text(L.Mail.skippedHidden(info.skipped))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .help(info.skippedHint ?? "")
                    .padding(.leading, 28)
            }
            HStack(spacing: 10) {
                Picker(L.MailPref.lookbackShort, selection: $lookback) {
                    ForEach(MailSettingsFormat.options(MailAccountsSection.lookbackChoices, including: lookback), id: \.self) {
                        Text(L.MailPref.days($0)).tag($0)
                    }
                }
                .fixedSize()
                .help(L.MailPref.lookbackHelp)
                Spacer()
                Button(L.MailPref.edit, action: onEdit).fixedSize()
                Button(L.MailPref.remove, role: .destructive, action: onRemove).fixedSize()
            }
            .controlSize(.small)
            .padding(.leading, 28)
        }
        .padding(.vertical, 2)
    }
}
