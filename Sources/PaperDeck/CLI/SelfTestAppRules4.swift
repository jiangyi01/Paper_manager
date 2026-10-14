import AppKit
import SwiftUI
import Vision
import PaperDeckCore

/// Round-4 checks of `--selftest app-rules`:
/// - skipped (a4-1): allowlisted emails skipped because the retry list was full are a notice of
///   their own — Settings ▸ Mail ▸ Accounts rows (the engine's `skippedHint`, UI language) and the
///   inbox header (one line, the sentence its tooltip) — with 「立即同步」, hidden until the count
///   grows; the status line no longer repeats the sentence and the inbox's status pill counts the
///   account. Pure rules, then a real engine (fake mail source, no network) with a stored count;
/// - bytes (a4-2): every size the app shows is worded in the UI language (no "Zero KB" in zh);
/// - alert (a4-3): the launch alert is assembled once (`LaunchAlert.makeAlert`) for the real
///   launch (`AppDelegate.launchAlert`) and the renders (`PreviewRenderer.launchAlert`).
extension SelfTestAppRules {
    static func runRound4(scratch: URL, _ c: Checker) async {
        skippedRules(c)
        await skippedEngine(scratch: scratch, c)
        byteSizes(c)
        await footerDrawn(scratch: scratch, c)
        launchAlertAssembly(c)
    }

