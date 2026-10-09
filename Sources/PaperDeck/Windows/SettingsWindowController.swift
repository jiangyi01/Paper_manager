import AppKit
import Observation
import SwiftUI
import PaperDeckCore

/// 设置 window: a toolbar-style NSTabViewController (the native Settings look), one
/// SwiftUI `SettingsView` per tab. The window resizes to each tab's height.
final class SettingsWindowController: NSObject {
    private let state: AppState
    private var window: NSWindow?
    private var tabs: SettingsTabViewController?

    init(state: AppState) {
        self.state = state
        super.init()
    }

    /// `tab`: "general" | "profile" | "plan" | "ai" | "assist" | "mail" | "library" | "widget" (unknown, hidden
    /// or nil keeps the current tab).
    func show(tab: String? = nil) {
        if window == nil { build() }
        if let tab, let t = SettingsTab(rawValue: tab.lowercased()) { tabs?.select(t) }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let vc = SettingsTabViewController(state: state)
        let w = NSWindow(contentViewController: vc)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        vc.fitWindow(animated: false)
        w.center()
        window = w
        tabs = vc
    }
}

/// Tabs in toolbar order (READING_ASSIST_PLAN §8: general, profile, plan, ai, assist, mail, library, widget).
enum SettingsTab: String, CaseIterable {
    case general, profile, plan, ai, assist, mail, library, widget

    /// The tabs the window shows: Explain & Ask once its settings ship (`AssistSettingsTab.isAvailable`).
    static var shown: [SettingsTab] { allCases.filter(\.isShown) }

    var isShown: Bool { self != .assist || AssistRollout.assistSettings }

    var title: String {
        switch self {
        case .general: L.Pref.tabGeneral
        case .profile: L.Profile.tab
        case .plan: L.Pref.tabPlan
        case .ai: L.Pref.tabAI
        case .assist: L.Assist.tab
        case .mail: L.MailPref.tabMail
        case .library: L.Pref.tabLibrary
        case .widget: L.Pref.tabWidget
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .profile: "person.crop.circle"
        case .plan: "calendar.badge.clock"
        case .ai: "sparkles"
        case .assist: "text.bubble"
        case .mail: "envelope"
        case .library: "externaldrive"
        case .widget: "square.grid.2x2"
        }
    }

    /// Content height; taller tabs scroll inside their grouped form.
    var height: CGFloat {
        switch self {
        case .general: 560
        case .profile: 720
        case .plan: 600
        case .ai: 700
        case .assist: ExplainCoordinator.isAvailable ? 700 : 560    // Ask alone: the switch + Settings ▸ Ask
        case .mail: 760
        case .library: 700
        case .widget: 520
        }
    }

    static let width: CGFloat = 660
}

final class SettingsTabViewController: NSTabViewController {
    private let state: AppState

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        canPropagateSelectedChildViewControllerTitle = true
        for tab in SettingsTab.shown {
            let host = NSHostingController(rootView: SettingsView(state: state, tab: tab))
            host.sizingOptions = []
            host.preferredContentSize = NSSize(width: SettingsTab.width, height: tab.height)
            host.title = tab.title
            let item = NSTabViewItem(viewController: host)
            item.identifier = tab.rawValue
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            addTabViewItem(item)
        }
        observeLanguage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func select(_ tab: SettingsTab) {
        guard let i = SettingsTab.shown.firstIndex(of: tab), i != selectedTabViewItemIndex else { return }
        selectedTabViewItemIndex = i
    }

    private var currentTab: SettingsTab {
        let shown = SettingsTab.shown
        return shown.indices.contains(selectedTabViewItemIndex) ? shown[selectedTabViewItemIndex] : .general
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindow(animated: view.window?.isVisible == true)
    }

    /// Keeps the top edge fixed while the content area follows the selected tab (measured
    /// against the real content view, so the toolbar height is accounted for).
    func fitWindow(animated: Bool) {
        guard let window = view.window, let content = window.contentView else { return }
        let dw = SettingsTab.width - content.frame.width
        let dh = currentTab.height - content.frame.height
        guard abs(dw) > 0.5 || abs(dh) > 0.5 else { return }
        var target = window.frame
        target.size.width += dw
        target.size.height += dh
        target.origin.y -= dh
        window.setFrame(target, display: true, animate: animated)
    }

    /// Tab labels and the window title follow the UI language.
    private func observeLanguage() {
        withObservationTracking {
            _ = LangStore.shared.lang
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for (item, tab) in zip(self.tabViewItems, SettingsTab.shown) {
                    item.label = tab.title
                    item.viewController?.title = tab.title
                    item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
                }
                self.view.window?.title = self.currentTab.title
                self.observeLanguage()
            }
        }
    }
}
