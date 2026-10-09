import CoreGraphics
import Foundation
import Testing
@testable import PaperDeckCore

/// Shared fixtures of the Explain UI tests: an engine in a temporary root whose only assist backend
/// is the zero-quota mock (both card providers are signed-out stand-ins: no CLI can be reached),
/// settings the test changes while the engine reads them, papers, and the panel services over that
/// engine with fake capture-lane parts (no OCR, no locator, a fixed prompt).
enum ExplainUITestKit {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var settings: EngineSettings
        private var t: Date
        init(_ s: EngineSettings, now: Date) { settings = s; t = now }
        var value: EngineSettings { lock.withLock { settings } }
        func update(_ f: (inout EngineSettings) -> Void) { lock.withLock { f(&settings) } }
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
    }

    struct World {
        let engine: Engine
        let root: URL
        let box: Box
        let mock: MockAssistBackend

        func close() async {
            await engine.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// `mode`: `assist.mode` at the start (mock by default; `off` to test the switch).
    static func world(mode: AssistMode = .mock, behavior: MockAssistBackend.Behavior = .answer) async throws -> World {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-explainui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var s = EngineSettings(metadataLookup: false)
        s.lang = .en
        s.assist.mode = mode
        let box = Box(s, now: t0)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let mock = MockAssistBackend(behavior: behavior)
        let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: Engine.Dependencies(
            loadSettings: { box.value }, now: { box.now }, calendar: cal, fetcher: nil,
            claude: MockAgentProvider(behavior: .notLoggedIn), codex: MockAgentProvider(behavior: .notLoggedIn),
            sidecarDelay: .milliseconds(10), cliFacts: .inMemory(), loadMailSettings: { MailSettings() },
            mailSecrets: InMemoryMailSecretStore(), assistBackends: [mock]))
        return World(engine: engine, root: root, box: box, mock: mock)
    }

    static func paper(_ engine: Engine, title: String = "Blastema Signalling", notes: String = "") async throws -> Paper {
        let id = UUID().uuidString.lowercased()
        let sha = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let folder = "Papers/_Inbox/\(sha.prefix(8))"
        try FileManager.default.createDirectory(at: engine.paths.library.appendingPathComponent(folder), withIntermediateDirectories: true)
        var p = Paper(id: id, sha256: sha, fileSize: 1000, title: title, titleRank: .font, pageCount: 6, charCount: 10,
                      folder: folder, pdfName: "paper.pdf", originalName: "paper.pdf", stage: .ready, addedAt: t0, updatedAt: t0)
        p.notes = notes
        return try await engine.db.insertPaper(p)
    }

    /// A fixed prompt (the capture lane's builder in the app): the selection, the kind, the image.
    static func prompt(_ spec: ExplainTurnSpec) -> AssistRequest {
        let text = "<task kind=\"\(spec.kind.actionCode)\" lang=\"\(spec.language.rawValue)\"/>\n<selection>\n"
            + BlockTags.neutralize(spec.prepared.selection ?? "") + "\n</selection>"
            + (spec.kind.question.map { "\n<question>\n" + BlockTags.neutralize($0) + "\n</question>" } ?? "")
        return AssistRequest(surface: .explain, systemPrompt: "SYSTEM", turnText: text,
                             image: spec.sendImage ? spec.prepared.image : nil, model: "prompt-default",
                             limits: AssistLimits.defaults(for: .explain, provider: nil))
    }

    /// The panel services over `w`'s engine; `match` is what the fake locator answers.
    @MainActor
    static func services(_ w: World, match: PaperMatch? = nil, content: ExplainPrepared.Content = .text,
                         prepared: (@MainActor (ExplainCapture) -> ExplainPrepared)? = nil) -> ExplainEngineServices {
        ExplainEngineServices(engine: w.engine, prepare: { capture, anchor in
            if let prepared { return prepared(capture) }
            let m = anchor.map { PaperMatch(paperID: $0.paperID, page: $0.page, via: .reader, score: 1) } ?? match
            return ExplainPrepared(selection: capture.text ?? anchor?.text, image: capture.image, content: content, match: m)
        }, build: { spec in prompt(spec) })
    }

    @MainActor
    static func panel(_ services: any ExplainServicing, capture: ExplainCapture = ExplainCapture(source: .clipboard, text: excerpt),
                      anchor: ReaderAnchor? = nil, language: UILang = .zh) -> ExplainPanelState {
        ExplainPanelState(capture: capture, anchor: anchor, services: services, language: language, depth: .quick)
    }

    static let excerpt = "We regularize the attention weights by a temperature-scaled softmax."

    /// A ticket as a click would mint it (tests stand in for the App's action handlers).
    static func ticket(_ g: ConsentTicket.Gesture = .clipboard, at date: Date = t0) -> ConsentTicket {
        ConsentTicket.mint(g, surface: .explain, now: date)
    }

    /// A synthetic image (solid or noisy).
    static func image(width: Int, height: Int, noise: Bool = false) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if noise, let data = ctx.data {
            var g = SystemRandomNumberGenerator()
            let p = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height)
            for y in 0..<height {
                for x in 0..<width {
                    let o = y * ctx.bytesPerRow + x * 4
                    p[o] = UInt8.random(in: 0...255, using: &g); p[o + 1] = UInt8.random(in: 0...255, using: &g)
                    p[o + 2] = UInt8.random(in: 0...255, using: &g); p[o + 3] = 255
                }
            }
        } else {
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 8))
        }
        return ctx.makeImage()!
    }
}

