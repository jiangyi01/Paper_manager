import AppKit
import UniformTypeIdentifiers
import PaperDeckCore
import PaperDeckConfig

// Mail inbox state and actions (MAIL_DESIGN Part A §3). The stored properties live in
// AppState.swift (@Observable needs them in the class body); everything else is here.
//
// Privacy: nothing here logs mail content — only counts and error types. Mail text is
// untrusted: it is shown as plain text only, links open only when they are http(s).

extension AppState {
    // MARK: Lifecycle

    /// Called from `start()`: drop handlers, app-activation sync nudge, periodic refresh.
    /// Returns the long-running tasks (cancelled by `stop()`).
    func startMail() -> [Task<Void, Never>] {
        let registry = DropTargetRegistry.shared
        registry.onTargetedDrop = { [weak self] target, items, ignored in
            self?.handleTargetedDrop(target, items: items, ignored: ignored)
        }
        registry.onMailFiles = { [weak self] urls, temporary in
            self?.importMailFiles(urls, temporary: temporary)
        }
        scheduleMailRefresh(delay: .zero)
        let engine = self.engine
        var tasks: [Task<Void, Never>] = []
        // App activation → the sync actor may run a (throttled) pass; the inbox refreshes.
        tasks.append(Task { [weak self] in
            let token = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    Task { await engine.mail.appDidBecomeActive() }
                    self?.scheduleMailRefresh()
                }
            }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            NotificationCenter.default.removeObserver(token)
        })
        // Every minute (account status, triage usage, snooze wake-ups); every 5 s while the inbox
        // is open and an AI triage is queued or running ("running" is never written to the DB).
        tasks.append(Task { [weak self] in
            var elapsed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                elapsed += 5
                if elapsed >= 60 || self.mailNeedsFastRefresh {
                    elapsed = 0
                    self.scheduleMailRefresh(delay: .zero)
                }
            }
        })
        return tasks
    }

    /// The inbox is visible and something there changes without a DB write.
    private var mailNeedsFastRefresh: Bool {
        guard sidebar == .mail, let snap = mailSnapshot else { return false }
        if snap.triageQueued > 0 || mailSyncing { return true }
        return snap.cards(.pending).contains { [.queued, .running].contains($0.displayTriageState) }
    }

    /// Coalesces bursts of mail changes into one snapshot read (never starves: a snapshot older
    /// than 2 s is read at once).
    func scheduleMailRefresh(delay: Duration = .milliseconds(200)) {
        mailRefreshTask?.cancel()
        let wait = Date().timeIntervalSince(mailRefreshedAt) > 2 ? .zero : delay
        mailRefreshTask = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled, let self else { return }
            do {
                let snap = try await self.engine.mailSnapshot()
                guard !Task.isCancelled else { return }
                self.mailRefreshedAt = Date()
                if snap != self.mailSnapshot {
                    self.mailSnapshot = snap
                    self.onMailSnapshot?(snap)
                }
            } catch {
                Log.app.error("mail snapshot failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    /// Drop zones of the inbox rows / cards (shared with every `DropHostingView`).
    var dropTargets: DropTargetRegistry { .shared }

    // MARK: Navigation

    /// Library ▸ Mail (the default `router.showMail`): selects `id` in its filter when given.
    func openMail(_ id: String?) {
        if !searchText.isEmpty { searchText = "" }
        sidebar = .mail
        if let id = id?.lowercased() {
            selectedMailID = id
            if let card = mailSnapshot?.card(id: id) {
                mailFilter = card.filter
            } else {
                let engine = self.engine
                Task {
                    if let card = try? await engine.mailCard(id: id), self.selectedMailID == id { self.mailFilter = card.filter }
                    self.scheduleMailRefresh(delay: .zero)
                }
            }
        }
        router.showLibrary()
    }

    /// Settings ▸ Mail with the Power Automate guide open (the 「N 个文件不是完整的邮件」 hints).
    func openPowerAutomateGuide(accountID: String?) {
        mailGuideRequest = accountID ?? ""
        router.showSettings("mail")
    }

    /// The selected card (snapshot first; the detail view loads older ones itself).
    var selectedMailCard: MailCard? {
        guard let id = selectedMailID else { return nil }
        return mailSnapshot?.card(id: id)
    }

    // MARK: Card actions

    /// The merge popover's defaults: the sender rule's priority / category / due-date policy and
    /// the email's due date only when confident and not past (`MailMergeOptions.suggested`).
    func suggestedMergeOptions(for card: MailCard) async -> MailMergeOptions {
        let settings = await engine.ctx.settings()
        let today = LocalDate.today(now: engine.ctx.now(), calendar: engine.ctx.calendar)
        return MailMergeOptions.suggested(for: card.message, rule: card.rule, settings: settings, today: today)
    }

    /// 「全部合并 (N)」 with the popover's options.
    func mergeAllMail(_ card: MailCard, options: MailMergeOptions) {
        let id = card.id
        mailOperation(keys: [id] + card.items.map(\.id)) {
            let produced = try await self.engine.mergeAllMailItems(messageID: id, options: options)
            if produced.isEmpty { self.post(Toast(kind: .info, message: L.Mail.mergedNone)) }
        }
    }

    /// 「合并到论文库」 / 「自动下载并合并」 / 「关联」 for one row.
    func mergeMailItem(_ item: MailItem, options: MailMergeOptions) {
        let id = item.id
        let downloads = MailInboxRules.chip(item) == .downloadable
        mailOperation(keys: [id]) {
            // nil = the download or the import didn't produce a paper; the row says why and waits.
            if try await self.engine.mergeMailItem(itemID: id, options: options) == nil {
                self.post(Toast(kind: .warning, message: downloads ? L.Mail.downloadFailed : L.Mail.attachFailed))
            }
        }
    }

    /// 「转换为 PDF 并合并」 for a document row, with the popover's options: converted on this Mac
    /// and imported like an attachment (the possibly-unpublished hold applies; nothing goes to AI or
    /// the network). The row shows 「正在本机转换为 PDF…」 meanwhile (`MailDocumentActivity`); a
    /// failure leaves the row waiting with its reason (`downloadError`) and a toast. A second
    /// request while the row converts does nothing (the engine would answer it with nil).
    func convertMailDocument(_ item: MailItem, options: MailMergeOptions) {
        let id = item.id
        let activity = MailDocumentActivity.shared
        guard !activity.isConverting(id) else { return }
        let name = MailDocumentInfo.fileName(item) ?? L.Mail.documentKind(.other)
        activity.begin(id)
        mailOperation(keys: [id]) {
            defer { activity.end(id) }
            if let paperID = try await self.engine.convertAndMergeMailItem(itemID: id, options: options) {
                self.post(Toast(id: "mail-converted-\(id)", kind: .success, message: L.Mail.converted(name),
                                buttons: [.init(title: L.Mail.view, action: .openPaper(id: paperID))]))
            } else {
                self.post(Toast(id: "mail-convert-failed-\(id)", kind: .warning, message: L.Mail.convertFailed))
            }
        }
    }

    /// 「打开」 on a document row: the stored attachment in its own app (`MailDocumentOpen` —
    /// document types inside the attachment folder only, marked as downloaded first).
    func openMailDocument(_ item: MailItem) {
        let id = item.id
        let engine = self.engine
        Task {
            let url: URL
            do {
                url = try await engine.openMailDocument(itemID: id)
            } catch MailOperationError.fileMissing {
                self.post(Toast(id: "mail-document-missing-\(id)", kind: .warning, message: L.Mail.documentMissing))
                return
            } catch {
                self.report(error)
                return
            }
            let root = engine.paths.mailFiles
            let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
                guard MailDocumentOpen.mayOpen(url, root: root) else { return false }
                MailDocumentOpen.markDownloaded(url)
                return true
            }.value
            guard ok else {
                self.post(Toast(id: "mail-document-refused-\(id)", kind: .warning, message: L.Mail.documentRefused))
                return
            }
            NSWorkspace.shared.open(url)
        }
    }

    /// 「仅下载 PDF」 (the row becomes 已下载, merge later).
    func downloadMailItem(_ item: MailItem) {
        let id = item.id
        mailOperation(keys: [id]) { try await self.engine.downloadMailItem(itemID: id) }
    }

    func skipMailItem(_ item: MailItem) {
        let id = item.id
        mailOperation(keys: [id]) { try await self.engine.skipMailItem(itemID: id) }
    }

    func dismissMail(_ card: MailCard) {
        let id = card.id
        mailOperation(keys: [id]) {
            try await self.engine.dismissMail(messageID: id)
            self.post(Toast(id: "mail-dismissed-\(id)", kind: .info, message: L.Mail.dismissedToast))
        }
    }

    func snoozeMail(_ card: MailCard, until: Date) {
        let id = card.id
        mailOperation(keys: [id]) {
            try await self.engine.snoozeMail(messageID: id, until: until)
            self.post(Toast(id: "mail-snoozed-\(id)", kind: .info, message: L.Mail.snoozedToast(L.Mail.when(until))))
        }
    }

    /// Back to 待处理 (from 稍后 / 已处理 / 已忽略 / 无阅读需求).
    func reopenMail(_ card: MailCard) {
        let id = card.id
        mailOperation(keys: [id]) {
            try await self.engine.reopenMail(messageID: id)
            if self.selectedMailID == id { self.mailFilter = .pending }
        }
    }

    /// 「让 AI 分析」: the user's consent for this one email.
    func requestMailAI(_ card: MailCard) {
        let id = card.id
        mailAIRequested.insert(id)
        mailOperation(keys: [id]) {
            defer { self.mailAIRequested.remove(id) }
            _ = try await self.engine.requestMailAI(messageID: id)
        }
    }

    /// 立即同步 (all accounts, then the inbox refreshes).
    func syncMailNow() {
        guard !mailSyncing else { return }
        mailSyncing = true
        let engine = self.engine
        Task {
            await MailSyncCommands.syncAll(engine.mail)            // an explicit retry: every parked account
            self.mailSyncing = false
            self.scheduleMailRefresh(delay: .zero)
        }
    }

    // MARK: Links (untrusted: http(s) only)

    func openMailLink(_ item: MailItem) {
        guard let url = MailInboxRules.linkURL(item) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 「在 Gmail 中打开」 / 「在网页版中打开」 (the message's web link, when the transport knows one).
    func openMailOnWeb(_ card: MailCard) {
        guard let url = MailInboxRules.safeWebURL(card.message.webLink) else { return }
        NSWorkspace.shared.open(url)
    }

    func copyMailLink(_ card: MailCard) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(DeepLink.mail(id: card.id).url.absoluteString, forType: .string)
        post(Toast(id: "mail-link-copied", kind: .success, message: L.Mail.linkCopied))
    }

    func copyText(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    // MARK: PDFs for rows

    /// 「选择 PDF…」 on a row (the keyboard / accessibility path of the drop box).
    func choosePDF(for item: MailItem, window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = L.Mail.importPrompt
        panel.message = L.Mail.choosePDFMessage
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.attachPDF(url, to: item)
        }
        if let window, window.isVisible, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            NSApp.activate()
            panel.begin(completionHandler: handler)
        }
    }

    /// The user's PDF becomes this row's paper (sender defaults; copied, never moved).
    func attachPDF(_ file: URL, to item: MailItem) {
        let id = item.id
        let title = MailInboxRules.line(item.title, limit: 60)
        mailOperation(keys: [id]) {
            if let paperID = try await self.engine.attachPDFToMailItem(itemID: id, file: file) {
                self.post(Toast(id: "mail-attached-\(id)", kind: .success,
                                message: L.Mail.attached(title.isEmpty ? L.Mail.untitled : title),
                                buttons: [.init(title: L.Mail.view, action: .openPaper(id: paperID))]))
            } else {
                self.post(Toast(kind: .warning, message: L.Mail.attachFailed))
            }
        }
    }

    // MARK: Drops (DropHostingView → DropTargetRegistry)

    /// A PDF-only drop on a Mail row (one PDF → that row) or card (each PDF matched to a row by
    /// DOI / arXiv id / title; unmatched ones are imported normally, where the matcher may still
    /// link them).
    func handleTargetedDrop(_ target: DropTargetRegistry.Target, items: [IntakeItem], ignored: [String]) {
        if !ignored.isEmpty {
            post(Toast(kind: .warning, message: L.ignoredNonPDF(count: ignored.count, names: ignored.prefix(3).joined(separator: ", "))))
        }
        guard !items.isEmpty else { return }
        switch target {
        case .mailItem(let itemID):
            Task {
                guard let item = await self.mailItem(id: itemID) else {
                    self.ingest(items, origin: .drop)
                    return
                }
                var rest = Array(items.dropFirst())
                if let url = await self.materialize(items[0]) {
                    self.attachPDF(url, to: item)
                } else {
                    rest.insert(items[0], at: 0)
                }
                if !rest.isEmpty {
                    self.ingest(rest, origin: .drop)
                    self.post(Toast(kind: .info, message: L.Mail.oneRowOnePDF))
                }
            }
        case .mailCard(let messageID):
            Task { await self.dropOnCard(messageID: messageID, items: items) }
        }
    }

    private func dropOnCard(messageID: String, items: [IntakeItem]) async {
        var card = mailSnapshot?.card(id: messageID)
        if card == nil { card = try? await engine.mailCard(id: messageID) }
        guard let card else {
            ingest(items, origin: .drop)
            return
        }
        var remaining = card.items
        var unmatched: [IntakeItem] = []
        let extractor = PDFExtractor()
        for intake in items {
            guard let url = await materialize(intake) else { unmatched.append(intake); continue }
            let pdf = try? await extractor.extract(url: url, fileName: url.lastPathComponent)
            if let row = MailInboxRules.matchDroppedPDF(ids: pdf?.ids ?? PaperIDs(), title: pdf?.bestLocalTitle?.0,
                                                        items: remaining, soleFallback: items.count == 1) {
                remaining.removeAll { $0.id == row.id }
                attachPDF(url, to: row)
            } else {
                unmatched.append(Self.intakeItem(for: url, original: intake))
            }
        }
        if !unmatched.isEmpty {
            ingest(unmatched, origin: .drop)
            post(Toast(kind: .info, message: L.Mail.noRowMatched))
        }
    }

    private func mailItem(id: String) async -> MailItem? {
        if let snap = mailSnapshot {
            for filter in MailInboxFilter.allCases {
                for card in snap.cards(filter) {
                    if let item = card.items.first(where: { $0.id == id }) { return item }
                }
            }
        }
        return try? await engine.db.mailItem(id: id)
    }

    /// A local file for a dropped item: files and received promises as they are; raw PDF data is
    /// written under incoming/ (the import treats it like a promise copy). Links → nil.
    private func materialize(_ item: IntakeItem) async -> URL? {
        switch item {
        case .file(let url), .promised(let url):
            return url
        case .pdfData(let data, let name):
            let dir = engine.paths.incoming.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let safe = (name as NSString).lastPathComponent
            let url = dir.appendingPathComponent(safe.lowercased().hasSuffix(".pdf") ? safe : "Dropped.pdf")
            let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    return true
                } catch { return false }
            }.value
            return ok ? url : nil
        case .remote:
            return nil
        }
    }

    private static func intakeItem(for url: URL, original: IntakeItem) -> IntakeItem {
        switch original {
        case .file: return .file(url)
        case .promised, .pdfData: return .promised(url)
        case .remote: return original
        }
    }

    // MARK: .eml import

    /// Emails dropped anywhere (window, panel) or picked with 「导入 .eml…」 → Mail cards.
    /// `temporary` promise copies are deleted afterwards (the raw message never lingers).
    func importMailFiles(_ urls: [URL], temporary: Bool) {
        guard !urls.isEmpty else { return }
        let engine = self.engine
        let incoming = engine.paths.incoming
        Task {
            let ids = await engine.mail.importEML(urls)
            if temporary {
                await Task.detached(priority: .utility) { MailDropIntake.removeTemporary(urls, incoming: incoming) }.value
            }
            let failed = max(0, urls.count - ids.count)
            // Getting Started / the "blocked Microsoft 365" tutorial: an email was brought in by hand.
            if !ids.isEmpty { self.guide.record(.emlImported) }
            if let last = ids.last {
                var message = L.Mail.imported(ids.count)
                if failed > 0 { message += " · " + L.Mail.importFailed(failed) }
                self.post(Toast(id: "mail-imported-\(last)", kind: .success, message: message,
                                buttons: [.init(title: L.Mail.view, action: .openMail(id: last))]))
            } else {
                self.post(Toast(kind: .warning, message: L.Mail.importFailed(failed)))
            }
            self.scheduleMailRefresh(delay: .zero)
        }
    }

    /// 「导入 .eml…」.
    func pickAndImportEML(window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.emailMessage, UTType(filenameExtension: "eml") ?? .emailMessage]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = L.Mail.importPrompt
        panel.message = L.Mail.importEMLMessage
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.importMailFiles(panel.urls, temporary: false)
        }
        if let window, window.isVisible, window.attachedSheet == nil {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            NSApp.activate()
            panel.begin(completionHandler: handler)
        }
    }

    // MARK: Plumbing

    /// Runs a mail operation with `keys` marked busy; errors become a toast (zh/en); the inbox
    /// refreshes afterwards either way.
    private func mailOperation(keys: [String], _ op: @escaping () async throws -> Void) {
        let keys = Set(keys)
        mailBusy.formUnion(keys)
        Task {
            do { try await op() } catch { self.report(error) }
            self.mailBusy.subtract(keys)
            self.scheduleMailRefresh(delay: .zero)
        }
    }
}
