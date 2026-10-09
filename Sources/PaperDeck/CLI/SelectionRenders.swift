import AppKit
import SwiftUI
import PaperDeckCore

/// `--render OUTDIR --root SCRATCH --select-only [--no-mail-demo] [--lang zh|en] [--appearance light|dark]
/// [--probe-gestures]` (READING_ASSIST_PLAN §9.1 render checks; Slice C, C1): the multi-select surfaces
/// from a scratch library — the grids with nothing selected (as before multi-select), the grid with a
/// selection and its bar (wide / narrow), the bar alone at three widths and in Recently Deleted, the
/// multi-inspector, the Select menu's, Export's and the context menu's items, the re-read confirmation (AI on /
/// off), Add Tag…, and the batch toasts. Fixture papers are inserted when the root is empty. Nothing
/// here probes or starts an AI CLI: no Settings ▸ AI or setup page is drawn, the engine's providers
/// are the renderer's mocks and the agent queue is never started.
///
/// `--probe-gestures`: also drives the real grid with synthetic events in an off-screen window
/// (⌘-clicks, arrow keys with and without ⇧, ⌘A with the grid focused and with a text field focused,
/// Esc) and prints one `PROBE name PASS|FAIL` line each, then `PROBE SUMMARY n/m`.
enum SelectionRenders {
    static func render(state: AppState, engine: Engine, root: URL, appearance: NSAppearance?, out: URL,
                       suffix: String, probe: Bool) async throws {
        SelectionModel.previewOverride = true
        defer { SelectionModel.previewOverride = false }
        try await seedIfEmpty(engine: engine, root: root)
        state.scheduleRefresh(delay: .zero)
        var waited = 0
        while (state.snapshot?.rows.count ?? 0) < 6 && waited < 100 { try await Task.sleep(for: .milliseconds(100)); waited += 1 }
        let chrome = LibraryChrome()

        // Nothing selected: the grids as before multi-select (a regression check against today's grid).
        for (name, item) in [("plain-all", SidebarItem.all), ("plain-toread", .toRead)] {
            state.sidebar = item
            try await Task.sleep(for: .milliseconds(300))
            try await PreviewRenderer.captureView(CardGridView(state: state, rows: state.visibleRows).environment(chrome)
                                                    .frame(width: 1000, height: 1300),
                                                  size: NSSize(width: 1000, height: 1300), appearance: appearance,
                                                  out.appendingPathComponent("select-\(name)-\(suffix).png"))
        }

        // The grid with four papers selected, the second one focused.
        state.sidebar = .all
        try await Task.sleep(for: .milliseconds(300))
        state.selection.select(.mostRecentlyAdded, n: 4)
        let picked = state.selection.targetIDs
        if picked.count > 1 { state.selection.focus(picked[1]) }
        for (name, size) in [("grid", NSSize(width: 1000, height: 1300)), ("grid-narrow", NSSize(width: 600, height: 900))] {
            try await PreviewRenderer.captureView(CardGridView(state: state, rows: state.visibleRows, chromeStyle: .material)
                                                    .environment(chrome).frame(width: size.width, height: size.height),
                                                  size: size, appearance: appearance,
                                                  out.appendingPathComponent("select-\(name)-\(suffix).png"))
        }
        for (name, width) in [("bar", 1000.0), ("bar-icons", 640.0), ("bar-compact", 380.0)] {
            try await PreviewRenderer.captureView(SelectionBar(state: state, style: .material).padding(14).frame(width: width),
                                                  size: nil, appearance: appearance,
                                                  out.appendingPathComponent("select-\(name)-\(suffix).png"))
        }
        try await PreviewRenderer.captureView(MultiInspector(state: state).frame(width: 380, height: 900),
                                              size: NSSize(width: 380, height: 900), appearance: appearance,
                                              out.appendingPathComponent("select-inspector-\(suffix).png"))
        // Menus can't be captured open: the Select menu's items and the multi-paper context menu as lists.
        try await PreviewRenderer.captureView(VStack(alignment: .leading, spacing: 6) { SelectMenuItems(state: state) }
                                                .padding(14).frame(width: 340, alignment: .leading),
                                              size: nil, appearance: appearance,
                                              out.appendingPathComponent("select-menu-\(suffix).png"))
        // Export ▸ (copy as / save as, metadata only) — the items the bar's and the context menu's Export show.
        try await PreviewRenderer.captureView(VStack(alignment: .leading, spacing: 6) {
                                                  BatchMenus(state: state, rows: state.selection.targetRows).exportItems
                                              }
                                              .padding(14).frame(width: 340, alignment: .leading),
                                              size: nil, appearance: appearance,
                                              out.appendingPathComponent("select-export-\(suffix).png"))
        try await PreviewRenderer.captureView(VStack(alignment: .leading, spacing: 6) {
                                                  BatchContextMenu(state: state, rows: state.selection.targetRows)
                                              }
                                              .padding(14).frame(width: 340, alignment: .leading),
                                              size: nil, appearance: appearance,
                                              out.appendingPathComponent("select-contextmenu-\(suffix).png"))
        // Re-read with AI: the confirmation with AI reading on, then off (render-suite settings only).
        let mode = state.settings.agentMode
        state.settings.agentMode = AIProviderKind.claude.rawValue
        try await PreviewRenderer.captureView(BatchRereadSheet(state: state, count: picked.count, onCancel: {}, onConfirm: {}, onOpenSettings: {}),
                                              size: nil, appearance: appearance,
                                              out.appendingPathComponent("select-reread-\(suffix).png"))
        state.settings.agentMode = AgentMode.off.rawValue
        try await PreviewRenderer.captureView(BatchRereadSheet(state: state, count: picked.count, onCancel: {}, onConfirm: {}, onOpenSettings: {}),
                                              size: nil, appearance: appearance,
                                              out.appendingPathComponent("select-reread-off-\(suffix).png"))
        state.settings.agentMode = mode
        try await PreviewRenderer.captureView(BatchAddTagSheet(count: picked.count, suggestions: BatchActions.frequentTags(state),
                                                               onCancel: {}, onAdd: { _ in }),
                                              size: nil, appearance: appearance,
                                              out.appendingPathComponent("select-addtag-\(suffix).png"))
        // The batch toast (with Undo) next to a plain one.
        state.post(SelectionModel.toast(for: BatchNotice(operation: "setStatus.done", paperIDs: picked, undoToken: "render")))
        state.post(SelectionModel.toast(for: BatchNotice(operation: BatchOperation.rereadCode, paperIDs: picked)))
        try await PreviewRenderer.captureView(ToastStack(state: state, maxVisible: 3).frame(width: 320).padding(10), size: nil,
                                              appearance: appearance, out.appendingPathComponent("select-toasts-\(suffix).png"))

        // Recently Deleted: two papers moved there, both selected.
        let ids = Array(picked.prefix(2))
        _ = try await engine.applyBatch(.moveToTrash, paperIDs: ids)
        state.scheduleRefresh(delay: .zero)
        try await Task.sleep(for: .milliseconds(400))
        state.sidebar = .recentlyDeleted
        try await Task.sleep(for: .milliseconds(200))
        state.selection.selectAllVisible()
        try await PreviewRenderer.captureView(SelectionBar(state: state, style: .material).padding(14).frame(width: 640),
                                              size: nil, appearance: appearance,
                                              out.appendingPathComponent("select-bar-deleted-\(suffix).png"))
        _ = try await engine.applyBatch(.restore, paperIDs: ids)
        state.selection.clear()

        if probe {
            state.sidebar = .all
            state.scheduleRefresh(delay: .zero)
            try await Task.sleep(for: .milliseconds(400))
            await GestureProbe.run(state: state, appearance: appearance)
        }
    }