/// Services whose turns are scripted (the failure paths the mock backend can't produce: caps,
/// pauses, login), recording what was asked.
@MainActor
final class ScriptedExplainServices: ExplainServicing {
    var settings = AssistSettings(mode: .claude)
    var verdict: AssistPrivacy.Verdict? = .ok
    var prepared = ExplainPrepared(selection: ExplainUITestKit.excerpt, image: nil, content: .text, match: nil)
    /// One script per submit, in order (the last repeats).
    var scripts: [[AssistEvent]] = [[.delta("Answer."), .done(text: "Answer.", meta: AssistMeta(provider: "claude", model: "haiku"))]]
    private(set) var submitted: [(AssistRequest, ConsentTicket)] = []
    private(set) var saved: [ExplanationRecord] = []
    private(set) var pinnedCalls: [([String], Bool)] = []
    private(set) var notes: [String] = []
    private(set) var closed: [String] = []
    private(set) var cancels = 0
    private(set) var prepares = 0

    var assistSettings: AssistSettings { settings }
    var now: Date { ExplainUITestKit.t0 }
    func prepare(_ capture: ExplainCapture, anchor: ReaderAnchor?) async -> ExplainPrepared { prepares += 1; return prepared }
    func privacy(paperID: String?, hostBundleID: String?) async -> AssistPrivacy.Verdict? { verdict }
    func request(_ spec: ExplainTurnSpec) -> AssistRequest {
        ExplainEngineServices.finish(ExplainUITestKit.prompt(spec), spec: spec, settings: settings)
    }
    func submit(_ request: AssistRequest, ticket: ConsentTicket) async -> AsyncStream<AssistEvent> {
        let i = min(submitted.count, scripts.count - 1)
        submitted.append((request, ticket))
        let events = scripts[i]
        return AsyncStream { c in
            for e in events { c.yield(e) }
            c.finish()
        }
    }
    func cancelTurn() async { cancels += 1 }
    func closeSession(threadKey: String) async { closed.append(threadKey) }
    func save(_ record: ExplanationRecord, anchor: ReaderAnchor?) async throws -> ExplanationRecord { saved.append(record); return record }
    func setPinned(ids: [String], _ pinned: Bool) async { pinnedCalls.append((ids, pinned)) }
    func appendToNotes(id: String) async throws { notes.append(id) }
}
