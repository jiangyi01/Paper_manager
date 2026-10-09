import Foundation

/// The streaming answer as the panel shows it, redrawn about 30 times a second (plan §3.2: "UI
/// coalesces `.delta` to ~30 Hz; `.replace` is authoritative"). Deltas collect in `pending`; the
/// owner schedules one flush per `flushInterval` (only when `append` says so) and calls `flush`,
/// which moves everything pending into `shown` in one change. `replace` and `finish` are applied at
/// once. Pure value; owned by the Explain UI lane (A2).
package struct ExplainTextBuffer: Sendable, Equatable {
    /// At most one redraw per interval while streaming (≈ 30 Hz).
    package static let flushInterval: Duration = .milliseconds(33)

    /// The text on screen.
    package private(set) var shown = ""
    /// Arrived, not drawn yet.
    package private(set) var pending = ""
    /// A flush is scheduled (the owner's timer is running).
    package private(set) var flushScheduled = false

    package init() {}

    /// The text so far, drawn or not.
    package var full: String { shown + pending }

    /// Adds a delta. True when the owner should schedule a flush (none is scheduled yet).
    package mutating func append(_ delta: String) -> Bool {
        guard !delta.isEmpty else { return false }
        pending += delta
        guard !flushScheduled else { return false }
        flushScheduled = true
        return true
    }

    /// Draws everything pending. True when `shown` changed.
    @discardableResult
    package mutating func flush() -> Bool {
        flushScheduled = false
        guard !pending.isEmpty else { return false }
        shown += pending
        pending = ""
        return true
    }

    /// The backend's whole text so far (authoritative; pending deltas are dropped).
    package mutating func replace(_ text: String) {
        shown = text
        pending = ""
    }

    /// The turn ended: the final text when there is one, else what arrived (a stop keeps its partial).
    package mutating func finish(_ final: String?) {
        if let final { shown = final } else { shown += pending }
        pending = ""
        flushScheduled = false
    }

    package mutating func reset() { self = ExplainTextBuffer() }
}
