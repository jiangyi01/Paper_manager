import AppKit
import SwiftUI
import PaperDeckCore

/// 设置助手 window (first run while `!settings.setupCompleted`, or 设置 ▸ 通用 ▸ 重新打开设置助手).
final class SetupWindowController: NSObject {
    private let state: AppState
    private var window: NSWindow?
    /// Opened because setup was never completed (not via 设置 ▸ 重新打开设置助手).
    private var firstRun = false

    init(state: AppState) {
        self.state = state
        super.init()
    }

    func show() {
        if window?.isVisible != true { firstRun = !state.settings.setupCompleted }
        if window == nil { build() }
        window?.title = L.Pref.setupWindowTitle
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// 完成: close; after the first run, land in the library (今天).
    private func finish() {
        window?.close()
        if firstRun {
            firstRun = false
            state.router.showToday()
        }
    }

    private func build() {
        let view = SetupAssistantView(state: state, onFinish: { [weak self] in self?.finish() })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 620, height: 480)
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
        w.setContentSize(NSSize(width: 700, height: min(820, visible - 60)))
        w.center()
        window = w
    }
}
