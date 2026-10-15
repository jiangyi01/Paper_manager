import AppKit
import CoreText
import PDFKit
import SwiftUI
import PaperDeckCore
import PaperDeckShared

/// `--ask-render OUTDIR --root SCRATCH [--lang en|zh] [--appearance light|dark] [--probe-send]`
/// (READING_ASSIST_PLAN §9.1 render checks; Slice C, C2/C3): every state of the Ask tab, the Ask
/// window, PagePeek, Settings ▸ Ask and the "Ask Across" button, from a generated scratch library.
///
/// Mock only: the engine's card providers are mocks (signed out), its only assist backend is
/// `MockAssistBackend` and `assist.mode` is `mock`, so no CLI can be located, probed or spawned; the
/// settings live in their own suite `<bundle>.ask-render`, removed afterwards. The states are drawn
/// from the real views over real stored threads (inserted through the Q&A store with citations
/// computed by the Q&A core from the fixture's text) — a render never performs a question.
///
/// `--probe-send` also drives the real Ask tab in an off-screen window: ⌘↩ on its composer (the
/// tab's own action handler mints the ticket), the mock answer streaming in and stored, Stop
/// (Esc) on a hanging mock turn, and a question while Ask is off; one `PROBE name PASS|FAIL` line
/// each, then `PROBE SUMMARY n/m`.
enum AskRenders {
    /// Marks a scratch root this mode built (it refuses any other non-empty root).
    static let marker = ".paperdeck-ask-render"

