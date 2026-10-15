import AppKit
import PaperDeckCore

/// The menu bar's Paper menu: the card context menu's shortcuts — ⌘O, ⌥⌘O, ⌘D, ⌥⌘1/2/3, ⇧⌘P, ⌥⌘R,
/// ⇧⌘R, ⌘⌫ — as window commands on the selected papers (the focused paper, or the whole
/// multi-selection), so they work with the card menu closed. Each runs what its context-menu item
/// runs (`CardActions`, the engine, `SelectionModel.apply` for a multi-selection). Enabled only while
/// the library window is key and no text field or text view has the focus (`PaperCommandRules`):
/// in the search field or the notes ⌘⌫ still deletes to the start of the line.
enum PaperMenu {
    struct Entry {
        let command: PaperCommand
        let key: String
        let modifiers: NSEvent.ModifierFlags
    }

    /// ⌫ as a menu key equivalent (`NSBackspaceCharacter`): the Delete key.
    static let deleteKey = "\u{8}"

    /// Each command's shortcut, the one its context-menu item shows (`PaperContextMenu`).
    static let entries: [Entry] = [
        Entry(command: .openPDF, key: "o", modifiers: .command),
        Entry(command: .openInPreview, key: "o", modifiers: [.command, .option]),
        Entry(command: .toggleDone, key: "d", modifiers: .command),
        Entry(command: .priorityHigh, key: "1", modifiers: [.command, .option]),
        Entry(command: .priorityNormal, key: "2", modifiers: [.command, .option]),
        Entry(command: .priorityLow, key: "3", modifiers: [.command, .option]),
        Entry(command: .postponeDay, key: "p", modifiers: [.command, .shift]),
        Entry(command: .readWithAI, key: "r", modifiers: [.command, .option]),
        Entry(command: .revealInFinder, key: "r", modifiers: [.command, .shift]),
        Entry(command: .moveToTrash, key: deleteKey, modifiers: .command),
    ]

    /// The Paper menu (`LibraryMainMenu` adds it after Edit). Titles in the UI language; the
    /// changing ones (Mark as Read / Unread, Read / Re-read with AI) are set when it validates.
    static func make(target: PaperMenuTarget) -> NSMenu {
        let menu = NSMenu(title: L.Shell.menuPaper)
        func item(_ command: PaperCommand) -> NSMenuItem {
            let entry = entries.first { $0.command == command }
            let i = NSMenuItem(title: title(command, rows: []), action: #selector(PaperMenuTarget.runCommand(_:)),
                               keyEquivalent: entry?.key ?? "")
            i.keyEquivalentModifierMask = entry?.modifiers ?? []
            i.representedObject = command.rawValue
            i.target = target
            return i
        }
        menu.addItem(item(.openPDF))
        menu.addItem(item(.openInPreview))
        menu.addItem(.separator())
        menu.addItem(item(.toggleDone))
        let priority = NSMenu(title: L.cardsMenuPriority)
        [PaperCommand.priorityHigh, .priorityNormal, .priorityLow].forEach { priority.addItem(item($0)) }
        let holder = NSMenuItem(title: L.cardsMenuPriority, action: nil, keyEquivalent: "")
        holder.submenu = priority
        menu.addItem(holder)
        menu.addItem(item(.postponeDay))
        menu.addItem(.separator())
        menu.addItem(item(.readWithAI))
        menu.addItem(.separator())
        menu.addItem(item(.revealInFinder))
        menu.addItem(.separator())
        menu.addItem(item(.moveToTrash))
        return menu
    }

    /// The item's title for `rows` (none: the single-paper wording).
    static func title(_ command: PaperCommand, rows: [PaperRow]) -> String {
        switch command {
        case .openPDF: return rows.count > 1 ? L.Select.openPDFs(rows.count) : L.cardsMenuOpenPDF
        case .openInPreview: return L.cardsMenuOpenInPreview
        case .toggleDone:
            return rows.isEmpty || PaperCommandRules.marksRead(rows.map(\.paper)) ? L.cardsMenuMarkDone : L.cardsMenuMarkUnread
        case .priorityHigh: return L.cardsMenuPriorityName(.high)
        case .priorityNormal: return L.cardsMenuPriorityName(.normal)
        case .priorityLow: return L.cardsMenuPriorityName(.low)
        case .postponeDay: return L.cardsMenuPostponeDay
        case .readWithAI:
            if rows.count > 1 { return BatchActions.rereadTitle(rows) }
            return rows.first?.paper.card == nil ? L.cardsMenuReadWithClaude : L.cardsMenuRereadWithClaude
        case .revealInFinder: return L.cardsMenuRevealInFinder
        case .moveToTrash: return rows.count > 1 ? L.Select.moveToTrash(rows.count) : L.cardsMenuMoveToRecentlyDeleted
        }
    }

