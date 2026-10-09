import Foundation
import Observation
import PaperDeckCore

/// Explain & Ask state every assist surface shares: the lane's status (mode, login, pause, today's
/// count) for banners and the quota footer. `AppState.assist`. Owned by Slice A; Slice 0 created
/// the contract (`attach`, `update`) only.
@Observable
final class AssistUIModel {
    /// The lane's latest status (`EngineEvent.assistStatus`).
    private(set) var status = AssistStatus()
    @ObservationIgnored private weak var state: AppState?

    init() {}

    /// Called once by `AppState.init`.
    func attach(_ state: AppState) { self.state = state }

    /// `EngineEvent.assistStatus`.
    func update(_ s: AssistStatus) {
        if s != status { status = s }
    }
}
