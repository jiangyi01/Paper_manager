import Foundation
import Testing
@testable import PaperDeckCore

/// The open flake R3PostProcessTests.aQueuedRowWithoutHandOffOrMarkerOffersAIAfterAPass (failed at
/// "alert 5 → none"): the engine's first sync pass runs while the test builds its fixture, and its
/// triage tick read the mail settings *before* the test added the `never` sender but the rows
/// *after* alert 5 was inserted under it — "rule unknown → ask" refused alert 5 to
/// `awaitingConsent`, and no later pass revisits a refused row. The coordinator now judges every
/// row against settings read after the row (`withdrawDisallowed`). Replayed deterministically:
/// the tick's own settings read returns the stale snapshot once. Zero-quota mock provider.
///
/// Only the test's own tick may take the stale snapshot (`Settings.$inReplayedTick`, a task-local
/// bound around that one call): the engine's background passes (the mail loop's maintenance tick,
/// an agent-status mode switch) run in their own tasks and always read current settings. Before,
/// the next reader of any task took it — a background tick already past its top-of-tick read took
/// it at its after-the-rows read and refused both rows (portability verification regression #1:
/// one failure in ~41 full runs, C20).
@Suite(.serialized) struct PFTriageSnapshotTests {
    typealias K = MailSyncKit

    /// The mail settings closure of the engine: the current box value, except that `armStale`
    /// makes the next read *inside the replayed tick* (`$inReplayedTick`) return an older snapshot
    /// (what a tick that read before an edit holds). Reads from any other task get the current value.
    final class Settings: @unchecked Sendable {
        /// Bound to true only around the test's own `tick()` call (the engine's tasks never inherit it).
        @TaskLocal static var inReplayedTick = false
        private let lock = NSLock()
        private var current: MailSettings
        private var stale: MailSettings?
        private(set) var staleServed = 0
        /// Reads outside the replayed tick while the stale snapshot was armed (they got current settings).
        private(set) var otherReadsWhileArmed = 0
        init(_ s: MailSettings) { current = s }
        func set(_ s: MailSettings) { lock.withLock { current = s } }
        func armStale(_ s: MailSettings) { lock.withLock { stale = s } }
        func read() -> MailSettings {
            let mine = Self.inReplayedTick
            return lock.withLock {
                if let s = stale {
                    if mine { stale = nil; staleServed += 1; return s }
                    otherReadsWhileArmed += 1
                }
                return current
            }
        }
    }

    static func make(_ box: Settings) async throws -> (Engine, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-pf-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clock = K.Box(K.start)
        let settings = K.Box(EngineSettings(plan: PlanSettings(dailyBudgetMinutes: 60), lang: .en, agentMode: .mock,
                                            metadataLookup: false))
        let source = K.FakeSource(accountID: "acct-a")
        let deps = Engine.Dependencies(
            loadSettings: { settings.value }, now: { clock.value }, calendar: K.calendar, fetcher: nil,
            claude: MockAgentProvider(), codex: MockAgentProvider(), mock: MockAgentProvider(), sidecarDelay: .milliseconds(10),
            cliFacts: .inMemory(), loadMailSettings: { box.read() }, mailSecrets: InMemoryMailSecretStore(),
            mailSources: { account in account.id == "acct-a" ? source : K.FakeSource(accountID: account.id) },
            hostGate: HostGate(clock: K.VirtualClock()), assistBackends: [MockAssistBackend()])
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: deps)
        await engine.agents.configure(AgentQueue.Tuning(jobTimeout: .seconds(5), testTimeout: .seconds(5),
                                                        maxNap: .seconds(1), idleNap: .seconds(1),
                                                        loginRecheck: .seconds(1), shutdownWait: .seconds(2),
                                                        detectThrottle: .zero))
        await engine.start()
        await engine.mail.syncNow()                         // the startup pass is over
        return (engine, root)
    }

    static func insert(_ engine: Engine, _ n: Int, ruleID: String) async throws -> MailMessage {
        let msg = MailMessage(accountID: "acct-a", internetMessageID: "<pf-snap-\(n)@example.org>",
                              fromAddress: "news@example.org", ruleID: ruleID, senderKind: .alert,
                              subject: "Alert \(n)", receivedAt: K.start, bodyText: "New results [c1 biorxiv.org]",
                              triageState: .queued, createdAt: K.start, updatedAt: K.start)
        let item = MailItem(ord: 1, cand: "c1", origin: .alertEntry, title: "Spatial atlas \(n)",
                            ids: PaperIDs(doi: "10.1101/2026.09.2\(n).61412\(n)"), pdfState: .downloadable)
        return try await engine.db.insertMailMessage(msg, items: [item]).0
    }

    @Test func aTickHoldingOlderSettingsJudgesNewRowsWithTheCurrentOnes() async throws {
        let before = K.mailSettings()
        let box = Settings(before)
        let (engine, root) = try await Self.make(box)
        do { try await Self.replay(engine, box, before: before) } catch {
            await Self.close(engine, root)
            throw error
        }
        await Self.close(engine, root)
    }

    /// The harness itself (regression #1): while the stale snapshot is armed, a read from any other
    /// task — what a background tick does — gets the current settings and leaves the snapshot for
    /// the replayed tick, which takes it exactly once.
    @Test func onlyTheReplayedTickTakesTheStaleSnapshot() async {
        let before = K.mailSettings()
        var after = before
        after.senders.append(SenderRule(id: "rule-x", pattern: "@x.example", kind: .alert))
        let box = Settings(after)
        box.armStale(before)
        let background = await Task.detached { box.read() }.value               // another task, mid-tick
        let unbound = await Task { box.read() }.value                           // a task of the test's own, unbound
        #expect(background == after && unbound == after)
        #expect(box.staleServed == 0 && box.otherReadsWhileArmed == 2)
        let replayed = Settings.$inReplayedTick.withValue(true) { box.read() }
        let again = Settings.$inReplayedTick.withValue(true) { box.read() }
        #expect(replayed == before && again == after && box.staleServed == 1)
    }

    static func close(_ engine: Engine, _ root: URL) async {
        await engine.shutdown()
        await engine.db.close()
        try? FileManager.default.removeItem(at: root)
    }

    static func replay(_ engine: Engine, _ box: Settings, before: MailSettings) async throws {
        // The user adds two senders; emails are captured under them right away (queued, no hand-off).
        let never = SenderRule(id: "rule-never", pattern: "@never.example", label: "Never", kind: .alert, aiPolicy: .never)
        let always = SenderRule(id: "rule-always", pattern: "@always.example", label: "Always", kind: .alert, aiPolicy: .always)
        var after = before
        after.senders += [never, always]
        box.set(after)
        let silent = try await Self.insert(engine, 1, ruleID: never.id)
        let allowed = try await Self.insert(engine, 2, ruleID: always.id)
        // A tick whose own settings read predates the edit (only this tick can take the snapshot).
        box.armStale(before)
        await Settings.$inReplayedTick.withValue(true) { await engine.mailTriage.tick() }
        #expect(box.staleServed == 1)
        #expect(try await engine.db.mailMessage(pk: silent.pk)?.triageState == MailTriageState.none)   // never → none
        #expect(try await engine.db.mailMessage(pk: allowed.pk)?.triageState == .queued)               // not asked again
    }
}
