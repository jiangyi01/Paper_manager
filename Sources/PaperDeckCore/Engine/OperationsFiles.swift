import Foundation

// 最近删除 (§5): soft delete moves the paper folder to `.recently-deleted/`, restore moves it
// back, and after 30 days (or 永久删除) the row is hard-deleted and the folder goes to the
// Trash. Folder renames run inside the same Database call that rewrites `folder`, so a
// sidecar write can never resolve a half-moved path (SidecarWriter rule, §5), and filing
// (EnrichActor), delete, restore and purge never interleave on one paper.

extension Engine {
    /// How long 最近删除 keeps a paper before `purgeExpired` removes it.
    package static let recentlyDeletedRetention: TimeInterval = 30 * 86_400

    /// 移到最近删除 ⌘⌫: cancels the paper's agent job, moves its folder to
    /// `.recently-deleted/<name>` (unique name), sets `deleted_at`. A folder that is not where
    /// the row says (moved/renamed in Finder since the last launch) is found by its card.json
    /// id and taken along, so it can't stay behind under Papers/ and be adopted back later.
    @discardableResult
    package func softDelete(paperID: String) async throws -> Paper {
        let pk = try await PaperOpsSupport.livePK(db, paperID)
        // "Possibly unpublished — confirm before AI reading" is a fact about the file, not only its
        // job's: it outlives the cancelled job (the assist surfaces and the duplicate history read it).
        let before = try await db.paper(pk: pk)
        let unpublished = before?.aiNote == ImportAnnotation.unpublishedHoldNote
        // The reading it waited for (held, queued or running) comes back with a restore.
        let waiting = try await db.activeJob(paperPK: pk).map { TrashedJob($0, note: before?.aiNote) }
        await agents.cancel(paperPK: pk)
        let library = paths.library, bin = paths.recentlyDeleted, papers = paths.papers, inbox = paths.inbox
        let now = ctx.now()
        let saved = try await db.transaction { db -> Paper in
            var p = try PaperOpsSupport.live(db, pk: pk, id: paperID)
            if unpublished { p.aiNote = ImportAnnotation.unpublishedHoldNote }
            try db.setTrashedJob(waiting, paperID: p.id)
            try? FileOps.createFolder(bin)
            var src = LibraryPaths.folderURL(forRelative: p.folder, library: library)
            var name = OpsFiles.folderName(p)
            if !PaperOpsSupport.itemExists(src),
               let found = try OpsFiles.foldersClaiming(p, db: db, papers: papers, inbox: inbox, library: library).first {
                src = found.url
                name = found.url.lastPathComponent
                if let pdf = found.pdfName { p.pdfName = pdf }
            }
            let dst = bin.appendingPathComponent(PaperOpsSupport.uniqueChildName(name, in: bin), isDirectory: true)
            let moved = try OpsFiles.moveIfPresent(src, to: dst)
            p.folder = OpsFiles.relative(dst, library: library)
            p.deletedAt = now
            if moved && PaperOpsSupport.itemExists(dst.appendingPathComponent(p.pdfName)) {
                p.flags.remove(.missing)
            } else {
                p.flags.insert(.missing)
            }
            do {
                return try db.updatePaper(p, now: now)
            } catch {
                if moved { try? FileOps.moveFolder(from: dst, to: src) }
                throw error
            }
        }
        await ctx.syncSidecar(pk: pk)
        return saved
    }

