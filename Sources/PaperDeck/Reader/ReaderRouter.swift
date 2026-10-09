import AppKit
import PaperDeckCore

/// Opens a paper at a page (a citation chip, an explanation's page chip, a checklist "p. N" chip).
/// Owned by Slice C.
protocol ReaderRouting {
    /// `page`: physical, 1-based (what `[[p. N]]` counts); nil just opens the paper with the user's
    /// opener. `highlight`: a quote to find and highlight on (or next to) that page.
    func open(paperID: String, page: Int?, highlight: String?)
}

/// The built-in reader (READING_ASSIST_PLAN §6.4 C4): a page always opens the reader there (Preview
/// can't be told a page); without one the user's `pdf.opener` decides — Preview by default, the reader
/// only when the user picks it in Settings ▸ General. Decisions: `ReaderRoute.decide` (Core, tested).
struct ReaderRouter: ReaderRouting {
    /// The reader ships in this build: the Settings option appears and pages open in it.
    static let isAvailable = true

    let state: AppState

    func open(paperID: String, page: Int?, highlight: String?) {
        guard let row = state.snapshot?.row(id: paperID) else { return }
        state.openPDF(row, page: page, quote: highlight)
    }

    /// Opens (or brings forward) the reader window of `row` at `page` (nil: the remembered page) with
    /// `quote` highlighted. Counts as opening the paper, like `AppState.openPDF`.
    func openReader(_ row: PaperRow, page: Int?, quote: String?) {
        guard FileManager.default.fileExists(atPath: row.pdfURL.path) else {
            state.post(Toast(kind: .error, message: L.pdfMissing))
            return
        }
        ReaderWindowController.show(state: state, row: row, page: page, quote: quote)
        state.engine.recentOpens.push(paperID: row.id)      // Explain's paper locator prefers recent opens
        guard !row.paper.isDeleted else { return }
        let engine = state.engine
        state.perform { _ = try await engine.markOpened(paperID: row.id) }
    }

    /// Opens the reader of `row` at an explanation's anchor (A4: the history's page chips), marking
    /// the exact passage or box. Counts as opening the paper.
    func openReader(_ row: PaperRow, anchor: ReaderAnchor) {
        guard FileManager.default.fileExists(atPath: row.pdfURL.path) else {
            state.post(Toast(kind: .error, message: L.pdfMissing))
            return
        }
        ReaderWindowController.show(state: state, row: row, anchor: anchor)
        state.engine.recentOpens.push(paperID: row.id)
        guard !row.paper.isDeleted else { return }
        let engine = state.engine
        state.perform { _ = try await engine.markOpened(paperID: row.id) }
    }

    /// `pdf.opener` asks for the reader (the Lead's `AppState.openPDF(_:)` hook asks this first).
    static func opensInReader(opener: String) -> Bool {
        ReaderRoute.decide(opener: opener, page: nil, quote: nil, readerAvailable: isAvailable) == .reader(page: nil, quote: nil)
    }

    /// The PDF in Preview (else the default app), as `AppState.openPDF` does for "preview" — the
    /// reader's "Open in Preview".
    static func openInPreview(_ url: URL) {
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Slice 0's name for the router; code written against it now gets the reader.
typealias PDFOpenerRouter = ReaderRouter

extension AppState {
    /// Opens `row`'s PDF at `page` (physical, 1-based) with `quote` highlighted — the checklist's
    /// "Open PDF (start at p. N)" chips, citations. With a page this is the built-in reader (Preview
    /// can't open at a page); without one, exactly `openPDF(row)` (the user's opener).
    func openPDF(_ row: PaperRow, page: Int?, quote: String? = nil) {
        switch ReaderRoute.decide(opener: settings.pdfOpener, page: page, quote: quote, readerAvailable: ReaderRouter.isAvailable) {
        case .reader(let page, let quote): ReaderRouter(state: self).openReader(row, page: page, quote: quote)
        case .preview, .defaultApp: openPDF(row)
        }
    }

    /// The router citation chips and page chips use.
    var reader: ReaderRouting { ReaderRouter(state: self) }
}
