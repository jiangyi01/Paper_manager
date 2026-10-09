import Foundation

// Email card operations (MAIL_DESIGN §3 "Merge semantics"): merging a card's papers into the
// library through `IntakeActor` (origin `.mail`, always a copy) with a per-file
// `ImportAnnotation` (provenance, priority, pinned DDL, category, notes, link-don't-duplicate),
// downloading locally extracted PDF links, attaching a PDF the user dropped on a row,
// linking, skipping, dismissing and snoozing. Every user action marks the message
// `userTouched` (triage may no longer change its state). Message bodies are never read here
// except the sanitized summary that goes into the notes prefill.

// MARK: - Options

/// What the merge popover chose. nil fields change nothing: a new paper gets the normal
/// placement (priority normal, auto DDL), an existing (linked) paper keeps its priority / DDL.
package struct MailMergeOptions: Sendable, Equatable {
    package var priority: Priority?
    package var pinDeadline: LocalDate?
    /// Category name (created as the user's when missing); a linked paper only gets it when it has none.
    package var category: String?
    /// true → the new papers get AI reading jobs (held for the batch dialog when more than 3
    /// are merged at once; advisor requests are read first). false → no job.
    package var readWithAI: Bool

    package init(priority: Priority? = nil, pinDeadline: LocalDate? = nil, category: String? = nil,
                 readWithAI: Bool = true) {
        self.priority = priority; self.pinDeadline = pinDeadline; self.category = category
        self.readWithAI = readWithAI
    }

    /// The due-date confidence from which the popover pre-checks 「固定 DDL」.
    package static let confidentDue = 0.75

    /// The popover's pre-filled choices (also what `attachPDFToMailItem` and auto-merge use):
    /// the sender rule's defaults (priority — advisor high —, category, due date → DDL), an AI
    /// "high" for person senders, the email's due date only when confident and not past. AI
    /// reading follows 「自动解读新论文」 — except for confidential mail (`MailHeuristics.isConfidential`:
    /// a manuscript under review, a reviewer invitation, the user's own submission), whatever the
    /// sender kind (an editor's invitation from an alert preset's domain too): its papers are not
    /// read by AI unless the user ticks it, and even then the job is held (`mailAnnotation`).
    package static func suggested(for message: MailMessage, rule: SenderRule?, settings: EngineSettings,
                                  today: LocalDate) -> MailMergeOptions {
        var priority: Priority? = rule?.effectivePriority ?? (message.senderKind == .advisor ? .high : nil)
        if message.triage?.priority == .high, message.senderKind == .advisor || message.senderKind == .person {
            priority = .high
        }
        if priority == .normal { priority = nil }
        var pin: LocalDate?
        if rule?.useDueDateAsDDL ?? true, let due = message.triage?.dueDate,
           (message.triage?.dueConfidence ?? 0) >= confidentDue, due >= today {
            pin = due
        }
        let category = rule?.defaultCategory.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return MailMergeOptions(priority: priority, pinDeadline: pin, category: category,
                                readWithAI: settings.autoReadNewPapers && !MailHeuristics.isConfidential(message))
    }
}

// MARK: - Errors

/// Why an email operation was refused. The UI shows `message(_:)` (zh/en).
package enum MailOperationError: Error, Equatable, Sendable {
    case messageNotFound(String)
    case itemNotFound(String)
    /// Nothing to merge yet (no attachment, no downloadable link) — drop the PDF on the row.
    case needsPDF(itemID: String)
    /// The attachment copy is gone (retention or 清除所有邮件数据).
    case fileMissing(itemID: String)

    package func message(_ lang: UILang) -> String {
        let zh = lang == .zh
        switch self {
        case .messageNotFound: return zh ? "找不到这封邮件" : "Email not found"
        case .itemNotFound: return zh ? "找不到这篇论文条目" : "Paper entry not found in this email"
        case .needsPDF: return zh ? "还没有 PDF：请下载后拖到这一行" : "No PDF yet — download it and drop it on this row"
        case .fileMissing: return zh ? "附件副本已被清理，请重新拖入 PDF" : "The attachment copy was cleaned up — drop the PDF again"
        }
    }
}

// MARK: - Message state