    /// 恢复: moves the folder back under Papers/ (or Papers/_Inbox/ while not yet filed) with
    /// a unique name and clears `deleted_at`. Throws `.restoreConflict` when a live paper has
    /// the same DOI (either bioRxiv prefix) or arXiv id now. A paper deleted before the
    /// pipeline finished it goes back to EnrichActor (held AI, like a relaunch's resume); a ready
    /// paper gets back the reading its delete cancelled (`TrashedJob`): held when it was held or
    /// is possibly unpublished, else queued (a running one starts over).
    @discardableResult
    package func restore(paperID: String) async throws -> Paper {
        guard let current = try await db.paper(id: paperID) else { throw PaperOperationError.paperNotFound(paperID) }
        guard current.isDeleted else { throw PaperOperationError.paperNotDeleted(paperID) }
        let pk = current.pk
        let library = paths.library, bin = paths.recentlyDeleted, papers = paths.papers, inbox = paths.inbox
        let now = ctx.now()
        var saved = try await db.transaction { db -> Paper in
            guard var p = try db.paper(pk: pk) else { throw PaperOperationError.paperNotFound(paperID) }
            guard p.isDeleted else { throw PaperOperationError.paperNotDeleted(paperID) }
            if let other = try OpsFiles.liveSameIdentifier(db, as: p) {
                throw PaperOperationError.restoreConflict(paperID: other.id, title: other.title)
            }
            let name = OpsFiles.folderName(p)
            let src = bin.appendingPathComponent(name, isDirectory: true)
            let parent = p.stage == .committed || p.stage == .enriched ? inbox : papers
            let dst = parent.appendingPathComponent(PaperOpsSupport.uniqueChildName(name, in: parent), isDirectory: true)
            let moved = try OpsFiles.moveIfPresent(src, to: dst)
            p.folder = OpsFiles.relative(dst, library: library)
            p.deletedAt = nil
            if moved && PaperOpsSupport.itemExists(dst.appendingPathComponent(p.pdfName)) {
                p.flags.remove(.missing)
            } else {
                p.flags.insert(.missing)
            }
            do {
                return try db.updatePaper(p, now: now)
            } catch {
                if moved { try? FileOps.moveFolder(from: dst, to: src) }
                if let e = error as? SQLiteError, e.isUniqueViolation {
                    let other = (try? OpsFiles.liveSameIdentifier(db, as: p)) ?? nil
                    throw PaperOperationError.restoreConflict(paperID: other?.id ?? "", title: other?.title ?? "")
                }
                throw error
            }
        }
        if saved.stage == .ready {
            saved = await requeueTrashedJob(saved)
        } else {
            try? await db.setTrashedJob(nil, paperID: saved.id)      // the pipeline's resume decides
        }
        await ctx.syncSidecar(pk: pk)
        if saved.stage != .ready { await enrich.submit(pk: pk, holdAI: true) }
        return saved
    }

    /// A restored ready paper's reading its delete cancelled (`TrashedJob`), as an active job
    /// again — in its own transaction, so a failure here never undoes the restore. Unless a job
    /// is active already. Returns the row.
    private func requeueTrashedJob(_ p: Paper) async -> Paper {
        let now = ctx.now()
        do {
            let row = try await db.transaction { db -> Paper? in
                guard let job = try db.takeTrashedJob(paperID: p.id) else { return nil }
                guard let current = try db.paper(pk: p.pk), current.isLive, current.stage == .ready,
                      [.held, .queued, .running].contains(job.state), try db.activeJob(paperPK: p.pk) == nil else { return nil }
                let unpublished = current.aiNote == ImportAnnotation.unpublishedHoldNote
                let hold = job.state == .held || unpublished
                var waiting = current
                waiting.aiState = hold ? .held : .queued
                waiting.aiNote = unpublished ? ImportAnnotation.unpublishedHoldNote
                    : hold && job.note == AgentQueue.modeOffNote ? AgentQueue.modeOffNote : nil
                waiting = try db.updatePaper(waiting, now: now)
                guard try AgentQueue.recreateLostJob(for: waiting, db: db, providerID: job.provider, now: now) else {
                    return waiting
                }
                if job.priority != 0, var active = try db.activeJob(paperPK: p.pk) {
                    active.priority = job.priority
                    try db.updateJob(active)
                }
                return try db.paper(pk: p.pk) ?? waiting
            }
            guard let row else { return p }
            await agents.jobsChanged()
            return row
        } catch {
            Log.storage.error("restore: the reading of \(p.id, privacy: .public) was not queued again: \(String(describing: error), privacy: .public)")
            return p
        }
    }

