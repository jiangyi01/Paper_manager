import Foundation
import Testing
@testable import PaperDeckCore

/// Finding 10: the learned argv variant is a fact about the installed CLI (§3.1: UserDefaults
/// `agent.claude.argvVariant` / `…argvVariantCLIVersion`), not library state; it was kept in the
/// library DB kv. Finding 11: the CLI path override was read once at Engine.open.
@Suite(.serialized) struct RegressionCLIFactsTests {
    private static func request() -> CardRequest {
        CardRequest(schema: CardSchema.schema(categories: PaperCategory.starters.map(\.name)),
                    stdin: CardSchema.stdin(metadata: nil, pageCount: 3, categories: [], frequentTags: [],
                                            paperText: "[[p. 1]]\nA paper"))
    }

    /// A variant-B success through the real provider (fake runner) lands in the CLI facts, not in kv.
    @Test func learnedVariantIsPersistedAsACLIFact() async throws {
        let cli = try RAFakeCLI(replies: ["envelope-success-null-structured", "envelope-success"])
        let root = try RAQueueHarness.newRoot()
        let provider = ClaudeCodeProvider(locator: RAFakeCLI.locator(), agentCwd: root.appendingPathComponent("cwd"),
                                          runner: cli.runner, parentEnvironment: { [:] })
        let h = try await RAQueueHarness.make(mode: .claude, claude: provider, root: root)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.queue.start()
        #expect(await raEventually { try await h.job(p.pk).state == .succeeded })
        #expect(await raEventually { h.cliFacts.string(forKey: AgentQueue.variantKey) == "B" })
        #expect(h.cliFacts.string(forKey: AgentQueue.variantCLIVersionKey) == "2.1.284")
        #expect(try await h.db.kv(AgentQueue.variantKey) == nil)
        #expect(try await h.db.kv(AgentQueue.variantCLIVersionKey) == nil)
        await h.finish()
    }

    /// A second library (new DB) on the same Mac starts with the learned variant; a CLI update
    /// (another version) falls back to A.
    @Test func learnedVariantFollowsTheMachineNotTheLibrary() async throws {
        let facts = CLIFactStore.inMemory()
        facts.set("B", forKey: AgentQueue.variantKey)
        facts.set("2.1.284", forKey: AgentQueue.variantCLIVersionKey)
        let cli = try RAFakeCLI(replies: ["envelope-success"])
        let root = try RAQueueHarness.newRoot()
        let provider = ClaudeCodeProvider(locator: RAFakeCLI.locator(), agentCwd: root.appendingPathComponent("cwd"),
                                          runner: cli.runner, parentEnvironment: { [:] })
        let h = try await RAQueueHarness.make(mode: .claude, claude: provider, root: root, cliFacts: facts)
        let p = try await h.insertPaper()
        await h.queue.enqueue(paperPK: p.pk, hold: false)
        await h.queue.start()
        #expect(await raEventually { try await h.job(p.pk).state == .succeeded })
        let spawn = try #require(cli.printRequests.first)
        #expect(spawn.arguments.contains("--disallowedTools") && cli.printRequests.count == 1)
        #expect(await provider.preferredVariant(for: "2.1.300") == .a)      // per-CLI-version invalidation
        await h.finish()
    }

    /// Libraries from older builds kept the variant in kv: it moves to the CLI facts once.
    @Test func variantInLibraryKVIsMigrated() async throws {
        let fake = RAScriptedProvider()
        let h = try await RAQueueHarness.make(mode: .off, claude: fake)
        try await h.db.setKV(AgentQueue.variantKey, "B")
        try await h.db.setKV(AgentQueue.variantCLIVersionKey, "2.1.1")
        await h.queue.start()
        #expect(h.cliFacts.string(forKey: AgentQueue.variantKey) == "B")
        #expect(h.cliFacts.string(forKey: AgentQueue.variantCLIVersionKey) == "2.1.1")
        #expect(try await h.db.kv(AgentQueue.variantKey) == nil)
        #expect(try await h.db.kv(AgentQueue.variantCLIVersionKey) == nil)
        await h.finish()
    }

