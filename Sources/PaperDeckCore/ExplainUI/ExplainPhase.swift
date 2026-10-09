import Foundation

// What the Explain panel shows (READING_ASSIST_PLAN §7 `ExplainCoordinator.phase`, LN §7.5) and how a
// turn's events and failures move it. Pure; the App's panel and overlay word every case. Owned by the
// Explain UI lane (A2).

/// One panel's phase.
package enum ExplainPhase: Sendable, Equatable {
    /// Nothing asked yet (a panel opened by "Ask PaperDeck…" waiting for a question).
    case idle
    /// The overlay is up (hotkey, menu): frame or lens, with the clipboard offer if there is one.
    case armed(AssistSettings.OverlayMode)
    /// Freezing / cropping the screen (frame and lens, A3).
    case capturing
    /// Screen Recording is off: the explainer card (copy-then-hotkey, Services and drops still work).
    case permissionNeeded
    /// Local work before any AI: OCR, which library paper, its context. Zero quota.
    case locating
    /// The turn was handed to the lane: the CLI starting, or the first token awaited.
    case sending(ExplainWait)
    case streaming
    case done
    /// The turn failed after it was allowed: [Retry] (a fresh click, a fresh ticket).
    case error(ExplainProblem)
    /// A usage limit (the turn's, or the provider's shared pause).
    case limited(until: Date?)
    /// The CLI isn't logged in (or not with the subscription).
    case needsLogin(ProviderReason)
    /// Nothing was sent (the switch, the paper's policy, a confirmation, a cap, the ticket).
    case refused(ExplainRefusal)

    /// Local work or a turn is running (Esc stops it; a new capture replaces it).
    package var isBusy: Bool {
        switch self {
        case .capturing, .locating, .sending, .streaming: return true
        default: return false
        }
    }

    /// A failure state that offers [Retry].
    package var canRetry: Bool {
        switch self {
        case .error(let p): return p.canRetry
        case .limited, .needsLogin: return true
        case .refused(let r): return r == .expired || r == .burst || r == .privacyUnchecked
        default: return false
        }
    }
}

/// Before the first token.
package enum ExplainWait: String, Sendable, Equatable {
    /// The CLI is starting (cold).
    case starting
    /// The turn was written; waiting for the first token.
    case waiting
    /// The first-token watchdog fired: still waiting (the turn keeps running until its timeout).
    case stillWaiting
}

/// Why an allowed turn produced no complete answer.
package enum ExplainProblem: String, Sendable, Equatable {
    case timeout, overloaded, invalidOutput, notInstalled, unsupported, failed
    /// The answer passed the output cap (the kept text is shown, marked cut off).
    case outputCap

    package var canRetry: Bool {
        switch self {
        case .timeout, .overloaded, .failed, .invalidOutput, .notInstalled: return true
        case .unsupported, .outputCap: return false
        }
    }
}

/// Why nothing was sent.
package enum ExplainRefusal: Sendable, Equatable {
    /// `assist.mode` is off (or names another backend): the enable card.
    case off
    /// The paper is marked "never use AI".
    case blocked
    /// Possibly unpublished / confidential / person-sourced / a mail or chat window: [Send anyway].
    case confirmPrivacy([AssistPrivacy.Reason])
    /// Settings ▸ Explain ▸ "Ask before every send": [Send].
    case askBeforeSend
    /// Today's soft cap: [Continue] (a fresh `capOverride` ticket).
    case softCap(Int)
    case hardCap(Int)
    /// More than 6 turns in a minute.
    case burst
    /// The engine's run budget is spent.
    case budget
    /// The click's ticket was missing, reused or too old (press again).
    case expired
    /// Nothing to explain: no text, and OCR found none in a capture without an image.
    case emptyCapture
    /// The paper's privacy settings couldn't be read: nothing was sent (fail closed).
    case privacyUnchecked

    /// [Send anyway] / [Send] / [Continue] — the same turn goes out with a fresh click's ticket.
    package var isConfirmable: Bool {
        switch self {
        case .confirmPrivacy, .askBeforeSend, .softCap: return true
        default: return false
        }
    }
}

/// The phase rules (pure).
package enum ExplainFlow {
    /// The phase after the lane's `failed` event; nil for a stop (the turn shows "Stopped").
    package static func phase(after failure: AssistFailure) -> ExplainPhase? {
        switch failure {
        case .cancelled: return nil
        case .refused(let verdict): return phase(refusedBy: verdict)
        case .usageLimit(let resetsAt): return .limited(until: resetsAt)
        case .notLoggedIn(let reason): return .needsLogin(reason)
        case .overloaded: return .error(.overloaded)
        case .timeout: return .error(.timeout)
        case .binaryMissing: return .error(.notInstalled)
        case .unsupported: return .error(.unsupported)
        case .invalidOutput(let kind): return .error(kind == "output_cap" ? .outputCap : .invalidOutput)
        case .generic: return .error(.failed)
        }
    }

    /// The phase of a gate refusal.
    package static func phase(refusedBy verdict: AssistGate.Verdict) -> ExplainPhase {
        switch verdict {
        case .allowed: return .error(.failed)          // never a failure; defensive
        case .disabled, .wrongProvider: return .refused(.off)
        case .consentMissing, .consentReused, .consentExpired: return .refused(.expired)
        case .paused(let until): return .limited(until: until)
        case .burst: return .refused(.burst)
        case .dailySoftCap(let n): return .refused(.softCap(n))
        case .dailyHardCap(let n): return .refused(.hardCap(n))
        case .budgetExhausted: return .refused(.budget)
        case .policyBlocked: return .refused(.blocked)
        }
    }

    /// The phase while a turn's non-terminal events arrive (`current` is kept for anything else).
    package static func phase(for event: AssistEvent, current: ExplainPhase) -> ExplainPhase {
        switch event {
        case .waiting:
            return current == .streaming ? current : .sending(.starting)
        case .phase(let p):
            switch p {
            case .starting: return .sending(.starting)
            case .waitingForFirstToken: return .sending(.waiting)
            case .stillWaiting: return current == .streaming ? .streaming : .sending(.stillWaiting)
            case .streaming: return .streaming
            }
        case .delta, .replace: return .streaming
        case .done: return .done
        case .failed(let f, _): return phase(after: f) ?? .done
        }
    }

    /// The privacy verdict before any turn: blocked → refused, confirm → ask once per panel.
    package static func phase(privacy: AssistPrivacy.Verdict, confirmed: Bool) -> ExplainPhase? {
        switch privacy {
        case .ok: return nil
        case .blocked: return .refused(.blocked)
        case .confirm(let reasons): return confirmed ? nil : .refused(.confirmPrivacy(reasons))
        }
    }
}
