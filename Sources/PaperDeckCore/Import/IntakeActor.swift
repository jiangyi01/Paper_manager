import Foundation

/// The fast half of the import pipeline (DESIGN §6.1): receive → ingest → extract →
/// dedupe → commit. A drop becomes a card (≈DDL + heuristic checklist) in about a second,
/// and the source is read only inside the drop's authorization window (§3.6): one
/// coordinated read hashes, dedupes and clones it, and the source is never opened again.
///
/// Files of a batch move through the stages concurrently: every local file is hashed and
/// cloned promptly (a few at a time, ahead of the slower extraction, so a big folder drop is
/// ingested while its authorization is fresh); cloud placeholders wait for materialization
/// without holding a slot, so they never block local files; PDFKit extraction is bounded
/// separately; and commits are strictly serialized, so queue ranks and placements see every
/// earlier commit.
/// Metadata, filing and the AI decision continue in `EnrichActor`; nothing here awaits
/// metadata lookups.
package actor IntakeActor {
    /// Folder imports stop collecting after this many PDFs.
    package static let maxFolderPDFs = 500
    /// Local files in their coordinated read (head check, hash, clone) at the same time.
    package static let maxParallelIngests = 4
    /// PDFKit extractions at the same time.
    package static let maxParallelExtractions = 3
    /// `.automatic` AI: a batch with more PDFs than this is held for confirmation (§6.2).
    package static let holdThreshold = 3
    /// `.automatic` scheduling: a batch with more PDFs than this is placed sequentially at low priority.
    package static let sequentialThreshold = 10
    /// Batches up to this size get one toast per paper; larger ones one summary toast.
    package static let perPaperToastLimit = 3

    let ctx: EngineContext
    let enrich: EnrichActor
    let extractor: any PDFExtracting
    private var downloaderOverride: (any PDFDownloading)?
    private var sessionDownloader: URLSessionPDFDownloader?
    private let trashSource: @Sendable (URL) -> Bool

    private var pending: [String: PendingWork] = [:]
    /// Parked files the duplicate review dropped, kept for the undo window (then deleted).
    private var discarded: [String: PendingWork] = [:]
    /// Replacements the duplicate review applied, undoable for the undo window.
    private var replacedRecords: [String: ReplacedRecord] = [:]
    private var commitBusy = false
    private var commitWaiters: [CheckedContinuation<Void, Never>] = []
    private var slotsInUse: [SlotKind: Int] = [:]
    private var slotWaiters: [SlotKind: [CheckedContinuation<Void, Never>]] = [:]
    private var abortedBatches: Set<String> = []

    /// - Parameters:
    ///   - downloader: transport for dropped links (default: an ephemeral URLSession, created on first use).
    ///   - trashSource: move mode's "move the original to the Trash" (tests substitute it).
    package init(ctx: EngineContext, enrich: EnrichActor, extractor: any PDFExtracting = PDFExtractor(),
                 downloader: (any PDFDownloading)? = nil,
                 trashSource: @escaping @Sendable (URL) -> Bool = { FileOps.trash($0) }) {
        self.ctx = ctx; self.enrich = enrich; self.extractor = extractor
        self.downloaderOverride = downloader; self.trashSource = trashSource
    }

    // MARK: - Batch

    /// Receive → ingest → extract → dedupe → commit for every item; returns when all
    /// items reached a terminal row state (enrichment continues in the background).
    package func ingest(_ items: [IntakeItem], options: ImportOptions) async -> ImportBatchSummary {
        let batchID = UUID().uuidString.lowercased()
        let settings = await ctx.settings()
        let lang = settings.lang
        let incoming = ctx.paths.incoming, library = ctx.paths.library
        let expansion = await BlockingIO.run {
            Self.expand(items, incoming: incoming, library: library, lang: lang)
        }
        for toast in expansion.toasts { ctx.events.send(.toast(toast)) }

        let plan = Self.plan(batchID: batchID, count: expansion.candidates.count, options: options, settings: settings)
        for c in expansion.candidates {
            let stage: ImportRowUpdate.Stage
            if case .remote = c.source { stage = .downloading(fraction: nil) } else { stage = .receiving }
            emit(ImportRowUpdate(id: c.rowID, batchID: batchID, displayName: c.displayName, stage: stage))
        }
        let cloud = expansion.candidates.filter(\.needsCloudDownload)
        if !cloud.isEmpty {
            ctx.events.send(.toast(Toast(kind: .info, message: IntakeText.cloudWaiting(
                cloud.count, provider: Self.cloudProvider(cloud.first?.localURL), lang))))
        }

        var summary = ImportBatchSummary(batchID: batchID)
        var keptOriginals = 0
        var addedPapers: [Paper] = []
        var results: [(index: Int, result: ImportItemResult)] = []
        var reviews: [(index: Int, id: String)] = []          // duplicate decisions this batch asks for
        await withTaskGroup(of: (Int, FileOutcome).self) { group in
            for (index, c) in expansion.candidates.enumerated() {
                group.addTask { (index, await self.process(c, plan: plan)) }
            }
            for await (index, outcome) in group {
                let source = expansion.candidates[index].itemURL
                switch outcome {
                case .added(let paper, let held, let keptOriginal, let review):
                    addedPapers.append(paper)
                    if held { summary.heldForAI.append(paper.id) }
                    if keptOriginal { keptOriginals += 1 }
                    if let review, review.band != .possible { reviews.append((index, review.id)) }
                    results.append((index, ImportItemResult(source: source, outcome: .added(paperID: paper.id))))
                case .duplicate(let id, let linked):
                    summary.duplicates += 1
                    results.append((index, ImportItemResult(source: source, outcome: .duplicate(paperID: id), linked: linked)))
                case .sameWork(let id, let linked, let review):
                    if let review { reviews.append((index, review.id)) }
                    results.append((index, ImportItemResult(source: source, outcome: .sameWork(existingPaperID: id),
                                                            linked: linked)))
                case .rejected(let reason):
                    summary.rejected += 1
                    results.append((index, ImportItemResult(source: source, outcome: .rejected(reason: reason))))
                case .failed(let reason):
                    summary.failed += 1
                    results.append((index, ImportItemResult(source: source, outcome: .failed(reason: reason))))
                }
            }
        }
        summary.items = results.sorted { $0.index < $1.index }.map(\.result)
        abortedBatches.remove(batchID)
        let roots = expansion.cleanupRoots
        if !roots.isEmpty { await BlockingIO.run { for root in roots { Self.removeIncoming(root, incoming: incoming) } } }

        addedPapers.sort { $0.queueRank < $1.queueRank }
        summary.added = addedPapers.map(\.id)
        summary.lastDeadline = addedPapers.compactMap(\.deadline).max()
        if !plan.perPaperToasts, !addedPapers.isEmpty {
            let chip = summary.lastDeadline.map { chipText($0, provisional: true, lang: lang) }
            ctx.events.send(.toast(Toast(kind: .success, message: IntakeText.addedBatch(addedPapers.count, lastChip: chip, lang))))
        }
        if keptOriginals > 0 {
            ctx.events.send(.toast(Toast(kind: .info, message: IntakeText.originalsKept(keptOriginals, lang))))
        }
        // One review toast for the whole batch instead of one per file (dive-dedupe §6.3).
        if plan.dedupe.enabled, !plan.perPaperToasts, !reviews.isEmpty {
            let first = reviews.min { $0.index < $1.index }!.id
            ctx.events.send(.toast(Toast(id: "dup-batch-" + batchID, kind: .info,
                                         message: DupExplainer.batchToast(reviews.count, lang: lang),
                                         buttons: [.init(title: DupExplainer.reviewButton(lang),
                                                         action: .openDuplicateReview(id: first))])))
        }
        if plan.dedupe.enabled, !reviews.isEmpty, let open = try? await ctx.db.openDupReviewCount() {
            ctx.events.send(.dedupe(.openCount(open)))
        }
        ctx.events.send(.batchFinished(summary))
        return summary
    }

    /// The user's answer to a "same work already in library" toast. Replace: the old PDF is
    /// parked in `.recently-deleted/.replaced/` (recoverable; purged with 最近删除 after 30
    /// days), the new file takes the paper's folder and PDF name, file facts and text are
    /// refreshed, and checklist, DDL, notes and card are kept; when the new file is a newer
    /// version (a journal PDF over its preprint) the paper also adopts its DOI — the old one stays
    /// an alias — and its metadata is looked up again. Ignore: the staged copy is deleted.
    /// Unknown ids are ignored (pending answers live in memory; Maintenance removes stale
    /// `.partial` files). The file's duplicate review, if any, is closed with that choice.
    package func resolvePending(pendingID: String, replace: Bool) async {
        guard let w = pending[pendingID] else { return }
        switch await applyParked(pendingID: pendingID, replace ? .replace : .discard(keepForUndo: false)) {
        case .replaced: await closeReview(w.reviewID, choice: "keep_new")
        case .discarded: await closeReview(w.reviewID, choice: "skip")
        // The earlier paper was deleted meanwhile (the file became a paper of its own) or the
        // replace failed: the question no longer stands — nothing was kept in its place.
        default: await closeReview(w.reviewID, choice: nil)
        }
    }

    /// What the duplicate review does with a parked file (`Engine.resolveDuplicate`).
    package enum ParkedAction: Sendable, Equatable {
        /// Into the existing paper's place (the toast's 「替换并保留清单」).
        case replace
        /// Dropped; `keepForUndo` keeps the copy for `UndoToken.lifetime` (`restoreDiscarded`).
        case discard(keepForUndo: Bool)
        /// Committed as a paper of its own (the existing one is in Recently Deleted, or a
        /// different version the user keeps); `stripIdentity` drops the ids it shares (a
        /// supplement printing the paper's DOI); `pair` is the user's decision about the two,
        /// written in the insert transaction.
        case commitAsNew(stripIdentity: Bool, pair: DupPairIntent? = nil)
        /// Stored as `<paper folder>/supplements/<name>.pdf` of the existing paper.
        case attachSupplement
    }

    package enum ParkedOutcome: Sendable, Equatable {
        /// `undoID`: `undoReplace(id:)` puts the old file and facts back within the undo window.
        case replaced(Paper, undoID: String)
        case discarded
        case committed(Paper)
        /// The stored file's path relative to the library root.
        case attached(paperID: String, relativePath: String)
        /// No such parked file (answered already, or lost with a relaunch).
        case gone
        case failed(String)
    }

    /// Applies `action` to the parked file `pendingID` (see `ParkedAction`). Rows and toasts as
    /// for the toast's answers; the review itself is the caller's.
    package func applyParked(pendingID: String, _ action: ParkedAction) async -> ParkedOutcome {
        guard let w = pending.removeValue(forKey: pendingID) else { return .gone }
        let lang = (await ctx.settings()).lang
        switch action {
        case .discard(let keep):
            var row = w.row
            row.stage = .duplicate(paperID: w.existingID)
            emit(row)
            if keep {
                discarded[pendingID] = w
                let lifetime = UndoToken.lifetime + 5
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(lifetime))
                    await self?.dropDiscarded(pendingID)
                }
            } else {
                let partial = w.partial
                await BlockingIO.run { try? FileManager.default.removeItem(at: partial) }
                InFlightPartials.shared.remove(partial)
            }
            return .discarded
        case .commitAsNew(let strip, let pair):
            var staged = w.staged
            if strip {
                staged.ids = PaperIDs()
                staged.dupSubject = nil              // recomputed without the identifiers
            }
            await lockCommit()
            let outcome = await commitLocked(staged, row: w.row, plan: w.plan, skipIdentity: true, pair: pair)
            unlockCommit()
            await finishCommit(outcome, staged: staged, row: w.row, plan: w.plan)
            InFlightPartials.shared.remove(w.partial)
            if case .committed(let paper, _) = outcome { return .committed(paper) }
            return .failed(IntakeText.reasonLibraryWrite(lang))
        case .attachSupplement:
            return await attach(w, lang: lang)
        case .replace:
            return await replaceParked(w, lang: lang)
        }
    }

    /// Back into the pending map: a discard (within its undo window) is undone.
    package func restoreDiscarded(pendingID: String) -> Bool {
        guard let w = discarded.removeValue(forKey: pendingID) else { return false }
        pending[pendingID] = w
        return true
    }

    private func dropDiscarded(_ pendingID: String) async {
        guard let w = discarded.removeValue(forKey: pendingID) else { return }
        let partial = w.partial
        await BlockingIO.run { try? FileManager.default.removeItem(at: partial) }
        InFlightPartials.shared.remove(partial)
    }

    /// The replace of `w` (the toast's 「替换并保留清单」, the review's "Keep the new one").
    private func replaceParked(_ w: PendingWork, lang: UILang) async -> ParkedOutcome {
        await lockCommit()
        guard let existing = try? await ctx.db.paper(pk: w.existingPK), existing.isLive else {
            // The old paper was deleted meanwhile: the new file becomes a paper of its own — never
            // compared with that paper again (it would be parked again under a new id, asking the
            // same question in a loop).
            let outcome = await commitLocked(w.staged, row: w.row, plan: w.plan, skipIdentity: true)
            unlockCommit()
            await finishCommit(outcome, staged: w.staged, row: w.row, plan: w.plan)
            abortedBatches.remove(w.plan.batchID)          // that batch finished long ago
            if case .sameWork = outcome {} else { InFlightPartials.shared.remove(w.partial) }
            if case .committed(let paper, _) = outcome { return .committed(paper) }
            return .failed(IntakeText.reasonLibraryWrite(lang))
        }
        defer {
            unlockCommit()
            InFlightPartials.shared.remove(w.partial)
        }
        var row = w.row
        if let hit = try? await ctx.db.paper(sha256: w.staged.sha256) {
            let partial = w.partial
            await BlockingIO.run { try? FileManager.default.removeItem(at: partial) }
            row.stage = .duplicate(paperID: hit.id)
            emit(row)
            return .failed(IntakeText.alreadyInLibrary(hit.title, lang))
        }

        let pdf = ctx.pdfURL(existing)
        let folderName = ctx.folderURL(existing).lastPathComponent
        let paths = ctx.paths, parkedAt = ctx.now()
        let partial = w.partial
        let texts = ctx.texts, thumbs = ctx.thumbs, id = existing.id
        // What undo puts back (in memory for the undo window only).
        let previous = await BlockingIO.run { ((try? texts.load(id: id)) ?? nil, try? Data(contentsOf: thumbs.cardURL(for: id))) }
        let backup: URL?
        do {
            backup = try await BlockingIO.run {
                try Self.swapPDF(current: pdf, folderName: folderName, paths: paths, at: parkedAt, replacement: partial)
            }
        } catch {
            let e = FileOps.classify(error)
            Log.importer.error("replace \(existing.pk) failed: \(e.description, privacy: .public)")
            await BlockingIO.run { try? FileManager.default.removeItem(at: partial) }
            let reason = IntakeText.commitReason(.file(e), lang)
            row.stage = .failed(reason: reason)
            emit(row)
            ctx.events.send(.toast(Toast(kind: .error, message: IntakeText.importFailed(w.staged.originalName, reason: reason, lang))))
            return .failed(reason)
        }

        let staged = w.staged
        let text = staged.extracted?.fullText ?? ""
        await BlockingIO.run {
            do { try texts.save(text, id: id) } catch {
                Log.importer.error("text cache for \(id, privacy: .public) failed: \(FileOps.classify(error).description, privacy: .public)")
            }
            if let jpeg = staged.extracted?.cardThumbnailJPEG { try? thumbs.save(cardJPEG: jpeg, id: id) } else { thumbs.delete(id: id) }
        }
        let now = ctx.now()
        let pk = existing.pk
        // A newer version (journal over preprint, arXiv v3 over v1) brings its identifiers along —
        // with the duplicate check on. Off, the replace keeps the paper's ids, as before the check.
        let dedupeOn = w.plan.dedupe.enabled
        let adopt = dedupeOn && Self.adoptsIdentity(new: staged.ids, existing: existing)
        // The library's row was a notice, a comment, a review file or a supplement printing this
        // paper's identifier, and the new file is the paper: its title comes along too.
        let (stagedTitle, stagedRank) = staged.extracted?.bestLocalTitle ?? (Self.title(fromFileName: staged.originalName), .filename)
        let takeTitle = dedupeOn && Self.takesTitle(existing: existing, newTitle: stagedTitle, newRank: stagedRank,
                                                    newFileName: staged.originalName)
        // An annotated file (an email's) keeps its email's holds and provenance in the paper.
        let annotation = staged.annotation
        let sourcesBefore = annotation?.provenance == nil ? nil : try? await ctx.db.paperSources(paperPK: pk)
        let adopted: Paper
        do {
            adopted = try await ctx.db.transaction { db -> Paper in
                let takeDOI: Bool = try {
                    guard adopt, let doi = staged.ids.doi else { return false }
                    return try db.livePaper(holdingDOI: doi, excluding: pk) == nil
                }()
                let takeArxiv: Bool = try {
                    guard adopt, existing.ids.arxivID == nil, let arxiv = staged.ids.arxivID else { return false }
                    return try db.paperMatchingWork(doi: nil, arxivID: arxiv, publishedDOI: nil, excluding: pk) == nil
                }()
                let saved = try db.modifyPaper(pk: pk, now: now) { p in
                    p.sha256 = staged.sha256
                    p.fileSize = staged.fileSize
                    if let v = staged.ids.arxivVersion { p.ids.arxivVersion = v }
                    p.pageCount = staged.extracted?.pageCount
                    p.charCount = staged.extracted?.charCount
                    p.flags.subtract([.locked, .scanned, .unreadable, .missing])
                    p.flags.formUnion(staged.flags)
                    p.originalName = staged.originalName
                    if takeDOI, let doi = staged.ids.doi { p.ids.doi = doi.lowercased() }
                    if takeArxiv { p.ids.arxivID = staged.ids.arxivID }
                    // The journal's record (title, venue, year) replaces the preprint's on the refresh.
                    if takeDOI || takeArxiv, !p.metaUserEdited { p.metaSource = .none }
                    if takeTitle {
                        p.title = stagedTitle
                        p.titleRank = stagedRank
                    }
                    if annotation?.identifierLookupsOnly == true { p.flags.insert(.titleLookupHeld) }
                }
                try db.indexFullText(pk: pk, text: text)
                if let provenance = annotation?.provenance { try db.insertPaperSource(paperPK: pk, provenance) }
                if dedupeOn {
                    if takeDOI, let old = existing.ids.doi, old.lowercased() != staged.ids.doi?.lowercased(),
                       let token = DupKeys.doiToken(old) {
                        try db.addDupKeys(paperPK: pk, [DupKey(kind: .preprintDOI, value: token, source: .merge)])
                    }
                    try db.refreshLocalDupKeys(paperPK: pk)
                }
                try db.deleteDupFingerprint(paperPK: pk)
                return saved
            }
        } catch {
            Log.importer.error("replace \(pk): DB update failed: \(String(describing: error), privacy: .public)")
            await BlockingIO.run {
                try? FileManager.default.removeItem(at: pdf)          // the new copy
                if let backup {
                    try? FileOps.atomicRename(from: backup, to: pdf)
                    try? FileManager.default.removeItem(at: backup.deletingLastPathComponent())
                }
            }
            let reason = IntakeText.commitReason(.database, lang)
            row.stage = .failed(reason: reason)
            emit(row)
            ctx.events.send(.toast(Toast(kind: .error, message: IntakeText.importFailed(staged.originalName, reason: reason, lang))))
            return .failed(reason)
        }
        await ctx.syncSidecar(pk: pk)
        row.stage = .added(paperID: existing.id, deadline: existing.deadline, provisional: existing.provisional)
        emit(row)
        ctx.events.send(.toast(Toast(kind: .success, message: IntakeText.replaced(existing.title, lang),
                                     buttons: [.init(title: IntakeText.view(lang), action: .openPaper(id: existing.id))])))
        if adopted.metaSource == .none, adopted.ids != existing.ids {
            let enrich = self.enrich
            Task { _ = await enrich.refreshMetadata(pk: pk) }
        }
        let undoID = UUID().uuidString.lowercased()
        replacedRecords[undoID] = ReplacedRecord(work: w, pdf: pdf, backup: backup, before: existing, text: previous.0,
                                                 thumbnail: previous.1, sources: sourcesBefore)
        let lifetime = UndoToken.lifetime + 5
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(lifetime))
            await self?.forgetReplaced(undoID)
        }
        return .replaced(adopted, undoID: undoID)
    }

    /// Whether a replace adopts the new file's identifiers: it is the newer version and the
    /// metadata wasn't edited by the user.
    static func adoptsIdentity(new ids: PaperIDs, existing: Paper) -> Bool {
        guard !existing.metaUserEdited else { return false }
        let newer = VersionRank.newer(new: VersionRank.of(ids: ids, venue: nil),
                                      existing: VersionRank.of(ids: existing.ids, venue: existing.venue))
        guard newer == .new else { return false }
        if let doi = ids.doi, doi.lowercased() != existing.ids.doi?.lowercased() { return true }
        return existing.ids.arxivID == nil && ids.arxivID != nil
    }

    /// Whether a replace (or a merge) gives the kept paper the new file's title: the kept paper's
    /// title reads as a notice, a comment, a review file or a supplement — what was imported first
    /// printed the paper's identifier — and the new file's is the paper's (unless the user edited it).
    static func takesTitle(existing: Paper, newTitle: String, newRank: TitleRank, newFileName: String?) -> Bool {
        guard !existing.metaUserEdited, newRank >= .pdfAttribute,
              DedupeText.kind(title: newTitle, fileName: newFileName) == .article else { return false }
        switch DedupeText.kind(title: existing.title, fileName: existing.originalName) {
        case .notice, .comment, .review, .supplement: return true
        case .article, .generic: return false
        }
    }

    /// What a replace changed, for its undo.
    private struct ReplacedRecord: Sendable {
        var work: PendingWork
        var pdf: URL
        var backup: URL?
        var before: Paper
        var text: String?
        var thumbnail: Data?
        /// The paper's provenance before an annotated file's was added (nil: unchanged).
        var sources: [PaperProvenance]?
    }

    private func forgetReplaced(_ id: String) { replacedRecords[id] = nil }

    /// Undoes a replace within its window: the new file goes back to waiting (parked again with its
    /// review), the old PDF, text, thumbnail and file facts (and ids) come back. False when the
    /// window passed or the paper changed files since.
    package func undoReplace(id: String) async -> Bool {
        guard let r = replacedRecords.removeValue(forKey: id) else { return false }
        await lockCommit()
        defer { unlockCommit() }
        guard let current = try? await ctx.db.paper(pk: r.before.pk), current.sha256 == r.work.staged.sha256 else { return false }
        let partialDir = ctx.paths.partial, pdf = r.pdf, backup = r.backup
        let partial = partialDir.appendingPathComponent(UUID().uuidString.lowercased() + ".pdf")
        do {
            try await BlockingIO.run {
                try FileManager.default.createDirectory(at: partialDir, withIntermediateDirectories: true)
                try FileOps.atomicRename(from: pdf, to: partial)
                if let backup {
                    do { try FileOps.atomicRename(from: backup, to: pdf) } catch {
                        try? FileOps.atomicRename(from: partial, to: pdf)
                        throw error
                    }
                    try? FileManager.default.removeItem(at: backup.deletingLastPathComponent())
                }
            }
        } catch {
            Log.importer.error("undo replace \(r.before.pk) failed: \(FileOps.classify(error).description, privacy: .public)")
            return false
        }
        InFlightPartials.shared.insert(partial)
        let before = r.before, now = ctx.now()
        let texts = ctx.texts, thumbs = ctx.thumbs, id = before.id, text = r.text, thumb = r.thumbnail
        await BlockingIO.run {
            if let text { try? texts.save(text, id: id) }
            if let thumb { try? thumbs.save(cardJPEG: thumb, id: id) }
        }
        _ = try? await ctx.db.transaction { db in
            try db.modifyPaper(pk: before.pk, now: now) { p in
                p.sha256 = before.sha256; p.fileSize = before.fileSize; p.ids = before.ids
                p.pageCount = before.pageCount; p.charCount = before.charCount; p.flags = before.flags
                p.originalName = before.originalName; p.metaSource = before.metaSource
                p.title = before.title; p.titleRank = before.titleRank; p.authors = before.authors
                p.year = before.year; p.venue = before.venue; p.abstract = before.abstract
            }
            if let text { try db.indexFullText(pk: before.pk, text: text) }
            if let sources = r.sources { try db.replacePaperSources(paperPK: before.pk, sources) }
            try db.deleteDupKeys(paperPK: before.pk, source: .merge)
            try db.refreshLocalDupKeys(paperPK: before.pk)
            try db.deleteDupFingerprint(paperPK: before.pk)
        }
        await ctx.syncSidecar(pk: before.pk)
        var work = r.work
        work.staged.partial = partial
        pending[work.id] = work
        var row = work.row
        row.stage = .sameWork(existingPaperID: before.id, pendingID: work.id)
        emit(row)
        return true
    }

    /// The review's "Attach to paper": the parked file goes to `<paper folder>/supplements/`.
    private func attach(_ w: PendingWork, lang: UILang) async -> ParkedOutcome {
        guard let existing = try? await ctx.db.paper(pk: w.existingPK), existing.isLive else {
            pending[w.id] = w
            return .failed(IntakeText.reasonLibraryWrite(lang))
        }
        let folder = ctx.folderURL(existing)
        let partial = w.partial
        let name = FileNamer.inboxPDFName(originalName: w.staged.originalName)
        let library = ctx.paths.library
        do {
            let dest = try await BlockingIO.run { () throws -> URL in
                let dir = folder.appendingPathComponent(Self.supplementsFolder, isDirectory: true)
                try FileOps.createFolder(dir)
                let taken = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                let unique = FileNamer.uniqueName((name as NSString).deletingPathExtension, existing:
                    Set(taken.map { ($0 as NSString).deletingPathExtension })) + ".pdf"
                let dest = dir.appendingPathComponent(unique)
                try FileOps.atomicRename(from: partial, to: dest)
                return dest
            }
            InFlightPartials.shared.remove(partial)
            var row = w.row
            row.stage = .duplicate(paperID: existing.id)
            emit(row)
            attachedRecords[existing.id + "/" + dest.lastPathComponent] = w
            return .attached(paperID: existing.id,
                             relativePath: LibraryPaths.relativePath(of: dest, root: library) ?? dest.lastPathComponent)
        } catch {
            Log.importer.error("attach to \(existing.pk) failed: \(FileOps.classify(error).description, privacy: .public)")
            pending[w.id] = w
            return .failed(IntakeText.commitReason(.file(FileOps.classify(error)), lang))
        }
    }

    /// Supplements attached to a paper live in this subfolder of its folder (Rebuild and the
    /// reconcile pass read only the folder's top level, so they never become papers).
    package static let supplementsFolder = "supplements"

    private var attachedRecords: [String: PendingWork] = [:]

    /// Undoes an attach: the file goes back to waiting, parked again.
    package func undoAttach(paperID: String, relativePath: String) async -> Bool {
        let key = paperID + "/" + (relativePath as NSString).lastPathComponent
        guard let w = attachedRecords.removeValue(forKey: key) else { return false }
        let src = LibraryPaths.folderURL(forRelative: relativePath, library: ctx.paths.library)
        let partial = ctx.paths.partial.appendingPathComponent(UUID().uuidString.lowercased() + ".pdf")
        do {
            try await BlockingIO.run { try FileOps.atomicRename(from: src, to: partial) }
        } catch { return false }
        InFlightPartials.shared.insert(partial)
        var work = w
        work.staged.partial = partial
        pending[work.id] = work
        var row = work.row
        row.stage = .sameWork(existingPaperID: work.existingID, pendingID: work.id)
        emit(row)
        return true
    }

    /// Closes a review the toast answered (resolved with `choice`; nil: expired — the question no
    /// longer stands) and tells the UI.
    private func closeReview(_ id: String?, choice: String?) async {
        guard let id, var r = try? await ctx.db.dupReview(id: id), r.state == .open else { return }
        r.state = choice == nil ? .expired : .resolved
        r.choice = choice
        r.resolvedAt = ctx.now()
        r.pendingID = nil
        try? await ctx.db.updateDupReview(r)
        ctx.events.send(.dedupe(.reviewClosed(reviewID: id)))
        if let open = try? await ctx.db.openDupReviewCount() { ctx.events.send(.dedupe(.openCount(open))) }
    }

    /// The pending id of a parked file is still waiting (its review can still be applied).
    package func isPending(_ pendingID: String) -> Bool { pending[pendingID] != nil }

    /// What the decision sheet shows of a parked file.
    package struct ParkedFile: Sendable, Equatable {
        package var fileName: String
        package var title: String
        package var titleRank: TitleRank
        package var ids: PaperIDs
        package var pages: Int?
        package var fileSize: Int64
        package var existingPaperID: String
    }

    package func parkedFile(_ pendingID: String) -> ParkedFile? {
        guard let w = pending[pendingID] else { return nil }
        let (title, rank) = w.staged.extracted?.bestLocalTitle ?? (Self.title(fromFileName: w.staged.originalName), .filename)
        return ParkedFile(fileName: w.staged.originalName, title: title, titleRank: rank, ids: w.staged.ids,
                          pages: w.staged.extracted?.pageCount, fileSize: w.staged.fileSize, existingPaperID: w.existingID)
    }

    /// Launch recovery (Maintenance): a bare `_Inbox/<sha8>/` holding one PDF and no row is a
    /// commit interrupted between the move out of `.partial` and the insert (a crash). Its PDF
    /// is cloned back into `.partial` and committed like a drop — no source access (it is our
    /// own copy), AI held like a relaunch's resume — then the leftover folder is removed.
    /// Returns the new paper's id; nil when the folder turned out to be referenced, the
    /// bytes were already a paper (the folder is removed then too), or the commit failed
    /// (the folder stays for the next launch).
    package func recoverInterruptedCommit(folder: URL, pdfName: String) async -> String? {
        let paths = ctx.paths, db = ctx.db
        guard let relative = LibraryPaths.relativePath(of: folder, root: paths.library) else { return nil }
        /// True only when the lookup succeeded and found no row naming the folder.
        func unreferenced() async -> Bool {
            do { return try await db.paper(folder: relative) == nil } catch { return false }
        }
        guard await unreferenced() else { return nil }
        let pdf = folder.appendingPathComponent(pdfName)
        let partialDir = paths.partial
        let clone: (url: URL, sha256: String)
        do {
            clone = try await BlockingIO.run { try FileOps.cloneIntoPartial(source: pdf, partialDir: partialDir) }
        } catch {
            Log.importer.error("recovery of \(relative, privacy: .public) failed: \(FileOps.classify(error).description, privacy: .public)")
            return nil
        }
        let settings = await ctx.settings()
        let plan = Self.plan(batchID: UUID().uuidString.lowercased(), count: 1,
                             options: ImportOptions(origin: .folderImport, ai: .hold), settings: settings)
        let row = ImportRowUpdate(id: UUID().uuidString.lowercased(), batchID: plan.batchID, displayName: pdfName,
                                  stage: .parsing)
        await acquireSlot(.extract)
        let extraction = await extract(clone.url, fileName: pdfName)
        releaseSlot(.extract)
        guard case .ok(let extracted, let flags) = extraction else {
            await BlockingIO.run { try? FileManager.default.removeItem(at: clone.url) }
            InFlightPartials.shared.remove(clone.url)
            return nil                                  // not a PDF after all: left for 清理孤立文件
        }
        let ids = extracted?.ids ?? Identifiers.detect(fileName: pdfName, firstPagesText: "", attributeTitle: nil, xmpHead: nil)
        let staged = Staged(partial: clone.url, sha256: clone.sha256, fileSize: FileOps.fileSize(clone.url) ?? 0,
                            originalName: pdfName, extracted: extracted, flags: flags, ids: ids, source: nil)
        await lockCommit()
        let outcome = await commitLocked(staged, row: row, plan: plan)
        unlockCommit()
        await finishCommit(outcome, staged: staged, row: row, plan: plan)
        abortedBatches.remove(plan.batchID)
        let id: String?
        switch outcome {
        case .committed(let paper, _): id = paper.id
        case .duplicate, .linkedSameWork: id = nil
        case .sameWork: return nil                      // the user decides; the folder stays until then
        case .failed:
            InFlightPartials.shared.remove(clone.url)
            return nil
        }
        InFlightPartials.shared.remove(clone.url)
        // Our own leftover copy; the library has the bytes now. Never a folder a row names.
        if await unreferenced() {
            await BlockingIO.run { try? FileManager.default.removeItem(at: folder) }
        }
        return id
    }

    /// Ids of unanswered "same work" prompts (tests, UI state restoration).
    package func pendingIDs() -> [String] { pending.keys.sorted() }

    /// Replaces the link transport (tests and self-tests: a fake that never touches the network;
    /// nil = the default ephemeral URLSession).
    package func useDownloader(_ d: (any PDFDownloading)?) {
        downloaderOverride = d
    }

    /// The transport dropped links (and email links, `Engine.downloadMailItem`) go through.
    package func pdfDownloader() -> any PDFDownloading { downloader() }

    // MARK: - One file

    private func process(_ c: Candidate, plan: BatchPlan) async -> FileOutcome {
        var row = ImportRowUpdate(id: c.rowID, batchID: plan.batchID, displayName: c.displayName, stage: .receiving)
        let lang = plan.lang
        let annotation = plan.options.annotation(for: c.itemURL)
        guard !abortedBatches.contains(plan.batchID) else {
            if case .local(_, _, _, let cleanup) = c.source, let cleanup {
                let incoming = ctx.paths.incoming
                await BlockingIO.run { Self.removeIncoming(cleanup, incoming: incoming) }
            }
            let reason = IntakeText.reasonAborted(lang)
            row.stage = .failed(reason: reason)
            emit(row)
            return .failed(reason)
        }

        let local: URL, originalName: String, userFile: Bool, cleanup: URL?
        switch c.source {
        case .remote(let url):
            guard let file = await download(url, row: &row, lang: lang, quiet: plan.options.origin == .mail) else {
                if case .rejected(let reason) = row.stage { return .rejected(reason) }
                if case .failed(let reason) = row.stage { return .failed(reason) }
                return .failed(IntakeText.downloadFailed(status: nil, lang))
            }
            local = file.url; originalName = file.name; userFile = false; cleanup = file.url.deletingLastPathComponent()
        case .local(let url, let name, let isUserFile, let clean):
            local = url; originalName = name; userFile = isUserFile; cleanup = clean
        }

        // [摄取] one coordinated read: head check → SHA-256 → exact dedupe → APFS clone.
        // Cloud placeholders wait for their download without holding an ingest slot.
        let holdsSlot = !c.needsCloudDownload
        if holdsSlot {
            await acquireSlot(.ingest)
            row.stage = .verifying
        } else {
            row.stage = .waitingForCloud
        }
        emit(row)
        let db = ctx.db, partialDir = ctx.paths.partial, incoming = ctx.paths.incoming
        let ingested: Ingested
        do {
            ingested = try await FileOps.coordinatedRead(source: local) { url in
                try Self.ingestAccessor(url, db: db, partialDir: partialDir)
            }
        } catch {
            if holdsSlot { releaseSlot(.ingest) }
            if let cleanup { await BlockingIO.run { Self.removeIncoming(cleanup, incoming: incoming) } }
            return fail(row: &row, name: originalName, error: error, plan: plan)
        }
        if holdsSlot { releaseSlot(.ingest) }
        if let cleanup { await BlockingIO.run { Self.removeIncoming(cleanup, incoming: incoming) } }

        let partial: URL, sha: String, size: Int64
        switch ingested {
        case .duplicate(let existing):
            return await finishExisting(existing, sameWork: false, annotation: annotation, row: row, plan: plan)
        case .cloned(let url, let hash, let bytes):
            partial = url; sha = hash; size = bytes
        }

        // [抽取]
        await acquireSlot(.extract)
        row.stage = .parsing
        emit(row)
        let extraction = await extract(partial, fileName: originalName)
        releaseSlot(.extract)
        guard case .ok(let extracted, let flags) = extraction else {
            await BlockingIO.run { try? FileManager.default.removeItem(at: partial) }
            InFlightPartials.shared.remove(partial)
            let reason = IntakeText.reasonNotPDF(lang)
            row.stage = .rejected(reason: reason)
            emit(row)
            ctx.events.send(.toast(Toast(kind: .error, message: IntakeText.notPDF(originalName, lang))))
            return .rejected(reason)
        }
        let ids = extracted?.ids ?? Identifiers.detect(fileName: originalName, firstPagesText: "",
                                                        attributeTitle: nil, xmpHead: nil)
        var staged = Staged(partial: partial, sha256: sha, fileSize: size, originalName: originalName,
                            extracted: extracted, flags: flags, ids: ids, source: userFile ? local : nil,
                            annotation: annotation)
        if plan.dedupe.enabled {
            // The duplicate check's slow parts outside the commit lock (it serializes every
            // import): the file's signature, and the fingerprints of the papers it will be compared
            // with (an older build's library has none) — inside the lock they are only read.
            let subject = Self.dupSubject(of: staged)
            staged.dupSubject = subject
            await DedupeIndex.prepare(subject, ids: ids, ctx: ctx, pages: extracted?.pageTexts)
        }

        // [ID 查重] + [committed]
        await lockCommit()
        let outcome = await commitLocked(staged, row: row, plan: plan)
        unlockCommit()
        // A pending "same work" answer keeps its copy in `.partial/` (still in flight).
        if case .sameWork = outcome {} else { InFlightPartials.shared.remove(partial) }
        return await finishCommit(outcome, staged: staged, row: row, plan: plan)
    }

    /// Everything the pipeline knows about a file that sits in `.partial/`.
    private struct Staged: Sendable {
        var partial: URL
        var sha256: String
        var fileSize: Int64
        var originalName: String
        var extracted: ExtractedPDF?
        var flags: PaperFlags
        var ids: PaperIDs
        var source: URL?                 // the user's original (move mode trashes it)
        var annotation: ImportAnnotation? = nil
        /// The duplicate check's view of the file (computed once, before the commit lock).
        var dupSubject: DupSubject? = nil

        var linksExisting: Bool { annotation?.sameWorkPolicy == .link }
    }

    private enum CommitOutcome: Sendable {
        /// `review`: the duplicate review opened with the commit (held or possible), if any.
        case committed(Paper, review: DupReview?)
        case duplicate(Paper)
        /// `review`: the duplicate review of the parked file (duplicate check on).
        case sameWork(existing: Paper, pendingID: String, review: DupReview?)
        /// Same work under `SameWorkPolicy.link`: the copy was discarded; link to `existing`.
        case linkedSameWork(Paper)
        case failed(CommitFailure)
    }

    /// What the insert transaction decided.
    private enum InsertResult: Sendable {
        case inserted(Paper, DupReview?)
        case duplicate(Paper)
        case sameWork(Paper)
    }

    /// Dedupe again (another item may have committed the same bytes/work while this one was
    /// being parsed), then — in one Database call — dedupe once more, move the copy into
    /// `_Inbox/<sha8>/` and insert the paper, its heuristic checklist, its placement and its
    /// FTS rows. Checking inside the insert transaction means a DOI adopted meanwhile (an
    /// enrichment merge) becomes a same-work prompt, never a unique-index failure; and a
    /// committed folder never exists without its row except after a crash inside that call
    /// (Maintenance recovers those). Caller holds the commit lock.
    /// `skipIdentity` (the review's "keep both" / "import as new"): no same-work or duplicate
    /// check — only the exact bytes still count.
    private func commitLocked(_ s: Staged, row: ImportRowUpdate, plan: BatchPlan,
                              skipIdentity: Bool = false, pair: DupPairIntent? = nil) async -> CommitOutcome {
        let partial = s.partial
        if let hit = try? await ctx.db.paper(sha256: s.sha256) {
            await BlockingIO.run { try? FileManager.default.removeItem(at: partial) }
            return .duplicate(hit)
        }
        if !skipIdentity, let existing = try? await ctx.db.paperMatchingWork(doi: s.ids.doi, arxivID: s.ids.arxivID,
                                                                             publishedDOI: s.ids.publishedDOI) {
            return await sameWork(s, row: row, plan: plan, existing: existing)
        }

        let settings = await ctx.settings()
        let now = ctx.now()
        let paperID = UUID().uuidString.lowercased()
        let generated = ChecklistHeuristics.generate(structure: s.extracted?.structure ?? DocumentStructure(),
                                                     pageCount: s.extracted?.pageCount)
        let (title, rank) = s.extracted?.bestLocalTitle ?? (Self.title(fromFileName: s.originalName), .filename)
        let text = s.extracted?.fullText ?? ""

        // The duplicate check (DQ §3.7): an identifier of a paper in Recently Deleted, an alias,
        // a version family → parked like the same-work hits above; a likely match or a removed
        // paper read before → committed held (no DDL, AI held) with its review in the insert
        // transaction; a possible match → committed normally with a review (chip only).
        let subject: DupSubject? = plan.dedupe.enabled ? (s.dupSubject ?? Self.dupSubject(of: s)) : nil
        var intakeReview: (review: DupReview, hold: Bool)?
        if let subject, !skipIdentity,
           let m = await DedupeIndex.match(subject, ids: s.ids, excluding: nil, settings: plan.dedupe, ctx: ctx,
                                           pages: s.extracted?.pageTexts, computeMissing: Self.signaturesInLock) {
            if m.candidate.band == .certain, let existing = m.existing, !s.linksExisting {
                return await sameWork(s, row: row, plan: plan, existing: existing, match: m)
            }
            // An email's merge never waits: at most a chip.
            let band: DupBand = s.linksExisting ? .possible : m.reviewBand
            let hold = band != .possible
            let review = DupReview(newPaperID: paperID, existingPaperID: m.existing?.id, band: band,
                                   score: m.candidate.score, createdAt: now, existingPaperPK: m.existing?.pk,
                                   historyPK: m.history?.pk, relation: m.candidate.relation,
                                   evidence: m.candidate.evidence + (m.history != nil ? [DupEvidence(.history)] : []),
                                   newerSide: m.candidate.newerSide, origin: s.annotation != nil ? .mail : .intake,
                                   batchID: plan.batchID, stagedName: s.originalName,
                                   held: hold ? DupHeldIntent(scheduleHeld: true, placement: plan.placement.code) : nil)
            intakeReview = (review, hold)
        }

        let paths = ctx.paths, texts = ctx.texts, thumbs = ctx.thumbs
        let thumbnail = s.extracted?.cardThumbnailJPEG
        await BlockingIO.run {
            do { try texts.save(text, id: paperID) } catch {
                Log.importer.error("text cache for \(paperID, privacy: .public) failed: \(FileOps.classify(error).description, privacy: .public)")
            }
            if let thumbnail {
                do { try thumbs.save(cardJPEG: thumbnail, id: paperID) } catch {
                    Log.importer.error("thumbnail for \(paperID, privacy: .public) failed: \(FileOps.classify(error).description, privacy: .public)")
                }
            }
        }
        let dropCaches = {
            await BlockingIO.run {
                texts.delete(id: paperID)
                thumbs.delete(id: paperID)
            }
        }

        // The annotation's priority is set before place() — it decides where the paper lands.
        let annotation = s.annotation
        // An email's held titles stay held in the library: identifier lookups only.
        let flags = annotation?.identifierLookupsOnly == true ? s.flags.union(.titleLookupHeld) : s.flags
        let draft = Paper(id: paperID, sha256: s.sha256, fileSize: s.fileSize, ids: s.ids, title: title, titleRank: rank,
                          pageCount: s.extracted?.pageCount, charCount: s.extracted?.charCount, flags: flags,
                          folder: "", pdfName: "", originalName: s.originalName, nameFinal: false,
                          stage: .committed,
                          priority: annotation?.priority ?? (plan.placement == .sequentialLow ? .low : .normal),
                          provisional: true, estMinutes: generated.estMinutes, estSource: .heuristic,
                          aiState: .none, addedAt: now, updatedAt: now)
        let items = generated.items
        let scheduler = Scheduler(settings: settings.plan, now: now, calendar: ctx.calendar)
        // A held duplicate gets no DDL until the user decides (its review restores the placement).
        let placement = intakeReview?.hold == true ? .unscheduled : plan.placement
        let reviewDraft = intakeReview?.review
        let placed = PlacedCopy()
        let categoryCreated = LockedFlag()
        let result: InsertResult
        do {
            result = try await ctx.db.transaction { db -> InsertResult in
                if let hit = try db.paper(sha256: s.sha256) { return .duplicate(hit) }
                if !skipIdentity, let existing = try db.paperMatchingWork(doi: s.ids.doi, arxivID: s.ids.arxivID,
                                                                          publishedDOI: s.ids.publishedDOI) {
                    return .sameWork(existing)
                }
                let (folderURL, pdfName) = try Self.placeInInbox(partial, inbox: paths.inbox, sha256: s.sha256,
                                                                 originalName: s.originalName)
                placed.set(folderURL, pdfName: pdfName)
                do {
                    var paper = draft
                    paper.folder = LibraryPaths.relativePath(of: folderURL, root: paths.library)
                        ?? "Papers/_Inbox/" + folderURL.lastPathComponent
                    paper.pdfName = pdfName
                    paper.queueRank = try db.nextQueueRank()
                    let live = try db.livePapers()
                    let lists = try db.checklists(paperPKs: live.map(\.pk))
                    let others = live.map { Scheduler.item(for: $0, checklist: lists[$0.pk] ?? []) }
                    let q = Scheduler.item(for: paper, checklist: items)
                    let placedItem = placement == .unscheduled ? scheduler.unschedule(q) : scheduler.place(q, among: others)
                    paper.deadline = placedItem.deadline
                    paper.scheduleMode = placedItem.scheduleMode
                    paper.deadlineOrigin = placedItem.deadlineOrigin
                    paper.placementFloor = placedItem.placementFloor
                    if let annotation {
                        if try Self.annotate(&paper, with: annotation, db: db, now: now, isNew: true) {
                            categoryCreated.set()
                        }
                    }
                    let saved = try db.insertPaper(paper, checklist: items)
                    try db.indexFullText(pk: saved.pk, text: text)
                    if let provenance = annotation?.provenance {
                        try db.insertPaperSource(paperPK: saved.pk, provenance)
                    }
                    if let subject {
                        // Keys + fingerprint now, so later checks find this paper without re-reading it.
                        try db.addDupKeys(paperPK: saved.pk, DupKeys.local(saved.ids))
                        try db.upsertDupFingerprint(paperPK: saved.pk, subject: subject, sha256: saved.sha256,
                                                    sourceUpdatedAt: saved.updatedAt, now: now)
                    }
                    if let pair {
                        try db.setDupPair(saved.pk, pair.existingPK, decision: pair.decision, relation: pair.relation,
                                          decidedBy: "user", at: now)
                    }
                    if var review = reviewDraft {
                        // In the same Database call as the insert: a held paper never exists without its review.
                        review.newPaperPK = saved.pk
                        try db.insertDupReview(review)
                        return .inserted(saved, review)
                    }
                    return .inserted(saved, nil)
                } catch {
                    Self.unplace(folderURL, pdfName: pdfName, backTo: partial)
                    placed.clear()
                    throw error
                }
            }
        } catch {
            // COMMIT itself failed after the move: the copy goes back to `.partial` first.
            if let copy = placed.get() {
                await BlockingIO.run { Self.unplace(copy.folder, pdfName: copy.pdfName, backTo: partial) }
            }
            await dropCaches()
            if let e = error as? FileOpsError {
                Log.importer.error("commit of \(s.originalName, privacy: .public) failed: \(e.description, privacy: .public)")
                await BlockingIO.run { try? FileManager.default.removeItem(at: partial) }
                return .failed(.file(e))
            }
            Log.importer.error("commit of \(s.originalName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            if let e = error as? SQLiteError, e.isUniqueViolation {
                // Only a sha256 conflict is an exact duplicate; a DOI/arXiv one is the same work.
                if !skipIdentity, Self.isIdentityConflict(e), let existing = try? await ctx.db.paperMatchingWork(
                    doi: s.ids.doi, arxivID: s.ids.arxivID, publishedDOI: s.ids.publishedDOI) {
                    return await sameWork(s, row: row, plan: plan, existing: existing)
                }
                if !Self.isIdentityConflict(e), let hit = try? await ctx.db.paper(sha256: s.sha256) {
                    await BlockingIO.run { try? FileManager.default.removeItem(at: partial) }
                    return .duplicate(hit)
                }
            }
            await BlockingIO.run { try? FileManager.default.removeItem(at: partial) }
            return .failed(.database)
        }
        switch result {
        case .inserted(let paper, let review):
            if categoryCreated.isSet { await ctx.writeManifest() }
            return .committed(paper, review: review)
        case .duplicate(let hit):
            await dropCaches()
            await BlockingIO.run { try? FileManager.default.removeItem(at: partial) }
            return .duplicate(hit)
        case .sameWork(let existing):
            await dropCaches()
            return await sameWork(s, row: row, plan: plan, existing: existing)
        }
    }

    /// The staged file is the same work as `existing`: parked for the user's answer to a
    /// "same work" toast — or, under `SameWorkPolicy.link`, discarded (the caller links it).
    /// With the duplicate check on, the parked file gets a review (certain): `match` when the
    /// check found it, else the pair is compared here for the relation and the reasons.
    private func sameWork(_ s: Staged, row: ImportRowUpdate, plan: BatchPlan, existing: Paper,
                          match: DupMatch? = nil) async -> CommitOutcome {
        if s.linksExisting {
            let partial = s.partial
            await BlockingIO.run { try? FileManager.default.removeItem(at: partial) }
            return .linkedSameWork(existing)
        }
        let id = UUID().uuidString.lowercased()
        // Parked before its review is written: a review whose file isn't pending reads as lost with a
        // relaunch (`Engine.duplicateReviews` expires those), and the insert below suspends this actor.
        pending[id] = PendingWork(id: id, row: row, staged: s, existingPK: existing.pk, existingID: existing.id, plan: plan)
        var review: DupReview?
        if plan.dedupe.enabled {
            let n = s.dupSubject ?? Self.dupSubject(of: s)
            var candidate = match?.candidate
            if candidate == nil {
                let e = await DedupeIndex.subject(for: existing, ctx: ctx)
                candidate = DupDetector.compare(n, e, sensitivity: plan.dedupe.sensitivity)
            }
            let c = candidate ?? DupCandidate(band: .certain, relation: .sameWork, score: 0.99,
                                              evidence: [DupEvidence(.sharedDOI, value: s.ids.doi ?? existing.ids.doi)],
                                              newerSide: nil)
            let r = DupReview(newPaperID: nil, existingPaperID: existing.id, band: .certain, score: c.score,
                              createdAt: ctx.now(), existingPaperPK: existing.pk, relation: c.relation,
                              evidence: c.evidence, newerSide: c.newerSide, origin: .intake, batchID: plan.batchID,
                              pendingID: id, stagedName: s.originalName)
            do {
                try await ctx.db.insertDupReview(r)
                review = r
                pending[id]?.reviewID = r.id
            } catch {
                Log.importer.error("duplicate review failed: \(String(describing: error), privacy: .public)")
            }
        }
        return .sameWork(existing: existing, pendingID: id, review: review)
    }

    /// The duplicate check's subject of a staged file (its best local title, its signature).
    private static func dupSubject(of s: Staged) -> DupSubject {
        let (title, rank) = s.extracted?.bestLocalTitle ?? (Self.title(fromFileName: s.originalName), .filename)
        return DedupeIndex.stagedSubject(sha256: s.sha256, ids: s.ids, title: title, titleRank: rank,
                                         fileName: s.originalName, extracted: s.extracted)
    }

    /// Candidates whose fingerprint the check may still compute inside the commit lock (`prepare`
    /// computed them before it; one committed meanwhile has its own already).
    static let signaturesInLock = 3

    /// A UNIQUE failure on the DOI / arXiv indexes (ux_doi, ux_arxiv) rather than on sha256.
    private static func isIdentityConflict(_ e: SQLiteError) -> Bool {
        let m = e.message.lowercased()
        return !m.contains("sha256") && (m.contains("doi") || m.contains("arxiv"))
    }

    /// Rows, toasts, move mode and the hand-off to EnrichActor after a commit attempt.
    @discardableResult
    private func finishCommit(_ outcome: CommitOutcome, staged s: Staged, row: ImportRowUpdate,
                              plan: BatchPlan) async -> FileOutcome {
        var row = row
        let lang = plan.lang
        switch outcome {
        case .duplicate(let existing):
            return await finishExisting(existing, sameWork: false, annotation: s.annotation, row: row, plan: plan)
        case .linkedSameWork(let existing):
            return await finishExisting(existing, sameWork: true, annotation: s.annotation, row: row, plan: plan)
        case .sameWork(let existing, let pendingID, let review):
            row.stage = .sameWork(existingPaperID: existing.id, pendingID: pendingID)
            emit(row)
            if let review { ctx.events.send(.dedupe(.reviewOpened(reviewID: review.id, paperID: nil))) }
            // Today's two-button toast, unchanged (the app's duplicate model words it from the review
            // and offers [Review…]); a batch's files share one review toast instead (`ingest`).
            if review == nil || plan.perPaperToasts {
                let message = IntakeText.sameWork(existing: existing.ids.arxivVersion, new: s.ids.arxivVersion,
                                                  title: existing.title, newName: s.originalName, lang)
                ctx.events.send(.toast(Toast(kind: .info, message: message, buttons: [
                    .init(title: IntakeText.replaceKeepingChecklist(lang), action: .replaceKeepingChecklist(pendingID: pendingID)),
                    .init(title: IntakeText.ignore(lang), action: .ignorePending(pendingID: pendingID)),
                ])))
            }
            return .sameWork(existingPaperID: existing.id, linked: false, review: review)
        case .failed(let failure):
            return failCommit(row: &row, name: s.originalName, failure: failure, plan: plan)
        case .committed(let paper, let review):
            await ctx.syncSidecar(pk: paper.pk)
            row.stage = .added(paperID: paper.id, deadline: paper.deadline, provisional: paper.provisional)
            emit(row)
            if let review, review.holdsNewPaper {
                // Held for the user's decision: the review's toast instead of 「已添加 · DDL」.
                if plan.perPaperToasts {
                    let existingTitle = await reviewExistingTitle(review)
                    ctx.events.send(.toast(Toast(id: "dup-" + review.id, kind: .info,
                                                 message: DupExplainer.toastMessage(review, newTitle: paper.title,
                                                                                    existingTitle: existingTitle, lang: lang),
                                                 buttons: [.init(title: DupExplainer.reviewButton(lang),
                                                                 action: .openDuplicateReview(id: review.id))])))
                }
            } else if plan.perPaperToasts {
                let chip = chipText(paper.scheduleMode == .none ? nil : paper.deadline, provisional: paper.provisional, lang: lang)
                ctx.events.send(.toast(Toast(kind: .success, message: IntakeText.added(paper.title, chip: chip, lang), buttons: [
                    .init(title: IntakeText.view(lang), action: .openPaper(id: paper.id)),
                    .init(title: IntakeText.setHighPriority(lang), action: .setHighPriority(paperID: paper.id)),
                ])))
                if let warning = IntakeText.flagWarning(paper.flags, name: s.originalName, lang) {
                    ctx.events.send(.toast(Toast(kind: .warning, message: warning)))
                }
            }

            var keptOriginal = false
            if plan.moveSources, let source = s.source {
                let trash = trashSource
                keptOriginal = !(await BlockingIO.run { trash(source) })
            }

            let unreadable = !paper.flags.isDisjoint(with: [.locked, .scanned, .unreadable])
            let ai = plan.ai(for: s.annotation)
            let held = ai.hold && ai.wanted && !unreadable
            await enrich.submit(pk: paper.pk, holdAI: ai.hold, ai: ai.policy, row: row,
                                aiPriority: s.annotation?.aiPriority ?? 0,
                                holdUnlessIdentified: s.annotation?.holdAIUnlessIdentified ?? false)
            if let review { ctx.events.send(.dedupe(.reviewOpened(reviewID: review.id, paperID: paper.id))) }
            return .added(paper, held: held, keptOriginal: keptOriginal, review: review)
        }
    }

    /// The file is a paper the library already has (exact bytes, or — under
    /// `SameWorkPolicy.link` — the same work). With `.link` the annotation is applied to that
    /// paper; otherwise the usual 「已在库中」 toast.
    private func finishExisting(_ existing: Paper, sameWork: Bool, annotation: ImportAnnotation?,
                                row: ImportRowUpdate, plan: BatchPlan) async -> FileOutcome {
        var row = row
        let lang = plan.lang
        row.stage = .duplicate(paperID: existing.id)
        if existing.isDeleted, annotation?.leaveDeletedAlone == true {
            // The caller handles papers in 最近删除 (restore on the user's merge, or wait).
            emit(row)
            return sameWork ? .sameWork(existingPaperID: existing.id, linked: false, review: nil)
                            : .duplicate(paperID: existing.id, linked: false)
        }
        guard let annotation, annotation.sameWorkPolicy == .link else {
            emit(row)
            ctx.events.send(.toast(duplicateToast(existing, lang: lang)))
            return .duplicate(paperID: existing.id, linked: false)
        }
        var linked = true
        do {
            try await Self.link(existing.pk, annotation: annotation, ctx: ctx)
        } catch {
            linked = false
            Log.importer.error("linking to \(existing.pk) failed: \(String(describing: error), privacy: .public)")
        }
        emit(row)
        if existing.isDeleted {
            ctx.events.send(.toast(duplicateToast(existing, lang: lang)))
        } else if plan.perPaperToasts {
            ctx.events.send(.toast(Toast(kind: .info, message: IntakeText.linkedExisting(existing.title, lang),
                                         buttons: [.init(title: IntakeText.view(lang), action: .openPaper(id: existing.id))])))
        }
        return sameWork ? .sameWork(existingPaperID: existing.id, linked: linked, review: nil)
                        : .duplicate(paperID: existing.id, linked: linked)
    }

    // MARK: - Annotations

    /// Applies an annotation to a paper that already exists (an email linked to it) in one
    /// transaction: the provenance row always; priority and pinned DDL when given (live papers
    /// only — they are the user's explicit merge choices); the category only when the paper
    /// has none; the notes only when empty. Then card.json (and the manifest if a category
    /// was created).
    @discardableResult
    package static func link(_ paperPK: Int64, annotation a: ImportAnnotation, ctx: EngineContext) async throws -> Paper {
        let now = ctx.now()
        let (saved, created) = try await ctx.db.transaction { db -> (Paper, Bool) in
            guard var p = try db.paper(pk: paperPK) else { throw DatabaseError.notFound("paper \(paperPK)") }
            var created = false
            if p.isLive {
                let before = p
                created = try annotate(&p, with: a, db: db, now: now, isNew: false)
                if p != before { p = try db.updatePaper(p, now: now) }
            }
            if let provenance = a.provenance { try db.insertPaperSource(paperPK: paperPK, provenance) }
            return (p, created)
        }
        if created { await ctx.writeManifest() }
        await ctx.syncSidecar(pk: paperPK)
        return saved
    }

    /// Priority, pinned DDL, category and notes of an annotation onto `p` (inside a
    /// transaction). New papers already carry the priority (set before place()). Returns true
    /// when a category had to be created.
    static func annotate(_ p: inout Paper, with a: ImportAnnotation, db: isolated Database, now: Date,
                         isNew: Bool) throws -> Bool {
        if !isNew, let priority = a.priority { p.priority = priority }
        if let date = a.pinnedDeadline {
            p.deadline = date
            p.scheduleMode = .pinned
            p.deadlineOrigin = .user
            p.provisional = false                       // the user's date, not a heuristic ≈DDL
        }
        var created = false
        if let name = a.category, p.categoryPK == nil, let hit = try categoryPK(named: name, db: db, now: now) {
            p.categoryPK = hit.pk
            p.categoryUserSet = true
            p.needsReview = false
            created = hit.created
        }
        if let prefill = a.notesPrefill, !prefill.isEmpty,
           p.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            p.notes = prefill
        }
        return created
    }

    /// A category by (normalized) name, created as the user's when missing.
    static func categoryPK(named raw: String, db: isolated Database, now: Date) throws -> (pk: Int64, created: Bool)? {
        guard let name = Taxonomy.normalizeCategoryName(raw) else { return nil }
        if let existing = try db.category(named: name) { return (existing.pk, false) }
        let made = try db.insertCategory(PaperCategory(name: name, hue: Taxonomy.nextHue(existing: try db.categories()),
                                                       origin: .user, acknowledged: true, createdAt: now))
        return (made.pk, true)
    }

    // MARK: - Steps

    private enum Ingested: Sendable {
        case duplicate(Paper)
        case cloned(partial: URL, sha256: String, size: Int64)
    }

    /// Runs inside the coordinated read — the only time the source is touched.
    private static func ingestAccessor(_ url: URL, db: Database, partialDir: URL) throws -> Ingested {
        try FileOps.checkPDF(url)
        let sha = try FileOps.sha256(of: url)
        if let hit = paperBlocking(db: db, sha256: sha) { return .duplicate(hit) }
        let clone = try FileOps.cloneIntoPartial(source: url, partialDir: partialDir, expectedSHA256: sha)
        return .cloned(partial: clone.url, sha256: clone.sha256, size: FileOps.fileSize(clone.url) ?? 0)
    }

    /// `db.paper(sha256:)` from the (synchronous) accessor. The accessor runs on the ingest
    /// OperationQueue, never on the cooperative pool, and the Database has its own serial
    /// executor, so waiting here cannot starve or deadlock Swift concurrency. On timeout the
    /// file is cloned anyway; the commit re-checks under the commit lock.
    private static func paperBlocking(db: Database, sha256: String) -> Paper? {
        let box = LookupBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            box.set(try? await db.paper(sha256: sha256))
            done.signal()
        }
        guard done.wait(timeout: .now() + 10) == .success else {
            Log.importer.error("sha lookup timed out; deferring dedupe to commit")
            return nil
        }
        return box.get()
    }

    private enum Extraction: Sendable {
        case ok(ExtractedPDF?, PaperFlags)
        case notPDF
    }

    /// Unreadable files are still imported (flag + fallback checklist); only non-PDFs are rejected.
    private func extract(_ url: URL, fileName: String) async -> Extraction {
        do {
            let x = try await extractor.extract(url: url, fileName: fileName)
            var flags: PaperFlags = []
            if x.isLocked { flags.insert(.locked) }
            if x.isScanned { flags.insert(.scanned) }
            return .ok(x, flags)
        } catch let e as PDFExtractor.ExtractError where e == .notPDF {
            return .notPDF
        } catch {
            Log.importer.info("extraction failed for \(fileName, privacy: .public): \(String(describing: error), privacy: .public)")
            return .ok(nil, [.unreadable])
        }
    }

    /// Downloads a dropped link into caches/incoming; on failure emits the row + toast and returns nil.
    /// `quiet` (email merges): no error toast — the email card shows why its row needs a PDF.
    private func download(_ url: URL, row: inout ImportRowUpdate, lang: UILang,
                          quiet: Bool = false) async -> (url: URL, name: String)? {
        let hub = ctx.events
        let base = row
        let throttle = ProgressThrottle()
        let importer = URLImporter(downloader: downloader())
        let outcome = await importer.fetch(url, incoming: ctx.paths.incoming) { fraction in
            guard throttle.shouldEmit(fraction) else { return }
            var r = base
            r.stage = .downloading(fraction: fraction)
            hub.send(.importRow(r))
        }
        let browser = Toast.Button(title: IntakeText.openInBrowser(lang), action: .openInBrowser(url))
        let events = ctx.events
        func toast(_ message: String) {
            guard !quiet else { return }
            events.send(.toast(Toast(kind: .error, message: message, buttons: [browser])))
        }
        switch outcome {
        case .downloaded(let file, let name):
            row.displayName = name
            return (file, name)
        case .notPDFLink:
            row.stage = .rejected(reason: IntakeText.reasonNotPDFLink(lang))
            toast(IntakeText.cannotDownload(lang))
        case .notPDF:
            row.stage = .rejected(reason: IntakeText.reasonLinkNotPDF(lang))
            toast(IntakeText.cannotDownload(lang))
        case .httpError(let status):
            row.stage = .failed(reason: IntakeText.downloadFailed(status: status, lang))
            toast(IntakeText.downloadFailed(status: status, lang))
        case .failed(let detail):
            Log.importer.info("download failed: \(detail, privacy: .public)")
            row.stage = .failed(reason: IntakeText.downloadFailed(status: nil, lang))
            toast(IntakeText.downloadFailed(status: nil, lang))
        case .blocked:
            row.stage = .rejected(reason: IntakeText.reasonBlocked(lang))
            toast(IntakeText.cannotDownload(lang))
        }
        emit(row)
        return nil
    }

    private func downloader() -> any PDFDownloading {
        if let d = downloaderOverride { return d }
        if let d = sessionDownloader { return d }
        let d = URLSessionPDFDownloader()
        sessionDownloader = d
        return d
    }

    /// Maps an ingest error to the row, a toast and the batch outcome. A full disk or a
    /// vanished library pauses the rest of the batch (§6.1 失败).
    private func fail(row: inout ImportRowUpdate, name: String, error: any Error, plan: BatchPlan) -> FileOutcome {
        let lang = plan.lang
        let e: FileOpsError = error is CancellationError ? .io("cancelled") : FileOps.classify(error)
        let reason = IntakeText.reason(for: e, lang)
        if e == .notPDF {
            row.stage = .rejected(reason: reason)
            emit(row)
            ctx.events.send(.toast(Toast(kind: .error, message: IntakeText.notPDF(name, lang))))
            return .rejected(reason)
        }
        row.stage = .failed(reason: reason)
        emit(row)
        switch e {
        case .diskFull, .libraryUnavailable:
            if abortedBatches.insert(plan.batchID).inserted {
                ctx.events.send(.toast(Toast(kind: .error, message: IntakeText.paused(e, lang))))
            }
        case .sourceMissing, .permissionDenied, .timeout:
            ctx.events.send(.toast(Toast(kind: .error, message: IntakeText.dropAgain(name, reason: reason, lang))))
        default:
            ctx.events.send(.toast(Toast(kind: .error, message: IntakeText.importFailed(name, reason: reason, lang))))
        }
        return .failed(reason)
    }

    /// A failed commit. A full disk or a vanished library pauses the rest of the batch and a
    /// vanished staged copy asks for the file again, exactly like the ingest path; anything
    /// else (an unwritable library, a database error) is 「写入资料库失败」 — details are logged.
    private func failCommit(row: inout ImportRowUpdate, name: String, failure: CommitFailure,
                            plan: BatchPlan) -> FileOutcome {
        if case .file(let e) = failure, e == .diskFull || e == .libraryUnavailable || e == .sourceMissing {
            return fail(row: &row, name: name, error: e, plan: plan)
        }
        let reason = IntakeText.commitReason(failure, plan.lang)
        row.stage = .failed(reason: reason)
        emit(row)
        ctx.events.send(.toast(Toast(kind: .error, message: IntakeText.importFailed(name, reason: reason, plan.lang))))
        return .failed(reason)
    }

    /// The title of what a review matched (a paper, or a removed paper's tombstone).
    private func reviewExistingTitle(_ r: DupReview) async -> String {
        if let pk = r.existingPaperPK, let p = try? await ctx.db.paper(pk: pk) { return p.title }
        if let pk = r.historyPK, let h = try? await ctx.db.historyRow(pk: pk) { return h.title }
        return ""
    }

    private func duplicateToast(_ existing: Paper, lang: UILang) -> Toast {
        if existing.isDeleted {
            return Toast(kind: .info, message: IntakeText.inRecentlyDeleted(existing.title, lang),
                         buttons: [.init(title: IntakeText.restore(lang), action: .restorePaper(id: existing.id))])
        }
        return Toast(kind: .info, message: IntakeText.alreadyInLibrary(existing.title, lang),
                     buttons: [.init(title: IntakeText.view(lang), action: .openPaper(id: existing.id))])
    }

    private func chipText(_ deadline: LocalDate?, provisional: Bool, lang: UILang) -> String {
        let today = LocalDate.today(now: ctx.now(), calendar: ctx.calendar)
        return DeadlineLabel.chip(deadline: deadline, done: false, doneAt: nil, pinned: false, provisional: provisional,
                                  atRisk: false, today: today, lang: lang, calendar: ctx.calendar).text
    }

    private func emit(_ row: ImportRowUpdate) { ctx.events.send(.importRow(row)) }

    // MARK: - Serialization

    private func lockCommit() async {
        if !commitBusy { commitBusy = true; return }
        await withCheckedContinuation { commitWaiters.append($0) }
    }

    private func unlockCommit() {
        if commitWaiters.isEmpty { commitBusy = false } else { commitWaiters.removeFirst().resume() }
    }

    private enum SlotKind: Hashable { case ingest, extract }

    private func acquireSlot(_ kind: SlotKind) async {
        let limit = kind == .ingest ? Self.maxParallelIngests : Self.maxParallelExtractions
        if slotsInUse[kind, default: 0] < limit { slotsInUse[kind, default: 0] += 1; return }
        await withCheckedContinuation { slotWaiters[kind, default: []].append($0) }   // handed over by releaseSlot
    }

    private func releaseSlot(_ kind: SlotKind) {
        if var waiters = slotWaiters[kind], !waiters.isEmpty {
            let next = waiters.removeFirst()
            slotWaiters[kind] = waiters
            next.resume()
        } else {
            slotsInUse[kind, default: 1] -= 1
        }
    }

    // MARK: - Planning

    private enum Placement: Sendable {
        case normal, sequentialLow, unscheduled

        /// `DupHeldIntent.placement`.
        var code: String {
            switch self {
            case .normal: return "normal"
            case .sequentialLow: return "sequentialLow"
            case .unscheduled: return "unscheduled"
            }
        }
    }

    private struct BatchPlan: Sendable {
        var batchID: String
        var count: Int
        var placement: Placement
        var options: ImportOptions
        var autoRead: Bool
        var lang: UILang
        var moveSources: Bool
        var perPaperToasts: Bool
        /// The duplicate check's settings for this batch (`dedupe.enabled` off: today's behaviour).
        var dedupe: DedupeSettings = DedupeSettings(enabled: false)

        /// The AI decision for one file: its annotation's policy, else the batch's.
        func ai(for annotation: ImportAnnotation?) -> (policy: BatchAIPolicy, hold: Bool, wanted: Bool) {
            let policy = annotation?.aiPolicy ?? options.ai
            return (policy, IntakeActor.holds(policy, count: count), IntakeActor.wants(policy, autoRead: autoRead))
        }
    }

    /// Whether `policy` creates the job held for confirmation in a batch of `count` papers.
    static func holds(_ policy: BatchAIPolicy, count: Int) -> Bool {
        switch policy {
        case .automatic: return count > holdThreshold
        case .queueAll, .skip: return false
        case .hold, .queueHeld: return true
        }
    }

    /// Whether `policy` wants an AI job at all (auto-read decides for automatic / hold).
    static func wants(_ policy: BatchAIPolicy, autoRead: Bool) -> Bool {
        switch policy {
        case .skip: return false
        case .queueAll, .queueHeld: return true
        case .automatic, .hold: return autoRead
        }
    }

    private static func plan(batchID: String, count: Int, options: ImportOptions, settings: EngineSettings) -> BatchPlan {
        let placement: Placement
        switch options.scheduling {
        case .automatic:
            placement = count > sequentialThreshold || options.origin == .setupAssistant ? .sequentialLow : .normal
        case .sequentialLow: placement = .sequentialLow
        case .unscheduled: placement = .unscheduled
        }
        // Move mode is for the user's everyday drops; the setup assistant's "import existing
        // papers", CLI imports and email merges (our own attachment copies, the user's dropped
        // file) always copy (§8 设置助手 6).
        let move = settings.importMode == .move && options.origin != .setupAssistant && options.origin != .cli
            && options.origin != .mail
        return BatchPlan(batchID: batchID, count: count, placement: placement, options: options,
                         autoRead: settings.autoReadNewPapers, lang: settings.lang, moveSources: move,
                         perPaperToasts: count <= perPaperToastLimit, dedupe: settings.dedupe)
    }

    private enum FileOutcome: Sendable {
        case added(Paper, held: Bool, keptOriginal: Bool, review: DupReview?)
        case duplicate(paperID: String, linked: Bool)
        case sameWork(existingPaperID: String, linked: Bool, review: DupReview?)
        case rejected(String)
        case failed(String)
    }

    private struct PendingWork: Sendable {
        var id: String
        var row: ImportRowUpdate
        var staged: Staged
        var existingPK: Int64
        var existingID: String
        var plan: BatchPlan
        /// The duplicate review asking about this file (duplicate check on).
        var reviewID: String? = nil
        var partial: URL { staged.partial }
    }

    // MARK: - Receiving (blocking file-system work)

    private struct Candidate: Sendable {
        enum Source: Sendable {
            /// `userFile`: the user's own file outside the library (move mode may trash it).
            /// `cleanup`: our incoming copy to delete once ingested.
            case local(URL, originalName: String, userFile: Bool, cleanup: URL?)
            case remote(URL)
        }
        var rowID: String
        var displayName: String
        var source: Source
        var needsCloudDownload: Bool
        /// The URL the caller handed in for this file (annotation key, `ImportItemResult.source`).
        var itemURL: URL?

        var localURL: URL? {
            if case .local(let url, _, _, _) = source { return url }
            return nil
        }
    }

    private struct Expansion: Sendable {
        var candidates: [Candidate] = []
        var toasts: [Toast] = []
        var cleanupRoots: [URL] = []          // promised folders to remove after the batch
    }

    private static let supplementPattern = #"(^|[_\-\s.])(supp|suppl|supplement(ary)?|SI|extended[_\s-]?data)([_\-\s.]|$)"#

    static func isSupplementName(_ name: String) -> Bool {
        name.range(of: supplementPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func expand(_ items: [IntakeItem], incoming: URL, library: URL, lang: UILang) -> Expansion {
        var out = Expansion()
        var skipped: [String] = []
        var capped = false
        var folderBudget = maxFolderPDFs
        var pdfDataCount = 0

        func add(_ url: URL, userFile: Bool, cleanup: URL?, itemURL: URL? = nil) {
            let name = url.lastPathComponent
            out.candidates.append(Candidate(rowID: UUID().uuidString.lowercased(), displayName: name,
                                            source: .local(url, originalName: name, userFile: userFile, cleanup: cleanup),
                                            needsCloudDownload: needsCloudDownload(url), itemURL: itemURL ?? url))
        }
        func addFolder(_ dir: URL, userFiles: Bool, cleanupEach: Bool) {
            let scan = scanFolder(dir, limit: folderBudget)
            folderBudget -= scan.files.count
            skipped += scan.skipped
            capped = capped || scan.capped
            for f in scan.files { add(f, userFile: userFiles, cleanup: cleanupEach ? f : nil) }
        }

        for item in items {
            switch item {
            case .file(let url):
                if isPlainDirectory(url) {
                    addFolder(url, userFiles: LibraryPaths.relativePath(of: url, root: library) == nil, cleanupEach: false)
                } else {
                    add(url, userFile: LibraryPaths.relativePath(of: url, root: library) == nil, cleanup: nil)
                }
            case .promised(let url):
                let ours = isInside(url, incoming)
                if isPlainDirectory(url) {
                    addFolder(url, userFiles: false, cleanupEach: ours)
                    if ours { out.cleanupRoots.append(url) }
                } else {
                    add(url, userFile: false, cleanup: ours ? url : nil)
                }
            case .pdfData(let data, let suggestedName):
                let dir = incoming.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
                let name = FileNamer.inboxPDFName(originalName: suggestedName.isEmpty ? "Dropped.pdf" : suggestedName)
                let file = dir.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try data.write(to: file, options: .atomic)
                    add(file, userFile: false, cleanup: dir)
                    out.candidates[out.candidates.count - 1].itemURL = nil
                    pdfDataCount += 1
                } catch {
                    Log.importer.error("could not stage dropped PDF data: \(FileOps.classify(error).description, privacy: .public)")
                    try? FileManager.default.removeItem(at: dir)
                    out.toasts.append(Toast(kind: .error, message: IntakeText.importFailed(
                        name, reason: IntakeText.reason(for: FileOps.classify(error), lang), lang)))
                }
            case .remote(let url):
                let name = url.lastPathComponent.isEmpty || url.lastPathComponent == "/" ? (url.host ?? url.absoluteString)
                    : url.lastPathComponent
                out.candidates.append(Candidate(rowID: UUID().uuidString.lowercased(), displayName: name,
                                                source: .remote(url), needsCloudDownload: false, itemURL: url))
            }
        }
        if pdfDataCount > 0 { out.toasts.append(Toast(kind: .info, message: IntakeText.pdfDataPartial(lang))) }
        if !skipped.isEmpty { out.toasts.append(Toast(kind: .info, message: IntakeText.skippedSupplements(skipped, lang))) }
        if capped { out.toasts.append(Toast(kind: .warning, message: IntakeText.folderCapped(maxFolderPDFs, lang))) }
        return out
    }

    /// `*.pdf` files under `root` (recursive; hidden items and package contents skipped),
    /// sorted by path. In a folder that holds another PDF, supplement-looking names are
    /// skipped and reported.
    private static func scanFolder(_ root: URL, limit: Int) -> (files: [URL], skipped: [String], capped: Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return ([], [], false)
        }
        var byFolder: [String: [URL]] = [:]
        for case let url as URL in walker {
            guard url.pathExtension.lowercased() == "pdf",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            byFolder[url.deletingLastPathComponent().standardizedFileURL.path, default: []].append(url)
        }
        var files: [URL] = []
        var skipped: [String] = []
        for (_, group) in byFolder {
            let main = group.filter { !isSupplementName($0.lastPathComponent) }
            if main.isEmpty {
                files += group
            } else {
                files += main
                skipped += group.filter { isSupplementName($0.lastPathComponent) }.map(\.lastPathComponent)
            }
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let capped = files.count > max(0, limit)
        return (Array(files.prefix(max(0, limit))), skipped.sorted(), capped)
    }

    private static func isPlainDirectory(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return v?.isDirectory == true && v?.isPackage != true
    }

    /// iCloud/OneDrive placeholder that a coordinated read will have to download first.
    private static func needsCloudDownload(_ url: URL) -> Bool {
        guard FileOps.isUbiquitous(url) else { return false }
        var u = url
        u.removeAllCachedResourceValues()
        let status = (try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
        return status != .current
    }

    /// The sync app of a cloud placeholder, for the toast ("OneDrive", "Dropbox"…; iCloud Drive
    /// reads "iCloud" as before).
    private static func cloudProvider(_ url: URL?) -> String? {
        guard let path = url?.path, let app = CloudPathHint.providerName(forPath: path) else { return nil }
        return app == "iCloud Drive" ? "iCloud" : app
    }

    private static func isInside(_ url: URL, _ root: URL) -> Bool {
        LibraryPaths.relativePath(of: url, root: root) != nil
    }

    /// Deletes one of our own staging items (never anything outside caches/incoming), then
    /// its parent folder when that is an empty `incoming/<uuid>/`.
    private static func removeIncoming(_ url: URL, incoming: URL) {
        guard isInside(url, incoming) else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        let parent = url.deletingLastPathComponent()
        if isInside(parent, incoming), (try? fm.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
            try? fm.removeItem(at: parent)
        }
    }

    // MARK: - Library files (blocking)

    /// `.partial/<uuid>.pdf` → `_Inbox/<sha8>/<sanitized original name>`.
    private static func placeInInbox(_ partial: URL, inbox: URL, sha256: String, originalName: String) throws -> (URL, String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path))?.filter { !$0.hasPrefix(".") } ?? []
        let folderName = FileNamer.uniqueName(FileNamer.inboxFolderName(sha: sha256, originalName: originalName),
                                              existing: Set(names))
        let folder = inbox.appendingPathComponent(folderName, isDirectory: true)
        try FileOps.createFolder(folder)
        let pdfName = FileNamer.inboxPDFName(originalName: originalName)
        do {
            try FileOps.atomicRename(from: partial, to: folder.appendingPathComponent(pdfName))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return (folder, pdfName)
    }

    /// Undoes `placeInInbox`: the copy goes back to `partial` and the (now empty) folder away.
    private static func unplace(_ folder: URL, pdfName: String, backTo partial: URL) {
        let placed = folder.appendingPathComponent(pdfName)
        if FileManager.default.fileExists(atPath: placed.path) {
            do { try FileOps.atomicRename(from: placed, to: partial) } catch {
                Log.importer.error("could not move \(pdfName, privacy: .public) back to .partial: \(FileOps.classify(error).description, privacy: .public)")
                try? FileManager.default.removeItem(at: placed)
            }
        }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Parks `current` in a fresh, dated `.recently-deleted/.replaced/` entry (purged with
    /// 最近删除 after 30 days, see `ReplacedPDFs`) and moves `replacement` to `current`.
    /// Returns where the old file went (nil if it was already missing).
    private static func swapPDF(current: URL, folderName: String, paths: AppPaths, at date: Date,
                                replacement: URL) throws -> URL? {
        let fm = FileManager.default
        var backup: URL?
        if fm.fileExists(atPath: current.path) {
            let dir = try ReplacedPDFs.makeEntry(in: paths, paperFolder: folderName, at: date)
            let dest = dir.appendingPathComponent(current.lastPathComponent)
            do {
                try FileOps.atomicRename(from: current, to: dest)
            } catch {
                try? fm.removeItem(at: dir)
                throw error
            }
            backup = dest
        }
        do {
            try FileOps.atomicRename(from: replacement, to: current)
        } catch {
            if let backup {
                try? FileOps.atomicRename(from: backup, to: current)
                try? fm.removeItem(at: backup.deletingLastPathComponent())
            }
            throw error
        }
        return backup
    }

    /// Card title before metadata arrives: the file name, underscores as spaces.
    static func title(fromFileName name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let spaced = stem.replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return spaced.isEmpty ? FileNamer.fallbackName : spaced
    }
}

// MARK: - Small helpers

/// Result slot for the accessor's blocking DB lookup.
private final class LookupBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Paper?
    func set(_ v: Paper?) { lock.withLock { value = v } }
    func get() -> Paper? { lock.withLock { value } }
}

/// Why a commit failed (the details are logged).
private enum CommitFailure: Sendable {
    case file(FileOpsError)          // moving the copy into `_Inbox/` (or, on replace, the swap)
    case database                    // the insert / update
}

/// Set from inside a DB transaction closure, read after it.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Where the insert transaction put the staged copy (to undo it if COMMIT fails).
private final class PlacedCopy: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (folder: URL, pdfName: String)?
    func set(_ folder: URL, pdfName: String) { lock.withLock { value = (folder, pdfName) } }
    func clear() { lock.withLock { value = nil } }
    func get() -> (folder: URL, pdfName: String)? { lock.withLock { value } }
}