    static func run(_ args: CLIArgs) async -> Int32 {
        guard let out = args.positional.map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }),
              let root = args.url("--root") else {
            return CLIRunner.fail("--ask-render OUTDIR --root SCRATCH_ROOT [--lang en|zh] [--appearance light|dark] [--probe-send]")
        }
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        if !existing.isEmpty, !existing.contains(marker) {
            return CLIRunner.fail("--root must be an empty scratch folder (or one --ask-render made): \(root.path)")
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
        let suite = "\(BuildIdentity.current.bundleID).ask-render"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        var initial = EngineSettings(plan: PlanSettings(), lang: lang, agentMode: .off, autoReadNewPapers: false,
                                     metadataLookup: false)
        initial.assist.mode = .mock
        let engineSettings = SharedValue(initial)
        let mock = MockAssistBackend(delay: .milliseconds(40))
        let deps = Engine.Dependencies(loadSettings: { engineSettings.get }, fetcher: nil,
                                       claude: MockAgentProvider(behavior: .notLoggedIn),
                                       codex: MockAgentProvider(behavior: .notLoggedIn), mock: MockAgentProvider(),
                                       sidecarDelay: .milliseconds(20), cliFacts: .inMemory(),
                                       loadMailSettings: { MailSettings() }, mailSecrets: InMemoryMailSecretStore(),
                                       assistBackends: [mock])
        AskTab.previewOverride = true
        defer { AskTab.previewOverride = false }
        do {
            let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: deps)
            let store = SettingsStore(defaults: defaults, domain: suite)
            store.onMailSettingsChange = { _ in }
            store.language = lang
            store.agentMode = AgentMode.off.rawValue
            store.assist.mode = .mock
            let state = AppState(engine: engine, settings: store)
            state.start()
            let fixture = try await Fixture.build(engine: engine, root: root, lang: lang)
            state.scheduleRefresh(delay: .zero)
            var waited = 0
            while (state.snapshot?.rows.count ?? 0) < fixture.ids.count && waited < 150 {
                try await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            try await draw(state: state, fixture: fixture, appearance: appearance, out: out, suffix: suffix)
            var status: Int32 = 0
            if args.has("--probe-send") {
                status = await SendProbe.run(state: state, fixture: fixture, mock: mock, engineSettings: engineSettings,
                                             appearance: appearance, out: out, suffix: suffix)
            }
            state.stop()
            await engine.shutdown()
            return status
        } catch {
            return CLIRunner.fail(String(describing: error))
        }
    }

    // MARK: - Drawing

    private static func draw(state: AppState, fixture: Fixture, appearance: NSAppearance?, out: URL, suffix: String) async throws {
        func png(_ name: String) -> URL { out.appendingPathComponent("ask-\(name)-\(suffix).png") }
        let tab = NSSize(width: 380, height: 760)
        func tabView(_ session: AskSession) -> some View {
            AskThreadView(state: state, session: session, titles: session.paperIDs.map { state.snapshot?.row(id: $0)?.paper.title ?? "" },
                          perform: { _ in }).frame(width: tab.width, height: tab.height)
        }
        func session(_ ids: [String]) async -> AskSession {
            let s = AskSession(paperIDs: ids, state: state, settings: state.settings.assist)
            await s.load()
            return s
        }
        let settings = state.settings

        // Ask off: the enable card (no thread yet).
        settings.assist.mode = .off
        try await PreviewRenderer.captureView(tabView(await session([fixture.empty])), size: tab, appearance: appearance, png("tab-off"))
        settings.assist.mode = .mock

        // Empty: suggestions, the estimate line.
        let empty = await session([fixture.empty])
        try await PreviewRenderer.captureView(tabView(empty), size: tab, appearance: appearance, png("tab-empty"))

        // A thread with answers: citation chips (verified, printed label, outlined, dimmed), a zh answer.
        let done = await session([fixture.main])
        try await PreviewRenderer.captureView(tabView(done), size: tab, appearance: appearance, png("tab-done"))

        // Streaming a follow-up (Thorough, 中) — the phase line, partial Markdown with a citation.
        let streaming = await session([fixture.main])
        streaming.depth = .thorough
        streaming.language = .zh
        let partial = fixture.lang == .zh
            ? "鳍再生依赖于**芽基**（blastema）中的增殖 [p. 3]。\n\n- 第 14 天时恢复了约 92% 的长度"
            : "Regeneration depends on proliferation in the **blastema** [p. 3].\n\n- By day 14 the fins had regrown about 92%"
        streaming.streaming = AskSession.Streaming(threadID: streaming.thread?.id, question: fixture.followUp, text: partial,
                                                   blocks: QAAnswerFormat.blocks(partial), phase: .streaming,
                                                   startedAt: Date().addingTimeInterval(-7))
        try await PreviewRenderer.captureView(tabView(streaming), size: tab, appearance: appearance, png("tab-streaming"))
        streaming.streaming = AskSession.Streaming(threadID: streaming.thread?.id, question: fixture.followUp, phase: .waiting,
                                                   startedAt: Date().addingTimeInterval(-3))
        try await PreviewRenderer.captureView(tabView(streaming), size: tab, appearance: appearance, png("tab-waiting"))

        // Notices.
        settings.assist.mode = .claude
        for (name, notice) in [("usage-limit", AskNotice.limited(until: Calendar.current.date(bySettingHour: 15, minute: 45, second: 0, of: Date()))),
                               ("needs-login", .notLoggedIn(.loggedOut)), ("soft-cap", .softCap(50)), ("hard-cap", .hardCap(150)),
                               ("failed", .timeout)] {
            let s = await session([fixture.empty])
            s.messages = [QAMessage(threadID: s.thread?.id ?? "", role: .user, text: fixture.question, createdAt: Date())]
            s.notice = notice
            try await PreviewRenderer.captureView(tabView(s), size: tab, appearance: appearance, png("tab-\(name)"))
        }
        settings.assist.mode = .mock

        // Privacy: the confirmation for a paper marked confidential; a never-AI paper.
        let confidential = await session([fixture.confidential])
        confidential.messages = [QAMessage(threadID: confidential.thread?.id ?? "", role: .user, text: fixture.question, createdAt: Date())]
        if case .confirm(let reasons) = confidential.privacy {
            confidential.notice = .confirm(reasons: reasons, question: fixture.question, options: QAOptions())
        }
        try await PreviewRenderer.captureView(tabView(confidential), size: tab, appearance: appearance, png("tab-confirm"))
        try await PreviewRenderer.captureView(tabView(await session([fixture.neverAI])), size: tab, appearance: appearance,
                                              png("tab-blocked"))

        // The inspector as it ships: Ask chosen through `AskFocus` (what the reader's Ask button and
        // `AskRouter` do), then a fresh inspector on Overview. The Ask one goes first: an inspector
        // still alive from an earlier capture would take the request itself.
        if let row = state.snapshot?.row(id: fixture.main) {
            state.selectedPaperID = row.id
            let inspector = NSSize(width: 380, height: 900)
            AskFocus.shared.request(paperID: row.id)
            try await PreviewRenderer.captureView(PaperDetailView(state: state, row: row).environment(LibraryChrome())
                                                    .frame(width: inspector.width, height: inspector.height),
                                                  size: inspector, appearance: appearance, png("inspector-ask"))
            _ = AskFocus.shared.consume(row.id)
            try await PreviewRenderer.captureView(PaperDetailView(state: state, row: row).environment(LibraryChrome())
                                                    .frame(width: inspector.width, height: inspector.height),
                                                  size: inspector, appearance: appearance, png("inspector-overview"))
        }

        // The Ask window: three papers with an answer; ten of twelve selected, cards only.
        let window = NSSize(width: 960, height: 680)
        let multi = await session(fixture.multi)
        try await PreviewRenderer.captureView(AskWindowView(state: state, session: multi, capped: nil)
                                                .frame(width: window.width, height: window.height),
                                              size: window, appearance: appearance, png("window"))
        let many = Array(fixture.ids.prefix(10))
        let cards = await session(many)
        cards.setMode(.cards)
        try await Task.sleep(for: .milliseconds(500))
        try await PreviewRenderer.captureView(AskWindowView(state: state, session: cards, capped: (kept: many.count, selected: fixture.ids.count))
                                                .frame(width: window.width, height: window.height),
                                              size: window, appearance: appearance, png("window-cards"))

        // PagePeek on the fixture PDF: page 3 with the cited sentence, its printed label.
        if let row = state.snapshot?.row(id: fixture.main) {
            try await PreviewRenderer.captureView(PagePeekView(row: row, page: 3, highlight: fixture.quote, label: "1203",
                                                               onOpenPDF: {}, onClose: {}).frame(width: 560, height: 720),
                                                  size: NSSize(width: 560, height: 720), appearance: appearance, png("pagepeek"))
            // PDFView draws through layers the offscreen capture can't read: the page as an image too.
            if let image = PagePeekSnapshot.image(url: row.pdfURL, page: 3, highlight: fixture.quote) {
                try await PreviewRenderer.captureView(Image(nsImage: image).resizable().scaledToFit().frame(width: 520, height: 673),
                                                      size: NSSize(width: 520, height: 673), appearance: appearance,
                                                      png("pagepeek-page"))
            }
        }

        // Settings ▸ Explain & Ask as it ships (the shared switch + Settings ▸ Ask), off and on; the
        // selection bar's button.
        func settingsTab() -> some View {
            AssistSettingsTab(state: state).formStyle(.grouped).frame(width: SettingsTab.width)
        }
        settings.assist.mode = .off
        try await PreviewRenderer.captureView(settingsTab(), size: nil, appearance: appearance, png("settings-off"))
        settings.assist.mode = .claude
        try await PreviewRenderer.captureView(settingsTab(), size: nil, appearance: appearance, png("settings"))
        settings.assist.mode = .mock
        let rows = fixture.multi.compactMap { state.snapshot?.row(id: $0) }
        try await PreviewRenderer.captureView(HStack(spacing: 12) {
                                                  AskAcrossButton(state: state, rows: rows)
                                                  AskAcrossButton(state: state, rows: rows, short: true)
                                              }
                                              .buttonStyle(.bordered).padding(14),
                                              size: nil, appearance: appearance, png("across-button"))
    }

    // MARK: - Fixture

    struct Fixture {
        var ids: [String]
        /// A paper with two answered questions (citations of every kind).
        var main: String
        /// A paper with no questions yet.
        var empty: String
        var confidential: String
        var neverAI: String
        /// Three papers with a multi-paper thread.
        var multi: [String]
        var question: String
        var followUp: String
        var quote: String
        var lang: UILang

        static let titles = [
            "Zebrafish fin regeneration depends on blastema proliferation",
            "Spatial transcriptomics of the regenerating axolotl limb",
            "An unpublished manuscript on fin ray patterning",
            "A clinical report shared under embargo",
            "Single-cell atlas of the developing zebrafish heart",
            "Wnt signalling gradients during appendage regrowth",
            "Macrophages are required for tail regeneration",
            "Bioelectric cues in planarian head regeneration",
            "Fibroblast dedifferentiation in the regenerating fin",
            "Comparative genomics of regeneration capacity",
            "Osteoblast origins in the regenerating zebrafish fin",
            "Mechanical forces shape the regenerating blastema",
        ]

        static func build(engine: Engine, root: URL, lang: UILang) async throws -> Fixture {
            let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let quote = "Regenerating fins regrew 92 percent of their original length within 14 days of amputation."
            var ids: [String] = []
            for (i, title) in titles.enumerated() {
                let url = downloads.appendingPathComponent("paper-\(i + 1).pdf")
                try pdf(title: title, pages: 5, seed: i, quote: i == 0 ? quote : nil).write(to: url)
                let summary = await engine.intake.ingest([.file(url)], options: ImportOptions(origin: .drop))
                if let id = summary.added.first { ids.append(id) }
            }
            await engine.enrich.waitUntilIdle()
            guard ids.count == titles.count else { throw CocoaError(.fileReadCorruptFile) }
            // Metadata and cards (as a finished reading would leave them).
            for (i, id) in ids.enumerated() {
                guard let p = try await engine.db.paper(id: id) else { continue }
                let title = titles[i], venue = ["Nature", "Cell", "Development", "eLife"][i % 4]
                let card: ReadingCard? = i < 2 || i == 4 ? card(i) : nil
                _ = try await engine.db.modifyPaper(pk: p.pk) { paper in
                    paper.title = title
                    paper.authors = ["Mei Chen", "Jonas Berg", "Ana Ruiz"]
                    paper.year = 2020 + i % 6
                    paper.venue = venue
                    if let card { paper.card = card; paper.tldr = card.tldr }
                }
            }
            try await engine.setPaperPolicy(paperID: ids[2], confidential: true, neverAI: false)
            try await engine.setPaperPolicy(paperID: ids[3], confidential: false, neverAI: true)

            // Stored threads, with citations from the Q&A core over the fixture text.
            let qa = await engine.qaService()
            let now = Date()
            let question = lang == .zh ? "主要发现是什么？" : "What is the main finding?"
            let followUp = lang == .zh ? "芽基在其中起什么作用？" : "What role does the blastema play?"
            let main = ids[0]
            let pages = await textPages(engine, main)
            let answer1 = """
                The fins regrow almost completely: **92% of their length within 14 days** [p. 3], driven by a proliferating blastema [pp. 2–3].

                - Proliferation peaks around day 4 [p. 2]
                - Blocking it stops regrowth [p. 4]
                - The authors also report long-term scarring [p. 1]

                Treat the dose-response claim with care: it cites a page this PDF doesn't have [p. 9].
                """
            let answer2 = "鳍几乎完全再生：截肢后 14 天内恢复了 **92%** 的长度 [p. 3]。增殖的芽基（blastema）驱动了这一过程 [pp. 2–3]。"
            try await storeThread(engine: engine, papers: [main], questions: [question, QA.translateQuestion],
                                  answers: [answer1, answer2], langs: ["en", "zh"], pages: [pages], now: now,
                                  label: (paper: 1, page: 3, label: "1203"))
            let multi = [ids[0], ids[1], ids[4]]
            var multiPages: [[QAPage]] = []
            for id in multi { multiPages.append(await textPages(engine, id)) }
            let multiQuestion = lang == .zh ? "这些论文的方法有什么不同？" : "How do these papers differ in approach?"
            let multiAnswer = """
                P1 measures regrowth directly in zebrafish fins [P1 p. 3], while P2 maps gene expression across the axolotl limb [P2 · p. 2].
                P3 is an atlas without a regeneration experiment [P3]. A fourth paper is cited by mistake [P4 p. 1].
                """
            try await storeThread(engine: engine, papers: multi, questions: [multiQuestion], answers: [multiAnswer], langs: ["en"],
                                  pages: multiPages, now: now, label: nil)
            _ = qa
            return Fixture(ids: ids, main: main, empty: ids[5], confidential: ids[2], neverAI: ids[3], multi: multi,
                           question: question, followUp: followUp, quote: quote, lang: lang)
        }

        private enum QA { static let translateQuestion = L.QA.translateRequest(.zh) }

        static func textPages(_ engine: Engine, _ id: String) async -> [QAPage] {
            let raw = ((try? engine.ctx.texts.load(id: id)) ?? nil) ?? ""
            return QAContextBuilder.preparePages(rawText: raw)
        }

        /// A stored thread: each question with its done answer, citations computed like `QAService` does.
        static func storeThread(engine: Engine, papers: [String], questions: [String], answers: [String], langs: [String],
                                pages: [[QAPage]], now: Date, label: (paper: Int, page: Int, label: String)?) async throws {
            let thread = try await engine.db.insertQAThread(QAThread(paperIDs: papers, title: QAPrompts.title(for: questions[0]),
                                                                     mode: papers.count > 3 ? .excerpts : .fullText,
                                                                     createdAt: now.addingTimeInterval(-600)))
            var counts: [Int?] = []
            for id in papers { counts.append(try await engine.db.paper(id: id)?.pageCount) }
            let byPage = pages.map { Dictionary($0.map { ($0.number, $0.text) }, uniquingKeysWith: { a, _ in a }) }
            for (i, q) in questions.enumerated() {
                let t = now.addingTimeInterval(Double(-500 + i * 60))
                try await engine.db.insertQAMessage(QAMessage(threadID: thread.id, role: .user, text: q, createdAt: t))
                var cites = QACitations.attachQuotes(answers[i], pageCounts: counts) { paper, page in
                    byPage.indices.contains(paper - 1) ? byPage[paper - 1][page] : nil
                }
                if let label {
                    for k in cites.indices where cites[k].paper == label.paper && cites[k].page == label.page { cites[k].label = label.label }
                }
                try await engine.db.insertQAMessage(QAMessage(
                    threadID: thread.id, role: .assistant, text: answers[i],
                    meta: AssistMeta(provider: "mock", model: "mock", totalMs: 6_400, inputTokens: 5_200, outputTokens: 180),
                    createdAt: t.addingTimeInterval(7), citations: cites, language: langs[i], depth: .quick))
            }
        }

        static func card(_ i: Int) -> ReadingCard {
            ReadingCard(tldr: "Fins regrow from a proliferating blastema within two weeks.",
                        summary: "Amputated zebrafish fins regrow through a blastema whose proliferation peaks at day 4.",
                        contributions: ["Time course of regrowth", "Proliferation is required"], method: "Live imaging and EdU labelling.",
                        results: ["92% regrowth by day 14"], limitations: [.init(text: "One strain only", source: .authors)],
                        keyTerms: [.init(term: "blastema", definition: "A mass of dedifferentiated cells")], resources: [],
                        paperType: .research, category: "Regeneration", tags: ["zebrafish"], difficulty: .medium,
                        estimatedMinutes: 45, checklist: [], textQuality: .good)
        }

        /// A generated PDF: the title, an author line, then distinct sentences per page (`quote` on page 3).
        static func pdf(title: String, pages: Int, seed: Int, quote: String?) -> Data {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
            let subjects = ["The blastema", "Proliferating cells", "Osteoblasts", "Macrophages", "The wound epidermis", "Fibroblasts"]
            let verbs = ["accumulate at the amputation plane", "express regeneration markers", "respond to Wnt signalling",
                         "migrate distally over three days", "require proliferation to regrow tissue", "reorganise the extracellular matrix"]
            for page in 1...max(1, pages) {
                var lines: [(String, CGFloat)] = []
                if page == 1 {
                    lines.append((title, 17))
                    lines.append(("Mei Chen, Jonas Berg and Ana Ruiz", 11))
                    lines.append(("Abstract", 12))
                }
                for k in 0..<14 {
                    let s = subjects[(seed + page + k) % subjects.count], v = verbs[(seed * 3 + page * 2 + k) % verbs.count]
                    lines.append(("\(s) \(v) in experiment \(page * 20 + k) of study \(seed + 1).", 10))
                }
                if page == 3, let quote { lines.insert((quote, 10), at: 4) }
                ctx.beginPDFPage(nil)
                var y: CGFloat = 730
                for (text, size) in lines {
                    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
                    let line = CTLineCreateWithAttributedString(
                        NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
                    ctx.textPosition = CGPoint(x: 54, y: y)
                    CTLineDraw(line, ctx)
                    y -= size * 1.9
                }
                ctx.endPDFPage()
            }
            ctx.closePDF()
            return data as Data
        }
    }
}