    /// The UserDefaults-backed store (what the app uses) reads and removes keys.
    @Test func userDefaultsBackedStore() {
        let scratch = ScratchDefaults("regression-clifacts")
        defer { scratch.drop() }
        let defaults = scratch.defaults
        let store = CLIFactStore(defaults: defaults)
        store.set("B", forKey: AgentQueue.variantKey)
        #expect(defaults.string(forKey: AgentQueue.variantKey) == "B")
        #expect(store.string(forKey: AgentQueue.variantKey) == "B")
        store.set(nil, forKey: AgentQueue.variantKey)
        #expect(defaults.object(forKey: AgentQueue.variantKey) == nil)
        #expect(Engine.Dependencies(fetcher: nil).cliFacts === CLIFactStore.standard)
    }

    // MARK: 11 — CLI path override

    private static func probe(valid: Set<String>, versions: RABox<[String]>) -> BinaryLocator.Probe {
        BinaryLocator.Probe(isExecutable: { valid.contains($0) },
                            versionOutput: { path in versions.update { $0.append(path) }; return "2.1.284 (Claude Code)\n" },
                            loginShellLookup: { nil }, listDirectory: { _ in [] })
    }

    @Test func liveOverrideIsReadOnEveryResolve() async throws {
        let setting = RABox<String?>("/opt/a/claude")
        let probed = RABox<[String]>([])
        let locator = BinaryLocator(home: "/nonexistent-home", overrideSource: { setting.value },
                                    probe: Self.probe(valid: ["/opt/a/claude", "/opt/b/claude"], versions: probed))
        #expect(await locator.locate()?.path == "/opt/a/claude")
        #expect(await locator.locate()?.path == "/opt/a/claude")           // cached
        setting.value = "/opt/b/claude"                                    // Settings ▸ AI changed it
        #expect(await locator.locate()?.path == "/opt/b/claude")
        setting.value = "  "                                               // cleared → normal resolution
        #expect(await locator.locate() == nil)                             // no well-known path is valid here
        setting.value = "/opt/a/claude"
        #expect(await locator.currentOverride() == "/opt/a/claude")
        #expect(await locator.locate()?.path == "/opt/a/claude")
        #expect(probed.value.filter { $0 == "/opt/b/claude" }.count == 1)
    }

    /// The engine-built locator follows the settings (nothing is resolved or spawned here).
    @Test func engineLocatorFollowsTheSettings() async throws {
        let h = try await RAQueueHarness.make(mode: .off, claude: nil, adjust: { $0.cliPathOverride = "/opt/a/claude" })
        let locator = try #require(h.engine.binaryLocator)
        #expect(await locator.currentOverride() == "/opt/a/claude")
        h.settings.update { $0.cliPathOverride = "/opt/b/claude" }
        #expect(await locator.currentOverride() == "/opt/b/claude")
        await h.finish()
    }

    /// The queue notices a changed path on its next pass and re-detects at once (the throttle
    /// would otherwise keep a stale "ready"/"not installed"); `cliPathOverrideDidChange()` wakes it.
    @Test func changedPathTriggersADetect() async throws {
        let fake = RAScriptedProvider()
        var tuning = AgentQueue.Tuning.raFast
        tuning.detectThrottle = .seconds(3600)
        let h = try await RAQueueHarness.make(mode: .claude, claude: fake, tuning: tuning)
        await h.queue.start()
        #expect(await raEventually { await fake.detectCalls == 1 })
        try await Task.sleep(for: .milliseconds(150))
        #expect(await fake.detectCalls == 1)
        h.settings.update { $0.cliPathOverride = "/opt/b/claude" }
        await h.engine.cliPathOverrideDidChange()
        #expect(await raEventually { await fake.detectCalls == 2 })
        h.settings.update { $0.cliPathOverride = "/opt/c/claude" }       // no explicit call: next pass notices
        #expect(await raEventually { await fake.detectCalls == 3 })
        await h.finish()
    }
}
