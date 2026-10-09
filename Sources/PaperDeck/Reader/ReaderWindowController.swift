import AppKit
import SwiftUI
import PaperDeckCore

/// The built-in reader's windows (READING_ASSIST_PLAN §6.4 C4, LN §8): one window per paper, reused
/// when the paper is opened again (another page, another quote), hosted like the library window
/// (an NSWindow whose NSHostingView bridges SwiftUI's toolbar and title through
/// `sceneBridgingOptions`). The last frame is remembered; more windows cascade from it. While a reader
/// is open the app is a regular app (Dock icon, menus). Owned by Slice C (reader).
final class ReaderWindowController: NSObject, NSWindowDelegate {
    /// The windows' identifier (`ActivationPolicy` counts it among the regular windows).
    static let windowIdentifier = NSUserInterfaceItemIdentifier("PaperDeckReaderWindow")
    private static let frameName = "PaperDeckReader"
    private static let defaultSize = NSSize(width: 860, height: 1000)
    private static let minimumSize = NSSize(width: 520, height: 480)

    /// Open readers by paper id.
    private static var open: [String: ReaderWindowController] = [:]
    /// `--probe-reader` only: records the requests instead of opening windows (nothing reaches the screen).
    static var probeRecorder: ((_ paperID: String, _ page: Int?, _ quote: String?) -> Void)?

    let model: ReaderModel
    private var window: NSWindow?

    private init(state: AppState, row: PaperRow) {
        model = ReaderModel(state: state, paperID: row.id, title: row.paper.title, url: row.pdfURL)
        super.init()
    }

    /// Opens the reader of `row` at `page` (nil: where the user left it) with `quote` highlighted, or
    /// brings its window forward and goes there.
    static func show(state: AppState, row: PaperRow, page: Int?, quote: String?) {
        let id = row.id.lowercased()
        if let probeRecorder { probeRecorder(id, page, quote); return }
        ActivationPolicy.becomeRegular()
        LibraryMainMenu.installIfNeeded(state: state)
        NSApp.activate()
        if let existing = open[id], let w = existing.window {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
            existing.model.reveal(page: page, quote: quote)
            return
        }
        let controller = ReaderWindowController(state: state, row: row)
        open[id] = controller
        let w = controller.makeWindow()
        w.makeKeyAndOrderFront(nil)
        Task { await controller.model.load(page: page, quote: quote) }
    }

    /// Opens the reader of `row` at a saved explanation's exact place (A4: the box drawn again, or the
    /// passage highlighted).
    static func show(state: AppState, row: PaperRow, anchor: ReaderAnchor) {
        let id = row.id.lowercased()
        if let probeRecorder { probeRecorder(id, anchor.page, anchor.text); return }
        show(state: state, row: row, page: anchor.page, quote: nil)
        open[id]?.model.show(anchor: anchor)
    }

    /// The reader of `paperID`, if open (renders, tests).
    static func controller(for paperID: String) -> ReaderWindowController? { open[paperID.lowercased()] }

    private func makeWindow() -> NSWindow {
        let w = Self.makeWindow(for: model)
        w.delegate = self
        model.closeWindow = { [weak w] in w?.performClose(nil) }
        // Another reader is open: the same size, cascaded from the frontmost one; else the last frame.
        let others = NSApp.orderedWindows.filter { $0 !== w && $0.identifier == Self.windowIdentifier && $0.isVisible }
        if let front = others.first {
            w.setFrame(front.frame, display: false)
            w.setFrameTopLeftPoint(NSPoint(x: front.frame.minX + 24, y: front.frame.maxY - 24))
        } else if !w.setFrameUsingName(Self.frameName) {
            w.center()
        }
        window = w
        return w
    }

    /// A reader window around `model` (the renders draw this same window offscreen).
    static func makeWindow(for model: ReaderModel, size: NSSize = defaultSize) -> NSWindow {
        let hosting = NSHostingView(rootView: ReaderView(model: model))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        hosting.sizingOptions = []                       // the window owns its size (as the library's)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.toolbarStyle = .unified
        w.title = model.title
        w.contentView = hosting
        w.contentMinSize = minimumSize
        w.isReleasedWhenClosed = false
        w.tabbingMode = .automatic                       // tabs when the user prefers them (System Settings)
        w.tabbingIdentifier = frameName
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.identifier = windowIdentifier
        w.representedURL = model.url                     // the title's proxy icon (drag, ⌘-click path)
        return w
    }

    // MARK: NSWindowDelegate

    func windowDidEndLiveResize(_ notification: Notification) { window?.saveFrame(usingName: Self.frameName) }
    func windowDidMove(_ notification: Notification) { window?.saveFrame(usingName: Self.frameName) }

    func windowWillClose(_ notification: Notification) {
        window?.saveFrame(usingName: Self.frameName)
        model.close()
        Self.open[model.paperID] = nil
        ActivationPolicy.update(closing: window)
    }
}
