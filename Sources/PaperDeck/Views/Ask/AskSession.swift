import Foundation
import Observation
import PaperDeckCore

/// What a click in the Ask views asks for (Core's `QAIntent`: its gestures and what each click
/// sends are pure and tested there). Every intent that sends a question is performed with a
/// `ConsentTicket` the view minted in that click's action handler (`AskTab` / `AskWindowView`) —
/// nothing here, nor anything in `AskSession`, can start a turn on its own.
typealias AskIntent = QAIntent

/// Why the last question got no (full) answer, as the Ask views word it (`AskNotice.from`).
enum AskNotice: Equatable {
    /// `assist.mode` is off (or names another provider): the enable card.
    case off
    case notLoggedIn(ProviderReason)
    /// A usage limit (the turn's, or the provider's pause): resets then.
    case limited(until: Date?)
    case softCap(Int)
    case hardCap(Int)
    case burst
    case budget
    /// The paper is set to never use AI.
    case blocked
    /// A paper's privacy settings couldn't be read: nothing was sent (fail closed).
    case privacyUnchecked
    case notInstalled
    case unsupported
    /// The ticket was missing, reused or too old (press again).
    case expired
    case timeout
    case overloaded
    case failed
    /// Unpublished / confidential / person-sourced papers: confirm, then the same question goes out.
    case confirm(reasons: [AssistPrivacy.Reason], question: String, options: QAOptions)

    /// nil for a stop (the stored answer shows "Stopped").
    static func from(_ f: AssistFailure) -> AskNotice? {
        switch f {
        case .cancelled: return nil
        case .refused(let v):
            switch v {
            case .allowed: return .failed
            case .disabled, .wrongProvider: return .off
            case .consentMissing, .consentReused, .consentExpired: return .expired
            case .paused(let until): return .limited(until: until)
            case .burst: return .burst
            case .dailySoftCap(let n): return .softCap(n)
            case .dailyHardCap(let n): return .hardCap(n)
            case .budgetExhausted: return .budget
            case .policyBlocked: return .blocked
            }
        case .usageLimit(let resetsAt): return .limited(until: resetsAt)
        case .notLoggedIn(let reason): return .notLoggedIn(reason)
        case .overloaded: return .overloaded
        case .timeout: return .timeout
        case .binaryMissing: return .notInstalled
        case .unsupported: return .unsupported
        case .invalidOutput(QAService.outputCapKind): return nil          // the kept answer says it was cut off
        case .generic(QAService.privacyUncheckedCode): return .privacyUnchecked
        case .invalidOutput, .generic: return .failed
        }
    }

    /// The notice offers [Try Again] (a fresh click, a fresh ticket).
    var canRetry: Bool {
        switch self {
        case .notLoggedIn, .limited, .burst, .expired, .timeout, .overloaded, .failed, .notInstalled, .privacyUnchecked: return true
        case .off, .softCap, .hardCap, .budget, .blocked, .unsupported, .confirm: return false
        }
    }
}

/// One Ask conversation surface — the Ask tab of a paper, or the Ask window of a set of papers:
/// its threads, the current thread's messages, the answer streaming in, the toggles, the estimate
/// line and the last notice. Talks to `Engine.qaService()`; renders and self-tests build it with
/// fixture values and never call `perform`.
///
/// Streaming text is coalesced: deltas collect in a buffer that is flushed into `streaming` at most
/// every 33 ms (≈ 30 redraws a second), and the Markdown blocks are parsed in that flush, not in `body`.
@Observable
final class AskSession {
    enum Phase: Equatable { case preparing, starting, waiting, stillWaiting, streaming }

    struct Streaming: Equatable {
        var threadID: String?
        var question: String
        var text: String = ""
        var blocks: [QAAnswerFormat.Block] = []
        var phase: Phase = .preparing
        var startedAt: Date
    }

    /// Redraws while streaming: at most one per this interval.
    static let flushInterval: Duration = .milliseconds(33)

