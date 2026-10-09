import Foundation
import Testing
@testable import PaperDeckCore

/// Helpers of the review-fix A suites (triage gate, dismiss, downloads, merges, settings, DB):
/// engines built like `MailSyncKit.make` but with injectable Claude / Codex stand-ins and a PDF
/// reader that can be held mid-extraction. Zero-quota mocks only — nothing spawns a CLI, opens
/// a mail server or touches the user's library.
enum RFAKit {
    typealias K = MailSyncKit

    /// An engine with `claude` / `codex` / `mock` stand-ins (all MockAgentProvider-like actors).
    static func make(mode: AgentMode, mail: MailSettings = K.mailSettings(), claude: any AgentProvider = MockAgentProvider(),
                     codex: any AgentProvider = MockAgentProvider(), mock: any AgentProvider = MockAgentProvider(),
                     pdf: (any PDFExtracting)? = nil, start: Bool = true) async throws -> K.Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-rfa-\(UUID().uuidString)",
                                                                              isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clock = K.Box(K.start)
        let settings = K.Box(EngineSettings(plan: PlanSettings(dailyBudgetMinutes: 60), lang: .en, agentMode: mode,
                                            metadataLookup: false))
        let mailBox = K.Box(mail)
        let source = K.FakeSource(accountID: "acct-a")
        let deps = Engine.Dependencies(
            loadSettings: { settings.value }, now: { clock.value }, calendar: K.calendar, fetcher: nil,
            claude: claude, codex: codex, mock: mock, sidecarDelay: .milliseconds(10), cliFacts: .inMemory(),
            loadMailSettings: { mailBox.value }, mailSecrets: InMemoryMailSecretStore(),
            mailSources: { account in account.id == "acct-a" ? source : K.FakeSource(accountID: account.id) },
            mailPDFExtractor: pdf, hostGate: HostGate(clock: K.VirtualClock()), assistBackends: [MockAssistBackend()])
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: deps)
        await engine.agents.configure(AgentQueue.Tuning(jobTimeout: .seconds(5), testTimeout: .seconds(5),
                                                        maxNap: .seconds(1), idleNap: .seconds(1),
                                                        loginRecheck: .seconds(1), shutdownWait: .seconds(2),
                                                        detectThrottle: .zero))
        if start { await engine.start() }
        return K.Env(engine: engine, root: root, clock: clock, settings: settings, mail: mailBox,
                     sources: ["acct-a": source])
    }

    static func run(mode: AgentMode, mail: MailSettings = K.mailSettings(), claude: any AgentProvider = MockAgentProvider(),
                    codex: any AgentProvider = MockAgentProvider(), mock: any AgentProvider = MockAgentProvider(),
                    pdf: (any PDFExtracting)? = nil, _ body: (K.Env) async throws -> Void) async throws {
        let env = try await make(mode: mode, mail: mail, claude: claude, codex: codex, mock: mock, pdf: pdf)
        do { try await body(env) } catch {
            await env.cleanup()
            throw error
        }
        await env.cleanup()
    }

    /// A distinct copy of the bioRxiv alert fixture.
    static func alert(_ n: Int) throws -> Data {
        try K.variant("biorxiv-alert", messageID: "<alert-\(n)@alerts.highwire.org>")
    }

    static func alertID(_ n: Int) -> String { "<alert-\(n)@alerts.highwire.org>" }

    static func triageState(_ env: K.Env, _ mid: String) async -> MailTriageState? {
        try? await env.db.mailMessage(internetMessageID: mid)?.triageState
    }

    /// An alert row as the capture leaves it (`queued`, never handed off: no stdin size) or as a
    /// hand-off leaves it (`stdinBytes` set).
    @discardableResult
    static func insertAlert(_ env: K.Env, _ n: Int, state: MailTriageState = .queued, stdinBytes: Int? = nil,
                            ruleID: String = K.biorxivRule.id) async throws -> MailMessage {
        let msg = MailMessage(accountID: "acct-a", internetMessageID: alertID(n),
                              fromAddress: "biorxiv@alerts.highwire.org", ruleID: ruleID, senderKind: .alert,
                              subject: "bioRxiv alert \(n)", receivedAt: K.start, bodyText: "New results [c1 biorxiv.org]",
                              triageState: state, triageStdinBytes: stdinBytes, createdAt: K.start, updatedAt: K.start)
        let item = MailItem(ord: 1, cand: "c1", origin: .alertEntry, title: "Spatial atlas \(n)",
                            ids: PaperIDs(doi: "10.1101/2026.09.2\(n).61412\(n)"), pdfState: .downloadable)
        return try await env.db.insertMailMessage(msg, items: [item]).0
    }

    /// Today's (2026-09-30) triage record, as the coordinator stores it.
    static func setDayRecord(_ env: K.Env, day: String = "2026-09-30", n: Int, open: [Int64]) async throws {
        let list = open.map(String.init).joined(separator: ",")
        try await env.db.setKV(MailTriageCoordinator.dayKey, #"{"day":""# + day + #"","n":\#(n),"open":["# + list + "]}")
    }

    static func updateRule(_ env: K.Env, _ id: String, _ change: (inout SenderRule) -> Void) {
        env.mail.update { s in
            guard let i = s.senders.firstIndex(where: { $0.id == id }) else { return }
            change(&s.senders[i])
        }
    }

    /// A PDF reader that can be held inside `extract` (to act while a triage job is being built).
    final class GatedPDF: PDFExtracting, @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private var entered = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func arm() { lock.withLock { armed = true } }
        var enteredWhileArmed: Int { lock.withLock { entered } }

        func release() {
            let w = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                armed = false
                defer { waiters = [] }
                return waiters
            }
            for c in w { c.resume() }
        }

        func extract(url: URL, fileName: String) async throws -> ExtractedPDF {
            let hold = lock.withLock { () -> Bool in
                if armed { entered += 1 }
                return armed
            }
            if hold {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    let resumeNow = lock.withLock { () -> Bool in
                        guard armed else { return true }
                        waiters.append(c)
                        return false
                    }
                    if resumeNow { c.resume() }
                }
            }
            let title = "Cortical progenitor dynamics in the developing human brain"
            return ExtractedPDF(pageCount: 3, pageTexts: ["\(title)\nAbstract\nWe study cortex.", "p2", "p3"],
                                charCount: 900, isEncrypted: false, isLocked: false, isScanned: false,
                                attributeTitle: nil, attributeAuthor: nil, fontTitle: title, ids: PaperIDs(),
                                structure: DocumentStructure(), cardThumbnailJPEG: nil)
        }
    }
}
