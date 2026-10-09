import AppKit
import CoreGraphics
import SwiftUI
import PaperDeckCore

/// The window a capture comes from (LN §5): its owner app's bundle id (privacy: mail / chat
/// windows ask first) and, with Screen Recording, its title (the paper locator's first clue).
/// `CGWindowListCopyWindowInfo` never prompts; without Screen Recording the title is nil. The title
/// stays on this Mac: it goes to `PaperLocator` / `MailWindow` only, never into a prompt or a log.
///
/// PaperDeck's own reader and library windows are part of the still (only Explain's overlay and
/// panels are left out of it), so they are part of the lookup too: a box over the built-in reader is
/// that reader's paper, with that paper's AI policy (phase-3 fix F2). Explain's overlay and panels
/// sit above the normal window layer and are never found.
nonisolated enum WindowTitleReader {
    struct Window: Sendable, Equatable {
        var windowID: CGWindowID
        var bundleID: String?
        var ownerName: String?
        var title: String?
        /// Global (Quartz) points.
        var bounds: CGRect
    }

    /// The frontmost normal window under `point` (global Quartz points), PaperDeck's reader and
    /// library included; `excluding`: Explain's own overlay / panel windows (they sit above the
    /// normal layer anyway). No owner is skipped wholesale: `noOwner` matches no process.
    static func window(at point: CGPoint, excluding: Set<CGWindowID> = []) -> Window? {
        let entries = WindowList.entries(from: list()).filter { !excluding.contains($0.windowID) }
        return WindowList.window(at: point, in: entries, excludingPID: noOwner).map(make)
    }

    /// A process id no window has (`WindowList.window(at:in:excludingPID:)` then skips nothing).
    static let noOwner: Int32 = -1

    /// The frontmost app's frontmost window (text triggers: Services, the clipboard); PaperDeck's
    /// own window too when it is in front (Services from the built-in reader).
    static func frontmostWindow() -> Window? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return frontmostWindow(ofPID: app.processIdentifier, in: WindowList.entries(from: list())).map(make)
    }

    /// Who is on screen under `region` (global Quartz points): every window showing part of it
    /// (`CaptureSurroundings.make`), PaperDeck's own windows with the papers they show (`own`).
    /// `entries` defaults to the live window list; a caller that kept the list from when the
    /// screen was frozen passes that one. Local only — the privacy check reads it.
    static func surroundings(region: CGRect, point: CGPoint?, excluding: Set<CGWindowID>,
                             own: [CGWindowID: CaptureSurroundings.Shows],
                             entries: [WindowList.Entry]? = nil) -> CaptureSurroundings {
        CaptureSurroundings.make(region: region, point: point, entries: entries ?? WindowList.entries(from: list()),
                                 excluding: excluding, ownPID: ProcessInfo.processInfo.processIdentifier,
                                 ownBundleID: Bundle.main.bundleIdentifier, own: own, bundleID: bundleID(of:))
    }

    /// A text trigger's surroundings: the frontmost app's front window and, for copied text, the
    /// app it was copied in (`copiedIn`, with that app's front window title now — best effort).
    static func textSurroundings(copiedIn: String?, own: [CGWindowID: CaptureSurroundings.Shows]) -> CaptureSurroundings? {
        let entries = WindowList.entries(from: list())
        let me = ProcessInfo.processInfo.processIdentifier
        var hosts: [CaptureSurroundings.Host] = []
        func host(pid: Int32, bundleID: String?) -> CaptureSurroundings.Host {
            let w = frontmostWindow(ofPID: pid, in: entries)
            return CaptureSurroundings.Host(bundleID: bundleID, title: w?.title, shows: pid == me ? w.flatMap { own[$0.windowID] } : nil)
        }
        if let front = NSWorkspace.shared.frontmostApplication {
            hosts.append(host(pid: front.processIdentifier, bundleID: front.bundleIdentifier))
        }
        if let copiedIn, let app = NSRunningApplication.runningApplications(withBundleIdentifier: copiedIn).first {
            hosts.append(host(pid: app.processIdentifier, bundleID: copiedIn))
        } else if let copiedIn {
            hosts.append(CaptureSurroundings.Host(bundleID: copiedIn))         // it quit since: its id still counts
        }
        return CaptureSurroundings.text(hosts)
    }

    private static func frontmostWindow(ofPID pid: Int32, in entries: [WindowList.Entry]) -> WindowList.Entry? {
        WindowList.frontmostWindow(ofPID: pid, in: entries)
    }

    private static func list() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    private static func bundleID(of pid: Int32) -> String? { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }

    private static func make(_ e: WindowList.Entry) -> Window {
        Window(windowID: e.windowID, bundleID: bundleID(of: e.ownerPID), ownerName: e.ownerName, title: e.title, bounds: e.bounds)
    }
}

/// What PaperDeck's own windows show, by window number (F2): a reader its paper and page, the
/// library its focused and selected papers (the inspector shows their notes, answers and
/// explanations) — or, in its Mail section, e-mails (`.mail`: the messaging confirmation) — an Ask
/// window its papers; a sheet or child window what its parent shows.
/// Settings, Help and the other windows show no paper. Explain's overlay and panels are left out
/// by the caller (`ExplainCoordinator.ownWindowIDs`).
enum ExplainOwnWindows {
    static func roles(state: AppState?) -> [CGWindowID: CaptureSurroundings.Shows] {
        var out: [CGWindowID: CaptureSurroundings.Shows] = [:]
        for w in NSApp.windows where w.windowNumber > 0 && w.isVisible {
            if let shows = shows(w, state: state) ?? (w.sheetParent ?? w.parent).flatMap({ shows($0, state: state) }) {
                out[CGWindowID(w.windowNumber)] = shows
            }
        }
        return out
    }

    private static func shows(_ w: NSWindow, state: AppState?) -> CaptureSurroundings.Shows? {
        switch w.identifier {
        case ReaderWindowController.windowIdentifier?:
            guard let reader = w.delegate as? ReaderWindowController else { return nil }
            return .reader(paperID: reader.model.paperID, page: reader.model.page)
        case ActivationPolicy.library?:
            guard let state else { return nil }
            // The Mail section shows e-mails (cards, a message's full text in the inspector): PaperDeck's
            // own inbox is a mail window and asks first like Mail does (lead integration of F1 / F2).
            if state.sidebar == .mail { return .mail }
            var ids: [String] = state.selectedPaperID.map { [$0] } ?? []
            for id in state.selection.ids.sorted() where !ids.contains(id) { ids.append(id) }
            return ids.isEmpty ? nil : .papers(ids)
        case ActivationPolicy.ask?:
            guard let host = w.contentViewController as? NSHostingController<AskWindowView> else { return nil }
            return .papers(host.rootView.session.paperIDs)
        default:
            return nil
        }
    }
}
