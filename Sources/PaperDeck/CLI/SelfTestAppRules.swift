import Foundation
import PaperDeckCore
import PaperDeckConfig

/// `--selftest app-rules [--lang en|zh]`: app-side rules of the review fixes that the Core test
/// target can't reach (it doesn't link the app):
/// - launch (integrity-4): which `Engine.open` failures may offer another library folder — real
///   scratch libraries (a newer database, a failed pre-migration backup, an unusable library folder)
///   and synthetic errors — plus the alert texts and what 「显示备份」 reveals;
/// - account edit (safety-8): when 「测试并保存」 may sign in with the saved app password;
/// - Settings ▸ Mail → engine (runtime-3): plain edits notify without un-parking (debounced),
///   「测试并保存」 / account saves notify at once and un-park;
/// - the triage preview's mailing-list test and confidentiality guard (what may auto-triage under
///   an alert / always rule);
/// - round 3 (`SelfTestAppRules3.swift`): the launch alert's Retry and app folders, the inspector's
///   email text, Settings ▸ Mail ▸ Accounts language, targeted un-park;
/// - round 4 (`SelfTestAppRules4.swift`): the skipped-emails notice (Settings rows, inbox) with
///   「立即同步」, sizes in the UI language, one launch-alert assembly for the launch and the renders;
/// - portability fixes 2 (`SelfTestAppRulesPF2.swift`): the inspector draws the whole consent box;
/// - ui-runtime fixes (`SelfTestAppRulesUI.swift`): the mismatch alert's choices, versioned card
///   thumbnails, Help's mail facts, the Paper menu, the quit flush of pending notes, minimized
///   windows, the menu bar per language.
/// Offline: scratch folders and a scratch defaults file under $TMPDIR (removed afterwards), fake
/// mail sources, no keychain, no engine left open, nothing posted.
enum SelfTestAppRules {
    static func run(_ args: CLIArgs) async -> Int32 {
        let lang = UILang(rawValue: args.value("--lang") ?? "en") ?? .en
        let previous = LangStore.shared.lang
        LangStore.shared.lang = lang
        defer { LangStore.shared.lang = previous }

        let checker = Checker()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-selftest-app-rules-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        await launchFailures(scratch: scratch, checker)
        accountEdits(checker)
        await mailNotifications(scratch: scratch, checker)
        previewFacts(checker)
        consentPresentation(checker)
        await runRound3(scratch: scratch, checker)
        await runRound4(scratch: scratch, checker)
        await runPF2(scratch: scratch, checker)
        await runDocs(scratch: scratch, checker)
        await runUIRuntime(scratch: scratch, checker)

        print(checker.ok ? "SELFTEST PASS" : "SELFTEST FAIL")
        return checker.ok ? 0 : 1
    }

    /// One JSON line per check; `ok` turns false on the first failure.
    final class Checker {
        private(set) var ok = true
        func check(_ name: String, _ pass: Bool, _ extra: [String: Any?] = [:]) {
            var line: [String: Any?] = ["check": name, "ok": pass]
            line.merge(extra) { a, _ in a }
            CLIRunner.line(line)
            if !pass { ok = false }
        }
    }

    // MARK: 「让 AI 分析」 consent (portability F1)

    /// The inbox list keeps 「让 AI 分析」 to one line on every card but the selected one; the
    /// selected card and the inspector show the whole note, and the note carries the configured
    /// institution's guidance (the legacy preset's own wording for an existing install).
    static func consentPresentation(_ c: Checker) {
        c.check("consent: only unselected list cards are compact; the selected card shows the full note",
                MailCardView.compactConsent(selected: false) && !MailCardView.compactConsent(selected: true))
        guard let org = OrganizationPresets.preset(id: LegacyInstall.organizationID), let short = org.shortName else {
            c.check("consent: the legacy institution preset exists", false)
            return
        }
        for lang in UILang.allCases {
            let note = OrgStrings.consentNote(provider: "Claude", org: org, lang: lang)
            c.check("consent (\(lang.rawValue)): the full note carries the institution's guidance",
                    note.contains(short) && note.contains("Claude"), ["note": note])
        }
    }

    // MARK: Launch (integrity-4)

