import Foundation
import Testing
@testable import PaperDeckCore

/// Engines for the Q&A suites: `OpsTestKit`'s clock, settings and papers, with `assist.mode = mock`
/// and the given stand-in assist backends (mock or scripted — never a CLI). Papers get a cached text
/// of `pages` pages so the context builder has something to send.
enum QATestKit {
    static func make(mode: AssistMode = .mock, backends: [any AssistBackend]) async throws -> OpsTestKit.Env {
        let root = try OpsTestKit.newRoot()
        let clock = OpsTestKit.Box(OpsTestKit.start)
        var settings = OpsTestKit.settings()
        settings.assist.mode = mode
        let box = OpsTestKit.Box(settings)
        let deps = Engine.Dependencies(loadSettings: { box.value }, now: { clock.value }, calendar: OpsTestKit.calendar,
                                       fetcher: nil, claude: MockAgentProvider(), codex: MockAgentProvider(),
                                       mock: MockAgentProvider(), sidecarDelay: .milliseconds(10), cliFacts: .inMemory(),
                                       loadCardProfile: { CardPromptProfile.legacyCompBio }, assistBackends: backends)
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: deps)
        return OpsTestKit.Env(engine: engine, root: root, clock: clock, settings: box)
    }

    /// Runs `body` with a fresh engine and always cleans up.
    static func run(mode: AssistMode = .mock, backends: [any AssistBackend] = [MockAssistBackend()],
                    _ body: (OpsTestKit.Env) async throws -> Void) async throws {
        let env = try await make(mode: mode, backends: backends)
        do { try await body(env) } catch {
            await env.cleanup()
            throw error
        }
        await env.cleanup()
    }

    /// The text of page `k`: two long lines (longer than a running header, so `TextPreparer` keeps
    /// them on every page); `extra(k)` adds topic words.
    static func pageText(_ k: Int, extra: (Int) -> String = { _ in "" }) -> String {
        "Measurements reported on page \(k) describe the sample preparation in considerable detail, including buffers. "
            + extra(k) + "\nFurther discussion on page \(k) continues with the controls, the replicates and the statistics of each cohort."
    }

    /// A paper (OpsTestKit: 12 pages declared) with `pages` pages of cached text.
    @discardableResult
    static func addPaper(_ env: OpsTestKit.Env, title: String = "A paper", pages: Int = 12,
                         extra: @escaping (Int) -> String = { _ in "" }) async throws -> Paper {
        let p = try await OpsTestKit.addPaper(env, title: title)
        let text = (1...pages).map { pageText($0, extra: extra) }.joined(separator: "\u{0C}")
        try env.engine.ctx.texts.save(text, id: p.id)
        return p
    }

    static func collect(_ s: AsyncStream<QAEvent>) async -> [QAEvent] {
        var out: [QAEvent] = []
        for await e in s { out.append(e) }
        return out
    }

    /// One question with a ticket minted at the engine's clock (the gate checks it against that clock).
    static func ask(_ env: OpsTestKit.Env, _ qa: QAService, _ threadID: String, _ question: String,
                    options: QAOptions = QAOptions(), gesture: ConsentTicket.Gesture = .ask) async -> [QAEvent] {
        await collect(await qa.ask(threadID: threadID, question: question, options: options,
                                   ticket: ticket(env, gesture)))
    }

    static func ticket(_ env: OpsTestKit.Env, _ gesture: ConsentTicket.Gesture = .ask) -> ConsentTicket {
        .mint(gesture, surface: .qa, now: env.clock.value)
    }

    static func qaJSON(_ env: OpsTestKit.Env, _ paper: Paper) -> URL {
        env.engine.ctx.folderURL(paper).appendingPathComponent(QASidecar.fileName)
    }

    static func completed(_ events: [QAEvent]) -> QAMessage? {
        if case .completed(let m)? = events.last { return m }
        return nil
    }
}
