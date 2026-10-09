import Foundation

/// When the panel's match line may correct the paper (CUX-6 "Change…" / "Not this paper"), pure —
/// the App's `ExplainMatchLine` only acts on it. A correction explains the same capture again at
/// once with the click's ticket, and the rejection is remembered for the window (2 h). So it is
/// never offered while a turn runs, nor while the panel shows a privacy refusal: there it would be
/// the one click that gets past a never-AI paper's block, or past the confirmation a confidential /
/// possibly unpublished paper or a mail window needs (phase-3 fixes, lead integration). The user
/// confirms first ([Send Anyway]) or changes the paper's own policy; then the match can be corrected.
package enum ExplainCorrectionRules {
    package static func canCorrect(_ phase: ExplainPhase) -> Bool {
        if phase.isBusy { return false }
        if case .refused(let r) = phase {
            switch r {
            case .blocked, .confirmPrivacy, .privacyUnchecked: return false
            default: return true
            }
        }
        return true
    }
}
