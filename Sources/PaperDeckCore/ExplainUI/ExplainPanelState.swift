import Foundation
import Observation

// One explanation panel's conversation (LN §7, plan §3.2 "one assist turn, end to end"): the capture,
// the local preparation (OCR, the paper, its context), the privacy check, then one AI turn per user
// gesture through the lane, streamed into the panel at ~30 redraws a second, stored when it completes.
// The App's panel view and coordinator drive it; nothing here can start a turn on its own — every
// turn needs the `ConsentTicket` the App minted in that click's action handler, and the lane's gate
// checks it again. Owned by the Explain UI lane (A2).

/// The local result of reading a capture (no AI, no quota).
package struct ExplainPrepared: Sendable, Equatable {
    /// Keys the prompt context the services keep for this capture.
    package var id: UUID
    /// The text explained: exact text (Services, the clipboard, the reader) or the capture's OCR.
    package var selection: String?
    /// The capture's image (sent when the turn wants it: a figure, a formula, an override).
    package var image: AssistImage?
    package var content: Content
    /// The library paper it shows (the reader's exact one, or the locator's match).
    package var match: PaperMatch?
    /// The selection is the exact text (Services, the clipboard, the reader), not OCR of the image.
    package var selectionIsExact: Bool
    /// Who was on screen under what is actually sent (a clicked paragraph: under its crop only);
    /// nil: the capture's own `surroundings` apply. Privacy only, never sent.
    package var surroundings: CaptureSurroundings?
    /// The text the paper locator matched (and the context centred on): a ⇧-clicked term's
    /// paragraph, else the selection; nil when no locator ran on text. A match correction is
    /// remembered under it, so explaining again finds it (`ExplainPanelState.correctionExcerpts`).
    package var locatedText: String?

    /// What the capture holds (the capture lane's region classifier, or plain text).
    package enum Content: String, Sendable, Equatable { case text, mixed, visual }

    package init(id: UUID = UUID(), selection: String?, image: AssistImage?, content: Content, match: PaperMatch?,
                 selectionIsExact: Bool = true, locatedText: String? = nil, surroundings: CaptureSurroundings? = nil) {
        self.id = id; self.selection = selection; self.image = image; self.content = content; self.match = match
        self.selectionIsExact = selectionIsExact; self.surroundings = surroundings; self.locatedText = locatedText
    }

    /// Nothing to explain.
    package var isEmpty: Bool { (selection?.isEmpty ?? true) && image == nil }
}

/// Everything the services need to build one turn's request.
package struct ExplainTurnSpec: Sendable, Equatable {
    package var kind: ExplainTurnKind
    package var language: UILang
    package var depth: AssistSettings.Depth
    package var level: AssistSettings.Level
    /// Send the image with this turn.
    package var sendImage: Bool
    /// The panel's session (`AssistSessionPolicy.reuse`).
    package var threadKey: String
    /// 0 for the first explanation.
    package var turnIndex: Int
    /// The earlier turns (for the stateless fallback; neutralized).
    package var history: [AssistTurnText]
    package var prepared: ExplainPrepared
}

/// One turn as the panel shows it.
package struct ExplainTurn: Sendable, Equatable, Identifiable {
    package let id: UUID
    package var index: Int
    package var kind: ExplainTurnKind
    package var language: UILang
    package var depth: AssistSettings.Depth
    package var sentImage: Bool
    package var text: String
    /// Stopped by the user or replaced by a newer turn (the text so far is kept, not stored).
    package var stopped = false
    /// The answer passed the output cap (its first part is kept, not stored).
    package var cutOff = false
    package var meta: AssistMeta?
    /// The stored `explanation` row (nil until it completed and was saved).
    package var recordID: String?
    package var savedToNotes = false
    package var startedAt: Date
    /// The turn text that went out (the stateless history of later turns; never shown).
    package var sentTurnText: String?

    package init(id: UUID = UUID(), index: Int, kind: ExplainTurnKind, language: UILang, depth: AssistSettings.Depth,
                 sentImage: Bool, text: String = "", startedAt: Date) {
        self.id = id; self.index = index; self.kind = kind; self.language = language; self.depth = depth
        self.sentImage = sentImage; self.text = text; self.startedAt = startedAt
    }

    /// A finished, complete answer.
    package var isComplete: Bool { meta != nil && !stopped && !cutOff }
}

