import Foundation

/// `codex exec --json` lines as assist progress (dive-cli §4.2). The exec stream carries no token
/// deltas: an `agent_message` arrives whole (`item.completed`), or as full-text-so-far snapshots
/// (`item.started` / `item.updated`, if the CLI emits them) — each is a `.replace`, never a delta.
/// `reasoning` items only say "thinking"; their text is never shown or matched. The batch state
/// (`events`) feeds `CodexEvents.classifyFailure` at the end.
package struct CodexAssistEvents: Sendable {
    package enum Output: Sendable, Equatable {
        /// `turn.started`: the model has the turn.
        case turnStarted
        /// A `reasoning` item started or changed.
        case thinking
        /// The agent message's full text so far (changed since the last one).
        case message(String)
        case oversize
    }

    package private(set) var events = CodexEvents()
    /// The event types seen, for diagnostics (types only; bounded, runs collapsed).
    package private(set) var typeSequence: [String] = []
    private var shown: String?

    package init() {}

    package mutating func feed(_ line: Data) -> [Output] {
        if line == LineSplitter.oversizeMarker { return [.oversize] }
        guard let (type, value) = events.feed(line: String(decoding: line, as: UTF8.self)) else { return [] }
        if typeSequence.count < ClaudeStreamParser.maxTypeSequence, typeSequence.last != type { typeSequence.append(type) }
        switch type {
        case "turn.started":
            return [.turnStarted]
        case "item.started", "item.updated", "item.completed":
            guard let item = value["item"] else { return [] }
            if (item["type"]?.stringValue ?? item["item_type"]?.stringValue) == "reasoning" { return [.thinking] }
            guard CodexEvents.isAgentMessage(item), let text = events.latestAgentText, text != shown, !text.isEmpty else {
                return []
            }
            shown = text
            return [.message(text)]
        default:
            return []
        }
    }
}
