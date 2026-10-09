import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PaperDeckCore

// Harness of the RegressionImport suites (review findings on import / files / storage).
// A self-contained copy of the ImportPipelineTests harness (whose helpers are file-private)
// plus a controllable clock and gated fetcher/extractor so races can be staged exactly.
// Everything runs in a temp root; the Trash is always injected; no real `claude` ever runs.

/// Tuesday 2026-09-29 10:00 in Chicago.
let riStart = Date(timeIntervalSince1970: 1_790_694_000)
let riCalendar = LocalDate.gregorian(TimeZone(identifier: "America/Chicago")!)

func riSettings(lang: UILang = .zh, importMode: EngineSettings.ImportMode = .copy,
                metadataLookup: Bool = true) -> EngineSettings {
    EngineSettings(plan: PlanSettings(dailyBudgetMinutes: 60), lang: lang, agentMode: .off, autoReadNewPapers: true,
                   importMode: importMode, metadataLookup: metadataLookup)
}

/// Mutable value behind a lock (clock) — the engine reads it through a closure.
final class RIBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// HostGate clock where waiting is free.
final class RIInstantGateClock: HostGate.Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 10_000
    func now() -> TimeInterval { lock.withLock { t } }
    func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        lock.withLock { t += max(0, seconds) }
    }
}