    /// `AskSessions.key(paperIDs)`: follows the papers (a paper removed re-files the session).
    private(set) var key: String
    private(set) var paperIDs: [String]
    var thread: QAThread?
    /// Stored threads over exactly these papers, most recent first.
    var threads: [QAThread] = []
    var messages: [QAMessage] = []
    var streaming: Streaming?
    var notice: AskNotice?
    var draft = ""
    var depth: AssistSettings.Depth
    var language: AssistSettings.AnswerLanguage
    var mode: QAContextMode
    var estimate: QAEstimate?
    var privacy: AssistPrivacy.Verdict = .ok
    /// A paper's verdict couldn't be read: `privacy` is `.blocked` until a reload reads it (fail closed).
    var privacyUnchecked = false
    /// Each paper's own verdict, in `paperIDs` order (the Ask window names the ones that block or ask).
    var paperPrivacy: [AssistPrivacy.Verdict] = []
    /// The last question sent from here, in which thread and how (Try Again / Continue resend it
    /// there; never with the privacy confirmation, which covered that one send). Cleared when the
    /// thread or the papers change.
    var lastAsk: QASentQuestion?

    @ObservationIgnored weak var state: AppState?
    /// The papers changed (`setPapers`): the Ask window showing this session follows (its registration
    /// and title). `filed`: this session is now the one kept for the new set (`AskSessions.rekey`).
    @ObservationIgnored var onPapersChange: ((_ oldKey: String, _ filed: Bool) -> Void)?
    @ObservationIgnored private var buffer = ""
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var estimateTask: Task<Void, Never>?

    init(paperIDs: [String], state: AppState?, settings: AssistSettings) {
        self.paperIDs = paperIDs
        self.key = AskSessions.key(paperIDs)
        self.state = state
        self.depth = settings.qaDepth
        self.language = settings.qaLanguage
        self.mode = QAContextMode.defaultMode(paperCount: paperIDs.count)
    }

    var isMulti: Bool { paperIDs.count > 1 }
    var isRunning: Bool { streaming != nil }
    /// The thread whose answer is streaming is the one on screen.
    var streamingHere: Streaming? {
        guard let s = streaming, s.threadID == nil || s.threadID == thread?.id else { return nil }
        return s
    }

    /// The gesture a ticket for `intent` is minted with.
    func gesture(for intent: AskIntent) -> ConsentTicket.Gesture {
        intent.gesture(firstQuestion: messages.isEmpty)
    }

    /// The options of the next question (the toggles).
    var options: QAOptions { QAOptions(depth: depth, language: language) }

    // MARK: Loading

    /// Threads, the latest thread's messages, the privacy verdict, the estimate.
    func load() async {
        guard let engine = state?.engine else { return }
        let qa = await engine.qaService()
        await reloadThreads(qa)
        if thread == nil || !(threads.contains { $0.id == thread?.id } || thread?.persisted == false) {
            thread = threads.first
        }
        if thread == nil { thread = await qa.newThread(paperIDs: paperIDs, mode: mode) }
        if let t = thread { mode = t.mode; if t.persisted { language = t.language } }
        await reloadMessages(qa)
        let check = await qa.privacyCheck(paperIDs: paperIDs)
        privacyUnchecked = !check.unchecked.isEmpty
        privacy = privacyUnchecked ? .blocked : check.verdict
        var each: [AssistPrivacy.Verdict] = []
        for id in paperIDs { each.append(paperIDs.count == 1 ? privacy : await qa.privacy(paperIDs: [id])) }
        paperPrivacy = each
        await refreshEstimate(qa)
    }

    /// "P2", "P4": the papers whose own verdict matches.
    func labels(where match: (AssistPrivacy.Verdict) -> Bool) -> [String] {
        paperPrivacy.enumerated().filter { match($0.element) }.map { "P\($0.offset + 1)" }
    }

