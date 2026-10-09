import Foundation
import Testing
@testable import PaperDeckCore

/// Google Scholar bylines keep their venue and year (MailCandidate → MailItem).
@Suite struct MailFixesScholarTests {
    private typealias Kit = MailFixesKit

    @Test func scholarEntriesCarryVenueAndYear() throws {
        let content = try MIMEParser.parse(try Kit.fixture("scholar-alert"), maxAttachmentBytes: 1 << 20)
        let entries = AlertParsers.googleScholar(html: try #require(content.html))
        #expect(entries.map(\.venue) == ["bioRxiv", "Nature", "arXiv preprint arXiv:2609.12345", "Cell", "Bioinformatics"])
        #expect(entries.allSatisfy { $0.year == 2026 })
        let x = MailExtractor.extract(content, senderKind: .alert, bodyCap: 0)
        let atlas = try #require(x.candidates.first { $0.title?.hasPrefix("Spatial transcriptomics atlas") == true })
        #expect(atlas.venue == "bioRxiv" && atlas.year == 2026)
    }

    @Test func capturedRowsKeepThem() async throws {
        try await Kit.run(mail: MailSettings(enabled: false, syncMinutes: 0)) { env in
            let file = env.root.appendingPathComponent("scholar.eml")
            try Kit.fixture("scholar-alert").write(to: file)
            let ids = await env.engine.mail.importEML([file])
            let message = try await env.message(try #require(ids.first))
            let rows = try await env.db.mailItems(messagePK: message.pk)
            let nature = try #require(rows.first { $0.ids.doi == "10.1038/s41586-026-01234-5" })
            #expect(nature.venue == "Nature" && nature.year == 2026)
            #expect(rows.filter { $0.origin == .alertEntry }.allSatisfy { $0.year == 2026 && $0.venue != nil })
        }
    }
}

/// The triage lane in `AgentQueueStatus`: queued and running triage are visible ("Analyzing
/// email…") while the paper-queue fields stay what they were (no paper running, nothing queued).
@Suite struct MailFixesTriageStatusTests {
    private typealias Kit = MailFixesKit

    /// Mock-mode provider whose triage answer waits until the test releases it.
    private actor GatedTriage: AgentProvider {
        nonisolated let id = "mock"
        private var waiting: CheckedContinuation<Void, Never>?
        private var open = false
        private(set) var calls = 0

        func detect() async -> ProviderStatus { .ready(plan: "mock", version: "0.0.0-mock", path: "mock") }

        func generateCard(_ r: CardRequest, jobDir: URL) async -> AgentOutcome {
            calls += 1
            if !open { await withCheckedContinuation { waiting = $0 } }
            return .success(card: MockAgentProvider.triage(for: r), meta: RunMeta(
                model: "mock", durationMs: 1, costUSD: 0, inputTokens: 1, outputTokens: 1, numTurns: 1, variant: nil))
        }

        func release() {
            open = true
            waiting?.resume()
            waiting = nil
        }
    }

    private static func job(_ pk: Int64) -> MailTriageJob {
        let stdin = Data("<email>\n{\"from\":\"jsmith@wustl.edu\"}\n\nPlease read [c1].\n</email>\n".utf8)
        return MailTriageJob(messagePK: pk, messageID: UUID().uuidString.lowercased(),
                             request: MailTriageSchema.request(stdin: stdin, model: "haiku", timeout: .seconds(30)),
                             provider: nil)
    }

    private static func status(_ e: EngineEvent) -> AgentQueueStatus? {
        if case .agentStatus(let s) = e { return s }
        return nil
    }

    @Test func queuedAndRunningTriageShowInTheStatus() async throws {
        let gated = GatedTriage()
        try await Kit.run(mode: .mock, mock: gated) { env in
            let queue = env.engine.agents
            await queue.configure(AgentQueue.Tuning(jobTimeout: .seconds(30), testTimeout: .seconds(5),
                                                    maxNap: .milliseconds(50), idleNap: .milliseconds(50),
                                                    loginRecheck: .seconds(1), shutdownWait: .seconds(2),
                                                    detectThrottle: .zero))
            await queue.setTriageHandler { _, _ in }
            defer { Task { await gated.release() } }

            // Not started yet: the job waits — visible as queued.
            var mark = env.events.count
            await queue.enqueueTriage(Self.job(41))
            let queued = await env.events.first(after: mark) { Self.status($0)?.triageQueued == 1 }.flatMap(Self.status)
            #expect(queued?.triageRunning == false && queued?.queued == 0 && queued?.runningPaperID == nil)
            #expect(queued?.triageText(.en) == "1 email waiting for AI analysis")
            #expect(queued?.triageText(.zh) == "1 封邮件待 AI 分析")
            mark = env.events.count
            await queue.cancelTriage(messagePK: 41)
            let cancelled = await env.events.first(after: mark) { Self.status($0)?.triageQueued == 0 }.flatMap(Self.status)
            #expect(cancelled?.triageText(.en) == nil)

            // Running: the slot is busy with an email, not a paper.
            mark = env.events.count
            await queue.enqueueTriage(Self.job(42))
            await queue.start()
            let running = await env.events.first(after: mark) { Self.status($0)?.triageRunning == true }.flatMap(Self.status)
            #expect(running?.runningTriageMessagePK == 42 && running?.triageRunningSince != nil)
            #expect(running?.runningPaperID == nil && running?.queued == 0 && running?.held == 0)
            #expect(running?.triageText(.en) == "Analyzing email…" && running?.triageText(.zh) == "正在分析邮件…")
            #expect(await queue.status().triageRunning)

            mark = env.events.count
            await gated.release()
            let done = await env.events.first(after: mark) {
                guard let s = Self.status($0) else { return false }
                return !s.triageRunning && s.triageQueued == 0
            }
            #expect(done != nil)
            #expect(await gated.calls == 1)
        }
    }

    @Test func statusDefaultsLeaveThePaperQueueAlone() {
        let s = AgentQueueStatus(runningPaperID: "p", queued: 2, held: 1)
        #expect(s.triageQueued == 0 && s.runningTriageMessagePK == nil && !s.triageRunning)
        #expect(s.triageText(.en) == nil)
        #expect(AgentQueueStatus(triageQueued: 3).triageText(.en) == "3 emails waiting for AI analysis")
    }
}
