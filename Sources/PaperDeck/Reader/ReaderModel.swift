import AppKit
import Observation
import PDFKit
import PaperDeckCore

/// One reader window's state (READING_ASSIST_PLAN §7 "Reader": loading → reading(page) → selection
/// (toolbar) | boxMode; page memory restored on open). Owns the window's `PDFView`, which the SwiftUI
/// tree hosts (`ReaderPDFRepresentable`) and the thumbnails follow. Never edits or saves the PDF: the
/// highlights are view-only, the region box is an overlay. Owned by Slice C (reader).
@Observable
final class ReaderModel {
    /// `timedOut`: the file wasn't readable in time (a cloud file still downloading) — Try Again.
    enum Phase: Equatable { case loading, reading, missing, unreadable, locked, timedOut }

    /// A text selection or a ⌘-drag box, with where it sits in the view (origin top-left) for the
    /// floating toolbar.
    struct Target: Equatable {
        var anchor: ReaderAnchor
        var viewRect: CGRect
    }

    /// One-line notes shown over the page for a few seconds.
    enum Notice: Equatable { case quoteNotFound(page: Int), quotePartial, copied }

    let paperID: String
    let url: URL
    private(set) var title: String
    private(set) var phase: Phase = .loading
    private(set) var pageCount = 0
    /// Physical, 1-based.
    private(set) var page = 1
    private(set) var labels: [String?] = []
    var showThumbnails = false
    /// Plain drags draw a box (⌘-drag always does).
    var regionMode = false

    // Find
    var findVisible = false
    /// Bumped by ⌘F: the field takes the focus again.
    private(set) var findFocusRequest = 0
    var findQuery = "" { didSet { if findQuery != oldValue { scheduleFind() } } }
    private(set) var findCursor = ReaderFindCursor(matchPages: [], startingAt: nil)
    private(set) var findCapped = false
    /// A find is running (off the main actor, RD-1): the share of pages searched so far, 0…1.
    private(set) var findProgress: Double?
    /// The open has been waiting a while (a cloud file downloading?): the loading view says so and
    /// offers Cancel.
    private(set) var loadIsSlow = false

    // Overlays
    private(set) var selection: Target?
    private(set) var region: Target?
    /// The box being dragged (view coordinates, origin top-left).
    private(set) var band: CGRect?
    private(set) var notice: Notice?

    @ObservationIgnored let pdfView = ReaderPDFView()
    @ObservationIgnored private(set) var document: PDFDocument?
    /// The bytes `document` was made from (the find searches its own document made from them).
    @ObservationIgnored private var documentData: Data?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Closes the reader's window (Cancel while opening); set by `ReaderWindowController`.
    @ObservationIgnored var closeWindow: (() -> Void)?
    @ObservationIgnored private weak var state: AppState?
    @ObservationIgnored private var pending: (page: Int?, quote: String?)?
    /// A saved explanation's exact place to show once the document is laid out (A4).
    @ObservationIgnored private var pendingAnchor: ReaderAnchor?
    @ObservationIgnored private var findMatches: [PDFSelection] = []
    /// The quote's highlight (`ReaderHighlight`: temporary, never saved).
    @ObservationIgnored private var quoteMarks: [ReaderHighlight.Mark] = []
    @ObservationIgnored private var findTask: Task<Void, Never>?
    /// The page the running find counts from (the page being read when it started).
    @ObservationIgnored private var findStartPage: Int?
    /// The current match was scrolled to (a running find reveals it once).
    @ObservationIgnored private var findRevealed = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var boxStart: (page: PDFPage, point: CGPoint)?
    @ObservationIgnored private var observesScrolling = false

    /// Find highlights: at most this many matches are drawn (a one-letter query in a long PDF).
    static let findLimit = 500
    /// Opaque: a highlight annotation multiplies its colour over the page (an alpha colour isn't drawn).
    static let quoteColor = NSColor(srgbRed: 1, green: 0.88, blue: 0.3, alpha: 1)
    static let findColor = NSColor.systemYellow.withAlphaComponent(0.35)
    static let findCurrentColor = NSColor.systemOrange.withAlphaComponent(0.55)

    init(state: AppState?, paperID: String, title: String, url: URL) {
        self.state = state
        self.paperID = paperID.lowercased()
        self.title = title
        self.url = url
        configureView()
    }

    // MARK: Loading

