import AppKit
import SwiftUI
import UserNotifications
import PaperDeckCore

// MARK: - 阅读计划与提醒

struct PlanSettingsTab: View {
    let state: AppState
    @State private var sendingTest = false

    private var reminders: ReminderService? { ReminderService.shared }

    var body: some View {
        @Bindable var settings = state.settings
        Form {
            Section {
                BudgetPicker(settings: settings)
                WeekdayPicker(settings: settings)
                CutoffPicker(settings: settings)
            } header: {
                Text(L.Pref.planSection)
            } footer: {
                NoteText(L.Pref.planFooter)
            }

            Section {
                Toggle(L.Pref.reminderEnabled, isOn: $settings.reminderEnabled)
                ReminderTimePicker(settings: settings)
                    .disabled(!settings.reminderEnabled)
                Toggle(L.Pref.skipWhenEmpty, isOn: Binding(get: { !settings.remindWhenEmpty },
                                                           set: { settings.remindWhenEmpty = !$0 }))
                    .disabled(!settings.reminderEnabled)
                NotificationAuthorizationRow(reminders: reminders)
                LabeledContent {
                    Button {
                        sendingTest = true
                        Task {
                            await reminders?.sendTest()
                            sendingTest = false
                        }
                    } label: {
                        if sendingTest { ProgressView().controlSize(.small) } else { Text(L.Pref.send) }
                    }
                    .disabled(sendingTest || reminders == nil)
                } label: {
                    Text(L.Pref.testNotification)
                    Text(L.Pref.testNotificationHint(time: L.Pref.reminderClock(hour: settings.reminderHour,
                                                                                minute: settings.reminderMinute)))
                }
            } header: {
                Text(L.Pref.reminderSection)
            } footer: {
                NoteText(L.Pref.reminderFooter)
            }

            Section {
                Toggle(L.Pref.autoMarkDone, isOn: $settings.autoMarkDone)
                Toggle(L.Pref.notifyOnAgentDone, isOn: $settings.notifyOnAgentDone)
            }
        }
    }
}

/// `通知权限：已允许` / `[允许通知]` / `已关闭 [打开系统通知设置]` — refreshed on appear and
/// whenever PaperDeck comes back to the front (the user may have changed it in System Settings).
struct NotificationAuthorizationRow: View {
    let reminders: ReminderService?
    @State private var requesting = false

    var body: some View {
        let status = reminders?.authorization ?? .denied
        LabeledContent {
            HStack(spacing: 8) {
                switch status {
                case .notDetermined:
                    Button {
                        requesting = true
                        Task {
                            _ = await reminders?.requestAuthorization()
                            requesting = false
                        }
                    } label: {
                        if requesting { ProgressView().controlSize(.small) } else { Text(L.Pref.allowNotifications) }
                    }
                    .disabled(requesting)
                case .denied:
                    Button(L.Pref.openNotificationSettings) { ReminderService.openSystemNotificationSettings() }
                        .disabled(reminders?.notificationsAvailable != true)
                default:
                    EmptyView()
                }
            }
        } label: {
            Text(L.Pref.notificationPermission)
            StatusLine(Self.kind(status, available: reminders?.notificationsAvailable == true),
                       Self.text(status, available: reminders?.notificationsAvailable == true))
                .font(.callout)
        }
        .task { await reminders?.refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await reminders?.refreshAuthorization() }
        }
    }

    static func kind(_ s: UNAuthorizationStatus, available: Bool) -> StatusKind {
        guard available else { return .warning }
        switch s {
        case .authorized, .provisional: return .ok
        case .denied: return .warning
        default: return .pending
        }
    }

    static func text(_ s: UNAuthorizationStatus, available: Bool) -> String {
        guard available else { return L.Pref.notificationsUnavailable }
        switch s {
        case .authorized: return L.Pref.authAuthorized
        case .provisional: return L.Pref.authProvisional
        case .denied: return L.Pref.authDenied
        default: return L.Pref.authNotDetermined
        }
    }
}
