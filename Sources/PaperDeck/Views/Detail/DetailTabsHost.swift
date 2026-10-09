import SwiftUI
import PaperDeckCore

/// The detail inspector's tabs: Overview (today's inspector) | Ask (Slice C's `AskTab`). Until the
/// Ask tab ships — and always for a paper in Recently Deleted — it shows the overview alone, with
/// no segmented control, exactly as before. Lead-owned (Slice 0).
struct DetailTabsHost<Overview: View>: View {
    enum Tab: Hashable { case overview, ask }

    let state: AppState
    let row: PaperRow
    @ViewBuilder let overview: () -> Overview

    @State private var tab: Tab = .overview

    var body: some View {
        if AssistRollout.ask, !row.paper.isDeleted {
            VStack(spacing: 0) {
                Picker(selection: $tab) {
                    Text(L.QA.tabOverview).tag(Tab.overview)
                    Text(L.QA.tabAsk).tag(Tab.ask)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.top, 10)
                switch tab {
                case .overview: overview()
                case .ask: AskTab(state: state, row: row)
                }
            }
            // "Ask" from elsewhere (the reader, a context menu): `AskRouter` selects the paper and
            // asks for its Ask tab; the request is taken once, by the host showing that paper.
            .onAppear { if AskFocus.shared.consume(row.id) { tab = .ask } }
            .onChange(of: AskFocus.shared.paperID) { _, id in
                if id == row.id, AskFocus.shared.consume(row.id) { tab = .ask }
            }
        } else {
            overview()
        }
    }
}