    /// Hard-deletes papers soft-deleted at least `age` ago: DB row (checklist, tags, jobs,
    /// FTS rows cascade), folder → Trash (`trash` is injectable for tests), cached text and
    /// thumbnails. Each paper is re-read inside the Database call that trashes and deletes
    /// it, so one restored (or deleted again) since the list was read is left alone. A folder
    /// that can't be trashed keeps its row for the next run. Old PDFs parked by
    /// 「替换并保留清单」 follow the same retention. Returns the purged paper ids.
    @discardableResult
    package func purgeExpired(olderThan age: TimeInterval = Engine.recentlyDeletedRetention,
                              trash: @escaping @Sendable (URL) -> Bool = { FileOps.trash($0) }) async throws -> [String] {
        let cutoff = ctx.now().addingTimeInterval(-age)
        let expired = try await db.deletedPapers().filter { ($0.deletedAt ?? .distantFuture) <= cutoff }
        var purged: [String] = []
        for p in expired {
            if try await OpsFiles.hardRemove(self, p, scope: .stillDeleted(cutoff: cutoff), trash: trash) == .removed {
                purged.append(p.id)
            }
        }
        let parkedRoot = ReplacedPDFs.root(paths)
        let parked = await BlockingIO.run { ReplacedPDFs.expired(root: parkedRoot, cutoff: cutoff) }
        for entry in parked {
            let trashed = await BlockingIO.run { trash(entry) }
            if !trashed {
                Log.storage.error("purge: could not trash replaced PDF \(entry.lastPathComponent, privacy: .public)")
            }
        }
        return purged
    }

    /// 永久删除 (from 最近删除, or directly): same as a purge, right now, of the paper as it
    /// is at that moment (its current folder, even if it was restored or refiled meanwhile).
    package func deleteNow(paperID: String, trash: @escaping @Sendable (URL) -> Bool = { FileOps.trash($0) }) async throws {
        guard let p = try await db.paper(id: paperID) else { throw PaperOperationError.paperNotFound(paperID) }
        await agents.cancel(paperPK: p.pk)
        switch try await OpsFiles.hardRemove(self, p, scope: .asIsNow, trash: trash) {
        case .removed, .alreadyGone, .skipped: return
        case .trashFailed(let name): throw PaperOperationError.trashFailed(name)
        }
    }
}

enum OpsFiles {
    static func folderName(_ p: Paper) -> String { (p.folder as NSString).lastPathComponent }

    /// Library-relative path ("Papers/…", ".recently-deleted/…") of a URL built under `library`.
    static func relative(_ url: URL, library: URL) -> String {
        LibraryPaths.relativePath(of: url, root: library)
            ?? url.pathComponents.suffix(url.deletingLastPathComponent().lastPathComponent == "_Inbox" ? 3 : 2)
                .joined(separator: "/")
    }

    /// Moves a folder (no clobber). False when `src` doesn't exist; file errors are typed.
    static func moveIfPresent(_ src: URL, to dst: URL) throws -> Bool {
        guard PaperOpsSupport.itemExists(src) else { return false }
        do { try FileOps.moveFolder(from: src, to: dst) } catch {
            throw PaperOperationError.fileOperation(FileOps.classify(error).description)
        }
        return true
    }

    /// Another live paper holding the same DOI (both bioRxiv prefixes count as one) or
    /// arXiv id — the same work must not be live twice.
    static func liveSameIdentifier(_ db: isolated Database, as p: Paper) throws -> Paper? {
        if let doi = p.ids.doi, let m = try db.livePaper(holdingDOI: doi, excluding: p.pk) {
            return m
        }
        if let arxiv = p.ids.arxivID,
           let m = try db.paperMatchingWork(doi: nil, arxivID: arxiv, publishedDOI: nil, excluding: p.pk) {
            return m
        }
        return nil
    }

