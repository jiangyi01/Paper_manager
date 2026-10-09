import Foundation

/// The slow half of the import pipeline (DESIGN §6.1): canonical metadata → filing into
/// `Papers/YYYY_Author_Title` → ready (AI job decision). Runs up to four papers at a time;
/// network traffic goes through the resolver's HostGate. Every step persists `paper.stage`,
/// so `resume()` continues papers whose stage ≠ ready after a crash or quit, and each step
/// is idempotent (re-running it after a crash never duplicates folders or jobs).
/// Every paper that reaches [ready] is offered to `MailMatcher`, so email rows waiting for that
/// PDF are satisfied whatever brought it in (MAIL_DESIGN §3 anywhere-drop matching).
package actor EnrichActor {
    package static let maxConcurrent = 4

    let ctx: EngineContext
    let resolverFactory: @Sendable (EngineSettings) -> MetadataResolver?
    let onReady: @Sendable (_ pk: Int64, _ holdAI: Bool) async -> Void

    /// Options for one queued/running paper.
    private struct Job {
        var holdAI: Bool
        var policy: BatchAIPolicy
        var row: ImportRowUpdate?          // the panel row that imported it (nil after a relaunch)
        var aiPriority = 0                 // AgentJob.priority of the reading job (1 = advisor request)
        var holdUnlessIdentified = false   // a person's emailed PDF: hold when no DOI/arXiv id resolves
    }

    private var jobs: [Int64: Job] = [:]              // queued or running
    private var queue: [Int64] = []
    private var running: [Int64: Task<Void, Never>] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Callers waiting for one paper's pipeline to finish (`waitUntilSettled(pk:)`).
    private var paperWaiters: [Int64: [CheckedContinuation<Void, Never>]] = [:]
    private var filingBusy = false
    private var filingWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopped = false

    package init(ctx: EngineContext,
                 resolverFactory: @escaping @Sendable (EngineSettings) -> MetadataResolver?,
                 onReady: @escaping @Sendable (_ pk: Int64, _ holdAI: Bool) async -> Void) {
        self.ctx = ctx; self.resolverFactory = resolverFactory; self.onReady = onReady
    }

    // MARK: - Queue

    /// Queue a committed paper for metadata → filing → ready. Never waits for the work.
    /// `ai` is the batch's AI policy (`.skip` → no job); `row` is the panel row to finish
    /// with `.queuedForAI` when a job is queued right away. Re-submitting a queued or
    /// running paper only updates its options. `aiPriority` becomes the reading job's priority
    /// (email merges: advisor requests are read first); `holdUnlessIdentified` holds the job
    /// with `ImportAnnotation.unpublishedHoldNote` when the paper ends up without a DOI/arXiv id.
    package func submit(pk: Int64, holdAI: Bool, ai: BatchAIPolicy = .automatic, row: ImportRowUpdate? = nil,
                        aiPriority: Int = 0, holdUnlessIdentified: Bool = false) {
        guard !stopped else { return }
        if var job = jobs[pk] {
            job.holdAI = holdAI
            job.policy = ai
            if row != nil { job.row = row }
            job.aiPriority = aiPriority
            job.holdUnlessIdentified = holdUnlessIdentified
            jobs[pk] = job
            return
        }
        jobs[pk] = Job(holdAI: holdAI, policy: ai, row: row, aiPriority: aiPriority,
                       holdUnlessIdentified: holdUnlessIdentified)
        queue.append(pk)
        pump()
    }

    /// Re-queue every live paper whose stage ≠ ready (after a crash/quit). Returns once they
    /// are queued; `waitUntilIdle()` waits for them. AI jobs of resumed papers are created
    /// held — the batch that imported them may have needed confirmation, and that answer
    /// did not survive the relaunch — never spending quota without the user's say-so.
    package func resume() async {
        guard let stuck = try? await ctx.db.papers(notInStage: .ready) else { return }
        for p in stuck where jobs[p.pk] == nil {
            submit(pk: p.pk, holdAI: true, ai: .automatic)
        }
    }

    /// Returns when `pk` is neither queued nor running: a duplicate merge moves the paper's folder
    /// and PDF, which must not race its filing.
    package func waitUntilSettled(pk: Int64) async {
        guard jobs[pk] != nil || running[pk] != nil else { return }
        await withCheckedContinuation { paperWaiters[pk, default: []].append($0) }
    }

    /// Returns when nothing is queued or running (tests, CLI self-tests).
    package func waitUntilIdle() async {
        if running.isEmpty && queue.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// Stops taking work and cancels what runs. Interrupted papers keep their persisted
    /// stage (a cancelled lookup never advances it), so the next launch resumes them.
    package func shutdown() async {
        stopped = true
        for pk in queue {
            jobs[pk] = nil
            for w in paperWaiters.removeValue(forKey: pk) ?? [] { w.resume() }
        }
        queue.removeAll()
        let tasks = Array(running.values)
        for t in tasks { t.cancel() }
        for t in tasks { await t.value }
        resumeIdleWaitersIfIdle()
    }

    private func pump() {
        while !stopped, running.count < Self.maxConcurrent, !queue.isEmpty {
            let pk = queue.removeFirst()
            running[pk] = Task { await self.run(pk) }
        }
        resumeIdleWaitersIfIdle()
    }

    private func run(_ pk: Int64) async {
        await process(pk)
        running[pk] = nil
        jobs[pk] = nil
        for w in paperWaiters.removeValue(forKey: pk) ?? [] { w.resume() }
        pump()
    }

    private func resumeIdleWaitersIfIdle() {
        guard running.isEmpty, queue.isEmpty, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    /// committed → enriched → filed → ready, re-reading the row before every step.
    private func process(_ pk: Int64) async {
        guard let paper = try? await ctx.db.paper(pk: pk), paper.isLive else { return }
        var stage = paper.stage
        if stage == .committed {
            guard await enrichStep(pk: pk, forceRefresh: false, advanceStage: true) != nil else { return }
            stage = .enriched
        }
        guard !Task.isCancelled else { return }
        if stage == .enriched {
            guard case .done = await fileStep(pk: pk, advanceStage: true) else { return }
            stage = .filed
        }
        guard !Task.isCancelled else { return }
        if stage == .filed { await readyStep(pk: pk) }
    }

    // MARK: - Card actions

    /// "Refresh metadata" on a card: re-resolves bypassing the cache, merges, then refiles
    /// if the canonical name changed. Returns true when anything changed.
    package func refreshMetadata(pk: Int64) async -> Bool {
        guard resolverFactory(await ctx.settings()) != nil else { return false }
        let changed = await enrichStep(pk: pk, forceRefresh: true, advanceStage: false) ?? false
        let moved = await refile(pk: pk)
        if changed { await MailMatcher.paperReady(pk: pk, ctx: ctx) }     // new ids may satisfy an email
        return changed || moved
    }

    /// Renames the folder/PDF when the canonical name (year, first author, title) no longer
    /// matches — after an agent card or a metadata edit. No-op while the pipeline has not
    /// filed the paper yet (it files with the fresh metadata) or when only a `_2` style
    /// collision suffix differs. Returns true when something moved.
    @discardableResult
    package func refile(pk: Int64) async -> Bool {
        guard let p = try? await ctx.db.paper(pk: pk), p.isLive, Self.order(p.stage) >= Self.order(.filed) else {
            return false
        }
        let base = FileNamer.folderName(year: p.year, firstAuthor: p.authors.first, title: p.title)
        let current = (p.folder as NSString).lastPathComponent
        let inPapersRoot = (p.folder as NSString).deletingLastPathComponent == Self.papersRelative(ctx.paths)
        if inPapersRoot, Self.nameVariants(of: base).contains(current) {
            let final = Self.isFinalName(p.metaSource)
            if p.nameFinal != final {
                _ = try? await ctx.db.modifyPaper(pk: pk, now: ctx.now()) { $0.nameFinal = final }
                await ctx.syncSidecar(pk: pk)
            }
            return false
        }
        if case .done(let changed) = await fileStep(pk: pk, advanceStage: false) { return changed }
        return false
    }

    // MARK: - [enriched]

    /// Resolves and merges canonical metadata. nil = aborted (cancelled / paper gone), else
    /// whether bibliographic fields or ids changed. Lookup failures are not errors.
    private func enrichStep(pk: Int64, forceRefresh: Bool, advanceStage: Bool) async -> Bool? {
        let settings = await ctx.settings()
        guard let before = try? await ctx.db.paper(pk: pk), before.isLive else { return nil }
        var meta: BiblioMetadata?
        if !before.metaUserEdited, let resolver = resolverFactory(settings) {
            // `titleLookupHeld` (an email's confidential or possibly unpublished PDF): identifiers
            // only — no title search, not even as the fallback of an identifier nobody knows.
            let titles = !before.flags.contains(.titleLookupHeld)
            meta = await resolver.resolve(ids: before.ids,
                                          titleGuess: titles && before.titleRank > .filename ? before.title : nil,
                                          firstAuthorGuess: titles ? before.authors.first : nil, forceRefresh: forceRefresh)
            guard !Task.isCancelled else { return nil }
        }

        // Ids another live paper already holds would violate the partial unique indexes:
        // keep ours and tell the user the two may be the same work.
        var allowDOI = true, allowArxiv = true
        var lookalikes: [Paper] = []
        if let meta {
            var proposal = before
            Self.merge(meta, into: &proposal, allowDOI: true, allowArxiv: true)
            // Both bioRxiv prefixes of a preprint are one work (Database.sameWorkDOIs).
            if let doi = proposal.ids.doi, doi != before.ids.doi,
               let other = try? await ctx.db.paperMatchingWork(doi: doi, arxivID: nil, publishedDOI: nil, excluding: pk) {
                if other.ids.doi?.lowercased() == doi.lowercased() { allowDOI = false }
                lookalikes.append(other)
            }
            if let arxiv = proposal.ids.arxivID, arxiv != before.ids.arxivID,
               let other = try? await ctx.db.paperMatchingWork(doi: nil, arxivID: arxiv, publishedDOI: nil, excluding: pk) {
                allowArxiv = false
                lookalikes.append(other)
            }
            if let published = proposal.ids.publishedDOI, published != before.ids.publishedDOI,
               let other = try? await ctx.db.paperMatchingWork(doi: published, arxivID: nil, publishedDOI: nil,
                                                              excluding: pk) {
                lookalikes.append(other)
            }
        }

        let now = ctx.now()
        let resolved = meta
        let write = { [ctx] (allowDOI: Bool, allowArxiv: Bool) async throws -> Paper in
            try await ctx.db.modifyPaper(pk: pk, now: now) { p in
                // Soft-deleted during the lookup: leave the row as it was (restore resubmits it).
                guard p.isLive else { throw EnrichAbort.deleted }
                if let resolved { Self.merge(resolved, into: &p, allowDOI: allowDOI, allowArxiv: allowArxiv) }
                if advanceStage, p.stage == .committed { p.stage = .enriched }
            }
        }
        let after: Paper
        do {
            after = try await write(allowDOI, allowArxiv)
        } catch EnrichAbort.deleted {
            return nil
        } catch let e as SQLiteError where e.isUniqueViolation {
            // Another paper took the id between the check and the write.
            Log.importer.info("enrich \(pk): id already taken, keeping local ids")
            guard let retried = try? await write(false, false) else { return nil }
            after = retried
            if lookalikes.isEmpty,
               let other = try? await ctx.db.paperMatchingWork(doi: meta?.ids.doi, arxivID: meta?.ids.arxivID,
                                                              publishedDOI: nil, excluding: pk) {
                lookalikes.append(other)
            }
        } catch {
            Log.importer.error("enrich \(pk) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        if !allowDOI || !allowArxiv {
            Log.importer.info("enrich \(pk): skipped ids held by another paper (doi \(allowDOI ? "ok" : "taken", privacy: .public), arXiv \(allowArxiv ? "ok" : "taken", privacy: .public))")
        }

        // The duplicate check first (its review exists before the lookalike toast arrives, so the app
        // can offer [Review…] on it); the lookalike toasts themselves are unchanged. Only on the
        // import's own enrichment: a later "refresh metadata" never reopens a question.
        if settings.dedupe.enabled, advanceStage, let meta {
            await checkDuplicates(after, meta: meta, settings: settings, toasted: Set(lookalikes.map(\.pk)))
        }
        var seen = Set<Int64>()
        for other in lookalikes where seen.insert(other.pk).inserted {
            ctx.events.send(.toast(Toast(kind: .info, message: EnrichText.possibleDuplicate(other.title, settings.lang),
                                         buttons: [.init(title: EnrichText.view(settings.lang),
                                                         action: .openPaper(id: other.id))])))
        }

        let changed = Self.bibliographyDiffers(before, after)
        if changed || after.stage != before.stage { await ctx.syncSidecar(pk: pk) }
        return changed
    }

    /// The import's open review after enrichment re-matched its paper (nil: unchanged). Only a
    /// stronger match replaces it — a stronger band, or a paper where only a removed paper's
    /// tombstone matched. With the AI judge's answer on the review (B3-5), consistently:
    /// - a band the judge moved (a confident answer) is never undone by the same kind of evidence:
    ///   only an identifier (certain, which the judge can't weigh) re-bands it;
    /// - whenever the review is re-banded, the answer is dropped (`aiVerdict` nil, `aiState` back to
    ///   "none"): it was about the earlier evidence, and the sheet would otherwise show "moved to
    ///   possibly" on a likely review. The user can ask again.
    static func upgraded(_ current: DupReview, by m: DupMatch) -> DupReview? {
        var r = current
        guard m.reviewBand > r.band || (m.reviewBand == r.band && m.existing?.pk != nil && r.existingPaperPK == nil)
        else { return nil }
        if let v = r.aiVerdict, v.bandAfter != v.bandBefore, m.reviewBand != .certain { return nil }
        r.band = m.reviewBand
        r.relation = m.candidate.relation
        r.evidence = m.candidate.evidence + (m.history != nil ? [DupEvidence(.history)] : [])
        r.newerSide = m.candidate.newerSide
        r.score = m.candidate.score
        r.existingPaperPK = m.existing?.pk
        r.existingPaperID = m.existing?.id
        r.historyPK = m.history?.pk
        if r.held == nil, r.band != .possible { r.held = DupHeldIntent(scheduleHeld: false) }
        if r.aiVerdict != nil || r.aiState == DupJudge.answeredState {
            r.aiVerdict = nil
            r.aiState = DupJudge.unansweredState
        }
        return r
    }

    /// With canonical metadata the paper's identity is known: its record's links (has-preprint,
    /// is-version-of, the OpenAlex id) become keys, and it is checked against the library again
    /// (identity, then title + authors + year + text). A new match opens a review on the
    /// committed paper — held (AI held, ribbon) when certain or likely; an open review from the
    /// import is upgraded when this one is stronger. Never toasts about pairs already decided.
    /// `toasted`: papers the lookalike toast names anyway (no second toast about them).
    private func checkDuplicates(_ paper: Paper, meta: BiblioMetadata, settings: EngineSettings,
                                 toasted: Set<Int64>) async {
        let db = ctx.db, pk = paper.pk
        let apiIDs = DupKeys.local(meta.ids).map { DupKey(kind: $0.kind, value: $0.value, source: .crossref) }
        let recordKeys = DupKeys.fromRecord(meta) + apiIDs
        do {
            try await db.refreshLocalDupKeys(paperPK: pk)
            try await db.addDupKeys(paperPK: pk, recordKeys)
        } catch {
            Log.importer.error("enrich \(pk): duplicate keys failed: \(String(describing: error), privacy: .public)")
        }
        let stored = (try? await db.dupKeys(paperPK: pk)) ?? recordKeys
        var subject = await DedupeIndex.subject(for: paper, ctx: ctx, storedKeys: stored)
        subject.kind = DedupeText.kind(title: paper.title, fileName: paper.originalName, workType: meta.workType,
                                       relations: meta.relations)
        subject.rank = VersionRank.of(ids: paper.ids, venue: paper.venue, workType: meta.workType, fileName: paper.originalName)
        let extra = meta.relations.filter(\.kind.sameWork).map(\.doi) + [meta.ids.doi, meta.ids.publishedDOI].compactMap { $0 }
        guard let m = await DedupeIndex.match(subject, ids: paper.ids, extraDOIs: extra, excluding: pk,
                                              settings: settings.dedupe, ctx: ctx) else { return }
        let lang = settings.lang
        let now = ctx.now()
        let current = try? await db.openDupReview(newPaperPK: pk)
        if let current {
            // The import's review stays; a stronger match (an identifier, now) takes its place —
            // decided on the stored review in one step, so an AI judge's answer written meanwhile
            // is seen (and never overwritten by a stale copy).
            let changed = try? await db.modifyDupReview(id: current.id) { r in
                guard r.state == .open, let upgraded = Self.upgraded(r, by: m) else { return false }
                r = upgraded
                return true
            }
            if let r = changed ?? nil { ctx.events.send(.dedupe(.reviewOpened(reviewID: r.id, paperID: paper.id))) }
            return
        }
        // This pair is already under review (from the other side).
        if let other = m.existing?.pk, (try? await db.openDupReview(pair: pk, other)) != nil { return }
        let review = DupReview(newPaperID: paper.id, existingPaperID: m.existing?.id, band: m.reviewBand,
                               score: m.candidate.score, createdAt: now, newPaperPK: pk, existingPaperPK: m.existing?.pk,
                               historyPK: m.history?.pk, relation: m.candidate.relation,
                               evidence: m.candidate.evidence + (m.history != nil ? [DupEvidence(.history)] : []),
                               newerSide: m.candidate.newerSide, origin: .enrich,
                               held: m.reviewBand != .possible ? DupHeldIntent(scheduleHeld: false) : nil)
        do { try await db.insertDupReview(review) } catch {
            Log.importer.error("enrich \(pk): duplicate review failed: \(String(describing: error), privacy: .public)")
            return
        }
        if review.holdsNewPaper, !(m.existing.map { toasted.contains($0.pk) } ?? false) {
            let title = m.existing?.title ?? m.history?.title ?? ""
            ctx.events.send(.toast(Toast(id: "dup-" + review.id, kind: .info,
                                         message: DupExplainer.toastMessage(review, newTitle: paper.title, existingTitle: title,
                                                                            lang: lang),
                                         buttons: [.init(title: DupExplainer.reviewButton(lang),
                                                         action: .openDuplicateReview(id: review.id))])))
        }
        ctx.events.send(.dedupe(.reviewOpened(reviewID: review.id, paperID: paper.id)))
        if let open = try? await db.openDupReviewCount() { ctx.events.send(.dedupe(.openCount(open))) }
    }

    /// Canonical metadata onto a paper (§6.1 merge rules). Nothing changes for user-edited
    /// metadata. The API title (rank 4) replaces lower-ranked ones; authors, year, venue and
    /// abstract are taken when the API has them. The API DOI is adopted when the local one is
    /// missing or the source is bioRxiv (whose papers moved to the 10.64898 prefix — file
    /// names still say 10.1101, the API knows the live one).
    static func merge(_ meta: BiblioMetadata, into p: inout Paper, allowDOI: Bool, allowArxiv: Bool) {
        guard !p.metaUserEdited else { return }
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        if let title = clean(meta.title), p.titleRank <= .api {
            p.title = title
            p.titleRank = .api
        }
        let authors = meta.authors.compactMap(clean)
        if !authors.isEmpty { p.authors = authors }
        if let year = meta.year { p.year = year }
        if let venue = clean(meta.venue) { p.venue = venue }
        if let abstract = clean(meta.abstract) { p.abstract = abstract }

        var ids = p.ids
        if allowDOI, let doi = clean(meta.ids.doi)?.lowercased(), meta.source == .biorxiv || ids.doi == nil {
            ids.doi = doi
        }
        if allowArxiv, ids.arxivID == nil, let arxiv = clean(meta.ids.arxivID) {
            ids.arxivID = arxiv          // the file's version stays unknown: the API reports the latest
        }
        if ids.pii == nil, let pii = clean(meta.ids.pii) { ids.pii = pii }
        if let published = clean(meta.ids.publishedDOI)?.lowercased() { ids.publishedDOI = published }
        p.ids = ids
        if meta.source != .none { p.metaSource = meta.source }
    }

    private static func bibliographyDiffers(_ a: Paper, _ b: Paper) -> Bool {
        a.title != b.title || a.titleRank != b.titleRank || a.authors != b.authors || a.year != b.year
            || a.venue != b.venue || a.abstract != b.abstract || a.ids != b.ids || a.metaSource != b.metaSource
    }

    // MARK: - [filed]

    private enum FileStepOutcome { case aborted, done(changed: Bool) }

    private enum EnrichAbort: Error { case deleted }

    /// What the filing transaction did.
    private enum FilingCommit: Sendable {
        case gone                                  // deleted (or vanished) meanwhile
        case kept(synced: Bool)                    // filing failed; the paper keeps its folder
        case filed(before: Paper, after: Paper)
    }

    /// Moves the paper's folder to `Papers/<canonical name>` and renames the PDF to match.
    /// Serialized (names are picked against the current listing). The move and the row update
    /// run in one Database call on the row read in that call — like soft delete and restore,
    /// so a delete can never record one folder while the files end up in another, and a
    /// sidecar write always resolves the folder the row names (§5 SidecarWriter rule).
    /// Filing errors are logged and the paper keeps its folder — it still proceeds, and a
    /// later refile can retry.
    private func fileStep(pk: Int64, advanceStage: Bool) async -> FileStepOutcome {
        await lockFiling()
        defer { unlockFiling() }
        guard !Task.isCancelled else { return .aborted }
        let library = ctx.paths.library, papers = ctx.paths.papers, papersRelative = Self.papersRelative(ctx.paths)
        let now = ctx.now()
        let outcome: FilingCommit
        do {
            outcome = try await ctx.db.transaction { db -> FilingCommit in
                guard let p = try db.paper(pk: pk), p.isLive else { return .gone }
                let input = FilingInput(library: library, papers: papers, papersRelative: papersRelative,
                                        folder: p.folder, pdfName: p.pdfName, sha256: p.sha256, fileSize: p.fileSize,
                                        base: FileNamer.folderName(year: p.year, firstAuthor: p.authors.first, title: p.title))
                let result: FilingResult
                do {
                    result = try Self.fileBlocking(input)
                } catch {
                    Log.importer.error("filing \(pk) failed: \(FileOps.classify(error).description, privacy: .public)")
                    guard advanceStage, Self.order(p.stage) < Self.order(.filed) else { return .kept(synced: false) }
                    var q = p
                    q.stage = .filed
                    try db.updatePaper(q, now: now)
                    return .kept(synced: true)
                }
                var q = p
                q.folder = result.folder
                q.pdfName = result.pdfName
                q.nameFinal = Self.isFinalName(q.metaSource)
                if result.missing { q.flags.insert(.missing) } else { q.flags.remove(.missing) }
                if advanceStage, Self.order(q.stage) < Self.order(.filed) { q.stage = .filed }
                do {
                    return .filed(before: p, after: try db.updatePaper(q, now: now))
                } catch {
                    Self.undoFiling(result, of: input)
                    throw error
                }
            }
        } catch {
            Log.importer.error("filing \(pk): DB update failed: \(String(describing: error), privacy: .public)")
            return .aborted
        }
        switch outcome {
        case .gone:
            return .aborted
        case .kept(let synced):
            if synced { await ctx.syncSidecar(pk: pk) }
            return .done(changed: false)
        case .filed(let before, let after):
            await ctx.syncSidecar(pk: pk)
            return .done(changed: after.folder != before.folder || after.pdfName != before.pdfName
                            || after.nameFinal != before.nameFinal)
        }
    }

    /// Puts files back where the row still says they are (the row update failed). Best effort.
    private static func undoFiling(_ r: FilingResult, of j: FilingInput) {
        let now = LibraryPaths.folderURL(forRelative: r.folder, library: j.library)
        let was = LibraryPaths.folderURL(forRelative: j.folder, library: j.library)
        if r.pdfName != j.pdfName {
            try? FileOps.atomicRename(from: now.appendingPathComponent(r.pdfName), to: now.appendingPathComponent(j.pdfName))
        }
        if r.folder != j.folder { try? FileOps.moveFolder(from: now, to: was) }
    }

    private struct FilingInput: Sendable {
        var library: URL
        var papers: URL
        var papersRelative: String
        var folder: String
        var pdfName: String
        var sha256: String
        var fileSize: Int64
        var base: String
    }

    private struct FilingResult: Sendable {
        var folder: String       // relative to the library root
        var pdfName: String
        var missing: Bool
    }

    /// Blocking file work of one filing. Crash-safe: when the recorded folder is gone because
    /// a previous run moved it but died before the DB update, the moved folder is found again
    /// (same bytes under one of the candidate names) and only the row is fixed.
    private static func fileBlocking(_ j: FilingInput) throws -> FilingResult {
        let current = LibraryPaths.folderURL(forRelative: j.folder, library: j.library)
        let currentName = current.lastPathComponent
        let inPapersRoot = (j.folder as NSString).deletingLastPathComponent == j.papersRelative

        if isDirectory(current) {
            for _ in 0..<5 {
                var existing = folderNames(in: j.papers)
                if inPapersRoot { existing.remove(currentName) }
                let target = FileNamer.uniqueName(j.base, existing: existing)
                if !(inPapersRoot && target == currentName) {
                    do {
                        try FileOps.moveFolder(from: current, to: j.papers.appendingPathComponent(target, isDirectory: true))
                    } catch FileOpsError.destinationExists {
                        continue                     // someone created that name meanwhile: pick again
                    }
                }
                return finishPDF(folderName: target, in: j)
            }
            throw FileOpsError.destinationExists
        }

        // Recorded folder is gone: did an interrupted filing already move it?
        for candidate in nameVariants(of: j.base) {
            let dir = j.papers.appendingPathComponent(candidate, isDirectory: true)
            guard isDirectory(dir) else { continue }
            for name in [j.pdfName, FileNamer.pdfName(forFolder: candidate)] {
                let file = dir.appendingPathComponent(name)
                guard FileOps.fileSize(file) == j.fileSize, (try? FileOps.sha256(of: file)) == j.sha256 else { continue }
                return finishPDF(folderName: candidate, in: j, currentPDF: name)
            }
        }
        Log.importer.error("filing: folder \(j.folder, privacy: .public) is missing")
        return FilingResult(folder: j.folder, pdfName: j.pdfName, missing: true)
    }

    /// The PDF inside the (now canonical) folder gets the folder's name + ".pdf".
    private static func finishPDF(folderName: String, in j: FilingInput, currentPDF: String? = nil) -> FilingResult {
        let dir = j.papers.appendingPathComponent(folderName, isDirectory: true)
        let folder = j.papersRelative + "/" + folderName
        let have = currentPDF ?? j.pdfName
        let want = FileNamer.pdfName(forFolder: folderName)
        let from = dir.appendingPathComponent(have), to = dir.appendingPathComponent(want)
        if have == want {
            return FilingResult(folder: folder, pdfName: want, missing: !FileManager.default.fileExists(atPath: to.path))
        }
        if FileManager.default.fileExists(atPath: from.path) {
            do {
                try FileOps.atomicRename(from: from, to: to)
                return FilingResult(folder: folder, pdfName: want, missing: false)
            } catch {
                Log.importer.error("filing: PDF rename failed: \(FileOps.classify(error).description, privacy: .public)")
                return FilingResult(folder: folder, pdfName: have, missing: false)
            }
        }
        // Renamed by an earlier, interrupted run.
        return FilingResult(folder: folder, pdfName: want, missing: !FileManager.default.fileExists(atPath: to.path))
    }

    /// `base`, `base_2`, `base_3`… exactly as FileNamer.uniqueName produces them.
    private static func nameVariants(of base: String, count: Int = 30) -> [String] {
        var taken = Set<String>()
        var out: [String] = []
        for _ in 0..<count {
            let name = FileNamer.uniqueName(base, existing: taken)
            out.append(name)
            taken.insert(name)
        }
        return out
    }

    /// Paper folder names under Papers/ (hidden entries and _Inbox excluded).
    private static func folderNames(in papers: URL) -> Set<String> {
        let items = (try? FileManager.default.contentsOfDirectory(at: papers, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        var out = Set<String>()
        for item in items where item.lastPathComponent != "_Inbox" && isDirectory(item) {
            out.insert(item.lastPathComponent)
        }
        return out
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func papersRelative(_ paths: AppPaths) -> String {
        LibraryPaths.relativePath(of: paths.papers, root: paths.library) ?? paths.papers.lastPathComponent
    }

    /// Named from canonical metadata (API, agent or user) rather than local guesses.
    private static func isFinalName(_ source: MetaSource) -> Bool { source != .none && source != .pdf }

    private static func order(_ s: PaperStage) -> Int { PaperStage.allCases.firstIndex(of: s) ?? 0 }

    private func lockFiling() async {
        if !filingBusy { filingBusy = true; return }
        await withCheckedContinuation { filingWaiters.append($0) }
    }

    private func unlockFiling() {
        if filingWaiters.isEmpty { filingBusy = false } else { filingWaiters.removeFirst().resume() }
    }

    // MARK: - [ready]

    /// Locked/scanned/unreadable → ai_state skipped. Otherwise, when the batch wants a job
    /// (policy ≠ skip and auto-read on, or "queue all"), hand it to the agent queue — which
    /// decides held/queued against agent.mode — unless the paper already has an active job.
    private func readyStep(pk: Int64) async {
        guard let p = try? await ctx.db.paper(pk: pk), p.isLive else { return }
        let job = jobs[pk] ?? Job(holdAI: true, policy: .automatic, row: nil)
        let settings = await ctx.settings()
        let unreadable = !p.flags.isDisjoint(with: [.locked, .scanned, .unreadable])
        let wanted = !unreadable && !p.flags.contains(.missing) && job.policy != .skip
            && (settings.autoReadNewPapers || job.policy == .queueAll || job.policy == .queueHeld)
        // A person's emailed PDF that resolved to no public identifier may be unpublished work.
        let unpublished = job.holdUnlessIdentified && p.ids.doi == nil && p.ids.arxivID == nil
            && p.ids.publishedDOI == nil
        // A paper waiting for a duplicate decision: no quota spent reading what may be a copy.
        var dupHold = false
        if settings.dedupe.enabled, var review = try? await ctx.db.openDupReview(newPaperPK: pk), review.holdsNewPaper {
            dupHold = true
            var held = review.held ?? DupHeldIntent(scheduleHeld: false)
            held.aiQueue = wanted && !(job.holdAI || unpublished)
            if held != review.held {
                review.held = held
                try? await ctx.db.updateDupReview(review)
            }
        }
        let hold = job.holdAI || unpublished || dupHold
        if wanted {
            let active: AgentJob? = try? await ctx.db.activeJob(paperPK: pk)
            if active == nil {
                await onReady(pk, hold)
                await applyJobExtras(pk: pk, priority: job.aiPriority, unpublished: unpublished)
            }
        }
        do {
            try await ctx.db.modifyPaper(pk: pk, now: ctx.now()) { q in
                guard q.isLive else { throw EnrichAbort.deleted }       // restore resubmits it
                if unreadable, q.aiState == .none { q.aiState = .skipped }
                q.stage = .ready
            }
        } catch EnrichAbort.deleted {
            return
        } catch {
            Log.importer.error("ready \(pk) failed: \(String(describing: error), privacy: .public)")
            return
        }
        await ctx.syncSidecar(pk: pk)
        if wanted, !hold, settings.agentMode != .off, var row = job.row {
            row.stage = .queuedForAI(paperID: p.id)
            ctx.events.send(.importRow(row))
        }
        await MailMatcher.paperReady(pk: pk, ctx: ctx)
    }

    /// After `onReady` created the job: its priority (read first) and, for a possibly unpublished
    /// attachment, the held job's note. Re-read in one transaction; a job that already started
    /// (or was cancelled) is left alone.
    private func applyJobExtras(pk: Int64, priority: Int, unpublished: Bool) async {
        guard priority != 0 || unpublished else { return }
        let now = ctx.now()
        do {
            let changed = try await ctx.db.transaction { db -> Bool in
                guard var j = try db.activeJob(paperPK: pk), j.state == .held || j.state == .queued else { return false }
                var changed = false
                if j.priority != priority {
                    j.priority = priority
                    try db.updateJob(j)
                    changed = true
                }
                if unpublished, j.state == .held, let p = try db.paper(pk: pk), p.aiState == .held,
                   p.aiNote != ImportAnnotation.unpublishedHoldNote {
                    try db.modifyPaper(pk: pk, now: now) { $0.aiNote = ImportAnnotation.unpublishedHoldNote }
                    changed = true
                }
                return changed
            }
            if changed { await ctx.syncSidecar(pk: pk) }
        } catch {
            Log.importer.error("ready \(pk): job extras failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// zh/en strings produced by the enrich stage.
private enum EnrichText {
    static func possibleDuplicate(_ title: String, _ lang: UILang) -> String {
        let t = shortTitle(title)
        return lang == .zh ? "可能与已有论文重复：\(t)" : "May duplicate a paper already in the library: \(t)"
    }

    static func view(_ lang: UILang) -> String { lang == .zh ? "查看" : "View" }

    private static func shortTitle(_ s: String) -> String {
        s.count > 60 ? String(s.prefix(59)) + "…" : s
    }
}
