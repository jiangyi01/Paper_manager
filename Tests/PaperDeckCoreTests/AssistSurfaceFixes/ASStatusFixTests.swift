import Foundation
import Testing
@testable import PaperDeckCore

/// assist-surfaces-7: today's count reaches the Explain / Ask footers without waiting for a turn —
/// at launch (the counts restored from kv), after a provider or cap change and after a day change
/// (`AssistLane.publishSnapshot`, which never detects or spawns anything). Scripted backends only.
@Suite(.timeLimit(.minutes(1))) struct ASStatusFixTests {
    final class Statuses: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [AssistStatus] = []
        func add(_ s: AssistStatus) { lock.withLock { seen.append(s) } }
        var all: [AssistStatus] { lock.withLock { seen } }
    }

    /// A relaunch: 7 Claude turns already counted today. Starting the engine publishes them.
    @Test func launchPublishesTodaysRestoredCount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-as-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = ScriptedBackend(mode: .claude)
        var s = EngineSettings(agentMode: .off, metadataLookup: false)
        s.assist.mode = .claude
        s.assist.dailySoftCap = 50
        let settings = s
        let now = Date()
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: Engine.Dependencies(
            loadSettings: { settings }, now: { now }, fetcher: nil, claude: MockAgentProvider(behavior: .notLoggedIn),
            codex: MockAgentProvider(behavior: .notLoggedIn), cliFacts: .inMemory(),
            loadMailSettings: { MailSettings() }, mailSecrets: InMemoryMailSecretStore(), assistBackends: [backend]))
        let counter = engine.assistGate.counter
        try await engine.db.setCounterKV(counter.key(day: counter.day(now), provider: AIProviderKind.claude.rawValue), 7)

        let seen = Statuses()
        let events = engine.events.subscribe()
        let listener = Task { for await e in events { if case .assistStatus(let st) = e { seen.add(st) } } }
        await engine.start()
        let published = await assistEventually(.seconds(5)) { seen.all.contains { $0.todayCount == 7 } }
        #expect(published, "no status after launch: \(seen.all)")
        let status = try #require(seen.all.last)
        #expect(status.mode == .claude && status.todayCount == 7 && status.softCap == 50 && !status.busy)
        #expect(await backend.detections == 0, "a snapshot detects nothing")
        #expect(await backend.turns == 0)
        listener.cancel()
        await engine.shutdown()
    }

    /// Another provider, another cap, another day: `publishSnapshot` sends the status as it is now.
    @Test func aSnapshotFollowsTheModeTheCapAndTheDay() async throws {
        let claude = ScriptedBackend(mode: .claude)
        let codex = ScriptedBackend(mode: .codex)
        let box = SettingsBox(.claude)
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var t = Date(timeIntervalSince1970: 1_790_000_000)
            var now: Date { lock.withLock { t } }
            func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
        }
        let clock = Clock()
        let counter = AssistDailyCounter(calendar: Calendar(identifier: .gregorian))
        let gate = AssistGate(budget: RunBudget(), load: { box.value }, pause: { _ in nil }, counter: counter)
        let lane = AssistLane(gate: gate, load: { box.value }, now: { clock.now }, backends: [claude, codex])
        let seen = Statuses()
        await lane.setStatusSink { seen.add($0) }

        _ = await collectEvents(await lane.submit(assistRequest(), ticket: .mint(.box, surface: .explain, now: clock.now)))
        #expect(seen.all.last?.todayCount == 1 && seen.all.last?.mode == .claude)

        box.update { $0.assist.mode = .codex }
        await lane.publishSnapshot()
        #expect(seen.all.last?.mode == .codex && seen.all.last?.todayCount == 0, "the new provider's own count")

        box.update { $0.assist.mode = .claude; $0.assist.dailySoftCap = 30 }
        await lane.publishSnapshot()
        #expect(seen.all.last?.mode == .claude && seen.all.last?.todayCount == 1 && seen.all.last?.softCap == 30)

        clock.advance(2 * 24 * 3600)                                     // a later day
        await lane.publishSnapshot()
        #expect(seen.all.last?.todayCount == 0, "yesterday's count is not today's")
        #expect(await claude.detections == 0)
        #expect(await codex.detections == 0)
        #expect(await claude.turns == 1)
        #expect(await codex.turns == 0)
    }
}
