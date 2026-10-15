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
    /// The session's key while this window shows it (a paper removed re-files both).
    private var key: String
    /// How many papers the window asks about (its title).
    private var paperCount: Int

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
        let capped = unique.count > kept.count ? (kept: kept.count, selected: unique.count) : nil
        let controller = AskWindowController(state: state, session: session, capped: capped, key: key)
        open[key] = controller
        controller.present()
    }

    private init(state: AppState, session: AskSession, capped: (kept: Int, selected: Int)?, key: String) {
        self.key = key
        paperCount = session.paperIDs.count
        let host = NSHostingController(rootView: AskWindowView(state: state, session: session, capped: capped))
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
        session.onPapersChange = { [weak self, weak session] oldKey, filed in
            guard let self, let session else { return }
            self.papersChanged(session, from: oldKey, filed: filed)
        }
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

    /// "Remove from This Question": the window is found under the new set of papers (asking across
    /// the old selection again opens a window over all of it) and its title counts the papers left.
    /// When another session was already kept for the new set (`filed` false), asking across it
    /// brings that session's own window, not this one.
    private func papersChanged(_ session: AskSession, from oldKey: String, filed: Bool) {
        if Self.open[oldKey] === self { Self.open[oldKey] = nil }
        if filed, Self.open[session.key] == nil { Self.open[session.key] = self }
        key = session.key
        paperCount = session.paperIDs.count
        window.title = L.QA.windowTitle(session.paperIDs.count)
    }

    /// A language switch: every open Ask window's title in the new language.
    static func relocalizeTitles() {
        for controller in open.values { controller.window.title = L.QA.windowTitle(controller.paperCount) }
    }

    func windowWillClose(_ notification: Notification) {
        if Self.open[key] === self { Self.open[key] = nil }
        ActivationPolicy.update(closing: window)
    }
}
