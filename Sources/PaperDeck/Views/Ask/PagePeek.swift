import AppKit
import PDFKit
import SwiftUI
import PaperDeckCore

/// A cited page at a glance (DQ §6.5, READING_ASSIST_PLAN §6.4 C2): one floating panel with the PDF
/// page (PDFKit, single page) and the supporting sentence highlighted, the physical page and the
/// printed label, and [Open PDF] (the reader at that page, when it ships). Citation clicks reach it
/// through `ReaderRouting` when the built-in reader isn't in the build (`AskCitationRouting`).
struct PagePeekRouter: ReaderRouting {
    let state: AppState

    func open(paperID: String, page: Int?, highlight: String?) {
        guard let row = state.snapshot?.row(id: paperID) else { return }
        PagePeekPanel.shared.show(state: state, row: row, page: page ?? 1, highlight: highlight)
    }
}

/// The one PagePeek panel (reused; it follows the last citation clicked).
final class PagePeekPanel: NSObject, NSWindowDelegate {
    static let shared = PagePeekPanel()
    private var panel: NSPanel?

    func show(state: AppState, row: PaperRow, page: Int, highlight: String?) {
        let view = PagePeekView(row: row, page: page, highlight: highlight,
                                onOpenPDF: { state.openPDF(row, page: page, quote: highlight) },
                                onClose: { [weak self] in self?.panel?.close() })
        let p = panel ?? makePanel()
        p.contentViewController = NSHostingController(rootView: view)
        p.title = row.paper.title
        p.setContentSize(NSSize(width: 560, height: 720))
        if !p.isVisible { p.center() }
        p.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        p.setFrameAutosaveName("PaperDeckPagePeek")
        panel = p
        return p
    }
}

/// The panel's content (also drawn by `--ask-render`).
struct PagePeekView: View {
    let row: PaperRow
    let page: Int
    let highlight: String?
    var label: String?
    let onOpenPDF: () -> Void
    let onClose: () -> Void

    @State private var document: PDFDocument?
    /// The page's printed label, read with the document (nil: none, or the same as the page number).
    @State private var printedLabel: String?
    @State private var loaded = false
    @State private var highlighted = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let document, page >= 1, page <= document.pageCount {
                    PDFPageView(document: document, pageIndex: page - 1, highlight: highlight, found: $highlighted)
                } else if loaded {
                    Text(document == nil ? L.QA.noPDF : L.QA.pageMissing(page))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            footer
        }
        .task(id: row.pdfURL) {
            // Opened, and the label read, in one turn inside `PDFKitGate` (R-PDFKIT-1): imports read
            // other PDFs on background threads meanwhile, so the main actor may wait for one of their
            // steps here, once, rather than on every redraw. Lazy: pages are parsed when drawn.
            let page = page
            let opened = PDFKitGate.shared.run { () -> (document: PDFDocument?, label: String?) in
                let document = PDFDocument(url: row.pdfURL)
                return (document, document?.page(at: page - 1)?.label)
            }
            document = opened.document
            printedLabel = opened.label.flatMap { $0 == String(page) ? nil : $0 }
            loaded = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: row.paper.title.isEmpty ? row.paper.originalName : row.paper.title)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(L.QA.peekTitle(page))
                if let label = label ?? printedLabel { Text(verbatim: "·"); Text(L.QA.printedPage(label)) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let highlight {
                Text(verbatim: "“" + highlight + "”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                if !highlighted {
                    Text(L.QA.quoteNotHighlighted).font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L.QA.close, action: onClose).keyboardShortcut(.cancelAction)
            Button(L.QA.openPDF, action: onOpenPDF).keyboardShortcut(.defaultAction)
        }
        .padding(10)
    }
}

/// One PDF page with an optional highlighted sentence (searched on that page only).
struct PDFPageView: NSViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int
    let highlight: String?
    @Binding var found: Bool

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.document = document
        v.displayMode = .singlePage
        v.autoScales = true
        v.displaysPageBreaks = false
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        if v.document !== document { v.document = document }
        guard let page = document.page(at: pageIndex) else { return }
        v.go(to: page)
        guard let highlight, let selection = Self.find(highlight, on: page, in: document) else {
            v.highlightedSelections = nil
            if highlight != nil, found { DispatchQueue.main.async { found = false } }
            return
        }
        selection.color = NSColor.systemYellow.withAlphaComponent(0.5)
        v.highlightedSelections = [selection]
        v.go(to: selection)
    }

    /// The sentence on `page`: the whole quote, else its first eight words (line breaks and
    /// hyphenation in the PDF can differ from the extracted text). PDFKit reads the pages' text
    /// inside `PDFKitGate` (R-PDFKIT-1), one search per candidate.
    static func find(_ quote: String, on page: PDFPage, in doc: PDFDocument) -> PDFSelection? {
        let words = quote.split(whereSeparator: \.isWhitespace)
        var candidates = [quote.trimmingCharacters(in: CharacterSet(charactersIn: "…").union(.whitespaces))]
        if words.count > 8 { candidates.append(words.prefix(8).joined(separator: " ")) }
        if words.count > 4 { candidates.append(words.prefix(4).joined(separator: " ")) }
        for c in candidates where c.count >= 8 {
            let hit = PDFKitGate.shared.run {
                doc.findString(c, withOptions: [.caseInsensitive, .diacriticInsensitive]).first(where: { $0.pages.contains(page) })
            }
            if let hit { return hit }
        }
        return nil
    }
}
