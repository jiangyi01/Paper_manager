import AppKit
import CoreText
import SwiftUI
import PaperDeckCore

/// The duplicate check's command-line modes (Slice B). Both are local only: no network, no AI
/// (mock providers; agent and assist off), no keychain, never the app's settings domain.
///
/// - `--dedupe-report --root DIR [--json] [--sensitivity strict|balanced|loose]`: the pairs a
///   library check would ask about, for calibrating the thresholds. It works on a scratch copy of
///   DIR's database (the text cache is read in place); DIR itself is never written. Run it on the
///   real library only with the user's OK.
/// - `--dedupe-render OUTDIR --root SCRATCH [--lang en|zh] [--appearance light|dark] [--extra-papers N]`:
///   builds a fixture library in SCRATCH (generated PDFs: an arXiv v1 ← v3, a copy without ids, a
///   supplement, a removed paper read before, one in Recently Deleted; `--extra-papers` adds N
///   unrelated ones first) through the real intake, and draws the decision sheets, the list,
///   ribbon, chip, sidebar row, settings and toasts. It draws no Settings ▸ AI or setup page, so
///   no CLI is probed.
enum DedupeCLI {
    // MARK: - --dedupe-report

    static func report(_ args: CLIArgs) async -> Int32 {
        guard let root = args.url("--root") else {
            return CLIRunner.fail("--dedupe-report --root LIBRARY_ROOT [--json] [--sensitivity strict|balanced|loose]")
        }
        let source = AppPaths.rooted(at: root)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.database.path) else {
            return CLIRunner.fail("no library database at \(source.database.path)")
        }
        let sensitivity = DedupeSettings.Sensitivity(rawValue: args.value("--sensitivity") ?? "balanced") ?? .balanced
        // A scratch copy of the database; the text cache is linked, read in place.
        let scratch = fm.temporaryDirectory.appendingPathComponent("paperdeck-dedupe-report-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        let paths = AppPaths(library: scratch.appendingPathComponent("Library", isDirectory: true),
                             support: scratch.appendingPathComponent("Support", isDirectory: true),
                             caches: scratch.appendingPathComponent("Caches", isDirectory: true),
                             widget: scratch.appendingPathComponent("Support/widget", isDirectory: true))
        do {
            try fm.createDirectory(at: paths.support, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let from = URL(fileURLWithPath: source.database.path + suffix)
                if fm.fileExists(atPath: from.path) {
                    try fm.copyItem(at: from, to: URL(fileURLWithPath: paths.database.path + suffix))
                }
            }
            if fm.fileExists(atPath: source.textCache.path) {
                try fm.createSymbolicLink(at: paths.textCache, withDestinationURL: source.textCache)
            }
        } catch {
            return CLIRunner.fail("could not make the scratch copy: \(error)")
        }
        let settings = EngineSettings(plan: PlanSettings(), lang: .en, agentMode: .off, autoReadNewPapers: false,
                                      metadataLookup: false, dedupe: DedupeSettings(sensitivity: sensitivity, history: false))
        do {
            let engine = try await Engine.open(paths: paths, deps: safeDependencies(settings))
            let papers = try await engine.db.livePapers()
            let t0 = Date()
            let pairs = try await engine.dedupeReport()
            let elapsed = Date().timeIntervalSince(t0)
            let byID = Dictionary(papers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let json = args.has("--json")
            for p in pairs {
                let n = byID[p.newPaperID], e = byID[p.existingPaperID]
                if json {
                    CLIRunner.line(["band": p.band.rawValue, "relation": p.relation.rawValue,
                                    "score": (p.score * 100).rounded() / 100, "known": p.known,
                                    "new": ["id": p.newPaperID, "title": n?.title ?? ""],
                                    "existing": ["id": p.existingPaperID, "title": e?.title ?? ""],
                                    "why": p.evidence.map { DupExplainer.line($0, lang: .en) }])
                } else {
                    print("\(p.band.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) "
                          + "\(p.relation.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)) "
                          + String(format: "%.2f", p.score) + (p.known ? "  [known]" : ""))
                    print("    new:      \(n?.title ?? p.newPaperID)")
                    print("    existing: \(e?.title ?? p.existingPaperID)")
                    print("    why:      " + p.evidence.map { DupExplainer.line($0, lang: .en) }.joined(separator: "; "))
                }
            }
            let count = { (b: DupBand) in pairs.filter { $0.band == b }.count }
            let perPaper = papers.isEmpty ? 0 : elapsed * 1_000 / Double(papers.count)
            let summary = "\(papers.count) papers · \(pairs.count) pairs (certain \(count(.certain)), likely \(count(.likely)), "
                + "possible \(count(.possible)); \(pairs.filter(\.known).count) already known) · "
                + String(format: "%.1f s, %.2f ms per paper", elapsed, perPaper)
            if json { CLIRunner.line(["summary": summary]) } else { print(summary) }
            await engine.shutdown()
            return 0
        } catch {
            return CLIRunner.fail(String(describing: error))
        }
    }

