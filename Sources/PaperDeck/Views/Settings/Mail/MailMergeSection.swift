import SwiftUI
import UserNotifications
import PaperDeckCore

/// Settings ▸ Mail ▸ Merge & reminders: notes prefill, notifications, the 11:00 reminder line,
/// attachment size cap, retention, and 「清除所有邮件数据」.
struct MailMergeSection: View {
    let state: AppState
    let clearing: Bool
    @Binding var confirmClear: Bool

    static let attachmentCaps = [10, 25, 50, 100]
    static let retentionChoices = [7, 14, 30, 90, 180]

    var body: some View {
        @Bindable var settings = state.settings
        Section {
            Toggle(isOn: $settings.mailPrefillNotes) {
                Text(L.MailPref.prefillNotes)
                Text(L.MailPref.prefillNotesHint)
            }
            Toggle(isOn: $settings.mailNotifyNewRequests) {
                Text(L.MailPref.notifyRequests)
                Text(L.MailPref.notifyRequestsHint)
            }
            .onChange(of: settings.mailNotifyNewRequests) { _, on in
                // Turning it on is the moment to ask for notification permission (once).
                guard on, let reminders = ReminderService.shared else { return }
                Task {
                    if await reminders.refreshAuthorization() == .notDetermined { _ = await reminders.requestAuthorization() }
                }
            }
            if settings.mailNotifyNewRequests {
                NotificationAuthorizationRow(reminders: ReminderService.shared)
            }
            Toggle(isOn: $settings.mailIncludeInDailyReminder) {
                Text(L.MailPref.includeInReminder(String(format: "%02d:%02d", settings.reminderHour, settings.reminderMinute)))
                Text(settings.reminderEnabled ? L.MailPref.includeInReminderHint : L.MailPref.reminderIsOff)
            }
            Picker(selection: $settings.mailMaxAttachmentMB) {
                ForEach(MailSettingsFormat.options(Self.attachmentCaps, including: settings.mailMaxAttachmentMB), id: \.self) {
                    Text(L.MailPref.megabytes($0)).tag($0)
                }
            } label: {
                Text(L.MailPref.attachmentCap)
                Text(L.MailPref.attachmentCapHint)
            }
            Picker(selection: retentionBinding) {
                ForEach(settings.mailRetentionDays > 0
                        ? MailSettingsFormat.options(Self.retentionChoices, including: settings.mailRetentionDays)
                        : Self.retentionChoices, id: \.self) {
                    Text(L.MailPref.days($0)).tag($0)
                }
                Text(L.MailPref.keepForever).tag(SettingsStore.mailKeepForever)
            } label: {
                Text(L.MailPref.retention)
                Text(L.MailPref.retentionHint)
            }
            LabeledContent {
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    if clearing { ProgressView().controlSize(.small) } else { Text(L.MailPref.clearAll) }
                }
                .disabled(clearing)
            } label: {
                Text(L.MailPref.clearAllLabel)
                Text(L.MailPref.clearAllHint)
            }
        } header: {
            Text(L.MailPref.mergeSection)
        } footer: {
            NoteText(L.MailPref.backupNote)
        }
    }

    /// 0 is never written (the sync loop would purge every handled card at once): "keep" is -1.
    private var retentionBinding: Binding<Int> {
        let settings = state.settings
        return Binding {
            settings.mailRetentionDays < 0 ? SettingsStore.mailKeepForever : max(1, settings.mailRetentionDays)
        } set: { v in
            let value = v < 0 ? SettingsStore.mailKeepForever : max(1, v)
            if value != settings.mailRetentionDays { settings.mailRetentionDays = value }
        }
    }
}
