import AppKit
import PaperDeckCore
import PaperDeckConfig

/// Parsed `--flag value` / `--flag` arguments.
struct CLIArgs {
    let command: String?
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ argv: [String]) {
        let args = Array(argv.dropFirst())
        command = args.first.flatMap { CLIRunner.commands.contains($0) ? $0 : nil }
        var i = command == nil ? 0 : 1
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") { values[a] = args[i + 1]; i += 2; continue }
                flags.insert(a)
            } else if values["_positional"] == nil {
                values["_positional"] = a
            }
            i += 1
        }
    }

    func value(_ key: String) -> String? { values[key] }
    func has(_ key: String) -> Bool { flags.contains(key) || values[key] != nil }
    var positional: String? { values["_positional"] }

    func url(_ key: String) -> URL? {
        value(key).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }
    func int(_ key: String) -> Int? { value(key).flatMap(Int.init) }
    /// ISO 8601 with a zone, or local time without one (2026-09-29T10:00:00). A `--now` that is
    /// present but doesn't parse never gets here: `runIfRequested` refuses it first.
    func date(_ key: String) -> Date? {
        value(key).flatMap(CommandLineRules.date)
    }
}

/// Dispatches headless command-line modes. Returns nil when the arguments ask
/// for the normal GUI.
enum CLIRunner {
    static let commands: Set<String> = [
        "--version", "--help", "-h", "--selftest", "--doctor", "--agent-argv", "--agent-smoke",
        "--plan-reminders", "--rebuild-index", "--dump-canonical", "--render", "--mail-flow-package",
        "--mail-dry-run", "--mail-sync", "--config", "--migrate-dry-run", "--export-settings", "--import-settings",
        "--guide-export", "--assist-argv", "--assist-smoke", "--dedupe-report", "--dedupe-render",
        "--ask-render", "--explain-render",
    ]

    static func runIfRequested(_ argv: [String]) -> Int32? {
        // A mistyped `--option` (or `--gui-root` without a folder, or an unparsable `--now`) is an
        // error, never the GUI on the real library; single-dash AppKit arguments still pass.
        switch CommandLineRules.launch(argv, commands: commands) {
        case .gui: return nil
        case .refuse(let message): return fail(message)
        case .command: break
        }
        let args = CLIArgs(argv)
        guard let command = args.command else { return nil }
        switch command {
        case "--version":
            print("PaperDeck \(versionString)")
            return 0
        case "--help", "-h":
            print(usage)
            return 0
        case "--selftest": return spin { await SelfTest.run(args) }
        case "--doctor": return spin { await Doctor.run(args) }
        case "--agent-argv": return spin { await AgentCLI.argv(args) }
        case "--agent-smoke": return spin { await AgentCLI.smoke(args) }
        case "--plan-reminders": return spin { await SelfTest.planReminders(args) }
        case "--rebuild-index": return spin { await SelfTest.rebuildIndex(args) }
        case "--dump-canonical": return spin { await SelfTest.dumpCanonical(args) }
        case "--render": return spin { await PreviewRenderer.run(args) }
        case "--mail-flow-package": return mailFlowPackage(args)
        case "--mail-dry-run": return spin { await MailCLI.dryRun(args) }
        case "--mail-sync": return spin { await MailCLI.sync(args) }
        case "--config": return ConfigCLI.config(args)
        case "--migrate-dry-run": return ConfigCLI.migrateDryRun(args)
        case "--export-settings": return ConfigCLI.exportSettings(args)
        case "--import-settings": return ConfigCLI.importSettings(args)
        case "--guide-export": return GuideExport.run(args)
        case "--assist-argv": return AssistCLI.argv(args)
        case "--assist-smoke": return spin { await assistSmoke(args) }
        case "--dedupe-report": return spin { await DedupeCLI.report(args) }
        case "--dedupe-render": return spin { await DedupeCLI.render(args) }
        case "--ask-render": return spin { await AskRenders.run(args) }
        case "--explain-render": return spin { await ExplainRenders.run(args) }
        default: return nil
        }
    }

