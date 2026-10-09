import AppKit
import CoreGraphics
import PDFKit
import SwiftUI
import PaperDeckCore

/// `--render OUTDIR --root SCRATCH --reader-only [--no-mail-demo] [--lang zh|en] [--appearance light|dark]
/// [--probe-reader]` (READING_ASSIST_PLAN §9.1 render checks; Slice C, C4): the built-in reader's states
/// from a scratch library — opening, page 3 with a quote highlighted, thumbnails at a printed-label page,
/// the find bar, a selection's toolbar, a ⌘-drag box with its toolbar (each also with the Ask / Explain
/// buttons this build hides, `-assist`), the missing / unreadable / locked states, the Settings opener
/// picker, and the region image Explain would get. The papers are the synthetic fixture
/// (`ReaderFixturePDF.sample`: six pages labelled i, ii, 1201–1204), inserted when the root has no
/// reader fixtures. Nothing here probes or starts an AI CLI (no Settings ▸ AI or setup page,
/// the renderer's mock providers, the agent queue never started); windows are drawn transparent, never
/// shown, and nothing is written outside OUTDIR and the scratch root.
///
/// `--probe-reader`: drives the real reader view with synthetic events in an off-screen window (⌘-drag
/// box → page + rect anchor, Esc, ⌘F, the page field with a printed label, the page memory, the quote
/// highlight, and the routing with the window recorded instead of shown) and prints `PROBE name
/// PASS|FAIL`, then `PROBE SUMMARY n/m`.
enum ReaderRenders {
    static let titles = (ok: "A Synthetic Paper for the PaperDeck Reader", missing: "Reader Fixture: Missing File",
                         broken: "Reader Fixture: Damaged File", locked: "Reader Fixture: Locked File")
    static let size = NSSize(width: 900, height: 1000)

