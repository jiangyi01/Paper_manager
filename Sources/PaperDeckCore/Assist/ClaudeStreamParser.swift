import Foundation

/// Incremental parser of `claude -p --output-format stream-json --verbose --include-partial-messages`
/// (dive-cli §3.3): one JSON object per line.
/// - `system` / `init`: session id, model, tools (asserted empty by the session).
/// - `stream_event`: Anthropic SSE events. `content_block_delta` + `text_delta` → `.delta`;
///   a second `message_start` within a turn (an API retry) restarts the text → `.replace("")`.
///   Thinking / signature deltas are ignored.
/// - `assistant`: the message's full text → `.replace` when it differs (repairs missed deltas).
/// - `result`: the end of the turn → `.result(ClaudeEnvelope)` (the card envelope's shape).
/// Unknown types (rate-limit, control, replay, hook lines) and non-JSON lines are skipped. The
/// model's text is never interpreted here: classification happens only on the result line and
/// stderr (`ClaudeEnvelope.classifyTurn`).
package struct ClaudeStreamParser: Sendable {
    package enum Output: Sendable, Equatable {
        /// `system` / `init`.
        case started(sessionID: String?, model: String?, tools: [String])
        case delta(String)
        case replace(String)
        case result(ClaudeEnvelope)
        /// A line over the splitter's cap stood in for by `LineSplitter.oversizeMarker`.
        case oversize
    }

    /// The text of the current turn so far.
    package private(set) var text = ""
    package private(set) var sessionID: String?
    package private(set) var model: String?
    /// Lines that were not JSON objects with a `type` (counted, never kept).
    package private(set) var skippedLines = 0
    /// The event types seen in this turn, for diagnostics (types only, never fields; bounded).
    package private(set) var typeSequence: [String] = []
    private var messageStarts = 0
    package static let maxTypeSequence = 200

    package init() {}

    /// Starts the next turn of the same process (the text and the retry detection restart).
    package mutating func beginTurn() {
        text = ""
        messageStarts = 0
        typeSequence = []
    }

    package mutating func feed(_ line: Data) -> [Output] {
        guard let first = line.first(where: { $0 != 0x20 && $0 != 0x09 }), first == UInt8(ascii: "{"),
              let v = try? JSONDecoder().decode(JSONValue.self, from: line),
              let type = v["type"]?.stringValue else {
            if line.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) { skippedLines += 1 }
            return []
        }
        note(type == "stream_event" ? "stream_event." + (v["event"]?["type"]?.stringValue ?? "?") : type)
        switch type {
        case "_oversize":
            return [.oversize]
        case "system":
            guard v["subtype"]?.stringValue == "init" else { return [] }
            sessionID = v["session_id"]?.stringValue ?? sessionID
            model = v["model"]?.stringValue ?? model
            let tools = (v["tools"]?.arrayValue ?? []).compactMap { $0.stringValue ?? $0["name"]?.stringValue }
            return [.started(sessionID: sessionID, model: model, tools: tools)]
        case "stream_event":
            guard let e = v["event"] else { return [] }
            switch e["type"]?.stringValue {
            case "message_start"?:
                messageStarts += 1
                // Without tools a turn is one message: another start is an API retry restarting the stream.
                if messageStarts > 1, !text.isEmpty {
                    text = ""
                    return [.replace("")]
                }
                return []
            case "content_block_delta"?:
                guard e["delta"]?["type"]?.stringValue == "text_delta",
                      let s = e["delta"]?["text"]?.stringValue, !s.isEmpty else { return [] }
                text += s
                return [.delta(s)]
            default:
                return []
            }
        case "assistant":
            let blocks = v["message"]?["content"]?.arrayValue ?? []
            let full = blocks.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined()
            // A line that only repeats the start of what streamed (or carries no text) changes nothing.
            guard !full.isEmpty, full != text, !text.hasPrefix(full) else { return [] }
            text = full
            return [.replace(full)]
        case "result":
            guard let env = ClaudeEnvelope.from(v) else { return [] }
            sessionID = env.sessionID ?? sessionID
            return [.result(env)]
        default:
            return []
        }
    }

    private mutating func note(_ type: String) {
        guard typeSequence.count < Self.maxTypeSequence else { return }
        // Runs of the same type collapse ("stream_event.content_block_delta ×40" reads as one).
        if typeSequence.last != type { typeSequence.append(type) }
    }
}
