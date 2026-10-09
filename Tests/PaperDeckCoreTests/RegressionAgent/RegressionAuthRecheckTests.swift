import Foundation
import Testing
@testable import PaperDeckCore

/// Finding 3: subscription-only auth was checked only in detect(); after an auth switch
/// (API-key login / apiKeyHelper) the next `-p` would bill the API. ClaudeCodeProvider now runs
/// the zero-quota `claude auth status --json` (cached ≤ 60 s) before every real spawn.
@Suite(.serialized) struct RegressionAuthRecheckTests {
    private static func request() -> CardRequest {
        CardRequest(schema: CardSchema.schema(categories: PaperCategory.starters.map(\.name)),
                    stdin: CardSchema.stdin(metadata: nil, pageCount: 3, categories: [], frequentTags: [],
                                            paperText: "[[p. 1]]\nA paper"))
    }

    private static func provider(_ cli: RAFakeCLI, clock: RABox<Date>, root: URL) -> ClaudeCodeProvider {
        ClaudeCodeProvider(locator: RAFakeCLI.locator(), agentCwd: root.appendingPathComponent("agent-cwd"),
                           runner: cli.runner, parentEnvironment: { ["HOME": "/Users/tester"] },
                           now: { clock.value })
    }

    /// Ported to the provider (the reviewer's scripted provider never consulted detect()).
    @Test func authSwitchAfterDetectionIsNotRecheckedBeforeTheNextSpawn() async throws {
        let root = try RAQueueHarness.newRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try RAFakeCLI(replies: ["envelope-success", "envelope-success"])
        let clock = RABox(raStart)
        let provider = Self.provider(cli, clock: clock, root: root)
        #expect(await provider.detect() == .ready(plan: "max", version: "2.1.284", path: RAFakeCLI.binary))
        guard case .success = await provider.generateCard(Self.request(), jobDir: root.appendingPathComponent("j1")) else {
            Issue.record("first card should succeed"); return
        }
        #expect(cli.printRequests.count == 1)

        // Claude Code switches off the subscription (apiKeyHelper / Console login).
        try cli.setAuth("auth-status-api-key")
        clock.update { $0 = $0.addingTimeInterval(61) }
        let outcome = await provider.generateCard(Self.request(), jobDir: root.appendingPathComponent("j2"))
        #expect(outcome == .notLoggedIn, "paper B was sent to claude -p although auth is no longer the subscription")
        #expect(cli.printRequests.count == 1, "a -p process was spawned under non-subscription auth")
    }

    /// Logged out between jobs: same refusal, no spawn.
    @Test func loggedOutBeforeASpawnIsRefused() async throws {
        let root = try RAQueueHarness.newRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try RAFakeCLI(auth: "auth-status-logged-out", authExit: 1, replies: ["envelope-success"])
        let provider = Self.provider(cli, clock: RABox(raStart), root: root)
        #expect(await provider.generateCard(Self.request(), jobDir: root.appendingPathComponent("j")) == .notLoggedIn)
        #expect(cli.printRequests.isEmpty)
        #expect(cli.authRequests.count == 1)
    }

    /// A hung `auth status` never lets a spawn through.
    @Test func timedOutAuthCheckRefusesTheSpawn() async throws {
        let root = try RAQueueHarness.newRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try RAFakeCLI(replies: ["envelope-success"])
        cli.setAuthResult(.init(exitCode: 130, signal: SIGINT, timedOut: true))
        let provider = Self.provider(cli, clock: RABox(raStart), root: root)
        #expect(await provider.generateCard(Self.request(), jobDir: root.appendingPathComponent("j")) == .notLoggedIn)
        #expect(cli.printRequests.isEmpty)
    }

    /// The check is cached for at most 60 s: two cards within a minute run `auth status` once,
    /// a third after 61 s checks again. The variant-B retry reuses the fresh check.
    @Test func authCheckIsCachedForSixtySeconds() async throws {
        let root = try RAQueueHarness.newRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = try RAFakeCLI(replies: ["envelope-success-null-structured", "envelope-success", "envelope-success",
                                          "envelope-success"])
        let clock = RABox(raStart)
        let provider = Self.provider(cli, clock: clock, root: root)
        guard case .success(_, let meta) = await provider.generateCard(Self.request(), jobDir: root.appendingPathComponent("a")) else {
            Issue.record("expected success after the B retry"); return
        }
        #expect(meta.variant == "B")
        #expect(cli.printRequests.count == 2 && cli.authRequests.count == 1)
        clock.update { $0 = $0.addingTimeInterval(30) }
        _ = await provider.generateCard(Self.request(), jobDir: root.appendingPathComponent("b"))
        #expect(cli.printRequests.count == 3 && cli.authRequests.count == 1)
        clock.update { $0 = $0.addingTimeInterval(31) }
        _ = await provider.generateCard(Self.request(), jobDir: root.appendingPathComponent("c"))
        #expect(cli.printRequests.count == 4 && cli.authRequests.count == 2)
        // Every auth probe precedes the spawn it guards.
        let order = cli.requests.compactMap(\.arguments.first).filter { $0 == "auth" || $0 == "-p" }
        #expect(order == ["auth", "-p", "-p", "-p", "auth", "-p"])
    }

    /// End to end through the queue: after the switch the next paper waits with needs_login,
    /// the provider state names the reason, and nothing was spawned for it.
    @Test func queueParksThePaperWithTheNonSubscriptionReason() async throws {
        let cli = try RAFakeCLI(replies: ["envelope-success", "envelope-success"])
        let clock = RABox(raStart)
        let root = try RAQueueHarness.newRoot()
        let provider = Self.provider(cli, clock: clock, root: root)
        let h = try await RAQueueHarness.make(mode: .claude, claude: provider, root: root, clock: clock)
        let a = try await h.insertPaper(title: "a.pdf")
        await h.queue.start()
        await h.queue.enqueue(paperPK: a.pk, hold: false)
        #expect(await raEventually { try await h.job(a.pk).state == .succeeded })
        #expect(cli.printRequests.count == 1)

        try cli.setAuth("auth-status-api-key")
        clock.update { $0 = $0.addingTimeInterval(120) }
        let b = try await h.insertPaper(title: "b.pdf")
        await h.queue.enqueue(paperPK: b.pk, hold: false)
        #expect(await raEventually { try await h.paper(b.pk).aiState == .needsLogin })
        #expect(try await h.job(b.pk).state == .queued)
        #expect(cli.printRequests.count == 1, "paper B reached claude -p under API-key auth")
        #expect(await h.queue.status().provider == .notLoggedIn("non_subscription:api_key"))
        #expect(try await h.paper(b.pk).aiNote == "PaperDeck 只使用订阅登录（当前：api_key）")
        await h.finish()
    }
}
