import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Testing
@testable import PaperDeckCore

// MARK: - Harness (private to this file)

/// Tuesday 2026-09-29 10:00 in Chicago.
private let importNow = Date(timeIntervalSince1970: 1_790_694_000)
private let importCalendar = LocalDate.gregorian(TimeZone(identifier: "America/Chicago")!)

private let fixtureDir = NSHomeDirectory() + "/Library/Caches/PaperDeck-dev/fixtures"
private let fixtureNames = [
    "1-s2.0-S0092867424013321-main.pdf", "2025.09.01.673319.full.pdf", "2026.02.27.708412.full.pdf",
    "2026.04.06.716850.full.pdf", "2604.09554v2.pdf", "2606.24530v2.pdf",
    "Agentic_Laboratories_of_the_Future_Towards_World_Models_for_Scientific_Discoverypreprints202608.0213.v1.pdf",
    "SpatialFormer.pdf", "s41586-024-08351-7.pdf",
]
private let natureFixture = "s41586-024-08351-7.pdf"
private func fixtureURL(_ name: String) -> URL { URL(fileURLWithPath: fixtureDir + "/" + name) }
private let allFixturesPresent = fixtureNames.allSatisfy { FileManager.default.fileExists(atPath: fixtureDir + "/" + $0) }
private let natureFixturePresent = FileManager.default.fileExists(atPath: fixtureDir + "/" + natureFixture)
private let fakeFixturePresent = FileManager.default.fileExists(atPath: fixtureDir + "/bad/fake.pdf")

private func importSettings(lang: UILang = .zh, autoRead: Bool = true, importMode: EngineSettings.ImportMode = .copy)
    -> EngineSettings {
    EngineSettings(plan: PlanSettings(dailyBudgetMinutes: 60), lang: lang, agentMode: .off, autoReadNewPapers: autoRead,
                   importMode: importMode, metadataLookup: true)
}

/// HostGate clock where waiting is free (sleep advances virtual time).
private final class InstantGateClock: HostGate.Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 10_000
    func now() -> TimeInterval { lock.withLock { t } }
    func sleep(seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        lock.withLock { t += max(0, seconds) }
    }
}

private final class ReadyLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(pk: Int64, hold: Bool)] = []
    func record(_ pk: Int64, _ hold: Bool) { lock.withLock { calls.append((pk, hold)) } }
    var all: [(pk: Int64, hold: Bool)] { lock.withLock { calls } }
}

/// Collects every engine event; `drain()` waits until everything sent so far has arrived.
private final class EventLog: @unchecked Sendable {
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

    var batches: [ImportBatchSummary] {
        lock.withLock { items.compactMap { if case .batchFinished(let s) = $0 { return s }; return nil } }
    }

    func clear() { lock.withLock { items.removeAll() } }
}

private struct FakeDoc: Sendable {
    var title: String?
    var ids: PaperIDs?
    var pages = 10
    var locked = false
    var scanned = false
    var unreadable = false
}

/// Stand-in for PDFKit: ids from the file name (like the real detector), a fixed structure,
/// and a real JPEG thumbnail. Synthetic files only need a `%PDF-` header.
private struct FakeExtractor: PDFExtracting {
    var docs: [String: FakeDoc] = [:]

    func extract(url: URL, fileName: String) async throws -> ExtractedPDF {
        guard FileOps.isPDF(head: try FileOps.readHead(url)) else { throw PDFExtractor.ExtractError.notPDF }
        let doc = docs[fileName] ?? FakeDoc()
        if doc.unreadable { throw PDFExtractor.ExtractError.unreadable }
        let ids = doc.ids ?? Identifiers.detect(fileName: fileName, firstPagesText: "", attributeTitle: nil, xmpHead: nil)
        let title = doc.title ?? "Synthetic study of \((fileName as NSString).deletingPathExtension)"
        let pageText = doc.scanned ? "x" : String(repeating: "Results show that the method works well. ", count: 20)
        let texts = doc.locked ? [] : Array(repeating: pageText, count: doc.pages)
        let structure = DocumentStructure(sections: [
            SectionHit(kind: .abstract, title: "Abstract", page: 1),
            SectionHit(kind: .introduction, title: "Introduction", page: 1),
            SectionHit(kind: .results, title: "Results", page: 2),
            SectionHit(kind: .discussion, title: "Discussion", page: 6),
            SectionHit(kind: .methods, title: "Methods", page: 7),
        ], mainFigureNumbers: [1, 2, 3], mainWordCount: 3_000)
        return ExtractedPDF(pageCount: doc.pages, pageTexts: texts, charCount: texts.reduce(0) { $0 + $1.count },
                            isEncrypted: doc.locked, isLocked: doc.locked, isScanned: doc.scanned,
                            attributeTitle: nil, attributeAuthor: nil, fontTitle: doc.locked ? nil : title, ids: ids,
                            structure: doc.locked ? DocumentStructure() : structure,
                            cardThumbnailJPEG: doc.locked ? nil : FakeExtractor.jpeg)
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

/// Metadata transport whose requests never finish (until cancelled).
private struct HangingFetcher: HTTPFetching {
    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResult {
        try await Task.sleep(for: .seconds(3_600))
        throw URLError(.timedOut)
    }
}

private final class FakeDownloader: PDFDownloading, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var mime: String?
        var body: Data
        var suggested: String?
    }

    private let lock = NSLock()
    private var urls: [URL] = []
    private let route: @Sendable (URL) -> Reply

    init(_ route: @escaping @Sendable (URL) -> Reply) { self.route = route }

    var requested: [URL] { lock.withLock { urls } }

    func download(_ url: URL, into directory: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> PDFDownload {
        lock.withLock { urls.append(url) }
        let reply = route(url)
        progress(nil); progress(0.5); progress(1)
        let file = directory.appendingPathComponent("body.download")
        try reply.body.write(to: file)
        return PDFDownload(status: reply.status, mimeType: reply.mime, file: file, suggestedFilename: reply.suggested)
    }
}

private struct HarnessConfig {
    var settings = importSettings()
    var fetcher: (any HTTPFetching)?
    var extractor: any PDFExtracting = FakeExtractor()
    var downloader: (any PDFDownloading)?
    var trash: (@Sendable (URL) -> Bool)?
    /// Use the engine's own IntakeActor/EnrichActor (real Engine.open wiring) instead of test-built ones.
    var engineActors = false
}

private struct Harness {
    let root: URL
    let sources: URL
    let engine: Engine
    let intake: IntakeActor
    let enrich: EnrichActor
    let ready: ReadyLog
    let events: EventLog

    var ctx: EngineContext { engine.ctx }
    var db: Database { engine.db }
    var paths: AppPaths { engine.paths }

