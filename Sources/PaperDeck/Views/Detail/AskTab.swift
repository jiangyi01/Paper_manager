import SwiftUI
import PaperDeckCore

/// The detail inspector's Ask tab (Q&A about one paper: streaming answers, citation chips, the
/// estimate line, Quick / Thorough, EN / 中 / Auto). Owned by Slice C. `DetailTabsHost` shows the
/// Overview | Ask control only once `isAvailable` is true.
///
/// The one place this tab mints consent tickets: `perform` below, run by the click that sends (Ask,
/// Try Again, Send Anyway, Continue, Ask Thoroughly, Answer in …) — one ticket per click.
struct AskTab: View {
    /// The tab ships (phase 2). Sending still needs `assist.mode` on (off by default) and a click.
    static let isAvailable = true
    /// `--ask-render` draws the Ask surfaces while the tab isn't available (never set in the app).
    static var previewOverride = false
    /// The Ask surfaces may be shown: the tab ships, or a render draws them.
    static var shown: Bool { isAvailable || previewOverride }

    let state: AppState
    let row: PaperRow

    var body: some View {
        let session = AskSessions.session(for: [row.id], state: state)
        AskThreadView(state: state, session: session, titles: [row.paper.title]) { intent in
            session.perform(intent, ticket: ConsentTicket.mint(session.gesture(for: intent), surface: .qa))
        }
        .task(id: row.id) {
            AskRouter.install(state)
            await session.load()
        }
    }
}