    /// Mock providers, no fetcher, in-memory CLI facts / mail secrets, the given settings; the
    /// assist lane gets only the mock backend (no CLI, no on-device model is ever registered).
    static func safeDependencies(_ settings: EngineSettings) -> Engine.Dependencies {
        Engine.Dependencies(loadSettings: { settings }, fetcher: nil,
                            claude: MockAgentProvider(behavior: .notLoggedIn), codex: MockAgentProvider(behavior: .notLoggedIn),
                            mock: MockAgentProvider(), sidecarDelay: .milliseconds(20), cliFacts: .inMemory(),
                            loadMailSettings: { MailSettings() }, mailSecrets: InMemoryMailSecretStore(),
                            assistBackends: [MockAssistBackend()])
    }

    // MARK: - --dedupe-render

    /// Marks a scratch root this mode built (it refuses any other non-empty root).
    static let marker = ".paperdeck-dedupe-render"

    static func render(_ args: CLIArgs) async -> Int32 {
        guard let out = args.positional.map({ URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }),
              let root = args.url("--root") else {
            return CLIRunner.fail("--dedupe-render OUTDIR --root SCRATCH_ROOT [--lang en|zh] [--appearance light|dark]")
        }
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        if !existing.isEmpty, !existing.contains(marker) {
            return CLIRunner.fail("--root must be an empty scratch folder (or one --dedupe-render made): \(root.path)")
        }
        // A fresh fixture each run.
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
        let suite = "\(BuildIdentity.current.bundleID).dedupe-render"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = EngineSettings(plan: PlanSettings(), lang: lang, agentMode: .off, autoReadNewPapers: false,
                                      metadataLookup: false, dedupe: DedupeSettings())
        do {
            let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: safeDependencies(settings))
            let store = SettingsStore(defaults: defaults, domain: suite)
            store.onMailSettingsChange = { _ in }
            store.language = lang
            store.agentMode = AgentMode.off.rawValue
            let state = AppState(engine: engine, settings: store)
            state.start()
            let fixture = try await Fixture.build(engine: engine, root: root, extra: max(0, min(args.int("--extra-papers") ?? 0, 2_000)))
            state.dedupe.scheduleRefresh(delay: .zero)
            var waited = 0
            while (state.snapshot == nil || state.dedupe.openCount < fixture.expectedReviews) && waited < 100 {
                try await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
            try await draw(state: state, fixture: fixture, appearance: appearance, out: out, suffix: suffix)
            state.stop()
            await engine.shutdown()
            return 0
        } catch {
            return CLIRunner.fail(String(describing: error))
        }
    }