    /// How long the open may take before the loading view mentions a download and offers Cancel.
    static let slowLoadNotice: Duration = .milliseconds(1500)

    /// Reads the PDF and goes to `page` (nil: the remembered page) with `quote` highlighted. The file
    /// is read and the document built off the main actor (RD-3: `ReaderDocumentLoader`, a
    /// coordinated read with a time limit — an iCloud / OneDrive file not downloaded yet is fetched
    /// first while the window shows a spinner). Closing the window (or Cancel) stops the wait.
    func load(page: Int?, quote: String?) async {
        pending = (page, quote)
        loadTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
    }

    private func performLoad() async {
        phase = .loading
        loadIsSlow = false
        let url = self.url
        let slow = Task { [weak self] in
            try? await Task.sleep(for: Self.slowLoadNotice)
            guard !Task.isCancelled, let self, self.phase == .loading else { return }
            self.loadIsSlow = true
        }
        defer { slow.cancel() }
        let result = await ReaderDocumentLoader.open(url)
        guard !Task.isCancelled else { return }
        switch result {
        case .missing: phase = .missing
        case .unreadable: phase = .unreadable
        case .locked: phase = .locked
        case .timedOut: phase = .timedOut
        case .cancelled: return
        case .opened(let opened):
            let remembered = await state?.engine.readerPage(paperID: paperID)
            guard !Task.isCancelled else { return }
            // A second request while this one waited (the same paper opened again) wins.
            let wanted = pending ?? (nil, nil)
            let doc = opened.document
            document = doc
            documentData = opened.data
            labels = opened.labels
            pageCount = doc.pageCount
            pdfView.document = doc
            let start = ReaderPageMemory.startPage(requested: wanted.page, remembered: remembered, pageCount: doc.pageCount)
            self.page = start
            pending = (start, wanted.quote)
            phase = .reading
            applyPendingIfLaidOut()
        }
    }

    /// Try Again after a time-out.
    func retryLoad() {
        let wanted = pending
        Task { await load(page: wanted?.page, quote: wanted?.quote) }
    }

    /// Cancel while opening: stop waiting for the file and close the window.
    func cancelLoading() {
        loadTask?.cancel()
        closeWindow?()
    }

    /// The window was asked for this paper again (a chip with another page).
    func reveal(page: Int?, quote: String?) {
        guard phase == .reading else {
            if phase == .loading { pending = (page ?? pending?.page, quote ?? pending?.quote) }
            return
        }
        if let page { go(to: page, quote: quote) } else if let quote { go(to: self.page, quote: quote) }
    }

    /// The pending target needs a laid-out view (`go(to:)` before that scrolls nowhere).
    func applyPendingIfLaidOut() {
        guard phase == .reading, isLaidOut else { return }
        if let p = pending {
            pending = nil
            go(to: p.page ?? 1, quote: p.quote)
        }
        if let a = pendingAnchor {
            pendingAnchor = nil
            show(anchor: a)
        }
    }

    // MARK: Explanation anchors (A4)

    /// Opens at a saved explanation's exact place: a selection's text highlighted on its page (the
    /// quote finder), a box drawn again where it was (scaled to the page if its size changed), and
    /// scrolled into view. Before the view is laid out it waits.
    func show(anchor: ReaderAnchor) {
        guard phase == .reading, isLaidOut, let doc = document, let target = doc.page(at: anchor.page - 1) else {
            pendingAnchor = anchor
            return
        }
        if anchor.kind == .selection, let text = anchor.text {
            go(to: anchor.page, quote: text)
            return
        }
        let bounds = target.bounds(for: .cropBox)
        var placed = anchor
        placed.rect = ReaderAnchor.rect(unit: anchor.unitRect, in: bounds)
        placed.pageBounds = bounds
        clearSelection()
        region = Target(anchor: placed, viewRect: viewRect(placed.rect, on: target))
        reveal(placed.rect, on: target)
        viewMoved()
    }

    /// Where `target` sits on screen (AppKit global): the Explain panel opens beside it.
    func screenRect(of target: Target) -> CGRect? {
        guard let window = pdfView.window else { return nil }
        let r = target.viewRect
        let local = pdfView.isFlipped ? r : CGRect(x: r.minX, y: pdfView.bounds.height - r.maxY, width: r.width, height: r.height)
        return window.convertToScreen(pdfView.convert(local, to: nil))
    }

    // MARK: Navigation

