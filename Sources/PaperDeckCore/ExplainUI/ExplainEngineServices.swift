import Foundation

/// The panels' services over the engine (`ExplainServicing`): the privacy verdict (fail closed), the
/// assist lane (the ticket the click minted goes straight to `AssistLane.submit`, whose gate checks
/// it), the explanation store and its reader anchors. The two parts that need the capture lane's
/// pieces — reading a capture (OCR, the region's kind, the paper, its context) and building the
/// prompt — are injected: the App passes its adapter (`LiveExplainServices`), tests pass fakes.
/// Owned by the Explain UI lane (A2).
@MainActor
package final class ExplainEngineServices: ExplainServicing {
    package typealias Prepare = @MainActor (ExplainCapture, ReaderAnchor?) async -> ExplainPrepared
    package typealias Build = @MainActor (ExplainTurnSpec) -> AssistRequest

    private let engine: Engine
    private let prepareCapture: Prepare
    private let build: Build
    /// After an explanation was stored, pinned or saved to notes (history views reload).
    package var onHistoryChange: (@MainActor () -> Void)?
    /// A panel closed (the adapter drops what it kept for that capture).
    package var onClose: (@MainActor (_ threadKey: String) -> Void)?

    package init(engine: Engine, prepare: @escaping Prepare, build: @escaping Build) {
        self.engine = engine
        self.prepareCapture = prepare
        self.build = build
    }

    package var assistSettings: AssistSettings { engine.ctx.loadSettings().assist }
    package var now: Date { engine.ctx.now() }

    package func prepare(_ capture: ExplainCapture, anchor: ReaderAnchor?) async -> ExplainPrepared {
        await prepareCapture(capture, anchor)
    }

    /// An unmatched capture is judged by its host app alone; a matched paper by its policy and
    /// provenance too. nil (nothing is sent) when the paper's privacy inputs can't be read.
    package func privacy(paperID: String?, hostBundleID: String?) async -> AssistPrivacy.Verdict? {
        guard let paperID else {
            return AssistPrivacy.verdict(policy: nil, aiNote: nil, provenance: [], hostBundleID: hostBundleID)
        }
        return try? await engine.assistPrivacy(paperID: paperID, hostBundleID: hostBundleID)
    }

    package func request(_ spec: ExplainTurnSpec) -> AssistRequest {
        Self.finish(build(spec), spec: spec, settings: assistSettings)
    }

    /// The prompt builder's request with the panel's session (one warm session per panel), the
    /// depth's model and effort, the stateless history (the builder's own when it set one), the image
    /// only when the turn sends it, and the surface's limits for the mode's provider.
    package static func finish(_ base: AssistRequest, spec: ExplainTurnSpec, settings: AssistSettings) -> AssistRequest {
        let (model, effort) = ExplainModelChoice.model(settings, depth: spec.depth)
        return AssistRequest(surface: .explain, systemPrompt: base.systemPrompt, turnText: base.turnText,
                             image: spec.sendImage ? base.image : nil, history: base.history.isEmpty ? spec.history : base.history,
                             model: model, effort: effort,
                             format: .text, session: .reuse(threadKey: spec.threadKey),
                             limits: AssistLimits.defaults(for: .explain, provider: settings.mode.providerKind))
    }

    package func submit(_ request: AssistRequest, ticket: ConsentTicket) async -> AsyncStream<AssistEvent> {
        await engine.assist.submit(request, ticket: ticket)
    }

    package func cancelTurn() async { await engine.assist.cancel(surface: .explain) }

    package func closeSession(threadKey: String) async {
        onClose?(threadKey)
        await engine.assist.closeSession(threadKey: threadKey)
    }

    package func save(_ record: ExplanationRecord, anchor: ReaderAnchor?) async throws -> ExplanationRecord {
        let stored = try await engine.saveExplanation(record)
        if let anchor { await engine.saveExplanationReaderAnchor(anchor, explanationID: stored.id) }
        onHistoryChange?()
        return stored
    }

    package func setPinned(ids: [String], _ pinned: Bool) async {
        for id in ids { try? await engine.setExplanationPinned(id: id, pinned) }
        onHistoryChange?()
    }

    package func appendToNotes(id: String) async throws {
        try await engine.appendExplanationToNotes(id: id)
        onHistoryChange?()
    }
}
