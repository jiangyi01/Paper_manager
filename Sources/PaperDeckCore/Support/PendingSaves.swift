import Foundation

/// Edits the UI writes a moment later (the notes editor saves 1 s after the last keystroke). Quitting
/// writes them first (`flushAll`, before the engine shuts down): the debounce never runs once the
/// process is gone, and AppKit's terminate closes no view, so nothing else would save them.
/// One entry per editor (`key`); each holds the save of that editor's latest text.
@MainActor
package final class PendingSaves {
    private var saves: [String: @MainActor () async -> Void] = [:]

    package init() {}

    /// `key`'s latest unsaved edit (replaces the previous one: only the newest text is written).
    package func set(_ key: String, _ save: @escaping @MainActor () async -> Void) {
        saves[key] = save
    }

    /// `key` has nothing left to save (written, or back to the saved text).
    package func clear(_ key: String) {
        saves[key] = nil
    }

    package var isEmpty: Bool { saves.isEmpty }
    package var count: Int { saves.count }

    /// Runs every pending save once, one after another (quit). The entries are taken out before they
    /// run; one registered while they ran (an edit landing during the flush) gets one more round.
    package func flushAll() async {
        for _ in 0..<2 where !saves.isEmpty {
            let pending = saves
            saves.removeAll()
            for key in pending.keys.sorted() {
                if let save = pending[key] { await save() }
            }
        }
    }
}
