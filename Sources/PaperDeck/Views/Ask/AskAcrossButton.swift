import SwiftUI
import PaperDeckCore

/// Slot for the selection bar and the multi-paper menus (READING_ASSIST_PLAN §6.4 C3): "Ask Across
/// N…" opens the Ask window with the selected papers (P1…Pn in selection order). Renders nothing
/// until the Ask surfaces ship, or for fewer than two papers. Opening the window sends nothing.
struct AskAcrossButton: View {
    let state: AppState
    let rows: [PaperRow]
    /// The bar's short title ("Ask").
    var short = false

    var body: some View {
        let live = rows.filter { $0.paper.isLive }
        if AskTab.shown, live.count >= 2 {
            Button {
                AskRouter.ask(state: state, paperIDs: live.map(\.id), prefill: nil)
            } label: {
                Label(short ? L.QA.tabAsk : L.QA.askAcross(live.count), systemImage: "bubble.left.and.text.bubble.right")
            }
            .help(L.QA.askAcrossHelp)
        }
    }
}
