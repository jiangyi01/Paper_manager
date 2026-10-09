import Foundation

// The [Undo] of a toast works only as long as the engine keeps its record (`UndoToken.lifetime`:
// 今天跳过, a multi-select batch, a duplicate decision). Toasts with buttons are sticky, so without
// this the button would stay and do nothing (READING_ASSIST_PLAN §6.4 C1; Phase 1 fix F10). The
// App calls `withUndoExpired` when the window closes and shows the result. Owned by Slice C.
extension Toast {
    /// The undo record's lifetime as the App counts it: a second short of `UndoToken.lifetime`, so a
    /// click just before the button goes still reaches a live record.
    package static var undoButtonLifetime: TimeInterval { max(1, UndoToken.lifetime - 1) }

    /// The toast's `.undo(token:)` buttons (nil when it has none).
    package var undoTokens: [String]? {
        let tokens = buttons.compactMap { b -> String? in if case .undo(let t) = b.action { return t }; return nil }
        return tokens.isEmpty ? nil : tokens
    }

    /// This toast once its undo window closed: the `.undo` buttons removed and `note` ("Undo
    /// expired") added to the message — so a toast left with no button is no longer sticky and
    /// goes away like any plain one. nil when it had no undo button (nothing to change).
    package func withUndoExpired(note: String) -> Toast? {
        guard undoTokens != nil else { return nil }
        var t = self
        t.buttons = buttons.filter { if case .undo = $0.action { return false }; return true }
        t.message = message.isEmpty ? note : message + " · " + note
        return t
    }
}
