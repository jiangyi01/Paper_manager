import Foundation

/// `applyAgentCard` (§6.2): folds one sanitized AI reading card into a paper in a
/// single transaction — card fields, estimate, first-read metadata, category,
/// tags, checklist merge and the one-time provisional re-place — then refreshes
/// the FTS row, card.json/notes.md and (for a new category) the library manifest.
package enum CardApplier {
    package enum ApplyError: Error, Equatable {
        case paperMissing
        /// Thrown by a `within` precondition (e.g. the job was cancelled meanwhile); nothing was written.
        case aborted
    }

    package struct Result: Sendable, Equatable {
        package var paper: Paper
        package var checklist: [ChecklistItem]
        package var createdCategory: PaperCategory?
        package var metadataChanged: Bool
        package var deadlineChanged: Bool
    }

    /// - Parameters:
    ///   - settings: a snapshot from `ctx.settings()` — used for `allowNewCategories` and the
    ///     scheduler (its skip days are re-read inside the transaction).
    ///   - onApplied: called after commit and sidecar sync (the engine refiles the folder
    ///     when the naming basis changed).
    ///   - within: runs first inside the same transaction; throw to abort everything
    ///     (the agent queue marks its job succeeded here, so card and job commit together).
    @discardableResult
    package static func apply(_ card: ReadingCard, to pk: Int64, ctx: EngineContext, settings: EngineSettings,
                              onApplied: (@Sendable (Int64) async -> Void)? = nil,
                              within: (@Sendable (isolated Database) throws -> Void)? = nil) async throws -> Result {
        let now = ctx.now()
        let calendar = ctx.calendar
        let result = try await ctx.db.transaction { db in
            try within?(db)
            // The re-place must see the skip days as of this transaction, not the caller's
            // snapshot (a 今天跳过 may have landed while the card was on its way).
            var fresh = settings
            fresh.plan.skipDays = EngineContext.skipDays(in: db)
            return try applyInTransaction(card, pk: pk, db: db, settings: fresh, now: now, calendar: calendar)
        }
        do { try await ctx.db.reindexMeta(pk: pk) } catch {
            Log.agent.error("reindexMeta(\(pk)) failed: \(String(describing: error), privacy: .public)")
        }
        await ctx.syncSidecar(pk: pk)
        if result.createdCategory != nil { await ctx.writeManifest() }
        if let onApplied { await onApplied(pk) }
        return result
    }

    private static func applyInTransaction(_ card: ReadingCard, pk: Int64, db: isolated Database,
                                           settings: EngineSettings, now: Date, calendar: Calendar) throws -> Result {
        guard var p = try db.paper(pk: pk) else { throw ApplyError.paperMissing }
        let original = p

        // Bibliographic header — only for papers no API or user has described.
        var metadataChanged = false
        if p.metaSource == .none, !p.metaUserEdited, let em = card.extractedMetadata {
            let title = em.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, p.titleRank < .agent {
                p.title = title
                p.titleRank = .agent
                metadataChanged = true
            }
            let authors = em.authors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !authors.isEmpty, authors != p.authors { p.authors = authors; metadataChanged = true }
            if let year = em.year, year != p.year { p.year = year; metadataChanged = true }
            if let venue = em.venue?.trimmingCharacters(in: .whitespacesAndNewlines), !venue.isEmpty, venue != p.venue {
                p.venue = venue
                metadataChanged = true
            }
            if p.ids.doi == nil, let doi = em.doi?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !doi.isEmpty {
                // The DOI is unique among live papers; another paper holding it is a duplicate
                // work for the user to resolve, not something to clobber here.
                let holder = try db.paperMatchingWork(doi: doi, arxivID: nil, publishedDOI: nil)
                if holder == nil || holder?.pk == p.pk {
                    p.ids.doi = doi
                    metadataChanged = true
                }
            }
            if metadataChanged { p.metaSource = .agent }
        }

        // PaperCategory (skipped entirely when the user picked one).
        var created: PaperCategory?
        if !p.categoryUserSet {
            let categories = try db.categories()
            let counts = try db.categoryCounts()
            let tagSets = try db.tagSetsByCategory()
            let profiles = categories.map {
                Taxonomy.CategoryProfile(pk: $0.pk, paperCount: counts[$0.pk] ?? 0, tags: tagSets[$0.pk] ?? [])
            }
            switch Taxonomy.decide(card: card, existing: categories, profiles: profiles,
                                   allowNew: settings.allowNewCategories, categoryUserSet: p.categoryUserSet,
                                   currentPK: p.categoryPK) {
            case .keep:
                break
            case .useExisting(let categoryPK):
                p.categoryPK = categoryPK
                p.needsReview = false
            case .createNew(let name, let description, let hue):
                let c = try db.insertCategory(PaperCategory(name: name, description: description.isEmpty ? nil : description,
                                                            hue: hue, origin: .agent, acknowledged: false, createdAt: now))
                created = c
                p.categoryPK = c.pk
                p.needsReview = false
            case .fallback(let categoryPK, let needsReview):
                p.categoryPK = categoryPK
                p.needsReview = needsReview
            }
        }

        // Tags: user ∪ new agent − suppressed; suppressed rows are kept so re-reads respect them.
        let currentTags = try db.tags(paperPK: pk)
        let suppressed = currentTags.filter { $0.origin == .suppressed }
        var tags = Taxonomy.mergeTags(user: currentTags.filter { $0.origin == .user }, agent: card.tags,
                                      suppressed: suppressed.map(\.name))
        let taken = Set(tags.map { $0.name.lowercased() })
        tags += suppressed.filter { !taken.contains($0.name.lowercased()) }
        try db.setTags(paperPK: pk, tags)

        // Estimate (the user's own estimate always wins).
        let previousEst = p.estMinutes ?? card.estimatedMinutes
        let userEstimate = p.estSource == .user
        if !userEstimate {
            p.estMinutes = card.estimatedMinutes
            p.estSource = .agent
        }
        let targetEst = userEstimate ? (p.estMinutes ?? card.estimatedMinutes) : card.estimatedMinutes

        // Checklist (§6.4): ticked / user / edited items survive in place.
        let checklist = ChecklistMerger.merge(existing: try db.checklist(paperPK: pk), agentSteps: card.checklist,
                                              est: targetEst)
        try db.replaceChecklist(paperPK: pk, items: checklist)

        // Schedule: the first result may re-place a provisional ≈DDL once; always clears provisional.
        let scheduler = Scheduler(settings: settings.plan, now: now, calendar: calendar)
        let q = Scheduler.item(for: p, checklist: checklist)
        let mayReplace = p.isLive && p.provisional && p.scheduleMode == .auto && p.deadline != nil
            && p.deadlineOrigin == .place && !userEstimate
        var among: [SchedItem] = []
        if mayReplace {
            let live = try db.livePapers()
            let lists = try db.checklists(paperPKs: live.map(\.pk))
            among = live.map { $0.pk == pk ? q : Scheduler.item(for: $0, checklist: lists[$0.pk] ?? []) }
        }
        let placed = scheduler.applyAgentEstimate(q, heuristicMinutes: previousEst,
                                                  agentMinutes: userEstimate ? previousEst : card.estimatedMinutes,
                                                  addedAt: p.addedAt, among: among)
        p.deadline = placed.deadline
        p.scheduleMode = placed.scheduleMode
        p.deadlineOrigin = placed.deadlineOrigin
        p.placementFloor = placed.placementFloor
        p.provisional = placed.provisional

        // The card itself.
        p.card = card
        p.tldr = card.tldr
        p.textQuality = card.textQuality
        p.cardVersion = (p.cardVersion ?? 0) + 1
        p.aiState = .done
        p.aiSeen = false
        p.aiNote = nil

        let saved = try db.updatePaper(p, now: now)
        return Result(paper: saved, checklist: checklist, createdCategory: created, metadataChanged: metadataChanged,
                      deadlineChanged: saved.deadline != original.deadline)
    }
}