/// How far a card is: it becomes `merged` once every item it asked for (requested /
/// highlighted; when nothing is rated, every unrated item) is merged, linked or skipped.
/// Until then it stays in 待处理 with 「还差 N 篇需要 PDF」.
package enum MailMergeState {
    /// The items that decide completion: requested ∪ highlighted, else those without a
    /// relevance; empty when every item is merely `listed` (an alert digest nobody rated).
    package static func targetItems(_ items: [MailItem]) -> [MailItem] {
        let rated = items.filter { $0.relevance == .requested || $0.relevance == .highlighted }
        if !rated.isEmpty { return rated }
        return items.filter { $0.relevance == nil }
    }

    /// Target items still pending (the 「还差 N 篇」 number).
    package static func remaining(_ items: [MailItem]) -> Int {
        targetItems(items).filter { $0.status == .pending }.count
    }

    /// Every target item handled; for an all-`listed` digest, once anything was merged or linked.
    package static func isComplete(_ items: [MailItem]) -> Bool {
        let target = targetItems(items)
        if target.isEmpty {
            return items.contains { $0.status == .merged || $0.status == .linked }
        }
        return target.allSatisfy { $0.status != .pending }
    }

    /// 「还差 N 篇需要 PDF」 / "N more papers need a PDF".
    package static func remainingText(_ n: Int, _ lang: UILang) -> String {
        lang == .zh ? "还差 \(n) 篇需要 PDF" : (n == 1 ? "1 more paper needs a PDF" : "\(n) more papers need a PDF")
    }

    /// The state after items changed. Complete → `merged` (snooze cleared, `handledAt` set).
    /// A user action on an incomplete card brings a dismissed / no-request / merged card back
    /// to 待处理 and marks it `userTouched`; automatic links (the matcher) only ever complete
    /// open cards.
    package static func settle(_ m: inout MailMessage, items: [MailItem], now: Date, userAction: Bool) {
        if userAction { m.userTouched = true }
        if isComplete(items) {
            guard m.state != .merged else { return }
            m.state = .merged
            m.snoozedUntil = nil
            m.handledAt = now
        } else if userAction, m.state == .dismissed || m.state == .noRequest || m.state == .merged {
            m.state = .pending
            m.handledAt = nil
        }
    }
}

// MARK: - Operations

extension Engine {
    /// 「合并到论文库」 for one row. Attachment → imported; downloadable link → downloaded
    /// (`downloadMailItem`) then imported; already in the library → linked (provenance, plus the
    /// options the user chose). Duplicates and same-work files link to the existing paper
    /// instead of parking a replace toast. Returns the paper id (nil when the download or
    /// import failed — the row then says why and waits for a PDF). Idempotent for merged /
    /// linked rows. Throws `MailOperationError.needsPDF` for rows without any PDF source.
    /// `userAction: false` (the sync's auto-merge) leaves `userTouched` alone and only ever
    /// completes an open card.
    @discardableResult
    package func mergeMailItem(itemID: String, options: MailMergeOptions, userAction: Bool = true) async throws -> String? {
        let (message, item) = try await mailRow(itemID)
        if item.status == .merged || item.status == .linked, let id = item.paperID,
           try await db.paper(id: id) != nil {
            return id
        }
        if let linked = try await linkIfInLibrary(item, message: message, options: options, userAction: userAction) {
            return linked
        }
        switch item.pdfState {
        case .hasPDF:
            return try await mergeStored([item], message: message, options: options, userAction: userAction,
                                         strict: true)[item.id]
        case .needsPDF:
            throw MailOperationError.needsPDF(itemID: item.id)
        case .downloadable, .unknown, .downloading, .inLibrary:
            guard let url = Self.mailDownloadURL(item) else {
                try await markNeedsPDF(item, error: nil, userAction: userAction)
                throw MailOperationError.needsPDF(itemID: item.id)
            }
            // Nobody clicked: only arXiv / bioRxiv / medRxiv over https; the rest waits for the user.
            if !userAction, !DownloadPolicy.mailAutomatic.allows(url) { return nil }
            let after = try await downloadMailItemReturning(item, message: message, userAction: userAction)
            if let linked = try await linkIfInLibrary(after, message: message, options: options, userAction: userAction) {
                return linked
            }
            guard after.pdfState == .hasPDF else { return nil }
            return try await mergeStored([after], message: message, options: options, userAction: userAction,
                                         strict: true)[after.id]
        }
    }

    /// 「全部合并」: every pending row the card asked for (`MailMergeState.targetItems`) that has
    /// a PDF source — links first, then downloads, then one import batch (more than 3 files with
    /// AI reading → jobs held for the batch dialog). Rows that still need a PDF stay pending.
    /// Returns the paper ids produced or linked, in row order. `userAction: false` (auto-merge)
    /// downloads only from arXiv / bioRxiv / medRxiv over https (`DownloadPolicy.mailAutomatic`);
    /// `allowDownloads: false` downloads nothing (the sender rule's 「自动下载」 is off).
    @discardableResult
    package func mergeAllMailItems(messageID: String, options: MailMergeOptions,
                                   userAction: Bool = true, allowDownloads: Bool = true) async throws -> [String] {
        let message = try await mailCard(messageID)
        let items = try await db.mailItems(messagePK: message.pk)
        let targets = MailMergeState.targetItems(items).filter { $0.status == .pending }
        var produced: [String: String] = [:]
        var files: [MailItem] = []
        for item in targets {
            if let id = try await linkIfInLibrary(item, message: message, options: options, userAction: userAction) {
                produced[item.id] = id
                continue
            }
            switch item.pdfState {
            case .hasPDF:
                files.append(item)
            case .needsPDF:
                continue
            case .downloadable, .unknown, .downloading, .inLibrary:
                guard allowDownloads, let url = Self.mailDownloadURL(item) else { continue }
                if !userAction, !DownloadPolicy.mailAutomatic.allows(url) { continue }
                let after = try await downloadMailItemReturning(item, message: message, userAction: userAction)
                if let id = try await linkIfInLibrary(after, message: message, options: options, userAction: userAction) {
                    produced[item.id] = id
                } else if after.pdfState == .hasPDF {
                    files.append(after)
                }
            }
        }
        if !files.isEmpty {
            for (itemID, paperID) in try await mergeStored(files, message: message, options: options,
                                                           userAction: userAction) {
                produced[itemID] = paperID
            }
        }
        if produced.isEmpty, userAction { try await touchMail(message.pk) }
        var seen = Set<String>()
        return targets.compactMap { produced[$0.id] }.filter { seen.insert($0).inserted }
    }