    /// A text field (its field editor) or a text view has the focus: the keys are the text's.
    static func isEditingText(_ responder: NSResponder?) -> Bool {
        responder is NSText || responder is NSTextField
    }

    /// The selected visible papers the commands act on (`SelectionModel.targetIDs`, as drawn).
    static func targetRows(_ state: AppState) -> [PaperRow] {
        guard let snap = state.snapshot else { return [] }
        return state.selection.targetIDs.compactMap { snap.row(id: $0) }
    }

    /// Where the keys were pressed and what is selected.
    static func context(_ state: AppState, rows: [PaperRow], keyWindow: NSWindow?) -> PaperCommandContext {
        let libraryIsKey = keyWindow?.identifier == ActivationPolicy.library && keyWindow?.attachedSheet == nil
        return PaperCommandContext(libraryIsKey: libraryIsKey, editingText: isEditingText(keyWindow?.firstResponder),
                                   listsPapers: state.sidebar != .mail, papers: rows.map(\.paper),
                                   aiOff: state.settings.agentMode == "off")
    }

    /// Runs `command` on `rows` as the context menu does: one paper through its own operation, a
    /// multi-selection through `SelectionModel.apply` (one transaction, one undo toast).
    static func run(_ command: PaperCommand, state: AppState, rows: [PaperRow]) {
        guard !rows.isEmpty else { return }
        let ids = rows.map(\.id)
        let single = rows.count == 1 ? rows.first : nil
        switch command {
        case .openPDF:
            if let single { state.openPDF(single) } else { BatchActions.openPDFs(state, rows: rows) }
        case .openInPreview:
            for row in rows.prefix(PaperCommandRules.openLimit) { CardActions.openInPreview(state, row) }
        case .toggleDone:
            if rows.count > 1, PaperCommandRules.marksRead(rows.map(\.paper)) {
                state.selection.apply(.setStatus(.done), ids: ids)
            } else {
                // One paper, or papers all read: each back to Reading / To Read as its own ⌘D does.
                for id in ids { state.perform { try await state.engine.toggleDone(paperID: id) } }
            }
        case .priorityHigh, .priorityNormal, .priorityLow:
            guard let p = command.priority else { return }
            if let single {
                let id = single.id
                state.perform { try await state.engine.setPriority(paperID: id, p) }
            } else {
                state.selection.apply(.setPriority(p), ids: ids)
            }
        case .postponeDay:
            if let single {
                let id = single.id
                state.perform { try await state.engine.postponeDay(paperID: id) }
            } else {
                state.selection.apply(.postponeDay, ids: ids)
            }
        case .readWithAI:
            if let single {
                let id = single.id
                state.perform { try await state.engine.requestReread(paperID: id) }
            } else {
                BatchActions.confirmReread(state, rows: rows)    // asks first, as the selection's menu does
            }
        case .revealInFinder:
            if let single { state.revealInFinder(single) } else { NSWorkspace.shared.activateFileViewerSelecting(rows.map(\.pdfURL)) }
        case .moveToTrash:
            if let single { CardActions.softDelete(state, single) } else { state.selection.apply(.moveToTrash, ids: ids) }
        }
    }
}

/// The Paper menu's target: validates each item against the selection and runs it.
final class PaperMenuTarget: NSObject, NSMenuItemValidation {
    private weak var state: AppState?

    init(state: AppState?) {
        self.state = state
    }

    @objc func runCommand(_ sender: NSMenuItem) {
        guard let state, let command = Self.command(sender) else { return }
        let rows = PaperMenu.targetRows(state)
        // Checked again: a key equivalent reaches here only through validation, a stale item never acts.
        guard PaperCommandRules.isEnabled(command, PaperMenu.context(state, rows: rows, keyWindow: NSApp.keyWindow)) else { return }
        PaperMenu.run(command, state: state, rows: rows)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let command = Self.command(item) else { return true }
        guard let state else { return false }
        let rows = PaperMenu.targetRows(state)
        item.title = PaperMenu.title(command, rows: rows)
        return PaperCommandRules.isEnabled(command, PaperMenu.context(state, rows: rows, keyWindow: NSApp.keyWindow))
    }

    private static func command(_ item: NSMenuItem) -> PaperCommand? {
        (item.representedObject as? String).flatMap(PaperCommand.init(rawValue:))
    }
}