/// Download progress → at most one row update per 5 %.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Double?
    private var sentUnknown = false

    func shouldEmit(_ fraction: Double?) -> Bool {
        lock.withLock {
            guard let f = fraction else {
                if sentUnknown { return false }
                sentUnknown = true
                return true
            }
            if let last, f < 1, f - last < 0.05 { return false }
            if let last, last >= 1 { return false }
            last = f
            return true
        }
    }
}

/// zh/en strings produced by the intake stage (rows and toasts, §8).
/// zh/en texts of the import pipeline (internal: `MailMachineText` re-words the stored failure reasons).
enum IntakeText {
    static func t(_ lang: UILang, _ zh: String, _ en: String) -> String { lang == .zh ? zh : en }

    static func shortTitle(_ s: String) -> String { s.count > 60 ? String(s.prefix(59)) + "…" : s }

    // Success
    static func added(_ title: String, chip: String, _ l: UILang) -> String {
        t(l, "已添加：\(shortTitle(title)) · DDL \(chip)", "Added: \(shortTitle(title)) · due \(chip)")
    }
    static func addedBatch(_ n: Int, lastChip: String?, _ l: UILang) -> String {
        guard let lastChip else { return t(l, "已添加 \(n) 篇论文", "Added \(n) papers") }
        return t(l, "已添加 \(n) 篇论文 · 最后 DDL \(lastChip)", "Added \(n) papers · last due \(lastChip)")
    }
    static func replaced(_ title: String, _ l: UILang) -> String {
        t(l, "已替换为新文件：\(shortTitle(title))", "Replaced with the new file: \(shortTitle(title))")
    }
    static func view(_ l: UILang) -> String { t(l, "查看", "View") }
    static func setHighPriority(_ l: UILang) -> String { t(l, "设为高优先级", "Set high priority") }

