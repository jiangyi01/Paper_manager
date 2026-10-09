import Foundation

// The shared interactive-AI contracts (READING_ASSIST_PLAN §4), frozen in Slice 0. Explain (A),
// the duplicate judge (B) and Q&A (C) all build an `AssistRequest`, pass `AssistPrivacy`, and run it
// through `AssistLane` behind `AssistGate`. Lead-owned: changes go through a change request.

/// The opt-in switch for interactive AI (`assist.mode`), independent of `agent.mode` (card reading).
/// `off` by default: nothing interactive reaches a CLI until the user turns it on. `local` is the
/// on-device model (offered only if spike S7 passes); `mock` is the zero-quota stand-in.
package enum AssistMode: String, Sendable, Codable, CaseIterable {
    case off, claude, codex, local, mock

    /// The subscription CLI this mode runs; nil for off / local / mock.
    package var providerKind: AIProviderKind? {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .off, .local, .mock: return nil
        }
    }

    /// Spends subscription quota (a real CLI turn).
    package var usesQuota: Bool { providerKind != nil }
}

extension AIProviderKind {
    /// The `assist.mode` that runs this provider.
    package var assistMode: AssistMode { self == .codex ? .codex : .claude }
}

/// Which feature a turn belongs to (limits, models, history tables).
package enum AssistSurface: String, Sendable, Codable, CaseIterable {
    case explain, qa, dupJudge
}

/// One user gesture's permission for exactly one AI turn (§2: minted only in App action handlers,
/// single use, valid `validity` seconds, consumed by `AssistGate.checkTurn` when the turn is
/// allowed). It can't be built any other way: the initializer is private.
package struct ConsentTicket: Sendable, Hashable {
    package enum Gesture: String, Sendable, CaseIterable {
        case box, lens, clipboard, service, drop, reader, ask, followUp, action, retry, judge, capOverride
    }

    package let id: UUID
    package let gesture: Gesture
    package let surface: AssistSurface
    package let issuedAt: Date

    /// Seconds a ticket stays valid after the gesture.
    package static let validity: TimeInterval = 60

    private init(id: UUID, gesture: Gesture, surface: AssistSurface, issuedAt: Date) {
        self.id = id; self.gesture = gesture; self.surface = surface; self.issuedAt = issuedAt
    }

    /// Call only from a UI action handler, at the moment of the user's gesture (contract test
    /// `AssistContractGrepTests` keeps the call sites in an allowlist).
    package static func mint(_ g: Gesture, surface: AssistSurface, now: Date = .now) -> ConsentTicket {
        ConsentTicket(id: UUID(), gesture: g, surface: surface, issuedAt: now)
    }

    /// Expired at `now`, or issued in the future (a clock moved backwards: refuse rather than trust it).
    package func isExpired(at now: Date) -> Bool {
        let age = now.timeIntervalSince(issuedAt)
        return age > Self.validity || age < -1
    }
}

/// A hotkey press: allows pre-spawning a warm process (`AssistGate.checkSpawn`), never a turn.
package struct ArmingToken: Sendable, Equatable {
    package let issuedAt: Date
    /// Seconds an arming token allows a pre-spawn.
    package static let validity: TimeInterval = 30

    private init(issuedAt: Date) { self.issuedAt = issuedAt }

    /// The hotkey handler's token.
    package static func arm(now: Date = .now) -> ArmingToken { ArmingToken(issuedAt: now) }

    package func isExpired(at now: Date) -> Bool {
        let age = now.timeIntervalSince(issuedAt)
        return age > Self.validity || age < -1
    }
}

/// One image for a turn: PNG or JPEG, long edge ≤ `maxLongEdge` px.
package struct AssistImage: Sendable, Equatable {
    package let data: Data
    package let mediaType: String
    package let pixelSize: CGSize

    package static let maxLongEdge: CGFloat = 1568
    package static let mediaTypes: Set<String> = ["image/png", "image/jpeg"]

    package init(data: Data, mediaType: String, pixelSize: CGSize) {
        self.data = data; self.mediaType = mediaType; self.pixelSize = pixelSize
    }

    /// A supported type within the size limit.
    package var isAcceptable: Bool {
        Self.mediaTypes.contains(mediaType) && max(pixelSize.width, pixelSize.height) <= Self.maxLongEdge
            && pixelSize.width > 0 && pixelSize.height > 0 && !data.isEmpty
    }
}

