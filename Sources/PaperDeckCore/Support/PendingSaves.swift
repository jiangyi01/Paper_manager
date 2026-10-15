import Foundation

/// Edits the UI writes a moment later (the notes editor saves 1 s after the last keystroke). Quitting
/// writes them first (`flushAll`, before the engine shuts down): the debounce never runs once the
/// process is gone, and AppKit's terminate closes no view, so nothing else would save them.
/// One entry per edited thing (`key`: the notes editor uses the paper, so a later editor of the
/// same paper replaces an earlier one's entry instead of a stale copy being written after it);
/// each holds the save of the latest text.
@MainActor
package final class PendingSaves {
    private var saves: [String: (token: Int, save: @MainActor () async -> Void)] = [:]
    private var nextToken = 0

    package init() {}

    /// `key`'s latest unsaved edit (replaces the previous one: only the newest text is written).
    /// Returns its token: `clear(_:ifToken:)` removes exactly this registration.
    @discardableResult
    package func set(_ key: String, _ save: @escaping @MainActor () async -> Void) -> Int {
        nextToken += 1
        saves[key] = (nextToken, save)
        return nextToken
    }

    /// `key` has nothing left to save (back to the saved text).
    package func clear(_ key: String) {
        saves[key] = nil
    }

    /// The save registered as `token` was written: `key` is cleared unless a newer edit was
    /// registered since (that one still has to be written at quit).
    package func clear(_ key: String, ifToken token: Int) {
        if saves[key]?.token == token { saves[key] = nil }
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
                if let entry = pending[key] { await entry.save() }
            }
        }
    }
}
