import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PaperDeckCore

/// Shared fixtures of the Operations test suites: temp-rooted engines with a controllable
/// clock and settings, and papers inserted the way the import pipeline leaves them
/// (folder + PDF under Papers/, heuristic checklist, card.json synced).
enum OpsTestKit {
    static let timeZone = TimeZone(identifier: "America/Chicago")!
    static var calendar: Calendar { LocalDate.gregorian(timeZone) }
    /// Tuesday 2026-09-29 10:00 local — the §6.3 worked example's "now".
    static var start: Date { day(2026, 9, 29).date(hour: 10, minute: 0, calendar: calendar) }
    static let weekdays: Set<Int> = [2, 3, 4, 5, 6]          // Mon–Fri

    static func day(_ y: Int, _ m: Int, _ d: Int) -> LocalDate { LocalDate(year: y, month: m, day: d) }

    /// Mutable value behind a lock (clock, settings) — the engine reads it through closures.
    final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    struct Env: Sendable {
        let engine: Engine
        let root: URL
        let clock: Box<Date>
        let settings: Box<EngineSettings>

        var paths: AppPaths { engine.paths }
        var db: Database { engine.db }

        func advance(_ seconds: TimeInterval) { clock.value = clock.value.addingTimeInterval(seconds) }

        func cleanup() async {
            await engine.shutdown()
            await engine.db.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func settings(budget: Int = 60, weekdays: Set<Int> = OpsTestKit.weekdays, lang: UILang = .zh,
                         autoDone: Bool = true) -> EngineSettings {
        EngineSettings(plan: PlanSettings(dailyBudgetMinutes: budget, readingWeekdays: weekdays),
                       lang: lang, agentMode: .off, metadataLookup: false, autoMarkDone: autoDone)
    }

    static func newRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-ops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func make(_ settings: EngineSettings = OpsTestKit.settings(), root: URL? = nil,
                     now: Date = OpsTestKit.start) async throws -> Env {
        let root = try root ?? newRoot()
        let clock = Box(now)
        let box = Box(settings)
        let deps = Engine.Dependencies(loadSettings: { box.value }, now: { clock.value }, calendar: calendar,
                                       fetcher: nil, claude: MockAgentProvider(), codex: MockAgentProvider(), mock: MockAgentProvider(),
                                       sidecarDelay: .milliseconds(10), assistBackends: [MockAssistBackend()])
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: deps)
        return Env(engine: engine, root: root, clock: clock, settings: box)
    }

    /// Runs `body` with a fresh engine and always cleans up (engine shut down, temp root removed).
    static func run(_ settings: EngineSettings = OpsTestKit.settings(), now: Date = OpsTestKit.start,
                    _ body: (Env) async throws -> Void) async throws {
        let env = try await make(settings, now: now)
        do {
            try await body(env)
        } catch {
            await env.cleanup()
            throw error
        }
        await env.cleanup()
    }

    /// The import-time checklist: fixed 5′ abstract + weighted rows (Σ = 60 by default).
    static func heuristicChecklist(_ minutes: [Int] = [5, 30, 20, 5]) -> [ChecklistItem] {
        minutes.enumerated().map { i, m in
            ChecklistItem(ord: Double(i), text: "Step \(i + 1)", section: i == 0 ? "Abstract" : "Section \(i)",
                          page: i + 1, minutes: m, kind: i == 0 ? .overview : .other, origin: .heuristic)
        }
    }

    /// Unique, tiny "PDF" bytes (operations never parse the PDF).
    static func pdfBytes(_ tag: String) -> Data { Data("%PDF-1.4\n% \(tag)\n%%EOF\n".utf8) }

    /// Creates `Papers/<folder>/<folder>.pdf` and inserts the row + checklist, then syncs card.json.
    @discardableResult
    static func addPaper(_ env: Env, title: String = "A paper", folder: String? = nil, doi: String? = nil,
                         arxiv: String? = nil, deadline: LocalDate? = nil, mode: ScheduleMode = .auto,
                         origin: DeadlineOrigin = .place, priority: Priority = .normal, est: Int? = 60,
                         checklist: [ChecklistItem]? = nil, status: PaperStatus = .toRead,
                         stage: PaperStage = .ready, inInbox: Bool = false, provisional: Bool = false,
                         addedAt: Date? = nil) async throws -> Paper {
        let name = folder ?? "2026_Test_\(title.replacingOccurrences(of: " ", with: "-"))_\(UUID().uuidString.prefix(4))"
        let parent = inInbox ? env.paths.inbox : env.paths.papers
        let dir = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let bytes = pdfBytes(UUID().uuidString)
        let pdfName = FileNamer.pdfName(forFolder: name)
        try bytes.write(to: dir.appendingPathComponent(pdfName))
        let relative = (inInbox ? "Papers/_Inbox/" : "Papers/") + name
        let paper = Paper(sha256: FileOps.sha256(of: bytes), fileSize: Int64(bytes.count),
                          ids: PaperIDs(doi: doi, arxivID: arxiv), title: title, titleRank: .api,
                          authors: ["Li Wang", "Arnold R. Kriegstein"], year: 2024, venue: "Nature",
                          metaSource: .crossref, pageCount: 12, folder: relative, pdfName: pdfName,
                          originalName: "original-\(name).pdf", nameFinal: true, stage: stage, status: status,
                          priority: priority, deadline: mode == .none ? nil : deadline, scheduleMode: mode,
                          deadlineOrigin: origin, provisional: provisional, estMinutes: est,
                          addedAt: addedAt ?? env.clock.value, updatedAt: env.clock.value)
        let saved = try await env.db.insertPaper(paper, checklist: checklist ?? heuristicChecklist())
        await env.engine.ctx.syncSidecar(pk: saved.pk)
        return saved
    }

    static func paper(_ env: Env, _ id: String) async throws -> Paper {
        try #require(try await env.db.paper(id: id))
    }

    static func checklist(_ env: Env, _ id: String) async throws -> [ChecklistItem] {
        try await env.db.checklist(paperPK: try await paper(env, id).pk)
    }

    /// A decodable 560×240 JPEG (card thumbnail stand-in).
    static func jpeg(width: Int = 560, height: Int = 240) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