    static func make(_ config: HarnessConfig) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sources = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let settings = config.settings
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: Engine.Dependencies(
            loadSettings: { settings }, now: { importNow }, calendar: importCalendar, fetcher: nil,
            claude: MockAgentProvider(), codex: MockAgentProvider(), sidecarDelay: .milliseconds(10), assistBackends: [MockAssistBackend()]))
        let ready = ReadyLog()
        let events = EventLog(hub: engine.events)
        if config.engineActors {
            return Harness(root: root, sources: sources, engine: engine, intake: engine.intake, enrich: engine.enrich,
                           ready: ready, events: events)
        }
        let fetcher = config.fetcher
        let gate = HostGate(clock: InstantGateClock())
        let cache = InMemoryMetadataCache()
        let enrich = EnrichActor(ctx: engine.ctx, resolverFactory: { s in
            guard s.metadataLookup, let fetcher else { return nil }
            return MetadataResolver(fetcher: fetcher, cache: cache, gate: gate, mailto: s.crossrefMailto)
        }, onReady: { pk, hold in ready.record(pk, hold) })
        let intake = IntakeActor(ctx: engine.ctx, enrich: enrich, extractor: config.extractor,
                                 downloader: config.downloader, trashSource: config.trash ?? { FileOps.trash($0) })
        return Harness(root: root, sources: sources, engine: engine, intake: intake, enrich: enrich, ready: ready, events: events)
    }

    func finish() async {
        await enrich.shutdown()
        await engine.enrich.shutdown()
        await ctx.sidecars.flush()
        await db.close()
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

    /// A synthetic "PDF" (just a header and unique bytes) outside the library.
    @discardableResult
    func writeSource(_ name: String, in dir: URL? = nil, tag: String = UUID().uuidString) throws -> URL {
        let folder = dir ?? sources
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data("%PDF-1.4\n% PaperDeck import test \(tag)\n1 0 obj << >> endobj\n%%EOF\n".utf8).write(to: url)
        return url
    }

    func paper(_ id: String) async throws -> Paper { try #require(try await db.paper(id: id)) }

    func folderNames(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    func paperFolders() -> [String] { folderNames(paths.papers).filter { $0 != "_Inbox" } }

    func partialFiles() -> [String] { folderNames(paths.partial) }

    func sidecar(_ p: Paper) throws -> CardSidecar {
        try CardSidecar.decoded(from: Data(contentsOf: ctx.folderURL(p).appendingPathComponent(CardSidecar.fileName)))
    }
}

private func withHarness(_ config: HarnessConfig = HarnessConfig(), _ body: (Harness) async throws -> Void) async throws {
    let h = try await Harness.make(config)
    do {
        try await body(h)
    } catch {
        await h.finish()
        throw error
    }
    await h.finish()
}

private func mode(_ url: URL) -> mode_t {
    var st = stat()
    _ = url.withUnsafeFileSystemRepresentation { stat($0!, &st) }
    return st.st_mode & 0o7777
}

private func sha(_ url: URL) throws -> String { try FileOps.sha256(of: url) }

// MARK: - Intake: synthetic files (fast, no fixtures needed)

@Suite(.serialized) struct IntakePipelineTests {

    @Test func commitsCardWithChecklistPlacementAndFiles() async throws {
        try await withHarness { h in
            let src = try h.writeSource("Local_Paper.pdf")
            let summary = await h.importAll([.file(src)])
            #expect(summary.added.count == 1)
            #expect(summary.heldForAI.isEmpty)
            #expect(h.events.batches.map(\.batchID) == [summary.batchID])
            let p = try await h.paper(try #require(summary.added.first))

            #expect(p.stage == .ready)
            #expect(p.title == "Synthetic study of Local_Paper")
            #expect(p.titleRank == .font)
            #expect(p.metaSource == .none)
            #expect(p.originalName == "Local_Paper.pdf")
            #expect(p.priority == .normal)
            #expect(p.provisional)
            #expect(p.estSource == .heuristic)
            #expect(p.queueRank == 1)
            #expect(p.scheduleMode == .auto)
            #expect(p.deadline != nil)
            #expect(p.deadlineOrigin == .place)
            #expect(p.placementFloor == LocalDate(year: 2026, month: 9, day: 29))
            let items = try await h.db.checklist(paperPK: p.pk)
            #expect(!items.isEmpty)
            #expect(items.reduce(0) { $0 + $1.minutes } == p.estMinutes)
            #expect(items.allSatisfy { $0.origin == .heuristic })

            // Filed from the local title, the PDF renamed after the folder.
            #expect(p.folder == "Papers/Synthetic-study-of-Local_Paper")
            #expect(p.pdfName == "Synthetic-study-of-Local_Paper.pdf")
            #expect(!p.nameFinal)
            #expect(try sha(h.ctx.pdfURL(p)) == p.sha256)
            #expect(try sha(src) == p.sha256)
            #expect(h.folderNames(h.paths.inbox).isEmpty)
            #expect(h.partialFiles().isEmpty)
            #expect(h.ctx.thumbs.existingCardURL(for: p.id) != nil)
            #expect(h.ctx.thumbs.existingWidgetURL(for: p.id) != nil)
            #expect(try h.ctx.texts.load(id: p.id)?.contains("method works well") == true)
            #expect(try await h.db.search("method").contains(p.pk))
            let card = try h.sidecar(p)
            #expect(card.id == p.id)
            #expect(card.pdf == p.pdfName)
            #expect(card.state.stage == .ready)
            #expect(FileManager.default.fileExists(atPath: h.ctx.folderURL(p).appendingPathComponent("notes.md").path))

            // Rows walk the stages and end with ✓ added; one success toast with the two actions.
            let stages = h.events.rows.map(\.stage)
            #expect(stages.first == .receiving)
            #expect(stages.contains(.verifying))
            #expect(stages.contains(.parsing))
            #expect(stages.last == .added(paperID: p.id, deadline: p.deadline, provisional: true))
            let toast = try #require(h.events.toasts.first { $0.kind == .success })
            #expect(toast.message.hasPrefix("已添加：Synthetic study of Local_Paper · DDL ≈"))
            #expect(toast.buttons.map(\.action) == [.openPaper(id: p.id), .setHighPriority(paperID: p.id)])
            #expect(h.ready.all.count == 1)
            #expect(h.ready.all.first?.hold == false)
        }
    }

    @Test func englishToast() async throws {
        try await withHarness(HarnessConfig(settings: importSettings(lang: .en))) { h in
            let summary = await h.importAll([.file(try h.writeSource("english.pdf"))])
            #expect(summary.added.count == 1)
            let toast = try #require(h.events.toasts.first { $0.kind == .success })
            #expect(toast.message.hasPrefix("Added: Synthetic study of english · due ≈"))
            #expect(toast.buttons.map(\.title) == ["View", "Set high priority"])
        }
    }

    @Test func exactDuplicatesAndSoftDeleted() async throws {
        try await withHarness { h in
            let src = try h.writeSource("dup.pdf")
            let first = await h.importAll([.file(src)])
            let id = try #require(first.added.first)
            h.events.clear()

            // Same bytes twice in one batch plus once more: one row is new… none here, all duplicates.
            let copy = h.sources.appendingPathComponent("dup copy.pdf")
            try FileManager.default.copyItem(at: src, to: copy)
            let again = await h.importAll([.file(src), .file(copy)])
            #expect(again.added.isEmpty)
            #expect(again.duplicates == 2)
            #expect(h.events.rows.filter { $0.stage == .duplicate(paperID: id) }.count == 2)
            let dupToast = try #require(h.events.toasts.first)
            #expect(dupToast.message == "已在库中：Synthetic study of dup")
            #expect(dupToast.buttons.map(\.action) == [.openPaper(id: id)])
            #expect(try await h.db.livePapers().count == 1)
            #expect(h.partialFiles().isEmpty)

            // Soft-deleted → offer restore.
            let p = try await h.paper(id)
            try await h.db.softDelete(pk: p.pk)
            h.events.clear()
            let third = await h.importAll([.file(src)])
            #expect(third.duplicates == 1)
            let restore = try #require(h.events.toasts.first)
            #expect(restore.message.hasPrefix("已在「最近删除」中："))
            #expect(restore.buttons.map(\.action) == [.restorePaper(id: id)])
        }
    }

    @Test func sameBytesTwiceInOneBatch() async throws {
        try await withHarness { h in
            let src = try h.writeSource("twice.pdf")
            let copy = h.sources.appendingPathComponent("twice-copy.pdf")
            try FileManager.default.copyItem(at: src, to: copy)
            let summary = await h.importAll([.file(src), .file(copy)])
            #expect(summary.added.count == 1)
            #expect(summary.duplicates == 1)
            #expect(try await h.db.livePapers().count == 1)
            #expect(h.partialFiles().isEmpty)
            #expect(h.paperFolders().count == 1)
        }
    }

    @Test func rejectsNonPDF() async throws {
        try await withHarness { h in
            let txt = h.sources.appendingPathComponent("fake.pdf")
            try Data("just some text, definitely not a PDF".utf8).write(to: txt)
            let summary = await h.importAll([.file(txt)])
            #expect(summary.rejected == 1)
            #expect(summary.added.isEmpty)
            #expect(h.events.rows.last?.stage == .rejected(reason: "不是 PDF"))
            let toast = try #require(h.events.toasts.first)
            #expect(toast.kind == .error)
            #expect(toast.message == "无法导入 fake.pdf：不是 PDF")
            #expect(h.partialFiles().isEmpty)
            #expect(try await h.db.livePapers().isEmpty)

            let missing = await h.importAll([.file(h.sources.appendingPathComponent("gone.pdf"))])
            #expect(missing.failed == 1)
            #expect(h.events.toasts.last?.message.contains("请重新拖入") == true)
        }
    }

    @Test func readOnlySourceIsClonedWritableAndUntouched() async throws {
        try await withHarness { h in
            let src = try h.writeSource("readonly.pdf")
            #expect(chmod(src.path, 0o444) == 0)
            let before = try sha(src)
            let summary = await h.importAll([.file(src)])
            let p = try await h.paper(try #require(summary.added.first))
            let copy = h.ctx.pdfURL(p)
            #expect(mode(copy) & S_IWUSR != 0)
            #expect(mode(src) == 0o444)
            #expect(try sha(src) == before)
            #expect(try sha(copy) == before)
        }
    }

    @Test func sameWorkReplaceKeepsChecklistDeadlineAndNotes() async throws {
        try await withHarness { h in
            let v2 = try h.writeSource("2606.24530v2.pdf")
            let first = await h.importAll([.file(v2)])
            let id = try #require(first.added.first)
            var p = try await h.paper(id)
            #expect(p.ids.arxivID == "2606.24530")
            #expect(p.ids.arxivVersion == 2)
            var items = try await h.db.checklist(paperPK: p.pk)
            items[0].doneAt = importNow
            try await h.db.upsertChecklistItem(paperPK: p.pk, item: items[0])
            try await h.db.modifyPaper(pk: p.pk) { $0.notes = "my notes" }
            p = try await h.paper(id)
            let checklist = try await h.db.checklist(paperPK: p.pk)
            let oldBytes = try Data(contentsOf: h.ctx.pdfURL(p))
            h.events.clear()

            let v3 = try h.writeSource("2606.24530v3.pdf")
            let second = await h.importAll([.file(v3)])
            #expect(second.added.isEmpty)
            #expect(second.duplicates == 0)
            let pendingID = try #require(await h.intake.pendingIDs().first)
            #expect(h.events.rows.last?.stage == .sameWork(existingPaperID: id, pendingID: pendingID))
            let toast = try #require(h.events.toasts.first)
            #expect(toast.message == "同一论文已在库中（v2）· 新文件 v3")
            #expect(toast.isSticky)
            #expect(toast.buttons.map(\.action) == [.replaceKeepingChecklist(pendingID: pendingID), .ignorePending(pendingID: pendingID)])
            #expect(h.partialFiles().count == 1)
            #expect(try await h.db.livePapers().count == 1)

            await h.intake.resolvePending(pendingID: pendingID, replace: true)
            await h.ctx.sidecars.flush()
            await h.events.drain()
            let after = try await h.paper(id)
            #expect(after.sha256 == (try sha(v3)))
            #expect(after.ids.arxivVersion == 3)
            #expect(after.originalName == "2606.24530v3.pdf")
            #expect(after.folder == p.folder)
            #expect(after.pdfName == p.pdfName)
            #expect(after.deadline == p.deadline)
            #expect(after.scheduleMode == p.scheduleMode)
            #expect(after.notes == "my notes")
            #expect(try await h.db.checklist(paperPK: p.pk) == checklist)
            #expect(try Data(contentsOf: h.ctx.pdfURL(after)) == (try Data(contentsOf: v3)))
            let folderName = h.ctx.folderURL(p).lastPathComponent
            let kept = ReplacedPDFs.root(h.paths).appendingPathComponent(ReplacedPDFs.stamp(importNow) + "_" + folderName)
                .appendingPathComponent(p.pdfName)
            #expect(try Data(contentsOf: kept) == oldBytes)
            #expect(h.partialFiles().isEmpty)
            #expect(await h.intake.pendingIDs().isEmpty)
            #expect(try h.sidecar(after).sha256 == after.sha256)
            #expect(h.events.rows.last?.stage == .added(paperID: id, deadline: p.deadline, provisional: p.provisional))
            #expect(h.events.toasts.last?.message.hasPrefix("已替换为新文件：") == true)
        }
    }

    @Test func sameWorkIgnoreDeletesStagedCopy() async throws {
        try await withHarness { h in
            let first = await h.importAll([.file(try h.writeSource("2604.09554v1.pdf"))])
            let id = try #require(first.added.first)
            let before = try await h.paper(id)
            _ = await h.importAll([.file(try h.writeSource("2604.09554v2.pdf"))])
            let pendingID = try #require(await h.intake.pendingIDs().first)
            #expect(h.partialFiles().count == 1)
            await h.intake.resolvePending(pendingID: pendingID, replace: false)
            await h.events.drain()
            #expect(h.partialFiles().isEmpty)
            #expect(await h.intake.pendingIDs().isEmpty)
            #expect(try await h.paper(id).sha256 == before.sha256)
            #expect(h.events.rows.last?.stage == .duplicate(paperID: id))
            // Answering twice is harmless.
            await h.intake.resolvePending(pendingID: pendingID, replace: true)
            #expect(try await h.paper(id).sha256 == before.sha256)
        }
    }

    @Test func sameWorkByDOI() async throws {
        let extractor = FakeExtractor(docs: [
            "journal.pdf": FakeDoc(ids: PaperIDs(doi: "10.1038/s41586-024-08351-7")),
            "journal-again.pdf": FakeDoc(ids: PaperIDs(doi: "10.1038/S41586-024-08351-7")),
        ])
        try await withHarness(HarnessConfig(extractor: extractor)) { h in
            let first = await h.importAll([.file(try h.writeSource("journal.pdf"))])
            #expect(first.added.count == 1)
            _ = await h.importAll([.file(try h.writeSource("journal-again.pdf"))])
            #expect(await h.intake.pendingIDs().count == 1)
            #expect(h.events.toasts.last?.message.hasPrefix("同一论文已在库中：") == true)
        }
    }

    @Test func largeBatchIsPlacedSequentiallyAtLowPriorityAndHeld() async throws {
        try await withHarness { h in
            var items: [IntakeItem] = []
            for i in 1...12 { items.append(.file(try h.writeSource(String(format: "batch-%02d.pdf", i)))) }
            let summary = await h.importAll(items)
            #expect(summary.added.count == 12)
            #expect(summary.heldForAI.count == 12)
            let papers = try await h.db.livePapers()        // queue order
            #expect(papers.count == 12)
            #expect(papers.allSatisfy { $0.priority == .low && $0.scheduleMode == .auto && $0.deadline != nil })
            let deadlines = papers.compactMap(\.deadline)
            #expect(deadlines == deadlines.sorted())
            #expect(summary.lastDeadline == deadlines.last)
            #expect(summary.added == papers.map(\.id))
            #expect(h.ready.all.count == 12)
            #expect(h.ready.all.allSatisfy { $0.hold })
            // Big batches get one summary toast, not twelve.
            let successes = h.events.toasts.filter { $0.kind == .success }
            #expect(successes.count == 1)
            #expect(successes.first?.message.hasPrefix("已添加 12 篇论文 · 最后 DDL") == true)
            #expect(successes.first?.buttons.isEmpty == true)
        }
    }

    @Test func setupAssistantAndUnscheduledBatches() async throws {
        try await withHarness { h in
            let setup = await h.importAll([.file(try h.writeSource("setup-a.pdf")), .file(try h.writeSource("setup-b.pdf"))],
                                          ImportOptions(origin: .setupAssistant))
            for id in setup.added { #expect(try await h.paper(id).priority == .low) }

            let normal = await h.importAll([.file(try h.writeSource("normal.pdf"))])
            #expect(try await h.paper(try #require(normal.added.first)).priority == .normal)

            let none = await h.importAll([.file(try h.writeSource("later.pdf"))],
                                         ImportOptions(origin: .drop, scheduling: .unscheduled))
            let p = try await h.paper(try #require(none.added.first))
            #expect(p.scheduleMode == .none)
            #expect(p.deadline == nil)
            #expect(none.lastDeadline == nil)
            #expect(h.events.toasts.last { $0.kind == .success }?.message.hasSuffix("DDL 未排期") == true)
        }
    }

    @Test func aiPolicies() async throws {
        let extractor = FakeExtractor(docs: [
            "scan.pdf": FakeDoc(scanned: true),
            "locked.pdf": FakeDoc(locked: true),
            "broken_file_name.pdf": FakeDoc(unreadable: true),
        ])
        try await withHarness(HarnessConfig(extractor: extractor)) { h in
            // > 3 → held; ≤ 3 → queued right away.
            var four: [IntakeItem] = []
            for i in 1...4 { four.append(.file(try h.writeSource("four-\(i).pdf"))) }
            let held = await h.importAll(four)
            #expect(held.heldForAI.count == 4)
            #expect(h.ready.all.count == 4 && h.ready.all.allSatisfy { $0.hold })

            let small = await h.importAll([.file(try h.writeSource("two-1.pdf")), .file(try h.writeSource("two-2.pdf"))])
            #expect(small.heldForAI.isEmpty)
            #expect(h.ready.all.count == 6 && h.ready.all.suffix(2).allSatisfy { !$0.hold })

            // skip → no job at all; explicit hold → held even for one paper.
            _ = await h.importAll([.file(try h.writeSource("skip.pdf"))], ImportOptions(origin: .drop, ai: .skip))
            #expect(h.ready.all.count == 6)
            let explicit = await h.importAll([.file(try h.writeSource("hold.pdf"))], ImportOptions(origin: .drop, ai: .hold))
            #expect(explicit.heldForAI.count == 1)
            #expect(h.ready.all.count == 7 && h.ready.all.last?.hold == true)

            // Scanned / locked / unreadable: imported, ai skipped, no job.
            let flagged = await h.importAll([.file(try h.writeSource("scan.pdf")), .file(try h.writeSource("locked.pdf")),
                                             .file(try h.writeSource("broken_file_name.pdf"))])
            #expect(flagged.added.count == 3)
            #expect(flagged.heldForAI.isEmpty)
            #expect(h.ready.all.count == 7)
            for id in flagged.added {
                let p = try await h.paper(id)
                #expect(p.aiState == .skipped)
                #expect(p.stage == .ready)
                let items = try await h.db.checklist(paperPK: p.pk)
                #expect(items.reduce(0) { $0 + $1.minutes } == p.estMinutes)
                switch p.originalName {
                case "scan.pdf": #expect(p.flags == .scanned)
                case "locked.pdf":
                    #expect(p.flags == .locked)
                    #expect(p.title == "locked")
                    #expect(p.titleRank == .filename)
                case "broken_file_name.pdf":
                    #expect(p.flags == .unreadable)
                    #expect(p.title == "broken file name")
                    #expect(p.titleRank == .filename)
                    #expect(h.ctx.thumbs.existingCardURL(for: p.id) == nil)
                default: Issue.record("unexpected \(p.originalName)")
                }
            }
            #expect(h.events.toasts.contains { $0.kind == .warning && $0.message.hasPrefix("PDF 已加密：locked.pdf") })
        }
    }

    @Test func autoReadOffOnlyQueueAllCreatesJobs() async throws {
        try await withHarness(HarnessConfig(settings: importSettings(autoRead: false))) { h in
            let auto = await h.importAll([.file(try h.writeSource("a.pdf"))])
            #expect(auto.heldForAI.isEmpty)
            #expect(h.ready.all.isEmpty)
            #expect(try await h.paper(try #require(auto.added.first)).aiState == .none)
            _ = await h.importAll([.file(try h.writeSource("b.pdf"))], ImportOptions(origin: .drop, ai: .queueAll))
            #expect(h.ready.all.count == 1)
            #expect(h.ready.all.first?.hold == false)
        }
    }

    @Test func folderExpansionSkipsSupplementsHiddenAndPackages() async throws {
        try await withHarness { h in
            let dir = h.sources.appendingPathComponent("Paper folder", isDirectory: true)
            try h.writeSource("main.pdf", in: dir)
            try h.writeSource("main_SI.pdf", in: dir)
            try h.writeSource("Supplementary_Data.pdf", in: dir)
            try h.writeSource(".hidden.pdf", in: dir)
            try Data("notes".utf8).write(to: dir.appendingPathComponent("notes.txt"))
            try h.writeSource("other.pdf", in: dir.appendingPathComponent("sub"))
            try h.writeSource("only_supp.pdf", in: dir.appendingPathComponent("sub/deep"))
            try h.writeSource("inside.pdf", in: dir.appendingPathComponent("Viewer.app/Contents"))

            let summary = await h.importAll([.file(dir)])
            #expect(summary.added.count == 3)
            let names = Set(try await h.db.livePapers().map(\.originalName))
            #expect(names == ["main.pdf", "other.pdf", "only_supp.pdf"])
            let toast = try #require(h.events.toasts.first { $0.message.hasPrefix("已跳过") })
            #expect(toast.message == "已跳过 2 个补充材料：Supplementary_Data.pdf、main_SI.pdf")
            #expect(IntakeActor.isSupplementName("Extended-Data.pdf"))
            #expect(IntakeActor.isSupplementName("paper.suppl.pdf"))
            #expect(!IntakeActor.isSupplementName("Supervised_learning.pdf"))
            #expect(!IntakeActor.isSupplementName("analysis.pdf"))
        }
    }

    @Test func pdfDataAndPromisesAreStagedThenCleanedUp() async throws {
        try await withHarness { h in
            let bytes = Data("%PDF-1.7\n% selected pages \(UUID())\n%%EOF\n".utf8)
            let data = await h.importAll([.pdfData(bytes, suggestedName: "Preview pages")])
            let p = try await h.paper(try #require(data.added.first))
            #expect(p.originalName == "Preview pages.pdf")
            #expect(h.events.toasts.contains { $0.kind == .info && $0.message == "拖入的 PDF 可能只包含所选页面" })

            let promiseDir = h.paths.incoming.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let promised = try h.writeSource("Mail attachment.pdf", in: promiseDir)
            let summary = await h.importAll([.promised(promised)])
            #expect(summary.added.count == 1)
            #expect(!FileManager.default.fileExists(atPath: promiseDir.path))
            #expect(h.folderNames(h.paths.incoming).isEmpty)
        }
    }

    @Test func moveModeTrashesUserFilesOnly() async throws {
        let trashed = TrashLog()
        let config = HarnessConfig(settings: importSettings(importMode: .move), trash: { url in
            trashed.append(url)
            return (try? FileManager.default.removeItem(at: url)) != nil
        })
        try await withHarness(config) { h in
            let src = try h.writeSource("move-me.pdf")
            let summary = await h.importAll([.file(src)])
            #expect(summary.added.count == 1)
            #expect(trashed.all.map(\.lastPathComponent) == ["move-me.pdf"])
            #expect(!FileManager.default.fileExists(atPath: src.path))
            #expect(!h.events.toasts.contains { $0.message == "原文件已保留" })
            let p = try await h.paper(try #require(summary.added.first))
            #expect(FileManager.default.fileExists(atPath: h.ctx.pdfURL(p).path))

            // Staged copies (promises) are ours, not the user's: never trashed.
            let promised = try h.writeSource("promised.pdf", in: h.paths.incoming.appendingPathComponent("p1"))
            _ = await h.importAll([.promised(promised)])
            #expect(trashed.all.count == 1)
        }
    }

    @Test func moveModeKeepsOriginalWhenTrashFails() async throws {
        // Real FileOps.trash: a read-only parent folder makes trashing fail (EACCES) → info toast.
        try await withHarness(HarnessConfig(settings: importSettings(importMode: .move))) { h in
            let locked = h.sources.appendingPathComponent("locked-dir", isDirectory: true)
            let src = try h.writeSource("keep-me.pdf", in: locked)
            #expect(chmod(locked.path, 0o555) == 0)
            defer { chmod(locked.path, 0o755) }
            let summary = await h.importAll([.file(src)])
            #expect(summary.added.count == 1)
            #expect(FileManager.default.fileExists(atPath: src.path))
            let toast = try #require(h.events.toasts.first { $0.message == "原文件已保留" })
            #expect(toast.kind == .info)
        }
    }

    // MARK: Links

    @Test func remoteLinks() async throws {
        let pdfBytes = Data("%PDF-1.5\n% downloaded \(UUID())\n%%EOF\n".utf8)
        let downloader = FakeDownloader { url in
            switch url.absoluteString {
            case "https://arxiv.org/pdf/2606.24530v2":
                return .init(status: 200, mime: "application/pdf", body: pdfBytes, suggested: "whatever.pdf")
            case "https://example.org/paywalled.pdf":
                return .init(status: 403, mime: "text/html", body: Data("<html>no</html>".utf8))
            case "https://example.org/login.pdf":
                return .init(status: 200, mime: "text/html", body: Data("<html>login</html>".utf8))
            case "https://example.org/octet.pdf":
                return .init(status: 200, mime: "application/octet-stream",
                             body: Data("%PDF-1.4\n% octet \(UUID())\n".utf8), suggested: "Octet Paper.pdf")
            default:
                return .init(status: 404, mime: nil, body: Data())
            }
        }
        try await withHarness(HarnessConfig(downloader: downloader)) { h in
            let arxiv = await h.importAll([.remote(URL(string: "https://arxiv.org/abs/2606.24530v2")!)])
            #expect(arxiv.added.count == 1)
            let p = try await h.paper(try #require(arxiv.added.first))
            #expect(p.originalName == "2606.24530v2.pdf")
            #expect(p.ids.arxivID == "2606.24530")
            #expect(h.events.rows.contains { $0.stage == .downloading(fraction: 0.5) })
            #expect(h.folderNames(h.paths.incoming).isEmpty)

            h.events.clear()
            let page = URL(string: "https://www.nature.com/articles/s41586-024-08351-7")!
            let web = await h.importAll([.remote(page)])
            #expect(web.rejected == 1)
            #expect(!downloader.requested.contains(page))
            let toast = try #require(h.events.toasts.first)
            #expect(toast.message == "无法下载 PDF")
            #expect(toast.buttons.map(\.action) == [.openInBrowser(page)])

            h.events.clear()
            let paywall = URL(string: "https://example.org/paywalled.pdf")!
            let forbidden = await h.importAll([.remote(paywall)])
            #expect(forbidden.failed == 1)
            #expect(h.events.toasts.first?.message == "下载失败（403）")
            #expect(h.events.toasts.first?.buttons.map(\.action) == [.openInBrowser(paywall)])

            let login = await h.importAll([.remote(URL(string: "https://example.org/login.pdf")!)])
            #expect(login.rejected == 1)

            let octet = await h.importAll([.remote(URL(string: "https://example.org/octet.pdf")!)])
            #expect(octet.added.count == 1)
            #expect(try await h.paper(try #require(octet.added.first)).originalName == "Octet Paper.pdf")
            #expect(h.folderNames(h.paths.incoming).isEmpty)
            #expect(h.partialFiles().isEmpty)
        }
    }

    @Test func pdfLinkRewriting() {
        func rewrite(_ s: String) -> String? { URLImporter.pdfURL(for: URL(string: s)!)?.absoluteString }
        #expect(rewrite("https://arxiv.org/abs/2606.24530") == "https://arxiv.org/pdf/2606.24530")
        #expect(rewrite("https://arxiv.org/abs/2606.24530v2") == "https://arxiv.org/pdf/2606.24530v2")
        #expect(rewrite("http://www.arxiv.org/html/2604.09554v1") == "https://arxiv.org/pdf/2604.09554v1")
        #expect(rewrite("https://arxiv.org/pdf/2604.09554v2.pdf") == "https://arxiv.org/pdf/2604.09554v2")
        #expect(rewrite("https://arxiv.org/abs/hep-th/9901001v1") == "https://arxiv.org/pdf/hep-th/9901001v1")
        #expect(rewrite("https://www.biorxiv.org/content/10.1101/2025.09.01.673319v1.full.pdf")
                == "https://www.biorxiv.org/content/10.1101/2025.09.01.673319v1.full.pdf")
        #expect(rewrite("https://openreview.net/pdf?id=abc") == "https://openreview.net/pdf?id=abc")
        #expect(rewrite("https://www.nature.com/articles/s41586-024-08351-7") == nil)
        #expect(rewrite("https://arxiv.org/list/cs.AI/recent") == nil)
        #expect(rewrite("ftp://example.org/x.pdf") == nil)
        #expect(rewrite("file:///tmp/x.pdf") == nil)
        #expect(URLImporter.arxivPDF(URL(string: "https://arxiv.org/abs/2606.24530v2")!)?.fileName == "2606.24530v2.pdf")
    }
}

/// URL list for the move-mode trash stand-in.
private final class TrashLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ u: URL) { lock.withLock { urls.append(u) } }
    var all: [URL] { lock.withLock { urls } }
}

// MARK: - Enrich: metadata, filing, refile, resume

@Suite(.serialized) struct EnrichPipelineTests {

    @Test func biorxivNewPrefixIsAdoptedAndFolderRenamed() async throws {
        let extractor = FakeExtractor(docs: [
            "2026.02.27.708412.full.pdf": FakeDoc(title: "Eubiota modular agentic AI", ids: PaperIDs(doi: "10.1101/2026.02.27.708412")),
        ])
        try await withHarness(HarnessConfig(fetcher: MetadataResolverTests.FakeFetcher(), extractor: extractor)) { h in
            let summary = await h.importAll([.file(try h.writeSource("2026.02.27.708412.full.pdf"))])
            let p = try await h.paper(try #require(summary.added.first))
            #expect(p.ids.doi == "10.64898/2026.02.27.708412")
            #expect(p.title == "Eubiota: Modular Agentic AI for Autonomous Discovery in the Gut Microbiome")
            #expect(p.titleRank == .api)
            #expect(p.metaSource == .biorxiv)
            #expect(p.authors.first == "P. Lu")
            #expect(p.venue == "bioRxiv")
            #expect(p.nameFinal)
            #expect(p.folder == "Papers/2026_Lu_Eubiota-Modular-Agentic-AI-for-Autonomous-Discovery-in-the-Gut-Microbiome")
            #expect(p.pdfName == "2026_Lu_Eubiota-Modular-Agentic-AI-for-Autonomous-Discovery-in-the-Gut-Microbiome.pdf")
            #expect(FileManager.default.fileExists(atPath: h.ctx.pdfURL(p).path))
            #expect(h.paperFolders() == ["2026_Lu_Eubiota-Modular-Agentic-AI-for-Autonomous-Discovery-in-the-Gut-Microbiome"])
            #expect(h.folderNames(h.paths.inbox).isEmpty)
            let card = try h.sidecar(p)
            #expect(card.ids.doi == "10.64898/2026.02.27.708412")
            #expect(card.meta.source == .biorxiv)
            #expect(card.state.nameFinal)
            #expect(try await h.db.search("microbiome").contains(p.pk))
        }
    }

    @Test func conflictingDOIIsNotWritten() async throws {
        let extractor = FakeExtractor(docs: [
            "a.pdf": FakeDoc(title: "Eubiota first copy", ids: PaperIDs(doi: "10.64898/2026.02.27.708412")),
            "b.pdf": FakeDoc(title: "Eubiota second copy", ids: PaperIDs(doi: "10.1101/2026.02.27.708412")),
        ])
        try await withHarness(HarnessConfig(fetcher: MetadataResolverTests.FakeFetcher(), extractor: extractor)) { h in
            let a = try await h.paper(try #require(await h.importAll([.file(try h.writeSource("a.pdf"))]).added.first))
            // Both bioRxiv prefixes name one work: a second copy is a same-work prompt at intake.
            let again = await h.importAll([.file(try h.writeSource("b.pdf"))])
            #expect(again.added.isEmpty)
            #expect(await h.intake.pendingIDs().count == 1)

            // A row that already holds the old prefix (committed before a took the new one)
            // keeps it through enrichment and is flagged as a possible duplicate.
            let folder = h.paths.inbox.appendingPathComponent("0b0b0b0b", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let bytes = Data("%PDF-1.4\n% legacy second copy\n%%EOF\n".utf8)
            try bytes.write(to: folder.appendingPathComponent("b.pdf"))
            let legacy = try await h.db.insertPaper(Paper(
                sha256: FileOps.sha256(of: bytes), fileSize: Int64(bytes.count), ids: PaperIDs(doi: "10.1101/2026.02.27.708412"),
                title: "Eubiota second copy", titleRank: .font, folder: "Papers/_Inbox/0b0b0b0b", pdfName: "b.pdf",
                originalName: "b.pdf", addedAt: importNow, updatedAt: importNow))
            h.events.clear()
            await h.enrich.submit(pk: legacy.pk, holdAI: true)
            await h.enrich.waitUntilIdle()
            await h.ctx.sidecars.flush()
            await h.events.drain()
            let b = try await h.paper(legacy.id)
            #expect(a.ids.doi == "10.64898/2026.02.27.708412")
            #expect(b.ids.doi == "10.1101/2026.02.27.708412")    // the API's DOI belongs to `a`
            #expect(b.stage == .ready)
            #expect(b.titleRank == .api)
            #expect(b.folder == a.folder + "_2")
            let toast = try #require(h.events.toasts.first { $0.message.hasPrefix("可能与已有论文重复") })
            #expect(toast.kind == .info)
            #expect(toast.message.hasPrefix("可能与已有论文重复：Eubiota: Modular Agentic AI"))
            #expect(toast.buttons.map(\.action) == [.openPaper(id: a.id)])
        }
    }

    @Test func mergeRules() {
        var p = Paper(sha256: "s", fileSize: 1, ids: PaperIDs(doi: "10.1101/2026.02.27.708412"), title: "Local",
                      titleRank: .font, folder: "Papers/x", pdfName: "x.pdf", originalName: "x.pdf")
        let meta = BiblioMetadata(title: "Canonical", authors: ["A B"], year: 2026, venue: "bioRxiv", abstract: "Abs",
                                  ids: PaperIDs(doi: "10.64898/2026.02.27.708412", publishedDOI: "10.1038/X"), source: .biorxiv)
        EnrichActor.merge(meta, into: &p, allowDOI: true, allowArxiv: true)
        #expect(p.title == "Canonical" && p.titleRank == .api && p.metaSource == .biorxiv)
        #expect(p.ids.doi == "10.64898/2026.02.27.708412")
        #expect(p.ids.publishedDOI == "10.1038/x")
        #expect(p.authors == ["A B"] && p.year == 2026 && p.abstract == "Abs")

        // Crossref never replaces a DOI the file already has; user titles and edits win.
        var q = Paper(sha256: "t", fileSize: 1, ids: PaperIDs(doi: "10.1/local"), title: "Mine", titleRank: .user,
                      folder: "Papers/y", pdfName: "y.pdf", originalName: "y.pdf")
        EnrichActor.merge(BiblioMetadata(title: "API", ids: PaperIDs(doi: "10.1/other"), source: .crossref),
                          into: &q, allowDOI: true, allowArxiv: true)
        #expect(q.title == "Mine" && q.ids.doi == "10.1/local" && q.metaSource == .crossref)
        var edited = q
        edited.metaUserEdited = true
        edited.metaSource = .user
        EnrichActor.merge(meta, into: &edited, allowDOI: true, allowArxiv: true)
        #expect(edited.metaSource == .user && edited.authors.isEmpty)

        var noDOI = Paper(sha256: "u", fileSize: 1, title: "T", folder: "Papers/z", pdfName: "z.pdf", originalName: "z.pdf")
        EnrichActor.merge(BiblioMetadata(title: "API", ids: PaperIDs(doi: "10.1/new"), source: .crossref),
                          into: &noDOI, allowDOI: false, allowArxiv: true)
        #expect(noDOI.ids.doi == nil)
    }

    @Test func refileFollowsCanonicalNameChanges() async throws {
        try await withHarness { h in
            let summary = await h.importAll([.file(try h.writeSource("refile.pdf"))])
            let id = try #require(summary.added.first)
            let p = try await h.paper(id)
            #expect(p.folder == "Papers/Synthetic-study-of-refile")
            #expect(await h.enrich.refile(pk: p.pk) == false)           // name unchanged

            // An agent card supplied metadata (what applyAgentCard does), then the queue calls refile.
            try await h.db.modifyPaper(pk: p.pk) { q in
                q.title = "Better title from the agent"
                q.titleRank = .agent
                q.authors = ["Jane van der Berg"]
                q.year = 2025
                q.metaSource = .agent
            }
            #expect(await h.enrich.refile(pk: p.pk))
            await h.ctx.sidecars.flush()
            let moved = try await h.paper(id)
            #expect(moved.folder == "Papers/2025_van-der-Berg_Better-title-from-the-agent")
            #expect(moved.pdfName == "2025_van-der-Berg_Better-title-from-the-agent.pdf")
            #expect(moved.nameFinal)
            #expect(moved.stage == .ready)
            #expect(h.paperFolders() == ["2025_van-der-Berg_Better-title-from-the-agent"])
            #expect(try sha(h.ctx.pdfURL(moved)) == moved.sha256)
            #expect(try h.sidecar(moved).pdf == moved.pdfName)
            #expect(await h.enrich.refile(pk: p.pk) == false)

            // A second paper with the same canonical name gets _2 and is left alone afterwards.
            let other = try await h.paper(try #require(await h.importAll([.file(try h.writeSource("other.pdf"))]).added.first))
            try await h.db.modifyPaper(pk: other.pk) { q in
                q.title = "Better title from the agent"; q.authors = ["J. van der Berg"]; q.year = 2025; q.metaSource = .agent
            }
            #expect(await h.enrich.refile(pk: other.pk))
            #expect(try await h.paper(other.id).folder == "Papers/2025_van-der-Berg_Better-title-from-the-agent_2")
            #expect(await h.enrich.refile(pk: other.pk) == false)
        }
    }

    @Test func refreshMetadataRestoresCanonicalRecord() async throws {
        try await withHarness(HarnessConfig(fetcher: MetadataResolverTests.FakeFetcher())) { h in
            let summary = await h.importAll([.file(try h.writeSource("2604.09554v2.pdf"))])
            let id = try #require(summary.added.first)
            let p = try await h.paper(id)
            #expect(p.metaSource == .arxiv)
            #expect(p.title.hasPrefix("LABBench2"))
            let canonicalFolder = p.folder
            try await h.db.modifyPaper(pk: p.pk) { q in q.title = "Scrambled"; q.titleRank = .font }
            #expect(await h.enrich.refreshMetadata(pk: p.pk))
            let refreshed = try await h.paper(id)
            #expect(refreshed.title == p.title)
            #expect(refreshed.folder == canonicalFolder)
            #expect(await h.enrich.refreshMetadata(pk: p.pk) == false)
        }
        try await withHarness { h in           // lookup disabled → nothing to refresh
            let summary = await h.importAll([.file(try h.writeSource("offline.pdf"))])
            let p = try await h.paper(try #require(summary.added.first))
            #expect(await h.enrich.refreshMetadata(pk: p.pk) == false)
        }
    }

    /// Crash simulation: papers stuck at committed / enriched / "moved but not recorded" /
    /// filed are finished by a fresh EnrichActor's resume() exactly once.
    @Test func resumeFinishesInterruptedPapersExactlyOnce() async throws {
        try await withHarness(HarnessConfig(fetcher: HangingFetcher())) { h in
            var items: [IntakeItem] = []
            for i in 1...4 { items.append(.file(try h.writeSource("2601.0000\(i)v1.pdf"))) }
            let summary = await h.intake.ingest(items, options: ImportOptions(origin: .drop))
            #expect(summary.added.count == 4)
            await h.enrich.shutdown()                                   // "crash" while metadata hangs
            var papers = try await h.db.livePapers()
            #expect(papers.map(\.stage) == [.committed, .committed, .committed, .committed])
            #expect(h.ready.all.isEmpty)

            // p1 stays committed. p2: metadata merged, not filed yet.
            try #require(papers.count > 3)          // no index past a failed expectation (QA-15)
            try await h.db.modifyPaper(pk: papers[1].pk) { $0.stage = .enriched }
            // p3: the folder was moved into place but the DB update never happened.
            let p3 = papers[2]
            let base3 = FileNamer.folderName(year: nil, firstAuthor: nil, title: p3.title)
            try await h.db.modifyPaper(pk: p3.pk) { $0.stage = .enriched }
            try FileOps.moveFolder(from: h.ctx.folderURL(p3), to: h.paths.papers.appendingPathComponent(base3))
            // p4: fully filed, not yet ready.
            let p4 = papers[3]
            let base4 = FileNamer.folderName(year: nil, firstAuthor: nil, title: p4.title)
            let dest4 = h.paths.papers.appendingPathComponent(base4)
            try FileOps.moveFolder(from: h.ctx.folderURL(p4), to: dest4)
            try FileOps.atomicRename(from: dest4.appendingPathComponent(p4.pdfName),
                                     to: dest4.appendingPathComponent(FileNamer.pdfName(forFolder: base4)))
            try await h.db.modifyPaper(pk: p4.pk) { q in
                q.folder = "Papers/" + base4; q.pdfName = FileNamer.pdfName(forFolder: base4); q.stage = .filed
            }

            let log = ReadyLog()
            let fresh = EnrichActor(ctx: h.ctx, resolverFactory: { _ in nil }, onReady: { pk, hold in log.record(pk, hold) })
            await fresh.resume()
            await fresh.waitUntilIdle()
            await h.ctx.sidecars.flush()

            papers = try await h.db.livePapers()
            #expect(papers.allSatisfy { $0.stage == .ready })
            #expect(Set(log.all.map(\.pk)) == Set(papers.map(\.pk)))
            #expect(log.all.count == 4)
            #expect(log.all.allSatisfy { $0.hold })                         // resumed jobs never run unconfirmed
            #expect(h.paperFolders().count == 4)
            #expect(h.folderNames(h.paths.inbox).isEmpty)
            #expect(h.partialFiles().isEmpty)
            for p in papers {
                #expect(p.folder.hasPrefix("Papers/") && !p.folder.contains("_Inbox"))
                #expect(!p.flags.contains(.missing))
                #expect(try sha(h.ctx.pdfURL(p)) == p.sha256)
                #expect(try h.sidecar(p).state.stage == .ready)
            }
            #expect(try await h.paper(p3.id).folder == "Papers/" + base3)   // found again, not refiled to _2
            #expect(try await h.paper(p4.id).folder == "Papers/" + base4)

            await fresh.resume()
            await fresh.waitUntilIdle()
            #expect(log.all.count == 4)
            await fresh.shutdown()
        }
    }
}

// MARK: - Real papers (read-only dev fixtures; skipped when absent)

@Suite(.serialized) struct ImportFixtureTests {

    @Test(.enabled(if: allFixturesPresent)) func importsAllFixturesOfflineThenDedupes() async throws {
        try await withHarness(HarnessConfig(extractor: PDFExtractor(), engineActors: true)) { h in
            let summary = await h.importAll(fixtureNames.map { .file(fixtureURL($0)) })
            #expect(summary.added.count == 9)
            #expect(summary.duplicates == 0 && summary.rejected == 0 && summary.failed == 0)
            #expect(summary.heldForAI.count == 9)                      // > 3 in one drop
            let papers = try await h.db.livePapers()
            #expect(papers.count == 9)
            for p in papers {
                #expect(p.stage == .ready, "\(p.originalName)")
                let items = try await h.db.checklist(paperPK: p.pk)
                #expect(!items.isEmpty)
                #expect(items.reduce(0) { $0 + $1.minutes } == p.estMinutes, "\(p.originalName)")
                #expect(p.scheduleMode == .auto && p.deadline != nil, "\(p.originalName)")
                #expect(p.flags.isEmpty, "\(p.originalName)")
                #expect(h.ctx.thumbs.existingCardURL(for: p.id) != nil)
                #expect(h.ctx.texts.exists(id: p.id))
                #expect(try h.sidecar(p).id == p.id)
                let name = (p.folder as NSString).lastPathComponent
                #expect(p.folder == "Papers/" + name && name != "_Inbox")
                #expect(name.count > 12 && name.contains("-"), "unreadable folder name \(name)")
                #expect(p.pdfName == name + ".pdf")
                let copy = h.ctx.pdfURL(p)
                #expect(mode(copy) & S_IWUSR != 0)                      // fixtures are 0444
                #expect(FileOps.fileSize(copy) == p.fileSize)
            }
            #expect(h.paperFolders().count == 9)
            #expect(h.partialFiles().isEmpty)
            #expect(h.folderNames(h.paths.inbox).isEmpty)
            #expect(Set(papers.compactMap(\.ids.doi)).contains("10.1038/s41586-024-08351-7"))
            #expect(try await h.db.search("neocortex").count >= 1)

            let again = await h.importAll(fixtureNames.map { .file(fixtureURL($0)) })
            #expect(again.duplicates == 9)
            #expect(again.added.isEmpty)
            #expect(try await h.db.livePapers().count == 9)
            #expect(h.partialFiles().isEmpty)

            if fakeFixturePresent {
                let bad = await h.importAll([.file(URL(fileURLWithPath: fixtureDir + "/bad/fake.pdf"))])
                #expect(bad.rejected == 1)
                #expect(try await h.db.livePapers().count == 9)
            }
        }
    }

    @Test(.enabled(if: natureFixturePresent)) func nature35MBCommitsQuickly() async throws {
        try await withHarness(HarnessConfig(extractor: PDFExtractor())) { h in
            let start = ContinuousClock.now
            let summary = await h.intake.ingest([.file(fixtureURL(natureFixture))], options: ImportOptions(origin: .drop))
            let elapsed = ContinuousClock.now - start
            #expect(summary.added.count == 1)
            // Load-tolerant (ENV-1): the commit never waits for the 35 MB extraction; generous on a busy machine.
            #expect(elapsed < .seconds(8), "commit took \(elapsed)")
            await h.enrich.waitUntilIdle()
            let p = try await h.paper(try #require(summary.added.first))
            #expect(p.pageCount == 49)
            #expect(p.title == "Molecular and cellular dynamics of the developing human neocortex")
        }
    }

    /// A re-downloaded arXiv PDF: different bytes (appended trailer), same id, newer version.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: fixtureDir + "/2606.24530v2.pdf")))
    func sameWorkWithRealPDF() async throws {
        try await withHarness(HarnessConfig(extractor: PDFExtractor())) { h in
            let first = await h.importAll([.file(fixtureURL("2606.24530v2.pdf"))])
            let id = try #require(first.added.first)
            let before = try await h.paper(id)
            let checklist = try await h.db.checklist(paperPK: before.pk)

            var bytes = try Data(contentsOf: fixtureURL("2606.24530v2.pdf"))
            bytes.append(Data("\n% re-downloaded copy\n".utf8))
            let v3 = h.sources.appendingPathComponent("2606.24530v3.pdf")
            try bytes.write(to: v3)
            let second = await h.importAll([.file(v3)])
            #expect(second.added.isEmpty)
            let pendingID = try #require(await h.intake.pendingIDs().first)
            #expect(h.events.toasts.last?.message == "同一论文已在库中（v2）· 新文件 v3")

            await h.intake.resolvePending(pendingID: pendingID, replace: true)
            let after = try await h.paper(id)
            #expect(after.sha256 == (try sha(v3)))
            #expect(after.ids.arxivVersion == 3)
            #expect(after.pageCount == before.pageCount)
            #expect(after.flags.isEmpty)
            #expect(after.deadline == before.deadline)
            #expect(try await h.db.checklist(paperPK: before.pk) == checklist)
            #expect(try sha(h.ctx.pdfURL(after)) == after.sha256)
            #expect(try h.ctx.texts.load(id: id)?.contains("NatureBench") == true)
            #expect(h.partialFiles().isEmpty)
            #expect(try await h.db.livePapers().count == 1)
        }
    }

    @Test(.enabled(if: allFixturesPresent)) func canonicalMetadataFromRecordedResponses() async throws {
        try await withHarness(HarnessConfig(fetcher: MetadataResolverTests.FakeFetcher(), extractor: PDFExtractor())) { h in
            let summary = await h.importAll(fixtureNames.map { .file(fixtureURL($0)) })
            #expect(summary.added.count == 9)
            let papers = try await h.db.livePapers()
            let canonical = papers.filter { $0.titleRank == .api && $0.metaSource != .none && $0.nameFinal }
            #expect(canonical.count == 9, "\(papers.filter { $0.titleRank != .api }.map(\.originalName))")
            for p in papers {
                #expect(p.stage == .ready)
                let name = (p.folder as NSString).lastPathComponent
                #expect(name.range(of: #"^20\d\d_"#, options: .regularExpression) != nil, "\(name)")
                #expect(p.pdfName == name + ".pdf")
            }
            let nature = try #require(papers.first { $0.originalName == natureFixture })
            // Crossref: published online 2025-01-08 (the DOI says 2024).
            #expect(nature.folder == "Papers/2025_Wang_Molecular-and-cellular-dynamics-of-the-developing-human-neocortex")
            #expect(nature.venue == "Nature")
            #expect(nature.abstract?.isEmpty == false)
            let eubiota = try #require(papers.first { $0.originalName == "2026.02.27.708412.full.pdf" })
            #expect(eubiota.ids.doi == "10.64898/2026.02.27.708412")
            #expect(h.paperFolders().count == 9)
            #expect(h.folderNames(h.paths.inbox).isEmpty)
        }
    }
}
