import AppKit
import SwiftUI
import PaperDeckCore

/// Right-click menu content for a card / Today row (§8 右键菜单). Use as
/// `.contextMenu { PaperContextMenu(state: state, row: row) }`.
/// The shortcuts shown here are display hints inside the menu; the window-level
/// commands for the selected paper are the shell's. On a card that is part of a
/// multi-selection the menu acts on the whole selection (`BatchContextMenu`); on any other
/// card on that card alone, like Finder.
struct PaperContextMenu: View {
    let state: AppState
    let row: PaperRow

    init(state: AppState, row: PaperRow) {
        self.state = state
        self.row = row
    }

    private var paper: Paper { row.paper }
    private var id: String { row.paper.id }

    var body: some View {
        if state.selection.menuActsOnSelection(row.id) {
            BatchContextMenu(state: state, rows: state.selection.targetRows)
        } else if paper.isDeleted {
            deletedItems
        } else {
            liveItems
        }
    }

    // MARK: Live papers

    @ViewBuilder private var liveItems: some View {
        Button { state.openPDF(row) } label: { Label(L.cardsMenuOpenPDF, systemImage: "doc.richtext") }
            .keyboardShortcut("o", modifiers: .command)
        Button { CardActions.openInPreview(state, row) } label: { Label(L.cardsMenuOpenInPreview, systemImage: "eye") }
            .keyboardShortcut("o", modifiers: [.command, .option])
        // The built-in reader, one click away while Preview (or the default app) stays the opener.
        if ReaderRouter.isAvailable && state.settings.pdfOpener != ReaderRoute.Opener.paperDeck {
            Button { ReaderRouter(state: state).openReader(row, page: nil, quote: nil) } label: {
                Label(L.Reader.openInReader, systemImage: "book.pages")
            }
            .help(L.Reader.openInReaderHelp)
        }

        Divider()

        statusMenu
        priorityMenu
        deadlineMenu
        categoryMenu

        Divider()

        agentItems

        Divider()

        Button { CardActions.copy(CardText.displayTitle(paper)) } label: { Label(L.cardsMenuCopyTitle, systemImage: "doc.on.doc") }
        Button { CardActions.copy(paper.ids.doi ?? "") } label: { Label(L.cardsMenuCopyDOI, systemImage: "link") }
            .disabled(paper.ids.doi == nil)
        Button { CardActions.editMetadata(state, row) } label: { Label(L.cardsMenuEditMetadata, systemImage: "pencil") }
            .keyboardShortcut("e", modifiers: .command)
        Button { state.revealInFinder(row) } label: { Label(L.cardsMenuRevealInFinder, systemImage: "folder") }
            .keyboardShortcut("r", modifiers: [.command, .shift])

        Divider()

        Button(role: .destructive) { CardActions.softDelete(state, row) } label: {
            Label(L.cardsMenuMoveToRecentlyDeleted, systemImage: "trash")
        }
        .keyboardShortcut(.delete, modifiers: .command)
    }

    private var statusMenu: some View {
        Menu {
            ForEach(PaperStatus.allCases, id: \.self) { s in
                Toggle(L.cardsMenuStatusName(s), isOn: choice(paper.status == s) {
                    state.perform { try await state.engine.setStatus(paperID: id, s) }
                })
            }
            Divider()
            Button(paper.status == .done ? L.cardsMenuMarkUnread : L.cardsMenuMarkDone) {
                state.perform { try await state.engine.toggleDone(paperID: id) }
            }
            .keyboardShortcut("d", modifiers: .command)
        } label: {
            Label(L.cardsMenuStatus, systemImage: "circle.lefthalf.filled")
        }
    }

    private var priorityMenu: some View {
        Menu {
            ForEach([Priority.high, .normal, .low], id: \.self) { p in
                Toggle(L.cardsMenuPriorityName(p), isOn: choice(paper.priority == p) {
                    state.perform { try await state.engine.setPriority(paperID: id, p) }
                })
                .keyboardShortcut(Self.priorityKey(p), modifiers: [.command, .option])
            }
        } label: {
            Label(L.cardsMenuPriority, systemImage: "flag")
        }
    }

