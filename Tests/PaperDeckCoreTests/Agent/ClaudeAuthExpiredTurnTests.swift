import Foundation
import Testing
@testable import PaperDeckCore

/// Real CLI 2.1.286 behaviour seen in the 2026-10-01 assist spike: when the OAuth session has
/// expired, `claude -p` answers locally (model "<synthetic>", zero tokens) with a result line
/// `subtype: "success", is_error: true, result: "Failed to authenticate: OAuth session expired and
/// could not be refreshed"`. That must read as "needs login", not a generic failure, for both the
/// card path and an assist turn.
@Suite struct ClaudeAuthExpiredTurnTests {
    static let message = "Failed to authenticate: OAuth session expired and could not be refreshed"

    @Test func anAssistTurnWithAnExpiredSessionNeedsLogin() {
        let env = ClaudeEnvelope(type: "result", subtype: "success", isError: true, result: Self.message)
        #expect(ClaudeEnvelope.classifyTurn(result: env, stderr: Data(), exitCode: 0) == .failure(.notLoggedIn))
    }

    @Test func theCardPathReadsTheSameResultLineAsNeedsLogin() throws {
        let line = #"{"type":"result","subtype":"success","is_error":true,"result":"\#(Self.message)","total_cost_usd":0}"#
        let cls = ClaudeEnvelope.classify(exitCode: 1, stdout: Data(line.utf8), stderr: Data())
        #expect(cls == .notLoggedIn)
    }
}