    // MARK: Fixture papers

    /// Eight synthetic papers (titles, authors, deadlines, one done, one reading, two tags) when the
    /// scratch root has none — never anyone's real library.
    static func seedIfEmpty(engine: Engine, root: URL) async throws {
        guard try await engine.db.livePapers().isEmpty else { return }
        let today = LocalDate.today()
        let fixtures: [(String, [String], Int, String, Int?, PaperStatus, Priority)] = [
            ("A single-cell atlas of the developing human cortex", ["Li Wang", "Arnold R. Kriegstein"], 2024, "Nature", 0, .toRead, .high),
            ("Spatial transcriptomics reveals tissue organization", ["Mei Chen", "Jonas Berg"], 2025, "Cell", 1, .toRead, .normal),
            ("Foundation models for protein design", ["Sana Patel"], 2025, "Science", 3, .reading, .normal),
            ("Benchmarking autonomous research agents", ["Jin Kim", "Ana Ruiz"], 2026, "arXiv", 6, .toRead, .normal),
            ("Chromatin accessibility across human tissues", ["Rosa Gómez"], 2023, "Nature Genetics", nil, .toRead, .low),
            ("Gut microbiome and host metabolism", ["Tobi Okafor", "Lena Vogel"], 2024, "Cell Host & Microbe", 9, .toRead, .normal),
            ("Long-read sequencing of structural variants", ["Eva Novak"], 2025, "Nature Methods", -2, .toRead, .normal),
            ("Neural circuit mapping with expansion microscopy", ["Hana Sato"], 2024, "Neuron", 4, .done, .normal),
        ]
        let library = engine.paths.papers
        let base = Date().addingTimeInterval(-86_400 * 10)
        for (i, f) in fixtures.enumerated() {
            let name = String(format: "%d_Fixture_%02d", f.2, i)
            let dir = library.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let bytes = Data("%PDF-1.4\n% select fixture \(i)\n%%EOF\n".utf8)
            let pdf = FileNamer.pdfName(forFolder: name)
            try bytes.write(to: dir.appendingPathComponent(pdf))
            let deadline = f.4.map { today.adding(days: $0) }
            let p = Paper(sha256: FileOps.sha256(of: bytes), fileSize: Int64(bytes.count), title: f.0, titleRank: .api,
                          authors: f.1, year: f.2, venue: f.3, metaSource: .crossref, pageCount: 12,
                          folder: "Papers/" + name, pdfName: pdf, originalName: name + ".pdf", nameFinal: true, stage: .ready,
                          status: f.5, priority: f.6, deadline: deadline, scheduleMode: deadline == nil ? .none : .auto,
                          provisional: false, estMinutes: 45 + i * 5,
                          tldr: i % 3 == 0 ? "A fixture summary line for the card." : nil,
                          addedAt: base.addingTimeInterval(Double(i) * 3_600), doneAt: f.5 == .done ? Date() : nil)
            let saved = try await engine.db.insertPaper(p, checklist: [
                ChecklistItem(ord: 0, text: "Abstract", section: "Abstract", page: 1, minutes: 5, kind: .overview, origin: .heuristic),
                ChecklistItem(ord: 1, text: "Results", section: "Results", page: 3, minutes: 30, kind: .other, origin: .heuristic),
            ])
            if i < 2 { _ = try await engine.addTag(paperID: saved.id, i == 0 ? "single-cell" : "spatial") }
        }
    }
}

