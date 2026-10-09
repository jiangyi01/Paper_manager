import AppKit
import Foundation
import PaperDeckCore
import PaperDeckConfig

/// Settings ▸ Library ▸ Change… and onboarding: an open panel for a library folder, then a
/// bounded inspection of what it contains (`LibraryInspector`, off the main actor; nothing is
/// written).
@MainActor enum LibraryFolderPicker {
    /// nil when the panel was cancelled.
    static func pick(startingAt: URL?, prompt: String) async -> (url: URL, kind: LibraryFolderKind)? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = startingAt
        panel.prompt = L.Pref.choose
        panel.message = prompt
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url, await LibraryInspector.inspect(url))
    }
}

/// What Settings ▸ Library ▸ Change… offers for a picked folder (pure; `--selftest settings`
/// checks the table). Nothing changes until the user confirms; a switch to another library is
/// done by the next launch (`LibraryPendingAction`), which backs the index up first.
enum LibraryChangeDecision: Equatable {
    /// The folder PaperDeck uses already: nothing to do.
    case current
    /// The same library (same manifest id), e.g. moved in Finder: only `library.path` changes.
    case useSameLibrary(URL)
    /// Another PaperDeck library: the next launch rebuilds the index from its cards.
    case openOther(URL, cards: Int)
    /// The parent of a library: "Did you mean …?" (the child is inspected again).
    case suggestChild(URL, cards: Int)
    /// No library yet: a new empty one — in the folder itself, or in `<folder>/Papers` when it
    /// holds other things.
    case startNew(URL, otherItems: Int)
    /// Can't be used (missing or unreadable).
    case unusable(missing: Bool)

    /// The buttons a decision offers.
    enum Action: String, Equatable {
        case useThisFolder, openThisLibrary, useChild, startNewLibrary, chooseAnother
    }

    static func decide(_ folder: URL, kind: LibraryFolderKind, currentLibrary: URL, currentID: String?) -> LibraryChangeDecision {
        if folder.standardizedFileURL.path == currentLibrary.standardizedFileURL.path { return .current }
        switch kind {
        case .missing: return .unusable(missing: true)
        case .unreadable: return .unusable(missing: false)
        case .empty: return .startNew(folder, otherItems: 0)
        case .otherContent(let items): return .startNew(folder.appendingPathComponent("Papers", isDirectory: true), otherItems: items)
        case .existingLibrary(let id, let cards):
            if let id, let currentID, id == currentID { return .useSameLibrary(folder) }
            return .openOther(folder, cards: cards)
        case .parentOfLibrary(let child, let cards):
            if child.standardizedFileURL.path == currentLibrary.standardizedFileURL.path { return .current }
            return .suggestChild(child, cards: cards)
        }
    }

    var offered: [Action] {
        switch self {
        case .current: return [.chooseAnother]
        case .useSameLibrary: return [.useThisFolder, .chooseAnother]
        case .openOther: return [.openThisLibrary, .chooseAnother]
        case .suggestChild: return [.useChild, .chooseAnother]
        case .startNew: return [.startNewLibrary, .chooseAnother]
        case .unusable: return [.chooseAnother]
        }
    }

    /// What confirming writes: the pending action for the next launch (nil: none) and the new
    /// `library.path`. `useChild` / `chooseAnother` write nothing (another pick follows).
    func confirmation(previous: URL) -> (pending: LibraryPendingAction?, path: String)? {
        switch self {
        case .useSameLibrary(let url): return (nil, url.path)
        case .openOther(let url, _):
            return (LibraryPendingAction(kind: .openExisting, path: url.path, previousPath: previous.path), url.path)
        case .startNew(let url, _):
            return (LibraryPendingAction(kind: .startNew, path: url.path, previousPath: previous.path), url.path)
        case .current, .suggestChild, .unusable: return nil
        }
    }
}