    private static func draw(state: AppState, fixture: Fixture, appearance: NSAppearance?, out: URL,
                             suffix: String) async throws {
        func png(_ name: String) -> URL { out.appendingPathComponent("\(name)-\(suffix).png") }
        // One decision sheet per kind of review.
        let open = try await state.engine.duplicateReviews(state: .open)
        for r in open {
            let name: String
            if r.matchesHistory { name = "removed" }
            else if r.relation == .supplement { name = "supplement" }
            else if r.isParked, r.existingPaperID == fixture.deletedPaperID { name = "deleted" }
            else if r.isParked { name = "newer" }
            else { name = "held" }
            let model = DuplicateSheetModel(state: state, queue: [r.id])
            await model.load()
            try await PreviewRenderer.captureView(DuplicateSheet(model: model, close: {}), size: nil, appearance: appearance,
                                                  png("dup-sheet-\(name)"))
        }
        // B3: the AI judge in the decision sheet — offered, then answered (a fixture answer: a turn
        // needs a click's ticket, which only the sheet's button mints).
        if let held = open.first(where: { !$0.isParked && $0.band != .certain && !$0.matchesHistory }),
           let detail = try? await state.engine.duplicateReviewDetail(id: held.id) {
            let today = state.snapshot?.today.today ?? LocalDate.today()
            let ready = DuplicateSheetModel(fixture: detail, today: today,
                                            judge: .ready(DupJudgeStatus(block: nil, usedToday: 3, dailyCap: 10)))
            try await PreviewRenderer.captureView(DuplicateSheet(model: ready, close: {}), size: nil, appearance: appearance,
                                                  png("dup-sheet-judge"))
            var answered = detail
            answered.review.aiVerdict = DupAIVerdict(verdict: .newVersion, confidence: 0.9,
                                                     reason: L.lang == .zh ? "标题与作者相同，正文大体一致；新文件是更新的版本。"
                                                        : "Same title and authors, mostly the same text; the new file is the later version.",
                                                     bandBefore: .possible, bandAfter: .likely, provider: "mock", model: "mock",
                                                     at: Date())
            let done = DuplicateSheetModel(fixture: answered, today: today,
                                           judge: .ready(DupJudgeStatus(block: nil, usedToday: 4, dailyCap: 10)))
            try await PreviewRenderer.captureView(DuplicateSheet(model: done, close: {}), size: nil, appearance: appearance,
                                                  png("dup-sheet-judge-answered"))
            let blocked = DuplicateSheetModel(fixture: detail, today: today,
                                              judge: .blocked(L.Dedupe.judgeBlocked(.privateNew) ?? ""))
            try await PreviewRenderer.captureView(DuplicateSheet(model: blocked, close: {}), size: nil, appearance: appearance,
                                                  png("dup-sheet-judge-private"))
        }
        // B3: the batch review of every open question (the real rows), then with overrides and AI rows.
        let batch = DuplicateBatchModel(state: state, ids: open.reversed().map(\.id), origin: .all)
        await batch.load()
        try await PreviewRenderer.captureView(DuplicateBatchSheet(model: batch, close: { _ in }), size: nil,
                                              appearance: appearance, png("dup-batch"))
        var rows = DupBatch.applying(.keepBoth, to: batch.rows)
        if let i = rows.firstIndex(where: { !$0.detail.review.isParked && $0.detail.review.band != .certain }) {
            rows[i].detail.review.aiVerdict = DupAIVerdict(verdict: .different, confidence: 0.85, reason: "",
                                                           bandBefore: rows[i].detail.review.band, bandAfter: .possible,
                                                           provider: "mock", model: "mock", at: Date())
            rows[i].detail.review.band = .possible
        }
        var judges: [String: DuplicateSheetModel.JudgePhase] = [:]
        for r in rows where !r.detail.review.isParked && r.detail.review.band != .certain {
            judges[r.id] = .ready(DupJudgeStatus(block: nil, usedToday: 4, dailyCap: 10))
        }
        let edited = DuplicateBatchModel(fixture: rows, origin: .importBatch, judges: judges)
        try await PreviewRenderer.captureView(DuplicateBatchSheet(model: edited, close: { _ in }), size: nil,
                                              appearance: appearance, png("dup-batch-edited"))
        // B3: the email merge popover's duplicate question (a newer version of a finished paper).
        if let newer = open.first(where: { $0.isParked && $0.relation == .newerVersion }),
           let detail = try? await state.engine.duplicateReviewDetail(id: newer.id),
           let paperID = detail.existing.paperID, let paper = try? await state.engine.db.paper(id: paperID) {
            let rules = MailDupRules.choices(existing: paper, band: .likely, relation: .newerVersion, newerSide: .new,
                                             identity: false)
            let match = MailDupMatch(itemID: "fixture", existingPaperID: paperID, existing: detail.existing, band: .likely,
                                     relation: .newerVersion, newerSide: .new, identity: false,
                                     headline: detail.explanation.headline, historyLine: detail.explanation.historyLine,
                                     versionLine: detail.explanation.versionLine, evidence: detail.explanation.evidence,
                                     choices: rules.choices, defaultChoice: rules.default)
            try await PreviewRenderer.captureView(MailDuplicatePreview(match: match).frame(width: 420).padding(16), size: nil,
                                                  appearance: appearance, png("dup-mail-popover"))
        }
        // A queue ("1 of N") with the options of "Re-read the earlier one" open.
        if let newer = open.first(where: { $0.isParked && $0.relation == .newerVersion }) {
            let model = DuplicateSheetModel(state: state, queue: [newer.id] + open.filter { $0.id != newer.id }.map(\.id))
            await model.load()
            if model.detail?.choices.contains(.rereadEarlier) == true {
                model.choice = .rereadEarlier
                model.checklist = .uncheckAll
                model.deadline = .date
            }
            try await PreviewRenderer.captureView(DuplicateSheet(model: model, close: {}), size: nil, appearance: appearance,
                                                  png("dup-sheet-queue"))
        }
        // The list, after a library check.
        state.dedupe.startCheck()
        var waited = 0
        while state.dedupe.check?.running != false && waited < 200 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        state.dedupe.scheduleRefresh(delay: .zero)
        try await Task.sleep(for: .milliseconds(300))
        try await PreviewRenderer.captureView(DuplicatesList(state: state, close: {}), size: nil, appearance: appearance,
                                              png("dup-list"))
        // The sidebar's Duplicates row.
        try await PreviewRenderer.captureView(LibrarySidebarView(state: state).environment(LibraryChrome())
                                                .frame(width: 250, height: 780),
                                              size: NSSize(width: 250, height: 780), appearance: appearance,
                                              png("dup-sidebar"))
        // A held card (ribbon) and its inspector (chip).
        if let held = state.snapshot?.rows.first(where: { state.dedupe.showsRibbon($0.id) }) {
            let today = state.snapshot?.today.today ?? LocalDate.today()
            try await PreviewRenderer.captureView(
                PaperCardView(row: held, today: today, lang: L.lang, agentStatus: state.agentStatus, queuePosition: nil,
                              isSelected: false).frame(width: 260).padding(12),
                size: nil, appearance: appearance, png("dup-card"))
            try await PreviewRenderer.captureView(PaperDetailView(state: state, row: held).environment(LibraryChrome())
                                                    .frame(width: 380, height: 760),
                                                  size: NSSize(width: 380, height: 760), appearance: appearance,
                                                  png("dup-detail"))
        }
        // Settings ▸ Library ▸ Duplicates (as it ships; then with the AI judge's switch, B3).
        try await PreviewRenderer.captureView(Form { DedupeSettingsSection(state: state) }.formStyle(.grouped)
                                                .frame(width: 640, height: 330),
                                              size: NSSize(width: 640, height: 330), appearance: appearance,
                                              png("dup-settings"))
        try await PreviewRenderer.captureView(Form { DedupeSettingsSection(state: state, showsJudge: true) }.formStyle(.grouped)
                                                .frame(width: 640, height: 430),
                                              size: NSSize(width: 640, height: 430), appearance: appearance,
                                              png("dup-settings-judge"))
        // The toasts the imports produced (worded from their reviews).
        try await PreviewRenderer.captureView(ToastStack(state: state, maxVisible: 6).frame(width: 340).padding(10), size: nil,
                                              appearance: appearance, png("dup-toasts"))
    }

