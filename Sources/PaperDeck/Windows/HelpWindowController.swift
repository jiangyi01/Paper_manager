import AppKit
import SwiftUI
import PaperDeckCore
import PaperDeckConfig

/// Help ▸ PaperDeck Help (⌘?): one window, 880×620 (minimum 720×520). PaperDeck is a regular app
/// while it is open.
final class HelpWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let facts: SetupFactsCollector
    private let model = HelpCenterModel()
    private var window: NSWindow?

    init(settings: SettingsStore, facts: SetupFactsCollector) {
        self.settings = settings
        self.facts = facts
        super.init()
    }

    var isVisible: Bool { window?.isVisible == true }

    /// nil: Getting Started.
    func show(topic: GuideTopicID?) {
        model.open(topic)
        present()
    }

    func showTour() {
        model.open(.tour)
        present()
    }

    private func present() {
        let w = window ?? makeWindow()
        w.title = L.Help.windowTitle
        ActivationPolicy.becomeRegular()
        if let state = facts.state { LibraryMainMenu.installIfNeeded(state: state) } else { LibraryMainMenu.installStandalone() }
        NSApp.activate()
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: HelpCenterView(model: model, facts: facts, settings: settings))
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.identifier = ActivationPolicy.help
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.minSize = NSSize(width: 720, height: 520)
        w.setContentSize(NSSize(width: 880, height: 620))
        w.delegate = self
        let restored = w.setFrameUsingName("PaperDeckHelp")
        w.setFrameAutosaveName("PaperDeckHelp")
        if !restored { w.center() }
        window = w
        return w
    }

    func windowWillClose(_ notification: Notification) {
        ActivationPolicy.update(closing: window)
    }
}
