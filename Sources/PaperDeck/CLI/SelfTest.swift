import Foundation
import PaperDeckCore

/// Headless end-to-end checks against an isolated `--root` library. Default AI
/// provider is the mock; a real run needs `--agent claude|codex --yes --max-runs N`.
enum SelfTest {
    static let defaultFixtures = SharedPaths.realHome.appendingPathComponent("Library/Caches/PaperDeck-dev/fixtures", isDirectory: true)

    struct Options {
        var root: URL
        var fixtures: URL
        var agent: AgentMode
        var network: Bool
        var only: String?
        var now: Date?
        var maxRuns: Int?
        var confirmed: Bool

        init?(_ args: CLIArgs) {
            guard let root = args.url("--root") else { return nil }
            self.root = root
            fixtures = args.url("--fixtures") ?? SelfTest.defaultFixtures
            agent = AgentMode(rawValue: args.value("--agent") ?? "mock") ?? .mock
            network = (args.value("--network") ?? "on") != "off"
            only = args.value("--only")
            now = args.date("--now")
            maxRuns = args.int("--max-runs")
            confirmed = args.has("--yes")
        }
    }

    // MARK: Engine

    static func settings(_ o: Options) -> EngineSettings {
        EngineSettings(plan: PlanSettings(), lang: .zh, agentMode: o.agent, autoReadNewPapers: o.agent != .off,
                       metadataLookup: o.network)
    }

    /// `mail`: the self-test's own Settings ▸ Mail (default: empty — never the user's).
    static func openEngine(_ o: Options, mail: MailSettings = MailSettings()) async throws -> Engine {
        try FileManager.default.createDirectory(at: o.root, withIntermediateDirectories: true)
        let s = settings(o)
        let fixedNow = o.now
        let deps = Engine.Dependencies(
            loadSettings: { s },
            now: { fixedNow ?? Date() },
            fetcher: o.network ? URLSessionHTTPFetcher() : nil,
            // Only --agent claude / --agent codex may build that real CLI provider; everything else is a mock.
            claude: o.agent == .claude ? nil : MockAgentProvider(behavior: .notLoggedIn),
            codex: o.agent == .codex ? nil : MockAgentProvider(behavior: .notLoggedIn),
            mock: MockAgentProvider(),
            sidecarDelay: .milliseconds(50),
            cliFacts: .inMemory(),         // never write learned CLI facts into the app's UserDefaults
            // Never the user's Settings ▸ Mail (real accounts) nor the login keychain.
            loadMailSettings: { mail },
            mailSecrets: InMemoryMailSecretStore()
        )
        let engine = try await Engine.open(paths: AppPaths.rooted(at: o.root), deps: deps)
        await engine.agents.setLogObserver { print("[agent] \($0)") }
        return engine
    }

    // MARK: Entry

    static func run(_ args: CLIArgs) async -> Int32 {
        // Pure rules, no library: needs no --root.
        if args.positional == "mail-notify" { return SelfTestMailNotify.run(args) }
        if args.positional == "app-rules" { return await SelfTestAppRules.run(args) }
        if args.positional == "strings" { return SelfTestStrings.run(args) }
        if args.positional == "settings" { return await SelfTestSettings.run(args) }
        if args.positional == "onboarding" { return await SelfTestOnboarding.run(args) }
        if args.positional == "dedupe" { return SelfTestDedupe.run(args) }
        if args.positional == "qa" { return SelfTestQA.run(args) }
        guard let o = Options(args) else { return CLIRunner.fail("--selftest needs --root DIR (an isolated scratch library)") }
        if let kind = o.agent.providerKind {
            guard o.confirmed, let n = o.maxRuns, n > 0 else {
                return CLIRunner.fail("--agent \(kind.rawValue) spends \(kind.shortName) subscription quota: pass --yes --max-runs N")
            }
        }
        let mode = args.positional ?? "all"
        if mode == "mail" { return await SelfTestMail.run(args, o) }
        do {
            let engine = try await openEngine(o)
            if o.agent.providerKind != nil, let n = o.maxRuns { engine.runBudget.setLimit(n) }
            await engine.start()
            var ok = true
            switch mode {
            case "import": ok = try await importFixtures(engine, o)
            case "schedule": ok = try await schedule(engine, o)
            case "agent": ok = try await agent(engine, o)
            case "storage": ok = try await storage(engine, o)
            case "all":
                ok = try await importFixtures(engine, o)
                ok = try await schedule(engine, o) && ok
                ok = try await agent(engine, o) && ok
                ok = try await storage(engine, o) && ok
            default:
                return CLIRunner.fail("unknown selftest '\(mode)' (import|schedule|agent|storage|all|mail)")
            }
            await engine.shutdown()
            print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
            return ok ? 0 : 1
        } catch {
            return CLIRunner.fail(String(describing: error))
        }
    }

    // MARK: import

