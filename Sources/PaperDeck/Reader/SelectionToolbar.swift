import AppKit
import SwiftUI
import PaperDeckCore

/// The reader's floating mini-toolbars (LN §8): over a text selection — Copy · Copy as Quote · Ask ·
/// Explain · Terms · Translate — and over a ⌘-drag box — Copy Image · Copy Text · Ask · Explain ·
/// Terms · Translate · ✕. Copying is local. Ask appears once the Ask tab ships (`AssistRollout.ask`)
/// and only opens it with the passage quoted (nothing is sent until the user presses Send there).
/// Explain / Terms / Translate appear once Explain ships (`AssistRollout.explain`); each click is the
/// fresh gesture that mints Explain's ticket, with the exact anchor (page + rect + text) and, for a
/// box, the region drawn from the PDF (2–3×, turned by the page's /Rotate). Built by Slice C; the
/// Explain hand-off (A4) is the Explain UI lane's.
struct ReaderSelectionToolbar: View {
    let model: ReaderModel
    let target: ReaderModel.Target
    /// `--render` only: draws the Ask / Explain buttons this build hides, to review their layout.
    static var previewShowsAssist = false

    private var isRegion: Bool { target.anchor.kind == .region }
    private var text: String? { target.anchor.text }
    private var showsAsk: Bool { AssistRollout.ask || Self.previewShowsAssist }
    private var showsExplain: Bool { AssistRollout.explain || Self.previewShowsAssist }

    var body: some View {
        HStack(spacing: 2) {
            if isRegion {
                Text(L.Reader.pageChip(target.anchor.page, printed: target.anchor.printedLabel))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .lineLimit(1)
                button(L.Reader.copyImage, "photo.on.rectangle", help: L.Reader.copyImageHelp) { model.copyRegionImage() }
                if let text { button(L.Reader.copyText, "doc.on.doc") { model.copy(text) } }
            } else if let text {
                button(L.Reader.copy, "doc.on.doc") { model.copy(text) }
                button(L.Reader.copyQuote, "quote.opening", help: L.Reader.copyQuoteHelp) { model.copyQuote(target.anchor) }
            }
            if showsAsk {
                Divider().frame(height: 16)
                button(L.Reader.ask, "bubble.left.and.text.bubble.right", help: L.Reader.askHelp) {
                    AskRouter.ask(paperIDs: [model.paperID], prefill: ReaderExplainHandoff.askPrefill(target.anchor))
                }
            }
            if showsExplain {
                Divider().frame(height: 16)
                ForEach(ReaderExplainHandoff.Action.allCases, id: \.self) { action in
                    button(action.title, action.symbol, help: action.help) {
                        // The click is the gesture: one ticket, for this one turn.
                        let ticket = ConsentTicket.mint(.reader, surface: .explain)
                        ReaderExplainHandoff.begin(target.anchor, action: action,
                                                   image: isRegion ? model.regionImage() : nil,
                                                   near: model.screenRect(of: target), ticket: ticket)
                    }
                }
            }
            if isRegion {
                Divider().frame(height: 16)
                Button { model.clearRegion() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(L.Reader.clearRegion)
                    .accessibilityLabel(L.Reader.clearRegion)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .fixedSize()
    }

    private func button(_ title: String, _ symbol: String, help: String? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.callout)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .help(help ?? title)
    }
}

/// What the reader hands to Explain (A4): the exact text (`.reader` source), a region's image drawn
/// from the PDF, the exact anchor (page + rect in page space + text — stored with the explanation so
/// its history can open the reader there and mark it), the turn the button asks for, and where the
/// selection sits on screen (the panel opens beside it).
enum ReaderExplainHandoff {
    enum Action: String, CaseIterable {
        case explain, terms, translate

        var title: String {
            switch self {
            case .explain: L.Reader.explain
            case .terms: L.Reader.terms
            case .translate: L.Reader.translate
            }
        }

        var symbol: String {
            switch self {
            case .explain: "sparkles"
            case .terms: "character.book.closed"
            case .translate: "translate"
            }
        }

        /// The tooltip: the action, and ⌥-click for the Thorough model.
        var help: String { title + " · " + L.Explain.optionThorough }

        /// The Explain turn the button runs.
        var kind: ExplainTurnKind {
            switch self {
            case .explain: .explain
            case .terms: .defineTerms
            case .translate: .translate
            }
        }
    }

    /// What Explain receives for `anchor` (exact text, the region image when there is one).
    static func capture(_ anchor: ReaderAnchor, image: AssistImage?) -> ExplainCapture {
        ExplainCapture(source: .reader, text: anchor.text, image: image)
    }

    /// The button's turn, with its ticket; ⌥ held asks the Thorough model.
    static func begin(_ anchor: ReaderAnchor, action: Action, image: AssistImage?, near: CGRect?, ticket: ConsentTicket) {
        guard AssistRollout.explain, let coordinator = ExplainBootstrap.coordinator else { return }
        coordinator.begin(capture: capture(anchor, image: image), ticket: ticket, anchor: anchor, kind: action.kind,
                          near: near, depth: ExplainPanelView.optionDepth)
    }

    /// Ask's question field, prefilled with the passage: About “…” (p. 3):
    static func askPrefill(_ anchor: ReaderAnchor) -> String? {
        let chip = L.Reader.pageChip(anchor.page, printed: anchor.printedLabel)
        guard let text = anchor.text else { return L.Reader.askPrefillRegion(chip) }
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let short = flat.count > 300 ? String(flat.prefix(300)) + "…" : flat
        return L.Reader.askPrefill(short, chip)
    }
}
