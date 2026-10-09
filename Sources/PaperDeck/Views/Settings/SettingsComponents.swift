import AppKit
import SwiftUI
import PaperDeckCore

// Small building blocks shared by the settings tabs and the setup assistant.

/// State shown next to a check: symbol + text + color (never color alone).
enum StatusKind {
    case ok, warning, error, pending, neutral, working

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .pending: "circle.dashed"
        case .neutral: "minus.circle"
        case .working: "hourglass"
        }
    }

    var tint: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .error: .red
        case .pending, .neutral, .working: .secondary
        }
    }
}

/// `✓ 已登录 · Max · 2.1.284` — icon + text line.
struct StatusLine: View {
    let kind: StatusKind
    let text: String

    init(_ kind: StatusKind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    var body: some View {
        Label {
            Text(text).textSelection(.enabled)
        } icon: {
            if kind == .working {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: kind.symbol).foregroundStyle(kind.tint)
            }
        }
    }
}

/// A shell command in a monospaced box with [复制].
struct CommandBox: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? L.Pref.copied : L.Pref.copy) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Secondary explanatory text with an optional leading symbol.
struct NoteText: View {
    let text: String
    var symbol: String?

    init(_ text: String, symbol: String? = nil) {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Plan controls (settings ▸ 阅读计划 and setup assistant row 5)

struct BudgetPicker: View {
    @Bindable var settings: SettingsStore
    static let options = [30, 45, 60, 90, 120]

    var body: some View {
        let values = Array(Set(Self.options + [settings.dailyBudgetMinutes])).sorted()
        Picker(L.Pref.dailyBudget, selection: $settings.dailyBudgetMinutes) {
            ForEach(values, id: \.self) { Text(L.Pref.minutes($0)).tag($0) }
        }
    }
}

/// Seven toggle buttons, Monday first. At least one day stays selected.
struct WeekdayPicker: View {
    @Bindable var settings: SettingsStore
    private static let order = [2, 3, 4, 5, 6, 7, 1]      // Foundation weekdays, Mon … Sun

    var body: some View {
        LabeledContent(L.Pref.readingDays) {
            HStack(spacing: 4) {
                ForEach(Self.order, id: \.self) { day in
                    let on = settings.readingWeekdays.contains(day)
                    Toggle(isOn: binding(day)) {
                        Text(SharedStrings.weekday(day, L.lang)).frame(minWidth: 30)
                    }
                    .toggleStyle(.button)
                    .disabled(on && settings.readingWeekdays.count == 1)
                    .accessibilityValue(on ? L.Pref.on : L.Pref.off)
                }
            }
            .controlSize(.small)
        }
    }

    private func binding(_ day: Int) -> Binding<Bool> {
        Binding {
            settings.readingWeekdays.contains(day)
        } set: { on in
            var days = settings.readingWeekdays
            if on { days.insert(day) } else if days.count > 1 { days.remove(day) }
            if days != settings.readingWeekdays { settings.readingWeekdays = days }
        }
    }
}

struct ReminderTimePicker: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        DatePicker(L.Pref.reminderTime, selection: time, displayedComponents: .hourAndMinute)
    }

    private var time: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: min(max(settings.reminderHour, 0), 23),
                                  minute: min(max(settings.reminderMinute, 0), 59), second: 0, of: Date()) ?? Date()
        } set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            if let h = c.hour, h != settings.reminderHour { settings.reminderHour = h }
            if let m = c.minute, m != settings.reminderMinute { settings.reminderMinute = m }
        }
    }
}

struct CutoffPicker: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        let hours = Array(Set(Array(12...23) + [settings.cutoffHour])).sorted()
        Picker(L.Pref.cutoff, selection: $settings.cutoffHour) {
            ForEach(hours, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
        }
    }
}

// MARK: - Formatting & system links

enum SettingsFormat {
    /// A size in the UI language (`L.bytes`).
    static func bytes(_ n: Int64) -> String { L.bytes(n) }

    static func shortDateTime(_ d: Date) -> String {
        let lang = L.lang
        if let (cached, f) = dateTimeFormatter, cached == lang { return f.string(from: d) }
        let f = DateFormatter()
        f.locale = Locale(identifier: lang == .zh ? "zh_CN" : "en_US")
        f.setLocalizedDateFormatFromTemplate("MMMd HH:mm")
        dateTimeFormatter = (lang, f)
        return f.string(from: d)
    }

    private static var dateTimeFormatter: (UILang, DateFormatter)?
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func time(_ d: Date) -> String { timeFormatter.string(from: d) }

    static func duration(ms: Int) -> String {
        let s = max(0, ms / 1000)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// `~/.local/bin/claude`.
    static func tildePath(_ path: String) -> String {
        let home = SharedPaths.realHome.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Error text for inline results (operation errors are localized by the engine).
    static func error(_ error: Error) -> String {
        if let e = error as? PaperOperationError { return e.message(L.lang) }
        return error.localizedDescription
    }

    /// `max` → `Max`.
    static func plan(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return L.Pref.subscription }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}

enum SystemLinks {
    static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    static func filesAndFolders() { open("x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") }

    static func openTerminal() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
