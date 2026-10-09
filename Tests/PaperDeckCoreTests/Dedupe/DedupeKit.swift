import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import PaperDeckCore

// Harness of the duplicate-check suites (Slice B). Everything runs in a temp root through the
// engine's own intake / enrich actors (so `Engine.resolveDuplicate` sees the parked files),
// with real generated PDFs (PDFKit extracts their title and DOI), a fixed clock, an injected
// Trash, and either no metadata transport or a scripted one. Nothing reaches the network or a CLI.

enum DedupeKit {
    /// Tuesday 2026-09-29 10:00 in Chicago.
    static let start = Date(timeIntervalSince1970: 1_790_694_000)
    static let calendar = LocalDate.gregorian(TimeZone(identifier: "America/Chicago")!)

    static func settings(dedupe: DedupeSettings = DedupeSettings(), lang: UILang = .en, lookup: Bool = false,
                         agentMode: AgentMode = .off) -> EngineSettings {
        EngineSettings(plan: PlanSettings(dailyBudgetMinutes: 60), lang: lang, agentMode: agentMode, autoReadNewPapers: true,
                       metadataLookup: lookup, dedupe: dedupe)
    }

    /// Engine settings the test can change while the engine runs.
    final class Settings: @unchecked Sendable {
        private let lock = NSLock()
        private var s: EngineSettings
        init(_ s: EngineSettings) { self.s = s }
        var value: EngineSettings {
            get { lock.withLock { s } }
            set { lock.withLock { s = newValue } }
        }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: Date
        init(_ t: Date) { self.t = t }
        var now: Date {
            get { lock.withLock { t } }
            set { lock.withLock { t = newValue } }
        }
    }

    final class InstantGateClock: HostGate.Clock, @unchecked Sendable {
        private let lock = NSLock()
        private var t: TimeInterval = 10_000
        func now() -> TimeInterval { lock.withLock { t } }
        func sleep(seconds: TimeInterval) async throws {
            try Task.checkCancellation()
            lock.withLock { t += max(0, seconds) }
        }
    }

    /// Scripted metadata transport: URL prefix → (status, JSON body). Everything else is a 404.
    struct Fetcher: HTTPFetching {
        var routes: [(prefix: String, status: Int, body: String)] = []
        func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResult {
            let s = url.absoluteString
            for r in routes where s.hasPrefix(r.prefix) { return HTTPResult(status: r.status, body: Data(r.body.utf8)) }
            return HTTPResult(status: 404, body: Data())
        }
    }

    /// Every engine event, in order; `drain()` waits until what was sent so far arrived.
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [EngineEvent] = []
        private var task: Task<Void, Never>?
        private let hub: EventHub<EngineEvent>

        init(hub: EventHub<EngineEvent>) {
            self.hub = hub
            let stream = hub.subscribe()
            task = Task { [weak self] in for await e in stream { self?.append(e) } }
        }
        deinit { task?.cancel() }
        private func append(_ e: EngineEvent) { lock.withLock { items.append(e) } }