    /// Physical page `page`; with a quote, the quote's match on (or next to) it is highlighted and
    /// scrolled to, else a note says it wasn't found and the page is shown. Before the view is laid
    /// out this becomes the pending target (a later layout would otherwise undo it).
    func go(to page: Int, quote: String? = nil) {
        guard let doc = document, let p = ReaderPages.clamp(page, pageCount: doc.pageCount),
              let target = doc.page(at: p - 1) else { return }
        guard isLaidOut else { pending = (p, quote); return }
        pending = nil
        ReaderHighlight.remove(quoteMarks, in: pdfView)
        quoteMarks = []
        if let quote, !quote.isEmpty {
            // The pages' text is read, and the selection and its line highlights built, inside `PDFKitGate`.
            let hit = PDFKitGate.shared.run { () -> (match: ReaderQuoteMatch, page: PDFPage, bounds: CGRect, marks: [ReaderHighlight.Mark])? in
                guard let m = ReaderQuoteFinder.locate(quote, near: p, in: doc), let matchPage = doc.page(at: m.page - 1),
                      let sel = matchPage.selection(for: m.range) else { return nil }
                return (m, matchPage, sel.bounds(for: matchPage), ReaderHighlight.add(sel, color: Self.quoteColor, in: pdfView))
            }
            if let hit {
                quoteMarks = hit.marks
                reveal(hit.bounds, on: hit.page)
                if !hit.match.exact { show(.quotePartial) }
                return
            }
            show(.quoteNotFound(page: p))
        }
        pdfView.go(to: target)
    }

    /// Scrolls so that `rect` (page space) starts a quarter of the way down the view (the clip view
    /// is scrolled directly: deterministic, whatever the document view's flippedness).
    private func reveal(_ rect: CGRect, on page: PDFPage) {
        pdfView.go(to: page)
        guard let doc = pdfView.documentView, let scroll = doc.enclosingScrollView else { return }
        let clip = scroll.contentView
        let inDoc = doc.convert(pdfView.convert(rect, from: page), from: pdfView)
        let h = clip.bounds.height
        var origin = clip.bounds.origin
        origin.y = doc.isFlipped ? inDoc.minY - h * 0.25 : inDoc.maxY - h * 0.75
        origin.y = min(max(origin.y, doc.bounds.minY), max(doc.bounds.maxY - h, doc.bounds.minY))
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }

    private var isLaidOut: Bool { pdfView.window != nil && pdfView.bounds.height > 0 }

    /// The page field: a physical number or a printed label (`ReaderPages.resolve`). False: nothing to go to.
    @discardableResult
    func go(toField text: String) -> Bool {
        guard let p = ReaderPages.resolve(text, labels: labels, pageCount: pageCount) else { return false }
        go(to: p)
        return true
    }

    func zoomIn() { pdfView.autoScales = false; pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.autoScales = false; pdfView.zoomOut(nil) }
    func actualSize() { pdfView.autoScales = false; pdfView.scaleFactor = 1 }
    func fitWidth() { pdfView.autoScales = true }

    var printedLabel: String? {
        page >= 1 && page <= labels.count ? ReaderPages.printedLabel(physical: page, label: labels[page - 1]) : nil
    }

    func printedLabel(of page: Int) -> String? {
        page >= 1 && page <= labels.count ? ReaderPages.printedLabel(physical: page, label: labels[page - 1]) : nil
    }

    // MARK: Find

    func showFind() {
        findVisible = true
        findFocusRequest += 1
    }

    func closeFind() {
        findVisible = false
        findQuery = ""
        resetFind()
    }

    func findNext() { guard findCursor.count > 0 else { return }; findCursor.next(); showCurrentMatch() }
    func findPrevious() { guard findCursor.count > 0 else { return }; findCursor.previous(); showCurrentMatch() }

