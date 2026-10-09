import Foundation

/// The notes editor's merge when a paper's notes change underneath unsaved typing (R-QA-9). "Save to
/// Notes" (Ask, Explain) appends a block in Core (`ExplainNotes.append`); an editor holding unsaved
/// edits of the same paper used to save its whole text afterwards and drop that block. Pure, so the
/// App's `NotesEditor` stays a thin caller.
package enum NotesMerge {
    /// `base`: the text the editor and the store last agreed on; `stored`: the notes now; `local`:
    /// the editor's unsaved text. When `stored` is `base` with one or more Save-to-Notes blocks
    /// appended (each starts with "— ", like `ExplainNotes.block` / `QANotes.block`), returns `local`
    /// with the same blocks appended (or `local` itself when it already holds them). Any other
    /// change — the editor's own save landing, an edit elsewhere — returns nil: the editor's pending
    /// save wins, as before.
    package static func appendedBlocks(base: String, stored: String, local: String) -> String? {
        let trimmedBase = base.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        guard stored != base, stored.hasPrefix(trimmedBase) else { return nil }
        let added = String(stored.dropFirst(trimmedBase.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !added.isEmpty, added.hasPrefix(blockMarker) else { return nil }
        // What came after `base` must start on a line of its own (not the tail of a longer line).
        let gap = stored.dropFirst(trimmedBase.count).prefix { $0.isWhitespace }
        guard trimmedBase.isEmpty || gap.contains(where: \.isNewline) else { return nil }
        if local.contains(added) { return local }
        return ExplainNotes.append(added, to: local)
    }

    /// The first characters of every block Save to Notes appends.
    package static let blockMarker = "— "
}