// MARK: - Gesture probe

/// Drives the real `CardGridView` with synthetic events in an off-screen window (never on a display,
/// so no real click can land in it; the app is never activated). Checks that LazyVGrid delivers
/// plain / ⌘ / ⇧ clicks to the cards, that the focused grid gets the arrow keys, ⌘A and Esc, and that
/// ⌘A in a focused text field selects its text instead of the cards.
private enum GestureProbe {
    final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    struct Harness: View {
        let state: AppState
        @State var text = "some text"

        var body: some View {
            VStack(spacing: 0) {
                TextField("probe", text: $text).frame(width: 300, height: 30)
                CardGridView(state: state, rows: state.visibleRows, chromeStyle: .material)
                    .frame(width: 1000, height: 1270)
            }
            .frame(width: 1000, height: 1300, alignment: .top)
        }
    }

    static func run(state: AppState, appearance: NSAppearance?) async {
        // Never hang a render run: a stuck probe ends the process.
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) { print("PROBE TIMEOUT"); exit(3) }
        let size = NSSize(width: 1000, height: 1300)
        let window = KeyableWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        let hosting = NSHostingView(rootView: Harness(state: state).background(.background))
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(900))
        hosting.layoutSubtreeIfNeeded()

        let rows = state.visibleRows.map(\.id)
        guard rows.count >= 6 else { print("PROBE setup FAIL (only \(rows.count) rows)"); return }
        var results: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            results.append((name, ok))
            print("PROBE \(name) \(ok ? "PASS" : "FAIL")\(ok ? "" : " " + detail())")
        }
        // Card centres in window coordinates: 3 columns of (960 − 32) / 3 pt, rows 300 + 16 pt,
        // 18 pt top padding under the 30 pt text field; aim at the thumbnail (no controls there).
        let colWidth = (1000.0 - 40 - 32) / 3
        func point(_ i: Int) -> NSPoint {
            let x = 20 + Double(i % 3) * (colWidth + 16) + colWidth / 2
            let yTop = 30 + 18 + Double(i / 3) * 316 + 60
            return NSPoint(x: x, y: size.height - yTop)
        }
        /// One click at `at`. `tracking`: the mouse-up waits in the queue, so a control's tracking
        /// loop (a text field's) finds it; else both are dispatched in turn, as for the cards.
        func press(_ at: NSPoint, _ flags: NSEvent.ModifierFlags = [], tracking: Bool = false) async {
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: at, modifierFlags: flags,
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            }
            guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
            if tracking {
                NSApp.postEvent(up, atStart: false)
                NSApp.sendEvent(down)
                if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(pending)
                }
            } else {
                NSApp.sendEvent(down)
                NSApp.sendEvent(up)
            }
            try? await Task.sleep(for: .milliseconds(350))       // past the double-click wait
        }
        func click(_ i: Int, _ flags: NSEvent.ModifierFlags = []) async { await press(point(i), flags) }
        func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) async {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: code) {
                    window.sendEvent(e)
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        /// Edit ▸ Select All as the menu sends it: `selectAll:` up the responder chain from the first responder.
        func selectAllCommand() async {
            // NSApp.sendAction needs a key window; walk the window's chain the way it does
            // (each responder, then its supplemental target — where SwiftUI's onCommand lives).
            let action = #selector(NSResponder.selectAll(_:))
            var responder = window.firstResponder
            while let r = responder {
                if r.responds(to: action) { r.perform(action, with: nil); break }
                if let target = r.supplementalTarget(forAction: action, sender: nil) as? NSObject {
                    target.perform(action, with: nil); break
                }
                responder = r.nextResponder
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let sel = state.selection
        func ids() -> Set<String> { SelectionLogic.normalized(sel.current).ids }


        // The app is never activated, so this window is never key, and AppKit passes only plain
        // ⌘-clicks to a background window (any other click just brings it forward). The clicks below
        // hold ⌘, so each goes the real way: NSApp → the app's local monitor (ClickModifiers) → the
        // card's tap gesture → SelectionModel. Plain and ⇧-clicks run the same handler with other
        // flags (their rules: SelectionLogicTests); ⇧-ranges are driven from the keyboard below.
        await click(0, .command)
        check("command-click-selects", ids() == [rows[0]] && state.selectedPaperID == rows[0], "\(ids())")
        await click(2, .command)
        check("command-click-adds", ids() == [rows[0], rows[2]] && state.selectedPaperID == rows[2], "\(ids())")
        await click(0, .command)
        check("command-click-removes", ids() == [rows[2]] && state.selectedPaperID == rows[2], "\(ids())")
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!), down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        await key(124, right, [.function, .numericPad])                                   // →
        check("arrow-moves", ids() == [rows[3]] && state.selectedPaperID == rows[3], "\(ids())")
        await key(124, right, [.shift, .function, .numericPad])                           // ⇧→
        check("shift-arrow-extends", ids() == [rows[3], rows[4]], "\(ids())")
        await key(125, down, [.shift, .function, .numericPad])                            // ⇧↓ (3 columns)
        check("shift-arrow-down-extends-the-range", ids() == Set(rows[3...7]) && state.selectedPaperID == rows[7], "\(ids())")
        check("bar-shown", sel.isMulti && sel.targetIDs == Array(rows[3...7]))
        await selectAllCommand()
        check("command-a-in-grid", ids() == Set(rows), "\(ids().count) of \(rows.count)")
        await key(53, "\u{1b}")                                                 // Esc
        check("escape-clears", ids().isEmpty && state.selectedPaperID == nil, "\(ids())")
        // ⌘A while the text field is focused: the field's text, never the cards.
        await click(1, .command)
        let before = ids()
        await press(NSPoint(x: 500, y: size.height - 15), tracking: true)
        let editing = window.firstResponder is NSTextView
        await selectAllCommand()
        let editor = window.firstResponder as? NSTextView
        check("text-field-focused", editing)
        check("command-a-in-text-field-keeps-cards", ids() == before, "\(ids())")
        check("command-a-selects-the-text", editor.map { $0.selectedRange().length == $0.string.utf16.count && $0.string.utf16.count > 0 } ?? false)
        let passed = results.filter(\.1).count
        print("PROBE SUMMARY \(passed)/\(results.count)")
        state.selection.clear()
    }
}
