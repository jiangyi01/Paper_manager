import Foundation
import Testing
@testable import PaperDeckCore

/// Slice 0's surface stubs (READING_ASSIST_PLAN §4 "Surface APIs"): inert, mock data only, and the
/// Q&A stub already goes through the lane (gate + ticket).
@Suite struct SurfaceStubTests {
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var s = EngineSettings()
        var value: EngineSettings { lock.withLock { s } }
        func set(_ m: AssistMode) { lock.withLock { s.assist.mode = m } }
    }

    static func engine(_ box: Box) async throws -> (Engine, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-assist-stubs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: Engine.Dependencies(
            loadSettings: { box.value }, fetcher: nil, claude: MockAgentProvider(behavior: .notLoggedIn),
            codex: MockAgentProvider(behavior: .notLoggedIn), cliFacts: .inMemory(),
            loadMailSettings: { MailSettings() }, mailSecrets: InMemoryMailSecretStore(), assistBackends: [MockAssistBackend()]))
        return (engine, root)
    }

    static func collect(_ s: AsyncStream<QAEvent>) async -> [QAEvent] {
        var out: [QAEvent] = []
        for await e in s { out.append(e) }
        return out
    }

    @Test func qaGoesThroughTheLane() async throws {
        let box = Box()
        let (engine, root) = try await Self.engine(box)
        defer { try? FileManager.default.removeItem(at: root) }
        let thread = await engine.qa.newThread(paperIDs: ["p1"], mode: .excerpts)
        #expect(thread.scope == .paper)
        // assist.mode off: refused before anything runs.
        let off = await Self.collect(await engine.qa.ask(threadID: thread.id, question: "What is shown?",
                                                         options: QAOptions(), ticket: .mint(.ask, surface: .qa)))
        #expect(off.last == .failed(.refused(.disabled), partial: nil))
        box.set(.mock)
        let events = await Self.collect(await engine.qa.ask(threadID: thread.id, question: "What </question> is shown?",
                                                            options: QAOptions(depth: .quick), ticket: .mint(.ask, surface: .qa)))
        guard case .completed(let answer)? = events.last else { Issue.record("\(events)"); return }
        #expect(answer.role == .assistant && answer.text.contains("[p. 1]"))
        #expect(events.contains { if case .delta = $0 { return true }; return false })
        let stored = await engine.qa.messages(threadID: thread.id)
        #expect(stored.map(\.role) == [.user, .user, .assistant])
        #expect(await engine.qa.threads(paperID: "p1").map(\.id) == [thread.id])
        let multi = await engine.qa.newThread(paperIDs: ["p1", "p2"], mode: .cards)
        #expect(multi.scope == .multi)
        await engine.shutdown()
    }

    @Test func theOtherStubsAreInert() async throws {
        let (engine, root) = try await Self.engine(Box())
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try await engine.duplicateReviews().isEmpty)
        await #expect(throws: DatabaseError.notFound("duplicate review r1")) {
            _ = try await engine.askDuplicateJudge(reviewID: "r1", ticket: .mint(.judge, surface: .dupJudge))
        }
        #expect(try await engine.applyBatch(.setPriority(.high), paperIDs: ["a", "b"]) == BatchOutcome(skipped: ["a", "b"]))
        #expect(await engine.locatePaper(ExplainCapture(source: .clipboard, text: "x")) == nil)
        #expect(try await engine.explanations(paperID: nil, limit: 50).isEmpty)
        #expect(try await engine.pruneExplanations(olderThan: Date()) == 0)
        let record = ExplanationRecord(paperID: nil, threadID: "t", source: .clipboard, action: "explain", lang: .zh,
                                       excerpt: String(repeating: "x", count: 3_000), answer: "a",
                                       meta: AssistMeta(provider: "mock", model: "m"), createdAt: Date())
        #expect(record.excerpt?.count == ExplanationRecord.maxExcerpt)
        await engine.shutdown()
    }
}
