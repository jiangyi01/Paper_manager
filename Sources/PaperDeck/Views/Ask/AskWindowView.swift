import SwiftUI
import PaperDeckCore

/// Ask across several papers (READING_ASSIST_PLAN §6.4 C3, DQ §6.6): the papers as P1…Pn on the
/// left (remove one, the cap note), the context mode (cards / excerpts / full text — full text only
/// for ≤ 3), and the same conversation as the Ask tab on the right; citations read "P2 · p. 5".
///
/// The one place this window mints consent tickets: `perform` below, run by the click that sends.
struct AskWindowView: View {
    let state: AppState
    let session: AskSession
    /// How many papers were selected (more than the cap: a note says which were kept).
    let selectedCount: Int

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 250)
            Divider()
            AskThreadView(state: state, session: session, titles: titles) { intent in
                session.perform(intent, ticket: ConsentTicket.mint(session.gesture(for: intent), surface: .qa))
            }
            .frame(minWidth: 420)
        }
        .task(id: session.key) { await session.load() }
    }

    private var rows: [PaperRow] { session.paperIDs.compactMap { state.snapshot?.row(id: $0) } }
    private var titles: [String] { session.paperIDs.map { state.snapshot?.row(id: $0)?.paper.title ?? $0 } }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L.QA.papersHeader).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(session.paperIDs.enumerated()), id: \.element) { i, id in
                        paperRow(index: i, id: id)
                    }
                }
            }
            if selectedCount > session.paperIDs.count {
                Text(L.QA.capNote(session.paperIDs.count, selectedCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(L.QA.contextMode).font(.caption).foregroundStyle(.secondary)
                Picker(selection: Binding(get: { session.mode }, set: { session.setMode($0) })) {
                    ForEach(QAContextMode.allowed(paperCount: session.paperIDs.count), id: \.self) { m in
                        Text(L.QA.modeName(m)).tag(m)
                    }
                } label: { EmptyView() }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(session.isRunning)
                .help(L.QA.modeHelp)
                if session.paperIDs.count > QAContextMode.fullTextMaxPapers {
                    Text(L.QA.fullTextLimit).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
    }

    private func paperRow(index i: Int, id: String) -> some View {
        let row = state.snapshot?.row(id: id)
        return HStack(alignment: .top, spacing: 8) {
            Text(verbatim: "P\(i + 1)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Self.color(i)))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row?.paper.title ?? id).font(.callout).lineLimit(3)
                if let p = row?.paper {
                    Text(verbatim: [p.authors.first, p.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if session.paperPrivacy.indices.contains(i) {
                switch session.paperPrivacy[i] {
                case .ok: EmptyView()
                case .blocked: Image(systemName: "hand.raised").foregroundStyle(.red).help(L.Policy.neverAI)
                case .confirm: Image(systemName: "lock.shield").foregroundStyle(.orange).help(L.Policy.confidential)
                }
            }
            if session.paperIDs.count > 2 {
                Button {
                    session.setPapers(session.paperIDs.filter { $0 != id })
                } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .disabled(session.isRunning)
                .help(L.QA.removePaper)
                .accessibilityLabel(L.QA.removePaper)
            }
        }
    }

    /// The P-label colours (stable per position).
    static func color(_ i: Int) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown, .mint, .red]
        return palette[i % palette.count]
    }
}