    // Dedupe
    static func alreadyInLibrary(_ title: String, _ l: UILang) -> String {
        t(l, "已在库中：\(shortTitle(title))", "Already in your library: \(shortTitle(title))")
    }
    static func linkedExisting(_ title: String, _ l: UILang) -> String {
        t(l, "已在库中，已关联到邮件：\(shortTitle(title))", "Already in your library — linked to the email: \(shortTitle(title))")
    }
    static func inRecentlyDeleted(_ title: String, _ l: UILang) -> String {
        t(l, "已在「最近删除」中：\(shortTitle(title))", "In Recently Deleted: \(shortTitle(title))")
    }
    static func restore(_ l: UILang) -> String { t(l, "恢复", "Restore") }
    static func sameWork(existing: Int?, new: Int?, title: String, newName: String, _ l: UILang) -> String {
        if let existing, let new {
            return t(l, "同一论文已在库中（v\(existing)）· 新文件 v\(new)",
                     "Same paper already in your library (v\(existing)) · new file v\(new)")
        }
        return t(l, "同一论文已在库中：\(shortTitle(title)) · 新文件 \(newName)",
                 "Same paper already in your library: \(shortTitle(title)) · new file \(newName)")
    }
    static func replaceKeepingChecklist(_ l: UILang) -> String { t(l, "替换并保留清单", "Replace, keep checklist") }
    static func ignore(_ l: UILang) -> String { t(l, "忽略", "Ignore") }