/// What the answer is: free text, or one JSON object inside the text (the judge; parsed tolerantly).
package enum AssistResponseFormat: String, Sendable, Equatable {
    case text, jsonInText
}

/// One-shot turn, or a session reused per panel / thread (`threadKey`).
package enum AssistSessionPolicy: Sendable, Equatable, Hashable {
    case oneShot
    case reuse(threadKey: String)

    package var threadKey: String? {
        if case .reuse(let key) = self { return key }
        return nil
    }
}

/// Per-turn watchdogs and the output cap (plan §4, "Turn parameters").
package struct AssistLimits: Sendable, Equatable {
    /// No first token by then → "still waiting" (the turn keeps running until `turnTimeout`).
    package var firstTokenWatchdog: Duration
    package var turnTimeout: Duration
    package var maxOutputChars: Int

    package init(firstTokenWatchdog: Duration, turnTimeout: Duration, maxOutputChars: Int) {
        self.firstTokenWatchdog = firstTokenWatchdog; self.turnTimeout = turnTimeout; self.maxOutputChars = maxOutputChars
    }

    /// The frozen defaults per surface and provider (Codex answers more slowly). The judge has no
    /// separate first-token watchdog: it is the turn timeout.
    package static func defaults(for surface: AssistSurface, provider: AIProviderKind?) -> AssistLimits {
        let codex = provider == .codex
        switch surface {
        case .explain:
            return AssistLimits(firstTokenWatchdog: .seconds(20), turnTimeout: .seconds(codex ? 150 : 90), maxOutputChars: 6_000)
        case .qa:
            return AssistLimits(firstTokenWatchdog: .seconds(30), turnTimeout: .seconds(codex ? 300 : 180), maxOutputChars: 20_000)
        case .dupJudge:
            let t: Duration = .seconds(codex ? 240 : 90)
            return AssistLimits(firstTokenWatchdog: t, turnTimeout: t, maxOutputChars: 4_000)
        }
    }
}

/// One earlier turn, resent only by the stateless fallback (neutralized like the turn text).
package struct AssistTurnText: Sendable, Equatable, Codable {
    package enum Role: String, Sendable, Codable { case user, assistant }
    package var role: Role
    package var text: String

    package init(role: Role, text: String) { self.role = role; self.text = text }
}

/// Everything one turn sends. Content travels on stdin only, never in argv.
package struct AssistRequest: Sendable, Equatable {
    package let surface: AssistSurface
    /// Static per surface, so the provider can cache it.
    package let systemPrompt: String
    /// The turn's blocks, already neutralized (`BlockTags.neutralize`).
    package let turnText: String
    package let image: AssistImage?
    /// Used only by the stateless fallback (a live session already has it).
    package let history: [AssistTurnText]
    package let model: String
    package let effort: String?
    package let format: AssistResponseFormat
    package let session: AssistSessionPolicy
    package let limits: AssistLimits

    package init(surface: AssistSurface, systemPrompt: String, turnText: String, image: AssistImage? = nil,
                 history: [AssistTurnText] = [], model: String, effort: String? = nil,
                 format: AssistResponseFormat = .text, session: AssistSessionPolicy = .oneShot, limits: AssistLimits) {
        self.surface = surface; self.systemPrompt = systemPrompt; self.turnText = turnText; self.image = image
        self.history = history; self.model = model; self.effort = effort; self.format = format
        self.session = session; self.limits = limits
    }
}