/// The page as PagePeek shows it, drawn into an image with the cited sentence highlighted (offscreen
/// renders can't read PDFView's layers). Opened, drawn and searched inside `PDFKitGate`.
enum PagePeekSnapshot {
    static func image(url: URL, page: Int, highlight: String?) -> NSImage? {
        PDFKitGate.shared.run { draw(url: url, page: page, highlight: highlight) }
    }

    private static func draw(url: URL, page: Int, highlight: String?) -> NSImage? {
        guard let doc = PDFDocument(url: url), let p = doc.page(at: page - 1) else { return nil }
        let bounds = p.bounds(for: .mediaBox)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }
        NSColor.white.setFill()
        bounds.fill()
        p.draw(with: .mediaBox, to: ctx)
        if let highlight, let sel = PDFPageView.find(highlight, on: p, in: doc) {
            NSColor.systemYellow.withAlphaComponent(0.45).setFill()
            for line in sel.selectionsByLine() { line.bounds(for: p).fill(using: .multiply) }
        }
        return image
    }
}

// MARK: - Send probe

/// Drives the real Ask tab in an off-screen window (never on a display; the app is never
/// activated): ⌘↩ on the composer runs the tab's own action handler — which mints the ticket — and
/// the mock answer must stream in and be stored; Esc stops a hanging mock turn (stored "stopped");
/// a question while Ask is off is refused with no answer stored. Mock backend only.
private enum SendProbe {
    final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    static func run(state: AppState, fixture: AskRenders.Fixture, mock: MockAssistBackend, engineSettings: SharedValue<EngineSettings>,
                    appearance: NSAppearance?, out: URL, suffix: String) async -> Int32 {
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) { print("PROBE TIMEOUT"); exit(3) }
        var results: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            results.append((name, ok))
            print("PROBE \(name) \(ok ? "PASS" : "FAIL")\(ok ? "" : " " + detail())")
        }
        guard let row = state.snapshot?.row(id: fixture.ids[6]) else { print("PROBE setup FAIL"); return 1 }
        let size = NSSize(width: 380, height: 760)
        let window = KeyableWindow(contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        let hosting = NSHostingView(rootView: AskTab(state: state, row: row).frame(width: size.width, height: size.height)
            .background(.background))
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.orderOut(nil) }
        let session = AskSessions.session(for: [row.id], state: state)
        try? await Task.sleep(for: .milliseconds(900))

        /// A key equivalent the way AppKit delivers one (⌘↩ to the Ask button, Esc to Stop).
        func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) async {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                        context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: code) {
                if !window.performKeyEquivalent(with: e) { window.sendEvent(e) }
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        func wait(_ seconds: Double = 6, _ until: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if until() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return until()
        }

        // 1. ⌘↩ asks: the question goes out with the paper, streams in, is stored.
        let turnsBefore = await mock.turns
        session.draft = fixture.question
        try? await Task.sleep(for: .milliseconds(200))
        // Watches the streamed text from before the key press (the mock answers in ~150 ms).
        let watcher = Task { @MainActor in
            var saw = false
            while !Task.isCancelled {
                if session.streaming?.text.isEmpty == false { saw = true }
                try? await Task.sleep(for: .milliseconds(3))
            }
            return saw
        }
        await key(36, "\r", [.command])
        check("command-return-sends", await wait(2) { session.isRunning || !session.messages.isEmpty }, "draft=\(session.draft)")
        _ = await wait(6) { !session.isRunning && session.messages.contains { $0.role == .assistant } }
        watcher.cancel()
        check("answer-streamed", await watcher.value)
        let answer = session.messages.last
        check("answer-stored", answer?.role == .assistant && answer?.state == .done, "\(session.messages.map(\.state))")
        check("citation-validated", answer?.citations.first?.page == 1 && answer?.citations.first?.valid == true,
              "\(answer?.citations ?? [])")
        let request = await mock.lastRequest
        let turnsAfter = await mock.turns
        check("one-turn-with-the-paper", turnsAfter == turnsBefore + 1
              && request?.turnText.contains("[[p. 1]]") == true && request?.session == .oneShot, "\(turnsAfter)")
        check("draft-cleared", session.draft.isEmpty)
        try? await PreviewRenderer.captureView(AskThreadView(state: state, session: session, titles: [row.paper.title], perform: { _ in })
                                                .frame(width: size.width, height: size.height),
                                               size: size, appearance: appearance,
                                               out.appendingPathComponent("ask-probe-done-\(suffix).png"))

        // 2. Esc stops a hanging answer; it is stored as stopped.
        await mock.enqueue(.hang)
        session.draft = fixture.followUp
        try? await Task.sleep(for: .milliseconds(200))
        await key(36, "\r", [.command])
        _ = await wait(3) { session.isRunning }
        try? await Task.sleep(for: .milliseconds(300))
        await key(53, "\u{1b}")
        check("escape-stops", await wait(4) { !session.isRunning }, "running=\(session.isRunning)")
        _ = await wait(2) { session.messages.last?.state == .cancelled }
        check("stopped-answer-stored", session.messages.last?.state == .cancelled, "\(session.messages.map(\.state))")

        // 3. Ask off in the engine: refused before anything runs; no answer stored, the notice says why.
        var off = engineSettings.get
        off.assist.mode = .off
        engineSettings.set(off)
        let turns = await mock.turns
        let count = session.messages.count
        session.draft = "One more?"
        try? await Task.sleep(for: .milliseconds(200))
        await key(36, "\r", [.command])
        _ = await wait(3) { session.notice != nil }
        check("off-refused", session.notice == .off, "\(String(describing: session.notice))")
        let turnsOff = await mock.turns
        check("off-sent-nothing", turnsOff == turns && session.messages.count == count + 1
              && session.messages.last?.role == .user, "\(session.messages.map(\.role))")
        var on = engineSettings.get
        on.assist.mode = .mock
        engineSettings.set(on)

        let passed = results.filter(\.1).count
        print("PROBE SUMMARY \(passed)/\(results.count)")
        return passed == results.count ? 0 : 1
    }
}