    private static func cjk(_ s: String) -> Bool { s.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF } }

    /// Runs `body` with the UI language set to `lang`.
    private static func inLang<T>(_ lang: UILang, _ body: () -> T) -> T {
        let saved = LangStore.shared.lang
        LangStore.shared.lang = lang
        defer { LangStore.shared.lang = saved }
        return body()
    }

    // MARK: Skipped emails (a4-1)

    private static func skippedRules(_ c: Checker) {
        let lang = LangStore.shared.lang
        let hint = MailSyncText.skippedByCap(3, lookbackDays: 14, lang)
        let account = fakeAccount("acct-k")
        let ready = MailAccountSyncInfo(id: "acct-k", displayName: "Gmail", kind: .imap, enabled: true,
                                        status: .unavailable("Signed in as k@example.org · " + hint),
                                        lastSuccessAt: Date(), skipped: 3, skippedHint: hint)
        // 1. The notice and its action.
        let notices = MailAccountNotice.notices(ready, active: true)
        c.check("skipped: an account with skipped emails has its own notice",
                notices == [.skipped(count: 3, hint: hint)] && notices.first?.text == hint && notices.first?.action == .syncNow,
                ["notices": notices.map(\.kind)])
        c.check("skipped: no notice while the account doesn't sync (paused / mail off)",
                MailAccountNotice.notices(ready, active: false).isEmpty)
        var none = ready
        none.skipped = 0
        none.skippedHint = nil
        c.check("skipped: no notice without skipped emails", MailAccountNotice.notices(none, active: true).isEmpty)
        var both = ready
        both.kind = .folder
        both.notEmailFiles = 2
        let pair = MailAccountNotice.notices(both, active: true)
        c.check("skipped: not-email notice first (guide), then skipped (Sync Now)",
                pair.map(\.kind) == ["not-email", "skipped"] && pair.map(\.action) == [.openGuide, .syncNow])

        // 2. The status line leaves the sentence to the notice.
        let shown = MailAccountNotice.shownStatus(ready, active: true)
        c.check("skipped: the status no longer repeats the sentence", shown == .ready(detail: "Signed in as k@example.org"),
                ["shown": shown.map { "\($0)" }])
        let row = MailStatusText.line(account: account, info: ready, masterOn: true)
        c.check("skipped: Settings row status is ready without the sentence",
                row.kind == .ok && row.text == "Signed in as k@example.org" && !row.text.contains(hint))
        var undl = ready
        undl.undownloadable = 2
        let undlText = MailSyncText.undownloadable(2, lang)
        undl.status = .unavailable("Signed in as k@example.org · " + undlText + " · " + hint)
        c.check("skipped: undownloadable emails keep the warning",
                MailAccountNotice.shownStatus(undl, active: true) == .unavailable("Signed in as k@example.org · " + undlText))
        c.check("skipped: without the notice the status is shown as it is",
                MailAccountNotice.shownStatus(ready, active: false) == ready.status)
        var other = ready
        other.status = .authFailed("rejected")
        c.check("skipped: other statuses untouched", MailAccountNotice.shownStatus(other, active: true) == .authFailed("rejected"))

        // 3. The inbox: the status pill counts the account; its notices (one shown at a time) come
        // most serious first, for syncing accounts only; hidden ones come back when the count grows.
        let pill = MailNoticePolicy.pill([ready], enabled: true)
        c.check("skipped: the inbox's status pill counts the account", pill == .attention(accounts: 1, critical: false),
                ["pill": "\(pill)"])
        var paused = ready
        paused.id = "acct-p"
        paused.enabled = false
        both.id = "acct-b"
        let entries = MailNoticePolicy.notices([ready, paused, both])
        c.check("skipped: inbox notices for syncing accounts only, most serious first",
                entries.map(\.id) == ["acct-b/notEmail", "acct-k/skipped", "acct-b/skipped"], ["ids": entries.map(\.id)])
        var hidden = ready
        hidden.skippedDismissed = 3
        var grown = hidden
        grown.skipped = 4
        c.check("skipped: a hidden notice stays hidden until more emails are skipped",
                MailNoticePolicy.notices([hidden]).isEmpty && MailAccountNotice.notices(hidden, active: true).isEmpty
                    && MailNoticePolicy.pill([hidden], enabled: true) == .synced(hidden.lastSuccessAt)
                    && MailNoticePolicy.notices([grown]).map(\.kind) == [.skipped])

        // 4. Rows read in another language never show the old sentence.
        let otherLang: UILang = lang == .zh ? .en : .zh
        var stale = ready
        stale.skippedHint = MailSyncText.skippedByCap(3, lookbackDays: 14, otherLang)
        let current = MailStatusText.current([stale], readIn: otherLang, lang: lang)
        c.check("skipped: a row read in another language shows no skipped sentence",
                current.first?.skippedHint == nil && MailAccountNotice.notices(current.first, active: true).isEmpty)
    }

    private static func skippedEngine(scratch: URL, _ c: Checker) async {
        let root = scratch.appendingPathComponent("skipped", isDirectory: true)
        let lang = Shared(UILang.en)
        let account = fakeAccount("acct-s")
        // Listing fails: Sync Now's re-list doesn't get through, so the count stays.
        let source = FakeSource("acct-s", status: .ready(detail: "Signed in"), failListing: true)
        let settings = Shared(MailSettings(enabled: false, accounts: [account], syncMinutes: 0))
        guard let engine = try? await skippedEngine(root, lang: lang, mail: settings, source: source) else {
            c.check("skipped: engine fixture", false)
            return
        }
        do {
            // The count the pipeline stored (kv `<id>.skipped`) is read at the next pass.
            try await engine.db.setMailCursor(accountID: "acct-s.skipped", MailCursor("4"))
            await engine.mail.syncNow()                               // mail off: counts seeded, nothing synced
            for l in [UILang.en, .zh] {
                let row = await MailStatusText.read(engine.mail, lang: l).first
                let expected = MailSyncText.skippedByCap(4, lookbackDays: account.lookbackDays, l)
                let notices = MailAccountNotice.notices(row, active: true)
                c.check("skipped: Settings row notice is the engine's hint (\(l.rawValue))",
                        row?.skipped == 4 && row?.skippedHint == expected && notices == [.skipped(count: 4, hint: expected)]
                            && cjk(notices.first?.text ?? "") == (l == .zh),
                        ["skipped": row?.skipped])
            }
            // Mail on, the account syncing: the inbox snapshot carries the hint in the UI language.
            settings.set(MailSettings(enabled: true, accounts: [account], syncMinutes: 0))
            lang.set(.zh)
            await engine.mail.settingsDidChange()
            await engine.mail.syncNow()
            let snap = try await engine.mailSnapshot()
            let entries = MailNoticePolicy.notices(snap.accounts)
            let zh = MailSyncText.skippedByCap(4, lookbackDays: account.lookbackDays, .zh)
            c.check("skipped: inbox notice from the snapshot, in the UI language",
                    entries.count == 1 && entries.first?.kind == .skipped && entries.first?.count == 4 && entries.first?.text == zh,
                    ["entries": entries.map(\.id)])
            await close(engine)
        } catch {
            c.check("skipped: engine fixture", false, ["error": String(describing: type(of: error))])
            await close(engine)
            return
        }

        // A pass that gets through but doesn't re-list (the timer's): the status the pipeline
        // composes (`… · <hint>`) is shown without the sentence the notice says.
        let ui = LangStore.shared.lang
        let root2 = scratch.appendingPathComponent("skipped-timer", isDirectory: true)
        let ok = FakeSource("acct-t", status: .ready(detail: "Signed in"))
        let timed = fakeAccount("acct-t")
        let settings2 = Shared(MailSettings(enabled: true, accounts: [timed], syncMinutes: 60))
        guard let engine2 = try? await skippedEngine(root2, lang: Shared(ui), mail: settings2, source: ok) else {
            c.check("skipped: timer engine fixture", false)
            return
        }
        do {
            try await engine2.db.setMailCursor(accountID: "acct-t.skipped", MailCursor("2"))
            await engine2.mail.start()                                // first pass: due, not forced
            let synced = await eventually(5) { await MailStatusText.read(engine2.mail, lang: ui).first?.lastSuccessAt != nil }
            let row = await MailStatusText.read(engine2.mail, lang: ui).first
            let hint = MailSyncText.skippedByCap(2, lookbackDays: timed.lookbackDays, ui)
            let shown = MailAccountNotice.shownStatus(row, active: true)
            var suffixed = false
            if case .unavailable(let text)? = row?.status { suffixed = text.hasSuffix(" · " + hint) }
            c.check("skipped: the pipeline's status carries the sentence (fixture)",
                    synced && row?.skippedHint == hint && suffixed, ["synced": synced])
            c.check("skipped: shown status without the suffix, ready again",
                    shown == .ready(detail: "Signed in"), ["shown": shown.map { "\($0)" }])
            await skippedViews(scratch: scratch, engine: engine2, account: timed, lang: ui, c)
        } catch {
            c.check("skipped: timer engine fixture", false, ["error": String(describing: type(of: error))])
        }
        await close(engine2)
    }

    /// The views themselves, drawn offscreen and read back (`drawnText`): the inbox header shows the
    /// skipped notice as one line (the sentence is its tooltip) with one 「立即同步」; the Settings
    /// account row says the sentence once — in the notice, not again in the status line — with
    /// 「立即同步」 beside it.
    private static func skippedViews(scratch: URL, engine: Engine, account: MailAccount, lang: UILang, _ c: Checker) async {
        let suite = scratch.appendingPathComponent("defaults-skipped/defaults").path
        try? FileManager.default.createDirectory(atPath: (suite as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let defaults = UserDefaults(suiteName: suite) else {
            c.check("skipped: scratch defaults", false)
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let savedLang = LangStore.shared.lang, savedProvider = LangStore.shared.provider
        defer { LangStore.shared.lang = savedLang; LangStore.shared.provider = savedProvider }
        let store = SettingsStore(defaults: defaults)
        store.language = lang
        store.mailAccounts = [account]
        store.mailEnabled = true
        let state = AppState(engine: engine, settings: store)
        // Recognized text keeps the words, not always the spaces (「4封」, "14天"): compared squeezed.
        func squeeze(_ s: String) -> String { s.filter { !$0.isWhitespace } }
        func occurrences(_ key: String, _ lines: [String]) -> Int { squeeze(lines.joined()).components(separatedBy: key).count - 1 }
        let key = lang == .zh ? "重试队列已满" : "retrylistwasfull"
        // A button's line: its title, maybe after its icon read as a letter (「↻ 立即同步」 → "C 立即同步").
        func buttons(_ title: String, _ lines: [String]) -> Int {
            let t = squeeze(title)
            return lines.filter { squeeze($0).hasSuffix(t) && squeeze($0).count <= t.count + 2 }.count
        }
        guard let snap = try? await engine.mailSnapshot() else {
            c.check("skipped: snapshot", false)
            return
        }
        let inbox = await drawnText(MailInboxHeader(state: state, snap: snap), width: 820)
        let line = lang == .zh ? "封邮件被跳过" : "wereskipped"
        c.check("skipped: inbox header shows one notice line (no sentence), with Sync Now",
                occurrences(key, inbox) == 0 && occurrences(line, inbox) == 1 && buttons(L.Mail.syncNow, inbox) == 1,
                ["sentences": occurrences(key, inbox), "lines": occurrences(line, inbox), "buttons": buttons(L.Mail.syncNow, inbox)])
        let rows = await MailStatusText.read(engine.mail, lang: lang)
        let settings = await drawnText(Form { MailAccountsSection(state: state, infos: rows, sheet: .constant(nil)) }
                                        .formStyle(.grouped), width: 640)
        c.check("skipped: Settings row shows the sentence once, with Sync Now",
                occurrences(key, settings) == 1 && buttons(L.MailPref.syncNow, settings) == 1,
                ["sentences": occurrences(key, settings), "buttons": buttons(L.MailPref.syncNow, settings)])
    }

    /// The lines of text a view draws: rendered in an invisible borderless window (as `--render`
    /// does) and read back with on-device text recognition (Vision; nothing leaves the Mac).
    static func drawnText<V: View>(_ view: V, width: CGFloat) async -> [String] {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.frame(width: width).padding(8).background(Color.white))
        host.appearance = NSAppearance(named: .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: max(size.width, width), height: max(size.height, 60))),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(900))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return [] }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let image = rep.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return [] }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// An engine whose mail settings the check changes, with one fake source (no network).
    private static func skippedEngine(_ root: URL, lang: Shared<UILang>, mail: Shared<MailSettings>,
                                      source: FakeSource) async throws -> Engine {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let deps = Engine.Dependencies(
            loadSettings: {
                EngineSettings(plan: PlanSettings(), lang: lang.get, agentMode: .off, autoReadNewPapers: false,
                               metadataLookup: false)
            },
            fetcher: nil, claude: MockAgentProvider(behavior: .notLoggedIn), codex: MockAgentProvider(behavior: .notLoggedIn),
            mock: MockAgentProvider(), sidecarDelay: .milliseconds(10), cliFacts: .inMemory(),
            loadMailSettings: { mail.get }, mailSecrets: InMemoryMailSecretStore(),
            mailSources: { account in account.id == source.accountID ? source : FakeSource(account.id, status: .needsSetup("none")) })
        return try await Engine.open(paths: AppPaths.rooted(at: root), deps: deps)
    }

    // MARK: Sizes (a4-2)

    private static func byteSizes(_ c: Checker) {
        for l in [UILang.en, .zh] {
            let (zero, shown, big) = inLang(l) {
                (L.bytes(0),
                 [SettingsFormat.bytes(0), DetailFormat.bytes(0), L.Mail.bytes(0),
                  LibrarySidebarView.footerTotals(count: 0, bytes: 0), LibrarySidebarView.footerShared(bytes: 0),
                  L.MailPref.sampleMeta(provider: "Claude", model: "haiku", bytes: 0)],
                 [SettingsFormat.bytes(1_234_567), DetailFormat.bytes(1_234_567), L.Mail.bytes(1_234_567)])
            }
            let words = ["Zero", "zero", "KB", "kB"]
            c.check("bytes: zero in the UI language (\(l.rawValue))",
                    zero == (l == .zh ? "0字节" : "0 bytes") && !words.contains { zero.contains($0) }, ["zero": zero])
            c.check("bytes: every size display uses it (\(l.rawValue))",
                    shown.allSatisfy { $0.contains(zero) && !words.contains(where: $0.contains) }
                        && (l == .en || !shown.contains { $0.contains("bytes") }),
                    ["shown": shown])
            c.check("bytes: larger sizes keep their unit (\(l.rawValue))",
                    big.allSatisfy { $0 == big[0] && $0.contains("1.2") && $0.contains("MB") }, ["big": big[0]])
        }
        c.check("bytes: zh footer reads 0 篇 · 0字节",
                inLang(.zh) { LibrarySidebarView.footerTotals(count: 0, bytes: 0) } == "0 篇 · 0字节")
        c.check("bytes: negative sizes read as zero", L.bytes(-5, lang: .en) == "0 bytes")
    }

    /// The sidebar footer as drawn for an empty library (the report: 「0 篇 · Zero KB」 in zh).
    private static func footerDrawn(scratch: URL, _ c: Checker) async {
        let ui = LangStore.shared.lang
        let root = scratch.appendingPathComponent("footer", isDirectory: true)
        let mail = Shared(MailSettings(enabled: false))
        guard let engine = try? await skippedEngine(root, lang: Shared(ui), mail: mail,
                                                    source: FakeSource("none", status: .needsSetup("none"))) else {
            c.check("bytes: footer engine fixture", false)
            return
        }
        let suite = scratch.appendingPathComponent("defaults-footer/defaults").path
        try? FileManager.default.createDirectory(atPath: (suite as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let defaults = UserDefaults(suiteName: suite) {
            let savedLang = LangStore.shared.lang, savedProvider = LangStore.shared.provider
            let store = SettingsStore(defaults: defaults)
            store.language = ui
            let state = AppState(engine: engine, settings: store)
            state.scheduleRefresh(delay: .zero)
            _ = await eventually(5) { state.snapshot != nil }
            let lines = await drawnText(LibrarySidebarView(state: state).environment(LibraryChrome()).frame(height: 780), width: 250)
            let text = lines.joined().filter { !$0.isWhitespace }
            let size = L.bytes(0).filter { !$0.isWhitespace }
            c.check("bytes: the drawn footer says the size in the UI language (\(ui.rawValue))",
                    state.snapshot?.totals.count == 0 && text.contains(size) && !text.contains("Zero") && !text.contains("KB"),
                    ["footer": lines.last { $0.contains(ui == .zh ? "篇" : "paper") }])
            state.stop()
            defaults.removePersistentDomain(forName: suite)
            LangStore.shared.lang = savedLang
            LangStore.shared.provider = savedProvider
        } else {
            c.check("bytes: scratch defaults", false)
        }
        await close(engine)
    }

    // MARK: Launch alert assembly (a4-3)

    private static func launchAlertAssembly(_ c: Checker) {
        _ = NSApplication.shared
        let paths = AppPaths.rooted(at: FileManager.default.temporaryDirectory.appendingPathComponent("pd-alert-check", isDirectory: true))
        func facts(_ a: NSAlert) -> [String] {
            [a.messageText, a.informativeText, "\(a.alertStyle.rawValue)"] + a.buttons.map(\.title)
        }
        let cases = PreviewRenderer.launchAlertCases() + PreviewRenderer.volumeAlertCases()
        c.check("alert: the renders draw every launch failure",
                Set(cases.map(\.failure.logName)) == ["database", "database-disk-full", "newer-schema", "app-data-folder", "library-folder",
                                                      "library-volume-missing"])
        for (name, failure) in cases {
            let render = PreviewRenderer.launchAlert(failure)
            let real = AppDelegate.launchAlert(for: failure, paths: paths)
            let buttons = LaunchAlert.buttons(for: failure).map(L.launchButton)
            if case .volumeMissing(let volume) = failure {
                // A library on a disk that isn't connected: Retry · Choose Another Folder… · Quit.
                let titles = [L.retry, L.Onb.chooseAnotherFolder, L.quit]
                c.check("alert: \(name) — render and launch assembled alike",
                        render.messageText == real.messageText && real.messageText == L.Onb.volumeMissingTitle(volume)
                            && render.alertStyle == real.alertStyle && real.alertStyle == .warning
                            && render.buttons.map(\.title) == titles && real.buttons.map(\.title) == titles
                            && real.informativeText.contains(paths.library.path)
                            && render.informativeText == L.Onb.volumeMissingBody(path: "/Volumes/Research/PaperDeck", volume: "Research"),
                        ["buttons": real.buttons.map(\.title)])
            } else if failure.offersAnotherLibrary {
                // Only the folder named differs: the render shows a stand-in for the user's library.
                c.check("alert: \(name) — render and launch assembled alike",
                        render.messageText == real.messageText && render.alertStyle == real.alertStyle
                            && render.buttons.map(\.title) == real.buttons.map(\.title) && real.buttons.map(\.title) == buttons
                            && real.informativeText.contains(paths.library.path) && real.informativeText.contains("Papers")
                            && render.informativeText == L.libraryUnavailableBody(path: "~/Documents/PaperDeck", alt: "~/Papers")
                            && real.alertStyle == .warning)
            } else {
                c.check("alert: \(name) — render is the launch's alert",
                        facts(render) == facts(real) && real.alertStyle == .critical
                            && real.messageText == L.databaseFailureTitle(failure) && real.informativeText == L.databaseFailureBody(failure)
                            && real.buttons.map(\.title) == buttons,
                        ["buttons": real.buttons.map(\.title)])
            }
        }
        // A click maps back to the button at its place; anything else quits.
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let db = LibraryOpenFailure.database(diskFull: false)
        let mapped = (0..<3).map { LaunchAlert.button(for: NSApplication.ModalResponse(rawValue: first + $0), failure: db) }
        c.check("alert: clicks map to the alert's buttons in order",
                mapped == LaunchAlert.buttons(for: db)
                    && LaunchAlert.button(for: NSApplication.ModalResponse(rawValue: first + 3), failure: db) == .quit
                    && LaunchAlert.button(for: .abort, failure: .libraryFolder) == .quit
                    && LaunchAlert.button(for: NSApplication.ModalResponse(rawValue: first), failure: .libraryFolder) == .useAlternative)
    }
}
