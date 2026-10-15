import AppKit
import Observation
import SwiftUI
import PaperDeckCore

extension Notification.Name {
    /// An explanation was stored, pinned or saved to notes (history views reload).
    static let explainHistoryChanged = Notification.Name("PaperDeckExplainHistoryChanged")
}

/// The explanations of one paper (the inspector's section) or of every paper (the history window):
/// threads (a panel's first explanation with its chips and follow-ups), pinned first, newest next.
/// Reads the Core explanation store (`Engine.explanations`, `explanationAnchor`); pin / save to notes
/// go through the engine. Sends nothing. Owned by the Explain UI lane (A2, anchors A4).
@Observable
final class ExplainHistoryModel {
    let paperID: String?
    private(set) var threads: [ExplainHistory.Thread] = []
    private(set) var loaded = false
    var expanded: Set<String> = []
    @ObservationIgnored private weak var app: AppState?

    init(paperID: String?, app: AppState?) {
        self.paperID = paperID
        self.app = app
    }

    func load() async {
        guard let engine = app?.engine else { return }
        let records = (try? await engine.explanations(paperID: paperID, limit: ExplainHistory.loadLimit)) ?? []
        threads = ExplainHistory.threads(records)
        loaded = true
    }

    /// `--explain-render`: fixture threads.
    func applyRenderFixture(_ records: [ExplanationRecord], expanded: Set<String> = []) {
        threads = ExplainHistory.threads(records)
        self.expanded = expanded
        loaded = true
    }

    func toggle(_ t: ExplainHistory.Thread) {
        if expanded.contains(t.id) { expanded.remove(t.id) } else { expanded.insert(t.id) }
    }

    func setPinned(_ t: ExplainHistory.Thread, _ on: Bool) {
        guard let engine = app?.engine else { return }
        Task {
            for r in t.turns { try? await engine.setExplanationPinned(id: r.id, on) }
            NotificationCenter.default.post(name: .explainHistoryChanged, object: nil)
            await load()
        }
    }

    func saveToNotes(_ r: ExplanationRecord) {
        guard let app else { return }
        Task {
            do {
                try await app.engine.appendExplanationToNotes(id: r.id)
                app.post(Toast(kind: .success, message: L.Explain.saved))
                NotificationCenter.default.post(name: .explainHistoryChanged, object: nil)
                await load()
            } catch {
                app.report(error)
            }
        }
    }

    /// Opens the paper where the explanation came from: the reader at its exact anchor (a reader
    /// explanation: the passage or box is marked there), else its page with the excerpt's first
    /// sentence highlighted (`Engine.explanationAnchor`).
    func open(_ t: ExplainHistory.Thread) {
        guard let app, let paperID = t.first.paperID else { return }
        let first = t.first
        Task {
            if let exact = await app.engine.explanationReaderAnchor(id: first.id) {
                ExplainOpen.paper(app: app, paperID: paperID, page: exact.page, anchor: exact, quote: exact.text)
                return
            }
            let back = try? await app.engine.explanationAnchor(id: first.id)
            ExplainOpen.paper(app: app, paperID: back?.paperID ?? paperID, page: back?.page ?? t.page, anchor: nil,
                              quote: back?.highlight ?? first.excerpt)
        }
    }

    static func copy(_ r: ExplanationRecord) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(r.answer, forType: .string)
        ExplainBootstrap.coordinator?.noteOwnPasteboardWrite()
    }
}

/// The rows of a history (the inspector shows `limit` of them).
struct ExplainHistoryList: View {
    let model: ExplainHistoryModel
    let app: AppState?
    /// The history window names each thread's paper; the inspector doesn't.
    var showsPaper = false
    var limit: Int?

    var body: some View {
        let threads = limit.map { Array(model.threads.prefix($0)) } ?? model.threads
        VStack(alignment: .leading, spacing: 10) {
            ForEach(threads) { t in
                ExplainHistoryRow(thread: t, model: model, app: app, showsPaper: showsPaper)
                if t.id != threads.last?.id { Divider().opacity(0.5) }
            }
        }
    }
}

struct ExplainHistoryRow: View {
    let thread: ExplainHistory.Thread
    let model: ExplainHistoryModel
    let app: AppState?
    var showsPaper = false