    static func render(state: AppState, engine: Engine, root: URL, appearance: NSAppearance?, out: URL,
                       suffix: String, probe: Bool) async throws {
        try await seedIfNeeded(engine: engine, root: root)
        state.scheduleRefresh(delay: .zero)
        var waited = 0
        func row(_ title: String) -> PaperRow? { state.snapshot?.rows.first { $0.paper.title == title } }
        while row(titles.locked) == nil && waited < 100 { try await Task.sleep(for: .milliseconds(100)); waited += 1 }
        guard let paper = row(titles.ok), let missing = row(titles.missing), let broken = row(titles.broken),
              let locked = row(titles.locked) else { throw ReaderRenderError("reader fixtures missing from the scratch root") }
        func png(_ name: String) -> URL { out.appendingPathComponent("reader-\(name)-\(suffix).png") }

        // Opening (before the PDF is read).
        try await capture(ReaderModel(state: state, paperID: paper.id, title: paper.paper.title, url: paper.pdfURL),
                          appearance: appearance, png("loading")) { _ in }
        // Page 3 with the sample quote highlighted (it breaks across two lines there).
        try await capture(model(state, paper), appearance: appearance, png("page3-quote")) { m in
            await m.load(page: ReaderFixturePDF.sampleQuotePage, quote: ReaderFixturePDF.sampleQuote)
            try? await Task.sleep(for: .milliseconds(600))
            // PDFView draws the highlight in layers an offscreen capture misses: the page as PDFKit
            // draws it (its annotations included) shows the same highlight.
            if let page = m.document?.page(at: ReaderFixturePDF.sampleQuotePage - 1),
               let tiff = PDFKitGate.shared.run({ page.thumbnail(of: NSSize(width: 1224, height: 1584), for: .mediaBox) }).tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: png("page3-quote-pagedraw"))
                print("wrote \(png("page3-quote-pagedraw").path)")
            }
        }
        // A quote that isn't on the page: the page and a note.
        try await capture(model(state, paper), appearance: appearance, png("quote-notfound")) { m in
            await m.load(page: 2, quote: "a sentence this paper never prints anywhere")
        }
        // Thumbnails at page 5, printed 1203.
        try await capture(model(state, paper), appearance: appearance, png("thumbs-printed")) { m in
            await m.load(page: 5, quote: nil)
            m.showThumbnails = true
        }
        // Find "attention".
        try await capture(model(state, paper), appearance: appearance, png("find")) { m in
            await m.load(page: 1, quote: nil)
            try? await Task.sleep(for: .milliseconds(500))
            m.showFind()
            m.findQuery = "attention"
            m.runFind()
            await m.findSettled()
            m.findNext()
        }
        // A text selection and its toolbar; then with the hidden Ask / Explain buttons drawn.
        for assist in [false, true] {
            ReaderSelectionToolbar.previewShowsAssist = assist
            try await capture(model(state, paper), appearance: appearance, png(assist ? "selection-assist" : "selection")) { m in
                await m.load(page: 3, quote: nil)
                try? await Task.sleep(for: .milliseconds(500))
                if let doc = m.document, let page = doc.page(at: 2), let text = PDFKitGate.shared.run({ page.string }),
                   let r = ReaderTextIndex(text, joinHyphens: true).find("the effect in Figure 1"),
                   let sel = PDFKitGate.shared.run({ page.selection(for: r) }) {
                    m.pdfView.setCurrentSelection(sel, animate: false)
                    m.selectionSettled()
                }
            }
            // A ⌘-drag box around the figure on page 4 and its toolbar.
            try await capture(model(state, paper), appearance: appearance, png(assist ? "region-assist" : "region")) { m in
                await m.load(page: 4, quote: nil)
                try? await Task.sleep(for: .milliseconds(500))
                dragBox(m, page: 4, rect: ReaderFixturePDF.sampleFigure.insetBy(dx: -6, dy: -6))
            }
        }
        ReaderSelectionToolbar.previewShowsAssist = false
        // The states without a page.
        try await capture(model(state, missing), appearance: appearance, png("missing")) { m in await m.load(page: nil, quote: nil) }
        try await capture(model(state, broken), appearance: appearance, png("unreadable")) { m in await m.load(page: nil, quote: nil) }
        try await capture(model(state, locked), appearance: appearance, png("locked")) { m in await m.load(page: nil, quote: nil) }

        // Settings ▸ General ▸ Open PDFs with: the picker as SettingsView lays it out (its row only).
        for value in [ReaderRoute.Opener.preview, ReaderRoute.Opener.paperDeck] {
            try await PreviewRenderer.captureView(OpenerPickerPreview(value: value).frame(width: 520), size: nil,
                                                  appearance: appearance,
                                                  out.appendingPathComponent("settings-opener-\(value)-\(suffix).png"))
        }
        // The exact image a box hands to Explain (drawn from the PDF, ≤ 1568 px).
        if let doc = PDFKitGate.shared.run({ PDFDocument(url: paper.pdfURL) }), let page = doc.page(at: 3),
           let image = ReaderPDF.renderRegion(ReaderFixturePDF.sampleFigure.insetBy(dx: -6, dy: -6), of: page) {
            try image.data.write(to: out.appendingPathComponent("reader-region-image-\(suffix).png"))
            print("wrote reader-region-image-\(suffix).png (\(Int(image.pixelSize.width))×\(Int(image.pixelSize.height)))")
        }

        if probe { await ReaderProbe.run(state: state, engine: engine, row: paper, appearance: appearance) }
    }

    static func model(_ state: AppState, _ row: PaperRow) -> ReaderModel {
        ReaderModel(state: state, paperID: row.id, title: row.paper.title, url: row.pdfURL)
    }

    /// A ⌘-drag from corner to corner of `rect` (page space) the way the view reports it.
    static func dragBox(_ m: ReaderModel, page: Int, rect: CGRect) {
        guard let p = m.document?.page(at: page - 1) else { return }
        let a = m.pdfView.convert(CGPoint(x: rect.minX, y: rect.maxY), from: p)
        let b = m.pdfView.convert(CGPoint(x: rect.maxX, y: rect.minY), from: p)
        m.boxBegan(at: a)
        m.boxMoved(to: b)
        m.boxEnded(at: b)
    }

    /// Draws the reader window for `model` (its real toolbar and title) offscreen after `setup`.
    static func capture(_ model: ReaderModel, appearance: NSAppearance?, _ url: URL,
                        setup: (ReaderModel) async -> Void) async throws {
        let w = ReaderWindowController.makeWindow(for: model, size: size)
        w.appearance = appearance
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        w.orderFrontRegardless()
        defer { model.close(); w.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(400))
        await setup(model)
        try await Task.sleep(for: .milliseconds(1400))
        guard let frame = w.contentView?.superview else { return }
        frame.layoutSubtreeIfNeeded()
        if let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            print("wrote \(url.path)")
        }
    }

    // MARK: Fixture papers

    /// Four papers: the sample PDF, one whose PDF is gone, one damaged, one password-protected — only
    /// in a scratch root, never anyone's real library.
    static func seedIfNeeded(engine: Engine, root: URL) async throws {
        let live = try await engine.db.livePapers()
        guard !live.contains(where: { $0.title == titles.ok }) else { return }
        let fixtures: [(String, Data?)] = [
            (titles.ok, ReaderFixturePDF.sample()),
            (titles.missing, nil),
            (titles.broken, Data("%PDF-1.4\nthis is not a PDF body\n%%EOF\n".utf8)),
            (titles.locked, lockedPDF()),
        ]
        let library = engine.paths.papers
        for (i, f) in fixtures.enumerated() {
            let name = String(format: "2026_ReaderFixture_%02d", i)
            let dir = library.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pdf = FileNamer.pdfName(forFolder: name)
            let bytes = f.1 ?? Data("%PDF-1.4\n% reader fixture \(i)\n%%EOF\n".utf8)
            if f.1 != nil { try bytes.write(to: dir.appendingPathComponent(pdf)) }
            let p = Paper(sha256: FileOps.sha256(of: bytes), fileSize: Int64(bytes.count), title: f.0, titleRank: .api,
                          authors: ["Ada Example", "Grace Sample"], year: 2026, venue: "Fixture Journal", metaSource: .crossref,
                          pageCount: 6, folder: "Papers/" + name, pdfName: pdf, originalName: name + ".pdf", nameFinal: true,
                          stage: .ready, status: .toRead, priority: .normal, deadline: nil, scheduleMode: .none,
                          provisional: false, estMinutes: 30, addedAt: Date().addingTimeInterval(Double(-i) * 3_600))
            _ = try await engine.db.insertPaper(p, checklist: [
                ChecklistItem(ord: 0, text: "Introduction", section: "Introduction", page: 3, minutes: 10, kind: .overview, origin: .heuristic),
            ])
        }
    }

    /// A one-page PDF with a user password (PDFKit opens it locked).
    static func lockedPDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let aux = [kCGPDFContextUserPassword: "reader-fixture", kCGPDFContextOwnerPassword: "reader-fixture-owner"] as CFDictionary
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, aux) else { return Data() }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 72, y: 600, width: 200, height: 100))
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }
}

