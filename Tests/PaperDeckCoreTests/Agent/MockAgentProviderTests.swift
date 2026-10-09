import Foundation
import Testing
@testable import PaperDeckCore

@Suite struct MockAgentProviderTests {
    private let jobDir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-mock-unused")

    private func request(metadata: BiblioMetadata? = nil, pages: Int? = 12, categories: [String] = PaperCategory.starters.map(\.name),
                         paper: String = "[[p. 1]]\nDeep Atlas of Everything\nAbstract text\n[[p. 2]]\nMore",
                         timeout: Duration = .seconds(360)) -> CardRequest {
        CardRequest(schema: CardSchema.schema(categories: categories),
                    stdin: CardSchema.stdin(metadata: metadata, pageCount: pages,
                                            categories: categories.map { ($0, nil, 0) }, frequentTags: [],
                                            paperText: paper),
                    timeout: timeout)
    }

    @Test func successCardIsDeterministicAndSanitizes() async throws {
        let meta = BiblioMetadata(title: "Molecular and cellular dynamics of the developing human neocortex",
                                  authors: ["Li Wang"], year: 2024, venue: "Nature", source: .crossref)
        let r = request(metadata: meta, pages: 49)
        let mock = MockAgentProvider()
        guard case .success(let card, let runMeta) = await mock.generateCard(r, jobDir: jobDir) else {
            Issue.record("expected success"); return
        }
        #expect(card == MockAgentProvider.card(for: r))
        #expect(runMeta.model == "mock")
        #expect(runMeta.costUSD == 0)
        #expect(runMeta.variant == nil)

        let c = try CardSanitizer.sanitize(card, pageCount: 49)
        #expect(c.tldr.contains("Molecular and cellular dynamics"))
        #expect(c.tldr.count <= 120)
        #expect(c.category == "AI Agents for Science")          // first enum value
        #expect(c.newCategory == nil)
        #expect(c.extractedMetadata == nil)                     // canonical metadata present
        #expect(c.checklist.count == 5)
        #expect(c.checklist.reduce(0) { $0 + $1.minutes } == c.estimatedMinutes)
        #expect(c.checklist.first?.page == 1)
        #expect(c.checklist.last?.page == 49)
        #expect(c.checklist.allSatisfy { ($0.page ?? 0) <= 49 })
        #expect(c.tags.contains("mock"))
        #expect(c.estimatedMinutes == 120)
    }

    @Test func withoutMetadataTitleComesFromThePaper() throws {
        let card = MockAgentProvider.card(for: request(metadata: nil, pages: nil))
        let c = try CardSanitizer.sanitize(card, pageCount: nil)
        #expect(c.extractedMetadata?.title == "Deep Atlas of Everything")
        #expect(c.tldr.contains("Deep Atlas of Everything"))
        #expect(c.checklist.map(\.page) == [1, 1, 1, 1, 2])     // pages inferred from [[p. N]] markers
    }

    @Test func noCategoriesUsesNewToken() throws {
        let c = try CardSanitizer.sanitize(MockAgentProvider.card(for: request(categories: [])), pageCount: 12)
        #expect(c.category == ReadingCard.newCategoryToken)
        #expect(c.newCategory?.name == "Uncategorized")
    }

    @Test func hostilePageMarkersDoNotTrap() throws {
        let r = request(pages: nil, paper: "[[p. 99999999999999999999]]\n[[p. 9223372036854775806]]\nx")
        _ = try CardSanitizer.sanitize(MockAgentProvider.card(for: r), pageCount: nil)
    }

    @Test(.timeLimit(.minutes(1))) func hangReportsTimeoutAfterTheRequestTimeout() async {
        let mock = MockAgentProvider(behavior: .hang)
        let clock = ContinuousClock()
        let t0 = clock.now
        let outcome = await mock.generateCard(request(timeout: .milliseconds(300)), jobDir: jobDir)
        #expect(outcome == .timeout)
        #expect(t0.duration(to: clock.now) >= .milliseconds(300))
    }

    @Test(.timeLimit(.minutes(1))) func hangIsCancellable() async {
        let mock = MockAgentProvider(behavior: .hang)
        let r = request(timeout: .seconds(60))
        let dir = jobDir
        let task = Task { await mock.generateCard(r, jobDir: dir) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        #expect(await task.value == .cancelled)
    }

    @Test func scriptedFailuresThenFallback() async {
        let reset = Date(timeIntervalSince1970: 1_790_000_000)
        let mock = MockAgentProvider(behavior: .success, script: [.usageLimit(resetsAt: reset), .invalidOutput])
        #expect(await mock.generateCard(request(), jobDir: jobDir) == .usageLimit(resetsAt: reset))
        #expect(await mock.generateCard(request(), jobDir: jobDir) == .invalidOutput("mock provider: structured_output is null"))
        guard case .success = await mock.generateCard(request(), jobDir: jobDir) else {
            Issue.record("expected fallback success"); return
        }
        #expect(await mock.calls == 3)
        await mock.enqueue(.notLoggedIn)
        #expect(await mock.generateCard(request(), jobDir: jobDir) == .notLoggedIn)
    }

    @Test func detectReflectsLoginBehavior() async {
        #expect(await MockAgentProvider().detect() == .ready(plan: "mock", version: "0.0.0-mock", path: "mock"))
        let loggedOut = MockAgentProvider(behavior: .notLoggedIn)
        guard case .notLoggedIn = await loggedOut.detect() else { Issue.record("expected notLoggedIn"); return }
        #expect(await loggedOut.generateCard(request(), jobDir: jobDir) == .notLoggedIn)
        #expect(MockAgentProvider().id == "mock")
    }
}