    private var expanded: Bool { model.expanded.contains(thread.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(verbatim: L.Explain.action(thread.first.action)).font(.caption.weight(.semibold))
                if let page = thread.page { Text(verbatim: L.Explain.page(page)).font(.caption).foregroundStyle(.secondary) }
                Text(thread.latest, format: Date.RelativeFormatStyle(presentation: .named)
                        .locale(Locale(identifier: L.lang == .zh ? "zh-Hans" : "en")))
                    .font(.caption).foregroundStyle(.tertiary)
                if thread.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange).help(L.Explain.pinned) }
                if thread.saved { Image(systemName: "note.text").font(.caption2).foregroundStyle(.secondary).help(L.Explain.saved) }
                Spacer(minLength: 4)
                buttons
            }
            if showsPaper {
                Text(verbatim: paperTitle).font(.callout.weight(.medium)).lineLimit(1)
            }
            if let excerpt = thread.first.excerpt {
                Text(verbatim: "“" + ClipboardOffer.preview(excerpt, limit: 120) + "”")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if expanded {
                ForEach(thread.turns) { r in
                    VStack(alignment: .leading, spacing: 3) {
                        if let q = r.question { Text(verbatim: L.Explain.question(q)).font(.caption.weight(.medium)) }
                        else if r.turn > 0 { Text(verbatim: L.Explain.action(r.action)).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
                        ExplainAnswerView(text: r.answer)
                    }
                }
            } else {
                Text(verbatim: ExplainHistory.summary(thread.turns.last ?? thread.first))
                    .font(.callout).lineLimit(2)
                if thread.turns.count > 1 {
                    Text(verbatim: L.Explain.followUps(thread.turns.count - 1)).font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { model.toggle(thread) } }
    }

    private var paperTitle: String {
        thread.first.paperID.flatMap { app?.snapshot?.row(id: $0)?.paper.title } ?? L.Explain.notFromLibrary
    }

    private var buttons: some View {
        HStack(spacing: 4) {
            if thread.first.paperID != nil {
                icon(thread.page.map { L.Explain.openAt(L.Explain.page($0)) } ?? L.Explain.openPaper, "book") { model.open(thread) }
            }
            icon(L.Explain.copy, "doc.on.doc") { ExplainHistoryModel.copy(thread.turns.last ?? thread.first) }
            icon(thread.pinned ? L.Explain.unpin : L.Explain.pin, thread.pinned ? "pin.slash" : "pin") {
                model.setPinned(thread, !thread.pinned)
            }
            if let r = thread.turns.last, r.paperID != nil, r.savedToNotesAt == nil {
                icon(L.Explain.saveToNotes, "square.and.arrow.down") { model.saveToNotes(r) }
            }
        }
        .font(.caption)
    }

    private func icon(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(title)
            .accessibilityLabel(title)
    }
}

/// Explain ▸ Explanation History (⌘Y in a panel): every paper's explanations, newest first. A
/// floating utility panel, so opening it never changes the app's Dock presence.
final class ExplainHistoryWindowController {
    private static var panel: NSPanel?
    private static var model: ExplainHistoryModel?
    private static var observer: (any NSObjectProtocol)?

    static func show(state: AppState) {
        let model = ExplainHistoryModel(paperID: nil, app: state)
        self.model = model
        let p = panel ?? makePanel()
        panel = p
        p.contentView = NSHostingView(rootView: ExplainHistoryWindowView(model: model, app: state))
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .explainHistoryChanged, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { ExplainHistoryWindowController.reload() }
            }
        }
        Task { await model.load() }
        if !p.isVisible { p.center() }
        p.orderFrontRegardless()
        p.makeKey()
    }

    private static func reload() {
        guard let model else { return }
        Task { await model.load() }
    }

    /// A language switch: the panel's title (its content is SwiftUI and follows by itself).
    static func relocalizeTitle() {
        panel?.title = L.Explain.historyTitle
    }

    private static func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                        styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
                        backing: .buffered, defer: false)
        p.title = L.Explain.historyTitle
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentMinSize = NSSize(width: 380, height: 300)
        p.setFrameAutosaveName("PaperDeckExplainHistory")
        return p
    }
}

struct ExplainHistoryWindowView: View {
    let model: ExplainHistoryModel
    let app: AppState?

    var body: some View {
        Group {
            if model.loaded && model.threads.isEmpty {
                ContentUnavailableView {
                    Label(L.Explain.historyEmpty, systemImage: "sparkles")
                } description: {
                    Text(L.Explain.historyEmptyHint)
                }
            } else {
                ScrollView {
                    ExplainHistoryList(model: model, app: app, showsPaper: true)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 300)
    }
}
