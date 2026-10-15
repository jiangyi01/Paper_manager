import Foundation

// The library window's Paper menu (§8 右键菜单's shortcuts as window commands): ⌘O, ⌥⌘O, ⌘D,
// ⌥⌘1/2/3, ⇧⌘P, ⌥⌘R, ⇧⌘R and ⌘⌫ act on the selected papers while the card menu is closed, like the
// card's context menu does on its card. Pure rules: which command is on for which selection; the
// App builds the menu and runs the same actions as the context menu.

/// A command of the Paper menu (each has the shortcut its context-menu item shows).
package enum PaperCommand: String, Sendable, CaseIterable {
    case openPDF                // ⌘O
    case openInPreview          // ⌥⌘O
    case toggleDone             // ⌘D  Mark as Read / Mark as Unread
    case priorityHigh           // ⌥⌘1
    case priorityNormal         // ⌥⌘2
    case priorityLow            // ⌥⌘3
    case postponeDay            // ⇧⌘P
    case readWithAI             // ⌥⌘R
    case revealInFinder         // ⇧⌘R
    case moveToTrash            // ⌘⌫  Move to Recently Deleted

    /// The priority a priority command sets.
    package var priority: Priority? {
        switch self {
        case .priorityHigh: return .high
        case .priorityNormal: return .normal
        case .priorityLow: return .low
        default: return nil
        }
    }
}

/// What the Paper menu acts on, and where the keys were pressed.
package struct PaperCommandContext: Sendable, Equatable {
    /// The library window is the key window (no sheet, reader, Ask or other window in front).
    package var libraryIsKey: Bool
    /// A text field or text view has the focus: the keys keep their text meaning there (⌘⌫ deletes
    /// to the start of the line, ⌘D / ⌘O stay the field's), so no command runs.
    package var editingText: Bool
    /// The view lists papers (every section but the Mail inbox).
    package var listsPapers: Bool
    /// The selected visible papers (`SelectionModel.targetIDs`): the focused paper, or a multi-selection.
    package var papers: [Paper]
    /// AI reading is off (`agent.mode` = off): one paper's Read with AI is off, as in its context menu
    /// (a multi-selection's goes through the confirmation sheet, which explains it).
    package var aiOff: Bool

    package init(libraryIsKey: Bool, editingText: Bool, listsPapers: Bool, papers: [Paper], aiOff: Bool) {
        self.libraryIsKey = libraryIsKey; self.editingText = editingText; self.listsPapers = listsPapers
        self.papers = papers; self.aiOff = aiOff
    }
}

package enum PaperCommandRules {
    /// Open PDF / Open in Preview are offered up to this many papers at once (the multi-selection's
    /// "Open N PDFs" too).
    package static let openLimit = 10

    /// The command can run for this selection (the menu item is enabled; its key equivalent fires).
    package static func isEnabled(_ command: PaperCommand, _ c: PaperCommandContext) -> Bool {
        guard c.libraryIsKey, !c.editingText, c.listsPapers, !c.papers.isEmpty else { return false }
        // Recently Deleted: only Show in Finder (its other actions — restore, delete now — have no key).
        let live = c.papers.allSatisfy { !$0.isDeleted }
        switch command {
        case .revealInFinder:
            return true
        case .openPDF, .openInPreview:
            return live && c.papers.count <= openLimit
        case .toggleDone, .priorityHigh, .priorityNormal, .priorityLow, .moveToTrash:
            return live
        case .postponeDay:
            // The DDL items do nothing for papers marked read (the context menu disables them).
            return live && c.papers.contains { $0.status != .done }
        case .readWithAI:
            return live && (c.papers.count > 1 || !c.aiOff)
        }
    }

    /// ⌘D marks the papers read unless every one of them is read already (then: unread again).
    package static func marksRead(_ papers: [Paper]) -> Bool {
        !papers.allSatisfy { $0.status == .done }
    }
}
