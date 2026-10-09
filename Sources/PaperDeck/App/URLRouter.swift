import Foundation
import PaperDeckCore
import PaperDeckConfig

/// Dispatches `paperdeck://` links (notifications, widget, menu bar, `open`) to the
/// AppRouter closures installed by AppDelegate.
enum URLRouter {
    /// `debug/remind` and `debug/pending` go here (installed by the reminder service);
    /// only honoured after `defaults write <the app's bundle id> debugURLs -bool true`.
    static var debugHandler: ((DeepLink) -> Void)?

    static let debugDefaultsKey = "debugURLs"

    static func handle(_ link: DeepLink, state: AppState) {
        switch link {
        case .today:
            state.router.showToday()
        case .paper(let id):
            state.router.showPaper(id)
        case .openPDF(let id):
            openPDF(id: id, state: state)
        case .dropzone:
            state.router.armDropPanel(10)
        case .settings(let tab):
            state.router.showSettings(tab)
        case .mail(let id):
            // Library ▸ Mail; with an id that email's card is selected (its filter follows).
            state.router.showMail(id)
        case .help(let topic):
            // Navigation only: a topic the catalog doesn't know opens Getting Started.
            state.router.showHelp(topic.map(GuideTopicID.init(rawValue:)))
        case .setup:
            state.router.showSetupAssistant()
        case .debugRemind, .debugPending:
            guard UserDefaults.standard.bool(forKey: debugDefaultsKey) else {
                Log.app.info("ignoring \(link.url.absoluteString, privacy: .public): debugURLs is off")
                return
            }
            guard let debugHandler else {
                Log.app.error("no debug handler installed for \(link.url.absoluteString, privacy: .public)")
                return
            }
            debugHandler(link)
        }
    }

    /// A cold launch from the widget can arrive before the first library snapshot:
    /// wait briefly for it instead of reporting a missing paper.
    private static func openPDF(id: String, state: AppState) {
        if let row = state.snapshot?.row(id: id) {
            state.openPDF(row)
            return
        }
        Task {
            var waited = 0
            while state.snapshot == nil && waited < 50 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            if let row = state.snapshot?.row(id: id) {
                state.openPDF(row)
            } else {
                state.post(Toast(kind: .error, message: L.routerPaperNotFound))
            }
        }
    }
}