    private func scheduleFind() {
        // A running search of the old query stops now (its matches stay drawn until the new one runs).
        findTask?.cancel()
        findProgress = nil
        findTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.runFind()
        }
    }

    /// Stops a running find and clears its matches.
    private func resetFind() {
        findTask?.cancel()
        findTask = nil
        findMatches = []
        findCursor = ReaderFindCursor(matchPages: [], startingAt: nil)
        findCapped = false
        findProgress = nil
        findRevealed = false
        applyHighlights()
    }

    /// Runs the query now (the debounce skipped: Return in the field, the renders). The search runs
    /// off the main actor (`ReaderFindSearch`, RD-1) and its matches arrive in batches: at most
    /// `findLimit` ever become selections, the first one on or after the page being read is shown
    /// as soon as it is found, and a new query (or Done) stops the old search.
    func runFind() {
        resetFind()
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let doc = document, let data = documentData, !q.isEmpty else { return }
        findStartPage = page
        findProgress = 0
        let batches = ReaderFindSearch.search(q, data: data, limit: Self.findLimit)
        findTask = Task { [weak self] in
            for await batch in batches {
                guard !Task.isCancelled, let self else { return }
                self.receive(batch, in: doc)
            }
        }
    }

    /// Waits until the running find (if any) has delivered everything (the renders and the probe).
    func findSettled() async {
        await findTask?.value
    }

    /// One batch of a running find: its matches become selections on the window's own document
    /// (built inside `PDFKitGate`, like the search's own page reads).
    private func receive(_ batch: ReaderFindBatch, in doc: PDFDocument) {
        guard doc === document else { return }
        var pages: [Int] = []
        PDFKitGate.shared.run {
            for m in batch.matches where findMatches.count < Self.findLimit {
                guard let p = doc.page(at: m.page - 1), let sel = p.selection(for: m.range) else { continue }
                findMatches.append(sel)
                pages.append(m.page)
            }
        }
        findCursor.append(pages, startingAt: findStartPage)
        if batch.finished {
            findCursor.finish()
            findCapped = batch.capped
            findProgress = nil
        } else {
            findProgress = batch.pageCount > 0 ? Double(batch.searchedPages) / Double(batch.pageCount) : nil
        }
        if !findRevealed, findCursor.index != nil {
            findRevealed = true
            showCurrentMatch()
        } else if !pages.isEmpty || batch.finished {
            applyHighlights()
        }
    }

    private func showCurrentMatch() {
        applyHighlights()
        guard let i = findCursor.index, i < findMatches.count, let page = findMatches[i].pages.first else { return }
        findRevealed = true
        pending = nil
        reveal(findMatches[i].bounds(for: page), on: page)
    }

    /// Find matches (the current one stronger), drawn by the view only.
    private func applyHighlights() {
        for (i, m) in findMatches.enumerated() {
            m.color = i == findCursor.index ? Self.findCurrentColor : Self.findColor
        }
        pdfView.highlightedSelections = findMatches.isEmpty ? nil : findMatches
    }

    /// Whether the quote highlight is showing (the probe, the renders).
    var hasQuoteHighlight: Bool { !quoteMarks.isEmpty }

    // MARK: Selection and region

    /// The text selection after the mouse is up (or a keyboard change): its anchor and where the
    /// toolbar goes; nil hides the toolbar.
    func selectionSettled() {
        guard let sel = pdfView.currentSelection, let first = sel.pages.first, let doc = document,
              let text = PDFKitGate.shared.run({ sel.string }), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            selection = nil
            return
        }
        let n = doc.index(for: first) + 1
        let rect = sel.bounds(for: first)
        let anchor = ReaderAnchor(paperID: paperID, kind: .selection, page: n, printedLabel: printedLabel(of: n), rect: rect,
                                  pageBounds: first.bounds(for: .cropBox), text: text)
        selection = Target(anchor: anchor, viewRect: viewRect(rect, on: first))
    }

    func clearSelection() {
        pdfView.clearSelection()
        selection = nil
    }

    func boxBegan(at viewPoint: CGPoint) {
        guard let page = pdfView.page(for: viewPoint, nearest: true) else { return }
        boxStart = (page, pdfView.convert(viewPoint, to: page))
        clearSelection()
        region = nil
        band = topLeft(CGRect(origin: viewPoint, size: .zero))
    }

    func boxMoved(to viewPoint: CGPoint) {
        guard let start = boxStart else { return }
        let a = pdfView.convert(start.point, from: start.page)
        band = topLeft(CGRect(x: min(a.x, viewPoint.x), y: min(a.y, viewPoint.y),
                              width: abs(a.x - viewPoint.x), height: abs(a.y - viewPoint.y)))
    }

    func boxEnded(at viewPoint: CGPoint) {
        defer { boxStart = nil; band = nil }
        guard let start = boxStart, let doc = document else { return }
        let end = pdfView.convert(viewPoint, to: start.page)
        let n = doc.index(for: start.page) + 1
        let bounds = start.page.bounds(for: .cropBox)
        guard var anchor = ReaderAnchor.region(paperID: paperID, page: n, printedLabel: printedLabel(of: n),
                                               from: start.point, to: end, pageBounds: bounds) else { return }
        anchor.text = ReaderAnchor.trimmed(PDFKitGate.shared.run { start.page.selection(for: anchor.rect)?.string })
        region = Target(anchor: anchor, viewRect: viewRect(anchor.rect, on: start.page))
    }

    func clearRegion() { region = nil }

    /// Esc: the box, then the selection, then the find bar, then the quote highlight.
    func escape() {
        if band != nil || boxStart != nil { boxStart = nil; band = nil; return }
        if region != nil { region = nil; return }
        if selection != nil || pdfView.currentSelection != nil { clearSelection(); return }
        if findVisible { closeFind(); return }
        ReaderHighlight.remove(quoteMarks, in: pdfView)
        quoteMarks = []
    }

    /// The region as an image drawn from the PDF (copy, Explain).
    func regionImage() -> AssistImage? {
        guard let r = region?.anchor, let page = document?.page(at: r.page - 1) else { return nil }
        return ReaderPDF.renderRegion(r.rect, of: page)
    }

    // MARK: Copy

    func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        show(.copied)
    }

    func copyQuote(_ anchor: ReaderAnchor) {
        guard let text = anchor.text else { return }
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        copy(L.Reader.quote(flat, title: title, page: L.Reader.pageChip(anchor.page, printed: anchor.printedLabel)))
    }

    func copyRegionImage() {
        guard let image = regionImage() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(image.data, forType: .png)
        if let tiff = NSImage(data: image.data)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        show(.copied)
    }

    // MARK: Lifecycle

    /// Window closing: the page is remembered now (not after the debounce).
    func close() {
        ReaderHighlight.remove(quoteMarks, in: pdfView)
        quoteMarks = []
        loadTask?.cancel()
        saveTask?.cancel()
        findTask?.cancel()
        noticeTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if phase == .reading, let engine = state?.engine {
            let id = paperID, page = self.page
            Task { await engine.setReaderPage(paperID: id, page: page) }
        }
    }

    func show(_ n: Notice) {
        notice = n
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: View plumbing

    private func configureView() {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        pdfView.interpolationQuality = .high
        pdfView.model = self
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pageChanged() }
        })
        observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewMoved() }
        })
        observers.append(center.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // While dragging, the toolbar waits for the mouse-up (`ReaderPDFView.mouseUp`).
                if NSEvent.pressedMouseButtons == 0 { self.selectionSettled() } else { self.selection = nil }
            }
        })
    }

    /// The scroll view's clip view posts bounds changes on scroll (installed once the view has one).
    func observeScrolling() {
        guard !observesScrolling, let clip = pdfView.documentView?.enclosingScrollView?.contentView else { return }
        observesScrolling = true
        clip.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewMoved() }
        })
    }

    private func pageChanged() {
        guard let doc = document, let current = pdfView.currentPage else { return }
        let n = doc.index(for: current) + 1
        guard n != page else { return }
        page = n
        saveTask?.cancel()
        let id = paperID
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let engine = self?.state?.engine else { return }
            await engine.setReaderPage(paperID: id, page: n)
        }
    }

    /// Scroll / zoom / resize: the overlays follow their page rects (state changes only when a rect moved).
    func viewMoved() {
        if var s = selection, let page = document?.page(at: s.anchor.page - 1) {
            let moved = viewRect(s.anchor.rect, on: page)
            if moved != s.viewRect { s.viewRect = moved; selection = s }
        }
        if var r = region, let page = document?.page(at: r.anchor.page - 1) {
            let moved = viewRect(r.anchor.rect, on: page)
            if moved != r.viewRect { r.viewRect = moved; region = r }
        }
    }

    /// `ReaderPDFView.layout` (the next turn): scroll observation, the pending target, the overlays.
    func afterLayout() {
        observeScrolling()
        applyPendingIfLaidOut()
        viewMoved()
    }

    /// A page-space rect in the PDF view, origin top-left (SwiftUI's overlay space).
    private func viewRect(_ rect: CGRect, on page: PDFPage) -> CGRect {
        topLeft(pdfView.convert(rect, from: page))
    }

    private func topLeft(_ r: CGRect) -> CGRect {
        pdfView.isFlipped ? r : CGRect(x: r.minX, y: pdfView.bounds.height - r.maxY, width: r.width, height: r.height)
    }
}