/// A one-shot latch: `wait()` suspends until `open()` (idempotent).
final class RILatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0

    func wait() async {
        let proceed: Bool = lock.withLock { arrivals += 1; return isOpen }
        if proceed { return }
        await withCheckedContinuation { c in
            let resumeNow: Bool = lock.withLock {
                if isOpen { return true }
                waiters.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }

    func open() {
        let w: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        for c in w { c.resume() }
    }

    /// How many callers reached `wait()` so far.
    var arrived: Int { lock.withLock { arrivals } }

    /// Polls until `n` callers are waiting (or ~5 s passed).
    func waitForArrivals(_ n: Int) async {
        for _ in 0..<1_000 where arrived < n { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

/// Collects every engine event; `drain()` waits until everything sent so far has arrived.
final class RIEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [EngineEvent] = []
    private var task: Task<Void, Never>?
    private let hub: EventHub<EngineEvent>

    init(hub: EventHub<EngineEvent>) {
        self.hub = hub
        let stream = hub.subscribe()
        task = Task { [weak self] in
            for await event in stream { self?.append(event) }
        }
    }

    deinit { task?.cancel() }

    private func append(_ e: EngineEvent) { lock.withLock { items.append(e) } }

    func drain() async {
        let marker = "sentinel-" + UUID().uuidString
        hub.send(.toast(Toast(id: marker, kind: .info, message: marker)))
        for _ in 0..<500 {
            let seen = lock.withLock { items.contains { if case .toast(let t) = $0 { return t.id == marker }; return false } }
            if seen { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    var toasts: [Toast] {
        lock.withLock {
            items.compactMap { if case .toast(let t) = $0, !t.id.hasPrefix("sentinel-") { return t }; return nil }
        }
    }

    var rows: [ImportRowUpdate] {
        lock.withLock { items.compactMap { if case .importRow(let r) = $0 { return r }; return nil } }
    }

    func clear() { lock.withLock { items.removeAll() } }
}

struct RIFakeDoc: Sendable {
    var title: String?
    var ids: PaperIDs?
    var pages = 10
}

/// Stand-in for PDFKit: ids from the file name (like the real detector) unless `docs` says
/// otherwise, a fixed structure, a real JPEG thumbnail. `gate` (optional) holds every
/// extraction until it is opened — the partial then sits in `.partial/` in flight.
struct RIFakeExtractor: PDFExtracting {
    var docs: [String: RIFakeDoc] = [:]
    var gate: RILatch?

    func extract(url: URL, fileName: String) async throws -> ExtractedPDF {
        guard FileOps.isPDF(head: try FileOps.readHead(url)) else { throw PDFExtractor.ExtractError.notPDF }
        if let gate { await gate.wait() }
        let doc = docs[fileName] ?? RIFakeDoc()
        let ids = doc.ids ?? Identifiers.detect(fileName: fileName, firstPagesText: "", attributeTitle: nil, xmpHead: nil)
        let title = doc.title ?? "Synthetic study of \((fileName as NSString).deletingPathExtension)"
        let pageText = String(repeating: "Results show that the method works well. ", count: 20)
        let texts = Array(repeating: pageText, count: doc.pages)
        let structure = DocumentStructure(sections: [
            SectionHit(kind: .abstract, title: "Abstract", page: 1),
            SectionHit(kind: .results, title: "Results", page: 2),
            SectionHit(kind: .methods, title: "Methods", page: 7),
        ], mainFigureNumbers: [1, 2], mainWordCount: 3_000)
        return ExtractedPDF(pageCount: doc.pages, pageTexts: texts, charCount: texts.reduce(0) { $0 + $1.count },
                            isEncrypted: false, isLocked: false, isScanned: false,
                            attributeTitle: nil, attributeAuthor: nil, fontTitle: title, ids: ids,
                            structure: structure, cardThumbnailJPEG: RIFakeExtractor.jpeg)
    }

    static let jpeg: Data = {
        let ctx = CGContext(data: nil, width: 560, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 560, height: 240))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }()
}

/// Metadata transport that answers 404 to everything — after `gate` opens, if one is given.
struct RIGatedFetcher: HTTPFetching {
    var gate: RILatch?
    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResult {
        if let gate { await gate.wait() }
        try Task.checkCancellation()
        return HTTPResult(status: 404, body: Data())
    }
}

/// Records what was "trashed" and moves it away like `FileManager.trashItem` does: one rename,
/// into a scratch folder of its own (removed with the trash). A recursive delete is not atomic —
/// a card.json the sidecar writer landed mid-delete made it fail with ENOTEMPTY, which the real
/// Trash never does.
final class RITrash: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    /// Where trashed items go (one UUID-named entry each).
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pd-ritrash-\(UUID().uuidString)", isDirectory: true)
    var all: [URL] { lock.withLock { urls } }
    var function: @Sendable (URL) -> Bool {
        { [self] url in
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let dst = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
            guard rename(url.path, dst.path) == 0 else { return false }
            lock.withLock { urls.append(url) }
            return true
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

struct RIConfig {
    var settings = riSettings()
    /// Transport of the test-built EnrichActor (nil → no metadata lookup there).
    var fetcher: (any HTTPFetching)?
    var extractor: any PDFExtracting = RIFakeExtractor()
    var trash: (@Sendable (URL) -> Bool)?
    /// Transport of the engine's own EnrichActor (restore/resume resubmit there).
    var engineFetcher: (any HTTPFetching)?
}

struct RIHarness {
    let root: URL
    let sources: URL
    let engine: Engine
    let intake: IntakeActor
    let enrich: EnrichActor
    let events: RIEventLog
    let clock: RIBox<Date>

    var ctx: EngineContext { engine.ctx }
    var db: Database { engine.db }
    var paths: AppPaths { engine.paths }

    static func make(_ config: RIConfig) async throws -> RIHarness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-regimport-\(UUID().uuidString)",
                                                                                isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sources = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let settings = config.settings
        let clock = RIBox(riStart)
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: Engine.Dependencies(
            loadSettings: { settings }, now: { clock.value }, calendar: riCalendar, fetcher: config.engineFetcher,
            claude: MockAgentProvider(), codex: MockAgentProvider(), sidecarDelay: .milliseconds(10), assistBackends: [MockAssistBackend()]))
        let events = RIEventLog(hub: engine.events)
        let fetcher = config.fetcher
        let gate = HostGate(clock: RIInstantGateClock())
        let cache = InMemoryMetadataCache()
        let enrich = EnrichActor(ctx: engine.ctx, resolverFactory: { s in
            guard s.metadataLookup, let fetcher else { return nil }
            return MetadataResolver(fetcher: fetcher, cache: cache, gate: gate, mailto: s.crossrefMailto)
        }, onReady: { _, _ in })
        let trash = config.trash ?? { _ in false }
        let intake = IntakeActor(ctx: engine.ctx, enrich: enrich, extractor: config.extractor, trashSource: trash)
        return RIHarness(root: root, sources: sources, engine: engine, intake: intake, enrich: enrich,
                         events: events, clock: clock)
    }

    func finish() async {
        await enrich.shutdown()
        await engine.enrich.shutdown()
        await engine.agents.shutdown()
        await ctx.sidecars.flush()
        await db.close()
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.inbox.path)
        try? FileManager.default.removeItem(at: root)
    }

    /// Ingest and wait for the whole pipeline (enrichment included) and every event.
    @discardableResult
    func importAll(_ items: [IntakeItem], _ options: ImportOptions = ImportOptions(origin: .drop)) async -> ImportBatchSummary {
        let summary = await intake.ingest(items, options: options)
        await enrich.waitUntilIdle()
        await ctx.sidecars.flush()
        await events.drain()
        return summary
    }

    /// A synthetic "PDF" (a header and unique bytes) outside the library.
    @discardableResult
    func writeSource(_ name: String, in dir: URL? = nil, tag: String = UUID().uuidString) throws -> URL {
        let folder = dir ?? sources
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data("%PDF-1.4\n% PaperDeck regression test \(tag)\n1 0 obj << >> endobj\n%%EOF\n".utf8).write(to: url)
        return url
    }

    func paper(_ id: String) async throws -> Paper { try #require(try await db.paper(id: id)) }

    func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Every file below the library root whose bytes hash to `sha` (hidden folders included).
    func copies(ofSHA sha: String) -> Int {
        var n = 0
        let walker = FileManager.default.enumerator(at: paths.library, includingPropertiesForKeys: [.isRegularFileKey])
        while let u = walker?.nextObject() as? URL {
            if u.pathExtension == "pdf", (try? FileOps.sha256(of: u)) == sha { n += 1 }
        }
        return n
    }
}

func withRIHarness(_ config: RIConfig = RIConfig(), _ body: (RIHarness) async throws -> Void) async throws {
    let h = try await RIHarness.make(config)
    do {
        try await body(h)
    } catch {
        await h.finish()
        throw error
    }
    await h.finish()
}