/// What a finished turn cost and how it ran (persisted with explanations and Q&A messages).
package struct AssistMeta: Sendable, Codable, Equatable {
    package var provider: String
    package var model: String
    package var warm: Bool
    package var turnIndex: Int
    package var ttftMs: Int?
    package var totalMs: Int
    package var inputTokens: Int?
    package var outputTokens: Int?
    package var costUSD: Double?

    package init(provider: String, model: String, warm: Bool = false, turnIndex: Int = 0, ttftMs: Int? = nil,
                 totalMs: Int = 0, inputTokens: Int? = nil, outputTokens: Int? = nil, costUSD: Double? = nil) {
        self.provider = provider; self.model = model; self.warm = warm; self.turnIndex = turnIndex
        self.ttftMs = ttftMs; self.totalMs = totalMs; self.inputTokens = inputTokens
        self.outputTokens = outputTokens; self.costUSD = costUSD
    }
}

/// Progress of a turn before / while text arrives (the UI words it).
package enum AssistPhase: String, Sendable, Equatable {
    /// Starting the CLI (cold).
    case starting
    /// The turn was written; waiting for the first token.
    case waitingForFirstToken
    /// The first-token watchdog fired: still waiting.
    case stillWaiting
    /// Text is arriving.
    case streaming
}

/// Why a turn produced no (complete) answer. Codes only; the App words them.
package enum AssistFailure: Sendable, Equatable {
    case refused(AssistGate.Verdict)
    case usageLimit(resetsAt: Date?)
    case notLoggedIn(ProviderReason)
    case overloaded
    case timeout
    case cancelled
    case binaryMissing
    case unsupported(missingFlags: [String])
    case invalidOutput(String)
    case generic(String)
}

/// The stream of one turn. Exactly one terminal event (`done` or `failed`) ends it. `delta`
/// appends; `replace` is authoritative (the whole text so far).
package enum AssistEvent: Sendable, Equatable {
    case waiting(warm: Bool)
    case phase(AssistPhase)
    case delta(String)
    case replace(String)
    case done(text: String, meta: AssistMeta)
    case failed(AssistFailure, partial: String?)

    package var isTerminal: Bool {
        switch self {
        case .done, .failed: return true
        default: return false
        }
    }
}

/// The lane's state for the banners and footers: provider detected / logged in, pause, today's count.
package struct AssistStatus: Sendable, Equatable {
    package var mode: AssistMode
    /// Detection of `mode`'s backend (`.disabled` while off).
    package var provider: AgentQueueStatus.Provider
    package var pausedUntil: Date?
    /// Turns counted today for `mode`'s provider (0 for local / mock).
    package var todayCount: Int
    package var softCap: Int
    package var hardCap: Int
    /// A turn is generating right now.
    package var busy: Bool

    package init(mode: AssistMode = .off, provider: AgentQueueStatus.Provider = .disabled, pausedUntil: Date? = nil,
                 todayCount: Int = 0, softCap: Int = AssistSettings.defaultSoftCap,
                 hardCap: Int = AssistSettings.defaultHardCap, busy: Bool = false) {
        self.mode = mode; self.provider = provider; self.pausedUntil = pausedUntil; self.todayCount = todayCount
        self.softCap = softCap; self.hardCap = hardCap; self.busy = busy
    }
}

/// One way of answering a turn: the Claude live session, a Codex one-shot, the on-device model or
/// the mock. `AssistLane` asks `AssistGate` before every turn and every pre-spawn; a backend never
/// decides that on its own.
package protocol AssistBackend: Sendable {
    /// The `assist.mode` this backend serves.
    var mode: AssistMode { get }
    /// Runs one turn. The stream ends after exactly one terminal event; cancelling the consuming
    /// task (or dropping the stream) stops the turn.
    func turn(_ request: AssistRequest, turnIndex: Int) -> AsyncStream<AssistEvent>
    /// Starts a warm process ahead of a turn (only after `AssistGate.checkSpawn`). May do nothing.
    func prewarm() async
    /// Ends the session of `threadKey` (a panel or thread closed).
    func closeSession(threadKey: String) async
    /// Zero-quota detection (installed, logged in).
    func detect() async -> AgentQueueStatus.Provider
}