    /// The user dropped `file` (a PDF they downloaded) on a row: imported as that row's paper
    /// with the sender's default options (`MailMergeOptions.suggested`). The file is copied,
    /// never moved. Returns the paper id (nil when the import failed — the row keeps waiting).
    @discardableResult
    package func attachPDFToMailItem(itemID: String, file: URL) async throws -> String? {
        let (message, _) = try await mailRow(itemID)
        let settings = await ctx.settings()
        let today = LocalDate.today(now: ctx.now(), calendar: ctx.calendar)
        let options = MailMergeOptions.suggested(for: message, rule: loadMailSettings().rule(id: message.ruleID),
                                                 settings: settings, today: today)
        return try await attachPDFToMailItem(itemID: itemID, file: file, options: options)
    }

    /// `attachPDFToMailItem` with the popover's options.
    @discardableResult
    package func attachPDFToMailItem(itemID: String, file: URL, options: MailMergeOptions) async throws -> String? {
        let (message, item) = try await mailRow(itemID)
        let incoming = LibraryPaths.relativePath(of: file, root: paths.incoming) != nil
        let entry = MailImportEntry(item: item, intake: incoming ? .promised(file) : .file(file), key: file,
                                    storedCopy: nil, userFile: true)
        return try await mergeFiles([entry], message: message, options: options, userAction: true)[item.id]
    }

    /// 「下载」 a row's PDF from its locally extracted link (arXiv, bioRxiv / medRxiv, direct
    /// `.pdf`; never a URL the AI returned) into the card's attachment folder, through
    /// `URLImporter` (HTTP 200, PDF check, size cap). Success → `has_pdf` (or `in_library`
    /// when those bytes are already a paper); failure → `needs_pdf` with `download_error`
    /// (bioRxiv's bot wall gets its own hint). Does not merge. `userAction: false` for the
    /// sync's automatic downloads (the card stays untouched).
    package func downloadMailItem(itemID: String, userAction: Bool = true) async throws {
        let (message, item) = try await mailRow(itemID)
        guard item.status == .pending || item.status == .skipped else { return }
        _ = try await downloadMailItemReturning(item, message: message, userAction: userAction)
    }

    /// 「关联」 (a title-only match the user confirmed, or 「这就是这篇」): the row is linked to
    /// the paper (provenance row, no priority / DDL change).
    package func linkMailItem(itemID: String, paperID: String) async throws {
        let (message, item) = try await mailRow(itemID)
        guard let paper = try await db.paper(id: paperID) else { throw PaperOperationError.paperNotFound(paperID) }
        try await MailItemLinker.link(itemIDs: [item.id], messagePK: message.pk, to: paper, status: .linked,
                                      annotation: nil, userAction: true, ctx: ctx)
    }