/// What a panel needs from the app (the App's live implementation wraps the engine, the lane and the
/// capture lane's OCR / locator / prompt; tests use fakes around a real lane with the mock backend).
@MainActor
package protocol ExplainServicing: AnyObject {
    /// The assist settings now (re-read for every turn).
    var assistSettings: AssistSettings { get }
    var now: Date { get }
    /// OCR, the region's kind, which paper, its context. Local; never sends anything.
    func prepare(_ capture: ExplainCapture, anchor: ReaderAnchor?) async -> ExplainPrepared
    /// The privacy verdict of the paper (nil: unmatched) and the capture's host app; nil when the
    /// paper's settings couldn't be read (nothing is sent then).
    func privacy(paperID: String?, hostBundleID: String?) async -> AssistPrivacy.Verdict?
    /// The turn's request (the prompt builder's, with the panel's session, model and history).
    func request(_ spec: ExplainTurnSpec) -> AssistRequest
    func submit(_ request: AssistRequest, ticket: ConsentTicket) async -> AsyncStream<AssistEvent>
    /// Stops Explain's running turn.
    func cancelTurn() async
    /// The panel closed: its warm session ends.
    func closeSession(threadKey: String) async
    func save(_ record: ExplanationRecord, anchor: ReaderAnchor?) async throws -> ExplanationRecord
    func setPinned(ids: [String], _ pinned: Bool) async
    func appendToNotes(id: String) async throws
}

