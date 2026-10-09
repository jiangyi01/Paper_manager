import AppKit
import CoreGraphics
import CoreText
import SwiftUI
import PaperDeckCore
import PaperDeckShared

/// `--explain-render OUTDIR --root SCRATCH [--lang en|zh] [--appearance light|dark]` (READING_ASSIST_PLAN
/// §9.1 render checks; Explain UI lane, A2/A4): every state of the explanation panel (locating,
/// starting, waiting, streaming, done with follow-ups, an image capture, stopped, cut off, the
/// question panel, and each refusal / failure: off, privacy confirmation, ask before send, soft and
/// hard cap, usage limit, login, timeout, never-AI), the overlay (capture off with the clipboard
/// offer, the image offer, no offer, capture on, a failed capture; the frame's box, a ⌥ figure box
/// and its crosshair, the lens and a ⇧ term over a frozen fixture screen drawn in memory), the
/// Screen Recording explainer, Settings ▸ Explain &
/// Ask with the Explain section, the inspector's Explanations section and the history window, from a
/// generated scratch library.
///
/// Mock only: the engine's card providers are mocks (signed out), its only assist backend is
/// `MockAssistBackend` and its `assist.mode` is `mock`; no state here sends a turn (every panel is a
/// fixture over no-op services), no CLI is located, probed or spawned, no screen is captured (the
/// Screen Recording status is a fixture) and no hotkey or Services provider is installed. Settings
/// live in their own suite `<bundle>.explain-render`, removed afterwards; windows are drawn
/// transparent, never shown.
enum ExplainRenders {
    /// Marks a scratch root this mode built (it refuses any other non-empty root).
    static let marker = ".paperdeck-explain-render"
    static let panelSize = NSSize(width: 420, height: 520)