    /// 「撤销」 on the matcher's 「已匹配邮件请求」 toast (`Toast.Action.undoMailLink(token:)`): the
    /// rows that link changed go back to pending with their earlier PDF state, unless something
    /// changed them since (a merge, a skip, a re-link — those rows are left alone); the paper
    /// loses the provenance row that link added (while no other row of the card still names
    /// it); a card the link had completed is reopened — back to 待处理 (or 稍后) — unless it was
    /// changed since (reopened, dismissed, snoozed, or a first user action on it). The matcher
    /// won't link those rows to that paper again while the app runs. Not a user action on the
    /// card (`userTouched` unchanged: triage may still classify it). False when the token is
    /// unknown, used, expired (`MailLinkUndo.lifetime`) or nothing was left to undo.
    @discardableResult
    package func undoMailLink(token: String) async throws -> Bool {
        let owner = ObjectIdentifier(db)
        guard let undo = MailLinkUndoLedger.shared.take(token, owner: owner, now: ctx.now()) else { return false }
        MailLinkUndoLedger.shared.decline(itemIDs: undo.rows.map(\.prior.id), paperID: undo.paperID, owner: owner)
        let now = ctx.now()
        let restored = try await db.transaction { db -> Int in
            let paperID = undo.paperID.lowercased()
            var restored = 0
            for (prior, linkedAt) in undo.rows {
                guard var row = try db.mailItem(id: prior.id), row.messagePK == undo.messagePK,
                      row.status == .linked, row.paperID?.lowercased() == paperID, row.updatedAt == linkedAt,
                      !MailMergeInFlight.shared.contains(row.id) else { continue }
                row.status = prior.status
                row.paperID = prior.paperID
                row.pdfState = prior.pdfState
                row.pdfPath = prior.pdfPath
                row.downloadError = prior.downloadError
                try db.upsertMailItem(row, now: now)
                restored += 1
            }
            guard restored > 0 else { return 0 }
            let items = try db.mailItems(messagePK: undo.messagePK)
            let stillNamed = items.contains {
                ($0.status == .merged || $0.status == .linked) && $0.paperID?.lowercased() == paperID
            }
            if undo.sourceAdded, !stillNamed {
                try db.deletePaperSource(paperPK: undo.paperPK, internetMessageID: undo.internetMessageID)
            }
            if let reopen = undo.reopen, let m = try db.mailMessage(pk: undo.messagePK), m.state == .merged,
               m.userTouched == reopen.linkedUserTouched, m.handledAt == reopen.linkedHandledAt,
               !MailMergeState.isComplete(items) {
                try db.modifyMailMessage(pk: undo.messagePK, now: now) { m in
                    m.state = reopen.state
                    m.snoozedUntil = reopen.snoozedUntil
                    m.handledAt = reopen.handledAt
                }
            }
            return restored
        }
        guard restored > 0 else { return false }
        await ctx.syncSidecar(pk: undo.paperPK)
        Log.importer.info("mail match: undid the link of \(restored) email item(s) to paper \(undo.paperPK)")
        return true
    }

    /// 「跳过」 one row (not added). The card completes once every requested row is handled.
    package func skipMailItem(itemID: String) async throws {
        let (message, item) = try await mailRow(itemID)
        guard item.status == .pending else { return }
        let now = ctx.now()
        try await db.transaction { db in
            guard var row = try db.mailItem(id: item.id) else { throw MailOperationError.itemNotFound(item.id) }
            row.status = .skipped
            try db.upsertMailItem(row, now: now)
            let items = try db.mailItems(messagePK: message.pk)
            try db.modifyMailMessage(pk: message.pk, now: now) { m in
                MailMergeState.settle(&m, items: items, now: now, userAction: true)
            }
        }
    }

    /// 「忽略」: the card leaves 待处理 (still under 已忽略). An AI triage on its way — queued,
    /// running, held, failed, limited or needs-login — is withdrawn before anything is sent
    /// (`MailTriageCoordinator.withdraw`: the lane job is cancelled, today's count given back) and
    /// the triage goes back to `none`, so a reopened card offers 「让 AI 分析」 again and nothing
    /// re-runs by itself. A consent given for it is dropped (asked again after a reopen);
    /// `awaitingConsent` stays as it is.
    package func dismissMail(messageID: String) async throws {
        let message = try await mailCard(messageID)
        let now = ctx.now()
        try await db.modifyMailMessage(pk: message.pk, now: now) { m in
            m.state = .dismissed
            m.snoozedUntil = nil
            m.userTouched = true
            if m.handledAt == nil { m.handledAt = now }
            if MailTriageCoordinator.pendingStates.contains(m.triageState) {
                m.triageState = .none
                m.triageNotBefore = nil
                m.triageError = nil
            }
            m.triageConsented = false
            m.triageConsentProvider = nil
        }
        await mailTriage.withdraw(messagePK: message.pk)
    }

    /// Back to 待处理 (from 已忽略 / 无阅读需求 / 已处理 / 稍后).
    package func reopenMail(messageID: String) async throws {
        let message = try await mailCard(messageID)
        try await db.modifyMailMessage(pk: message.pk, now: ctx.now()) { m in
            m.state = .pending
            m.snoozedUntil = nil
            m.userTouched = true
            m.handledAt = nil
        }
    }

    /// 「稍后」 until `until` (明天 / 下周一 / 自定义); `unsnoozeDue()` brings it back.
    package func snoozeMail(messageID: String, until: Date) async throws {
        let message = try await mailCard(messageID)
        try await db.modifyMailMessage(pk: message.pk, now: ctx.now()) { m in
            m.state = .snoozed
            m.snoozedUntil = until
            m.userTouched = true
            m.handledAt = nil
        }
    }

    /// Snoozed cards whose time has come go back to 待处理. Returns how many (call on launch,
    /// app activation and every sync tick).
    @discardableResult
    package func unsnoozeDue() async throws -> Int {
        try await db.wakeSnoozedMail(now: ctx.now())
    }

    // MARK: Private