    private var deadlineMenu: some View {
        Menu {
            Button(L.cardsMenuPostponeDay) { state.perform { try await state.engine.postponeDay(paperID: id) } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button(L.cardsMenuPostponeWeek) { state.perform { try await state.engine.postponeWeek(paperID: id) } }
            Button(L.cardsMenuSetDate) { CardActions.pickDeadline(state, row) }
            Divider()
            Button(L.cardsMenuRestoreAuto) { state.perform { try await state.engine.restoreAutoDeadline(paperID: id) } }
                .disabled(paper.scheduleMode == .auto && paper.deadlineOrigin == .place)
            Button(L.cardsMenuReplan) { state.perform { try await state.engine.replan(paperID: id) } }
            Button(L.cardsMenuUnschedule) { state.perform { try await state.engine.unschedule(paperID: id) } }
                .disabled(paper.scheduleMode == .none)
        } label: {
            Label(L.cardsMenuDeadline, systemImage: "calendar")
        }
        .disabled(paper.status == .done)
    }

    private var categoryMenu: some View {
        Menu {
            ForEach(state.snapshot?.categories ?? []) { c in
                Toggle(c.category.name, isOn: choice(paper.categoryPK == c.category.pk) {
                    state.perform { try await state.engine.setCategory(paperID: id, categoryPK: c.category.pk) }
                })
            }
            Divider()
            Toggle(L.cardsUncategorized, isOn: choice(paper.categoryPK == nil) {
                state.perform { try await state.engine.setCategory(paperID: id, categoryPK: nil) }
            })
        } label: {
            Label(L.cardsMenuCategory, systemImage: "folder.badge.gearshape")
        }
    }

    @ViewBuilder private var agentItems: some View {
        let label = paper.card == nil ? L.cardsMenuReadWithClaude : L.cardsMenuRereadWithClaude
        if state.settings.agentMode == "off" {
            Button {} label: { Label(label, systemImage: "sparkles") }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(true)
            Button(L.cardsMenuAgentOffExplain) { state.router.showSettings("ai") }
        } else {
            Button { state.perform { try await state.engine.requestReread(paperID: id) } } label: {
                Label(label, systemImage: "sparkles")
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
        }
    }

    // MARK: 最近删除

    @ViewBuilder private var deletedItems: some View {
        Button { state.perform { try await state.engine.restore(paperID: id) } } label: {
            Label(L.cardsMenuRestore, systemImage: "arrow.uturn.backward")
        }
        Button { state.revealInFinder(row) } label: { Label(L.cardsMenuRevealInFinder, systemImage: "folder") }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        Button { CardActions.copy(CardText.displayTitle(paper)) } label: { Label(L.cardsMenuCopyTitle, systemImage: "doc.on.doc") }
        Divider()
        Button(role: .destructive) { CardActions.confirmDeleteNow(state, row) } label: {
            Label(L.cardsMenuDeleteNow, systemImage: "trash.slash")
        }
    }

    /// ⌥⌘1 / ⌥⌘2 / ⌥⌘3 = 高 / 普通 / 低 (§8 右键菜单).
    private static func priorityKey(_ p: Priority) -> KeyEquivalent {
        switch p {
        case .high: return "1"
        case .normal: return "2"
        case .low: return "3"
        }
    }

    /// Checkmark item: shows `isCurrent`; choosing it (on or off) runs `apply`.
    private func choice(_ isCurrent: Bool, _ apply: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { isCurrent }, set: { _ in if !isCurrent { apply() } })
    }
}

// MARK: - Actions shared by the menu, the grid and the badges

enum CardActions {
    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 在「预览」中打开 ⌥⌘O — Preview regardless of the 「打开 PDF 使用」 setting.
    static func openInPreview(_ state: AppState, _ row: PaperRow) {
        let url = row.pdfURL
        guard FileManager.default.fileExists(atPath: url.path),
              let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            state.openPDF(row)      // reports the missing file / falls back to the default app
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: NSWorkspace.OpenConfiguration())
        state.perform { _ = try await state.engine.markOpened(paperID: row.id) }
    }

    static func softDelete(_ state: AppState, _ row: PaperRow) {
        let id = row.id
        state.perform {
            try await state.engine.softDelete(paperID: id)
            if state.selectedPaperID == id { state.selectedPaperID = nil }
        }
    }

    /// 永久删除 with a confirmation alert (sheet on the frontmost window when possible).
    static func confirmDeleteNow(_ state: AppState, _ row: PaperRow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L.cardsMenuDeleteNowTitle(CardText.displayTitle(row.paper))
        alert.informativeText = L.cardsMenuDeleteNowBody
        let confirm = alert.addButton(withTitle: L.cardsMenuDeleteNowConfirm)
        confirm.hasDestructiveAction = true
        alert.addButton(withTitle: L.cancel)
        let id = row.id
        Task {
            let response: NSApplication.ModalResponse
            if let parent = CardSheetPresenter.parentWindow() {
                response = await alert.beginSheetModal(for: parent)
            } else {
                NSApp.activate()
                response = alert.runModal()
            }
            guard response == .alertFirstButtonReturn else { return }
            state.perform {
                try await state.engine.deleteNow(paperID: id)
                if state.selectedPaperID == id { state.selectedPaperID = nil }
            }
        }
    }

    /// 设定日期… → graphical date picker sheet → pinDeadline.
    static func pickDeadline(_ state: AppState, _ row: PaperRow) {
        let today = state.snapshot?.today.today ?? LocalDate.today()
        let id = row.id
        CardSheetPresenter.present { close in
            CardDeadlinePickerSheet(title: CardText.displayTitle(row.paper), current: row.paper.deadline, today: today,
                                onCancel: close,
                                onSet: { day in
                                    close()
                                    state.perform { try await state.engine.pinDeadline(paperID: id, date: day) }
                                })
        }
    }