    private func reloadThreads(_ qa: QAService) async {
        guard let first = paperIDs.first else { threads = []; return }
        let wanted = Set(paperIDs)
        threads = await qa.threads(paperID: first, scope: isMulti ? .multi : .paper)
            .filter { $0.persisted && Set($0.paperIDs) == wanted }
    }

    private func reloadMessages(_ qa: QAService) async {
        guard let t = thread else { messages = []; return }
        messages = await qa.messages(threadID: t.id)
    }

    /// Recomputes the estimate line after the draft or a toggle changed (debounced).
    func scheduleEstimate() {
        estimateTask?.cancel()
        estimateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, let engine = self.state?.engine else { return }
            await self.refreshEstimate(await engine.qaService())
        }
    }

    private func refreshEstimate(_ qa: QAService) async {
        guard let t = thread else { return }
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        estimate = await qa.estimate(threadID: t.id, question: q.isEmpty ? "?" : q, options: options)
    }

    // MARK: Threads

    func newThread() {
        guard !isRunning else { return }
        Task { [weak self] in
            guard let self, let engine = self.state?.engine else { return }
            let qa = await engine.qaService()
            self.thread = await qa.newThread(paperIDs: self.paperIDs, mode: self.mode)
            self.messages = []
            self.notice = nil
            self.lastAsk = nil
            await self.refreshEstimate(qa)
        }
    }

    func select(threadID: String) {
        guard let t = threads.first(where: { $0.id == threadID }) else { return }
        thread = t
        mode = t.mode
        language = t.language
        notice = nil
        lastAsk = nil                                   // Try Again here resends this thread's question
        Task { [weak self] in
            guard let self, let engine = self.state?.engine else { return }
            let qa = await engine.qaService()
            await self.reloadMessages(qa)
            await self.refreshEstimate(qa)
        }
    }

    func deleteThread() {
        guard let t = thread, t.persisted else { return }
        Task { [weak self] in
            guard let self, let engine = self.state?.engine else { return }
            let qa = await engine.qaService()
            do { try await qa.deleteThread(id: t.id) } catch { self.state?.report(error) }
            self.thread = nil
            await self.load()
        }
    }

    func setLanguage(_ l: AssistSettings.AnswerLanguage) {
        language = l
        if let t = thread {
            Task { [weak self] in
                guard let engine = self?.state?.engine else { return }
                await engine.qaService().setLanguage(threadID: t.id, l)
            }
        }
        scheduleEstimate()
    }

    func setMode(_ m: QAContextMode) {
        guard QAContextMode.allowed(paperCount: paperIDs.count).contains(m) else { return }
        mode = m
        if let t = thread {
            Task { [weak self] in
                guard let engine = self?.state?.engine else { return }
                await engine.qaService().setMode(threadID: t.id, m)
                if let self { self.thread = await engine.qaService().thread(id: t.id) ?? self.thread }
            }
        }
        scheduleEstimate()
    }

    /// The Ask window's paper list changed (a paper removed): a new thread over the new set. The
    /// session is filed under the new set (`AskSessions.rekey`): asking across the old selection again
    /// opens a session over all of it, and asking across the new one finds this window.
    func setPapers(_ ids: [String]) {
        guard ids != paperIDs, !ids.isEmpty, !isRunning else { return }
        let oldKey = key
        paperIDs = ids
        key = AskSessions.key(ids)
        let filed = state.map { AskSessions.rekey(self, from: oldKey, state: $0) } ?? false
        onPapersChange?(oldKey, filed)
        thread = nil
        messages = []
        notice = nil
        lastAsk = nil
        if !QAContextMode.allowed(paperCount: ids.count).contains(mode) { mode = .defaultMode(paperCount: ids.count) }
        Task { [weak self] in await self?.load() }
    }

    // MARK: Asking

    /// Performs `intent` with the ticket the view minted for this click (`QASendPlan` decides what
    /// goes out: Try Again / Continue resend this thread's question, a privacy confirmation covers
    /// only the send of its own click, "Answer in …" re-asks that answer's question).
    func perform(_ intent: AskIntent, ticket: ConsentTicket) {
        var confirming: (question: String, options: QAOptions)?
        if case .confirm(_, let q, let o)? = notice { confirming = (q, o) }
        guard let send = QASendPlan.send(intent, current: options, last: lastAsk, threadID: thread?.id,
                                         messages: messages, confirming: confirming) else { return }
        if case .ask = intent { draft = "" }
        start(send, intent: intent, ticket: ticket)
    }

    /// Cancel / ✕ on the notice. A privacy confirmation's question goes back into an empty composer:
    /// it was cleared when the question was sent, and nothing was stored.
    func dismissNotice() {
        if case .confirm(_, let q, _)? = notice {
            draft = QASendPlan.draftAfterDismissing(confirming: q, draft: draft, messages: messages)
        }
        notice = nil
    }

    /// Stops the answer streaming in this session.
    func stop() {
        guard let id = streaming?.threadID ?? thread?.id, let engine = state?.engine else { return }
        Task { await engine.qaService().cancel(threadID: id) }
    }

    /// A question stored without an answer at the end of the thread (a refused one).
    var trailingQuestion: String? { QASendPlan.trailingQuestion(messages) }

    /// The user question an answer replied to.
    func question(answering messageID: String) -> String? {
        QASendPlan.question(answering: messageID, in: messages)
    }

    private func start(_ send: QASendPlan.Send, intent: AskIntent, ticket: ConsentTicket) {
        guard let engine = state?.engine else { return }
        let question = send.question, options = send.options
        lastAsk = QASendPlan.sent(intent, send, threadID: thread?.id)
        notice = nil
        buffer = ""
        streaming = Streaming(threadID: thread?.id, question: question, startedAt: Date())
        turnTask?.cancel()
        turnTask = Task { [weak self] in
            let qa = await engine.qaService()
            guard let self else { return }
            if self.thread == nil { self.thread = await qa.newThread(paperIDs: self.paperIDs, mode: self.mode) }
            guard let t = self.thread else { return }
            self.streaming?.threadID = t.id
            if self.lastAsk?.threadID == nil { self.lastAsk?.threadID = t.id }
            let stream = await qa.ask(threadID: t.id, question: question, options: options, ticket: ticket)
            for await event in stream {
                guard !Task.isCancelled else { return }         // a newer question took over this view
                await self.handle(event, qa: qa, question: question, options: options)
            }
            if !Task.isCancelled, self.streaming != nil { self.finishStreaming() }
        }
    }

    private func handle(_ e: QAEvent, qa: QAService, question: String, options: QAOptions) async {
        switch e {
        case .started(let est):
            estimate = est
            streaming?.phase = .starting
            if let t = thread, let stored = await qa.thread(id: t.id) { thread = stored }
            await reloadMessages(qa)
        case .phase(let p):
            switch p {
            case .starting: streaming?.phase = .starting
            case .waitingForFirstToken: streaming?.phase = .waiting
            case .stillWaiting: streaming?.phase = .stillWaiting
            case .streaming: streaming?.phase = .streaming
            }
        case .delta(let s):
            append(s)
        case .replace(let text):
            buffer = ""
            if var s = streaming {
                s.text = text
                s.blocks = QAAnswerFormat.blocks(text)
                s.phase = .streaming
                streaming = s
            }
        // The stored answer replaces the live one in the same main-actor turn: clearing `streaming`
        // first showed the row as last saved mid-stream (partial text, state streaming) until the
        // reload landed — a flicker, and `isRunning` false over a not-yet-final answer. A newer
        // question asked meanwhile cancelled this turn's task: its live answer is left alone.
        case .completed:
            await reloadThreads(qa)
            await reloadMessages(qa)
            guard !Task.isCancelled else { return }
            finishStreaming()
            await refreshEstimate(qa)
        case .failed(let f, _):
            await reloadMessages(qa)
            guard !Task.isCancelled else { return }
            finishStreaming()
            notice = AskNotice.from(f)
        case .needsConfirmation(let reasons):
            finishStreaming()
            notice = .confirm(reasons: reasons, question: question, options: options)
        }
    }

    /// A delta: into the buffer; flushed at most every `flushInterval`.
    func append(_ delta: String) {
        buffer += delta
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: AskSession.flushInterval)
            self?.flush()
        }
    }

    /// Moves the buffered text into `streaming` and re-parses its blocks (one redraw).
    func flush() {
        flushTask = nil
        guard !buffer.isEmpty, var s = streaming else { buffer = ""; return }
        s.text += buffer
        buffer = ""
        s.blocks = QAAnswerFormat.blocks(s.text)
        s.phase = .streaming
        streaming = s                                   // one change, one redraw
    }

    private func finishStreaming() {
        flushTask?.cancel()
        flushTask = nil
        buffer = ""
        streaming = nil
    }

    // MARK: Answers

    func saveToNotes(messageID: String, paperIDs: [String]? = nil) {
        guard let state else { return }
        let ids = paperIDs ?? self.paperIDs
        Task {
            do {
                _ = try await state.engine.qaService().saveToNotes(messageID: messageID, paperIDs: ids)
                state.post(Toast(kind: .success, message: L.QA.savedToNotes))
            } catch {
                state.report(error)
            }
        }
    }

    func delete(messageID: String) {
        guard let state else { return }
        Task { [weak self] in
            let qa = await state.engine.qaService()
            do { try await qa.deleteMessage(id: messageID) } catch { state.report(error) }
            guard let self else { return }
            if let t = self.thread, await qa.thread(id: t.id) == nil {
                self.thread = nil
                await self.load()
            } else {
                await self.reloadMessages(qa)
            }
        }
    }
}