    private func mailCard(_ messageID: String) async throws -> MailMessage {
        guard let m = try await db.mailMessage(id: messageID) else { throw MailOperationError.messageNotFound(messageID) }
        return m
    }

    private func mailRow(_ itemID: String) async throws -> (MailMessage, MailItem) {
        guard let item = try await db.mailItem(id: itemID) else { throw MailOperationError.itemNotFound(itemID) }
        guard let m = try await db.mailMessage(pk: item.messagePK) else {
            throw MailOperationError.messageNotFound(String(item.messagePK))
        }
        return (m, item)
    }

    private func touchMail(_ pk: Int64) async throws {
        try await db.modifyMailMessage(pk: pk, now: ctx.now()) { $0.userTouched = true }
    }

    /// An `in_library` row whose paper is still live → linked (annotation with the user's options).
    private func linkIfInLibrary(_ item: MailItem, message: MailMessage, options: MailMergeOptions,
                                 userAction: Bool) async throws -> String? {
        guard item.pdfState == .inLibrary, let id = item.paperID, let paper = try await db.paper(id: id), paper.isLive else {
            return nil
        }
        let settings = await ctx.settings()
        let annotation = mailAnnotation(message: message, item: item, options: options, settings: settings)
        try await MailItemLinker.link(itemIDs: [item.id], messagePK: message.pk, to: paper, status: .linked,
                                      annotation: annotation, userAction: userAction, ctx: ctx)
        return paper.id
    }

    private func markNeedsPDF(_ item: MailItem, error: String?, userAction: Bool) async throws {
        let now = ctx.now()
        try await db.transaction { db in
            guard var row = try db.mailItem(id: item.id) else { return }
            row.pdfState = .needsPDF
            row.downloadError = error
            try db.upsertMailItem(row, now: now)
            if userAction { try db.modifyMailMessage(pk: row.messagePK, now: now) { $0.userTouched = true } }
        }
    }

    /// Ingests rows whose PDF sits in the card's attachment folder. A row whose copy is gone goes
    /// back to `needs_pdf` (`strict`: and throws `.fileMissing` — a single-row merge).
    private func mergeStored(_ items: [MailItem], message: MailMessage, options: MailMergeOptions,
                             userAction: Bool, strict: Bool = false) async throws -> [String: String] {
        let root = paths.mailFiles
        var entries: [MailImportEntry] = []
        for item in items {
            guard let rel = item.pdfPath, let url = MailAttachmentFiles.url(rel, root: root),
                  await BlockingIO.run({ FileManager.default.fileExists(atPath: url.path) }) else {
                try await markNeedsPDF(item, error: nil, userAction: userAction)
                if strict { throw MailOperationError.fileMissing(itemID: item.id) }
                continue
            }
            entries.append(MailImportEntry(item: item, intake: .file(url), key: url, storedCopy: rel, userFile: false))
        }
        guard !entries.isEmpty else { return [:] }
        return try await mergeFiles(entries, message: message, options: options, userAction: userAction)
    }

