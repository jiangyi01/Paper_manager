import AppKit
import SwiftUI
import PaperDeckCore

/// `--render … [--mail-folder DIR]`: the mail pages added by the app fixes — the watched folder's
/// 「不是完整的邮件」 hint (inbox notice, Settings account row, the guide sheet), the Power Automate
/// form with its OneDrive folder preselected, card states (awaiting consent / needs a PDF / triage
/// running / merged), the 「已匹配邮件请求」 toast with Undo, and the AI status with mail triage
/// (pill, queue popover, sidebar footer, menu-bar lines as text), and the skipped-emails notice
/// (Settings account rows, inbox) with 「立即同步」.
///
/// Everything stays inside the scratch `--root`: the demo folder account's OneDrive path is under
/// it, the folder sync runs with only that account configured (no IMAP account exists during the
/// pass), AI providers are mocks and agent mode is off; the triage status is a synthetic event.
enum MailAppRenders {
    /// Copies DIR's `.eml` files (an Outlook-shaped export, HTML-only files) into the demo folder
    /// account's watched folder and runs one real sync pass of that account.
    static func syncFolder(state: AppState, root: URL, fixtures: URL) async throws {
        let settings = state.settings
        guard let account = settings.mailAccounts.first(where: { $0.kind == .folder }), let path = account.folderPath else { return }
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        // Only ever inside the scratch root (symlinks resolved: /tmp → /private/tmp).
        let scratch = root.absoluteURL.resolvingSymlinksInPath().path + "/"
        guard folder.path.hasPrefix(root.absoluteURL.path + "/")
                || folder.resolvingSymlinksInPath().path.hasPrefix(scratch) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: folder.path])
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let settled = Date().addingTimeInterval(-3600)        // past the source's settle / stable-bytes checks
        let files = ((try? fm.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "eml" }
        for file in files {
            let dest = folder.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: file, to: dest) }
            try fm.setAttributes([.modificationDate: settled], ofItemAtPath: dest.path)
        }
        let saved = settings.mailAccounts
        settings.mailAccounts = [account]
        await state.engine.mail.syncNow()
        await state.engine.mail.waitUntilIdle()
        settings.mailAccounts = saved
        state.scheduleMailRefresh(delay: .zero)
        try await Task.sleep(for: .milliseconds(300))
    }

    static func render(state: AppState, appearance: NSAppearance?, out: URL, suffix: String,
                       engineLang: SharedValue<UILang>, root: URL, folderFixtures: URL?) async throws {
        func png(_ name: String) -> URL { out.appendingPathComponent("\(name)-\(suffix).png") }
        let engine = state.engine
        let zh = state.settings.language == .zh
        let chrome = LibraryChrome()
        let snap = try await engine.mailSnapshot()

        // Settings ▸ Mail: the accounts with the folder hint, the guide sheet, the Power Automate form.
        try await PreviewRenderer.captureView(
            Form { MailAccountsSection(state: state, infos: snap.accounts, sheet: .constant(nil)) }.formStyle(.grouped)
                .frame(width: 640, height: 560),
            size: NSSize(width: 640, height: 560), appearance: appearance, png("settings-mail-accounts"))
        // The live tab across a language switch (`.task(id: L.lang)` reads the rows again), and the
        // rows of the old language in the moment before that read lands (kinds only, no sentences).
        let start = state.settings.language
        let other: UILang = start == .zh ? .en : .zh
        // As in the app: the switch makes the next pass word the statuses anew (here one pass of
        // the folder account only — the demo IMAP account never connects).
        func switchTo(_ lang: UILang) async {
            state.settings.language = lang
            engineLang.set(lang)
            if let folderFixtures { try? await syncFolder(state: state, root: root, fixtures: folderFixtures) }
        }
        try await PreviewRenderer.captureSequence(
            SettingsView(state: state, tab: .mail).frame(width: 640, height: 900),
            size: NSSize(width: 640, height: 900), appearance: appearance,
            [(png("settings-mail-lang-before"), {}),
             (png("settings-mail-lang-switched"), { await switchTo(other) }),
             (png("settings-mail-lang-back"), { await switchTo(start) })])
        state.settings.language = other
        try await PreviewRenderer.captureView(
            Form { MailAccountsSection(state: state, infos: MailStatusText.current(snap.accounts.map { info in
                var i = info
                if i.status == nil { i.status = .unavailable(MailSyncText.syncFailed(start)) }
                return i
            }, readIn: start, lang: other), sheet: .constant(nil)) }.formStyle(.grouped)
                .frame(width: 640, height: 560),
            size: NSSize(width: 640, height: 560), appearance: appearance, png("settings-mail-accounts-stale"))
        state.settings.language = start
        let folderAccount = state.settings.mailAccounts.first { $0.kind == .folder }
        let folderInfo = snap.accounts.first { $0.id == folderAccount?.id }
        try await PreviewRenderer.captureView(
            MailPowerAutomateGuideSheet(state: state, account: folderAccount, notEmailFiles: folderInfo?.notEmailFiles ?? 0,
                                        onClose: {}),
            size: NSSize(width: 600, height: 700), appearance: appearance, png("mail-guide-sheet"))
        try await PreviewRenderer.captureView(
            MailAddAccountSheet(state: state, editing: nil, initialTemplate: .powerAutomate, onClose: {}),
            size: NSSize(width: 600, height: 700), appearance: appearance, png("mail-add-powerautomate"))
        // 「有新的阅读请求时通知我」 on: the permission row appears under it.
        state.settings.mailNotifyNewRequests = true
        try await PreviewRenderer.captureView(
            Form { MailMergeSection(state: state, clearing: false, confirmClear: .constant(false)) }.formStyle(.grouped)
                .frame(width: 640, height: 640),
            size: NSSize(width: 640, height: 640), appearance: appearance, png("settings-mail-notify"))
        state.settings.mailNotifyNewRequests = false
        if let notice = MailNoticePolicy.notices(snap.accounts).first(where: { $0.kind == .notEmail }) {
            for width in [820, 400] {
                try await PreviewRenderer.captureView(
                    MailInboxNoticeView(state: state, notice: notice, more: 1, onShowAll: {}).frame(width: CGFloat(width)).padding(12),
                    size: nil, appearance: appearance, png(width == 820 ? "mail-notemail-notice" : "mail-notemail-notice-400"))
            }
        }

        // Card states.
        let previous = state.sidebar
        state.sidebar = .mail
        defer { state.sidebar = previous }
        let pending = snap.cards(.pending)
        func card(_ c: MailCard, _ name: String) async throws {
            try await PreviewRenderer.captureView(MailCardView(state: state, card: c, aiMode: snap.aiMode).environment(chrome)
                                                    .frame(width: 820).padding(12),
                                                  size: nil, appearance: appearance, png(name))
        }
        if let c = pending.first(where: { $0.message.triageState == .awaitingConsent && $0.canRequestAI }) {
            try await card(c, "mail-card-consent")
            // The same card selected: the whole explanation box with the institution's note.
            let selected = state.selectedMailID
            state.selectedMailID = c.id
            try await card(c, "mail-card-consent-selected")
            state.selectedMailID = selected
        }
        if let c = pending.first(where: { $0.needsPDFCount > 0 }) {
            try await card(c, "mail-card-needspdf")
        }
        if let base = pending.first(where: { $0.message.senderKind == .alert }) ?? pending.first {
            // "Running" lives only in the agent queue (`runningTriagePK`), never in the database.
            var m = base.message
            m.triageState = .queued
            try await card(MailCard(message: m, items: base.items, rule: base.rule, account: base.account,
                                    runningTriagePK: m.pk), "mail-card-running")
        }
        if let c = pending.first(where: { c in c.items.contains { MailInboxRules.chip($0) == .attachment } }) {
            // A real merge of the attachment (agent mode is off: no AI run).
            _ = try? await engine.mergeAllMailItems(messageID: c.id, options: MailMergeOptions(priority: .high, pinDeadline: nil,
                                                                                                category: nil, readWithAI: false))
            if let merged = try await engine.mailCard(id: c.id) { try await card(merged, "mail-card-merged") }
            // The rest skipped → the card is handled (已处理).
            for item in (try await engine.mailCard(id: c.id))?.items ?? [] where item.status == .pending {
                try? await engine.skipMailItem(itemID: item.id)
            }
            if let handled = try await engine.mailCard(id: c.id) { try await card(handled, "mail-card-handled") }
        }

        // 「已匹配邮件请求」 with Undo (the matcher's toast), and what Undo reports.
        let subject = "Paper for Friday's meeting"
        let matched = Toast(kind: .success, message: zh ? "已匹配邮件请求：\(subject)" : "Matched an email request: \(subject)",
                            buttons: [.init(title: zh ? "查看" : "View", action: .openMail(id: "x")),
                                      .init(title: zh ? "撤销" : "Undo", action: .undoMailLink(token: "t"))])
        let undone = Toast(kind: .success, message: L.Mail.linkUndone)
        let failed = Toast(kind: .info, message: L.Mail.linkUndoFailed)
        try await PreviewRenderer.captureView(
            VStack(spacing: 8) {
                ForEach([matched, undone, failed]) { t in ToastCard(toast: t, onAction: { _ in }, onDismiss: {}) }
            }
            .frame(width: 320).padding(10),
            size: nil, appearance: appearance, png("toast-mail-undo"))

        // AI status while an email is analyzed / waits (synthetic queue events; nothing runs).
        let before = state.agentStatus
        let ready = AgentQueueStatus.Provider.ready(plan: "max", version: "2.1.0")
        let statuses: [(String, AgentQueueStatus)] = [
            ("triage-running", AgentQueueStatus(provider: ready, providerKind: .claude, mode: .claude, queued: 2,
                                                triageQueued: 1, runningTriageMessagePK: pending.first?.message.pk ?? 1,
                                                triageRunningSince: Date().addingTimeInterval(-12))),
            ("triage-queued", AgentQueueStatus(provider: ready, providerKind: .claude, mode: .claude, triageQueued: 3)),
            ("reading-plus-triage", AgentQueueStatus(provider: ready, providerKind: .claude, mode: .claude,
                                                     runningPaperID: "p", runningSince: Date().addingTimeInterval(-40),
                                                     queued: 1, triageQueued: 2)),
        ]
        var lines: [String] = []
        for (name, status) in statuses {
            engine.events.send(.agentStatus(status))
            try await Task.sleep(for: .milliseconds(250))
            lines.append("\(name): " + StatusBarController.claudeLine(status, lang: state.settings.language).title)
            try await PreviewRenderer.captureView(ClaudePill(state: state).padding(8), size: nil, appearance: appearance,
                                                  png("pill-\(name)"))
            try await PreviewRenderer.captureView(ClaudeQueuePopover(state: state), size: nil, appearance: appearance,
                                                  png("queue-\(name)"))
        }
        engine.events.send(.agentStatus(statuses[0].1))
        try await Task.sleep(for: .milliseconds(250))
        try await PreviewRenderer.captureView(LibrarySidebarView(state: state).environment(chrome).frame(width: 250, height: 780),
                                              size: NSSize(width: 250, height: 780), appearance: appearance,
                                              png("sidebar-triage"))
        engine.events.send(.agentStatus(before))
        let text = out.appendingPathComponent("menubar-lines-\(suffix).txt")
        try (lines.joined(separator: "\n") + "\n").write(to: text, atomically: true, encoding: .utf8)
        print("wrote \(text.path)")
        lines.forEach { print("  " + $0) }

        if folderFixtures != nil, let folderInfo {
            try await ignoreRenders(state: state, accountID: folderInfo.id, root: root, appearance: appearance, png: png)
        }
        try await skippedRenders(state: state, appearance: appearance, png: png)
    }

    /// The decluttered header and 「忽略」 on the folder's not-email files: the header and the status
    /// popover before; then the files ignored — the header without the notice or an orange status,
    /// the popover and Settings ▸ Mail with the quiet 「1 ignored file · Show」 line, the whole
    /// inbox; then a new not-email file (one more pass of the demo folder) brings the notice back
    /// for that file alone (then both are ignored). Everything inside the scratch `--root`; nothing
    /// is moved to the Trash.
    static func ignoreRenders(state: AppState, accountID: String, root: URL,
                              appearance: NSAppearance?, png: (String) -> URL) async throws {
        let engine = state.engine
        let chrome = LibraryChrome()
        func refreshed(_ ok: @escaping (MailSnapshot) -> Bool) async throws -> MailSnapshot {
            var waited = 0
            state.scheduleMailRefresh(delay: .zero)
            while !(state.mailSnapshot.map(ok) ?? false) && waited < 50 {
                try await Task.sleep(for: .milliseconds(100))
                state.scheduleMailRefresh(delay: .zero)
                waited += 1
            }
            return try await engine.mailSnapshot()
        }
        func shots(_ snap: MailSnapshot, _ tag: String) async throws {
            try await PreviewRenderer.captureView(MailInboxHeader(state: state, snap: snap).frame(width: 820).padding(12),
                                                  size: nil, appearance: appearance, png("mail-header-\(tag)"))
            try await PreviewRenderer.captureView(MailStatusPopover(state: state, snap: snap), size: nil, appearance: appearance,
                                                  png("mail-status-popover-\(tag)"))
            try await PreviewRenderer.captureView(
                Form { MailAccountsSection(state: state, infos: snap.accounts, sheet: .constant(nil)) }.formStyle(.grouped)
                    .frame(width: 640, height: 640),
                size: NSSize(width: 640, height: 640), appearance: appearance, png("settings-mail-accounts-\(tag)"))
        }
        let previous = state.sidebar
        state.sidebar = .mail
        defer { state.sidebar = previous }
        try await shots(try await refreshed { _ in true }, "notemail")

        await engine.mail.ignoreNotEmailFiles(accountID: accountID)
        let ignored = try await refreshed { $0.accounts.contains { $0.ignoredNotEmailFiles > 0 } }
        try await shots(ignored, "ignored")
        try await PreviewRenderer.captureView(MailInboxView(state: state).environment(chrome).frame(width: 1044, height: 900),
                                              size: NSSize(width: 1044, height: 900), appearance: appearance,
                                              png("mail-inbox-ignored"))

        // A new file that isn't an email (scratch fixtures under --root): the notice is back, for it alone.
        let extra = root.appendingPathComponent("render-new-notemail", isDirectory: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try Data("<html><head><meta charset=\"utf-8\"></head><body>Body only</body></html>".utf8)
            .write(to: extra.appendingPathComponent("Second body only.eml"))
        try await syncFolder(state: state, root: root, fixtures: extra)
        let again = try await refreshed { $0.accounts.contains { $0.notEmailFiles > 0 && $0.ignoredNotEmailFiles > 0 } }
        try await shots(again, "newfile")
        // Both ignored: the skipped-emails pages after these show their own notice.
        await engine.mail.ignoreNotEmailFiles(accountID: accountID)
        _ = try await refreshed { $0.accounts.allSatisfy { $0.notEmailFiles == 0 } }
    }

    /// Allowlisted emails skipped because an account's retry list was full (a4-1): the notice with
    /// the engine's `skippedHint` and 「立即同步」 — Settings ▸ Mail ▸ Accounts and the inbox header.
    /// The demo Gmail account gets the count a pass would have stored; it is read at the next pass,
    /// run here with mail off so no account syncs (nothing connects). The folder account's row also
    /// shows a pass that got through with emails still skipped (its status as the pipeline words it:
    /// `… · <skippedHint>`), whose sentence the status line leaves to the notice.
    static func skippedRenders(state: AppState, appearance: NSAppearance?, png: (String) -> URL) async throws {
        let settings = state.settings
        let engine = state.engine
        guard let gmail = settings.mailAccounts.first(where: { $0.kind == .imap }) else { return }
        try await engine.db.setMailCursor(accountID: gmail.id + ".skipped", MailCursor("3"))
        settings.mailEnabled = false
        await engine.mail.syncNow()                         // mail off: counts read, no account synced
        settings.mailEnabled = true
        let lang = settings.language
        let infos = await MailStatusText.read(engine.mail, lang: lang).map { info -> MailAccountSyncInfo in
            guard info.kind == .folder, case .ready(let detail)? = info.status else { return info }
            var i = info
            let account = settings.mailAccounts.first { $0.id == info.id }
            i.skipped = 2
            i.skippedHint = MailSyncText.skippedByCap(2, lookbackDays: account?.lookbackDays ?? 14, lang)
            i.status = .unavailable(detail + " · " + (i.skippedHint ?? ""))
            return i
        }
        try await PreviewRenderer.captureView(
            Form { MailAccountsSection(state: state, infos: infos, sheet: .constant(nil)) }.formStyle(.grouped)
                .frame(width: 640, height: 700),
            size: NSSize(width: 640, height: 700), appearance: appearance, png("settings-mail-accounts-skipped"))

        state.scheduleMailRefresh(delay: .zero)
        var waited = 0
        while state.mailSnapshot?.accounts.contains(where: { $0.skipped > 0 }) != true && waited < 50 {
            try await Task.sleep(for: .milliseconds(100))
            state.scheduleMailRefresh(delay: .zero)
            waited += 1
        }
        let previous = state.sidebar
        state.sidebar = .mail
        defer { state.sidebar = previous }
        try await PreviewRenderer.captureView(MailInboxView(state: state).environment(LibraryChrome()).frame(width: 900, height: 640),
                                              size: NSSize(width: 900, height: 640), appearance: appearance,
                                              png("mail-inbox-skipped"))
        if let notice = MailNoticePolicy.notices(state.mailSnapshot?.accounts ?? []).first(where: { $0.kind == .skipped }) {
            try await PreviewRenderer.captureView(MailInboxNoticeView(state: state, notice: notice, more: 0, onShowAll: {})
                                                    .frame(width: 820).padding(12),
                                                  size: nil, appearance: appearance, png("mail-skipped-notice"))
        }
        try await engine.db.setMailCursor(accountID: gmail.id + ".skipped", nil)
    }
}