    // Receiving
    static func pdfDataPartial(_ l: UILang) -> String {
        t(l, "拖入的 PDF 可能只包含所选页面", "The dropped PDF may contain only the selected pages")
    }
    static func skippedSupplements(_ names: [String], _ l: UILang) -> String {
        let shown = names.prefix(5).joined(separator: l == .zh ? "、" : ", ") + (names.count > 5 ? "…" : "")
        return t(l, "已跳过 \(names.count) 个补充材料：\(shown)", "Skipped \(names.count) supplementary file(s): \(shown)")
    }
    static func folderCapped(_ limit: Int, _ l: UILang) -> String {
        t(l, "PDF 超过 \(limit) 个，只导入了前 \(limit) 个", "More than \(limit) PDFs — imported the first \(limit)")
    }
    static func cloudWaiting(_ n: Int, provider: String?, _ l: UILang) -> String {
        t(l, "正在从 \(provider ?? "云端") 下载 \(n) 个文件…",
          "Downloading \(n) file(s) from \(provider ?? "the cloud")…")
    }
    static func originalsKept(_ n: Int, _ l: UILang) -> String {
        n == 1 ? t(l, "原文件已保留", "Original file kept") : t(l, "\(n) 个原文件已保留", "\(n) original files kept")
    }

    // Links
    static func openInBrowser(_ l: UILang) -> String { t(l, "在浏览器打开", "Open in browser") }
    static func cannotDownload(_ l: UILang) -> String { t(l, "无法下载 PDF", "Couldn't download a PDF from this link") }
    static func reasonNotPDFLink(_ l: UILang) -> String { t(l, "不是 PDF 链接", "Not a PDF link") }
    static func reasonBlocked(_ l: UILang) -> String {
        t(l, "不会从本地或内网地址下载", "PaperDeck doesn't download from local or private network addresses")
    }
    static func reasonLinkNotPDF(_ l: UILang) -> String { t(l, "链接内容不是 PDF", "The link didn't return a PDF") }
    static func downloadFailed(status: Int?, _ l: UILang) -> String {
        guard let status else { return t(l, "下载失败", "Download failed") }
        return t(l, "下载失败（\(status)）", "Download failed (\(status))")
    }