        func drain() async {
            let marker = "sentinel-" + UUID().uuidString
            hub.send(.toast(Toast(id: marker, kind: .info, message: marker)))
            for _ in 0..<1_000 {
                let seen = lock.withLock { items.contains { if case .toast(let t) = $0 { return t.id == marker }; return false } }
                if seen { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        var all: [EngineEvent] { lock.withLock { items } }
        var toasts: [Toast] {
            lock.withLock { items.compactMap { if case .toast(let t) = $0, !t.id.hasPrefix("sentinel-") { return t }; return nil } }
        }
        var notices: [DedupeNotice] {
            lock.withLock { items.compactMap { if case .dedupe(let n) = $0 { return n }; return nil } }
        }
        func clear() { lock.withLock { items.removeAll() } }
    }

    final class Trash: @unchecked Sendable {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pd-dedupe-trash-\(UUID().uuidString)")
        var function: @Sendable (URL) -> Bool {
            { [directory] url in
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return rename(url.path, directory.appendingPathComponent(UUID().uuidString).path) == 0
            }
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    struct Env {
        let root: URL
        let downloads: URL
        let engine: Engine
        let events: Events
        let clock: Clock
        let settings: Settings
        let trash = Trash()

        var db: Database { engine.db }
        var ctx: EngineContext { engine.ctx }

        /// Ingest through the engine's intake and wait for enrichment and every event.
        @discardableResult
        func ingest(_ urls: [URL], origin: ImportOrigin = .drop, annotations: [URL: ImportAnnotation] = [:]) async -> ImportBatchSummary {
            let summary = await engine.intake.ingest(urls.map { .file($0) },
                                                     options: ImportOptions(origin: origin, annotations: annotations))
            await settle()
            return summary
        }

        func settle() async {
            await engine.enrich.waitUntilIdle()
            await ctx.sidecars.flush()
            await events.drain()
        }

        /// A real PDF in ~/Downloads of the scratch root.
        func pdf(_ name: String, title: String, doi: String? = nil, body: String? = nil, pages: Int = 3,
                 author: String? = nil, tag: String = String(Int.random(in: 100_000...999_999_999))) throws -> URL {
            let url = downloads.appendingPathComponent(name)
            try DedupeKit.pdfData(title: title, doi: doi, body: body ?? DedupeKit.body(seed: name), pages: pages,
                                  author: author, tag: tag).write(to: url)
            return url
        }

        func paper(_ id: String) async throws -> Paper { try #require(try await db.paper(id: id)) }

        func onlyOpenReview() async throws -> DupReview {
            let open = try await db.dupReviews(state: .open)
            #expect(open.count == 1, "\(open)")
            return try #require(open.first)
        }

        func cleanup() async {
            await engine.shutdown()
            await db.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// `assist`: the mock assist backend the engine's lane gets (a scripted one for the AI judge).
    static func make(_ s: EngineSettings = DedupeKit.settings(), fetcher: (any HTTPFetching)? = nil,
                     assist: MockAssistBackend = MockAssistBackend()) async throws -> Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-dedupe-\(UUID().uuidString)", isDirectory: true)
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let box = Settings(s)
        let clock = Clock(start)
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: Engine.Dependencies(
            loadSettings: { box.value }, now: { clock.now }, calendar: calendar, fetcher: fetcher,
            claude: MockAgentProvider(behavior: .notLoggedIn), codex: MockAgentProvider(behavior: .notLoggedIn),
            sidecarDelay: .milliseconds(5), cliFacts: .inMemory(), loadMailSettings: { MailSettings() },
            mailSecrets: InMemoryMailSecretStore(), hostGate: HostGate(clock: InstantGateClock()),
            assistBackends: [assist]))
        return Env(root: root, downloads: downloads, engine: engine, events: Events(hub: engine.events), clock: clock,
                   settings: box)
    }

    static func run(_ s: EngineSettings = DedupeKit.settings(), fetcher: (any HTTPFetching)? = nil,
                    assist: MockAssistBackend = MockAssistBackend(), _ body: (Env) async throws -> Void) async throws {
        let env = try await make(s, fetcher: fetcher, assist: assist)
        do { try await body(env) } catch {
            await env.cleanup()
            throw error
        }
        await env.cleanup()
    }

    // MARK: PDFs

    /// Distinct body text per seed (so unrelated PDFs never share their page-1 fingerprint).
    static func body(seed: String) -> String {
        let words = ("cortex progenitor lineage atlas neuron chromatin spatial cluster organoid trajectory signal "
                     + "embryo tissue variant genome assembly protein binding imaging dynamic cohort marker").split(separator: " ")
        var h = MinHash.fnv1a(Substring(seed))
        var out: [Substring] = []
        for _ in 0..<160 {
            h = h &* 6364136223846793005 &+ 1442695040888963407
            out.append(words[Int(h >> 33) % words.count])
        }
        return out.joined(separator: " ")
    }

    /// A real PDF: a big title line, an author line, an optional DOI line, body text over
    /// `pages` pages and a unique tag (distinct bytes per call).
    static func pdfData(title: String, doi: String?, body: String, pages: Int, author: String? = nil, tag: String) -> Data {
        let out = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: out as CFMutableData)!
        let info: CFDictionary? = author.map { [kCGPDFContextAuthor as String: $0] as CFDictionary }
        let ctx = CGContext(consumer: consumer, mediaBox: &box, info)!
        let words = body.split(separator: " ").map(String.init)
        func chunks(_ from: Int) -> [String] {
            stride(from: from, to: min(words.count, from + 96), by: 12).map { words[$0..<min(words.count, $0 + 12)].joined(separator: " ") }
        }
        for page in 0..<max(1, pages) {
            var lines: [(String, CGFloat)] = []
            if page == 0 {
                lines.append((title, 18))
                lines.append(("Ada Lovelace and Grace Hopper", 11))
                if let doi { lines.append(("DOI: \(doi)", 9)) }
                lines.append(("Abstract", 12))
            }
            lines += chunks((page * 96) % max(1, words.count)).map { ($0, 10) }
            if page == 0 { lines.append(("tag \(tag)", 8)) }
            ctx.beginPDFPage(nil)
            var y: CGFloat = 730
            for (text, size) in lines {
                let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
                ctx.textPosition = CGPoint(x: 54, y: y)
                CTLineDraw(line, ctx)
                y -= size * 1.8
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return out as Data
    }

    // MARK: Metadata records

    /// A Crossref `/works/<doi>` body (title, authors, year, venue, type, relations).
    static func crossref(doi: String, title: String, authors: [String] = ["Ada Lovelace", "Grace Hopper"], year: Int = 2025,
                         venue: String = "Nature", type: String = "journal-article",
                         relation: [String: [String]] = [:], updateTo: [String] = []) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\"", with: "\\\"") }
        let auth = authors.map { a -> String in
            let parts = a.split(separator: " ")
            return "{\"given\":\"\(esc(parts.dropLast().joined(separator: " ")))\",\"family\":\"\(esc(String(parts.last ?? "")))\"}"
        }.joined(separator: ",")
        let rel = relation.map { kind, dois in
            "\"\(kind)\":[" + dois.map { "{\"id-type\":\"doi\",\"id\":\"\($0)\",\"asserted-by\":\"object\"}" }.joined(separator: ",") + "]"
        }.joined(separator: ",")
        let upd = updateTo.map { "{\"DOI\":\"\($0)\",\"type\":\"correction\"}" }.joined(separator: ",")
        return """
        {"status":"ok","message":{"DOI":"\(doi)","type":"\(type)","title":["\(esc(title))"],"author":[\(auth)],
         "issued":{"date-parts":[[\(year)]]},"container-title":["\(esc(venue))"],"relation":{\(rel)},"update-to":[\(upd)]}}
        """
    }
}