    /// Folders under Papers/ and Papers/_Inbox/ that no row points at and whose card.json
    /// names `p`'s id — where a folder moved/renamed in Finder went. Blocking; call inside a
    /// Database transaction so no filing/restore can move folders meanwhile.
    static func foldersClaiming(_ p: Paper, db: isolated Database, papers: URL, inbox: URL,
                                library: URL) throws -> [(url: URL, pdfName: String?)] {
        let candidates = StorageTools.subfolders(papers).filter { $0.lastPathComponent != inbox.lastPathComponent }
            + StorageTools.subfolders(inbox)
        guard !candidates.isEmpty else { return [] }
        let referenced = Set(try db.allPapers().map { StorageTools.folderKey($0.folder) })
        var out: [(url: URL, pdfName: String?)] = []
        for folder in candidates where !referenced.contains(StorageTools.folderKey(relative(folder, library: library))) {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(CardSidecar.fileName)),
                  let card = try? CardSidecar.decoded(from: data), card.id.lowercased() == p.id.lowercased() else { continue }
            let pdf = SidecarRestore.resolvePDF(in: folder, preferred: [p.pdfName, card.pdf,
                                                                       FileNamer.pdfName(forFolder: folder.lastPathComponent)])
            out.append((folder, pdf))
        }
        return out
    }

    /// Which row state a hard removal may act on.
    enum RemovalScope: Sendable, Equatable {
        /// Purge: only while the row is still soft-deleted — at or before `cutoff` when given —
        /// in the folder the caller's snapshot names.
        case stillDeleted(cutoff: Date?)
        /// 永久删除: the paper as it is now (live or deleted), in its current folder.
        case asIsNow
    }

    /// A folder the Trash refused: the removal's Database call rolls back.
    private struct TrashRefused: Error { let name: String }

    enum RemovalOutcome: Sendable, Equatable {
        case removed
        case alreadyGone                 // no row any more
        case skipped                     // restored / deleted again / moved since the snapshot
        case trashFailed(String)         // folder name that could not be trashed (row kept)
    }

    /// Re-reads the row and, in that same Database call, deletes the row (writing its tombstone
    /// and moving its open duplicate questions first) and then trashes its folder (plus any
    /// unreferenced folder claiming its id when the recorded one is gone): a folder that can't be
    /// trashed — or a row that can't be removed — rolls the whole call back, so the row and its
    /// folder always go together. Its pending card.json write, cached text and thumbnails follow.
    static func hardRemove(_ engine: Engine, _ p: Paper, scope: RemovalScope = .stillDeleted(cutoff: nil),
                           trash: @escaping @Sendable (URL) -> Bool) async throws -> RemovalOutcome {
        let library = engine.paths.library, papers = engine.paths.papers, inbox = engine.paths.inbox
        // Reading history survives the 30-day purge as a metadata-only tombstone (duplicate check,
        // DQ §3.1) — not "Delete Permanently" (the user asked for the paper to be gone), and never
        // for a paper whose title or identifiers are private (`Database.mayRemember`).
        let dedupe = engine.ctx.loadSettings().dedupe
        let remember = dedupe.enabled && dedupe.history && scope != .asIsNow
        let now = engine.ctx.now()
        let result: (RemovalOutcome, [DupReview])
        do {
            result = try await engine.db.transaction { db -> (RemovalOutcome, [DupReview]) in
                guard let current = try db.paper(pk: p.pk) else { return (.alreadyGone, []) }
                if case .stillDeleted(let cutoff) = scope {
                    guard let deletedAt = current.deletedAt, current.folder == p.folder else { return (.skipped, []) }
                    if let cutoff, deletedAt > cutoff { return (.skipped, []) }
                }
                let folder = LibraryPaths.folderURL(forRelative: current.folder, library: library)
                // Not where the row says: a copy claiming this id under Papers/ would otherwise be
                // adopted back as a live paper once the row is gone.
                let folders = PaperOpsSupport.itemExists(folder) ? [folder]
                    : try foldersClaiming(current, db: db, papers: papers, inbox: inbox, library: library).map(\.url)
                // Open duplicate reviews that compared a new paper with this one now compare it with
                // the tombstone (or end, releasing the held paper, when none is kept).
                let history = try remember && db.mayRemember(current) ? db.writeTombstone(current, at: now) : nil
                let released = try db.retargetOpenDupReviews(existing: current.pk, to: nil, history: history, now: now)
                try db.setTrashedJob(nil, paperID: current.id)
                try db.hardDelete(pk: current.pk)
                for url in folders where !trash(url) { throw TrashRefused(name: url.lastPathComponent) }
                return (.removed, released)
            }
        } catch let refused as TrashRefused {
            result = (.trashFailed(refused.name), [])
        }
        let (outcome, released) = result
        switch outcome {
        case .removed:
            if !released.isEmpty { await engine.releaseDuplicateHolds(released) }
            await engine.ctx.sidecars.discard(paperID: p.id)
            let texts = engine.ctx.texts, thumbs = engine.ctx.thumbs, id = p.id
            await BlockingIO.run {
                _ = texts.delete(id: id)
                thumbs.delete(id: id)
            }
        case .trashFailed(let name):
            Log.storage.error("purge: could not trash \(name, privacy: .public); keeping the row")
        case .alreadyGone, .skipped:
            break
        }
        return outcome
    }
}