    /// 编辑元数据… ⌘E → the detail slice's MetadataEditSheet in a sheet window.
    static func editMetadata(_ state: AppState, _ row: PaperRow) {
        CardSheetPresenter.present { close in
            MetadataSheetHost(state: state, row: row, close: close)
        }
    }

    /// Default AgentBadge click handling (§8 AgentBadge「点击」).
    static func handleBadge(_ action: AgentBadgeAction, paper: Paper, state: AppState) {
        switch action {
        case .openAISettings:
            state.router.showSettings("ai")
        case .retry:
            let pk = paper.pk
            state.perform { await state.engine.agents.retry(paperPK: pk) }
        case .confirmHeld:
            guard state.settings.agentMode != "off" else { state.router.showSettings("ai"); return }
            let held = (state.snapshot?.rows ?? [])
                .filter { $0.paper.aiState == .held && $0.paper.aiNote != AgentQueue.modeOffNote }
                .map(\.id)
            let ids = held.contains(paper.id) ? held : [paper.id] + held
            // `added` stays empty: the batch dialog then only asks about Claude, not scheduling.
            // [Read All] confirms this paper; the others that wait for their own confirmation
            // (possibly unpublished, confidential, under duplicate review…) stay held and are named.
            state.pendingBatch = ImportBatchSummary(batchID: "held-" + UUID().uuidString.lowercased(),
                                                    added: [], heldForAI: ids, confirmedPaperID: paper.id)
        }
    }
}

/// Bridges the Binding-based MetadataEditSheet to a sheet window.
private struct MetadataSheetHost: View {
    let state: AppState
    let row: PaperRow
    let close: () -> Void
    @State private var presented = true

    var body: some View {
        MetadataEditSheet(state: state, row: row, isPresented: $presented)
            .onChange(of: presented) { _, isPresented in
                if !isPresented { close() }
            }
    }
}

// MARK: - Sheet presentation (works from context menus, which have no view state of their own)

enum CardSheetPresenter {
    private static var standalone: [NSWindow] = []

    /// The window a sheet should attach to: the key (or main) window when it is a real
    /// document-sized window — never the small floating drop strip.
    static func parentWindow() -> NSWindow? {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        return candidates.first { $0.isVisible && $0.frame.width >= 420 && $0.frame.height >= 300 && $0.attachedSheet == nil }
    }

    /// Shows `make(close)` as a sheet (or a small centred window when there is no suitable
    /// parent). The content must offer its own Cancel/Done buttons that call `close`.
    static func present<Content: View>(_ make: (_ close: @escaping () -> Void) -> Content) {
        let box = WindowBox()
        let close: () -> Void = {
            guard let w = box.window else { return }
            if let parent = w.sheetParent { parent.endSheet(w) } else { w.orderOut(nil) }
            standalone.removeAll { $0 === w }
        }
        let host = NSHostingController(rootView: make(close))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        box.window = window
        if let parent = parentWindow() {
            parent.beginSheet(window)
        } else {
            window.title = L.appName
            window.level = .modalPanel
            window.center()
            standalone.append(window)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private final class WindowBox { weak var window: NSWindow? }
}

/// 设定日期…: a graphical calendar with quick picks. Setting a date pins the DDL (also the
/// multi-selection's Set Date…, `BatchActions.pickDeadline`).
struct CardDeadlinePickerSheet: View {
    let title: String
    let today: LocalDate
    let onCancel: () -> Void
    let onSet: (LocalDate) -> Void
    @State private var date: Date

    init(title: String, current: LocalDate?, today: LocalDate,
         onCancel: @escaping () -> Void, onSet: @escaping (LocalDate) -> Void) {
        self.title = title
        self.today = today
        self.onCancel = onCancel
        self.onSet = onSet
        let initial = current.flatMap { $0 >= today ? $0 : nil } ?? today.adding(days: 1)
        _date = State(initialValue: initial.date(hour: 12, minute: 0))
    }

    private var quickPicks: [(String, LocalDate)] {
        let weekday = today.weekday()                       // 1 = Sun … 7 = Sat
        let toMonday = ((2 - weekday) + 7) % 7
        return [
            (SharedStrings.tomorrow(L.lang), today.adding(days: 1)),
            (L.cardsPickNextMonday, today.adding(days: toMonday == 0 ? 7 : toMonday)),
            (L.cardsPickInAWeek, today.adding(days: 7)),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L.cardsPickTitle).font(.headline)
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            DatePicker("", selection: $date, in: today.startOfDay()..., displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                ForEach(quickPicks, id: \.1) { label, day in
                    Button(label) { date = day.date(hour: 12, minute: 0) }
                        .controlSize(.small)
                }
            }
            Label(L.cardsPickHint, systemImage: "pin.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L.cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L.cardsPickSet) { onSet(LocalDate(date)) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}