    /// One import batch (origin `.mail`, link policy) → rows merged / linked / waiting again.
    private func mergeFiles(_ entries: [MailImportEntry], message: MailMessage, options: MailMergeOptions,
                            userAction: Bool) async throws -> [String: String] {
        let settings = await ctx.settings()
        var annotations: [URL: ImportAnnotation] = [:]
        for e in entries {
            // A paper in 最近删除 is ours to handle below: intake neither links nor toasts it.
            annotations[e.key] = mailAnnotation(message: message, item: e.item, options: options, settings: settings,
                                                leaveDeletedAlone: true)
        }
        let ai: BatchAIPolicy = options.readWithAI
            ? (entries.count > IntakeActor.holdThreshold ? .queueHeld : .queueAll) : .skip
        for e in entries { MailMergeInFlight.shared.insert(e.item.id) }
        MailMergeInFlight.shared.insertMessage(message.id)
        defer {
            for e in entries { MailMergeInFlight.shared.remove(e.item.id) }
            MailMergeInFlight.shared.removeMessage(message.id)
        }

        let summary = await intake.ingest(entries.map(\.intake),
                                          options: ImportOptions(origin: .mail, ai: ai, annotations: annotations))
        var byKey: [String: ImportItemResult] = [:]
        for r in summary.items { if let s = r.source { byKey[ImportOptions.key(s)] = r } }

        let lang = settings.lang
        let results = entries.map { e in (e, byKey[ImportOptions.key(e.key)]) }
        // The bytes are a paper in 最近删除 (intake left it alone: no provenance, no toast): the
        // user's merge restores it and applies the merge's choices to it (provenance included);
        // an automatic merge leaves the row waiting — stored copy kept — with a note and never
        // touches the trashed paper. A merge never reports success while its paper stays deleted.
        var waitingDeleted: [String: String] = [:]          // item id → why it still waits
        var restoredIDs: Set<String> = []
        for (e, result) in results {
            guard let id = result?.outcome.paperID, let paper = try await db.paper(id: id),
                  paper.isDeleted || restoredIDs.contains(id) else { continue }
            guard userAction else {
                waitingDeleted[e.item.id] = MailOpsText.inRecentlyDeleted(lang)
                continue
            }
            do {
                if !restoredIDs.contains(id) {
                    _ = try await restore(paperID: id)
                    restoredIDs.insert(id)
                }
                if let annotation = annotations[e.key] {
                    try await IntakeActor.link(paper.pk, annotation: annotation, ctx: ctx)
                }
            } catch {
                Log.importer.error("mail merge: a paper in Recently Deleted was not restored (\(String(describing: type(of: error)), privacy: .public))")
                waitingDeleted[e.item.id] = MailOpsText.restoreFailed(lang)
            }
        }
        let now = ctx.now()
        let waiting = waitingDeleted
        let (produced, removed) = try await db.transaction { db -> ([String: String], [String]) in
            var produced: [String: String] = [:]
            var removed: [String] = []
            for (e, result) in results {
                guard var row = try db.mailItem(id: e.item.id) else { continue }
                if let note = waiting[e.item.id] {
                    row.downloadError = note                    // copy kept for a later merge
                } else if let paperID = result?.outcome.paperID {
                    if case .added = result?.outcome { row.status = .merged } else { row.status = .linked }
                    row.paperID = paperID
                    row.pdfState = .inLibrary
                    row.downloadError = nil
                    if let copy = row.pdfPath { removed.append(copy) }
                    row.pdfPath = nil
                    produced[row.id] = paperID
                } else {
                    // The file was not a usable PDF (or the import failed): the row waits for one.
                    let reason = result?.outcome.failureReason ?? MailOpsText.importFailed(lang)
                    if e.storedCopy != nil || row.pdfState == .hasPDF {
                        if let copy = row.pdfPath { removed.append(copy) }
                        row.pdfPath = nil
                        row.pdfSHA256 = nil
                        row.pdfBytes = nil
                        row.pdfState = .needsPDF
                    }
                    row.downloadError = reason
                }
                try db.upsertMailItem(row, now: now)
            }
            let items = try db.mailItems(messagePK: message.pk)
            try db.modifyMailMessage(pk: message.pk, now: now) { m in
                guard userAction || m.isOpen else { return }
                MailMergeState.settle(&m, items: items, now: now, userAction: userAction)
            }
            return (produced, removed)
        }
        let root = paths.mailFiles
        if !removed.isEmpty { await BlockingIO.run { MailAttachmentFiles.remove(removed, root: root) } }
        try await linkSiblings(of: message.pk, papers: Set(produced.values), userAction: userAction)
        return produced
    }

    /// Other rows of the same card naming a paper the merge just produced (an attachment plus a
    /// DOI link to it, say) are linked right away — silently, the user is on this card.
    private func linkSiblings(of messagePK: Int64, papers paperIDs: Set<String>, userAction: Bool) async throws {
        guard !paperIDs.isEmpty else { return }
        let rows = try await db.mailItems(messagePK: messagePK).filter {
            $0.status == .pending && !MailMergeInFlight.shared.contains($0.id)
        }
        guard !rows.isEmpty else { return }
        for id in paperIDs.sorted() {
            guard let paper = try await db.paper(id: id), paper.isLive else { continue }
            let dois = Set(Database.sameWorkDOIs(paper.ids.doi) + Database.sameWorkDOIs(paper.ids.publishedDOI))
            let arxiv = paper.ids.arxivID?.lowercased()
            let same = rows.filter { row in
                let rowDOIs = Database.sameWorkDOIs(row.ids.doi) + Database.sameWorkDOIs(row.ids.publishedDOI)
                if rowDOIs.contains(where: dois.contains) { return true }
                if let arxiv, let a = row.ids.arxivID?.lowercased(), a == arxiv { return true }
                return false
            }
            guard !same.isEmpty else { continue }
            try await MailItemLinker.link(itemIDs: same.map(\.id), messagePK: messagePK, to: paper, status: .linked,
                                          annotation: nil, userAction: userAction, ctx: ctx)
        }
    }