    static func fixtureFiles(_ o: Options) -> [URL] {
        let fm = FileManager.default
        let all = ((try? fm.contentsOfDirectory(at: o.fixtures, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let only = o.only { return all.filter { $0.lastPathComponent == only } }
        return all
    }

    static func importFixtures(_ engine: Engine, _ o: Options) async throws -> Bool {
        let files = fixtureFiles(o)
        guard !files.isEmpty else { print("no fixtures in \(o.fixtures.path)"); return false }
        var ok = true
        var added = 0
        for url in files {
            let t0 = Date()
            let s = await engine.intake.ingest([.file(url)], options: ImportOptions(origin: .cli, ai: .skip))
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let result = !s.added.isEmpty ? "added" : s.duplicates > 0 ? "duplicate" : s.rejected > 0 ? "rejected" : "failed"
            var info: [String: Any?] = ["file": url.lastPathComponent, "result": result, "ms": ms]
            if let id = s.added.first, let p = try await engine.db.paper(id: id) {
                added += 1
                info["pages"] = p.pageCount
                info["title"] = String(p.title.prefix(70))
                info["doi"] = p.ids.doi
                info["arxiv"] = p.ids.arxivID
                info["deadline"] = p.deadline?.iso
                info["est"] = p.estMinutes
                let items = try await engine.db.checklist(paperPK: p.pk)
                info["checklist"] = items.count
                if items.reduce(0, { $0 + $1.minutes }) != p.estMinutes { ok = false; info["error"] = "Σminutes != est" }
                info["cloned"] = FileOps.mayShareFileContent(engine.ctx.pdfURL(p))
            }
            CLIRunner.line(info)
        }
        await engine.enrich.waitUntilIdle()
        // Second pass must be all duplicates.
        var dupes = 0
        for url in files {
            let s = await engine.intake.ingest([.file(url)], options: ImportOptions(origin: .cli, ai: .skip))
            dupes += s.duplicates
        }
        CLIRunner.line(["check": "reimport", "duplicates": dupes, "expected": added])
        if dupes != added { ok = false }
        // A text file named .pdf must be rejected.
        let bad = o.fixtures.appendingPathComponent("bad/fake.pdf")
        if FileManager.default.fileExists(atPath: bad.path), o.only == nil {
            let s = await engine.intake.ingest([.file(bad)], options: ImportOptions(origin: .cli, ai: .skip))
            CLIRunner.line(["check": "fake.pdf", "rejected": s.rejected])
            if s.rejected != 1 { ok = false }
        }
        // Final metadata/filing state.
        let snap = try await engine.librarySnapshot()
        var canonical = 0
        for row in snap.rows {
            let p = row.paper
            if [.crossref, .arxiv, .biorxiv, .openalex].contains(p.metaSource) { canonical += 1 }
            CLIRunner.line(["paper": String(p.title.prefix(60)), "source": p.metaSource.rawValue, "year": p.year,
                            "venue": p.venue, "folder": p.folder, "stage": p.stage.rawValue])
        }
        CLIRunner.line(["check": "metadata", "canonical": canonical, "papers": snap.rows.count, "network": o.network])
        return ok
    }

    // MARK: schedule / reminders / widget

    static func schedule(_ engine: Engine, _ o: Options) async throws -> Bool {
        let snap = try await engine.librarySnapshot()
        let t = snap.today
        CLIRunner.line(["today": t.today.iso, "overdue": t.overdue.count, "dueToday": t.dueToday.count,
                        "planned": t.plannedToday.count, "minutes": t.todayMinutes, "backlog": t.backlogTotal,
                        "unscheduled": t.unscheduled, "atRisk": t.atRisk.count])
        for row in snap.rows {
            CLIRunner.line(["paper": String(row.paper.title.prefix(50)), "deadline": row.paper.deadline?.iso,
                            "mode": row.paper.scheduleMode.rawValue, "priority": row.paper.priority.rawValue,
                            "remaining": row.remainingMinutes, "atRisk": row.atRisk])
        }
        let plan = try await engine.reminderPlan(from: o.now ?? Date())
        CLIRunner.line(["check": "reminders", "count": plan.count, "first": plan.first?.id])
        var ok = plan.count == 14 || snap.rows.isEmpty
        if let first = plan.first {
            print("  \(first.title)\n  \(first.subtitle)\n" + first.body.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
        }
        let wrote = try await engine.writeWidgetSnapshot()
        let again = try await engine.writeWidgetSnapshot()
        CLIRunner.line(["check": "widget-snapshot", "written": wrote, "rewrittenWhenUnchanged": again])
        if again { ok = false }
        return ok
    }

    // MARK: agent

    static func agent(_ engine: Engine, _ o: Options) async throws -> Bool {
        guard o.agent != .off else { print("agent: off (skipped)"); return true }
        var papers = try await engine.db.livePapers()
        if let only = o.only { papers = papers.filter { $0.originalName == only } }
        papers = papers.filter { $0.flags.isDisjoint(with: [.locked, .scanned, .unreadable]) }
        for p in papers { await engine.agents.enqueue(paperPK: p.pk, hold: false) }
        await engine.agents.wake()
        // Wait until nothing is queued or running (or the budget stops the queue).
        let deadline = Date().addingTimeInterval(o.agent.providerKind != nil ? 600 : 120)
        while Date() < deadline {
            let s = await engine.agents.status()
            if s.queued == 0 && s.runningPaperID == nil { break }
            if engine.runBudget.isExhausted && s.runningPaperID == nil { break }
            try await Task.sleep(for: .milliseconds(300))
        }
        var ok = true
        for p in papers {
            guard let fresh = try await engine.db.paper(pk: p.pk) else { continue }
            let job = try await engine.db.recentJobs(limit: 200).first { $0.paperPK == p.pk }
            CLIRunner.line(["paper": String(fresh.title.prefix(50)), "ai": fresh.aiState.rawValue,
                            "tldr": fresh.tldr.map { String($0.prefix(120)) }, "category": fresh.categoryPK,
                            "est": fresh.estMinutes, "model": job?.model, "ms": job?.durationMs,
                            "costUSD": job?.costUSD, "note": fresh.aiNote])
            if o.agent == .mock && fresh.aiState != .done { ok = false }
        }
        if o.agent.providerKind != nil { CLIRunner.line(["runsUsed": engine.runBudget.consumed, "limit": engine.runBudget.maxRuns]) }
        return ok
    }

    // MARK: storage + rebuild fidelity

    static func storage(_ engine: Engine, _ o: Options) async throws -> Bool {
        let s = try await engine.storage.stats()
        CLIRunner.line(["papers": s.paperCount, "logicalBytes": s.logicalBytes, "estimatedSharedBytes": s.estimatedSharedBytes,
                        "thumbnailBytes": s.thumbnailBytes, "textCacheBytes": s.textCacheBytes,
                        "databaseBytes": s.databaseBytes, "missingFiles": s.missingFiles])
        await engine.ctx.sidecars.flush()
        let before = try await engine.dumpCanonical()
        // Rebuild into a copy of the library so the scratch root stays intact.
        let copyRoot = o.root.deletingLastPathComponent().appendingPathComponent(o.root.lastPathComponent + "-rebuild")
        try? FileManager.default.removeItem(at: copyRoot)
        try FileManager.default.createDirectory(at: copyRoot, withIntermediateDirectories: true)
        let src = AppPaths.rooted(at: o.root), dst = AppPaths.rooted(at: copyRoot)
        try FileManager.default.copyItem(at: src.library, to: dst.library)
        try FileManager.default.createDirectory(at: dst.support, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: src.textCache.path) {
            try FileManager.default.copyItem(at: src.textCache, to: dst.textCache)
        }
        var copyOptions = o
        copyOptions.root = copyRoot
        copyOptions.network = false
        let rebuilt = try await openEngine(copyOptions)
        let report = await rebuilt.start()      // empty DB + sidecars → rebuild
        let after = try await rebuilt.dumpCanonical()
        await rebuilt.shutdown()
        let same = before == after
        CLIRunner.line(["check": "rebuild", "identical": same, "bytes": before.count,
                        "rebuiltPapers": report.rebuilt?.papers])
        if !same {
            try? before.write(to: o.root.appendingPathComponent("canonical-before.json"))
            try? after.write(to: o.root.appendingPathComponent("canonical-after.json"))
            print("  diff: \(o.root.path)/canonical-{before,after}.json")
        }
        return same
    }

    // MARK: other commands

    static func planReminders(_ args: CLIArgs) async -> Int32 {
        guard var o = Options(args) else { return CLIRunner.fail("--plan-reminders needs --root DIR") }
        o.agent = .off
        o.network = false
        do {
            let engine = try await openEngine(o)
            for spec in try await engine.reminderPlan(from: o.now ?? Date()) {
                print("\(spec.id)  fire=\(spec.fireComponents)\n  \(spec.title)\n  \(spec.subtitle)")
                print(spec.body.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))
            }
            await engine.shutdown()
            return 0
        } catch { return CLIRunner.fail(String(describing: error)) }
    }

    static func rebuildIndex(_ args: CLIArgs) async -> Int32 {
        guard var o = Options(args) else { return CLIRunner.fail("--rebuild-index needs --root DIR") }
        o.agent = .off
        o.network = false
        do {
            let engine = try await openEngine(o)
            let report = try await engine.rebuildFromSidecars(replacingExisting: true)
            print(report)
            await engine.shutdown()
            return 0
        } catch { return CLIRunner.fail(String(describing: error)) }
    }

    static func dumpCanonical(_ args: CLIArgs) async -> Int32 {
        guard var o = Options(args) else { return CLIRunner.fail("--dump-canonical needs --root DIR") }
        o.agent = .off
        o.network = false
        do {
            let engine = try await openEngine(o)
            FileHandle.standardOutput.write(try await engine.dumpCanonical())
            print()
            await engine.shutdown()
            return 0
        } catch { return CLIRunner.fail(String(describing: error)) }
    }
}
