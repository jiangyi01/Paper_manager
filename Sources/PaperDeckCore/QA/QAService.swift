import Foundation

/// What `QAService` needs from a library: its stores and the two engine rules it must follow (the
/// privacy verdict, the reader the prompt is written for). Built by `Engine.qaService()`
/// (OperationsQA); it holds no reference to the engine itself.
package struct QALibrary: Sendable {
    package let ctx: EngineContext
    package let reader: @Sendable () -> String
    package let privacy: @Sendable (_ paperID: String) async throws -> AssistPrivacy.Verdict

    package init(ctx: EngineContext, reader: @escaping @Sendable () -> String,
                 privacy: @escaping @Sendable (_ paperID: String) async throws -> AssistPrivacy.Verdict) {
        self.ctx = ctx; self.reader = reader; self.privacy = privacy
    }
}

/// Paper Q&A (DQ §6, READING_ASSIST_PLAN §4 "Surface APIs", §6.4 C2/C3). Owned by Slice C.
///
/// One question is one assist turn through `AssistLane` (and so `AssistGate`: `assist.mode` on, a
/// fresh single-use `ConsentTicket` from the user's click, caps, pauses). Follow-ups resend the
/// context — the paper blocks first, byte-identical while the same pages go out, then the last turns
/// in `<conversation>` — as one-shot turns: never `--resume`, nothing kept by the CLI.
///
/// Before anything is stored or sent, every paper's privacy verdict is checked: never-AI refuses,
/// unpublished / confidential / person-sourced papers end with `.needsConfirmation` until the user
/// confirmed (`QAOptions.privacyAcknowledged`, with a fresh ticket from that click). A verdict that
/// can't be read refuses too (fail closed, Phase 2 fix QA-3): nothing is stored or sent.
///
/// Bound to a library (`Engine.qaService()`): threads and messages live in the `qa_*` tables; an
/// answer is stored `streaming` when its turn starts (its partial text saved every 2 s) and becomes
/// `done` / `failed` / `cancelled`; rows a crash left `streaming` become `cancelled` when the
/// service binds. Single-paper threads are mirrored to the paper folder's `qa.json` unless the
/// paper's verdict isn't `.ok` — re-checked whenever a paper's privacy inputs change, whatever
/// changed them (the policy, a duplicate merge, a person's email, the unpublished hold; Phase 2 fix
/// QA-2): the bound service follows the library's `ChangeHub`. A gate refusal (nothing sent) stores
/// no answer. Unbound (the engine's bare `qa`, Slice 0's stub contract): threads and messages in
/// memory, the question alone as context.
///
/// The latest question wins, app-wide (the lane runs one generating turn): a newer one stops an
/// older one, whose answer keeps its text as `cancelled`. A turn doesn't stop when its stream's
/// consumer goes away (the answer is still stored); `cancel(threadID:)` stops it.
package actor QAService {
    private struct Turn { let id: UUID }

    private let lane: AssistLane
    private let load: @Sendable () -> EngineSettings
    private let now: @Sendable () -> Date
    private var library: QALibrary?
    /// Threads with no question yet (and, unbound, every thread).
    private var pending: [String: QAThread] = [:]
    /// Unbound: the messages.
    private var memory: [String: [QAMessage]] = [:]
    private var running: [String: Turn] = [:]
    /// The thread of the last turn handed to the lane.
    private var latest: String?
    /// Bumped by every `ask`: an older turn that hasn't reached the lane yet stops.
    private var generation = 0
    private var cancelRequested: Set<String> = []
    private var pageCache: [String: [QAPage]] = [:]
    private var pageCacheOrder: [String] = []
    private var sidecarTasks: [String: Task<Void, Never>] = [:]
    /// Follows the library's changes (privacy inputs → `qa.json`).
    private var watcher: Task<Void, Never>?
    /// Papers changed since the last privacy pass; `dirtyAll`: a bulk change, every paper with threads.
    private var dirtyPapers: Set<Int64> = []
    private var dirtyAll = false
    private var privacyPass: Task<Void, Never>?

    /// How often a streaming answer's text is saved (crash recovery keeps it as stopped).
    package static let partialSaveInterval: Duration = .seconds(2)
    private var partialSaveEvery: Duration = QAService.partialSaveInterval
    private static let pageCacheSize = 8
    /// `AssistFailure.generic` of a question refused because a paper's privacy verdict couldn't be read.
    package static let privacyUncheckedCode = "privacy_unchecked"
    /// `QAMessage.errorKind` of an answer the lane cut at its output cap (kept, shown as cut off).
    package static let outputCapKind = "output_cap"

    package init(lane: AssistLane, load: @escaping @Sendable () -> EngineSettings, now: @escaping @Sendable () -> Date = Date.init) {
        self.lane = lane; self.load = load; self.now = now
    }

    deinit {
        watcher?.cancel()
        privacyPass?.cancel()
    }

    /// Binds the library (once; later calls do nothing) and recovers what a crash left: answers
    /// still `streaming` become `cancelled`, threads without papers go. From then on every change of
    /// a paper's privacy inputs re-checks its `qa.json` (and once now: changes made while unbound).
    package func bind(_ library: QALibrary) async {
        guard self.library == nil else { return }
        self.library = library
        do {
            let r = try await library.ctx.db.recoverQA()
            if r.cancelled + r.orphanThreads > 0 {
                Log.assist.notice("qa recovery: \(r.cancelled, privacy: .public) interrupted answer(s), \(r.orphanThreads, privacy: .public) orphan thread(s)")
            }
        } catch {
            Log.assist.error("qa recovery failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        let changes = library.ctx.changes.subscribe()
        watcher = Task { [weak self] in
            for await change in changes {
                guard let self else { return }
                await self.noteChange(change)
            }
        }
        dirtyAll = true
        schedulePrivacyPass()
    }

    /// Tests: save a streaming answer's text this often instead of every 2 s.
    package func setPartialSaveInterval(_ interval: Duration) { partialSaveEvery = interval }

    package var isBound: Bool { library != nil }

    // MARK: Threads

    /// Threads that include `paperID` (single- and multi-paper), most recently active first; threads
    /// with no question yet first.
    package func threads(paperID: String) async -> [QAThread] {
        await threads(paperID: paperID, scope: nil)
    }

    /// `threads(paperID:)` of one scope (nil: both).
    package func threads(paperID: String, scope: QAThread.Scope?) async -> [QAThread] {
        let unsaved = pending.values.filter { $0.paperIDs.contains(paperID) && (scope == nil || $0.scope == scope) }
            .sorted { $0.updatedAt > $1.updatedAt }
        guard let library else { return unsaved }
        let stored = (try? await library.ctx.db.qaThreads(paperID: paperID, scope: scope)) ?? []
        return unsaved.filter { !$0.persisted } + stored
    }

    package func thread(id: String) async -> QAThread? {
        if let t = pending[id] { return t }
        return try? await library?.ctx.db.qaThread(id: id)
    }

    /// A new thread over `paperIDs` (P1…Pn in this order). Stored with its first question.
    package func newThread(paperIDs: [String], mode: QAContextMode) -> QAThread {
        var t = QAThread(paperIDs: paperIDs, title: "", mode: mode, createdAt: now(),
                         language: load().assist.qaLanguage)
        if paperIDs.count == 1 { t.mode = .fullText }
        pending[t.id] = t
        return t
    }

    /// The thread's EN / 中 / Auto choice.
    package func setLanguage(threadID: String, _ language: AssistSettings.AnswerLanguage) async {
        if pending[threadID] != nil { pending[threadID]?.language = language; return }
        try? await library?.ctx.db.updateQAThread(id: threadID, language: language)
    }

    /// The thread's context mode (cards / excerpts / full text; full text only for ≤ 3 papers).
    package func setMode(threadID: String, _ mode: QAContextMode) async {
        guard let t = await thread(id: threadID), QAContextMode.allowed(paperCount: t.paperIDs.count).contains(mode) else { return }
        if pending[threadID] != nil { pending[threadID]?.mode = mode; return }
        try? await library?.ctx.db.updateQAThread(id: threadID, mode: mode)
    }

    /// Removes a thread with its messages (its papers' `qa.json` follows).
    package func deleteThread(id: String) async throws {
        await cancel(threadID: id)
        if let t = pending.removeValue(forKey: id), !t.persisted || library == nil {
            memory[id] = nil
            return
        }
        guard let library else { return }
        let papers = try await library.ctx.db.deleteQAThread(id: id)
        for p in papers { scheduleSidecar(paperID: p) }
    }

    /// The thread's messages, oldest first.
    package func messages(threadID: String) async -> [QAMessage] {
        if library == nil || pending[threadID]?.persisted == false { return memory[threadID] ?? [] }
        return (try? await library?.ctx.db.qaMessages(threadID: threadID)) ?? []
    }

    /// The combined privacy verdict of the thread's papers (the banner before Send): blocked when
    /// any is never-AI, otherwise every paper's reasons together. Unbound: `.ok`.
    package func privacy(threadID: String) async -> AssistPrivacy.Verdict {
        guard let t = await thread(id: threadID) else { return .ok }
        return await privacy(paperIDs: t.paperIDs)
    }

    // MARK: Estimate

    /// What `question` would send now (no call is made): characters, tokens, pages, model, the
    /// usual answer time.
    package func estimate(threadID: String, question: String, options: QAOptions) async -> QAEstimate {
        let settings = load()
        guard let thread = await thread(id: threadID) else {
            return QAEstimate(chars: question.count, estimatedTokens: QAEstimator.tokens(question))
        }
        let context = await buildContext(thread: thread, question: question, options: options, history: await history(thread.id))
        return await estimate(context.context, thread: thread, settings: settings, depth: options.depth)
    }

    // MARK: Ask

    /// Asks `question` in the thread with the user's `ticket` (minted by the Ask click). The stream
    /// ends after `completed`, `failed` or `needsConfirmation`.
    package func ask(threadID: String, question: String, options: QAOptions, ticket: ConsentTicket) -> AsyncStream<QAEvent> {
        let (stream, c) = AsyncStream<QAEvent>.makeStream(bufferingPolicy: .unbounded)
        let q = QAContextBuilder.capQuestion(question)          // stored and sent as cut (≤ 1,000 characters)
        guard !q.isEmpty else {
            c.yield(.failed(.generic("empty question"), partial: nil))
            c.finish()
            return stream
        }
        generation += 1
        let gen = generation
        let turn = Turn(id: UUID())
        running[threadID] = turn
        cancelRequested.remove(threadID)
        Task {
            await self.run(turn: turn, generation: gen, threadID: threadID, question: q, options: options, ticket: ticket, c)
            c.finish()
        }
        return stream
    }

    /// Stops the thread's turn: before it reached the lane nothing is sent; while it runs the lane
    /// stops it and the answer keeps its text as `cancelled`.
    package func cancel(threadID: String) async {
        guard running[threadID] != nil else { return }
        cancelRequested.insert(threadID)
        if latest == threadID { await lane.cancel(surface: .qa) }
    }

    package func isRunning(threadID: String) -> Bool { running[threadID] != nil }

    // MARK: Notes, deletion, sidecars

    /// Appends the answer (with its question) to the notes of every paper of its thread.
    package func saveToNotes(messageID: String) async throws {
        guard let m = try await message(id: messageID), let t = await thread(id: m.threadID) else {
            throw QAError.unknownMessage(messageID)
        }
        _ = try await saveToNotes(messageID: messageID, paperIDs: t.paperIDs)
    }

    /// Appends the answer to the notes of `paperIDs` (papers of its thread; others are ignored)
    /// through the same read-modify-write as the notes editor. A paper whose notes already hold
    /// this block is left alone. Returns how many papers got it.
    @discardableResult
    package func saveToNotes(messageID: String, paperIDs: [String]) async throws -> Int {
        guard let library else { return 0 }
        let db = library.ctx.db
        guard let m = try await db.qaMessage(id: messageID) else { throw QAError.unknownMessage(messageID) }
        guard m.role == .assistant, m.state == .done || m.state == .cancelled,
              !m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw QAError.notAnAnswer(messageID) }
        guard let thread = try await db.qaThread(id: m.threadID) else { throw QAError.unknownThread(m.threadID) }
        let all = try await db.qaMessages(threadID: thread.id)
        let question = all.last { $0.role == .user && $0.ord < m.ord }?.text
        var titles: [String] = []
        for id in thread.paperIDs { titles.append((try? await db.paper(id: id))?.title ?? id) }
        let settings = load()
        let block = QANotes.block(question: question, answer: m, paperTitles: titles, lang: settings.lang,
                                  timeZone: library.ctx.calendar.timeZone)
        var saved = 0
        for id in paperIDs where thread.paperIDs.contains(id) {
            guard let paper = try await db.paper(id: id), paper.isLive else { continue }
            let changed = try await db.modifyPaper(pk: paper.pk, now: now()) { p in
                guard p.isLive, !p.notes.contains(block) else { return }
                p.notes = ExplainNotes.append(block, to: p.notes)
            }
            if changed.notes != paper.notes { saved += 1 }
            await library.ctx.syncSidecar(pk: paper.pk)
        }
        return saved
    }

    /// Removes one message (a thread left empty goes too).
    package func deleteMessage(id: String) async throws {
        guard let library else {
            for key in memory.keys { memory[key]?.removeAll { $0.id == id } }
            return
        }
        guard let threadID = try await library.ctx.db.deleteQAMessage(id: id) else { throw QAError.unknownMessage(id) }
        guard let t = try await library.ctx.db.qaThread(id: threadID) else { return }
        if try await library.ctx.db.qaMessages(threadID: threadID).isEmpty {
            try await library.ctx.db.deleteQAThread(id: threadID)
        }
        for p in t.paperIDs { scheduleSidecar(paperID: p) }
    }

    /// Rewrites (or removes) `qa.json` for `paperID` — e.g. after its privacy flags changed.
    package func syncSidecar(paperID: String) async {
        scheduleSidecar(paperID: paperID)
        await flushSidecars()
    }

    /// Waits until the privacy pass that is running (or queued) and its `qa.json` writes are done.
    package func settlePrivacy() async {
        while let pass = privacyPass { await pass.value }
        await flushSidecars()
    }

    /// Waits until every scheduled `qa.json` write is on disk.
    package func flushSidecars() async {
        for task in sidecarTasks.values { await task.value }
    }

    /// Imports the threads of `paperID`'s `qa.json` that the database doesn't have (index rebuild).
    /// Returns how many threads were added.
    @discardableResult
    package func restoreSidecar(paperID: String) async -> Int {
        guard let library, let paper = try? await library.ctx.db.paper(id: paperID) else { return 0 }
        let url = Self.folder(of: paper, ctx: library.ctx).appendingPathComponent(QASidecar.fileName)
        guard let data = await BlockingIO.run({ try? Data(contentsOf: url) }), let file = try? QASidecar.decode(data),
              file.paperID.lowercased() == paperID.lowercased() else { return 0 }
        var added = 0
        for (thread, messages) in file.restored() {
            var t = thread
            t.paperIDs = [paperID]
            guard (try? await library.ctx.db.qaThread(id: t.id)) == nil else { continue }
            do {
                try await library.ctx.db.insertQAThread(t)
                for m in messages { try await library.ctx.db.insertQAMessage(m) }
                added += 1
            } catch {
                Log.assist.error("qa.json restore skipped a thread: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        return added
    }

    // MARK: - The turn

    private func run(turn: Turn, generation gen: Int, threadID: String, question: String, options: QAOptions,
                     ticket: ConsentTicket, _ c: AsyncStream<QAEvent>.Continuation) async {
        defer { if running[threadID]?.id == turn.id { running[threadID] = nil } }
        guard var thread = await thread(id: threadID) else {
            c.yield(.failed(.generic("unknown thread"), partial: nil))
            return
        }
        // 1. Privacy, before anything is stored or sent. A verdict that can't be read refuses.
        let check = library == nil ? PrivacyCheck(verdict: .ok) : await privacyCheck(paperIDs: thread.paperIDs)
        switch check.verdict {
        case .blocked:
            c.yield(.failed(.refused(.policyBlocked), partial: nil))
            return
        case _ where !check.unchecked.isEmpty:
            c.yield(.failed(.generic(Self.privacyUncheckedCode), partial: nil))
            return
        case .confirm(let reasons) where !options.privacyAcknowledged:
            c.yield(.needsConfirmation(reasons))
            return
        default:
            break
        }
        // 2. The thread and the question.
        let history = await history(threadID)
        do {
            thread = try await store(thread: thread, firstQuestion: question, language: options.language)
        } catch {
            c.yield(.failed(.generic("thread not stored"), partial: nil))
            return
        }
        let question = await storeQuestion(question, thread: thread)
        // 3. The context.
        let settings = load()
        let context = await buildContext(thread: thread, question: question.text, options: options, history: history)
        c.yield(.started(await estimate(context.context, thread: thread, settings: settings, depth: options.depth)))
        guard gen == generation, !cancelRequested.contains(threadID) else {
            c.yield(.failed(.cancelled, partial: nil))
            return
        }
        // 4. The turn.
        let mode = settings.assist.mode
        let request = AssistRequest(surface: .qa, systemPrompt: QAPrompts.system(reader: library?.reader() ?? ""),
                                    turnText: context.context.turnText, model: Self.model(settings, options.depth),
                                    effort: QAPrompts.effort(options.depth), format: .text, session: .oneShot,
                                    limits: AssistLimits.defaults(for: .qa, provider: mode.providerKind))
        latest = threadID
        let lang = QAPrompts.answerLanguage(options.language, question: question.text)
        var answer: QAMessage?
        var partial = ""
        let clock = ContinuousClock()
        var lastSave = clock.now
        var terminal = false
        // The answer's row, stored when the lane accepted the turn (a refusal stores none).
        let template = QAMessage(threadID: thread.id, role: .assistant, text: "", state: .streaming,
                                 meta: AssistMeta(provider: mode.rawValue, model: request.model), createdAt: now(),
                                 language: lang.rawValue, depth: options.depth, context: context.context.stats)
        for await event in await lane.submit(request, ticket: ticket) {
            switch event {
            case .waiting:
                if answer == nil { answer = await insert(template) }
            case .phase(let p):
                if answer == nil { answer = await insert(template) }
                c.yield(.phase(p))
            case .delta(let s):
                if answer == nil { answer = await insert(template) }
                partial += s
                // Saved before it is shown: what the reader saw survives a crash.
                if clock.now - lastSave >= partialSaveEvery, let id = answer?.id {
                    lastSave = clock.now
                    await savePartial(id: id, threadID: thread.id, text: partial)
                }
                c.yield(.delta(s))
            case .replace(let s):
                if answer == nil { answer = await insert(template) }
                partial = s
                c.yield(.replace(s))
            case .done(let text, let meta):
                if answer == nil { answer = await insert(template) }
                guard var m = answer else { break }
                m.text = text
                m.state = .done
                m.meta = meta
                m.citations = await citations(text, context: context)
                await update(m)
                await touch(thread)
                if thread.scope == .paper, let paperID = thread.paperIDs.first { scheduleSidecar(paperID: paperID) }
                c.yield(.completed(m))
                terminal = true
            case .failed(let failure, let p):
                terminal = true
                let kept = p ?? (partial.isEmpty ? nil : partial)
                if answer == nil, Self.sentNothing(failure) {
                    c.yield(.failed(failure, partial: nil))
                    break
                }
                if answer == nil { answer = await insert(template) }
                if var m = answer {
                    m.text = kept ?? ""
                    if failure == .invalidOutput(Self.outputCapKind) {
                        // Cut at the output cap: the text so far is kept, as a stopped answer marked cut off.
                        m.state = .cancelled
                        m.errorKind = Self.outputCapKind
                    } else {
                        m.state = failure == .cancelled ? .cancelled : .failed
                        m.errorKind = failure.code
                    }
                    await update(m)
                    await touch(thread)
                    if thread.scope == .paper, let paperID = thread.paperIDs.first { scheduleSidecar(paperID: paperID) }
                }
                c.yield(.failed(failure, partial: kept))
            }
            if terminal { break }
        }
        if !terminal {
            // The lane's stream ended without a verdict (it shouldn't): keep what came as stopped.
            if var m = answer {
                m.text = partial
                m.state = .cancelled
                m.errorKind = AssistFailure.cancelled.code
                await update(m)
            }
            c.yield(.failed(.cancelled, partial: partial.isEmpty ? nil : partial))
        }
    }

    /// The lane refused before anything reached a backend (no answer is stored for it).
    private static func sentNothing(_ f: AssistFailure) -> Bool {
        switch f {
        case .refused, .unsupported: return true
        default: return false
        }
    }

    /// The model of `depth` on the current mode (`mock` / `local` / `off` name themselves).
    static func model(_ settings: EngineSettings, _ depth: AssistSettings.Depth) -> String {
        settings.assist.mode.providerKind.map { settings.assist.model($0, depth) } ?? settings.assist.mode.rawValue
    }

    // MARK: Context

    private struct Built: Sendable {
        var context: QAContext
        var pageCounts: [Int?]
        var pdfs: [URL?]
    }

    private func buildContext(thread: QAThread, question: String, options: QAOptions, history: [AssistTurnText]) async -> Built {
        let settings = load()
        let papers = await paperInputs(thread.paperIDs)
        let request = QAContextRequest(papers: papers.map(\.input), question: question, history: history, mode: thread.mode,
                                       textBudget: settings.assist.qaTextBudget,
                                       language: QAPrompts.answerLanguage(options.language, question: question),
                                       depth: options.depth)
        let context = await BlockingIO.run { QAContextBuilder.build(request) }
        return Built(context: context, pageCounts: papers.map { $0.input.pageCount ?? $0.input.pages.map(\.number).max() },
                     pdfs: papers.map(\.pdf))
    }

    private func estimate(_ context: QAContext, thread: QAThread, settings: EngineSettings,
                          depth: AssistSettings.Depth) async -> QAEstimate {
        let mode = settings.assist.mode
        let recent = (try? await library?.ctx.db.qaRecentDurations(provider: mode.rawValue, depth: depth)) ?? []
        return QAEstimator.estimate(context.stats, systemPrompt: QAPrompts.system(reader: library?.reader() ?? ""), mode: mode,
                                    model: Self.model(settings, depth), depth: depth, recentMs: recent,
                                    papers: thread.paperIDs.count)
    }

    private struct PaperInput: Sendable {
        var input: QAPaperInput
        var pdf: URL?
    }

    private func paperInputs(_ ids: [String]) async -> [PaperInput] {
        guard let library else { return [] }
        var out: [PaperInput] = []
        for id in ids {
            guard let p = try? await library.ctx.db.paper(id: id) else { continue }
            let pages = await pages(of: p, ctx: library.ctx)
            let input = QAPaperInput(id: p.id, title: p.title, authors: p.authors, year: p.year, venue: p.venue,
                                     doi: p.ids.doi ?? p.ids.publishedDOI, arxiv: p.ids.arxivID, pageCount: p.pageCount,
                                     abstract: p.abstract, tldr: p.card?.tldr ?? p.tldr, cardLines: Self.cardLines(p.card),
                                     pages: pages)
            out.append(PaperInput(input: input, pdf: p.isLive ? library.ctx.pdfURL(p) : nil))
        }
        return out
    }

    /// The paper's prepared pages (cached per paper and file; read from the text cache, or from
    /// the PDF when the cache has none — nothing is written).
    private func pages(of p: Paper, ctx: EngineContext) async -> [QAPage] {
        let key = p.id + "#" + p.sha256
        if let hit = pageCache[key] { return hit }
        let texts = ctx.texts
        let id = p.id
        var raw = await BlockingIO.run { (try? texts.load(id: id)) ?? nil } ?? ""
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, p.isLive, !p.flags.contains(.locked) {
            // The page text only (no title heuristics, fonts or thumbnail): nothing written.
            let url = ctx.pdfURL(p)
            raw = await BlockingIO.run { QAPageLabels.pageText(pdf: url) }
        }
        let text = raw
        let pages = await BlockingIO.run { QAContextBuilder.preparePages(rawText: text) }
        pageCache[key] = pages
        pageCacheOrder.removeAll { $0 == key }
        pageCacheOrder.append(key)
        while pageCacheOrder.count > Self.pageCacheSize { pageCache[pageCacheOrder.removeFirst()] = nil }
        return pages
    }

    static func cardLines(_ card: ReadingCard?) -> [String] {
        guard let card else { return [] }
        var lines: [String] = []
        if !card.summary.isEmpty { lines.append("Summary: " + card.summary) }
        lines += card.contributions.filter { !$0.isEmpty }.map { "Contribution: " + $0 }
        if !card.method.isEmpty { lines.append("Method: " + card.method) }
        lines += card.results.filter { !$0.isEmpty }.map { "Result: " + $0 }
        lines += card.limitations.filter { !$0.text.isEmpty }.map { "Limitation: " + $0.text }
        if !card.keyTerms.isEmpty { lines.append("Key terms: " + card.keyTerms.map(\.term).joined(separator: "; ")) }
        return lines
    }

    /// The thread's earlier questions with their finished answers, oldest first.
    private func history(_ threadID: String) async -> [AssistTurnText] {
        let all = await messages(threadID: threadID)
        var out: [AssistTurnText] = []
        for (i, m) in all.enumerated() where m.role == .user {
            guard i + 1 < all.count, all[i + 1].role == .assistant, all[i + 1].state == .done else { continue }
            out.append(AssistTurnText(role: .user, text: m.text))
            out.append(AssistTurnText(role: .assistant, text: all[i + 1].text))
        }
        return out
    }

    /// Validated citations with their supporting sentences and printed page labels. A page that
    /// wasn't sent with the question is `.notSent` (invalid, unchecked): the model never saw it.
    private func citations(_ text: String, context built: Built) async -> [QACitation] {
        let sent = built.context.sentPages
        var cites = QACitations.attachQuotes(text, pageCounts: built.pageCounts) { paper, page in
            sent.indices.contains(paper - 1) ? sent[paper - 1][page] : nil
        }
        cites = QACitations.markUnsent(cites, sent: sent)
        // Printed labels ("1203") where the PDF has them and they differ from the physical page.
        var wanted: [Int: Set<Int>] = [:]
        for c in cites where c.valid { if let p = c.page { wanted[c.paper, default: []].insert(p) } }
        guard !wanted.isEmpty else { return cites }
        let pdfs = built.pdfs
        let want = wanted
        let labels = await BlockingIO.run { () -> [Int: [Int: String]] in
            var out: [Int: [Int: String]] = [:]
            for (paper, pages) in want where pdfs.indices.contains(paper - 1) {
                if let url = pdfs[paper - 1] { out[paper] = QAPageLabels.labels(pdf: url, pages: pages) }
            }
            return out
        }
        for i in cites.indices {
            if let p = cites[i].page, let label = labels[cites[i].paper]?[p] { cites[i].label = label }
        }
        return cites
    }

    // MARK: Privacy

    /// The combined verdict of some papers, and the ones whose verdict couldn't be read.
    package struct PrivacyCheck: Sendable, Equatable {
        /// Blocked when any paper is never-AI; otherwise every readable paper's reasons together.
        package var verdict: AssistPrivacy.Verdict
        /// Papers whose verdict lookup failed: a question about them is refused (fail closed).
        package var unchecked: [String] = []
    }

    /// The combined verdict of `paperIDs` (the Ask views' banner before a thread exists). A paper
    /// whose verdict can't be read counts as blocked — never as fine (fail closed).
    package func privacy(paperIDs: [String]) async -> AssistPrivacy.Verdict {
        let check = await privacyCheck(paperIDs: paperIDs)
        return check.unchecked.isEmpty ? check.verdict : .blocked
    }

    /// `privacy(paperIDs:)` with the papers whose verdict couldn't be read named. Unbound: `.ok`.
    package func privacyCheck(paperIDs: [String]) async -> PrivacyCheck {
        guard let library else { return PrivacyCheck(verdict: .ok) }
        var reasons: Set<AssistPrivacy.Reason> = []
        var unchecked: [String] = []
        for id in paperIDs {
            let verdict: AssistPrivacy.Verdict
            do { verdict = try await library.privacy(id) } catch {
                Log.assist.error("qa privacy check failed: \(String(describing: type(of: error)), privacy: .public)")
                unchecked.append(id)
                continue
            }
            switch verdict {
            case .blocked: return PrivacyCheck(verdict: .blocked, unchecked: unchecked)
            case .confirm(let r): reasons.formUnion(r)
            case .ok: break
            }
        }
        let ordered = AssistPrivacy.Reason.allCases.filter(reasons.contains)
        return PrivacyCheck(verdict: ordered.isEmpty ? .ok : .confirm(ordered), unchecked: unchecked)
    }

    // MARK: Privacy changes → qa.json

    private func noteChange(_ change: LibraryChange) {
        switch change {
        case .paper(let pk): dirtyPapers.insert(pk)
        case .papersBulk, .mail, .mailBulk: dirtyAll = true       // a message's sender kind is a privacy input too
        case .categories, .jobs, .settings: return
        }
        schedulePrivacyPass()
    }

    private func schedulePrivacyPass() {
        guard privacyPass == nil else { return }
        privacyPass = Task { await self.runPrivacyPasses() }
    }

    /// Re-checks the `qa.json` of every changed paper that has single-paper threads, until nothing
    /// is left (changes during a pass make another pass).
    private func runPrivacyPasses() async {
        while let library, dirtyAll || !dirtyPapers.isEmpty {
            let all = dirtyAll, changed = dirtyPapers
            dirtyAll = false
            dirtyPapers = []
            let papers = (try? await library.ctx.db.qaSidecarPapers()) ?? []
            for p in papers where all || changed.contains(p.pk) {
                if await Self.sidecarIsStale(paperID: p.id, library: library) { scheduleSidecar(paperID: p.id) }
            }
        }
        privacyPass = nil
    }

    /// `qa.json` exists while the verdict isn't `.ok` (or can't be read), or is missing while it is.
    private static func sidecarIsStale(paperID: String, library: QALibrary) async -> Bool {
        guard let paper = try? await library.ctx.db.paper(id: paperID) else { return false }
        let url = folder(of: paper, ctx: library.ctx).appendingPathComponent(QASidecar.fileName)
        let exists = await BlockingIO.run { FileManager.default.fileExists(atPath: url.path) }
        let ok = (try? await library.privacy(paperID)) == .ok
        return exists != ok
    }

    // MARK: Store

    /// Stores a new thread with its first question (its language: the question's toggle). A stored
    /// thread is left as it is: its language is the toggle's (`setLanguage`), and a one-off answer
    /// in another language ("Answer in 中文") doesn't change it (Phase 2 fix QA-12).
    private func store(thread: QAThread, firstQuestion: String, language: AssistSettings.AnswerLanguage) async throws -> QAThread {
        var t = thread
        if t.persisted { return t }
        t.title = QAPrompts.title(for: firstQuestion)
        t.language = language
        t.updatedAt = now()
        t.persisted = true
        if let library {
            let stored = try await library.ctx.db.insertQAThread(t)
            pending[t.id] = nil
            return stored
        }
        pending[t.id] = t
        return t
    }

    /// The question as a stored user message — the thread's last message when that is this same
    /// question still unanswered (a retry doesn't repeat it).
    private func storeQuestion(_ text: String, thread: QAThread) async -> QAMessage {
        let all = await messages(threadID: thread.id)
        if let last = all.last, last.role == .user, last.text == text { return last }
        return await insert(QAMessage(threadID: thread.id, role: .user, text: text, createdAt: now()))
    }

    private func insert(_ m: QAMessage) async -> QAMessage {
        guard let library else {
            var stored = m
            stored.ord = memory[m.threadID]?.count ?? 0
            memory[m.threadID, default: []].append(stored)
            return stored
        }
        do { return try await library.ctx.db.insertQAMessage(m) } catch {
            Log.assist.error("qa message not stored: \(String(describing: type(of: error)), privacy: .public)")
            return m
        }
    }

    private func update(_ m: QAMessage) async {
        guard let library else {
            if let i = memory[m.threadID]?.firstIndex(where: { $0.id == m.id }) { memory[m.threadID]?[i] = m }
            return
        }
        do { try await library.ctx.db.updateQAMessage(m) } catch {
            Log.assist.error("qa message not updated: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func savePartial(id: String, threadID: String, text: String) async {
        guard let library else {
            if let i = memory[threadID]?.firstIndex(where: { $0.id == id }) { memory[threadID]?[i].text = text }
            return
        }
        try? await library.ctx.db.updateQAMessageText(id: id, text: text)
    }

    private func touch(_ thread: QAThread) async {
        let t = now()
        if pending[thread.id] != nil { pending[thread.id]?.updatedAt = t; return }
        try? await library?.ctx.db.updateQAThread(id: thread.id, updatedAt: t)
    }

    private func message(id: String) async throws -> QAMessage? {
        guard let library else { return memory.values.lazy.flatMap { $0 }.first { $0.id == id } }
        return try await library.ctx.db.qaMessage(id: id)
    }

    // MARK: qa.json

    /// Queues a rewrite of `paperID`'s `qa.json` after the ones already queued.
    private func scheduleSidecar(paperID: String) {
        guard let library else { return }
        let previous = sidecarTasks[paperID]
        sidecarTasks[paperID] = Task {
            await previous?.value
            await Self.writeSidecar(paperID: paperID, library: library)
        }
    }

    private static func writeSidecar(paperID: String, library: QALibrary) async {
        let ctx = library.ctx
        guard let paper = try? await ctx.db.paper(id: paperID) else { return }
        let folder = folder(of: paper, ctx: ctx)
        // Only a paper that may go to an AI without a question keeps its threads beside it.
        let verdict = (try? await library.privacy(paperID)) ?? .blocked
        var payload: [(QAThread, [QAMessage])] = []
        if verdict == .ok {
            for t in (try? await ctx.db.qaThreads(paperID: paperID, scope: .paper, includeArchived: true)) ?? [] {
                payload.append((t, (try? await ctx.db.qaMessages(threadID: t.id)) ?? []))
            }
        }
        let sidecar = payload.isEmpty ? nil : QASidecar(paperID: paperID, threads: payload)
        let staging = ctx.paths.partial
        await BlockingIO.run { QASidecarFile.write(sidecar, folder: folder, staging: staging) }
    }

    static func folder(of p: Paper, ctx: EngineContext) -> URL {
        p.isDeleted ? ctx.paths.recentlyDeleted.appendingPathComponent((p.folder as NSString).lastPathComponent)
            : ctx.folderURL(p)
    }
}

/// Writing `qa.json`: atomic, only when the bytes change, never creating the folder (a paper folder
/// that is gone or moving is skipped). `nil` removes the file.
package enum QASidecarFile {
    package static func write(_ sidecar: QASidecar?, folder: URL, staging: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { return }
        let url = folder.appendingPathComponent(QASidecar.fileName)
        guard let sidecar else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? sidecar.encoded() else { return }
        if let existing = try? Data(contentsOf: url), existing == data { return }
        var stagingIsDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: staging.path, isDirectory: &stagingIsDir), stagingIsDir.boolValue {
            let temp = staging.appendingPathComponent(".qa-\(UUID().uuidString).tmp")
            if (try? data.write(to: temp)) != nil {
                if rename(temp.path, url.path) == 0 { return }
                try? FileManager.default.removeItem(at: temp)
            }
        }
        do { try data.write(to: url, options: .atomic) } catch {
            Log.storage.notice("qa.json not written in \(folder.lastPathComponent, privacy: .public)")
        }
    }
}

/// The notes block of a saved answer (the Explain block's shape, ExplainNotes):
/// ```
/// — Ask · 2026-10-01 14:32 · Claude haiku
/// > Q: What is the main finding?
/// > P1 = Title A; P2 = Title B          (several papers)
/// <answer, citations as (p. 3)>
/// ```
package enum QANotes {
    package static func block(question: String?, answer m: QAMessage, paperTitles: [String], lang: UILang,
                              timeZone: TimeZone) -> String {
        let zh = lang == .zh
        var head = [zh ? "提问" : "Ask", stamp(m.createdAt, timeZone: timeZone)]
        if let meta = m.meta {
            let who = AIProviderKind(rawValue: meta.provider)?.shortName
                ?? (meta.provider == AssistMode.local.rawValue ? (zh ? "本机模型" : "On-device model")
                    : meta.provider == AssistMode.mock.rawValue ? "Mock" : meta.provider)
            head.append(meta.model.isEmpty || meta.provider == AssistMode.local.rawValue ? who : "\(who) \(meta.model)")
        }
        var lines = ["— " + head.joined(separator: " · ")]
        if let q = question.map(QAPrompts.oneLine), !q.isEmpty {
            lines.append("> " + (zh ? "问：" : "Q: ") + (q.count > 300 ? String(q.prefix(299)) + "…" : q))
        }
        let multi = paperTitles.count > 1
        if multi {
            lines.append("> " + paperTitles.enumerated().map { "P\($0.offset + 1) = " + QAPrompts.oneLine($0.element) }
                .joined(separator: "; "))
        }
        lines.append(QACitations.plain(m.text, multi: multi).trimmingCharacters(in: .whitespacesAndNewlines))
        return lines.joined(separator: "\n")
    }

    private static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }
}