    static func deps() -> Engine.Dependencies {
        let es = EngineSettings(plan: PlanSettings(), lang: .en, agentMode: .off, autoReadNewPapers: false,
                                metadataLookup: false)
        return Engine.Dependencies(loadSettings: { es }, fetcher: nil, claude: MockAgentProvider(behavior: .notLoggedIn),
                                   codex: MockAgentProvider(behavior: .notLoggedIn), mock: MockAgentProvider(),
                                   sidecarDelay: .milliseconds(10), cliFacts: .inMemory(),
                                   loadMailSettings: { MailSettings() }, mailSecrets: InMemoryMailSecretStore())
    }

    /// What the launch would show for this library: nil when it opened.
    private static func failure(_ paths: AppPaths) async -> LibraryOpenFailure? {
        do {
            let engine = try await Engine.open(paths: paths, deps: deps())
            await engine.shutdown()
            await engine.db.close()
            return nil
        } catch {
            return LibraryOpenFailure.classify(error, paths: paths)
        }
    }

    private static func launchFailures(scratch: URL, _ c: Checker) async {
        let fm = FileManager.default
        let latest = Migrations.latestVersion

        // 1. A database upgraded by a newer PaperDeck: Quit / Show Backups, never another folder.
        let newer = AppPaths.rooted(at: scratch.appendingPathComponent("newer", isDirectory: true))
        var result: LibraryOpenFailure?
        do {
            try fm.createDirectory(at: newer.library.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LibraryPaths.ensureLayout(paths: newer)
            let raw = try SQLiteConnection(path: newer.database.path)
            try raw.exec("CREATE TABLE future_thing(x TEXT); PRAGMA user_version = \(latest + 1)")
            raw.close()
            result = await failure(newer)
        } catch {
            c.check("launch: newer database fixture", false, ["error": String(describing: error)])
        }
        c.check("launch: newer database → newer-version alert",
              result == .newerVersion(found: latest + 1, supported: latest) && result?.offersAnotherLibrary == false,
              ["got": result?.logName])

        // 2. The pre-migration backup can't be written (as with a full disk): database alert.
        let backup = AppPaths.rooted(at: scratch.appendingPathComponent("backup", isDirectory: true))
        result = nil
        do {
            try fm.createDirectory(at: backup.library.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LibraryPaths.ensureLayout(paths: backup)
            let raw = try SQLiteConnection(path: backup.database.path)
            try Migrations.prepare(raw, backupsDir: nil, targetVersion: 1)
            raw.close()
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: backup.backups.path)
            result = await failure(backup)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: backup.backups.path)
        } catch {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: backup.backups.path)
            c.check("launch: backup failure fixture", false, ["error": String(describing: error)])
        }
        c.check("launch: failed pre-migration backup → database alert",
              result == .database(diskFull: false) && result?.offersAnotherLibrary == false, ["got": result?.logName])

