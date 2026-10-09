import Foundation
import Testing
@testable import PaperDeckCore

/// What the Mail panel reads from the engine: a dropped .eml becomes a pending card in the
/// snapshot with rows the inbox rules can act on, and 「发送给 AI 的内容」 (`previewJob`) shows the
/// exact triage stdin without enqueuing, counting or spawning anything. Zero quota: every
/// provider is a mock, agent.mode is off, no network, no real library, no Keychain.
@Suite(.serialized) struct MailUITriagePreviewTests {
    private final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private struct Env {
        let engine: Engine
        let root: URL
        let mail: Box<MailSettings>
        let mock: MockAgentProvider
    }

    private static let advisor = SenderRule(id: "rule-advisor-ui", pattern: "jsmith@wustl.edu", label: "Prof. Smith",
                                            kind: .advisor)

    private static func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "eml", subdirectory: "Fixtures/mail/mail-sync"))
    }

    private static func withEngine(senders: [SenderRule] = [advisor], aiMode: MailSettings.AIMode = .ai,
                                   _ body: (Env) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-mailui-\(UUID().uuidString)",
                                                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let calendar = LocalDate.gregorian(TimeZone(identifier: "America/Chicago")!)
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 10))!
        let settings = EngineSettings(plan: PlanSettings(dailyBudgetMinutes: 60), lang: .en, agentMode: .off,
                                      metadataLookup: false)
        let mail = Box(MailSettings(enabled: false, senders: senders, syncMinutes: 0, aiMode: aiMode))
        let mock = MockAgentProvider()
        let deps = Engine.Dependencies(loadSettings: { settings }, now: { now }, calendar: calendar, fetcher: nil,
                                       claude: MockAgentProvider(), codex: MockAgentProvider(), mock: mock,
                                       sidecarDelay: .milliseconds(10), cliFacts: .inMemory(),
                                       loadMailSettings: { mail.value }, mailSecrets: InMemoryMailSecretStore(), assistBackends: [MockAssistBackend()])
        // Not started: import, post-processing, snapshots and card operations need no launch
        // maintenance, agent loop or sync loop (and the suite stays light next to timing tests).
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: deps)
        let env = Env(engine: engine, root: root, mail: mail, mock: mock)
        do {
            try await body(env)
        } catch {
            await Self.cleanup(env)
            throw error
        }
        await Self.cleanup(env)
    }

    private static func cleanup(_ env: Env) async {
        await env.engine.shutdown()
        await env.engine.db.close()
        try? FileManager.default.removeItem(at: env.root)
    }

    private static func importAdvisorMail(_ env: Env) async throws -> String {
        let ids = await env.engine.mail.importEML([try fixture("advisor-request-pdf")])
        await env.engine.mail.waitUntilIdle()
        return try #require(ids.first)
    }

    @Test func droppedEmailBecomesAPendingCardTheInboxCanAct() async throws {
        try await Self.withEngine { env in
            let id = try await Self.importAdvisorMail(env)
            let snap = try await env.engine.mailSnapshot()
            let card = try #require(snap.card(id: id))
            #expect(card.filter == .pending)
            #expect(snap.cards(.pending).contains { $0.id == id })
            #expect(snap.counts.pending >= 1)
            #expect(card.rule?.id == Self.advisor.id)
            #expect(card.message.senderKind == .advisor)
            // Person sender with the default "ask" policy: 「让 AI 分析」 is offered, nothing was sent.
            #expect(card.message.triageState == .awaitingConsent)
            #expect(card.canRequestAI)
            #expect(card.message.triageSource != .ai)
            // The attached PDF is a row the user can merge right away; 全部合并 counts it.
            let attachment = try #require(card.items.first { $0.origin == .attachment })
            #expect(MailInboxRules.chip(attachment) == .attachment)
            #expect(MailInboxRules.actions(attachment).contains(.merge))
            #expect(MailInboxRules.mergeAllCount(card.items) >= 1)
            #expect(MailInboxRules.requestBadge(card.message) != nil || card.message.triage == nil)
            // Deep links reach it by id.
            #expect(try await env.engine.mailCard(id: id.uppercased())?.id == id)
            #expect(await env.mock.calls == 0)
        }
    }

    @Test func previewIsTheExactTriageRequestWithoutSendingOrCounting() async throws {
        try await Self.withEngine { env in
            let id = try await Self.importAdvisorMail(env)
            let before = try #require(try await env.engine.db.mailMessage(id: id))
            let usageBefore = await env.engine.mailTriage.usage()

            let job = try #require(try await env.engine.mailTriage.previewJob(messageID: id))
            let stdin = String(decoding: job.request.stdin, as: UTF8.self)
            #expect(job.messageID == id)
            #expect(stdin.contains("<email>") && stdin.contains("</email>"))
            #expect(stdin.contains("<candidates>"))
            #expect(stdin.contains("Paper for Thursday"))
            #expect(stdin.contains("jsmith@wustl.edu"))
            // Wrapped / tracking URLs and other addresses never go out.
            #expect(!stdin.contains("utm_source"))
            #expect(!stdin.contains("lab.manager@wustl.edu"))
            #expect(MailTriageSchema.isTriageRequest(job.request))
            #expect(job.request.model == "haiku")

            // Nothing was enqueued, counted, spawned or written back.
            #expect(await env.engine.mailTriage.usage() == usageBefore)
            #expect(await env.engine.agents.triageStatus().queued == 0)
            #expect(await env.mock.calls == 0)
            let after = try #require(try await env.engine.db.mailMessage(id: id))
            #expect(after.triageState == before.triageState)
            #expect(after.triageStdinBytes == before.triageStdinBytes)
            #expect(after.userTouched == before.userTouched)

            // Same input → same bytes (what 「让 AI 分析」 would really send).
            let again = try #require(try await env.engine.mailTriage.previewJob(messageID: id))
            #expect(again.request.stdin == job.request.stdin)
            #expect(try await env.engine.mailTriage.previewJob(messageID: UUID().uuidString.lowercased()) == nil)
        }
    }

    @Test func previewRefusesWhatMayNeverBeSent() async throws {
        try await Self.withEngine(aiMode: .heuristicOnly) { env in
            let id = try await Self.importAdvisorMail(env)
            await #expect(throws: MailTriageError.aiDisabled) {
                _ = try await env.engine.mailTriage.previewJob(messageID: id)
            }
        }
        var never = Self.advisor
        never.aiPolicy = .never
        try await Self.withEngine(senders: [never]) { env in
            let id = try await Self.importAdvisorMail(env)
            await #expect(throws: MailTriageError.senderNever) {
                _ = try await env.engine.mailTriage.previewJob(messageID: id)
            }
            let card = try #require(try await env.engine.mailCard(id: id))
            #expect(!card.canRequestAI)
            #expect(await env.mock.calls == 0)
        }
    }

    @Test func cardActionsMoveTheCardBetweenFilters() async throws {
        try await Self.withEngine { env in
            let id = try await Self.importAdvisorMail(env)
            let until = Date(timeIntervalSince1970: 1_800_000_000)     // 2027-01-15, after the fixed clock
            try await env.engine.snoozeMail(messageID: id, until: until)
            var snap = try await env.engine.mailSnapshot()
            #expect(snap.card(id: id)?.filter == .snoozed)
            #expect(snap.cards(.snoozed).contains { $0.id == id })
            #expect(snap.counts.snoozed == 1)

            try await env.engine.dismissMail(messageID: id)
            snap = try await env.engine.mailSnapshot()
            #expect(snap.card(id: id)?.filter == .dismissed)
            #expect(!snap.cards(.pending).contains { $0.id == id })

            try await env.engine.reopenMail(messageID: id)
            snap = try await env.engine.mailSnapshot()
            #expect(snap.card(id: id)?.filter == .pending)
            #expect(snap.card(id: id)?.message.userTouched == true)

            // Skipping every target row completes the card (已处理).
            let card = try #require(snap.card(id: id))
            for item in MailMergeState.targetItems(card.items) where item.status == .pending {
                try await env.engine.skipMailItem(itemID: item.id)
            }
            snap = try await env.engine.mailSnapshot()
            #expect(snap.card(id: id)?.filter == .handled)
            #expect(snap.card(id: id).map { MailInboxRules.mergeAllCount($0.items) } == 0)
        }
    }
}