    static func run(_ args: CLIArgs) async -> Int32 {
        guard let out = args.positional.map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }),
              let root = args.url("--root") else {
            return CLIRunner.fail("--explain-render OUTDIR --root SCRATCH_ROOT [--lang en|zh] [--appearance light|dark]")
        }
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        if !existing.isEmpty, !existing.contains(marker) {
            return CLIRunner.fail("--root must be an empty scratch folder (or one --explain-render made): \(root.path)")
        }
        for name in existing { try? fm.removeItem(at: root.appendingPathComponent(name)) }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent(marker))
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
        } catch {
            return CLIRunner.fail("\(error)")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let lang = UILang(rawValue: args.value("--lang") ?? "en") ?? .en
        let appearanceName = args.value("--appearance") == "dark" ? "dark" : "light"
        let appearance = NSAppearance(named: appearanceName == "dark" ? .darkAqua : .aqua)
        let suffix = "\(lang.rawValue)-\(appearanceName)"
        let suite = "\(BuildIdentity.current.bundleID).explain-render"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        var initial = EngineSettings(plan: PlanSettings(), lang: lang, agentMode: .off, autoReadNewPapers: false,
                                     metadataLookup: false)
        initial.assist.mode = .mock
        let engineSettings = SharedValue(initial)
        let deps = Engine.Dependencies(loadSettings: { engineSettings.get }, fetcher: nil,
                                       claude: MockAgentProvider(behavior: .notLoggedIn),
                                       codex: MockAgentProvider(behavior: .notLoggedIn), mock: MockAgentProvider(),
                                       sidecarDelay: .milliseconds(20), cliFacts: .inMemory(),
                                       loadMailSettings: { MailSettings() }, mailSecrets: InMemoryMailSecretStore(),
                                       assistBackends: [MockAssistBackend()])
        ExplainSettingsSection.previewOverride = true
        ExplanationsSection.previewOverride = true
        ExplainSettingsSection.previewScreenRecording = false
        HotKeyRecorderView.previewStatus = .registered
        defer {
            ExplainSettingsSection.previewOverride = false
            ExplanationsSection.previewOverride = false
            ExplainSettingsSection.previewScreenRecording = nil
            HotKeyRecorderView.previewStatus = nil
        }
        do {
            let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: deps)
            let store = SettingsStore(defaults: defaults, domain: suite)
            store.onMailSettingsChange = { _ in }
            store.language = lang
            store.agentMode = AgentMode.off.rawValue
            store.assist.mode = .claude                  // the chrome reads "Claude"; nothing is sent
            let state = AppState(engine: engine, settings: store)
            state.start()
            let fixture = try await Fixture.build(engine: engine, root: root, lang: lang)
            state.scheduleRefresh(delay: .zero)
            var waited = 0
            while (state.snapshot?.rows.count ?? 0) < fixture.ids.count && waited < 150 {
                try await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            state.assist.update(AssistStatus(mode: .claude, provider: .ready(plan: "pro", version: "mock"), todayCount: 12))
            try await draw(state: state, fixture: fixture, appearance: appearance, out: out, suffix: suffix)
            state.stop()
            await engine.shutdown()
            return 0
        } catch {
            return CLIRunner.fail(String(describing: error))
        }
    }

    // MARK: - Drawing

    private static func draw(state: AppState, fixture: Fixture, appearance: NSAppearance?, out: URL, suffix: String) async throws {
        func png(_ name: String) -> URL { out.appendingPathComponent("explain-\(name)-\(suffix).png") }
        let services = RenderServices()
        let started = Date().addingTimeInterval(-4)
        let now = Date()
        let zh = fixture.lang == .zh
        let main = fixture.ids[0]
        let excerpt = Fixture.excerpt
        let anchor = ReaderAnchor(paperID: main, kind: .selection, page: 3, rect: CGRect(x: 72, y: 400, width: 460, height: 48),
                                  pageBounds: CGRect(x: 0, y: 0, width: 612, height: 792), text: excerpt)
        let matched = ExplainPrepared(selection: excerpt, image: nil, content: .text,
                                      match: PaperMatch(paperID: main, page: 3, via: .reader, score: 1))
        let unmatched = ExplainPrepared(selection: excerpt, image: nil, content: .text, match: nil)
        let meta = AssistMeta(provider: "claude", model: "haiku", turnIndex: 0, ttftMs: 2_100, totalMs: 6_200)

        func panel(_ name: String, capture: ExplainCapture = ExplainCapture(source: .clipboard, text: excerpt),
                   anchor: ReaderAnchor? = nil, phase: ExplainPhase, turns: [ExplainTurn] = [],
                   prepared: ExplainPrepared?, pinned: Bool = false, language: UILang? = nil,
                   height: CGFloat = panelSize.height) async throws {
            let s = ExplainPanelState(capture: capture, anchor: anchor, services: services,
                                      language: language ?? (zh ? .zh : .en), depth: .quick)
            s.applyRenderFixture(phase: phase, turns: turns, prepared: prepared, pinned: pinned)
            let view = ExplainPanelView(state: s, app: state, focus: ExplainPanelFocus(), style: .material, previewNow: now)
                .frame(width: panelSize.width, height: height)
            try await PreviewRenderer.captureView(view, size: NSSize(width: panelSize.width, height: height),
                                                  appearance: appearance, png("panel-" + name))
        }
        func turn(_ index: Int, _ kind: ExplainTurnKind, _ text: String, done: Bool = true, image: Bool = false) -> ExplainTurn {
            var t = ExplainTurn(index: index, kind: kind, language: zh ? .zh : .en, depth: .quick, sentImage: image,
                                text: text, startedAt: started)
            if done { t.meta = meta; t.recordID = "r\(index)" }
            return t
        }

        // Local work, then the turn on its way.
        try await panel("locating", phase: .locating, prepared: nil)
        try await panel("starting", phase: .sending(.starting), turns: [turn(0, .explain, "", done: false)], prepared: unmatched)
        try await panel("still-waiting", phase: .sending(.stillWaiting), turns: [turn(0, .explain, "", done: false)],
                        prepared: unmatched)
        // Streaming: partial Markdown with the caret, in a reader explanation (paper · page).
        try await panel("streaming", capture: ExplainCapture(source: .reader, text: excerpt), anchor: anchor, phase: .streaming,
                        turns: [turn(0, .explain, Fixture.partial(zh), done: false)], prepared: matched)
        // Done: the answer, a chip turn and a follow-up; pinned.
        try await panel("done", capture: ExplainCapture(source: .reader, text: excerpt), anchor: anchor, phase: .done,
                        turns: [turn(0, .explain, Fixture.answer(zh)), turn(1, .simpler, Fixture.simpler(zh)),
                                turn(2, .ask(Fixture.question(zh)), Fixture.followUpAnswer(zh))],
                        prepared: matched, pinned: true, height: 640)
        // The language switched after an answer: "Explain again in …".
        try await panel("done-language", phase: .done, turns: [turn(0, .explain, Fixture.answer(false))], prepared: unmatched,
                        language: .zh)
        // An image (a dropped screenshot): the thumbnail, "Explain the figure", the image toggle.
        if let image = Fixture.figureImage() {
            let prepared = ExplainPrepared(selection: zh ? "图 3：再生速度" : "Figure 3: regrowth rate", image: image, content: .mixed,
                                           match: nil)
            try await panel("image", capture: ExplainCapture(source: .drop, image: image), phase: .done,
                            turns: [turn(0, .figure, Fixture.figureAnswer(zh), image: true)], prepared: prepared)
        }
        // Stopped and cut off.
        var stopped = turn(0, .explain, Fixture.partial(zh), done: false)
        stopped.stopped = true
        try await panel("stopped", phase: .done, turns: [stopped], prepared: unmatched)
        var cut = turn(0, .explain, Fixture.answer(zh), done: false)
        cut.cutOff = true
        try await panel("cut-off", phase: .error(.outputCap), turns: [cut], prepared: unmatched)
        // "Ask PaperDeck…" from Services: the question field, nothing sent.
        try await panel("question", capture: ExplainCapture(source: .services, text: excerpt), phase: .idle, prepared: nil)

        // Refusals and failures.
        state.settings.assist.mode = .off
        try await panel("off", phase: .refused(.off), prepared: unmatched)
        state.settings.assist.mode = .claude
        try await panel("confirm-privacy", capture: ExplainCapture(source: .clipboard, text: excerpt, hostBundleID: "com.apple.mail"),
                        phase: .refused(.confirmPrivacy([.markedConfidential, .messagingHost])), prepared: unmatched)
        try await panel("ask-before-send", phase: .refused(.askBeforeSend), prepared: unmatched)
        try await panel("soft-cap", phase: .refused(.softCap(50)), prepared: unmatched)
        try await panel("hard-cap", phase: .refused(.hardCap(150)), prepared: unmatched)
        try await panel("blocked", phase: .refused(.blocked), prepared: matched)
        try await panel("empty", phase: .refused(.emptyCapture), prepared: ExplainPrepared(selection: nil, image: nil, content: .text, match: nil))
        let reset = Calendar.current.date(bySettingHour: 15, minute: 45, second: 0, of: Date())
        try await panel("limited", phase: .limited(until: reset), prepared: unmatched)
        try await panel("needs-login", phase: .needsLogin(.loggedOut), prepared: unmatched)
        try await panel("timeout", phase: .error(.timeout), turns: [], prepared: unmatched)

        // The overlay (one display's content; the HUD and cards).
        let screen = NSSize(width: 1280, height: 800)
        func overlay(_ name: String, allowed: Bool, offer: ClipboardOffer?, mode: AssistSettings.OverlayMode = .frame,
                     failed: Bool = false) async throws {
            let m = CaptureOverlayModel()
            m.captureAllowed = allowed
            m.hasCaptureLayer = allowed
            m.freezeFailed = failed
            m.offer = offer
            m.mode = mode
            m.hotkey = HotKeySpec.display(.defaultExplain)
            try await PreviewRenderer.captureView(CaptureOverlayView(model: m, active: true, layer: nil, style: .material)
                                                    .frame(width: screen.width, height: screen.height),
                                                  size: screen, appearance: appearance, png("overlay-" + name))
        }
        try await overlay("capture-off-text", allowed: false, offer: ClipboardOffer(content: .text, changeCount: 7))
        try await overlay("capture-off-image", allowed: false, offer: ClipboardOffer(content: .image, changeCount: 8))
        try await overlay("capture-off-none", allowed: false, offer: nil)
        // Capture on, the still not drawn yet (the HUD and the offer over the live screen).
        try await overlay("capture-on", allowed: true, offer: ClipboardOffer(content: .text, changeCount: 9), mode: .lens)
        // The still couldn't be taken (not a refusal): the ways that need nothing.
        try await overlay("capture-failed", allowed: true, offer: nil, failed: true)

        // The frame and the lens over a frozen fixture screen (what the user draws on): a box over a
        // paragraph with its size, a box held with ⌥ (a figure), the crosshair before a drag, the
        // lens over the text and, with ⇧, over a term. No capturer is involved: the still is drawn here.
        if let still = Fixture.screen(size: screen) {
            let display = FrozenDisplay(id: 1, frame: CGRect(origin: .zero, size: screen), scale: 2, image: still)
            func layered(_ name: String, mode: AssistSettings.OverlayMode, box: CGRect? = nil, cursor: CGPoint? = nil,
                         zoom: CGFloat = CaptureGesture.defaultZoom, option: Bool = false, shift: Bool = false,
                         offer: ClipboardOffer? = nil) async throws {
                let m = CaptureOverlayModel()
                m.captureAllowed = true
                m.hasCaptureLayer = true
                m.frozenReady = true
                m.mode = mode
                m.offer = offer
                m.optionHeld = option
                m.shiftHeld = shift
                m.hotkey = HotKeySpec.display(.defaultExplain)
                let layer = CaptureLayerModel(displayID: 1, size: screen, still: display)
                if let box {
                    layer.dragStart = box.origin
                    layer.dragEnd = CGPoint(x: box.maxX, y: box.maxY)
                }
                layer.cursor = cursor ?? box.map { CGPoint(x: $0.maxX, y: $0.maxY) }
                layer.zoom = zoom
                let view = CaptureOverlayView(model: m, active: true, layer: AnyView(CaptureLayerView(layer: layer, overlay: m)),
                                              style: .material)
                try await PreviewRenderer.captureView(view.frame(width: screen.width, height: screen.height),
                                                      size: screen, appearance: appearance, png("overlay-" + name))
            }
            try await layered("frame-box", mode: .frame, box: Fixture.paragraphBox, offer: ClipboardOffer(content: .text, changeCount: 9))
            try await layered("frame-figure", mode: .frame, box: Fixture.figureBox, option: true)
            try await layered("frame-hover", mode: .frame, cursor: Fixture.hoverPoint)
            try await layered("lens", mode: .lens, cursor: Fixture.lensPoint)
            try await layered("lens-term", mode: .lens, cursor: Fixture.termPoint, zoom: 3.2, shift: true)
            // The capture / panel fixes' states (fix-capture-ux, R-UX-7): fixtures only, nothing sent.
            try await ExplainUXRenders.draw(state: state, paperID: main, excerpt: excerpt, appearance: appearance, png: png)
        }
        try await PreviewRenderer.captureView(ScreenRecordingExplainer(), size: nil, appearance: appearance, png("screen-explainer"))

        // Settings ▸ Explain & Ask with the Explain section (as it ships), on.
        let settingsSize = NSSize(width: 640, height: 1180)
        try await PreviewRenderer.captureView(AssistSettingsTab(state: state).formStyle(.grouped)
                                                .frame(width: settingsSize.width, height: settingsSize.height),
                                              size: settingsSize, appearance: appearance, png("settings"))

        // The inspector's Explanations section (stored explanations of the paper) and the history window.
        if let row = state.snapshot?.row(id: main) {
            let inspector = NSSize(width: 380, height: 760)
            let records = (try? await state.engine.explanations(paperID: main, limit: 50)) ?? []
            try await PreviewRenderer.captureView(ScrollView { ExplanationsSection.preview(state: state, row: row, records: records).padding(16) }
                                                    .frame(width: inspector.width, height: inspector.height),
                                                  size: inspector, appearance: appearance, png("inspector-section"))
        }
        let history = ExplainHistoryModel(paperID: nil, app: state)
        await history.load()
        try await PreviewRenderer.captureView(ExplainHistoryWindowView(model: history, app: state).frame(width: 520, height: 640),
                                              size: NSSize(width: 520, height: 640), appearance: appearance, png("history"))
        let empty = ExplainHistoryModel(paperID: "none", app: state)
        empty.applyRenderFixture([])
        try await PreviewRenderer.captureView(ExplainHistoryWindowView(model: empty, app: state).frame(width: 520, height: 360),
                                              size: NSSize(width: 520, height: 360), appearance: appearance, png("history-empty"))
    }

    // MARK: - Fixture

    struct Fixture {
        let lang: UILang
        let ids: [String]

        static let titles = ["Blastema Signalling Drives Zebrafish Fin Regeneration", "A Confidential Manuscript on Fin Growth"]
        static let excerpt = "We regularize the attention weights by a temperature-scaled softmax so that the blastema signal dominates early regrowth."

        static func partial(_ zh: Bool) -> String {
            zh ? "**要点**：作者用带温度的 softmax（temperature-scaled softmax）来**约束注意力权重**，\n\n- 让芽基（blastema）信号在早期"
               : "**Gist:** the authors **constrain the attention weights** with a temperature-scaled softmax,\n\n- so the blastema signal dominates"
        }
        static func answer(_ zh: Bool) -> String {
            zh ? "**要点**：作者用带温度的 softmax（temperature-scaled softmax）来约束注意力权重，让芽基（blastema）信号在再生早期占主导。\n\n- **温度 τ**：τ 越小，分布越尖锐，少数位置得到大部分权重\n- **为什么这样做**：早期再生主要由芽基驱动，模型因此更关注它\n- **注意**：τ 是超参数，文中未给出敏感性分析"
               : "**Gist:** the authors constrain the attention weights with a temperature-scaled softmax, so the blastema signal dominates early regrowth.\n\n- **Temperature τ**: a smaller τ makes the distribution sharper, so a few positions take most of the weight\n- **Why**: early regeneration is driven mainly by the blastema, so the model attends to it\n- **Caveat**: τ is a hyperparameter; the paper reports no sensitivity analysis"
        }
        static func simpler(_ zh: Bool) -> String {
            zh ? "简单说：模型被调成更「专注」，只盯着最重要的那部分信号（芽基）。" : "In short: the model is tuned to focus hard on the most important signal (the blastema)."
        }
        static func question(_ zh: Bool) -> String { zh ? "τ 一般取多少？" : "What value of τ is typical?" }
        static func followUpAnswer(_ zh: Bool) -> String {
            zh ? "常见取值在 0.1–1 之间；本文没有写明，可以看补充材料。" : "Values between 0.1 and 1 are common; this paper doesn't state it, so check the supplement."
        }
        static func figureAnswer(_ zh: Bool) -> String {
            zh ? "**图 3**：横轴是截肢后的天数，纵轴是恢复的鳍长百分比。\n\n- 第 14 天约恢复 92%\n- 前 4 天增长最快" : "**Figure 3**: days after amputation (x) against regrown fin length in percent (y).\n\n- About 92% by day 14\n- Fastest growth in the first 4 days"
        }

        static func build(engine: Engine, root: URL, lang: UILang) async throws -> Fixture {
            let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            var ids: [String] = []
            for (i, title) in titles.enumerated() {
                let url = downloads.appendingPathComponent("explain-\(i + 1).pdf")
                try ReaderFixturePDF.sample(title: title).write(to: url)
                let summary = await engine.intake.ingest([.file(url)], options: ImportOptions(origin: .drop))
                if let id = summary.added.first { ids.append(id) }
            }
            await engine.enrich.waitUntilIdle()
            guard ids.count == titles.count else { throw CocoaError(.fileReadCorruptFile) }
            for (i, id) in ids.enumerated() {
                guard let p = try await engine.db.paper(id: id) else { continue }
                let title = titles[i]
                _ = try await engine.db.modifyPaper(pk: p.pk) { paper in
                    paper.title = title
                    paper.authors = ["Mei Chen", "Jonas Berg"]
                    paper.year = 2025
                    paper.venue = "Development"
                }
            }
            try await engine.setPaperPolicy(paperID: ids[1], confidential: true, neverAI: false)
            // Stored explanations: a reader one with a chip and a follow-up (anchored, pinned), one
            // saved to notes, one older.
            let zh = lang == .zh
            let now = Date()
            let meta = AssistMeta(provider: "claude", model: "haiku", totalMs: 5_800)
            func record(_ thread: String, _ turn: Int, _ action: String, _ answer: String, question: String? = nil,
                        page: Int?, pinned: Bool = false, ago: TimeInterval) -> ExplanationRecord {
                ExplanationRecord(paperID: ids[0], threadID: thread, turn: turn, source: .reader, action: action,
                                  lang: lang, page: page, excerpt: excerpt, question: question, answer: answer, meta: meta,
                                  pinned: pinned, createdAt: now.addingTimeInterval(-ago), matchVia: .reader, matchScore: 1)
            }
            let first = try await engine.saveExplanation(record("explain-a", 0, "explain", answer(zh), page: 3, pinned: true, ago: 3_600))
            _ = try await engine.saveExplanation(record("explain-a", 1, "simpler", simpler(zh), page: 3, pinned: true, ago: 3_500))
            _ = try await engine.saveExplanation(record("explain-a", 2, "ask", followUpAnswer(zh), question: question(zh), page: 3,
                                                        pinned: true, ago: 3_400))
            await engine.saveExplanationReaderAnchor(ReaderAnchor(paperID: ids[0], kind: .selection, page: 3,
                                                            rect: CGRect(x: 72, y: 400, width: 460, height: 48),
                                                            pageBounds: CGRect(x: 0, y: 0, width: 612, height: 792), text: excerpt),
                                               explanationID: first.id)
            let saved = try await engine.saveExplanation(record("explain-b", 0, "terms", zh ? "**芽基**（blastema）：再生时在伤口处形成的一团未分化细胞。" : "**Blastema**: a mass of undifferentiated cells that forms at the wound during regeneration.", page: 2, ago: 86_400))
            try await engine.appendExplanationToNotes(id: saved.id)
            _ = try await engine.saveExplanation(record("explain-c", 0, "figure", figureAnswer(zh), page: 4, ago: 5 * 86_400))
            return Fixture(lang: lang, ids: ids)
        }

        // MARK: The frozen screen the frame / lens renders draw on

        /// A box over the second paragraph, one around the figure, and where the pointer sits.
        static let paragraphBox = CGRect(x: 262, y: 236, width: 616, height: 72)
        static let figureBox = CGRect(x: 300, y: 372, width: 690, height: 272)
        static let hoverPoint = CGPoint(x: 560, y: 300)
        static let lensPoint = CGPoint(x: 520, y: 176)
        static let termPoint = CGPoint(x: 574, y: 141)

        /// A paper page in a PDF viewer's window (title, two paragraphs, a chart with its caption, a
        /// third paragraph) at 2×, drawn in memory — never a screenshot.
        static func screen(size: NSSize) -> CGImage? {
            let scale: CGFloat = 2
            let w = Int(size.width * scale), h = Int(size.height * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.scaleBy(x: scale, y: scale)
            let H = size.height
            func rect(_ x: CGFloat, _ top: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
                CGRect(x: x, y: H - top - height, width: width, height: height)
            }
            func text(_ s: String, x: CGFloat, top: CGFloat, size: CGFloat, bold: Bool = false, gray: CGFloat = 0.1) {
                let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Times-Roman") as CFString, size, nil)
                let attr = NSAttributedString(string: s, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1)])
                ctx.textPosition = CGPoint(x: x, y: H - top - size)
                CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
            }
            // The viewer's window: a dark backdrop, its toolbar, the page.
            ctx.setFillColor(CGColor(gray: 0.30, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setFillColor(CGColor(gray: 0.86, alpha: 1)); ctx.fill(rect(0, 0, size.width, 38))
            text("explain-1.pdf — Page 3 of 6", x: 520, top: 12, size: 13, bold: true, gray: 0.25)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(rect(230, 38, 820, size.height - 38))
            text(titles[0], x: 270, top: 58, size: 21, bold: true)
            text("Mei Chen, Jonas Berg · Development (2025)", x: 270, top: 90, size: 13, gray: 0.35)
            let body: [[String]] = [
                ["Regenerating fins re-form the lost tissue from a blastema, a mass of dedifferentiated cells at the wound.",
                 "We regularize the attention weights by a temperature-scaled softmax so that the blastema signal",
                 "dominates early regrowth, while the surrounding tissue contributes later in the time course."],
                ["A smaller temperature τ makes the distribution sharper: a few positions take most of the weight.",
                 "We fit τ on the first four days after amputation and keep it fixed afterwards, so that the later",
                 "stages are explained by the same parameters (Methods, Section 2.3)."],
            ]
            var top: CGFloat = 132
            for paragraph in body {
                for line in paragraph {
                    text(line, x: 270, top: top, size: 14.5)
                    top += 21
                }
                top += 46
            }
            // The figure: axes, bars, a caption.
            let axis = rect(330, 392, 620, 200)
            ctx.setStrokeColor(CGColor(gray: 0.2, alpha: 1)); ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: axis.minX, y: axis.maxY)); ctx.addLine(to: CGPoint(x: axis.minX, y: axis.minY))
            ctx.addLine(to: CGPoint(x: axis.maxX, y: axis.minY)); ctx.strokePath()
            for (i, v) in [0.28, 0.52, 0.74, 0.86, 0.92].enumerated() {
                ctx.setFillColor(CGColor(red: 0.20, green: 0.42, blue: 0.78, alpha: 1))
                ctx.fill(CGRect(x: axis.minX + 40 + CGFloat(i) * 112, y: axis.minY, width: 60, height: CGFloat(v) * 180))
            }
            text("Figure 3  Regrown fin length (%) at days 2–14 for τ = 0.5.", x: 330, top: 612, size: 13.5, bold: true, gray: 0.2)
            text("The blastema signal explains most of the early regrowth; later stages slow down as expected.", x: 270,
                 top: 668, size: 14.5)
            return ctx.makeImage()
        }

        /// A synthetic figure (axes, a rising curve, a caption) as a dropped image would arrive.
        static func figureImage() -> AssistImage? {
            let w = 640, h = 400
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setStrokeColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
            ctx.setLineWidth(2)
            ctx.move(to: CGPoint(x: 60, y: 60)); ctx.addLine(to: CGPoint(x: 600, y: 60))
            ctx.move(to: CGPoint(x: 60, y: 60)); ctx.addLine(to: CGPoint(x: 60, y: 360))
            ctx.strokePath()
            ctx.setStrokeColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
            ctx.setLineWidth(4)
            ctx.move(to: CGPoint(x: 60, y: 70))
            for i in 1...10 {
                let x = 60 + Double(i) * 54, y = 70 + 280 * (1 - exp(-Double(i) / 3))
                ctx.addLine(to: CGPoint(x: x, y: y))
            }
            ctx.strokePath()
            let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
            let attr = NSAttributedString(string: "Figure 3  Regrowth (%) vs days", attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 160, y: 20)
            CTLineDraw(line, ctx)
            return ctx.makeImage().flatMap(ExplainImageEncoder.encode)
        }
    }
}

/// Services of a rendered panel: nothing is prepared, judged, sent or stored.
private final class RenderServices: ExplainServicing {
    var assistSettings: AssistSettings { AssistSettings(mode: .claude) }
    var now: Date { Date() }
    func prepare(_ capture: ExplainCapture, anchor: ReaderAnchor?) async -> ExplainPrepared {
        ExplainPrepared(selection: capture.text, image: capture.image, content: .text, match: nil)
    }
    func privacy(paperID: String?, hostBundleID: String?) async -> AssistPrivacy.Verdict? { .ok }
    func request(_ spec: ExplainTurnSpec) -> AssistRequest {
        AssistRequest(surface: .explain, systemPrompt: "", turnText: "", model: "", limits: AssistLimits.defaults(for: .explain, provider: nil))
    }
    func submit(_ request: AssistRequest, ticket: ConsentTicket) async -> AsyncStream<AssistEvent> { AsyncStream { $0.finish() } }
    func cancelTurn() async {}
    func closeSession(threadKey: String) async {}
    func save(_ record: ExplanationRecord, anchor: ReaderAnchor?) async throws -> ExplanationRecord { record }
    func setPinned(ids: [String], _ pinned: Bool) async {}
    func appendToNotes(id: String) async throws {}
}