    /// The annotation every file of a card's merge carries (`item` is kept for the call sites).
    private func mailAnnotation(message: MailMessage, item: MailItem, options: MailMergeOptions,
                                settings: EngineSettings, leaveDeletedAlone: Bool = false) -> ImportAnnotation {
        let person = message.senderKind == .advisor || message.senderKind == .person || message.senderKind == .manual
        // Confidential mail (a manuscript under review…) is held the same way whoever sent it —
        // an editor's invitation from an alert preset's domain (@*.nature.com) included.
        let holdAI = person || MailHeuristics.isConfidential(message)
        return ImportAnnotation(
            provenance: .email(message, addedAt: ctx.now()),
            priority: options.priority, pinnedDeadline: options.pinDeadline, category: options.category,
            notesPrefill: loadMailSettings().prefillNotes
                ? MailOpsText.notesPrefill(message, lang: settings.lang, calendar: ctx.calendar) : nil,
            sameWorkPolicy: .link,
            aiPriority: options.readWithAI && message.senderKind == .advisor ? 1 : 0,
            // A person's PDF may be unpublished work, however it arrived — attachment,
            // link, a file dropped on the row, an auto-merge download; so may a confidential
            // email's. Identified (DOI / arXiv) papers are released by EnrichActor.
            holdAIUnlessIdentified: holdAI, leaveDeletedAlone: leaveDeletedAlone,
            // The email's held titles stay held in the library (confidential mail; a person's or
            // an alert domain's non-list mail before 「让 AI 分析」): identifier lookups only.
            identifierLookupsOnly: !MailSyncActor.mayLookUpTitles(message))
    }

    /// The URL a row may be downloaded from: only locally extracted (never AI-returned) arXiv,
    /// bioRxiv / medRxiv and direct-PDF links, on the unwrapped target (Safe Links and other
    /// wrappers removed). Whether it may be fetched is `DownloadPolicy`'s call.
    static func mailDownloadURL(_ item: MailItem) -> URL? {
        guard item.foundBy != .ai else { return nil }
        let unwrapped = item.url.flatMap(URL.init(string:)).map { LinkUnwrapper.unwrap($0).absoluteString } ?? item.url
        let candidate = MailCandidate(cand: item.cand, origin: item.origin, title: item.title, authors: item.authors,
                                      ids: item.ids, url: unwrapped, urlOriginal: item.urlOriginal, host: item.host,
                                      pdfState: item.pdfState)
        guard let url = PaperLinkClassifier.pdfURL(for: candidate), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", URLImporter.pdfURL(for: url) != nil else { return nil }
        return url
    }

    /// Download → stored copy (`has_pdf`), an existing paper (`in_library`), or `needs_pdf` + why.
    private func downloadMailItemReturning(_ item: MailItem, message: MailMessage,
                                           userAction: Bool) async throws -> MailItem {
        let lang = (await ctx.settings()).lang
        guard let url = Self.mailDownloadURL(item) else {
            try await markNeedsPDF(item, error: MailOpsText.noPDFLink(lang), userAction: userAction)
            return try await db.mailItem(id: item.id) ?? item
        }
        let policy: DownloadPolicy = userAction ? .mailUserAction : .mailAutomatic
        guard policy.allows(url) else {
            // Never fetched: a local / private address (the user's own click too), or a host an
            // automatic download may not reach — that row keeps waiting for the user.
            guard userAction else { return item }
            try await markNeedsPDF(item, error: MailOpsText.privateAddress(lang), userAction: userAction)
            return try await db.mailItem(id: item.id) ?? item
        }
        let now = ctx.now()
        try await db.transaction { db in
            guard var row = try db.mailItem(id: item.id) else { throw MailOperationError.itemNotFound(item.id) }
            row.pdfState = .downloading
            row.downloadError = nil
            try db.upsertMailItem(row, now: now)
            if userAction { try db.modifyMailMessage(pk: row.messagePK, now: now) { $0.userTouched = true } }
        }
        MailMergeInFlight.shared.insert(item.id)
        defer { MailMergeInFlight.shared.remove(item.id) }

        let importer = URLImporter(downloader: await intake.pdfDownloader())
        let outcome = await importer.fetch(url, incoming: paths.incoming, policy: policy) { _ in }
        let root = paths.mailFiles, incoming = paths.incoming
        let relative = "\(message.id)/\(item.id).pdf"
        var stored: (sha: String, bytes: Int64)?
        var failure: String?
        var stillDownloadable = false
        switch outcome {
        case .downloaded(let file, _):
            do {
                stored = try await BlockingIO.run { () throws -> (String, Int64) in
                    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                    guard LibraryPaths.relativePath(of: file, root: incoming) != nil,
                          let dest = MailAttachmentFiles.url(relative, root: root) else { throw FileOpsError.io("bad path") }
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: file, to: dest)
                    return (try FileOps.sha256(of: dest), FileOps.fileSize(dest) ?? 0)
                }
            } catch {
                Log.importer.error("mail download: storing failed: \(FileOps.classify(error).description, privacy: .public)")
                failure = MailOpsText.downloadFailed(status: nil, lang)
            }
        case .notPDFLink:
            failure = MailOpsText.noPDFLink(lang)
        case .notPDF:
            failure = Self.isPreprintHost(url) ? MailOpsText.biorxivBlocked(lang) : MailOpsText.notPDF(lang)
        case .httpError(let status):
            failure = Self.isPreprintHost(url) && (status == 403 || status == 503)
                ? MailOpsText.biorxivBlocked(lang) : MailOpsText.downloadFailed(status: status, lang)
        case .failed(let detail):
            Log.importer.info("mail download failed: \(detail, privacy: .public)")
            failure = MailOpsText.downloadFailed(status: nil, lang)
        case .blocked:
            // A redirect left the allowed hosts. Automatic: the user may still fetch it by hand.
            stillDownloadable = !userAction
            failure = userAction ? MailOpsText.privateAddress(lang) : MailOpsText.notAutomatic(lang)
        }

