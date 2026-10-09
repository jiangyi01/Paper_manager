import Foundation

/// The zero-quota assist backend (`assist.mode = mock`; tests, `--render`, the UIs of Slices B and
/// C from day 1). Answers are deterministic functions of the request; a script can queue other
/// behaviours. Never starts a process.
package actor MockAssistBackend: AssistBackend {
    package enum Behavior: Sendable, Equatable {
        /// The surface's canned answer, streamed in a few deltas.
        case answer
        /// Exactly these deltas, then done with their concatenation.
        case chunks([String])
        /// Some deltas, then this failure.
        case fail(AssistFailure, after: [String])
        /// Never finishes until the turn is cancelled (the stream ends with `.failed(.cancelled)`).
        case hang
    }

    package nonisolated let mode: AssistMode = .mock
    private var fallback: Behavior
    private var script: [Behavior] = []
    private nonisolated let delay: Duration
    package private(set) var turns = 0
    package private(set) var lastRequest: AssistRequest?
    package private(set) var prewarms = 0
    package private(set) var closedSessions: [String] = []

    /// `delay`: pause before each delta (tests use zero; renders a little).
    package init(behavior: Behavior = .answer, delay: Duration = .zero) {
        fallback = behavior
        self.delay = delay
    }

    package func setBehavior(_ b: Behavior) { fallback = b }
    package func enqueue(_ b: Behavior...) { script += b }

    package nonisolated func turn(_ request: AssistRequest, turnIndex: Int) -> AsyncStream<AssistEvent> {
        AsyncStream { continuation in
            let task = Task {
                let behavior = await self.begin(request)
                await Self.play(behavior, request: request, turnIndex: turnIndex, delay: self.delay, into: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    package func prewarm() async { prewarms += 1 }
    package func closeSession(threadKey: String) async { closedSessions.append(threadKey) }
    package nonisolated func detect() async -> AgentQueueStatus.Provider { .ready(plan: "mock", version: "mock") }

    private func begin(_ r: AssistRequest) -> Behavior {
        turns += 1
        lastRequest = r
        return script.isEmpty ? fallback : script.removeFirst()
    }

    /// The canned answer of a surface (plain, deterministic; never echoes the request's content).
    package static func cannedAnswer(for r: AssistRequest) -> String {
        switch r.surface {
        case .explain:
            return "Mock explanation. The selected passage states the main claim, defines its terms and says what the figure or equation shows."
        case .qa:
            return "Mock answer. The paper reports this in the Results section [p. 1]."
        case .dupJudge:
            return #"{"verdict":"different_work","confidence":0.5,"reason":"mock judge"}"#
        }
    }

    private static func play(_ behavior: Behavior, request: AssistRequest, turnIndex: Int, delay: Duration,
                             into c: AsyncStream<AssistEvent>.Continuation) async {
        let clock = ContinuousClock()
        let start = clock.now
        c.yield(.waiting(warm: turnIndex > 0))
        c.yield(.phase(.waitingForFirstToken))
        func pause() async -> Bool {
            if delay > .zero { try? await Task.sleep(for: delay) }
            return !Task.isCancelled
        }
        var text = ""
        func stream(_ parts: [String]) async -> Bool {
            for (i, part) in parts.enumerated() {
                guard await pause() else { return false }
                if i == 0 { c.yield(.phase(.streaming)) }
                text += part
                c.yield(.delta(part))
            }
            return true
        }
        let ms = { Int(start.duration(to: clock.now).components.seconds * 1_000) }
        let meta = { AssistMeta(provider: "mock", model: request.model, warm: turnIndex > 0, turnIndex: turnIndex,
                                ttftMs: 0, totalMs: ms(), inputTokens: 0, outputTokens: 0, costUSD: 0) }
        switch behavior {
        case .answer, .chunks:
            let parts: [String]
            if case .chunks(let given) = behavior { parts = given } else { parts = split(cannedAnswer(for: request)) }
            guard await stream(parts) else { c.yield(.failed(.cancelled, partial: text.isEmpty ? nil : text)); return }
            let capped = String(text.prefix(request.limits.maxOutputChars))
            if capped != text { c.yield(.replace(capped)) }
            c.yield(.done(text: capped, meta: meta()))
        case .fail(let failure, let parts):
            guard await stream(parts) else { c.yield(.failed(.cancelled, partial: text.isEmpty ? nil : text)); return }
            c.yield(.failed(failure, partial: text.isEmpty ? nil : text))
        case .hang:
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
            c.yield(.failed(.cancelled, partial: nil))
        }
    }

    /// About three deltas, split at spaces.
    private static func split(_ s: String) -> [String] {
        let words = s.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard words.count > 3 else { return [s] }
        let size = (words.count + 2) / 3
        return stride(from: 0, to: words.count, by: size).map { i in
            let chunk = words[i..<min(i + size, words.count)].joined(separator: " ")
            return i + size < words.count ? chunk + " " : chunk
        }
    }
}
