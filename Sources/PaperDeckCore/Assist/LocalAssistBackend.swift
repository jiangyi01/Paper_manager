import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// An on-device language model (`assist.mode = local`): text only, no quota, nothing leaves the
/// Mac — the private choice for possibly unpublished papers (LN §7.4). Offered by the App only when
/// `availability()` says ready (spike S7). Tests use a fake; nothing here is a subscription CLI.
package protocol LocalLanguageModel: Sendable {
    /// Zero-cost check (no generation).
    func availability() async -> AgentQueueStatus.Provider
    /// The answer as cumulative snapshots (each element is the whole text so far).
    func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, any Error>
}

/// Why an on-device turn failed, as stable codes (the model's own error text never reaches the UI).
package enum LocalModelError: Error, Sendable, Equatable {
    case unavailable(String)
    case contextWindow
    case guardrail
    case other(String)
}

package actor LocalAssistBackend: AssistBackend {
    package nonisolated let mode: AssistMode = .local
    private let model: any LocalLanguageModel
    private let now: @Sendable () -> Date

    package init(model: any LocalLanguageModel, now: @escaping @Sendable () -> Date = Date.init) {
        self.model = model; self.now = now
    }

    /// The system model when this SDK has FoundationModels (nil otherwise).
    package static func system() -> LocalAssistBackend? {
        #if canImport(FoundationModels)
        return LocalAssistBackend(model: SystemLocalLanguageModel())
        #else
        return nil
        #endif
    }

    package nonisolated func turn(_ request: AssistRequest, turnIndex: Int) -> AsyncStream<AssistEvent> {
        let model = self.model
        return AsyncStream(bufferingPolicy: .unbounded) { c in
            let task = Task {
                await Self.play(request, turnIndex: turnIndex, model: model, into: c)
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    private static func play(_ r: AssistRequest, turnIndex: Int, model: any LocalLanguageModel,
                             into c: AsyncStream<AssistEvent>.Continuation) async {
        // The on-device model reads text only.
        guard r.image == nil else {
            c.yield(.failed(.unsupported(missingFlags: ["image"]), partial: nil))
            return
        }
        let clock = ContinuousClock()
        let started = clock.now
        var first: ContinuousClock.Instant?
        var text = ""
        c.yield(.waiting(warm: false))
        c.yield(.phase(.waitingForFirstToken))
        do {
            let prompt = AssistFraming.statelessText(turnText: r.turnText, history: r.history)
            for try await snapshot in model.stream(instructions: r.systemPrompt, prompt: prompt) {
                if Task.isCancelled { return }
                guard snapshot != text else { continue }
                if first == nil {
                    first = clock.now
                    c.yield(.phase(.streaming))
                }
                text = snapshot
                c.yield(.replace(snapshot))
            }
        } catch is CancellationError {
            return
        } catch let e as LocalModelError {
            c.yield(.failed(failure(e), partial: text.isEmpty ? nil : text))
            return
        } catch {
            c.yield(.failed(.generic("on_device_error"), partial: text.isEmpty ? nil : text))
            return
        }
        guard !Task.isCancelled else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            c.yield(.failed(.invalidOutput("empty_answer"), partial: nil))
            return
        }
        let ms = { (d: Duration) in Int(d.components.seconds) * 1_000 + Int(d.components.attoseconds / 1_000_000_000_000_000) }
        c.yield(.done(text: text, meta: AssistMeta(provider: AssistMode.local.rawValue, model: "on-device", warm: false,
                                                   turnIndex: turnIndex, ttftMs: first.map { ms(started.duration(to: $0)) },
                                                   totalMs: ms(started.duration(to: clock.now)))))
    }

    private static func failure(_ e: LocalModelError) -> AssistFailure {
        switch e {
        case .unavailable(let code): return .unsupported(missingFlags: [code])
        case .contextWindow: return .invalidOutput("context_window")
        case .guardrail: return .generic("guardrail")
        case .other(let code): return .generic(code)
        }
    }

    package func prewarm() async {}
    package func closeSession(threadKey: String) async {}
    package nonisolated func detect() async -> AgentQueueStatus.Provider { await model.availability() }
}

#if canImport(FoundationModels)
/// `SystemLanguageModel.default` through a fresh `LanguageModelSession` per turn (the conversation
/// is resent in `<history>`, like every stateless turn).
package struct SystemLocalLanguageModel: LocalLanguageModel {
    package init() {}

    package func availability() async -> AgentQueueStatus.Provider {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .ready(plan: nil, version: "on-device")
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unsupported("device_not_eligible")
            case .appleIntelligenceNotEnabled: return .notLoggedIn("apple_intelligence_off")
            case .modelNotReady: return .unsupported("model_not_ready")
            @unknown default: return .unsupported("unavailable")
            }
        }
    }

    package func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { c in
            let task = Task {
                guard case .available = SystemLanguageModel.default.availability else {
                    c.finish(throwing: LocalModelError.unavailable("unavailable"))
                    return
                }
                let session = LanguageModelSession(instructions: instructions)
                do {
                    for try await snapshot in session.streamResponse(to: prompt) {
                        c.yield(snapshot.content)
                    }
                    c.finish()
                } catch let e as LanguageModelSession.GenerationError {
                    switch e {
                    case .exceededContextWindowSize: c.finish(throwing: LocalModelError.contextWindow)
                    case .guardrailViolation: c.finish(throwing: LocalModelError.guardrail)
                    default: c.finish(throwing: LocalModelError.other("generation_error"))
                    }
                } catch {
                    c.finish(throwing: error is CancellationError ? error : LocalModelError.other("on_device_error"))
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
