import Foundation
import PaperDeckCore

/// Mail command-line modes:
/// - `--mail-dry-run FILE.eml [--root R]` — parse, extract, local triage and the exact triage
///   stdin, offline: no spawn, no network, nothing stored.
/// - `--mail-sync --root R (--defaults-suite NAME | --real-accounts)` — one sync pass into an
///   isolated library (AI triage off, zero quota). The app's own accounts (and the login
///   keychain) are read only with an explicit `--real-accounts`; a watched folder's files are
///   never deleted by this command. Never used by tests with real servers.
enum MailCLI {

    // MARK: Settings sources

    /// Settings ▸ Mail for a CLI run: `--defaults-suite NAME` (a scratch UserDefaults domain),
    /// else the app's own settings (read-only). `--senders "advisor:a@x.edu;alert:@biorxiv.org"`
    /// appends rules (kind defaults to person).
    static func mailSettings(_ args: CLIArgs) -> (MailSettings, suite: UserDefaults?) {
        var suite: UserDefaults?
        if let name = args.value("--defaults-suite") { suite = UserDefaults(suiteName: name) }
        var s = args.has("--default-settings") ? MailSettings() : MailSettings.load(from: suite ?? .standard)
        s.senders += senderRules(args.value("--senders"))
        return (s, suite)
    }

