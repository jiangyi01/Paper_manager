import SwiftUI
import PaperDeckCore

/// The paper a capture was matched to, and the user's way to correct it (CUX-6): "Matched: <paper>
/// · Change… · Not this paper" (or "You chose: …", or "Not matched to a library paper · Choose…").
/// A correction is remembered for the window, for the text the locator matched and for the excerpt
/// shown (`correctionExcerpts`: a ⇧-clicked term's paragraph and the term; `PaperMatchCorrections`,
/// in memory), the panel's stored explanations are filed accordingly, and the same capture is explained again — that
/// send is the click's own (the panel view mints its ticket in `explainAgain`). Nothing for the
/// built-in reader (its paper is exact). Never offered while a turn runs or the panel shows a
/// privacy refusal (`ExplainCorrectionRules`: a correction must not be the click past a never-AI
/// block or a confirmation). Owned by fix-capture-ux.
struct ExplainMatchLine: View {
    let state: ExplainPanelState
    let app: AppState?
    /// Explains the capture again (the panel view mints the click's ticket).
    let explainAgain: () -> Void

    @State private var picking = false
    @State private var query = ""

    enum Kind: Equatable {
        case matched(String)
        case chosen(String)
        case unmatched
    }

    /// What the line says for `state` (nil: no line — the reader, or nothing read yet).
    static func kind(_ state: ExplainPanelState) -> Kind? {
        guard state.anchor == nil, let prepared = state.prepared, !prepared.isEmpty else { return nil }
        guard let m = prepared.match else { return .unmatched }
        switch m.via {
        case .reader: return nil
        case .user: return .chosen(m.paperID)
        default: return .matched(m.paperID)
        }
    }

    var body: some View {
        if let kind = Self.kind(state) {
            HStack(spacing: 6) {
                Image(systemName: kind == .unmatched ? "questionmark.square.dashed" : "link")
                    .foregroundStyle(.secondary)
                Text(verbatim: label(kind))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button(kind == .unmatched ? L.ExplainUX.choose : L.ExplainUX.change) { picking = true }
                    .buttonStyle(.link)
                    .help(L.ExplainUX.changeHelp)
                    .disabled(!ExplainCorrectionRules.canCorrect(state.phase) || app == nil)
                    .popover(isPresented: $picking, arrowEdge: .bottom) { picker(current: paperID(kind)) }
                if case .matched(let id) = kind {
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    Button(L.ExplainUX.notThisPaper) { notThisPaper(id) }
                        .buttonStyle(.link)
                        .help(L.ExplainUX.notThisPaperHelp)
                        .disabled(!ExplainCorrectionRules.canCorrect(state.phase) || app == nil)
                }
            }
            .font(.caption)
        }
    }

    private func paperID(_ kind: Kind) -> String? {
        switch kind {
        case .matched(let id), .chosen(let id): return id
        case .unmatched: return nil
        }
    }

    private func label(_ kind: Kind) -> String {
        switch kind {
        case .matched(let id): return L.ExplainUX.matched(title(id))
        case .chosen(let id): return L.ExplainUX.chosen(title(id))
        case .unmatched: return L.ExplainUX.unmatched
        }
    }

    private func title(_ id: String) -> String { app?.snapshot?.row(id: id)?.paper.title ?? L.Explain.notFromLibrary }

    private func picker(current: String?) -> some View {
        let papers = (app?.snapshot?.rows ?? []).map { (id: $0.id, title: $0.paper.title) }
        let rows = PaperMatchCorrections.candidates(papers, query: query, excluding: current)
        return VStack(alignment: .leading, spacing: 8) {
            Text(L.ExplainUX.choosePaperTitle).font(.headline)
            TextField(L.ExplainUX.searchPapers, text: $query)
                .textFieldStyle(.roundedBorder)
            if rows.isEmpty {
                Text(L.ExplainUX.noPapersFound).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.id) { row in
                Button {
                    picking = false
                    choose(row.id)
                } label: {
                    Text(verbatim: row.title).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help(L.ExplainUX.useAndExplain)
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    // MARK: Corrections

    private func notThisPaper(_ id: String) {
        guard let app, ExplainCorrectionRules.canCorrect(state.phase) else { return }
        PaperMatchCorrections.shared.reject(id, windowTitle: state.capture.windowTitle, excerpts: state.correctionExcerpts,
                                            scope: ObjectIdentifier(app.engine), now: app.engine.ctx.now())
        refile(nil)
        explainAgain()
    }

    private func choose(_ id: String) {
        guard let app, ExplainCorrectionRules.canCorrect(state.phase) else { return }
        PaperMatchCorrections.shared.choose(id, windowTitle: state.capture.windowTitle, excerpts: state.correctionExcerpts,
                                            scope: ObjectIdentifier(app.engine), now: app.engine.ctx.now())
        refile(id)
        explainAgain()
    }

    /// The panel's stored explanations follow the correction (every turn of the thread).
    private func refile(_ paperID: String?) {
        guard let app, let id = state.turns.compactMap(\.recordID).first else { return }
        Task { try? await app.engine.assignExplanation(id: id, paperID: paperID) }
    }
}