/// Settings ▸ General's "Open PDFs with" row as `SettingsView` builds it (with `ReaderOpenerOption`).
private struct OpenerPickerPreview: View {
    @State var value: String

    var body: some View {
        Form {
            Section {
                Picker(L.Pref.pdfOpener, selection: $value) {
                    Text(L.Pref.openerPreview).tag("preview")
                    Text(L.Pref.openerDefault).tag("default")
                    ReaderOpenerOption()
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 90)
    }
}

/// A render step that can't go on.
struct ReaderRenderError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Probe

/// Drives the real reader with synthetic events in an off-screen, transparent window (never on a
/// display, never key: AppKit delivers ⌘-drags to such a window, which is what the box uses).
private enum ReaderProbe {
    static func run(state: AppState, engine: Engine, row: PaperRow, appearance: NSAppearance?) async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) { print("PROBE TIMEOUT"); exit(3) }
        var results: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            results.append((name, ok))
            print("PROBE \(name) \(ok ? "PASS" : "FAIL")\(ok ? "" : " " + detail())")
        }
        let m = ReaderRenders.model(state, row)
        let w = ReaderWindowController.makeWindow(for: m, size: ReaderRenders.size)
        w.appearance = appearance
        w.alphaValue = 0
        w.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        w.orderFrontRegardless()
        defer { m.close(); w.orderOut(nil) }
        await m.load(page: 4, quote: nil)
        try? await Task.sleep(for: .milliseconds(900))
        check("opens-at-requested-page", m.page == 4, "page \(m.page)")

