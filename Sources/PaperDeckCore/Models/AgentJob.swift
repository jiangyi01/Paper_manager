import Foundation

/// A queued/finished AI reading of one paper (row of `agent_job`).
package struct AgentJob: Sendable, Identifiable, Equatable {
    package var pk: Int64
    package var id: String
    package var paperPK: Int64
    package var provider: String           // "claude" | "mock"
    package var state: AgentJobState
    package var priority: Int
    package var attempt: Int
    package var textBudget: Int?           // chars of paper text to send (nil = settings default)
    package var effort: String?            // override, e.g. "low" on retry
    package var notBefore: Date?           // backoff
    package var errorKind: String?
    package var errorMessage: String?
    package var model: String?
    package var durationMs: Int?
    package var costUSD: Double?
    package var inputTokens: Int?
    package var outputTokens: Int?
    package var createdAt: Date
    package var startedAt: Date?
    package var finishedAt: Date?

    package init(pk: Int64 = 0, id: String = UUID().uuidString.lowercased(), paperPK: Int64,
                 provider: String, state: AgentJobState, priority: Int = 0, attempt: Int = 0,
                 textBudget: Int? = nil, effort: String? = nil, notBefore: Date? = nil,
                 errorKind: String? = nil, errorMessage: String? = nil, model: String? = nil,
                 durationMs: Int? = nil, costUSD: Double? = nil, inputTokens: Int? = nil,
                 outputTokens: Int? = nil, createdAt: Date = Date(), startedAt: Date? = nil,
                 finishedAt: Date? = nil) {
        self.pk = pk; self.id = id; self.paperPK = paperPK; self.provider = provider; self.state = state
        self.priority = priority; self.attempt = attempt; self.textBudget = textBudget; self.effort = effort
        self.notBefore = notBefore; self.errorKind = errorKind; self.errorMessage = errorMessage
        self.model = model; self.durationMs = durationMs; self.costUSD = costUSD
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.createdAt = createdAt
        self.startedAt = startedAt; self.finishedAt = finishedAt
    }
}