        // 3. The library folder is unusable: the only case that may offer ~/Papers.
        let folder = AppPaths.rooted(at: scratch.appendingPathComponent("folder", isDirectory: true))
        result = nil
        do {
            try fm.createDirectory(at: folder.library.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not a folder".utf8).write(to: folder.library)
            result = await failure(folder)
        } catch {
            c.check("launch: folder fixture", false, ["error": String(describing: error)])
        }
        c.check("launch: unusable library folder → folder alert",
              result == .libraryFolder && result?.offersAnotherLibrary == true, ["got": result?.logName])

        // 4. Synthetic errors.
        let cases: [(String, any Error, LibraryOpenFailure)] = [
            ("sqlite full", SQLiteError(code: 13, message: "database or disk is full"), .database(diskFull: true)),
            ("sqlite cantopen", SQLiteError(code: 14, message: "unable to open database file"), .database(diskFull: false)),
            ("cocoa out of space", CocoaError(.fileWriteOutOfSpace), .database(diskFull: true)),
            ("posix enospc", NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)), .database(diskFull: true)),
            ("corrupt after rebuild", DatabaseError.corrupt("x"), .database(diskFull: false)),
            ("folder permission", FileOpsError.permissionDenied, .libraryFolder),
            ("folder missing", FileOpsError.libraryUnavailable, .libraryFolder),
            ("layout disk full", FileOpsError.diskFull, .database(diskFull: true)),
            ("newer", DatabaseError.newerSchema(found: 9, supported: 2), .newerVersion(found: 9, supported: 2)),
        ]
        for (name, error, expected) in cases {
            let got = LibraryOpenFailure.classify(error)
            c.check("launch: classify \(name)", got == expected && got.offersAnotherLibrary == (expected == .libraryFolder),
                  ["got": got.logName])
        }

        // 5. Texts: both languages, never the ~/Papers offer, the Backups folder named.
        for failure in [LibraryOpenFailure.newerVersion(found: 3, supported: 2), .database(diskFull: true), .database(diskFull: false)] {
            for l in [UILang.en, .zh] {
                let saved = LangStore.shared.lang
                LangStore.shared.lang = l
                let title = L.databaseFailureTitle(failure), body = L.databaseFailureBody(failure)
                LangStore.shared.lang = saved
                let pass = !title.isEmpty && body.contains("Backups") && !body.contains("~/Papers")
                    && (l == .zh) == body.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
                    && (failure == .database(diskFull: true)) == (body.contains("disk is full") || body.contains("磁盘已满"))
                c.check("launch: alert text \(failure.logName) \(l.rawValue)", pass, ["title": title])
            }
        }

        // 6. 「显示备份」: the newest pre-migration copy, else the folder, else its parent.
        let backups = scratch.appendingPathComponent("Backups", isDirectory: true)
        try? fm.createDirectory(at: backups.appendingPathComponent("corrupt-20261002-000000"), withIntermediateDirectories: true)
        for name in ["pre-migration-v1-20260930-101500.sqlite", "pre-migration-v1-20261001-090000.sqlite",
                     "pre-migration-v1-20261001-090000_2.sqlite", "notes.txt"] {
            fm.createFile(atPath: backups.appendingPathComponent(name).path, contents: Data())
        }
        c.check("launch: reveal newest backup",
              LibraryOpenFailure.revealTarget(backups: backups).lastPathComponent == "pre-migration-v1-20261001-090000_2.sqlite")
        let empty = scratch.appendingPathComponent("EmptyBackups", isDirectory: true)
        try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
        c.check("launch: reveal empty backups folder", LibraryOpenFailure.revealTarget(backups: empty).path == empty.path)
        let missing = scratch.appendingPathComponent("Support/Backups", isDirectory: true)
        c.check("launch: reveal parent when missing",
              LibraryOpenFailure.revealTarget(backups: missing).path == missing.deletingLastPathComponent().path)
    }

    // MARK: Account edit (safety-8)

    private static func accountEdits(_ c: Checker) {
        let saved = MailAccount(id: "acct-gmail", kind: .imap, displayName: "Gmail — me@gmail.com", imapPreset: .gmail,
                                host: "imap.gmail.com", port: 993, username: "me@gmail.com", mailbox: "PaperDeck")
        func reuse(_ edit: (inout MailAccount) -> Void) -> Bool {
            var a = saved
            edit(&a)
            return MailAccountEditRules.mayReuseSavedPassword(original: saved, edited: a)
        }
        c.check("edit: unchanged keeps the saved password", reuse { _ in })
        c.check("edit: name / mailbox / lookback keep it", reuse { $0.displayName = "Mine"; $0.mailbox = "INBOX"; $0.lookbackDays = 30 })
        c.check("edit: same host spelled differently keeps it", reuse { $0.host = "  IMAP.Gmail.com. " })
        c.check("edit: preset host left empty keeps it", reuse { $0.host = nil })
        c.check("edit: address case keeps it", reuse { $0.username = " Me@Gmail.com" })
        c.check("edit: another host needs the password", !reuse { $0.host = "imap.gmai1.com" })
        c.check("edit: another port needs the password", !reuse { $0.port = 143 })
        c.check("edit: another address needs the password", !reuse { $0.username = "someone.else@gmail.com" })
        c.check("edit: a new account never reuses one",
              !MailAccountEditRules.mayReuseSavedPassword(original: nil, edited: saved))
        var other = saved
        other.id = "acct-other"
        c.check("edit: another account never reuses one",
              !MailAccountEditRules.mayReuseSavedPassword(original: saved, edited: other))
    }

    // MARK: Triage preview (the capture's auto-triage facts)

    private static func previewFacts(_ c: Checker) {
        // The preview uses the capture's own rule; these cases hold whatever extra automated
        // headers (Precedence, Auto-Submitted) that rule also counts.
        let cases: [([String: String], Bool?)] = [
            ([:], false),
            (["list-id": "<alerts.biorxiv.org>"], true),
            (["list-unsubscribe": "<mailto:unsubscribe@example.org>"], true),
            (["precedence": " Bulk "], nil),
            (["precedence": "first-class"], false),
            (["auto-submitted": "auto-generated"], nil),
            (["auto-submitted": "No"], false),
            (["auto-submitted": "no (comment)"], false),
            (["list-id": "  "], false),
        ]
        for (headers, expected) in cases {
            let got = MailTriagePreview.isBulk(headers)
            c.check("preview: bulk \(headers.keys.sorted().joined(separator: ","))=\(expected.map { "\($0)" } ?? "capture")",
                    got == MailSyncActor.isBulk(headers) && (expected == nil || got == expected))
        }

        // The confidentiality guard (r3-1): a mailing-list alert under an `always` rule is
        // queued, but a reviewer invitation from the same list waits for consent — in the
        // preview exactly as the capture decides it (`MailHeuristics.isConfidential`).
        let rule = SenderRule(id: "selftest-alert", pattern: "@journals.example.org", label: "Journal", kind: .alert)
        let settings = MailSettings(senders: [rule])
        let es = EngineSettings(lang: .en)
        func preview(_ subject: String) -> MailTriagePreview.Result? {
            let eml = """
                From: Alerts <alerts@journals.example.org>\r
                To: me@example.edu\r
                Subject: \(subject)\r
                Date: Wed, 30 Sep 2026 09:00:00 -0500\r
                Message-ID: <selftest-\(subject.count)@journals.example.org>\r
                List-Id: <alerts.journals.example.org>\r
                MIME-Version: 1.0\r
                Content-Type: text/plain; charset=utf-8\r
                \r
                New paper: https://www.biorxiv.org/content/10.1101/2026.08.12.607788v1\r

                """
            guard let content = try? MIMEParser.parse(Data(eml.utf8), maxAttachmentBytes: 1 << 20) else { return nil }
            return MailTriagePreview.run(content: content, rule: rule, settings: settings, engineSettings: es,
                                         categories: [], frequentTags: [], now: Date(), calendar: .current)
        }
        let plain = preview("New results for spatial transcriptomics")
        let invitation = preview("Invitation to review manuscript NEURO-D-26-01234")
        c.check("preview: plain list alert under always → queued",
                plain?.syncedTriage == .queued && plain?.droppedTriage == .queued,
                ["synced": plain.map { "\($0.syncedTriage)" } ?? "unparsed"])
        c.check("preview: confidential list alert → awaiting consent",
                invitation?.syncedTriage == .awaitingConsent && invitation?.droppedTriage == .awaitingConsent,
                ["synced": invitation.map { "\($0.syncedTriage)" } ?? "unparsed"])
    }

    // MARK: Settings ▸ Mail → engine (runtime-3)

    private static func mailNotifications(scratch: URL, _ c: Checker) async {
        // A path-named suite: the plist lives in the scratch folder (never the app's own domain).
        let suite = scratch.appendingPathComponent("defaults/defaults").path
        try? FileManager.default.createDirectory(atPath: (suite as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        guard let defaults = UserDefaults(suiteName: suite) else {
            c.check("notify: scratch defaults", false, [:])
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = LangStore.shared.lang, savedProvider = LangStore.shared.provider
        defer { LangStore.shared.lang = saved; LangStore.shared.provider = savedProvider }
        let store = SettingsStore(defaults: defaults)
        var calls: [MailSettingsNotice] = []
        store.onMailSettingsChange = { calls.append($0) }
        func settle() async { try? await Task.sleep(for: .milliseconds(700)) }

        // Typing in Research interests, moving a slider: one debounced call, no un-park.
        store.mailCriteria.researchInterests = "s"
        store.mailCriteria.researchInterests = "spatial"
        store.mailTriageDailyMax = 12
        await settle()
        c.check("notify: edits notify once without un-parking", calls == [.edit], ["calls": "\(calls)"])

        // 「测试并保存」: at once, un-parking that account only, replacing a pending edit notification.
        calls.removeAll()
        store.upsertMailAccount(MailAccount(id: "acct", kind: .folder, displayName: "Folder", folderPath: "/tmp/x"))
        store.notifyMailNow(accountID: "acct")
        let retry = MailSettingsNotice(unpark: true, accountIDs: ["acct"])
        c.check("notify: test & save un-parks that account at once", calls == [retry], ["calls": "\(calls)"])
        await settle()
        c.check("notify: no stray call after test & save", calls == [retry], ["calls": "\(calls)"])

        // A toggle on its own: debounced, no un-park.
        calls.removeAll()
        store.mailPrefillNotes.toggle()
        await settle()
        c.check("notify: toggle does not un-park", calls == [.edit], ["calls": "\(calls)"])
    }
}