    // MARK: Fixture library

    /// Five duplicate situations, made through the engine's own intake from generated PDFs.
    struct Fixture {
        var deletedPaperID: String?
        var expectedReviews: Int

        /// `extra`: that many more unrelated papers first (a bigger library for `--dedupe-report` timings).
        static func build(engine: Engine, root: URL, extra: Int = 0) async throws -> Fixture {
            let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
            let trashDir = root.appendingPathComponent("Trash", isDirectory: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
            func file(_ name: String, title: String, doi: String? = nil, seed: String, pages: Int = 3) throws -> URL {
                let url = downloads.appendingPathComponent(name)
                try DedupeCLI.pdf(title: title, doi: doi, body: DedupeCLI.body(seed: seed), pages: pages, tag: name).write(to: url)
                return url
            }
            @discardableResult
            func ingest(_ url: URL) async -> ImportBatchSummary {
                let s = await engine.intake.ingest([.file(url)], options: ImportOptions(origin: .drop))
                await engine.enrich.waitUntilIdle()
                return s
            }
            let topics = ["cortex", "retina", "kidney", "liver", "heart", "lung", "gut", "skin", "bone", "blood"]
            let methods = ["single-cell atlas", "lineage tracing", "spatial profiling", "organoid model", "CRISPR screen"]
            for i in 0..<extra {
                let title = "A \(methods[i % methods.count]) of the developing \(topics[(i / 5) % topics.count]) in cohort \(i)"
                let url = try file("extra-\(i).pdf", title: title, seed: "extra \(i)")
                _ = await engine.intake.ingest([.file(url)], options: ImportOptions(origin: .drop))
            }
            if extra > 0 { await engine.enrich.waitUntilIdle() }
            // A finished arXiv v1 with the user's work, then its v3 (parked, newer version).
            let atlas = "Single-cell atlas of the developing human cortex"
            if let id = await ingest(try file("2401.01234v1.pdf", title: atlas, seed: "atlas v1")).added.first {
                _ = try await engine.addChecklistItem(paperID: id, text: "Compare the lineage tree with Fig. 3", minutes: 15)
                for item in try await engine.db.checklist(paperPK: try await engine.db.paper(id: id)?.pk ?? 0) {
                    _ = try? await engine.toggleChecklistItem(paperID: id, itemID: item.id)
                }
                _ = try await engine.setNotes(paperID: id, "Radial glia subtypes — check the spatial data.")
                _ = try await engine.setStatus(paperID: id, .done)
            }
            await ingest(try file("2401.01234v3.pdf", title: atlas, seed: "atlas v3"))
            // The same text twice without identifiers (the second is held: likely).
            let lineage = "Lineage tracing of organoid progenitors at scale"
            await ingest(try file("lineage-journal.pdf", title: lineage, seed: "lineage text"))
            await ingest(try file("lineage-authors-copy.pdf", title: lineage, seed: "lineage text"))
            // A supplement printing its paper's DOI.
            let doi = "10.1038/s41586-026-00001-1"
            await ingest(try file("s41586-026-00001-1.pdf", title: "Cortical folding emerges from progenitor mechanics",
                                  doi: doi, seed: "folding", pages: 12))
            await ingest(try file("mmc1.pdf", title: "Supplementary Information", doi: doi, seed: "folding si", pages: 2))
            // A paper read and removed for good, then the same file again.
            let removed = try file("retina.pdf", title: "Organoid models of retinal degeneration", doi: "10.1016/j.cell.2025.01.002",
                                   seed: "retina")
            let bytes = try Data(contentsOf: removed)
            if let id = await ingest(removed).added.first {
                _ = try await engine.setStatus(paperID: id, .done)
                try await engine.softDelete(paperID: id)
                _ = try await engine.purgeExpired(olderThan: 0, trash: { url in
                    (try? FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(UUID().uuidString))) != nil
                })
            }
            let again = downloads.appendingPathComponent("retina-again.pdf")
            try bytes.write(to: again)
            await ingest(again)
            // A paper in Recently Deleted, then another copy of it.
            let hippo = "Spatial transcriptomics of the mouse hippocampus"
            let hippoDOI = "10.1038/s41593-025-01111-1"
            var deleted: String?
            if let id = await ingest(try file("hippocampus.pdf", title: hippo, doi: hippoDOI, seed: "hippo")).added.first {
                try await engine.softDelete(paperID: id)
                deleted = id
            }
            await ingest(try file("hippocampus-download.pdf", title: hippo, doi: hippoDOI, seed: "hippo 2"))
            return Fixture(deletedPaperID: deleted, expectedReviews: 5)
        }
    }