        // ⌘-drag around the figure on page 4 → an exact anchor on page 4 covering the figure.
        guard let doc = m.document, let page4 = doc.page(at: 3) else { check("document", false); return }
        let fig = ReaderFixturePDF.sampleFigure
        func windowPoint(_ p: CGPoint) -> NSPoint { m.pdfView.convert(m.pdfView.convert(p, from: page4), to: nil) }
        let start = windowPoint(CGPoint(x: fig.minX - 4, y: fig.maxY + 4))
        let end = windowPoint(CGPoint(x: fig.maxX + 4, y: fig.minY - 4))
        func mouse(_ type: NSEvent.EventType, _ at: NSPoint, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: at, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseUp ? 0 : 1)
        }
        let mid = NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        for (type, at) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, mid), (.leftMouseDragged, end), (.leftMouseUp, end)] {
            if let e = mouse(type, at, .command) { w.sendEvent(e) }
            if type == .leftMouseDragged {
                try? await Task.sleep(for: .milliseconds(60))
                if at == mid { check("box-band-while-dragging", m.band != nil) }
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        if let a = m.region?.anchor {
            let expected = fig.insetBy(dx: -4, dy: -4)
            let close = abs(a.rect.minX - expected.minX) < 2 && abs(a.rect.maxY - expected.maxY) < 2
                && abs(a.rect.width - expected.width) < 3 && abs(a.rect.height - expected.height) < 3
            check("command-drag-makes-a-region", a.kind == .region && a.page == 4 && close, "\(a.page) \(a.rect)")
            check("region-printed-label", a.printedLabel == "1202", "\(String(describing: a.printedLabel))")
            check("region-image-from-pdf", m.regionImage().map { $0.isAcceptable && $0.pixelSize.width > 900 } ?? false)
        } else {
            check("command-drag-makes-a-region", false, "no region")
        }
        check("band-cleared-after-drag", m.band == nil)
        // Esc clears the box (the PDF view has the keys).
        w.makeFirstResponder(m.pdfView)
        if let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: w.windowNumber, context: nil, characters: "\u{1b}",
                                      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            m.pdfView.keyDown(with: esc)
        }
        check("escape-clears-the-box", m.region == nil)
        // A plain click is not a box (outside region mode): PDFKit's own tracking takes it (its loop
        // finds the queued mouse-up).
        m.regionMode = false
        if let down = mouse(.leftMouseDown, start, []), let up = mouse(.leftMouseUp, start, []) {
            NSApp.postEvent(up, atStart: false)
            m.pdfView.mouseDown(with: down)
            if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
                m.pdfView.mouseUp(with: pending)
            }
        }
        check("plain-click-is-not-a-box", m.region == nil && m.band == nil)
        // Region mode: a plain drag boxes.
        m.regionMode = true
        if let down = mouse(.leftMouseDown, start, []) { m.pdfView.mouseDown(with: down) }
        if let drag = mouse(.leftMouseDragged, end, []) { m.pdfView.mouseDragged(with: drag) }
        if let up = mouse(.leftMouseUp, end, []) { m.pdfView.mouseUp(with: up) }
        check("region-mode-plain-drag-boxes", m.region?.anchor.page == 4)
        m.regionMode = false
        m.clearRegion()
        // ⌘F through the window's key equivalents (the SwiftUI shortcut).
        if let cmdF = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f",
                                       isARepeat: false, keyCode: 3) {
            _ = w.contentView?.performKeyEquivalent(with: cmdF)
        }
        try? await Task.sleep(for: .milliseconds(300))
        check("command-f-shows-find", m.findVisible)
        m.findQuery = "attention"
        m.runFind()
        await m.findSettled()
        check("find-counts-matches", m.findCursor.count >= 4, "\(m.findCursor.count)")
        check("find-starts-at-the-page-read", m.findCursor.index.map { m.findCursor.matchPages[$0] >= 4 } ?? false)
        m.closeFind()
        // The page field takes a printed label.
        check("page-field-printed-label", m.go(toField: "1203"))
        try? await Task.sleep(for: .milliseconds(600))
        check("page-field-went-to-physical-5", m.page == 5, "page \(m.page)")
        check("page-field-rejects-nonsense", !m.go(toField: "xiv"))
        // The page is remembered (debounced 1 s).
        try? await Task.sleep(for: .milliseconds(1400))
        let remembered = await engine.readerPage(paperID: row.id)
        check("page-memory-saved", remembered == 5, "\(String(describing: remembered))")
        // A quote on page 3 from page 5: goes there and highlights it.
        m.go(to: 3, quote: ReaderFixturePDF.sampleQuote)
        try? await Task.sleep(for: .milliseconds(600))
        check("quote-goes-to-its-page", m.page == 3 && m.hasQuoteHighlight, "page \(m.page)")
        let marked = m.document?.page(at: 2)?.annotations.filter { $0.type == "Highlight" }.count ?? 0
        check("quote-highlight-lines", marked == 2, "\(marked)")
        m.escape()
        check("escape-clears-the-quote", !m.hasQuoteHighlight && (m.document?.page(at: 2)?.annotations.isEmpty ?? false))
        // Routing (the window is recorded, never shown): a page always opens the reader, whatever the
        // opener; a missing PDF says so and opens nothing.
        var opened: [(String, Int?, String?)] = []
        ReaderWindowController.probeRecorder = { opened.append(($0, $1, $2)) }
        defer { ReaderWindowController.probeRecorder = nil }
        let opener = state.settings.pdfOpener
        state.settings.pdfOpener = ReaderRoute.Opener.preview
        state.openPDF(row, page: 3, quote: "a quote")
        check("page-opens-the-reader-with-preview-as-opener", opened.count == 1 && opened.last?.1 == 3 && opened.last?.2 == "a quote",
              "\(opened)")
        state.reader.open(paperID: row.id, page: 5, highlight: nil)
        check("router-opens-the-reader-at-the-page", opened.count == 2 && opened.last?.0 == row.id && opened.last?.1 == 5, "\(opened)")
        if let missing = state.snapshot?.rows.first(where: { $0.paper.title == ReaderRenders.titles.missing }) {
            let before = state.toasts.count
            state.openPDF(missing, page: 2)
            check("missing-pdf-toast-no-window", opened.count == 2 && state.toasts.count == before + 1
                  && state.toasts.last?.message == L.pdfMissing)
        }
        state.settings.pdfOpener = opener
        let passed = results.filter(\.1).count
        print("PROBE SUMMARY \(passed)/\(results.count)")
    }
}