/// The Ask sessions of one app state, kept while the app runs (switching papers or closing the
/// Ask window doesn't lose a streaming answer or the draft).
enum AskSessions {
    private static var byState: [ObjectIdentifier: [String: AskSession]] = [:]
    private static var order: [ObjectIdentifier: [String]] = [:]
    static let keep = 24

    static func key(_ ids: [String]) -> String { ids.joined(separator: "+") }

    static func session(for paperIDs: [String], state: AppState) -> AskSession {
        let sid = ObjectIdentifier(state)
        let k = key(paperIDs)
        if let s = byState[sid]?[k] {
            if s.paperIDs == paperIDs { return s }
            order[sid]?.removeAll { $0 == k }           // it covers other papers now: not this selection's
        }
        let s = AskSession(paperIDs: paperIDs, state: state, settings: state.settings.assist)
        byState[sid, default: [:]][k] = s
        order[sid, default: []].append(k)
        // Forget the oldest idle sessions beyond `keep`.
        while (order[sid]?.count ?? 0) > keep, let oldest = order[sid]?.first(where: { byState[sid]?[$0]?.isRunning == false }) {
            order[sid]?.removeAll { $0 == oldest }
            byState[sid]?[oldest] = nil
        }
        return s
    }

    /// `session` now covers other papers (`AskSession.setPapers`): it is found under its new key, no
    /// longer under `old`. Another session already kept for the new set stays the one found for it.
    /// True when `session` is the one kept for its new key.
    @discardableResult
    static func rekey(_ session: AskSession, from old: String, state: AppState) -> Bool {
        let sid = ObjectIdentifier(state)
        if old != session.key, byState[sid]?[old] === session {
            byState[sid]?[old] = nil
            order[sid]?.removeAll { $0 == old }
        }
        if let kept = byState[sid]?[session.key] { return kept === session }
        byState[sid, default: [:]][session.key] = session
        order[sid, default: []].append(session.key)
        return true
    }
}
