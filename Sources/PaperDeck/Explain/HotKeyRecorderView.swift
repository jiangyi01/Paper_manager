import AppKit
import Observation
import SwiftUI
import PaperDeckCore

/// Records Explain's shortcut in Settings: a local key-down monitor in our own window (no
/// permission), the combination checked by `HotKeySpec.validate` (⌥-only and ⌥⇧-only combinations
/// are refused by macOS; ⌃ or ⌘ is required), then saved to `assist.explain.hotkey` and registered
/// again; "Used by another app" when Carbon says so. Owned by the Explain UI lane (A2).
@Observable
final class HotKeyRecorder {
    private(set) var recording = false
    private(set) var problem: HotKeySpec.Problem?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored var onRecord: (AssistSettings.HotKey) -> Void = { _ in }

    func start() {
        stop()
        problem = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording else { return event }
            self.handle(keyCode: Int(event.keyCode), flags: event.modifierFlags.rawValue)
            return nil                                       // the key never reaches the window
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    /// One key press while recording (Esc alone cancels).
    func handle(keyCode: Int, flags: UInt) {
        let mods = HotKeySpec.carbonModifiers(cocoaFlags: flags)
        if keyCode == HotKeySpec.Key.escape, mods == 0 {
            stop()
            return
        }
        let key = AssistSettings.HotKey(keyCode: keyCode, carbonModifiers: mods)
        if let p = HotKeySpec.validate(key) {
            problem = p
            return
        }
        problem = nil
        stop()
        onRecord(key)
    }
}

struct HotKeyRecorderView: View {
    let state: AppState
    /// `--explain-render`: the registration line to draw.
    static var previewStatus: HotKeyRegistration?

    @State private var recorder = HotKeyRecorder()

    private var key: AssistSettings.HotKey { state.settings.assist.explainHotKey }

    /// The registration as it is now (CUX-9): read from the coordinator in `body` — it is observable,
    /// so flipping Explain & Ask, a new shortcut or an import redraws the line; no copy that goes stale.
    private var status: HotKeyRegistration? { Self.previewStatus ?? ExplainBootstrap.coordinator?.hotKeyStatus }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                Text(verbatim: recorder.recording ? "…" : HotKeySpec.display(key))
                    .font(.body.monospaced())
                    .frame(minWidth: 64)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(recorder.recording ? Color.accentColor : Color.secondary.opacity(0.4)))
                Button(recorder.recording ? L.cancel : L.Explain.recordShortcut) {
                    recorder.recording ? recorder.stop() : recorder.start()
                }
                if key != .defaultExplain {
                    Button(L.Explain.resetShortcut) { save(.defaultExplain) }
                }
            }
            if let line = statusLine {
                Text(verbatim: line.text).font(.caption).foregroundStyle(line.color)
            }
        }
        .onAppear { recorder.onRecord = { save($0) } }
        .onDisappear { recorder.stop() }
    }

    private func save(_ k: AssistSettings.HotKey) {
        state.settings.assist.explainHotKey = k             // SettingsStore → ExplainBootstrap.shortcutChanged()
    }

    private var statusLine: (text: String, color: Color)? {
        if recorder.recording { return (L.Explain.recordingShortcut, .secondary) }
        if let p = recorder.problem { return (L.Explain.shortcutProblem(p), .orange) }
        switch status {
        case .registered?: return (L.Explain.shortcutReady, .green)
        case .inUse?: return (L.Explain.shortcutInUse, .orange)
        case .invalid(let p)?: return (L.Explain.shortcutProblem(p), .orange)
        case .failed?: return (L.Explain.shortcutFailed, .orange)
        case .switchedOff?: return (L.Explain.shortcutNeedsSwitch, .secondary)
        case .notRegistered?, nil: return nil
        }
    }
}