    /// Writes the ready-to-import Power Automate package (Import ▸ Import Package (Legacy)).
    /// Senders come from `--senders "a@x.edu;@biorxiv.org"` (';' or ',' separated) or, with
    /// `--from-settings`, from the app's enabled sender list (read-only). Nothing else is touched.
    static func mailFlowPackage(_ args: CLIArgs) -> Int32 {
        guard let out = args.positional else {
            return fail("--mail-flow-package OUT.zip [--senders \"a@x.edu;b@y.org\" | --from-settings] [--folder \"/PaperDeck Mail\"] [--name NAME] [--lang en|zh]")
        }
        let senders: [String] = args.has("--from-settings")
            ? PowerAutomatePackage.senders(from: MailSettings.load().senders)
            : (args.value("--senders") ?? "").split(whereSeparator: { ";,\n".contains($0) }).map(String.init)
        let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        let folder = args.value("--folder") ?? PowerAutomatePackage.defaultFolderPath
        let name = args.value("--name") ?? PowerAutomatePackage.defaultFlowName
        do {
            try PowerAutomatePackage.makeZip(senders: senders, folderPath: folder, flowName: name, into: url)
        } catch {
            return fail("\(error)")
        }
        let plan = PowerAutomatePackage.senderPlan(senders)
        line(["ok": true, "out": url.path, "from": plan.fromFilter, "allSenders": plan.allSenders,
              "addresses": plan.addresses, "domainRules": plan.domainRules, "ignored": plan.ignored])
        if plan.allSenders {
            FileHandle.standardError.write(Data((plan.domainRules.isEmpty
                ? "note: no exact sender addresses: the flow saves ALL Inbox mail; PaperDeck filters locally.\n"
                : "note: domain rules (\(plan.domainRules.joined(separator: ", "))) can't be expressed in the From field: the flow saves ALL Inbox mail; PaperDeck filters locally.\n").utf8))
        }
        let lang = UILang(rawValue: args.value("--lang") ?? "en") ?? .en
        print(PowerAutomatePackage.importInstructions(fileName: url.lastPathComponent, flowName: name, folderPath: folder, lang: lang))
        return 0
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    /// Runs async work on the main actor while pumping the main run loop (so
    /// MainActor hops inside the engine never deadlock).
    static func spin(_ work: @escaping () async -> Int32) -> Int32 {
        final class Box { var value: Int32? }
        let box = Box()
        Task { box.value = await work() }
        while box.value == nil {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        return box.value!
    }

    static let usage = """
    PaperDeck \(versionString) — paper-reading manager

    GUI:  open -a PaperDeck
          PaperDeck --gui-root DIR                  dev: the GUI on an isolated library in DIR. Only the library:
                                                    settings (the defaults domain) and the single-instance lock
                                                    are the normal ones, so quit the running PaperDeck first
                                                    (refused, exit 1, while it runs). An unknown --option exits 2.

    Headless (never touch the real library unless noted):
      --selftest import|schedule|agent|storage|all --root DIR [--fixtures DIR] [--agent off|mock|claude|codex]
                 [--network on|off] [--only FILE.pdf] [--now 2026-09-29T10:00:00] [--yes --max-runs N]
      --selftest mail --root DIR --fixtures EML_DIR [--agent mock|off] [--senders "advisor:a@x.edu;alert:@y.org"]
                                                    import .eml via the engine, mock AI triage, cards + counts,
                                                    merge one attachment, check provenance (offline, no mail server)
      --selftest mail-notify [--lang en|zh]        rules + text of the new-reading-request notification (synthetic
                                                    cards; nothing posted, no library)
      --selftest strings --write FILE | --check FILE [--lang en|zh] [--write-prompt FILE]
                                                    the organization- and field-dependent strings + the card prompt's
                                                    sha256 against a golden fixture (pure; no library, nothing spawned)
      --selftest app-rules [--lang en|zh]         launch alert (newer / failed database, app folders, Retry), saved
                                                    app password reuse on account edits, which account Settings ▸ Mail
                                                    un-parks, the inspector's email text, account status language
                                                    (scratch folders under $TMPDIR, fake mail sources; no library)
      --selftest settings [--lang en|zh]          institution / field strings, ConfigStore writes, settings import
                                                    rules, mail templates and Library ▸ Change… decisions (scratch
                                                    defaults; never the app's domain, no keychain, nothing spawned)
      --selftest onboarding [--lang en|zh]        setup window writes, gate, AI preselection, mail routes, finish /
                                                    revisit rules (scratch defaults, fake facts; no CLI, no keychain)
      --selftest dedupe [--lang en|zh]            duplicate strings (en ≠ zh), review toasts' buttons, the sheet's
                                                    choice mapping (pure; no library, nothing spawned)
      --selftest qa [--lang en|zh]                Ask strings (en ≠ zh), failure notices, ticket gestures, the
                                                    estimate line, citation links, stream coalescing (pure)
      --plan-reminders --root DIR [--now ISO]      print the 14-day reminder plan
      --rebuild-index --root DIR                    rebuild the DB from card.json sidecars
      --dump-canonical --root DIR                   deterministic JSON dump (rebuild fidelity)
      --render OUTDIR --root DIR [--lang zh|en] [--appearance light|dark] [--provider claude|codex] [--mode off|claude|codex]
                 [--provider-state ready]           offscreen PNGs of the window (AI providers are mocks;
                                                    --provider-state ready: the mocks report signed in)
                 [--mail-fixtures EML_DIR] [--mail-folder EML_DIR] [--mail-only] [--seed-plist FILE]
                                                    + the Mail inbox / folder-account pages; --mail-only skips the
                                                    rest (Settings ▸ AI and setup probe the CLIs with --version);
                                                    --seed-plist loads a settings plist into the render suite
                                                    instead of the demo accounts
                 [--mail-widths "720, 900, 1280" [--mail-widths-only]]
                                                    with --mail-fixtures: the Mail inbox in whole windows of those
                                                    widths; --mail-widths-only skips the other inbox pages
                 [--guide-only --scenario fresh|legacy|codexOnly|noAI|allReady|mailError|m365Contoso]
                                                    setup window pages + Help Center with canned facts; no CLI probes
                 [--select-only [--no-mail-demo] [--probe-gestures]]
                                                    multi-select PNGs (fixture papers when --root is empty);
                                                    --probe-gestures drives the grid off-screen (PROBE … PASS|FAIL);
                                                    no Settings ▸ AI / setup page, agent queue never started
                 [--reader-only [--no-mail-demo] [--probe-reader]]
                                                    the built-in reader's PNGs (fixture PDF printed i, ii, 1201–1204;
                                                    missing / damaged / locked files); --probe-reader drives it
                                                    off-screen (PROBE … PASS|FAIL); no CLI probed, no window shown
                 [--library-only [--widths "720, 900, 1280"] [--no-mail-demo]]
                                                    the library's columns at those window widths (default 720 …
                                                    2560), Today, grouped To Read, a selection, search, the
                                                    inspector (fixture papers when --root is empty); no CLI probed
      --guide-export DIR [--lang en|zh]             Help topics as Markdown: TROUBLESHOOTING.generated.<lang>.md +
                                                    GUIDE.generated.<lang>.md (pure; nothing spawned)
      --dedupe-report --root DIR [--json] [--sensitivity strict|balanced|loose]
                                                    the pairs a duplicate check would ask about (a scratch copy of
                                                    DIR's database; no network, no AI, DIR never written)
      --dedupe-render OUTDIR --root SCRATCH [--lang zh|en] [--appearance light|dark] [--extra-papers N]
                                                    a generated fixture library + PNGs of the duplicate sheets, list,
                                                    ribbon, chip, sidebar row, settings and toasts (no CLI probed)
      --ask-render OUTDIR --root SCRATCH [--lang zh|en] [--appearance light|dark] [--probe-send]
                                                    a generated fixture library + PNGs of every Ask state (tab, window,
                                                    PagePeek, settings); mock assist backend only, no CLI probed;
                                                    --probe-send drives the real Ask tab off-screen (PROBE … PASS|FAIL)
      --explain-render OUTDIR --root SCRATCH [--lang zh|en] [--appearance light|dark]
                                                    a generated fixture library + PNGs of every Explain state (panel,
                                                    overlay, explainer, settings, history); mock assist backend only,
                                                    no CLI probed, no screen captured, no hotkey or Services installed
      --doctor [--root DIR] [--mail-only]           Claude + Codex CLI, login (no quota), agent.mode, DB, signing, widget,
                                                    mail accounts / senders / statuses (never a secret, no network);
                                                    bundle id, keychain service, channel, institution and field
                                                    (--mail-only: identity, configuration and mail only; no CLI);
                                                    the database is opened read-only (never upgraded or backed up:
                                                    an older schema is reported, "open the app to upgrade")
      --agent-argv [--provider claude|codex] [--root DIR]
                                                    dry-run: argv, cwd, env keys, stdin size (no spawn)
      --agent-smoke --yes [--provider claude|codex] [--max-runs N] [--root DIR]
                                                    REAL claude -p / codex exec on a tiny synthetic paper (spends quota)
      --assist-argv [explain|qa|judge] [--provider claude|codex] [--model M] [--root DIR]
                                                    dry-run of one Explain & Ask turn: argv, cwd, env keys, stdin
                                                    shape (pure builders only: nothing located, probed or spawned)
      --assist-smoke --yes [--provider claude|codex] [--max-runs N≤6] [--turns K≤N] [--root DIR] [--record DIR]
                 [--prewarm-idle S]                 REAL quick-model assist turns on a synthetic figure (spends quota;
                                                    refused without --yes; at most 6 turns; --record keeps raw lines)
      --mail-flow-package OUT.zip [--senders "a@x.edu;b@y.org" | --from-settings] [--folder "/PaperDeck Mail"] [--name NAME] [--lang en|zh]
                                                    Power Automate flow package: Import ▸ Import Package (Legacy)
      --mail-dry-run FILE.eml [--root DIR] [--kind advisor|person|alert] [--senders SPEC] [--lang en|zh] [--stdin-only]
                 [--default-settings] [--defaults-suite NAME] [--now ISO]
                                                    parse + extraction + local triage + the exact AI triage stdin
                                                    (Settings ▸ Mail read-only; no spawn, no network, nothing stored);
                                                    --default-settings: the built-in mail settings instead of the
                                                    app's; --defaults-suite: read settings from that domain instead;
                                                    --now: the clock the dates are read against
      --mail-sync --root DIR (--defaults-suite NAME | --real-accounts)
                                                    one sync pass into DIR: scratch accounts, or the app's own with
                                                    --real-accounts (connects to your mail servers, reads the keychain;
                                                    watched-folder files are never deleted; AI triage off, zero quota)

    Configuration (read-only: never writes a defaults domain, never spawns; values from --plist FILE
    (e.g. a `defaults export` copy), --suite NAME, or else this app's own domain):
      --config [--plist FILE | --suite NAME] [--db-exists yes|no] [--json] [--card-prompt | --card-prompt-sha256]
                                                    institution, field, stage, origin, date order, this build's bundle
                                                    id / widget id / keychain service / channel; the card prompt it sends
      --migrate-dry-run [--plist FILE | --suite NAME] [--db-exists yes|no] [--json] [--now ISO] [--out NEW.plist]
                                                    the keys the first launch of this build would add (only absent
                                                    keys; legacy installs are backed up first); --out writes the
                                                    migrated copy to a new plist file
      --export-settings OUT.json [--plist FILE | --suite NAME] [--sections profile,organization,…]
                 [--include-mailbox-addresses] [--include-personal] [--home DIR]
                                                    a paperdeck.settings/1 file like Settings ▸ General ▸ Export
                                                    Settings… (no passwords; the keychain is never read);
                                                    mailbox addresses only with --include-mailbox-addresses,
                                                    the Crossref contact email (and addresses) only with
                                                    --include-personal
      --import-settings IN.json --dry-run [--plist FILE | --suite NAME] [--sections …] [--keep-people-always]
                 [--accept-reader] [--accept-instructions] [--accept-looser] [--home DIR] [--lang en|zh]
                                                    what an import would change and warn about (an import never turns
                                                    AI reading or Mail on; a privacy or quota setting looser than this
                                                    Mac's is kept stricter unless --accept-looser; the reader
                                                    description / triage instructions only with --accept-reader /
                                                    --accept-instructions; out-of-range values are dropped); a real
                                                    import is GUI-only
    """

    // MARK: Assist smoke

    /// `--assist-smoke --yes …`: the lead's format verification (READING_ASSIST_PLAN §9.2). Refused
    /// without `--yes`, and never more than `AssistSmoke.hardCap` real turns: the smoke lane's own
    /// RunBudget(`--max-runs`) sits behind the real `AssistGate`. `--yes` is the gesture: each turn
    /// gets its ticket here, right before it runs.
    static func assistSmoke(_ args: CLIArgs) async -> Int32 {
        let plan: AssistSmoke.Plan
        switch AssistSmoke.plan(yes: args.has("--yes"), provider: args.value("--provider"), maxRuns: args.int("--max-runs"),
                                turns: args.int("--turns"), prewarmIdle: args.int("--prewarm-idle")) {
        case .failure(let refusal): return fail(refusal.description)
        case .success(let p): plan = p
        }
        var recorder: AssistSmoke.Recorder?
        if let dir = args.url("--record") {
            do { recorder = try AssistSmoke.Recorder(dir: dir) } catch { return fail("cannot write to --record \(dir.path): \(error)") }
        }
        defer { recorder?.close() }
        let backend = AssistCLI.smokeBackend(plan, args: args, tap: recorder?.tap)
        let status = await backend.detect()
        print("detect: \(status)")
        guard case .ready = status else { return 1 }
        let (lane, budget) = AssistSmoke.lane(plan, backend: backend)
        let reports = await AssistSmoke.run(
            plan, lane: lane, image: AssistSmoke.syntheticFigure(),
            ticket: { gesture in ConsentTicket.mint(gesture, surface: .explain) },
            prewarm: plan.prewarmIdleSeconds.map { _ in ArmingToken.arm() },
            idle: .seconds(plan.prewarmIdleSeconds ?? 0), log: { print($0) })
        for r in reports { AssistCLI.report(r) }
        line(["runsUsed": budget.consumed, "maxRuns": plan.maxRuns, "provider": plan.provider.rawValue])
        return reports.count == plan.turns && reports.allSatisfy { $0.outcome == "success" } ? 0 : 1
    }

    // MARK: Output helpers

    static func line(_ object: [String: Any?]) {
        let clean = object.compactMapValues { $0 }
        if let data = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys, .withoutEscapingSlashes]),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        }
    }

    static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        return 2
    }
}