    // Failures
    static func reasonNotPDF(_ l: UILang) -> String { t(l, "不是 PDF", "Not a PDF") }
    static func notPDF(_ name: String, _ l: UILang) -> String {
        t(l, "无法导入 \(name)：不是 PDF", "Can't import \(name): not a PDF")
    }
    static func importFailed(_ name: String, reason: String, _ l: UILang) -> String {
        t(l, "无法导入 \(name)：\(reason)", "Can't import \(name): \(reason)")
    }
    static func dropAgain(_ name: String, reason: String, _ l: UILang) -> String {
        t(l, "\(name)：\(reason)", "\(name): \(reason)")
    }
    static func reasonAborted(_ l: UILang) -> String { t(l, "导入已暂停", "Import paused") }
    static func paused(_ e: FileOpsError, _ l: UILang) -> String {
        e == .diskFull ? t(l, "磁盘空间不足，导入已暂停", "Disk is full — import paused")
            : t(l, "资料库不可用，导入已暂停", "Library folder unavailable — import paused")
    }
    static func reason(for e: FileOpsError, _ l: UILang) -> String {
        switch e {
        case .notPDF: return reasonNotPDF(l)
        case .sourceMissing, .permissionDenied: return t(l, "无法读取，请重新拖入", "Couldn't read it — please drop it again")
        case .timeout: return t(l, "从云端下载超时，请重新拖入", "Cloud download timed out — please drop it again")
        case .diskFull: return t(l, "磁盘空间不足", "Disk is full")
        case .libraryUnavailable: return t(l, "资料库不可用", "Library folder unavailable")
        case .hashMismatch: return t(l, "复制校验失败", "Copy verification failed")
        case .destinationExists, .io: return t(l, "文件读写失败", "Couldn't read or write the file")
        }
    }
    static func reasonLibraryWrite(_ l: UILang) -> String { t(l, "写入资料库失败", "Couldn't write to the library") }
    /// Why a commit (or a replace) failed, for the row and the toast (details are logged).
    fileprivate static func commitReason(_ failure: CommitFailure, _ l: UILang) -> String {
        switch failure {
        case .file(let e) where e == .diskFull || e == .libraryUnavailable || e == .sourceMissing: return reason(for: e, l)
        case .file, .database: return reasonLibraryWrite(l)
        }
    }

    /// Added, but Claude won't read it.
    static func flagWarning(_ flags: PaperFlags, name: String, _ l: UILang) -> String? {
        if flags.contains(.locked) { return t(l, "PDF 已加密：\(name)（已添加，不会解读）", "Encrypted PDF: \(name) (added, won't be read)") }
        if flags.contains(.unreadable) { return t(l, "无法解析 PDF：\(name)（已添加，不会解读）", "Couldn't parse PDF: \(name) (added, won't be read)") }
        if flags.contains(.scanned) { return t(l, "扫描版 PDF：\(name)（已添加，不会解读）", "Scanned PDF: \(name) (added, won't be read)") }
        return nil
    }
}
