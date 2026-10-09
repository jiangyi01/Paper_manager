import Foundation

/// The user's per-paper AI policy (`paper_policy`, READING_ASSIST_PLAN §5): "Unpublished /
/// confidential" asks before any assist turn sends its content; "Never use AI" refuses every
/// assist turn (Explain, Q&A, the duplicate judge). A paper without a row has neither.
package struct PaperPolicy: Sendable, Equatable, Codable {
    /// Who set it last.
    package enum SetBy: String, Sendable, Codable, CaseIterable {
        case user, mail, merge, rebuild
    }

    package var confidential: Bool
    package var neverAI: Bool
    package var setBy: SetBy
    package var setAt: Date

    package init(confidential: Bool = false, neverAI: Bool = false, setBy: SetBy = .user, setAt: Date = Date()) {
        self.confidential = confidential; self.neverAI = neverAI; self.setBy = setBy; self.setAt = setAt
    }

    /// Neither flag: no row is stored.
    package var isEmpty: Bool { !confidential && !neverAI }
}
