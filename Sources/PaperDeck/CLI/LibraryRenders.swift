import AppKit
import SwiftUI
import PaperDeckCore

/// `--render OUTDIR --root SCRATCH --library-only [--widths "720, 900, 1100, …"] [--no-mail-demo]
/// [--lang zh|en] [--appearance light|dark]`: the library window's columns at several window widths
/// — sidebar | banners + card grid | inspector (closed, and open from 1100 pt) — plus Today, the
/// grouped To Read grid, a multi-selection with its bar, the search empty state and the inspector
/// alone at three widths. Split views can't be captured offscreen, so each render lays the real
/// column views side by side at the widths the window gives them (sidebar 236, inspector 380; the
/// sidebar is collapsed below the window's 900 pt minimum).
///
/// Fixture papers (synthetic titles, thumbnails, tags, categories, AI states, a missing file) are
/// inserted when the scratch root has none — never anyone's real library. Nothing here probes or
/// starts an AI CLI: the engine's providers are the renderer's mocks, the agent queue is never
/// started, and the "not signed in" banner comes from a synthetic status event.
enum LibraryRenders {
    static let defaultWidths: [Double] = [720, 900, 1100, 1280, 1440, 1680, 2000, 2560]
    static let sidebarWidth: Double = 236
    static let inspectorWidth: Double = 380
    static let height: Double = 1000

    /// `--widths "720, 900, …"` (commas and/or spaces); the defaults when absent or unreadable.
    static func widths(_ raw: String?) -> [Double] {
        let parsed = (raw ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }.filter { $0 >= 320 }
        return parsed.isEmpty ? defaultWidths : parsed
    }

    static func render(state: AppState, engine: Engine, root: URL, appearance: NSAppearance?, out: URL,
                       suffix: String, widths: [Double]) async throws {
        SelectionModel.previewOverride = true
        defer { SelectionModel.previewOverride = false }
        let ids = try await seedIfEmpty(engine: engine, root: root)
        state.scheduleRefresh(delay: .zero)
        var waited = 0
        while (state.snapshot?.rows.count ?? 0) < 10 && waited < 100 { try await Task.sleep(for: .milliseconds(100)); waited += 1 }
        // Claude chosen but not signed in: the error banner (and the cards' "needs login" look) —
        // a synthetic status, no CLI is asked.
        engine.events.send(.agentStatus(AgentQueueStatus(provider: .notLoggedIn("logged_out"), providerKind: .claude, mode: .claude,
                                                         queued: 1, held: 1)))
        try await Task.sleep(for: .milliseconds(300))
        let chrome = LibraryChrome()
        let rich = ids.first ?? state.snapshot?.rows.first?.id

        // The All grid, inspector closed at every width and open from 1100.
        state.sidebar = .all
        for width in widths {
            state.selection.clear()
            state.selectedPaperID = nil
            try await Task.sleep(for: .milliseconds(150))
            try await capture(state: state, chrome: chrome, width: width, content: .grid, inspector: false, appearance: appearance,
                              out.appendingPathComponent("lib-\(Int(width))-closed-\(suffix).png"))
            if width >= 1100 {
                state.selectedPaperID = rich
                try await Task.sleep(for: .milliseconds(150))
                try await capture(state: state, chrome: chrome, width: width, content: .grid, inspector: true, appearance: appearance,
                                  out.appendingPathComponent("lib-\(Int(width))-open-\(suffix).png"))
            }
        }
        state.selectedPaperID = nil

        // Today (a centred list) at a narrow, a medium and a wide window.
        state.sidebar = .today
        for width in [720.0, 1100, 1440, 2000] where widths.contains(width) || width == 1100 {
            try await Task.sleep(for: .milliseconds(150))
            try await capture(state: state, chrome: chrome, width: width, content: .today, inspector: false, appearance: appearance,
                              out.appendingPathComponent("today-\(Int(width))-\(suffix).png"))
        }

        // To Read sorted by DDL: the grouped grid with its pinned headers.
        state.sidebar = .toRead
        state.sort = .deadline
        for width in [900.0, 1440] {
            try await Task.sleep(for: .milliseconds(150))
            try await capture(state: state, chrome: chrome, width: width, content: .grid, inspector: false, appearance: appearance,
                              out.appendingPathComponent("toread-\(Int(width))-\(suffix).png"))
        }

        // Four papers selected: the bar over the grid (and the multi-inspector when open).
        state.sidebar = .all
        try await Task.sleep(for: .milliseconds(200))
        state.selection.select(.mostRecentlyAdded, n: 4)
        for (width, open) in [(900.0, false), (1280.0, true), (1680.0, false)] {
            try await Task.sleep(for: .milliseconds(150))
            try await capture(state: state, chrome: chrome, width: width, content: .grid, inspector: open, appearance: appearance,
                              out.appendingPathComponent("select-\(Int(width))-\(open ? "open" : "closed")-\(suffix).png"))
        }
        state.selection.clear()

        // A search with no results.
        state.searchText = "zzzz-no-such-paper"
        try await Task.sleep(for: .milliseconds(600))
        try await capture(state: state, chrome: chrome, width: 1280, content: .grid, inspector: false, appearance: appearance,
                          out.appendingPathComponent("empty-search-\(suffix).png"))
        state.searchText = ""
        try await Task.sleep(for: .milliseconds(400))

        // The inspector alone, tall, at its minimum, ideal and a wide width.
        if let rich, let row = state.snapshot?.row(id: rich) {
            state.selectedPaperID = rich
            for width in [320.0, 380, 480] {
                try await PreviewRenderer.captureView(PaperDetailView(state: state, row: row).environment(chrome)
                                                        .frame(width: width, height: 1500),
                                                      size: NSSize(width: width, height: 1500), appearance: appearance,
                                                      out.appendingPathComponent("inspector-\(Int(width))-\(suffix).png"))
            }
        }
        state.selectedPaperID = nil
        await probeToolbar(state: state, chrome: chrome, appearance: appearance, out: out, suffix: suffix)
    }

