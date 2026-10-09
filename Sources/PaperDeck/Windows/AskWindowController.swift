import AppKit
import SwiftUI
import PaperDeckCore

/// The Ask window (READING_ASSIST_PLAN §6.4 C3): one window per set of papers (asking again about
/// the same selection brings its window back with its conversation). At most
/// `assist.qa.multiMax` papers (default 10, within `AssistSettings.qaMultiMaxRange`), labelled
/// P1…Pn in the selection's order. Opening it sends nothing.
final class AskWindowController: NSObject, NSWindowDelegate {
    private static var open: [String: AskWindowController] = [:]

    private let window: NSWindow
    private let key: String

    /// Shows the window for `paperIDs` (≥ 2; the first `multiMax` are kept).
    static func show(state: AppState, paperIDs: [String], prefill: String? = nil) {
        var unique: [String] = []
        for id in paperIDs where !unique.contains(id) { unique.append(id) }
        guard unique.count >= 2 else { return }
        let range = AssistSettings.qaMultiMaxRange              // the Settings stepper's range (an imported 50 is 20)
        let cap = min(max(state.settings.assist.qaMultiMax, range.lowerBound), range.upperBound)
        let kept = Array(unique.prefix(cap))
        let session = AskSessions.session(for: kept, state: state)
        if let prefill, !prefill.isEmpty, session.draft.isEmpty { session.draft = prefill }
        let key = AskSessions.key(kept)
        if let existing = open[key] {
            existing.present()
            return
        }
        let controller = AskWindowController(state: state, session: session, selectedCount: unique.count, key: key)
        open[key] = controller
        controller.present()
    }

    private init(state: AppState, session: AskSession, selectedCount: Int, key: String) {
        self.key = key
        let host = NSHostingController(rootView: AskWindowView(state: state, session: session, selectedCount: selectedCount))
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.title = L.QA.windowTitle(session.paperIDs.count)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.identifier = ActivationPolicy.ask          // a regular app while it's open (Dock icon, menu bar)
        w.minSize = NSSize(width: 720, height: 480)
        w.setContentSize(NSSize(width: 960, height: 680))
        window = w
        super.init()
        w.delegate = self
        let restored = w.setFrameUsingName("PaperDeckAsk")
        w.setFrameAutosaveName("PaperDeckAsk")
        if !restored { w.center() } else { w.cascadeTopLeft(from: NSPoint(x: w.frame.minX + 24, y: w.frame.maxY - 24)) }
    }

    private func present() {
        ActivationPolicy.becomeRegular()
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Self.open[key] = nil
        ActivationPolicy.update(closing: window)
    }
}