    // MARK: Generated PDFs

    /// Distinct body text per seed.
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

    /// A PDF with a big title line, an author line, an optional DOI line and body text.
    static func pdf(title: String, doi: String?, body: String, pages: Int, tag: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        let words = body.split(separator: " ").map(String.init)
        for page in 0..<max(1, pages) {
            var lines: [(String, CGFloat)] = []
            if page == 0 {
                lines.append((title, 18))
                lines.append(("Ada Lovelace and Grace Hopper", 11))
                if let doi { lines.append(("DOI: \(doi)", 9)) }
                lines.append(("Abstract", 12))
            }
            let start = (page * 96) % max(1, words.count)
            for i in stride(from: start, to: min(words.count, start + 96), by: 12) {
                lines.append((words[i..<min(words.count, i + 12)].joined(separator: " "), 10))
            }
            if page == 0 { lines.append(("file \(tag)", 8)) }
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
        return data as Data
    }
}

/// The email merge popover's duplicate part as the renders draw it (the popover needs a mail card).
struct MailDuplicatePreview: View {
    let match: MailDupMatch
    @State private var choice: MailDupChoice

    init(match: MailDupMatch) {
        self.match = match
        _choice = State(initialValue: match.defaultChoice)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.Mail.mergeTitleOne).font(.headline)
            Divider()
            MailDuplicateSection(match: match, choice: $choice)
            Divider()
            Text(L.Dedupe.mailOptionsApplyToAdd).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L.cancel) {}
                Button(L.Dedupe.mailConfirm(choice)) {}.buttonStyle(.borderedProminent)
            }
        }
    }
}
