import AppKit
import CoreGraphics
import SwiftUI
import PaperDeckCore

/// Screen Recording ("Screen & System Audio Recording" in System Settings ▸ Privacy & Security), the
/// one permission Explain's frame and lens need (dive-capture §3, LN §4.3). Copy-then-hotkey,
/// Services and dropped images never need it.
///
/// The only file that may call `CGRequestScreenCaptureAccess` (AssistContractGrepTests), and only
/// from the explainer sheet's explicit button — never at launch, never from a capture (the capture
/// flow only preflights, `CaptureFlow.freeze`). macOS shows its prompt the first time and adds
/// PaperDeck to the list; after the user turns it on, macOS usually wants PaperDeck relaunched.
///
/// `isGranted` / `request()` are the capture lane's (its `ScreenCapturer` uses them); the Explain UI
/// reaches Screen Recording only through the injected `ScreenCapturing` (`preflight()` /
/// `request()`, fakes in tests and renders), never these directly. The explainer and the deep links
/// below are the Explain UI lane's (A2).
enum ScreenPermission {
    /// System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    /// Granted (never prompts).
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS (its prompt appears only the first time). True only when already granted —
    /// a fresh grant usually takes effect after a relaunch.
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    /// Opens the Privacy pane (after an earlier request, where `request` shows nothing any more).
    static func openSystemSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    // MARK: Explain UI (A2)

    /// System Settings ▸ Keyboard ▸ Keyboard Shortcuts (the Services shortcuts live there).
    static let keyboardShortcutsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")!

    static func openKeyboardShortcuts() { NSWorkspace.shared.open(keyboardShortcutsURL) }

    private static var explainerPanel: NSPanel?

    /// [Enable Screen Capture…]: the explainer first; its Continue asks through the capturer. The
    /// first time macOS shows its own prompt and nothing else opens (`request` answers false while
    /// that prompt is up — opening System Settings then put two dialogs on screen); a later Continue
    /// with access still off opens System Settings, where macOS shows nothing any more
    /// (`ScreenPermissionFlow`, phase-3 fix F11).
    static func presentExplainer(capturer: any ScreenCapturing) {
        explainerPanel?.orderOut(nil)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let close = { [weak panel] in panel?.orderOut(nil); explainerPanel = nil }
        panel.contentView = NSHostingView(rootView: ScreenRecordingExplainer(
            onContinue: {
                close()
                let requestedBefore = ScreenPermissionFlow.noteRequest(in: .standard)
                Task {
                    let granted = await capturer.request()
                    if ScreenPermissionFlow.opensSettings(granted: granted, requestedBefore: requestedBefore) {
                        openSystemSettings()
                    }
                }
            },
            onCancel: close))
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 440, height: 300))
        panel.center()
        explainerPanel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
    }
}

/// What turning Screen Recording on means, before macOS asks.
struct ScreenRecordingExplainer: View {
    var onContinue: () -> Void = {}
    var onCancel: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L.Explain.explainerTitle, systemImage: "rectangle.dashed.badge.record")
                .font(.headline)
            row("viewfinder", L.Explain.explainerCaptured)
            row("paperplane", L.Explain.explainerSent)
            row("tray", L.Explain.explainerStored)
            row("arrow.clockwise", L.Explain.explainerRelaunch)
            HStack {
                Spacer()
                Button(L.Explain.notNow, action: onCancel).keyboardShortcut(.cancelAction)
                Button(L.Explain.explainerContinue, action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .padding(.top, 8)
        .frame(width: 440)
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