    // MARK: Toolbar overflow

    /// A titled window that stays off every screen (the system would otherwise move it on screen).
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// The real library window's toolbar (bridged from SwiftUI, as `LibraryWindowController` makes it)
    /// at several widths, inspector closed and open: prints which items stay in the toolbar and which
    /// went to its overflow menu (`TOOLBAR …` lines). An invisible window far off screen; never key.
    static func probeToolbar(state: AppState, chrome: LibraryChrome, appearance: NSAppearance?, out: URL? = nil,
                             suffix: String = "") async {
        state.sidebar = .all
        let hosting = NSHostingView(rootView: LibraryRootView(state: state).environment(chrome))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        hosting.sizingOptions = []
        let w = OffscreenWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1280, height: 700),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        w.toolbarStyle = .unified
        w.appearance = appearance
        w.contentView = hosting
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.orderFrontRegardless()
        defer { w.orderOut(nil) }
        for open in [false, true] {
            chrome.inspectorPresented = open
            for width in [900.0, 1100, 1280, 1440, 2000] {
                w.setFrame(NSRect(x: -30_000, y: -30_000, width: width, height: 700), display: false)
                try? await Task.sleep(for: .milliseconds(700))
                w.layoutIfNeeded()
                let items = w.toolbar?.items ?? []
                func name(_ item: NSToolbarItem) -> String {
                    let label = item.label.isEmpty ? item.itemIdentifier.rawValue : item.label
                    return label.replacingOccurrences(of: " ", with: "_")
                }
                let shown = items.filter(\.isVisible).map(name)
                let overflow = items.filter { !$0.isVisible }.map(name)
                print("TOOLBAR width=\(Int(width)) inspector=\(open ? "open" : "closed") visible=\(shown) overflow=\(overflow)")
                // The title bar strip as drawn (glass may not be captured offscreen).
                if let out, let frame = w.contentView?.superview {
                    frame.layoutSubtreeIfNeeded()
                    let strip = NSRect(x: 0, y: frame.bounds.height - 60, width: frame.bounds.width, height: 60)
                    if let rep = frame.bitmapImageRepForCachingDisplay(in: strip) {
                        frame.cacheDisplay(in: strip, to: rep)
                        let url = out.appendingPathComponent("toolbar-\(Int(width))-\(open ? "open" : "closed")-\(suffix).png")
                        try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    }
                }
            }
        }
        chrome.inspectorPresented = false
    }

    enum Content { case grid, today }

    private static func capture(state: AppState, chrome: LibraryChrome, width: Double, content: Content, inspector: Bool,
                                appearance: NSAppearance?, _ url: URL) async throws {
        let view = LibraryColumns(state: state, chrome: chrome, sidebar: width >= 900, content: content, inspector: inspector)
            .environment(chrome)
            .frame(width: width, height: height)
        try await PreviewRenderer.captureView(view, size: NSSize(width: width, height: height), appearance: appearance, url)
    }

    // MARK: Fixtures

    /// One fixture paper: what the card, the Today row and the inspector have to fit.
    private struct Fixture {
        var title: String
        var authors: [String]
        var year: Int?
        var venue: String?
        var doi: String? = nil
        var arxiv: String? = nil
        var deadline: Int?
        var status: PaperStatus = .toRead
        var priority: Priority = .normal
        var category: Int? = nil
        var tags: [String] = []
        var tldr: String? = nil
        var abstract: String? = nil
        var ai: AIState = .none
        var aiNote: String? = nil
        var aiSeen = true
        var flags: PaperFlags = []
        var textQuality: TextQuality? = nil
        var filenameOnly = false
        var pinned = false
        var card = false
        var thumbnail = true
    }

    private static let categories = ["Neuroscience", "Genomics", "Machine learning", "Microbiology"]

    private static let fixtures: [Fixture] = [
        Fixture(title: "A single-cell atlas of the developing human cortex reveals lineage-specific transcriptional programs",
                authors: ["Li Wang", "Mei Chen", "Jonas Berg", "Ana Ruiz", "Tobi Okafor", "Lena Vogel", "Arnold R. Kriegstein"],
                year: 2024, venue: "Nature", doi: "10.1038/s41586-024-08351-7", deadline: 0, priority: .high, category: 0,
                tags: ["single-cell", "cortex", "development"],
                tldr: "Single-cell RNA-seq of 400k cells maps how radial glia diversify into the cortex's neuron and glia lineages.",
                ai: .done, aiSeen: false, card: true),
        Fixture(title: "Spatial transcriptomics reveals tissue organization", authors: ["Mei Chen", "Jonas Berg"], year: 2025,
                venue: "Cell", deadline: 1, category: 1, tags: ["spatial"], ai: .queued),
        Fixture(title: "Foundation models for protein design", authors: ["Sana Patel"], year: 2025, venue: "Science", deadline: 3,
                status: .reading, category: 2,
                tldr: "A 3B-parameter protein language model designs binders that fold as predicted in 70% of wet-lab tests, beating diffusion baselines on every benchmark the authors tried.",
                ai: .running),
        Fixture(title: "Benchmarking autonomous research agents on open-ended scientific discovery tasks",
                authors: ["Jin Kim", "Ana Ruiz", "Rosa Gómez", "Hana Sato"], year: 2026, venue: nil, arxiv: "2604.09554", deadline: 6,
                tags: ["agents", "benchmark", "llm", "evaluation"], ai: .failed, aiNote: "The reading stopped: the PDF's text ended early."),
        Fixture(title: "Chromatin accessibility across human tissues", authors: ["Rosa Gómez"], year: 2023, venue: "Nature Genetics",
                deadline: nil, priority: .low, category: 1, ai: .held, aiNote: AgentQueue.modeOffNote),
        Fixture(title: "Gut microbiome and host metabolism", authors: ["Tobi Okafor", "Lena Vogel"], year: 2024, venue: "Cell Host & Microbe",
                deadline: 9, category: 3,
                abstract: "The gut microbiome shapes host metabolism through bile acids and short-chain fatty acids. We profile 1,200 people over two years.",
                ai: .needsLogin),
        Fixture(title: "Long-read sequencing of structural variants", authors: ["Eva Novak"], year: 2025, venue: "Nature Methods",
                deadline: -2, category: 1, flags: .missing, thumbnail: false),
        Fixture(title: "Neural circuit mapping with expansion microscopy", authors: ["Hana Sato"], year: 2024, venue: "Neuron",
                deadline: 4, status: .done, category: 0, tags: ["imaging"], ai: .done),
        Fixture(title: "Cryo-EM structure of a bacterial flagellar motor in its native membrane", authors: ["Ivo Petrov", "Sun Li"],
                year: 2024, venue: nil, doi: "10.1101/2024.05.01.123456", deadline: 4, category: 3, tags: ["cryo-em", "structure"],
                ai: .done, textQuality: .partial),
        Fixture(title: "基于深度学习的单细胞多组学整合方法综述", authors: ["王磊", "陈梅", "李想"], year: 2025, venue: "科学通报",
                deadline: 12, category: 2, tags: ["review"], tldr: "系统比较了 24 种单细胞多组学整合方法，给出按数据规模与模态选择方法的建议。", ai: .done),
        Fixture(title: "s41586-024-07766-6", authors: [], year: nil, venue: nil, deadline: 5, ai: .skipped, filenameOnly: true, thumbnail: false),
        Fixture(title: "Microglia prune synapses during adolescent cortical development", authors: ["Paul Martin", "Ines Duarte"],
                year: 2023, venue: "Neuron", deadline: 2, category: 0, ai: .limited, pinned: true),
        Fixture(title: "Mixture-of-experts language models at scale", authors: ["Omar Haddad"], year: 2026, venue: "ICML", deadline: 15,
                category: 2, tags: ["llm"], ai: .held),
        Fixture(title: "Encrypted supplementary methods", authors: ["Lab Archive"], year: 2022, venue: nil, deadline: nil,
                flags: .locked, thumbnail: false),
    ]

    /// Inserts the fixtures when the scratch root has no papers; returns their ids in fixture order
    /// (empty when the root already had papers).
    @discardableResult
    static func seedIfEmpty(engine: Engine, root: URL) async throws -> [String] {
        guard try await engine.db.livePapers().isEmpty else {
            return try await engine.db.livePapers().sorted { $0.addedAt < $1.addedAt }.map(\.id)
        }
        let today = LocalDate.today()
        var categoryPKs: [Int64] = []
        for name in categories { categoryPKs.append(try await engine.createCategory(name: name).pk) }
        let library = engine.paths.papers
        let thumbs = ThumbnailStore(paths: engine.paths)
        let base = Date().addingTimeInterval(-86_400 * 20)
        var ids: [String] = []
        for (i, f) in fixtures.enumerated() {
            let name = String(format: "%d_Library_%02d", f.year ?? 2020, i)
            let dir = library.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let bytes = Data("%PDF-1.4\n% library fixture \(i)\n%%EOF\n".utf8)
            let pdf = FileNamer.pdfName(forFolder: name)
            if !f.flags.contains(.missing) { try bytes.write(to: dir.appendingPathComponent(pdf)) }
            let deadline = f.deadline.map { today.adding(days: $0) }
            var paperIDs = PaperIDs()
            paperIDs.doi = f.doi
            paperIDs.arxivID = f.arxiv
            let card: ReadingCard? = f.card ? ReadingCard(
                tldr: f.tldr ?? "", summary: "Radial glia give rise to excitatory neurons first, then astrocytes and oligodendrocytes; the switch is set by a small set of transcription factors.",
                contributions: ["An atlas of 400k cells across mid-gestation", "Lineage trees from barcoded organoids"],
                method: "Single-cell RNA-seq, ATAC-seq and lineage barcoding in organoids.",
                results: ["Six progenitor states", "Gliogenic switch at week 20"],
                limitations: [.init(text: "Few late-gestation samples", source: .authors)],
                keyTerms: [.init(term: "radial glia", definition: "Neural stem cells of the developing cortex")], resources: [],
                paperType: .research, category: categories[0], tags: f.tags, difficulty: .medium,
                estimatedMinutes: 60, checklist: [], textQuality: .good) : nil
            let p = Paper(sha256: FileOps.sha256(of: bytes), fileSize: Int64(bytes.count), ids: paperIDs,
                          title: f.filenameOnly ? f.title + ".pdf" : f.title, titleRank: f.filenameOnly ? .filename : .api,
                          authors: f.authors, year: f.year, venue: f.venue, abstract: f.abstract,
                          metaSource: f.filenameOnly ? .none : .crossref, pageCount: 12, flags: f.flags,
                          folder: "Papers/" + name, pdfName: pdf, originalName: name + ".pdf", nameFinal: true, stage: .ready,
                          status: f.status, priority: f.priority, deadline: deadline,
                          scheduleMode: deadline == nil ? .none : (f.pinned ? .pinned : .auto),
                          provisional: f.filenameOnly, estMinutes: 40 + i * 5,
                          tldr: f.tldr, card: card, textQuality: f.textQuality,
                          aiState: f.ai, aiNote: f.aiNote, aiSeen: f.aiSeen,
                          addedAt: base.addingTimeInterval(Double(i) * 3_600 * 20),
                          doneAt: f.status == .done ? Date().addingTimeInterval(-86_400 * 2) : nil)
            let saved = try await engine.db.insertPaper(p, checklist: [
                ChecklistItem(ord: 0, text: "Abstract and figure 1", section: "Abstract", page: 1, minutes: 8, kind: .overview, origin: .heuristic),
                ChecklistItem(ord: 1, text: "Results: the lineage trees", section: "Results", page: 4, minutes: 25, kind: .other, origin: .heuristic),
                ChecklistItem(ord: 2, text: "Methods: barcoding", section: "Methods", page: 9, minutes: 15, kind: .other, origin: .heuristic),
            ])
            ids.append(saved.id)
            if let c = f.category { _ = try await engine.setCategory(paperID: saved.id, categoryPK: categoryPKs[c]) }
            for tag in f.tags { _ = try await engine.addTag(paperID: saved.id, tag) }
            if f.thumbnail, let jpeg = thumbnailJPEG(title: f.title, venue: f.venue ?? (f.doi != nil ? "bioRxiv" : "arXiv"), seed: i) {
                try thumbs.save(cardJPEG: jpeg, id: saved.id)
            }
        }
        return ids
    }

    /// A page-1 look-alike (560 × 240 px, like the extractor's crop): a journal band, the title,
    /// an author line and grey text lines.
    static func thumbnailJPEG(title: String, venue: String, seed: Int) -> Data? {
        let w = 560, h = 240
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        let accents: [NSColor] = [.systemRed, .systemBlue, .systemTeal, .systemOrange, .systemPurple]
        accents[seed % accents.count].withAlphaComponent(0.85).setFill()
        NSRect(x: 0, y: h - 22, width: w, height: 22).fill()
        (venue as NSString).draw(at: NSPoint(x: 40, y: h - 18),
                                 withAttributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.white])
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let titleFont = NSFont(name: "Times New Roman Bold", size: 24) ?? .boldSystemFont(ofSize: 24)
        (title as NSString).draw(in: NSRect(x: 40, y: h - 112, width: w - 80, height: 82),
                                 withAttributes: [.font: titleFont, .foregroundColor: NSColor.black, .paragraphStyle: para])
        NSColor(white: 0.55, alpha: 1).setFill()
        NSRect(x: 40, y: h - 128, width: 260, height: 7).fill()
        for k in 0..<6 {
            NSColor(white: 0.84, alpha: 1).setFill()
            NSRect(x: 40, y: h - 150 - k * 15, width: w - 80 - (k % 3) * 46, height: 6).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

/// The library window's columns side by side (what `LibraryRootView`'s split view shows), for the
/// renders: sidebar | banners + content | inspector.
private struct LibraryColumns: View {
    let state: AppState
    let chrome: LibraryChrome
    let sidebar: Bool
    let content: LibraryRenders.Content
    let inspector: Bool

    var body: some View {
        HStack(spacing: 0) {
            if sidebar {
                LibrarySidebarView(state: state)
                    .frame(width: LibraryRenders.sidebarWidth)
                Divider()
            }
            VStack(spacing: 0) {
                LibraryBanners(state: state, chrome: chrome)
                switch content {
                case .grid:
                    let rows = state.visibleRows
                    if rows.isEmpty {
                        EmptyStateView(state: state, section: state.sidebar)
                    } else {
                        CardGridView(state: state, rows: rows, chromeStyle: .material)
                    }
                case .today:
                    TodayView(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if inspector {
                Divider()
                Group {
                    if state.selection.isMulti {
                        MultiInspector(state: state)
                    } else if let row = state.selectedRow {
                        PaperDetailView(state: state, row: row)
                    }
                }
                .frame(width: LibraryRenders.inspectorWidth)
            }
        }
    }
}