@MainActor
@Observable
package final class ExplainPanelState: Identifiable {
    package let id: UUID
    /// The panel's session key (`AssistSessionPolicy.reuse`, `explanation.thread_id`).
    package let threadKey: String
    package let capture: ExplainCapture
    /// The reader's exact place (A4); nil for screen, clipboard, Services and drops.
    package let anchor: ReaderAnchor?
    package private(set) var prepared: ExplainPrepared?
    package private(set) var phase: ExplainPhase = .idle
    package private(set) var turns: [ExplainTurn] = []
    /// The language of the next turn (EN / 中; 中 = Chinese with the English terms).
    package var language: UILang
    /// The depth of the next turn (Quick by default; ⌥ on a button asks Thorough for that turn).
    package var depth: AssistSettings.Depth
    /// Pinned panels stay when the next capture comes (and their explanations are kept in history).
    package private(set) var pinned = false
    /// The follow-up field.
    package var followUp = ""
    /// nil: the capture decides (text → text only; a figure or a formula → the image too).
    package var imageOverride: Bool?
    /// The privacy confirmation covers this panel's capture (asked once, before its first send).
    package private(set) var privacyConfirmed = false
    /// The turn a confirmation, [Continue] or [Retry] sends.
    package private(set) var pending: ExplainTurnKind?
    /// Why a `.refused(.askBeforeSend)` hold waits for [Send] (the card's hint says which).
    package private(set) var heldFor: ExplainHeldFor = .setting
    /// The clock of the panel's own debounce (tests set it).
    @ObservationIgnored package var clock: @MainActor () -> Date = { Date() }

    @ObservationIgnored private let services: any ExplainServicing
    @ObservationIgnored private var buffer = ExplainTextBuffer()
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var askConfirmedOnce = false
    @ObservationIgnored private var runGeneration = 0
    @ObservationIgnored private var debounce = ExplainGestureDebounce()

    package init(capture: ExplainCapture, anchor: ReaderAnchor? = nil, services: any ExplainServicing,
                 language: UILang, depth: AssistSettings.Depth, id: UUID = UUID()) {
        self.id = id
        self.threadKey = "explain-" + id.uuidString.lowercased()
        self.capture = capture
        self.anchor = anchor
        self.services = services
        self.language = language
        self.depth = depth
    }

    // MARK: Derived

    package var current: ExplainTurn? { turns.last }
    package var hasImage: Bool { capture.image != nil || prepared?.image != nil }
    /// What was explained (exact or OCR text).
    package var excerpt: String? { prepared?.selection ?? anchor?.text ?? capture.text }
    /// The texts "Not this paper" / "Change…" remember the correction under (`PaperMatchCorrections`):
    /// the text the locator matched — a ⇧-clicked term's paragraph, which is what the locator looks
    /// the correction up by when the capture is explained again — and the excerpt shown (the term),
    /// when it differs.
    package var correctionExcerpts: [String] {
        var out: [String] = []
        for text in [prepared?.locatedText, excerpt].compactMap({ $0 }) where !text.isEmpty && !out.contains(text) {
            out.append(text)
        }
        return out
    }
    package var paperID: String? { anchor?.paperID ?? prepared?.match?.paperID }
    package var page: Int? { anchor?.page ?? prepared?.match?.page }
    package var isRunning: Bool { phase.isBusy }
    /// "Save to notes": a stored, complete answer of a known paper, not saved yet.
    package var canSaveToNotes: Bool {
        guard paperID != nil, let t = current, t.isComplete, t.recordID != nil else { return false }
        return !t.savedToNotes
    }
    /// The answer for Copy.
    package var answerText: String { current?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    /// The chips this capture offers.
    package var chips: [ExplainChip] { ExplainChip.available(hasImage: hasImage) }

    // MARK: Gestures (each with the ticket its click minted)

    /// Starts a turn of `kind` (the first explanation, a chip, a follow-up) with the click's ticket.
    /// A turn running in this panel is replaced (its text so far is kept, marked stopped). The same
    /// button pressed again within `ExplainDebounce.click` (a double-click, a held ⌘-digit) is
    /// ignored: one press, one turn (F9).
    package func run(_ kind: ExplainTurnKind, ticket: ConsentTicket, depth: AssistSettings.Depth? = nil) {
        guard debounce.allow(.run(kind), at: clock()) else { return }
        askConfirmedOnce = false                            // a new send: "Ask before every send" asks for it
        start(kind, ticket: ticket, depth: depth)
    }

    /// The follow-up field's Return: its text as a question (nothing for an empty field).
    package func askFollowUp(ticket: ConsentTicket, depth: AssistSettings.Depth? = nil) {
        let q = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, debounce.allow(.run(.ask(q)), at: clock()) else { return }
        followUp = ""
        askConfirmedOnce = false
        start(.ask(q), ticket: ticket, depth: depth)
    }

    /// [Send anyway] (privacy), [Send] (ask before every send, a Services request), [Continue]
    /// (soft cap, with a `capOverride` ticket): the turn that was held goes out with this click's ticket.
    /// [Continue] is itself the user's click for that held send, so with "Ask before every send" on
    /// it is not held for [Send] once more (the two holds would otherwise take turns forever: [Send]'s
    /// plain ticket can't pass the soft cap, and [Continue]'s send was held again for [Send]).
    package func confirm(ticket: ConsentTicket) {
        guard case .refused(let r) = phase, r.isConfirmable, let kind = pending,
              debounce.allow(.confirm, at: clock()) else { return }
        switch r {
        case .confirmPrivacy: privacyConfirmed = true
        case .askBeforeSend, .softCap: askConfirmedOnce = true
        default: break
        }
        start(kind, ticket: ticket, depth: nil)
    }

    /// [Retry] / ⌘R: the held turn, else the last one, again (a fresh ticket).
    package func retry(ticket: ConsentTicket, depth: AssistSettings.Depth? = nil) {
        guard let kind = pending ?? current?.kind, debounce.allow(.retry, at: clock()) else { return }
        askConfirmedOnce = false
        start(kind, ticket: ticket, depth: depth)
    }

    /// Services ▸ "Explain with PaperDeck" / Translate (F10): the panel shows the selection held
    /// with [Send] — nothing is sent and no ticket exists until that click or ⏎ in the panel (a
    /// fresh gesture in PaperDeck; another app can't send by calling the service).
    package func holdForSend(_ kind: ExplainTurnKind) {
        guard !phase.isBusy, turns.isEmpty else { return }
        heldFor = .service
        hold(kind, .refused(.askBeforeSend))
    }

    private func start(_ kind: ExplainTurnKind, ticket: ConsentTicket, depth: AssistSettings.Depth?) {
        heldFor = .setting                                  // a turn's own holds name the setting
        turnTask?.cancel()
        supersedeRunningTurn()
        runGeneration += 1
        let generation = runGeneration
        turnTask = Task { [weak self] in await self?.perform(kind, ticket: ticket, depth: depth, generation: generation) }
    }

    /// Returns once the turn the last gesture started has finished (renders and tests; the views never wait).
    package func settled() async {
        await turnTask?.value
    }

    /// Stop (⌘. / Esc while streaming): the lane stops the turn; its text so far stays, marked stopped.
    package func stop() async {
        guard phase.isBusy else { return }
        if case .locating = phase {
            turnTask?.cancel()
            phase = turns.isEmpty ? .idle : .done
            return
        }
        await services.cancelTurn()
    }

    /// The panel closed: its own turn stops and its session ends. Only this panel's turn: ending the
    /// session stops the lane's turn when it is this panel's (`AssistLane.closeSession(threadKey:)`),
    /// and a turn still on its way there ends with the dropped stream. Never Explain's running turn
    /// as such — a panel still reading its capture (`.locating`) has none in the lane, and that turn
    /// may be a pinned panel's answer.
    package func close() async {
        turnTask?.cancel()
        flushTask?.cancel()
        await services.closeSession(threadKey: threadKey)
    }

    package func setPinned(_ on: Bool) async {
        guard on != pinned else { return }
        pinned = on
        let ids = turns.compactMap(\.recordID)
        if !ids.isEmpty { await services.setPinned(ids: ids, on) }
    }

    /// Appends the current answer to its paper's notes. Throws what the engine threw.
    package func saveToNotes() async throws {
        guard canSaveToNotes, let i = turns.indices.last, let id = turns[i].recordID else { return }
        try await services.appendToNotes(id: id)
        if turns.indices.contains(i), turns[i].recordID == id { turns[i].savedToNotes = true }
    }

    // MARK: The turn

    /// One turn, end to end (awaitable: tests call it directly; the views go through `run`).
    package func perform(_ kind: ExplainTurnKind, ticket: ConsentTicket, depth override: AssistSettings.Depth? = nil,
                         generation: Int? = nil) async {
        let mine: Int
        if let generation {
            mine = generation
        } else {
            runGeneration += 1
            mine = runGeneration
        }
        func live() -> Bool { !Task.isCancelled && mine == runGeneration }
        pending = nil
        if let q = kind.question, q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        if prepared == nil {
            phase = .locating
            let p = await services.prepare(capture, anchor: anchor)
            guard live() else { return }
            prepared = p
        }
        guard let prepared, !prepared.isEmpty else { phase = .refused(.emptyCapture); return }
        // Privacy, re-read for every turn (a policy toggle may have changed); fail closed. The
        // located paper's verdict, every paper PaperDeck's own windows show in the capture (F2), and
        // a mail / chat window anywhere under what is sent (F1: native, webmail, the copied-from app).
        let surroundings = prepared.surroundings ?? capture.surroundings
        var verdicts: [AssistPrivacy.Verdict?] = [await services.privacy(paperID: paperID, hostBundleID: capture.hostBundleID)]
        for shown in ExplainPrivacyRules.shownPapers(surroundings, besides: paperID) {
            guard live() else { return }
            verdicts.append(await services.privacy(paperID: shown, hostBundleID: nil))
        }
        guard live() else { return }
        guard let verdict = ExplainPrivacyRules.combine(verdicts, messaging: ExplainPrivacyRules.showsMessaging(capture, surroundings: surroundings)) else {
            hold(kind, .refused(.privacyUnchecked))
            return
        }
        if let refusal = ExplainFlow.phase(privacy: verdict, confirmed: privacyConfirmed) {
            hold(kind, refusal)
            return
        }
        let settings = services.assistSettings
        guard settings.mode != .off else { hold(kind, .refused(.off)); return }
        if settings.explainAskBeforeSend, !askConfirmedOnce {
            hold(kind, .refused(.askBeforeSend))
            return
        }
        askConfirmedOnce = false
        let turnDepth = override ?? depth
        let sendImage = Self.sendsImage(kind, prepared: prepared, override: imageOverride)
        let spec = ExplainTurnSpec(kind: kind, language: language, depth: turnDepth, level: settings.explainLevel,
                                   sendImage: sendImage, threadKey: threadKey, turnIndex: turns.count,
                                   history: Self.history(turns), prepared: prepared)
        let request = services.request(spec)
        // A newer gesture took over while this one was preparing: it must not reach the lane (the
        // lane's latest-wins would stop the newer turn).
        guard live() else { return }
        var turn = ExplainTurn(index: turns.count, kind: kind, language: language, depth: turnDepth,
                               sentImage: sendImage && request.image != nil, startedAt: services.now)
        turn.sentTurnText = request.turnText
        turns.append(turn)
        let turnID = turn.id
        buffer.reset()
        phase = .sending(.starting)
        let stream = await services.submit(request, ticket: ticket)
        for await event in stream {
            guard live() else { return }
            await handle(event, turnID: turnID, kind: kind)
            if event.isTerminal { break }
        }
    }

    private func handle(_ event: AssistEvent, turnID: UUID, kind: ExplainTurnKind) async {
        guard let i = turns.firstIndex(where: { $0.id == turnID }) else { return }
        switch event {
        case .waiting, .phase:
            phase = ExplainFlow.phase(for: event, current: phase)
        case .delta(let s):
            if buffer.append(s) { scheduleFlush(turnID) }
            phase = .streaming
        case .replace(let s):
            buffer.replace(s)
            turns[i].text = buffer.shown
            phase = .streaming
        case .done(let text, let meta):
            flushTask?.cancel()
            buffer.finish(text)
            turns[i].text = buffer.shown
            turns[i].meta = meta
            phase = .done
            await store(turnIndex: i, kind: kind)
        case .failed(let failure, let partial):
            flushTask?.cancel()
            buffer.finish(partial)
            turns[i].text = buffer.shown
            let next = ExplainFlow.phase(after: failure)
            if next == nil { turns[i].stopped = true }
            if case .error(.outputCap)? = next { turns[i].cutOff = true }
            if turns[i].text.isEmpty && next != nil {
                turns.remove(at: i)                     // it never answered: the notice says why
            }
            if let next {
                phase = next
                if next != .error(.outputCap) { pending = kind }
            } else {
                phase = turns.isEmpty ? .idle : .done
            }
        }
    }

    /// Saves a completed turn (pinned while the panel is) and its reader anchor.
    private func store(turnIndex i: Int, kind: ExplainTurnKind) async {
        guard turns.indices.contains(i), let meta = turns[i].meta else { return }
        let t = turns[i]
        let record = ExplanationRecord(paperID: paperID, threadID: threadKey, turn: t.index, source: capture.source,
                                       action: kind.actionCode, lang: t.language, page: page, excerpt: excerpt,
                                       question: kind.question, answer: t.text, hadImage: t.sentImage, meta: meta,
                                       pinned: pinned, createdAt: services.now,
                                       matchVia: anchor != nil ? .reader : prepared?.match?.via,
                                       matchScore: anchor != nil ? 1 : prepared?.match?.score)
        guard let stored = try? await services.save(record, anchor: anchor) else { return }
        if let j = turns.firstIndex(where: { $0.id == t.id }) { turns[j].recordID = stored.id }
    }

    private func hold(_ kind: ExplainTurnKind, _ refusal: ExplainPhase) {
        pending = kind
        phase = refusal
    }

    /// A newer turn replaces a running one: its text so far is kept, marked stopped.
    private func supersedeRunningTurn() {
        guard phase.isBusy, let i = turns.indices.last, turns[i].meta == nil, !turns[i].stopped else { return }
        flushTask?.cancel()
        buffer.finish(nil)
        turns[i].text = buffer.shown
        turns[i].stopped = true
        if turns[i].text.isEmpty { turns.remove(at: i) }
    }

    private func scheduleFlush(_ turnID: UUID) {
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: ExplainTextBuffer.flushInterval)
            guard !Task.isCancelled, let self else { return }
            self.flush(turnID)
        }
    }

    /// Draws what arrived since the last flush (one redraw).
    package func flush(_ turnID: UUID? = nil) {
        guard buffer.flush(), let i = turnID.flatMap({ id in turns.firstIndex { $0.id == id } }) ?? turns.indices.last else { return }
        turns[i].text = buffer.shown
    }

    // MARK: Rules

    /// Whether a turn sends the image: the user's override, else a figure chip, else what the
    /// capture holds (a visual or mixed region, or no text at all).
    package static func sendsImage(_ kind: ExplainTurnKind, prepared: ExplainPrepared, override: Bool?) -> Bool {
        guard prepared.image != nil else { return false }
        if let override { return override }
        if kind == .figure { return true }
        if prepared.selection?.isEmpty ?? true { return true }
        return prepared.content != .text
    }

    /// The earlier complete turns as the stateless fallback's history (newest 6), neutralized.
    package static func history(_ turns: [ExplainTurn], keep: Int = 6) -> [AssistTurnText] {
        turns.filter { $0.isComplete || ($0.stopped && !$0.text.isEmpty) }.suffix(keep).flatMap { t -> [AssistTurnText] in
            [AssistTurnText(role: .user, text: BlockTags.neutralize(t.sentTurnText ?? t.kind.actionCode)),
             AssistTurnText(role: .assistant, text: BlockTags.neutralize(t.text))]
        }
    }

    // MARK: Renders

    /// `--explain-render` only: draws the panel in a given state (no services are called).
    package func applyRenderFixture(phase: ExplainPhase, turns: [ExplainTurn], prepared: ExplainPrepared?,
                                    pinned: Bool = false, pending: ExplainTurnKind? = nil) {
        self.phase = phase
        self.turns = turns
        self.prepared = prepared
        self.pinned = pinned
        self.pending = pending
    }
}