        var hit: Paper?
        if let stored, let p = try await db.paper(sha256: stored.sha), p.isLive { hit = p }
        let done = ctx.now()
        let (stored_, existing, failure_, retry) = (stored, hit, failure, stillDownloadable)
        let saved = try await db.transaction { db -> MailItem in
            let stored = stored_, failure = failure_
            guard var row = try db.mailItem(id: item.id) else { throw MailOperationError.itemNotFound(item.id) }
            if let stored {
                row.pdfSHA256 = stored.sha
                row.pdfBytes = stored.bytes
                row.downloadError = nil
                if let existing {
                    row.pdfState = .inLibrary
                    row.paperID = existing.id
                    row.pdfPath = nil
                } else {
                    row.pdfState = .hasPDF
                    row.pdfPath = relative
                }
            } else {
                row.pdfState = retry ? .downloadable : .needsPDF
                row.downloadError = failure
            }
            return try db.upsertMailItem(row, now: done)
        }
        if existing != nil { await BlockingIO.run { MailAttachmentFiles.remove([relative], root: root) } }
        return saved
    }

    private static func isPreprintHost(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.hasSuffix("biorxiv.org") || host.hasSuffix("medrxiv.org")
    }
}

/// One file of a card's import batch.
private struct MailImportEntry: Sendable {
    var item: MailItem
    var intake: IntakeItem
    var key: URL                    // the annotation / result key (the item's URL)
    var storedCopy: String?         // relative path under AppPaths.mailFiles (our copy)
    var userFile: Bool              // the user's own file (never touched)
}

// MARK: - zh/en strings

enum MailOpsText {
    static func t(_ l: UILang, _ zh: String, _ en: String) -> String { l == .zh ? zh : en }

    static func noPDFLink(_ l: UILang) -> String { t(l, "没有可直接下载的 PDF 链接", "No direct PDF link") }
    static func notPDF(_ l: UILang) -> String { t(l, "链接内容不是 PDF", "The link didn't return a PDF") }
    static func biorxivBlocked(_ l: UILang) -> String {
        t(l, "bioRxiv 拒绝自动下载，请在浏览器下载后拖入", "bioRxiv refused the automatic download — download it in the browser and drop it here")
    }
    static func downloadFailed(status: Int?, _ l: UILang) -> String {
        guard let status else { return t(l, "下载失败", "Download failed") }
        return t(l, "下载失败（\(status)）", "Download failed (\(status))")
    }
    static func importFailed(_ l: UILang) -> String { t(l, "导入失败", "Import failed") }
    static func privateAddress(_ l: UILang) -> String {
        t(l, "链接指向本地或内网地址，PaperDeck 不会下载", "The link points to a local or private network address — PaperDeck doesn't download it")
    }
    static func notAutomatic(_ l: UILang) -> String {
        t(l, "链接跳转到其他网站，未自动下载 · 请点「下载」", "Not downloaded automatically (the link leads to another site) — use Download")
    }
    static func inRecentlyDeleted(_ l: UILang) -> String {
        t(l, "这篇论文在「最近删除」中 · 合并会恢复它", "This paper is in Recently Deleted — merging restores it")
    }
    static func restoreFailed(_ l: UILang) -> String {
        t(l, "无法从「最近删除」恢复这篇论文", "Couldn't restore this paper from Recently Deleted")
    }

    /// The notes prefill: 「来自邮件：<from> — <subject>（9/29）」 plus the triage summary on a
    /// second line. Untrusted text, so each line is flattened and Markdown-escaped (notes.md
    /// stays inert).
    static func notesPrefill(_ m: MailMessage, lang: UILang, calendar: Calendar) -> String {
        let name = m.fromName.map { MailInertText.clip($0, 80) }.flatMap { $0.isEmpty ? nil : $0 } ?? m.fromAddress
        let subject = MailInertText.clip(m.subject, 160)
        let c = calendar.dateComponents([.month, .day], from: m.receivedAt)
        let date = "\(c.month ?? 0)/\(c.day ?? 0)"
        let head = lang == .zh ? "来自邮件：\(name) — \(subject)（\(date)）" : "From email: \(name) — \(subject) (\(date))"
        var lines = [SidecarWriter.markdownText(head)]
        if let summary = m.triage.map({ MailInertText.clip($0.summary, 300) }), !summary.isEmpty {
            lines.append(SidecarWriter.markdownText(summary))
        }
        return lines.joined(separator: "\n")
    }
}
