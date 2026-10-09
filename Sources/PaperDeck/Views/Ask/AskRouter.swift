import Foundation
import Observation
import PaperDeckCore

/// "Ask" from anywhere (the selection bar, a context menu, Services): one paper opens the detail
/// inspector's Ask tab, two or more the Ask window. Owned by Slice C. Opening sends nothing; the
/// question still needs its own click. Inert while the Ask surfaces aren't shown.
enum AskRouter {
    /// The app state the state-less entry point uses (`install` — the Ask tab installs it too).
    private(set) static weak var state: AppState?

    /// Also binds Q&A to the library the first time a state is installed (AppDelegate does it at
    /// launch): answers a crash left streaming are recovered, and from then on a paper's `qa.json`
    /// follows every change of its privacy inputs — a duplicate merge, a person's email, the
    /// unpublished hold — not only the inspector's toggles (Phase 2 fix QA-2). Sends nothing.
    static func install(_ state: AppState) {
        guard self.state !== state else { return }
        self.state = state
        let engine = state.engine
        Task { await engine.recoverQA() }
    }

    /// The frozen entry point (READING_ASSIST_PLAN §4): uses the installed app state.
    static func ask(paperIDs: [String], prefill: String?) {
        guard let state else { return }
        ask(state: state, paperIDs: paperIDs, prefill: prefill)
    }

    static func ask(state: AppState, paperIDs: [String], prefill: String?) {
        guard AskTab.shown, !paperIDs.isEmpty else { return }
        install(state)
        if paperIDs.count == 1, let id = paperIDs.first {
            let session = AskSessions.session(for: [id], state: state)
            if let prefill, !prefill.isEmpty, session.draft.isEmpty { session.draft = prefill }
            state.selectedPaperID = id
            state.router.showPaper(id)
            AskFocus.shared.request(paperID: id)
        } else {
            AskWindowController.show(state: state, paperIDs: paperIDs, prefill: prefill)
        }
    }
}

/// A request to show a paper's Ask tab (`DetailTabsHost` switches to Ask when the request names
/// the paper it shows, then clears it).
@Observable
final class AskFocus {
    static let shared = AskFocus()
    private(set) var paperID: String?

    func request(paperID: String) { self.paperID = paperID }

    /// The detail host took the request for `paperID`.
    func consume(_ paperID: String) -> Bool {
        guard self.paperID == paperID else { return false }
        self.paperID = nil
        return true
    }
}