    /// `"advisor:prof@x.edu; alert:@biorxiv.org; @lab.org"` → rules (unknown kinds → person).
    static func senderRules(_ spec: String?) -> [SenderRule] {
        guard let spec else { return [] }
        return spec.split(whereSeparator: { ";,\n".contains($0) }).compactMap { raw in
            let part = raw.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { return nil }
            var kind = SenderKind.person
            var pattern = part
            if let colon = part.firstIndex(of: ":"), let k = SenderKind(rawValue: String(part[..<colon]).lowercased()), k != .manual {
                kind = k
                pattern = String(part[part.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            guard SenderMatcher.Pattern(pattern) != nil else { return nil }
            return SenderRule(id: "cli-" + pattern.lowercased(), pattern: pattern, label: pattern, kind: kind)
        }
    }

    // MARK: --mail-dry-run

    static func dryRun(_ args: CLIArgs) async -> Int32 {
        guard let path = args.positional else {
            return CLIRunner.fail("--mail-dry-run FILE.eml [--root DIR] [--kind advisor|person|alert] [--senders SPEC] [--default-settings] [--defaults-suite NAME] [--lang en|zh] [--now ISO] [--stdin-only]")
        }
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var (settings, suite) = mailSettings(args)
        var es = EngineSettings.load(from: suite ?? .standard)
        if let lang = args.value("--lang").flatMap(UILang.init(rawValue:)) { es.lang = lang }
        let now = args.date("--now") ?? Date()
        let calendar = Calendar.current
        let attachmentCap = max(1, settings.maxAttachmentMB) << 20
        let fetchLimit = attachmentCap / 3 * 4 + (2 << 20)

        let data: Data
        do {
            data = try await BlockingIO.run { try FileOps.readHead(file, bytes: fetchLimit) }
        } catch {
            return CLIRunner.fail("can't read \(file.path): \(error.localizedDescription)")
        }
        let content: MailContent
        do {
            content = try await BlockingIO.run { try MIMEParser.parse(data, maxAttachmentBytes: attachmentCap) }
        } catch {
            return CLIRunner.fail("not an email: \(error)")
        }
        guard !content.header.fromAddress.isEmpty || !content.header.subject.isEmpty else {
            return CLIRunner.fail("not an email (no From / Subject)")
        }

        // Sender rule: --kind forces one (as if the address were on the list).
        var rule = SenderMatcher.match(address: content.header.fromAddress, rules: settings.senders)
        if let k = args.value("--kind").flatMap(SenderKind.init(rawValue:)), k != .manual {
            let forced = SenderRule(id: "cli-kind", pattern: SenderMatcher.normalize(content.header.fromAddress),
                                    label: "--kind \(k.rawValue)", kind: k)
            settings.senders.insert(forced, at: 0)
            rule = forced
        }

        // Library context for <library> (only an isolated --root; never the real library).
        var categories: [String] = []
        var tags: [String] = []
        if let root = args.url("--root") {
            let paths = AppPaths.rooted(at: root)
            if FileManager.default.fileExists(atPath: paths.database.path) {
                do {
                    let db = try await Database.open(url: paths.database, backupsDir: nil)
                    categories = try await db.categories().map(\.name)
                    tags = try await db.frequentTags(limit: MailTriageSchema.maxFrequentTags).map(\.name)
                    await db.close()
                } catch {
                    FileHandle.standardError.write(Data("note: library context unavailable (\(error))\n".utf8))
                }
            }
        }

        // Attachments: stored like a capture (in a throw-away folder) for the first-page block.
        let truncated = data.count >= fetchLimit
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("paperdeck-mail-dry-run-\(UUID().uuidString.lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fetcher = MailPDFFetcher(root: scratch)
        let messageID = UUID().uuidString.lowercased()
        var stored: Set<Int> = []
        var rejected: [Int: MailPDFFetcher.Rejection] = [:]
        var pages: [Int: MailTriagePreview.Page] = [:]
        for (i, a) in content.attachments.enumerated() where a.looksLikePDF && !a.isInline {
            switch await fetcher.save(a, index: i, messageID: messageID, maxBytes: attachmentCap, truncated: truncated) {
            case .success(let saved):
                stored.insert(i)
                if let page = await fetcher.firstPage(relativePath: saved.relativePath) {
                    pages[i] = MailTriagePreview.Page(title: page.title, ids: page.ids, text: page.text)
                }
            case .failure(let why):
                rejected[i] = why
            }
        }

        let r = MailTriagePreview.run(content: content, rule: rule, settings: settings, engineSettings: es,
                                      categories: categories, frequentTags: tags, now: now, calendar: calendar,
                                      stored: stored, rejected: rejected, pages: pages)
        if args.has("--stdin-only") {
            FileHandle.standardOutput.write(r.stdin)
            return 0
        }
        let h = content.header
        CLIRunner.line(["from": h.fromAddress, "fromName": h.fromName, "subject": String(h.subject.prefix(200)),
                        "receivedAt": ISO8601DateFormatter().string(from: h.receivedAt),
                        "messageID": h.internetMessageID, "auth": MIMEParser.authState(h.authResults ?? content.headers["authentication-results"]).rawValue,
                        "attachments": content.attachments.count, "bytes": data.count, "truncated": truncated])
        CLIRunner.line(["sender": rule.map { "\($0.label.isEmpty ? $0.pattern : $0.label) (\($0.pattern))" } ?? "not on the sender list",
                        "kind": r.kind.rawValue, "aiPolicy": rule?.aiPolicy.rawValue,
                        "accountSync": rule == nil ? "skipped (not allowlisted: body never fetched)" : "captured",
                        "drop": "captured (explicit intent)"])
        CLIRunner.line(["extraction": ["chars": r.extraction.bodyText.count, "candidates": r.extraction.candidates.count,
                                       "forwarded": r.extraction.isForwarded] as [String: Any],
                        "snippet": String(r.extraction.snippet.prefix(160))])
        for item in r.items {
            CLIRunner.line(["cand": item.cand, "origin": item.origin.rawValue, "title": item.title.map { String($0.prefix(90)) },
                            "doi": item.ids.doi, "arxiv": item.ids.arxivID, "pii": item.ids.pii, "host": item.host,
                            "url": item.url.map { String($0.prefix(160)) }, "pdf": item.pdfState.rawValue,
                            "relevance": item.relevance?.rawValue, "note": item.downloadError])
        }
        let t = r.heuristic
        CLIRunner.line(["heuristic": ["kind": t.requestKind.rawValue, "request": t.hasReadingRequest,
                                      "priority": String(describing: t.priority),
                                      "confidence": (t.confidence * 100).rounded() / 100] as [String: Any],
                        "summary": String(t.summary.prefix(300)), "due": t.dueDate?.iso, "dueEvidence": t.dueEvidence,
                        "dueConfidence": t.dueConfidence.map { ($0 * 100).rounded() / 100 }])
        CLIRunner.line(["card": ["synced": r.syncedState.rawValue, "dropped": r.droppedState.rawValue] as [String: Any],
                        "triage": ["synced": rule == nil ? "n/a" : r.syncedTriage.rawValue, "dropped": r.droppedTriage.rawValue] as [String: Any],
                        "aiMode": settings.aiMode.rawValue])
        CLIRunner.line(["wouldSendTo": r.provider.rawValue, "model": r.model, "stdinBytes": r.stdin.count,
                        "route": r.route.heldText(.en) ?? "runs when the triage lane gets to it",
                        "note": "no spawn, no network; rows before metadata lookups"])
        print("----- BEGIN TRIAGE STDIN (\(r.stdin.count) bytes) -----")
        print(r.stdinText, terminator: r.stdinText.hasSuffix("\n") ? "" : "\n")
        print("----- END TRIAGE STDIN -----")
        return 0
    }

    // MARK: --mail-sync

    /// One pass over the configured accounts into `--root` (isolated library). Real servers:
    /// never run by tests except against a `--defaults-suite` with local folder accounts.
    static func sync(_ args: CLIArgs) async -> Int32 {
        let usage = "--mail-sync --root DIR (--defaults-suite NAME | --real-accounts) [--lang en|zh] (one sync pass into an isolated library)"
        guard let root = args.url("--root") else { return CLIRunner.fail(usage) }
        // The app's own Settings ▸ Mail and keychain only on request: this command must not act
        // on the user's real mail sources by accident.
        guard args.value("--defaults-suite") != nil || args.has("--real-accounts") else {
            return CLIRunner.fail("--mail-sync reads the app's own mail accounts only with --real-accounts "
                                  + "(or use --defaults-suite NAME for scratch accounts). " + usage)
        }
        var (settings, suite) = mailSettings(args)
        // Read-only towards the real sources: processed .eml files stay where they are.
        settings.accounts = MailSourceFactory.isolated(settings.accounts)
        guard !settings.accounts.isEmpty else {
            return CLIRunner.fail("no mail accounts configured (Settings ▸ Mail ▸ Accounts\(suite == nil ? "" : " in --defaults-suite"))")
        }
        if !settings.enabled {
            FileHandle.standardError.write(Data("note: mail is off in Settings ▸ Mail — syncing the enabled accounts once anyway\n".utf8))
            settings.enabled = true
        }
        // Zero quota: AI triage stays held (agent mode off); both provider slots are mocks.
        var es = EngineSettings.load(from: suite ?? .standard)
        es.agentMode = .off
        es.autoReadNewPapers = false
        if let lang = args.value("--lang").flatMap(UILang.init(rawValue:)) { es.lang = lang }
        let engineSettings = es
        let mail = settings
        // A scratch suite never reaches the login keychain; the app's own settings use its items.
        let secrets: any MailSecretStore = suite == nil ? KeychainMailSecretStore() : InMemoryMailSecretStore()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let deps = Engine.Dependencies(
                loadSettings: { engineSettings },
                fetcher: args.value("--network") == "off" ? nil : URLSessionHTTPFetcher(),
                claude: MockAgentProvider(behavior: .notLoggedIn), codex: MockAgentProvider(behavior: .notLoggedIn),
                mock: MockAgentProvider(), sidecarDelay: .milliseconds(50), cliFacts: .inMemory(),
                loadMailSettings: { mail }, mailSecrets: secrets)
            let engine = try await Engine.open(paths: AppPaths.rooted(at: root), deps: deps)
            await engine.start()                    // agent queue (mode off: triage held, count refunded)
            let t0 = Date()
            await engine.mail.syncNow()
            await engine.mail.waitUntilIdle()
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            var ok = true
            for info in await engine.mail.accountSyncInfo(lang: engineSettings.lang) {
                let (state, text) = Self.describe(info.status)
                if info.enabled, state != "ready" { ok = false }
                CLIRunner.line(["account": info.displayName, "kind": info.kind.rawValue, "enabled": info.enabled,
                                "status": info.enabled ? state : "paused", "detail": text,
                                "captured": info.totalCaptured, "failures": info.consecutiveFailures,
                                "skipped": info.skipped])
            }
            let snap = try await engine.mailSnapshot()
            CLIRunner.line(["pending": snap.counts.pending, "requests": snap.counts.requests,
                            "awaitingConsent": snap.counts.awaitingConsent, "needsPDF": snap.counts.needsPDF,
                            "cards": MailInboxFilter.allCases.reduce(0) { $0 + snap.cards($1).count }, "ms": ms])
            await engine.shutdown()
            return ok ? 0 : 1
        } catch {
            return CLIRunner.fail(String(describing: error))
        }
    }

    /// Status → ("ready" | "needs_setup" | "auth_failed" | "unavailable" | "not_checked", text).
    static func describe(_ s: MailSourceStatus?) -> (String, String?) {
        switch s {
        case .ready(let d)?: return ("ready", d)
        case .needsSetup(let m)?: return ("needs_setup", m)
        case .authFailed(let m)?: return ("auth_failed", m)
        case .unavailable(let m)?: return ("unavailable", m)
        case nil: return ("not_checked", nil)
        }
    }
}
