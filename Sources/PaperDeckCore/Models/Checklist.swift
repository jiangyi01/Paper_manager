import Foundation

/// One reading step, e.g. "Fig. 2: compare cell-type proportions…" (15 min, p. 5).
package struct ChecklistItem: Sendable, Identifiable, Equatable, Codable {
    package var id: String                 // short random id, stable across edits
    package var ord: Double                // display order (REAL so inserts don't renumber)
    package var text: String
    package var section: String?           // locator, e.g. "Fig. 2", "Methods: Clustering"
    package var page: Int?                 // 1-based page where it starts
    package var minutes: Int
    package var kind: ChecklistKind
    package var origin: ItemOrigin
    package var userEdited: Bool
    package var doneAt: Date?

    package init(id: String = ChecklistItem.newID(), ord: Double, text: String, section: String? = nil,
                 page: Int? = nil, minutes: Int, kind: ChecklistKind = .other, origin: ItemOrigin,
                 userEdited: Bool = false, doneAt: Date? = nil) {
        self.id = id; self.ord = ord; self.text = text; self.section = section; self.page = page
        self.minutes = minutes; self.kind = kind; self.origin = origin; self.userEdited = userEdited
        self.doneAt = doneAt
    }

    package var isDone: Bool { doneAt != nil }

    /// 8 lowercase base-36 characters.
    package static func newID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }
}
