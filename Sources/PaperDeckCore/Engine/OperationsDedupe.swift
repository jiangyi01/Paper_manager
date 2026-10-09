import Foundation

// The duplicate check's engine operations (DQ §4, §9; dive-dedupe §6; READING_ASSIST_PLAN §4,
// §6.3). Owned by Slice B. Every outcome maps onto existing operations (resolvePending /
// restore / softDelete / restoreAutoDeadline / pinDeadline) plus three composites:
// `reopenForReread`, `mergeDuplicate` and the intake's `attachSupplement`. Nothing here runs by
// itself: each resolution is the user's choice and is undoable for `UndoToken.lifetime`.
extension Engine {
    // MARK: - Reading

    /// Reviews in `state`, newest first. Open parked reviews whose file is gone (a relaunch since)
    /// are expired first.
    package func duplicateReviews(state: DupReviewState = .open) async throws -> [DupReview] {
        if state == .open { _ = await expireLostParkedReviews() }
        return try await db.dupReviews(state: state)
    }

    /// The number of open reviews (sidebar ▸ Duplicates).
    package func openDuplicateCount() async -> Int { (try? await db.openDupReviewCount()) ?? 0 }

    /// Open reviews with both sides' titles, in the UI language (the sidebar list, the ribbon and
    /// the chip), newest first.
    package func duplicateReviewSummaries() async throws -> [DupReviewSummary] {
        let lang = (await ctx.settings()).lang
        var out: [DupReviewSummary] = []
        for r in try await duplicateReviews(state: .open) {
            var newTitle = r.stagedName ?? ""
            if let pk = r.newPaperPK, let p = try await db.paper(pk: pk) {
                newTitle = p.title
            } else if let pending = r.pendingID, let f = await intake.parkedFile(pending) {
                newTitle = f.titleRank >= .pdfAttribute ? f.title : f.fileName
            }
            var existingTitle = "", deleted = false
            if let pk = r.existingPaperPK, let p = try await db.paper(pk: pk) {
                existingTitle = p.title
                deleted = p.isDeleted
            } else if let pk = r.historyPK, let h = try await db.historyRow(pk: pk) {
                existingTitle = h.title
            }
            out.append(DupReviewSummary(review: r, newTitle: newTitle, existingTitle: existingTitle,
                                        existingDeleted: deleted,
                                        headline: DupExplainer.headline(r, existing: DupSideSummary(title: existingTitle),
                                                                        lang: lang)))
        }
        return out
    }

    /// The import's classic toasts, worded from their review when one is open: the parked file's
    /// two-button "same work" toast gets [Review…] plus the one quick answer that never throws the
    /// library's version away (`DupExplainer.reviewToast`); the enrichment's "may duplicate" toast
    /// gets [Review…] before [View]. nil: no open review (the app shows the toast unchanged).
    package func duplicateToast(replacing t: Toast) async -> Toast? {
        let lang = (await ctx.settings()).lang
        if let pending = DupExplainer.classicSameWorkPendingID(t) {
            guard let r = try? await db.openDupReview(pendingID: pending), let pk = r.existingPaperPK,
                  let e = try? await db.paper(pk: pk) else { return nil }
            let newTitle = await intake.parkedFile(pending).map { $0.titleRank >= .pdfAttribute ? $0.title : $0.fileName }
                ?? r.stagedName ?? ""
            return DupExplainer.reviewToast(r, newTitle: newTitle, existingTitle: e.title, existingIsLive: e.isLive, lang: lang)
        }
        if let otherID = DupExplainer.classicLookalikePaperID(t) {
            guard let other = try? await db.paper(id: otherID),
                  let r = try? await db.openDupReviews(involving: other.pk).last else { return nil }
            var buttons = t.buttons
            buttons.insert(.init(title: DupExplainer.reviewButton(lang), action: .openDuplicateReview(id: r.id)), at: 0)
            return Toast(id: "dup-" + r.id, kind: t.kind, message: t.message, buttons: buttons)
        }
        return nil
    }

    /// Once per launch (the UI's first look): identity keys for papers imported before the check,
    /// and the parked reviews a relaunch lost marked expired. Returns (open, expired).
    @discardableResult
    package func prepareDuplicateReviews() async -> (open: Int, expired: Int) {
        _ = try? await db.backfillLocalDupKeys()
        let expired = await expireLostParkedReviews()
        return (await openDuplicateCount(), expired)
    }

    /// Open reviews of a parked file the intake no longer holds → expired.
    private func expireLostParkedReviews() async -> Int {
        guard let open = try? await db.dupReviews(state: .open) else { return 0 }
        var n = 0
        for var r in open where r.newPaperPK == nil {
            if let pending = r.pendingID, await intake.isPending(pending) { continue }
            r.state = .expired
            r.resolvedAt = ctx.now()
            r.pendingID = nil
            try? await db.updateDupReview(r)
            ctx.events.send(.dedupe(.reviewClosed(reviewID: r.id)))
            n += 1
        }
        if n > 0, let count = try? await db.openDupReviewCount() { ctx.events.send(.dedupe(.openCount(count))) }
        return n
    }

    /// Everything the decision sheet shows for one review, in the UI language.
    package func duplicateReviewDetail(id: String) async throws -> DupReviewDetail {
        guard let review = try await db.dupReview(id: id) else { throw DupResolutionError.reviewNotFound(id) }
        let lang = (await ctx.settings()).lang
        var newSide = DupSideSummary(title: review.stagedName ?? "")
        var newIDs = PaperIDs()
        if let pk = review.newPaperPK, let p = try await db.paper(pk: pk) {
            newSide = try await summary(of: p, lang: lang)
            newIDs = p.ids
        } else if let pending = review.pendingID, let f = await intake.parkedFile(pending) {
            newIDs = f.ids
            newSide = DupSideSummary(title: f.titleRank >= .pdfAttribute ? f.title : f.fileName, fileName: f.fileName,
                                     pages: f.pages,
                                     versionLabel: DupExplainer.versionLabel(venue: nil,
                                                                             rank: VersionRank.of(ids: f.ids, venue: nil, fileName: f.fileName),
                                                                             ids: f.ids, lang: lang))
        }
        var existing = DupSideSummary(title: "")
        var existingPaper: Paper?
        var history: DupHistoryRow?
        if let pk = review.existingPaperPK, let p = try await db.paper(pk: pk) {
            existing = try await summary(of: p, lang: lang)
            existingPaper = p
        } else if let pk = review.historyPK, let h = try await db.historyRow(pk: pk) {
            history = h
            existing = DupSideSummary(paperID: nil, title: h.title, year: h.year, status: h.lastStatus, addedAt: h.addedAt,
                                      doneAt: h.doneAt, purgedAt: h.purgedAt, readCount: h.readCount)
        }
        let options = DupChoiceRules.choices(review, newIDs: newIDs, existing: existingPaper, history: history)
        let canRegenerate = !(existingPaper?.card?.checklist.isEmpty ?? true)
        return DupReviewDetail(review: review, new: newSide, existing: existing,
                               explanation: DupExplainer.explain(review, new: newSide, existing: existing, lang: lang,
                                                                 calendar: ctx.calendar),
                               choices: options.choices, defaultChoice: options.default,
                               canRegenerateChecklist: canRegenerate)
    }

    private func summary(of p: Paper, lang: UILang) async throws -> DupSideSummary {
        let items = try await db.checklist(paperPK: p.pk)
        let cycles = try await db.readingCycles(paperPK: p.pk)
        return DupSideSummary(paperID: p.id, title: p.title, fileName: p.originalName, venue: p.venue, year: p.year,
                              pages: p.pageCount,
                              versionLabel: DupExplainer.versionLabel(venue: p.venue,
                                                                    rank: VersionRank.of(ids: p.ids, venue: p.venue, fileName: p.originalName),
                                                                    ids: p.ids, lang: lang),
                              status: p.status, addedAt: p.addedAt, doneAt: p.doneAt,
                              checklistDone: items.count(where: \.isDone), checklistTotal: items.count,
                              notesChars: p.notes.trimmingCharacters(in: .whitespacesAndNewlines).count, hasCard: p.card != nil,
                              deletedAt: p.deletedAt, readCount: ReadingCycle.readCount(cycles, doneAt: p.doneAt))
    }

    // MARK: - Resolving

    /// Applies the user's choice to a review (see `DupChoice`). Returns what happened; its
    /// `undoToken` reverts it within `UndoToken.lifetime` (`undoDuplicateResolution`).
    @discardableResult
    package func resolveDuplicate(reviewID: String, _ choice: DupChoice) async throws -> DupResolution {
        guard var review = try await db.dupReview(id: reviewID) else { throw DupResolutionError.reviewNotFound(reviewID) }
        guard review.state == .open else { throw DupResolutionError.reviewClosed(reviewID) }
        let lang = (await ctx.settings()).lang
        let existing: Paper? = try await review.existingPaperPK.asyncMap { try await db.paper(pk: $0) } ?? nil
        let history: DupHistoryRow? = try await review.historyPK.asyncMap { try await db.historyRow(pk: $0) } ?? nil
        var steps: [DupUndoStep] = [.reopenReview(review)]
        var outcome: (kept: String?, removed: String?, message: String, undoable: Bool)

        if let pending = review.pendingID, review.newPaperPK == nil {
            guard let file = await intake.parkedFile(pending) else {
                review.state = .expired
                review.resolvedAt = ctx.now()
                review.pendingID = nil
                try? await db.updateDupReview(review)
                ctx.events.send(.dedupe(.reviewClosed(reviewID: reviewID)))
                throw DupResolutionError.fileExpired(reviewID)
            }
            do {
                outcome = try await resolveParked(review, file: file, pendingID: pending, existing: existing, choice: choice,
                                                  steps: &steps, lang: lang)
            } catch {
                await rollBack(steps.dropFirst())
                throw error
            }
        } else if let pk = review.newPaperPK {
            guard let newPaper = try await db.paper(pk: pk) else { throw DupResolutionError.reviewNotFound(reviewID) }
            do {
                outcome = try await resolveCommitted(&review, newPaper: newPaper, existing: existing, history: history,
                                                     choice: choice, steps: &steps, lang: lang)
            } catch {
                await rollBack(steps.dropFirst())
                throw error
            }
        } else {
            throw DupResolutionError.reviewNotFound(reviewID)
        }

        if var latest = try await db.dupReview(id: reviewID) {
            latest.state = .resolved
            latest.choice = choice.code
            latest.resolvedAt = ctx.now()
            latest.pendingID = nil
            if review.newPaperPK == nil { latest.newPaperPK = nil }
            try await db.updateDupReview(latest)
        }
        ctx.events.send(.dedupe(.reviewClosed(reviewID: reviewID)))
        if let open = try? await db.openDupReviewCount() { ctx.events.send(.dedupe(.openCount(open))) }
        // card.json `readingCycles` / `distinctFrom` follow the decision on both papers.
        var touched = Set([review.newPaperPK, review.existingPaperPK].compactMap { $0 })
        for id in [outcome.kept, outcome.removed].compactMap({ $0 }) {
            if let p = try? await db.paper(id: id) { touched.insert(p.pk) }
        }
        for pk in touched.sorted() { await ctx.syncSidecar(pk: pk) }

        var token: String?
        if outcome.undoable {
            let id = UUID().uuidString.lowercased()
            let now = ctx.now()
            await dupUndoLedger.put(id, DupUndoLedger.Entry(owner: ObjectIdentifier(self),
                                                            expiresAt: now.addingTimeInterval(UndoToken.lifetime),
                                                            steps: steps), now: now)
            token = id
        }
        return DupResolution(reviewID: reviewID, choice: choice.kind, keptPaperID: outcome.kept,
                             removedPaperID: outcome.removed, undoToken: token, message: outcome.message)
    }

    /// A parked file (not committed): the intake applies the file side.
    private func resolveParked(_ review: DupReview, file: IntakeActor.ParkedFile, pendingID: String, existing: Paper?,
                               choice: DupChoice, steps: inout [DupUndoStep],
                               lang: UILang) async throws -> (kept: String?, removed: String?, message: String, undoable: Bool) {
        guard let existing else { throw DupResolutionError.choiceUnavailable(choice.code) }
        let allowed = DupChoiceRules.choices(review, newIDs: file.ids, existing: existing, history: nil).choices
        guard allowed.contains(choice.kind) else { throw DupResolutionError.choiceUnavailable(choice.code) }
        switch choice {
        case .keepNew(let reread):
            if existing.isDeleted {
                try await restoreForDuplicate(existing)
                steps.append(.softDeleteAgain(paperID: existing.id))
            }
            switch await intake.applyParked(pendingID: pendingID, .replace) {
            case .replaced(let paper, let undoID):
                steps.append(.intakeUndoReplace(id: undoID))
                if reread {
                    // Taken after the swap: its undo reverts the re-read only (the intake's
                    // undo then puts the earlier file and facts back).
                    let before = try await DupPaperSnapshot.take(paper.pk, db: db, ctx: ctx)
                    let n = try await reopenForReread(paperID: paper.id, checklist: .keepProgress, deadline: .auto)
                    steps.append(.restorePaper(before, text: nil, thumbnail: nil))
                    steps.append(.removeCycle(paperPK: paper.pk, n: n))
                }
                return (paper.id, nil, DupText.keptNew(paper.title, lang), true)
            case .committed(let paper):
                return (paper.id, nil, DupText.addedAsNew(paper.title, lang), false)
            case .gone: throw DupResolutionError.fileExpired(review.id)
            case .failed(let why): throw DupResolutionError.failed(why)
            case .discarded, .attached: throw DupResolutionError.failed("")
            }
        case .rereadEarlier(let checklist, let deadline, let useNewFile):
            if existing.isDeleted {
                try await restoreForDuplicate(existing)
                steps.append(.softDeleteAgain(paperID: existing.id))
            }
            if useNewFile {
                switch await intake.applyParked(pendingID: pendingID, .replace) {
                case .replaced(_, let undoID): steps.append(.intakeUndoReplace(id: undoID))
                case .gone: throw DupResolutionError.fileExpired(review.id)
                case .failed(let why): throw DupResolutionError.failed(why)
                case .committed, .discarded, .attached: throw DupResolutionError.failed("")
                }
            } else {
                _ = await intake.applyParked(pendingID: pendingID, .discard(keepForUndo: true))
                steps.append(.intakeRestoreDiscarded(pendingID: pendingID))
            }
            // After the swap (see keepNew): this undo step reverts the re-read only.
            let before = try await DupPaperSnapshot.take(existing.pk, db: db, ctx: ctx)
            let n = try await reopenForReread(paperID: existing.id, checklist: checklist, deadline: deadline)
            steps.append(.restorePaper(before, text: nil, thumbnail: nil))
            steps.append(.removeCycle(paperPK: existing.pk, n: n))
            return (existing.id, nil, DupText.rereading(existing.title, lang), true)
        case .keepBoth(let related):
            let pair = DupPairIntent(existingPK: existing.pk, decision: related ? "related" : "distinct",
                                     relation: related ? review.relation.rawValue : nil)
            // A correction, comment or supplement printed the paper's identifier: it isn't its own,
            // so it is committed without it (two live papers can't hold one DOI).
            let strip = !review.relation.isSameWork
            switch await intake.applyParked(pendingID: pendingID, .commitAsNew(stripIdentity: strip, pair: pair)) {
            case .committed(let paper):
                return (paper.id, nil, DupText.keptBoth(lang), false)
            case .gone: throw DupResolutionError.fileExpired(review.id)
            case .failed(let why): throw DupResolutionError.failed(why)
            default: throw DupResolutionError.failed("")
            }
        case .skip:
            _ = await intake.applyParked(pendingID: pendingID, .discard(keepForUndo: true))
            steps.append(.intakeRestoreDiscarded(pendingID: pendingID))
            return (existing.isLive ? existing.id : nil, nil, DupText.skipped(lang), true)
        case .attachSupplement:
            switch await intake.applyParked(pendingID: pendingID, .attachSupplement) {
            case .attached(let paperID, let path):
                steps.append(.intakeUndoAttach(paperID: paperID, relativePath: path))
                return (paperID, nil, DupText.attached(existing.title, lang), true)
            case .gone: throw DupResolutionError.fileExpired(review.id)
            case .failed(let why): throw DupResolutionError.failed(why)
            default: throw DupResolutionError.failed("")
            }
        case .addAgain:
            throw DupResolutionError.choiceUnavailable(choice.code)
        }
    }

    /// A committed new paper (held or possible).
    private func resolveCommitted(_ review: inout DupReview, newPaper n: Paper, existing: Paper?, history: DupHistoryRow?,
                                  choice: DupChoice, steps: inout [DupUndoStep],
                                  lang: UILang) async throws -> (kept: String?, removed: String?, message: String, undoable: Bool) {
        let allowed = DupChoiceRules.choices(review, newIDs: n.ids, existing: existing, history: history).choices
        guard allowed.contains(choice.kind) else { throw DupResolutionError.choiceUnavailable(choice.code) }
        switch choice {
        case .keepNew(let reread):
            guard let e = existing else { throw DupResolutionError.choiceUnavailable(choice.code) }
            let kept = try await mergeDuplicate(keep: e, drop: n, review: &review, steps: &steps)
            if reread {
                let n = try await reopenForReread(paperID: kept.id, checklist: .keepProgress, deadline: .auto)
                steps.append(.removeCycle(paperPK: kept.pk, n: n))
            }
            return (kept.id, nil, DupText.keptNew(kept.title, lang), true)
        case .rereadEarlier(let checklist, let deadline, let useNewFile):
            guard let e = existing else { throw DupResolutionError.choiceUnavailable(choice.code) }
            var kept = e
            if useNewFile {
                kept = try await mergeDuplicate(keep: e, drop: n, review: &review, steps: &steps)
            } else {
                if n.isLive {
                    try await softDelete(paperID: n.id)
                    steps.append(.unSoftDelete(paperID: n.id))
                }
                if e.isDeleted {
                    try await restoreForDuplicate(e)
                    steps.append(.softDeleteAgain(paperID: e.id))
                }
            }
            let before = try await DupPaperSnapshot.take(kept.pk, db: db, ctx: ctx)
            let cycle = try await reopenForReread(paperID: kept.id, checklist: checklist, deadline: deadline)
            steps.append(.restorePaper(before, text: nil, thumbnail: nil))
            steps.append(.removeCycle(paperPK: kept.pk, n: cycle))
            return (kept.id, useNewFile ? nil : n.id, DupText.rereading(kept.title, lang), true)
        case .keepBoth(let related):
            let before = try await DupPaperSnapshot.take(n.pk, db: db, ctx: ctx)
            if let e = existing {
                try await db.setDupPair(n.pk, e.pk, decision: related ? "related" : "distinct",
                                        relation: related ? review.relation.rawValue : nil, decidedBy: "user", at: ctx.now())
                steps.append(.removePair(n.pk, e.pk))
            }
            if try await releaseHold(review, paper: n) { steps.append(.reholdAI(paperPK: n.pk)) }
            steps.append(.restorePaper(before, text: nil, thumbnail: nil))
            return (n.id, nil, DupText.keptBoth(lang), true)
        case .addAgain:
            let before = try await DupPaperSnapshot.take(n.pk, db: db, ctx: ctx)
            let cycles = try await db.readingCycles(paperPK: n.pk)
            let number = max(history?.readCount ?? 0, cycles.map(\.n).max() ?? 0) + 1
            try await db.insertReadingCycle(paperPK: n.pk, ReadingCycle(n: number, startedAt: ctx.now(), reason: "again"))
            steps.append(.removeCycle(paperPK: n.pk, n: number))
            if try await releaseHold(review, paper: n) { steps.append(.reholdAI(paperPK: n.pk)) }
            steps.append(.restorePaper(before, text: nil, thumbnail: nil))
            return (n.id, nil, DupText.addedAgain(n.title, lang), true)
        case .skip:
            if n.isLive {
                try await softDelete(paperID: n.id)
                steps.append(.unSoftDelete(paperID: n.id))
            }
            return (existing?.isLive == true ? existing?.id : nil, n.id, DupText.skipped(lang), true)
        case .attachSupplement:
            throw DupResolutionError.choiceUnavailable(choice.code)
        }
    }

    /// Restores a paper in Recently Deleted for a resolution; a live paper holding its DOI makes
    /// it an identifier conflict.
    private func restoreForDuplicate(_ p: Paper) async throws {
        do { _ = try await restore(paperID: p.id) } catch let e as PaperOperationError {
            if case .restoreConflict = e { throw DupResolutionError.identifierConflict(p.id) }
            throw e
        }
    }

    /// A held paper the user keeps: its placement (when the review held it back) and its reading
    /// job (when it would have been queued). True when a held job was released.
    private func releaseHold(_ review: DupReview, paper: Paper) async throws -> Bool {
        guard let held = review.held else { return false }
        if held.scheduleHeld, held.placement != "unscheduled", paper.isLive, paper.scheduleMode == .none {
            _ = try await restoreAutoDeadline(paperID: paper.id)
        }
        if held.aiQueue == true, let job = try await db.activeJob(paperPK: paper.pk), job.state == .held {
            await agents.releaseHeld(paperPKs: [paper.pk])
            return true
        }
        return false
    }

    // MARK: - Composite operations

    /// "Re-read the earlier one" (dive-dedupe §6.2): back to To Read (`done_at` cleared), a new
    /// reading cycle (the first one recorded too when the paper had been finished), the
    /// checklist kept / unticked / rebuilt from the reading card, and the DDL placed, pinned or
    /// cleared. Restore first when it is in Recently Deleted. Returns the new cycle's number.
    @discardableResult
    package func reopenForReread(paperID: String, checklist: ChecklistReset, deadline: DeadlineChoice) async throws -> Int {
        let pk = try await PaperOpsSupport.livePK(db, paperID)
        let now = ctx.now()
        let number = try await db.transaction { db -> Int in
            var p = try PaperOpsSupport.live(db, pk: pk, id: paperID)
            var cycles = try db.readingCycles(paperPK: pk)
            // Only a finished reading is recorded as one: the reading under way is closed when the
            // paper is done; an unread paper (restored from Recently Deleted) has none to record.
            if var last = cycles.last, last.doneAt == nil, let done = p.doneAt {
                last.doneAt = done
                try db.insertReadingCycle(paperPK: pk, last)
                cycles[cycles.count - 1] = last
            } else if cycles.isEmpty, let done = p.doneAt {
                let first = ReadingCycle(n: 1, startedAt: p.openedAt ?? p.addedAt, doneAt: done, reason: "first")
                try db.insertReadingCycle(paperPK: pk, first)
                cycles = [first]
            }
            let next = (cycles.map(\.n).max() ?? 0) + 1
            let readBefore = ReadingCycle.readCount(cycles, doneAt: nil) > 0
            try db.insertReadingCycle(paperPK: pk, ReadingCycle(n: next, startedAt: now, reason: readBefore ? "reread" : "first"))
            var items = try db.checklist(paperPK: pk)
            switch checklist {
            case .keepProgress:
                break
            case .uncheckAll:
                for i in items.indices { items[i].doneAt = nil }
                try db.replaceChecklist(paperPK: pk, items: items)
            case .regenerate:
                if let steps = p.card?.checklist, !steps.isEmpty {
                    var cleared = items.filter { $0.origin == .user || $0.userEdited }
                    for i in cleared.indices { cleared[i].doneAt = nil }
                    items = ChecklistMerger.merge(existing: cleared, agentSteps: steps, est: p.estMinutes ?? p.card?.estimatedMinutes ?? 30)
                } else {
                    for i in items.indices { items[i].doneAt = nil }
                }
                try db.replaceChecklist(paperPK: pk, items: items)
            }
            p.status = .toRead
            p.doneAt = nil
            try db.updatePaper(p, now: now)
            return next
        }
        await ctx.syncSidecar(pk: pk)
        switch deadline {
        case .auto: _ = try await restoreAutoDeadline(paperID: paperID)
        case .date(let d): _ = try await pinDeadline(paperID: paperID, date: d)
        case .unscheduled: _ = try await unschedule(paperID: paperID)
        }
        return number
    }

    /// "Keep the new one" for a committed new paper (dive-dedupe §6.2 `mergeDuplicate`): the kept
    /// (earlier) paper takes the new one's PDF — its own goes to `.recently-deleted/.replaced/` —
    /// and, when the new one is a newer version, its identifiers (the old DOI stays an alias);
    /// whatever the user did on the new one (ticked or own checklist items, notes, user tags,
    /// email provenance) is merged in. The new paper's row is removed (its folder parked in
    /// `.replaced/` too). The kept paper keeps its id, folder, checklist, notes, history.
    package func mergeDuplicate(keep keptPaper: Paper, drop dropped: Paper, review: inout DupReview,
                                steps: inout [DupUndoStep]) async throws -> Paper {
        // The copy's reading state before its job is cancelled (cancelling clears the paper's note —
        // "possibly unpublished, confirm before AI reading" — which must follow its file, and come
        // back with the copy on undo).
        let copyBefore = try await db.paper(pk: dropped.pk) ?? dropped
        let copyJob = try await db.activeJob(paperPK: dropped.pk)
        await agents.cancel(paperPK: dropped.pk)
        // Their folders and PDFs move below: never while the pipeline files either of them (then
        // read them again: filing may have moved a folder meanwhile).
        await enrich.waitUntilSettled(pk: dropped.pk)
        await enrich.waitUntilSettled(pk: keptPaper.pk)
        guard let n = try await db.paper(pk: dropped.pk), let e = try await db.paper(pk: keptPaper.pk) else {
            throw DupResolutionError.reviewNotFound(review.id)
        }
        var snapN = try await DupPaperSnapshot.take(n.pk, db: db, ctx: ctx)
        snapN.paper.aiState = copyBefore.aiState
        snapN.paper.aiNote = copyBefore.aiNote
        let lang = (await ctx.settings()).lang
        let paths = self.paths, library = paths.library, now = ctx.now()
        let nFolder = LibraryPaths.folderURL(forRelative: n.folder, library: library)
        // 1. The new paper's folder is parked (with its card.json); its row goes.
        let parked: URL? = try await BlockingIO.run {
            guard FileManager.default.fileExists(atPath: nFolder.path) else { return nil }
            let entry = try ReplacedPDFs.makeEntry(in: paths, paperFolder: nFolder.lastPathComponent, at: now)
            let dest = entry.appendingPathComponent(nFolder.lastPathComponent, isDirectory: true)
            try FileOps.moveFolder(from: nFolder, to: dest)
            return dest
        }
        let reviewID = review.id
        var orphaned: [DupReview] = []
        do {
            orphaned = try await db.transaction { db -> [DupReview] in
                if var r = try db.dupReview(id: reviewID) {
                    r.newPaperPK = nil                 // keep the review row (ON DELETE CASCADE)
                    try db.updateDupReview(r)
                }
                for source in try db.paperSources(paperPK: n.pk) { try db.insertPaperSource(paperPK: e.pk, source) }
                // Other papers compared with the removed one are compared with the one kept.
                let orphaned = try db.retargetOpenDupReviews(existing: n.pk, to: e.pk, history: nil, now: now)
                try db.hardDelete(pk: n.pk)
                return orphaned
            }
        } catch {
            if let parked { _ = try? await BlockingIO.run { try FileOps.moveFolder(from: parked, to: nFolder) } }
            throw error
        }
        review.newPaperPK = nil
        await releaseDuplicateHolds(orphaned)
        await ctx.sidecars.discard(paperID: n.id)
        let movedItems = (try? await db.repointMailItems(from: n.id, to: e.id)) ?? []
        steps.append(.recreatePaper(snapN, parkedFolder: parked, mailItems: movedItems, keptPaperID: e.id,
                                    heldJob: copyJob.map { $0.state == .held || $0.state == .queued } ?? false))

        // Anything below that fails puts back what was done so far (the undo steps), then throws.
        let rollbackFrom = steps.count
        do {
            return try await mergeKept(e, drop: n, snapN: snapN, copyNote: copyBefore.aiNote, parked: parked, steps: &steps,
                                       lang: lang, now: now)
        } catch {
            var newPK: [Int64: Int64] = [:]
            for step in steps[rollbackFrom - 1..<steps.count].reversed() { try? await undo(step, newPK: &newPK) }
            steps.removeSubrange((rollbackFrom - 1)..<steps.count)
            if var r = try? await db.dupReview(id: reviewID), let pk = newPK[n.pk] {
                r.newPaperPK = pk
                try? await db.updateDupReview(r)
                review.newPaperPK = pk
            }
            throw error
        }
    }

    /// Steps 2–4 of `mergeDuplicate`: the kept paper (restored when deleted) takes the new file,
    /// the newer version's ids and what the user did on the removed one.
    private func mergeKept(_ e: Paper, drop n: Paper, snapN: DupPaperSnapshot, copyNote: String?, parked: URL?,
                           steps: inout [DupUndoStep], lang: UILang, now: Date) async throws -> Paper {
        let paths = self.paths
        // 2. The kept paper back from Recently Deleted, when it was there.
        var kept = e
        if e.isDeleted {
            try await restoreForDuplicate(e)
            steps.append(.softDeleteAgain(paperID: e.id))
            kept = try await db.paper(pk: e.pk) ?? e
        }
        let target = kept
        let snapE = try await DupPaperSnapshot.take(target.pk, db: db, ctx: ctx)
        let texts = ctx.texts, thumbs = ctx.thumbs
        let oldMedia = await BlockingIO.run { ((try? texts.load(id: e.id)) ?? nil, try? Data(contentsOf: thumbs.cardURL(for: e.id))) }

        // 3. The new file into the kept paper's place (its old PDF parked in `.replaced/`).
        let pdf = ctx.pdfURL(kept)
        let newPDF = parked?.appendingPathComponent(n.pdfName)
        var backup: URL?
        if let newPDF, FileManager.default.fileExists(atPath: newPDF.path) {
            let folderName = ctx.folderURL(kept).lastPathComponent
            backup = try await BlockingIO.run { () throws -> URL? in
                var b: URL?
                if FileManager.default.fileExists(atPath: pdf.path) {
                    let dir = try ReplacedPDFs.makeEntry(in: paths, paperFolder: folderName, at: now)
                    let dest = dir.appendingPathComponent(pdf.lastPathComponent)
                    try FileOps.atomicRename(from: pdf, to: dest)
                    b = dest
                }
                do { try FileOps.atomicRename(from: newPDF, to: pdf) } catch {
                    if let b { try? FileOps.atomicRename(from: b, to: pdf) }
                    throw error
                }
                return b
            }
            steps.append(.swapBack(paperPK: target.pk, backup: backup, newFileTo: newPDF))
        }
        steps.append(.restorePaper(snapE, text: oldMedia.0, thumbnail: oldMedia.1))

        // 4. The row: the new file's facts, the newer version's ids, what the user did on the new paper.
        let newText = await BlockingIO.run { (try? texts.load(id: n.id)) ?? nil }
        let adopt = IntakeActor.adoptsIdentity(new: n.ids, existing: target)
        let fileMoved = newPDF != nil
        // The privacy floor follows the file: the copy's "confidential" / "never use AI" marks are
        // added to the kept paper's (never removed), and an email's holds — a possibly unpublished
        // PDF held for confirmation, titles kept off the network — come along with its file.
        let mergedPolicy = Self.mergedPolicy(kept: snapE.policy, copy: snapN.policy, now: now)
        let carryNote = fileMoved && copyNote == ImportAnnotation.unpublishedHoldNote
            && target.aiNote != ImportAnnotation.unpublishedHoldNote
        let carryLookupHeld = fileMoved && n.flags.contains(.titleLookupHeld)
        // The kept row was a notice / comment / review file / supplement printing the paper's id.
        let takeTitle = fileMoved && IntakeActor.takesTitle(existing: target, newTitle: n.title, newRank: n.titleRank,
                                                           newFileName: n.originalName)
        let saved = try await db.transaction { db -> Paper in
            let takeDOI: Bool = try {
                guard adopt, let doi = n.ids.doi else { return false }
                return try db.livePaper(holdingDOI: doi, excluding: target.pk) == nil
            }()
            let takeArxiv: Bool = try {
                guard adopt, target.ids.arxivID == nil, let a = n.ids.arxivID else { return false }
                return try db.paperMatchingWork(doi: nil, arxivID: a, publishedDOI: nil, excluding: target.pk) == nil
            }()
            var items = try db.checklist(paperPK: target.pk)
            let have = Set(items.map { ChecklistMerger.norm($0.text) })
            var ord = (items.map(\.ord).max() ?? -1) + 1
            for item in snapN.checklist where ChecklistMerger.isTouched(item) && !have.contains(ChecklistMerger.norm(item.text)) {
                var copy = item
                copy.id = ChecklistItem.newID()
                copy.ord = ord
                ord += 1
                items.append(copy)
            }
            if items.count != (try db.checklist(paperPK: target.pk)).count { try db.replaceChecklist(paperPK: target.pk, items: items) }
            var tags = try db.tags(paperPK: target.pk)
            for t in snapN.tags where t.origin == .user && !tags.contains(where: { $0.name.lowercased() == t.name.lowercased() }) {
                tags.append(t)
            }
            try db.setTags(paperPK: target.pk, tags)
            let saved = try db.modifyPaper(pk: target.pk, now: now) { p in
                if fileMoved {
                    p.sha256 = n.sha256
                    p.fileSize = n.fileSize
                    p.pageCount = n.pageCount
                    p.charCount = n.charCount
                    p.flags.subtract([.locked, .scanned, .unreadable, .missing])
                    p.flags.formUnion(n.flags.intersection([.locked, .scanned, .unreadable]))
                    p.originalName = n.originalName
                    if let v = n.ids.arxivVersion { p.ids.arxivVersion = v }
                }
                if takeDOI, let doi = n.ids.doi { p.ids.doi = doi.lowercased() }
                if takeArxiv { p.ids.arxivID = n.ids.arxivID }
                if takeDOI || takeArxiv, !p.metaUserEdited { p.metaSource = .none }
                if carryNote { p.aiNote = ImportAnnotation.unpublishedHoldNote }
                if carryLookupHeld { p.flags.insert(.titleLookupHeld) }
                if takeTitle {
                    p.title = n.title
                    p.titleRank = n.titleRank
                }
                let extra = n.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !extra.isEmpty {
                    let head = DupText.mergedNotesHeader(n.title, lang: lang)
                    p.notes = p.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? extra
                        : p.notes + "\n\n" + head + "\n" + extra
                }
            }
            if fileMoved, let newText { try db.indexFullText(pk: target.pk, text: newText) }
            var aliases = snapN.keys.filter { $0.source != .local }
                + DupKeys.local(n.ids).map { DupKey(kind: $0.kind == .doi ? .versionDOI : $0.kind, value: $0.value, source: .merge) }
            if takeDOI, let old = target.ids.doi, let token = DupKeys.doiToken(old) {
                aliases.append(DupKey(kind: .preprintDOI, value: token, source: .merge))
            }
            try db.addDupKeys(paperPK: target.pk, aliases.map { DupKey(kind: $0.kind, value: $0.value, source: .merge) })
            try db.refreshLocalDupKeys(paperPK: target.pk)
            try db.deleteDupFingerprint(paperPK: target.pk)
            if let mergedPolicy { try db.setPaperPolicy(paperPK: target.pk, mergedPolicy) }
            return saved
        }
        // A reading of the kept paper waiting in the queue would now read the stricter copy's
        // file: it waits for the user's confirmation instead.
        var reheld = false
        if fileMoved, mergedPolicy != nil || carryNote,
           let job = try? await db.activeJob(paperPK: target.pk), job.state == .queued {
            await agents.enqueue(paperPK: target.pk, hold: true, priority: job.priority)
            reheld = true
            if carryNote {
                _ = try? await db.modifyPaper(pk: target.pk, now: now) { $0.aiNote = ImportAnnotation.unpublishedHoldNote }
            }
        }
        steps.append(.restorePrivacy(paperPK: target.pk, policy: snapE.policy, merged: mergedPolicy, aiNote: target.aiNote,
                                     noteCarried: carryNote, reheld: reheld))
        if fileMoved {
            let id = target.id, nid = n.id
            await BlockingIO.run {
                if let newText { try? texts.save(newText, id: id) }
                if let jpeg = try? Data(contentsOf: thumbs.cardURL(for: nid)) { try? thumbs.save(cardJPEG: jpeg, id: id) }
            }
        }
        await ctx.syncSidecar(pk: target.pk)
        if saved.metaSource == .none, saved.ids != target.ids {
            let enrich = self.enrich, pk = target.pk
            Task { _ = await enrich.refreshMetadata(pk: pk) }
        }
        // The removed paper's caches go once the undo window has passed (unless undone).
        let ctx = self.ctx, nid = n.id
        Task {
            try? await Task.sleep(for: .seconds(UndoToken.lifetime + 5))
            if (try? await ctx.db.paper(id: nid)) == nil {
                await BlockingIO.run { _ = ctx.texts.delete(id: nid); ctx.thumbs.delete(id: nid) }
            }
        }
        return saved
    }

    /// The kept paper's policy after a merge: each flag on when either paper had it (set by the
    /// merge). nil when the copy adds nothing.
    static func mergedPolicy(kept: PaperPolicy?, copy: PaperPolicy?, now: Date) -> PaperPolicy? {
        guard let copy, !copy.isEmpty else { return nil }
        let confidential = (kept?.confidential ?? false) || copy.confidential
        let neverAI = (kept?.neverAI ?? false) || copy.neverAI
        guard confidential != (kept?.confidential ?? false) || neverAI != (kept?.neverAI ?? false) else { return nil }
        return PaperPolicy(confidential: confidential, neverAI: neverAI, setBy: .merge, setAt: now)
    }

    // MARK: - Undo

    /// Reverts a resolution within `UndoToken.lifetime` (one token = one decision). False when
    /// the token is unknown, used or expired.
    @discardableResult
    package func undoDuplicateResolution(token: String) async throws -> Bool {
        guard let entry = await dupUndoLedger.take(token, owner: ObjectIdentifier(self), now: ctx.now()) else { return false }
        var newPK: [Int64: Int64] = [:]
        for step in entry.steps.reversed() {
            do { try await undo(step, newPK: &newPK) } catch {
                Log.importer.error("duplicate undo step failed: \(String(describing: error), privacy: .public)")
            }
        }
        if let open = try? await db.openDupReviewCount() { ctx.events.send(.dedupe(.openCount(open))) }
        return true
    }

    /// A choice that failed half-way: what it did so far is put back (newest first); the review stays open.
    private func rollBack(_ steps: ArraySlice<DupUndoStep>) async {
        var newPK: [Int64: Int64] = [:]
        for step in steps.reversed() {
            do { try await undo(step, newPK: &newPK) } catch {
                Log.importer.error("duplicate rollback step failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func undo(_ step: DupUndoStep, newPK: inout [Int64: Int64]) async throws {
        switch step {
        case .reopenReview(var r):
            if let pk = r.newPaperPK, let mapped = newPK[pk] { r.newPaperPK = mapped }
            r.state = .open
            r.choice = nil
            r.resolvedAt = nil
            if try await db.dupReview(id: r.id) != nil { try await db.updateDupReview(r) } else { try await db.insertDupReview(r) }
            ctx.events.send(.dedupe(.reviewOpened(reviewID: r.id, paperID: r.newPaperPK == nil ? nil : r.newPaperID)))
        case .restorePaper(let snap, let text, let thumbnail):
            try await snap.restore(db: db, ctx: ctx, now: ctx.now(), text: text, thumbnail: thumbnail)
        case .recreatePaper(let snap, let parked, let items, let keptID, let heldJob):
            if let parked {
                let dest = LibraryPaths.folderURL(forRelative: snap.paper.folder, library: paths.library)
                try await BlockingIO.run {
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileOps.moveFolder(from: parked, to: dest)
                    try? FileManager.default.removeItem(at: parked.deletingLastPathComponent())
                }
            }
            let pk = try await snap.recreate(db: db, ctx: ctx)
            newPK[snap.paper.pk] = pk
            _ = try? await db.repointMailItems(from: keptID, to: snap.paper.id, only: items)
            if heldJob {
                // Its reading waits again (for the review, or for the confirmation its note asks for).
                await agents.enqueue(paperPK: pk, hold: true)
                if let note = snap.paper.aiNote {
                    _ = try? await db.modifyPaper(pk: pk, now: ctx.now()) { $0.aiNote = note }
                }
            }
            await ctx.syncSidecar(pk: pk)
        case .swapBack(let paperPK, let backup, let newFileTo):
            guard let p = try await db.paper(pk: paperPK) else { return }
            let pdf = ctx.pdfURL(p)
            try await BlockingIO.run {
                if let newFileTo {
                    try FileManager.default.createDirectory(at: newFileTo.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileOps.atomicRename(from: pdf, to: newFileTo)
                }
                if let backup {
                    try FileOps.atomicRename(from: backup, to: pdf)
                    try? FileManager.default.removeItem(at: backup.deletingLastPathComponent())
                }
            }
        case .softDeleteAgain(let id):
            if let p = try await db.paper(id: id), p.isLive { _ = try await softDelete(paperID: id) }
        case .unSoftDelete(let id):
            if let p = try await db.paper(id: id), p.isDeleted { _ = try await restore(paperID: id) }
        case .removePair(let a, let b):
            try await db.removeDupPair(newPK[a] ?? a, newPK[b] ?? b)
            await ctx.syncSidecar(pk: newPK[a] ?? a)
            await ctx.syncSidecar(pk: newPK[b] ?? b)
        case .removeCycle(let pk, let n):
            try await db.deleteReadingCycle(paperPK: newPK[pk] ?? pk, n: n)
            await ctx.syncSidecar(pk: newPK[pk] ?? pk)
        case .reholdAI(let pk):
            await agents.enqueue(paperPK: newPK[pk] ?? pk, hold: true)
        case .restorePrivacy(let pk0, let before, let merged, let note, let carried, let reheld):
            let pk = newPK[pk0] ?? pk0
            // Only what the merge set, and only while nobody changed it since.
            if let merged, let current = try await db.paperPolicy(paperPK: pk),
               current.confidential == merged.confidential, current.neverAI == merged.neverAI {
                try await db.setPaperPolicy(paperPK: pk, before ?? PaperPolicy())
            }
            if reheld, let job = try await db.activeJob(paperPK: pk), job.state == .held {
                await agents.releaseHeld(paperPKs: [pk])
            }
            if carried, let p = try await db.paper(pk: pk), p.aiNote == ImportAnnotation.unpublishedHoldNote {
                _ = try await db.modifyPaper(pk: pk, now: ctx.now()) { $0.aiNote = note }
            }
            await ctx.syncSidecar(pk: pk)
        case .intakeRestoreDiscarded(let pending):
            _ = await intake.restoreDiscarded(pendingID: pending)
        case .intakeUndoReplace(let id):
            _ = await intake.undoReplace(id: id)
        case .intakeUndoAttach(let paperID, let path):
            _ = await intake.undoAttach(paperID: paperID, relativePath: path)
        }
    }

    // MARK: - Checking the library

    /// Library ▸ Check for Duplicates… (`paperIDs` empty: every live paper) and the selection
    /// bar's "Check duplicates": each paper against the rest of the library (identity, then title +
    /// authors + text). New pairs open reviews (origin scan; the later-added paper is "new");
    /// pairs under review or decided before are counted, not asked again. Nothing is changed
    /// otherwise. Cancellable (`Task.cancel`); `progress(done, total)` after each paper. Papers
    /// whose text fingerprint is computed now are paced (`backfillPause`) so a first check of a
    /// big library doesn't load the Mac; in Low Power Mode it goes slower still.
    @discardableResult
    package func checkDuplicates(paperIDs: [String] = [],
                                 progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil) async throws -> DupCheckSummary {
        let settings = await ctx.settings()
        var targets: [Paper]
        if paperIDs.isEmpty { targets = try await db.livePapers() } else {
            targets = []
            for id in paperIDs { if let p = try await db.paper(id: id), p.isLive { targets.append(p) } }
        }
        let printed = Set(try await db.dupFingerprints(paperPKs: targets.map(\.pk)).keys)
        var summary = DupCheckSummary()
        var asked = Set<[Int64]>()
        for p in targets {
            try Task.checkCancellation()
            summary.checked += 1
            let pair = try await scanPair(p, settings: settings.dedupe)
            progress?(summary.checked, targets.count)
            if !printed.contains(p.pk) {
                let pause = ProcessInfo.processInfo.isLowPowerModeEnabled ? Self.backfillPause * 4 : Self.backfillPause
                try await Task.sleep(for: pause)
            } else {
                await Task.yield()
            }
            guard let pair else { continue }
            let key = [min(pair.new.pk, pair.existing.pk), max(pair.new.pk, pair.existing.pk)]
            guard asked.insert(key).inserted else { continue }
            let underReview = try await db.openDupReview(pair: pair.new.pk, pair.existing.pk) != nil
            let newOpen = try await db.openDupReview(newPaperPK: pair.new.pk) != nil
            if underReview || newOpen {
                summary.known += 1
                continue
            }
            let c = pair.candidate
            let review = DupReview(newPaperID: pair.new.id, existingPaperID: pair.existing.id,
                                   band: c.band, score: c.score, createdAt: ctx.now(),
                                   newPaperPK: pair.new.pk, existingPaperPK: pair.existing.pk, relation: c.relation,
                                   evidence: c.evidence, newerSide: c.newerSide, origin: .scan)
            try await db.insertDupReview(review)
            summary.opened.append(review.id)
            ctx.events.send(.dedupe(.reviewOpened(reviewID: review.id, paperID: pair.new.id)))
        }
        if let open = try? await db.openDupReviewCount() { ctx.events.send(.dedupe(.openCount(open))) }
        return summary
    }

    /// The pause after a paper whose fingerprint the check had to compute (its text is read).
    package static let backfillPause: Duration = .milliseconds(10)

    /// The best duplicate of `p` among the other live papers, oriented so `new` is the later-added one.
    private func scanPair(_ p: Paper, settings: DedupeSettings) async throws -> (new: Paper, existing: Paper, candidate: DupCandidate)? {
        let subject = await DedupeIndex.subject(for: p, ctx: ctx)
        var dedupe = settings
        dedupe.history = false
        guard let m = await DedupeIndex.match(subject, ids: p.ids, excluding: p.pk, settings: dedupe, ctx: ctx),
              let other = m.existing, other.isLive else { return nil }
        if p.addedAt >= other.addedAt { return (p, other, m.candidate) }
        // Re-orient: compare the other way so "newer" and the relation read from the later paper.
        let otherSubject = await DedupeIndex.subject(for: other, ctx: ctx)
        let c = DupDetector.compare(otherSubject, subject, sensitivity: settings.sensitivity) ?? m.candidate
        return (other, p, c)
    }

    /// `--dedupe-report`: the pairs a check would ask about, read-only (no review is written,
    /// nothing is fetched, no AI). `known`: already under review or decided.
    package func dedupeReport() async throws -> [DupReportPair] {
        let settings = await ctx.settings()
        var out: [DupReportPair] = []
        var seen = Set<[Int64]>()
        for p in try await db.livePapers() {
            guard let pair = try await scanPair(p, settings: settings.dedupe) else { continue }
            let key = [min(pair.new.pk, pair.existing.pk), max(pair.new.pk, pair.existing.pk)]
            guard seen.insert(key).inserted else { continue }
            let open = try await db.openDupReview(pair: pair.new.pk, pair.existing.pk) != nil
            let decided = try await db.dupPair(pair.new.pk, pair.existing.pk) != nil
            let known = open || decided
            out.append(DupReportPair(newPaperID: pair.new.id, existingPaperID: pair.existing.id, band: pair.candidate.band,
                                     relation: pair.candidate.relation, score: pair.candidate.score,
                                     evidence: pair.candidate.evidence, known: known))
        }
        return out.sorted { $0.band != $1.band ? $0.band > $1.band : $0.score > $1.score }
    }

    /// Settings ▸ Library ▸ Duplicates ▸ Clear History: forgets every removed paper. Open reviews
    /// that matched one end with it; the new papers they held are released first (DDL placed,
    /// reading job queued as it would have been).
    @discardableResult
    package func clearDuplicateHistory() async throws -> Int {
        let matched = try await db.openDupReviewsMatchingHistory()
        await releaseDuplicateHolds(matched)
        let n = try await db.clearHistory()
        for r in matched { ctx.events.send(.dedupe(.reviewClosed(reviewID: r.id))) }
        if let open = try? await db.openDupReviewCount() { ctx.events.send(.dedupe(.openCount(open))) }
        return n
    }

    /// Reviews that ended without an answer (what they compared with is gone): their held new
    /// papers get the placement and the reading job the review held back.
    package func releaseDuplicateHolds(_ reviews: [DupReview]) async {
        for r in reviews {
            guard let pk = r.newPaperPK, let paper = try? await db.paper(pk: pk) else { continue }
            do { _ = try await releaseHold(r, paper: paper) } catch {
                Log.importer.error("duplicate hold release \(pk) failed: \(String(describing: error), privacy: .public)")
            }
            ctx.events.send(.dedupe(.reviewClosed(reviewID: r.id)))
        }
    }

    package func duplicateHistoryCount() async -> Int { (try? await db.historyCount()) ?? 0 }

    // MARK: - Batch review (B3)

    /// The rows of a batch review: the open reviews among `ids` with their choices and suggestions,
    /// in `DupBatch.ordered` order (closed or unknown ids are left out).
    package func duplicateBatchRows(ids: [String]) async -> [DupBatchRow] {
        var details: [DupReviewDetail] = []
        for id in ids {
            if let d = try? await duplicateReviewDetail(id: id), d.review.state == .open { details.append(d) }
        }
        return DupBatch.ordered(details).map { DupBatchRow(detail: $0) }
    }

    /// The open reviews of one import (its `batchID`), oldest first; or, for a library check, the
    /// open reviews it opened (`origin` scan) — what a batch review sheet lists.
    package func duplicateBatchReviewIDs(batchID: String?) async -> [String] {
        if let batchID { return ((try? await db.openDupReviews(batchID: batchID)) ?? []).map(\.id) }
        let open = (try? await duplicateReviews(state: .open)) ?? []
        return open.filter { $0.origin == .scan }.reversed().map(\.id)
    }

    /// [Apply] of the batch review: each row resolved in turn (its own transaction; file swaps
    /// can't share one). A row that can't be applied (answered elsewhere, its file gone, a
    /// conflict) is reported and the others still go. One undo token reverts every applied row.
    @discardableResult
    package func resolveDuplicates(_ items: [(reviewID: String, choice: DupChoice)]) async -> DupBatchResolution {
        let lang = (await ctx.settings()).lang
        var out = DupBatchResolution()
        var steps: [DupUndoStep] = []
        for item in items {
            do {
                let r = try await resolveDuplicate(reviewID: item.reviewID, item.choice)
                out.resolved.append(r)
                // The row's own undo record joins the batch's (applied in reverse: last row first).
                if let token = r.undoToken,
                   let entry = await dupUndoLedger.take(token, owner: ObjectIdentifier(self), now: ctx.now()) {
                    steps += entry.steps
                }
            } catch let e as DupResolutionError {
                out.failed[item.reviewID] = e
            } catch {
                out.failed[item.reviewID] = .failed(String(describing: error))
            }
        }
        if !steps.isEmpty {
            let token = UUID().uuidString.lowercased()
            let now = ctx.now()
            await dupUndoLedger.put(token, DupUndoLedger.Entry(owner: ObjectIdentifier(self),
                                                               expiresAt: now.addingTimeInterval(UndoToken.lifetime),
                                                               steps: steps), now: now)
            out.undoToken = token
        }
        // Each row's own token was folded into the batch's: one [Undo] for the whole sheet.
        for i in out.resolved.indices { out.resolved[i].undoToken = nil }
        out.message = DupBatchResolution.message(applied: out.resolved.count, failed: out.failed.count, lang: lang)
        return out
    }

    // MARK: - AI judge (B3)

    /// The kv row of Settings ▸ Library ▸ Duplicates ▸ "Ask AI to judge" (kept with the library,
    /// never exported; absent = off, the default).
    package static let duplicateJudgeKey = "dedupe.ai.judge"

    /// The "Ask AI to judge" switch (off by default). Even on, the judge runs only on a click, only
    /// with Explain & Ask on (`assist.mode`), at most `dedupe.ai.dailyCap` times a day, never for a
    /// paper marked confidential, never-AI or possibly unpublished.
    package func duplicateJudgeEnabled() async -> Bool { (try? await db.kv(Self.duplicateJudgeKey)) == "1" }

    package func setDuplicateJudgeEnabled(_ on: Bool) async throws {
        if on { try await db.setKV(Self.duplicateJudgeKey, "1") } else { try await db.removeKV(Self.duplicateJudgeKey) }
        if let open = try? await db.openDupReviewCount() { ctx.events.send(.dedupe(.openCount(open))) }
    }

    /// Whether [Ask AI] can run for `reviewID` now, and today's count against the cap.
    package func duplicateJudgeStatus(reviewID: String) async -> DupJudgeStatus {
        let settings = await ctx.settings()
        let used = dedupeJudgeCounter.count(at: ctx.now())
        var status = DupJudgeStatus(block: nil, usedToday: used, dailyCap: settings.dedupe.aiDailyCap)
        guard let review = try? await db.dupReview(id: reviewID) else {
            status.block = .reviewClosed
            return status
        }
        status.block = await judgeBlock(review, settings: settings).block
        return status
    }

    /// [Ask AI] in a decision sheet (or a batch review row): one judge turn through `AssistLane`
    /// (`.dupJudge`, one-shot, one JSON object in the text) with the ticket the click minted. The
    /// answer only re-bands the review (`DupJudge.reband`) and is kept with it (`aiVerdict`); it
    /// never resolves, merges, replaces or removes anything. Throws `DupJudgeError` when the judge
    /// isn't available for this review, the gate refuses the turn, the turn fails, or the answer
    /// can't be read. Unknown review: `DatabaseError.notFound`.
    package func askDuplicateJudge(reviewID: String, ticket: ConsentTicket) async throws -> DupReview {
        guard let review = try await db.dupReview(id: reviewID) else {
            throw DatabaseError.notFound("duplicate review \(reviewID)")
        }
        let settings = await ctx.settings()
        let check = await judgeBlock(review, settings: settings)
        if let block = check.block { throw DupJudgeError.blocked(block) }
        guard let newPaper = check.new, let existing = check.existing else { throw DupJudgeError.blocked(.reviewClosed) }
        // One judge turn at a time per engine: the cap check and the count stay together.
        guard DupJudgeInFlight.shared.begin(ObjectIdentifier(self)) else { throw DupJudgeError.blocked(.busy) }
        defer { DupJudgeInFlight.shared.end(ObjectIdentifier(self)) }
        if dedupeJudgeCounter.count(at: ctx.now()) >= settings.dedupe.aiDailyCap {
            throw DupJudgeError.blocked(.dailyCap)
        }

        // The review's match first, then up to two more library papers the detector also matched
        // (context for telling versions apart; their answers are shown, never acted on).
        var candidates: [Paper] = [existing]
        let newSubject = await DedupeIndex.subject(for: newPaper, ctx: ctx, computeMissing: false)
        for m in await DedupeIndex.paperMatches(newSubject, ids: newPaper.ids, excluding: newPaper.pk,
                                                settings: settings.dedupe, ctx: ctx, limit: DupJudge.maxCandidates + 1) {
            guard candidates.count < DupJudge.maxCandidates, let p = m.existing, p.pk != existing.pk,
                  p.isLive, await judgeMayRead(p) else { continue }
            candidates.append(p)
        }
        var records: [DupJudgePrompt.Record] = []
        for p in candidates { records.append(await judgeRecord(p)) }
        let provider = settings.assist.mode.providerKind
        let model = provider.map { settings.assist.model($0, .quick) } ?? settings.assist.mode.rawValue
        let request = AssistRequest(surface: .dupJudge, systemPrompt: DupJudgePrompt.system,
                                    turnText: DupJudgePrompt.turnText(new: await judgeRecord(newPaper), candidates: records),
                                    model: model, effort: "low", format: .jsonInText, session: .oneShot,
                                    limits: AssistLimits.defaults(for: .dupJudge, provider: provider))

        var terminal: AssistEvent?
        for await event in await assist.submit(request, ticket: ticket) where event.isTerminal {
            terminal = event
        }
        let answer: String
        let meta: AssistMeta
        switch terminal {
        case .done(let text, let m)?:
            answer = text
            meta = m
            dedupeJudgeCounter.increment(at: ctx.now())
        case .failed(let failure, _)?:
            // A refused or unsupported turn never reached a model: nothing counted.
            switch failure {
            case .refused(let verdict): throw DupJudgeError.refused(verdict)
            case .unsupported: throw DupJudgeError.failed(failure)
            default:
                dedupeJudgeCounter.increment(at: ctx.now())
                throw DupJudgeError.failed(failure)
            }
        default:
            throw DupJudgeError.failed(.cancelled)
        }

        let judgements = DupJudgeParser.parse(answer, candidates: candidates.count)
        guard let first = judgements.first(where: { $0.candidate == 1 }) else { throw DupJudgeError.unreadable }
        let others = judgements.filter { $0.candidate > 1 }.compactMap { j -> DupAIVerdict.Other? in
            let p = candidates[j.candidate - 1]
            return DupAIVerdict.Other(paperID: p.id, title: p.title, verdict: j.verdict, confidence: j.confidence)
        }
        let at = ctx.now()
        // On the stored review in one step: the user may have answered it meanwhile (then the
        // answer is dropped), and the import's enrichment may have re-banded it (the answer
        // re-bands what is stored, never a stale copy).
        let stored = try await db.modifyDupReview(id: reviewID) { latest in
            guard latest.state == .open else { throw DupJudgeError.blocked(.reviewClosed) }
            let after = DupJudge.reband(latest.band, first)
            latest.aiVerdict = DupAIVerdict(verdict: first.verdict, confidence: first.confidence, reason: first.reason,
                                            newer: first.newer, bandBefore: latest.band, bandAfter: after,
                                            provider: meta.provider, model: meta.model, at: at, others: others)
            latest.band = after
            latest.aiState = DupJudge.answeredState
            return true
        }
        guard let latest = stored else { throw DupJudgeError.blocked(.reviewClosed) }
        Log.importer.info("duplicate judge: \(first.verdict.rawValue, privacy: .public) \(Int(first.confidence * 100))% (\(latest.band.rawValue, privacy: .public))")
        if let open = try? await db.openDupReviewCount() { ctx.events.send(.dedupe(.openCount(open))) }
        return latest
    }

    /// Why the judge can't run for `review` (nil: it can), with the two papers when it can.
    private func judgeBlock(_ review: DupReview, settings: EngineSettings) async -> (block: DupJudgeBlock?, new: Paper?, existing: Paper?) {
        guard review.state == .open else { return (.reviewClosed, nil, nil) }
        guard settings.dedupe.enabled else { return (.dedupeOff, nil, nil) }
        guard await duplicateJudgeEnabled() else { return (.switchedOff, nil, nil) }
        guard settings.assist.mode != .off else { return (.assistOff, nil, nil) }
        // An identifier or the same bytes: nothing for an AI to weigh (and it couldn't move it).
        guard review.band != .certain, !review.isParked else { return (.certain, nil, nil) }
        guard review.existingPaperPK != nil else { return (.removedPaper, nil, nil) }
        guard let npk = review.newPaperPK, let n = try? await db.paper(pk: npk),
              let epk = review.existingPaperPK, let e = try? await db.paper(pk: epk) else { return (.reviewClosed, nil, nil) }
        guard await judgeMayRead(n) else { return (.privateNew, nil, nil) }
        guard await judgeMayRead(e) else { return (.privateExisting, nil, nil) }
        if dedupeJudgeCounter.count(at: ctx.now()) >= settings.dedupe.aiDailyCap { return (.dailyCap, nil, nil) }
        return (nil, n, e)
    }

    /// The judge may read a paper: `AssistPrivacy` says ok (not never-AI, not marked confidential,
    /// not held as possibly unpublished, not a person's email without a public id) and its title
    /// may even be remembered (`mayRemember`: no confidential email either). Stricter than Explain
    /// and Q&A: no confirmation path — these papers are never sent to the judge.
    private func judgeMayRead(_ p: Paper) async -> Bool {
        guard let verdict = try? await assistPrivacy(paperID: p.id, hostBundleID: nil), verdict == .ok else { return false }
        return (try? await db.mayRemember(p)) == true
    }

    /// A paper as the prompt shows it: metadata and the first page of its text (clipped there).
    private func judgeRecord(_ p: Paper) async -> DupJudgePrompt.Record {
        let texts = ctx.texts, id = p.id
        let first = await BlockingIO.run { () -> String? in
            guard let text = (try? texts.load(id: id)) ?? nil else { return nil }
            return text.components(separatedBy: "\u{0C}")
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { String($0.prefix(4 * DupJudgePrompt.pageChars)) }
        }
        return .paper(p, firstPage: first)
    }

    // MARK: - Mail merge popover (B3)

    /// The library paper an email row looks like, before it is merged (nil: none, the row is
    /// already linked, or the duplicate check is off). Read from the row's metadata only: nothing
    /// is downloaded, fetched or sent.
    package func mailDuplicateMatch(itemID: String) async -> MailDupMatch? {
        let settings = await ctx.settings()
        guard settings.dedupe.enabled, let item = try? await db.mailItem(id: itemID), item.status == .pending,
              item.pdfState != .inLibrary else { return nil }
        let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty || item.ids.doi != nil || item.ids.arxivID != nil else { return nil }
        let subject = DupSubject(keys: DupKeys.local(item.ids), doi: item.ids.doi, title: title,
                                 surnames: DedupeText.surnames(item.authors), year: item.year, venue: item.venue,
                                 rank: VersionRank.of(ids: item.ids, venue: item.venue))
        var dedupe = settings.dedupe
        dedupe.history = false
        guard let m = await DedupeIndex.match(subject, ids: item.ids, excluding: nil, settings: dedupe, ctx: ctx,
                                              computeMissing: 4),
              let e = m.existing, e.id != item.paperID else { return nil }
        let lang = settings.lang
        let identity = m.candidate.band == .certain
        let rules = MailDupRules.choices(existing: e, band: m.candidate.band, relation: m.candidate.relation,
                                         newerSide: m.candidate.newerSide, identity: identity)
        guard let summary = try? await summary(of: e, lang: lang) else { return nil }
        let probe = DupReview(newPaperID: nil, existingPaperID: e.id, band: m.candidate.band, score: m.candidate.score,
                              createdAt: ctx.now(), existingPaperPK: e.pk, relation: m.candidate.relation,
                              evidence: m.candidate.evidence, newerSide: m.candidate.newerSide, origin: .mail)
        let newSide = DupSideSummary(title: title, venue: item.venue, year: item.year,
                                     versionLabel: DupExplainer.versionLabel(venue: item.venue,
                                                                             rank: VersionRank.of(ids: item.ids, venue: item.venue),
                                                                             ids: item.ids, lang: lang))
        let words = DupExplainer.explain(probe, new: newSide, existing: summary, lang: lang, calendar: ctx.calendar)
        return MailDupMatch(itemID: item.id, existingPaperID: e.id, existing: summary, band: m.candidate.band,
                            relation: m.candidate.relation, newerSide: m.candidate.newerSide, identity: identity,
                            headline: words.headline, historyLine: words.historyLine, versionLine: words.versionLine,
                            evidence: words.evidence, choices: rules.choices, defaultChoice: rules.default)
    }

    /// The popover's answer for an email row that looks like `paperID` (see `MailDupChoice`).
    /// `options` are the popover's (priority, pinned due date, category; AI reading only for a
    /// paper added separately). Every library change but a plain link is undoable for 30 s — a
    /// link or re-read that restored the paper from Recently Deleted puts it back there too.
    @discardableResult
    package func resolveMailDuplicate(itemID: String, paperID: String, choice: MailDupChoice,
                                      options: MailMergeOptions) async throws -> MailDupOutcome {
        let settings = await ctx.settings()
        let lang = settings.lang
        guard settings.dedupe.enabled else { throw DupResolutionError.choiceUnavailable(choice.rawValue) }
        guard let item = try await db.mailItem(id: itemID), item.status == .pending else {
            throw DupResolutionError.reviewClosed(itemID)
        }
        guard let e = try await db.paper(id: paperID) else { throw DupResolutionError.reviewNotFound(paperID) }
        switch choice {
        case .link, .reread:
            // A paper in Recently Deleted is restored first — and Undo deletes it again, as the
            // decision sheet's restore does (B3-4): the step comes first, so it is undone last.
            var steps: [DupUndoStep] = []
            if e.isDeleted {
                try await restoreForDuplicate(e)
                steps.append(.softDeleteAgain(paperID: e.id))
            }
            try await linkMailItem(itemID: itemID, paperID: e.id)
            guard choice == .reread else {
                // A plain link changes nothing in the library; a link that restored the paper is undoable.
                let token = steps.isEmpty ? nil : await ledger(steps)
                return MailDupOutcome(paperID: e.id, undoToken: token, message: MailDupText.linked(e.title, lang))
            }
            // Taken after the restore: its undo reverts the re-read only (then the paper goes back).
            let before = try await DupPaperSnapshot.take(e.pk, db: db, ctx: ctx)
            let n = try await reopenForReread(paperID: e.id, checklist: .keepProgress,
                                              deadline: options.pinDeadline.map { .date($0) } ?? .auto)
            steps += [.restorePaper(before, text: nil, thumbnail: nil), .removeCycle(paperPK: e.pk, n: n)]
            let token = await ledger(steps)
            return MailDupOutcome(paperID: e.id, undoToken: token, message: DupText.rereading(e.title, lang))
        case .addSeparately:
            guard let id = try await mergeMailItem(itemID: itemID, options: options) else {
                return MailDupOutcome(paperID: nil, message: MailDupText.failed(lang))
            }
            if id == e.id { return MailDupOutcome(paperID: id, message: MailDupText.sameAfterAll(e.title, lang)) }
            guard let n = try await db.paper(id: id) else { return MailDupOutcome(paperID: id, message: DupText.keptBoth(lang)) }
            let related = DupRelationGuess.related(n, e)
            if let r = try await db.openDupReview(newPaperPK: n.pk), r.existingPaperPK == e.pk {
                let done = try await resolveDuplicate(reviewID: r.id, .keepBoth(linkAsRelated: related))
                return MailDupOutcome(paperID: id, reviewID: r.id, undoToken: done.undoToken, message: done.message)
            }
            try await db.setDupPair(n.pk, e.pk, decision: related ? "related" : "distinct", relation: nil, decidedBy: "user",
                                    at: ctx.now())
            await ctx.syncSidecar(pk: n.pk)
            await ctx.syncSidecar(pk: e.pk)
            let token = await ledger([.removePair(n.pk, e.pk)])
            return MailDupOutcome(paperID: id, undoToken: token, message: DupText.keptBoth(lang))
        case .useThisVersion:
            return try await useMailVersion(item, existing: e, options: options, lang: lang)
        }
    }

    /// "Use this version": the email's PDF takes the library paper's place through a duplicate
    /// review resolved with "keep the new one" (the paper keeps its checklist, notes and history).
    private func useMailVersion(_ item: MailItem, existing e: Paper, options: MailMergeOptions,
                                lang: UILang) async throws -> MailDupOutcome {
        var quiet = options
        quiet.readWithAI = false                  // the file is folded into a paper that has its card
        // An identifier match: a merge would link the email and drop its file, so the stored copy
        // goes through the intake, which parks it against the paper — then "keep the new one".
        let tokens = DupKeys.local(item.ids).map(\.value).sorted()
        var identity = false
        if !tokens.isEmpty {
            identity = try await db.paperPKs(holdingTokens: tokens, dois: DedupeIndex.columnDOIs(item.ids),
                                             arxivID: item.ids.arxivID, excluding: nil).contains(e.pk)
        }
        guard identity else {
            guard let id = try await mergeMailItem(itemID: item.id, options: quiet) else {
                return MailDupOutcome(paperID: nil, message: MailDupText.failed(lang))
            }
            if id == e.id { return MailDupOutcome(paperID: id, message: MailDupText.sameAfterAll(e.title, lang)) }
            guard let n = try await db.paper(id: id) else { throw DupResolutionError.failed("") }
            let review = try await reviewForMail(new: n, existing: e)
            let done = try await resolveDuplicate(reviewID: review.id, .keepNew(reread: false))
            return MailDupOutcome(paperID: done.keptPaperID ?? e.id, reviewID: review.id, undoToken: done.undoToken,
                                  message: done.message)
        }
        var row = item
        if row.pdfState != .hasPDF {
            try await downloadMailItem(itemID: row.id)
            guard let after = try await db.mailItem(id: row.id) else { throw DupResolutionError.reviewClosed(row.id) }
            row = after
        }
        if row.pdfState == .inLibrary, let id = row.paperID {
            try await linkMailItem(itemID: row.id, paperID: id)
            return MailDupOutcome(paperID: id, message: MailDupText.sameAfterAll(e.title, lang))
        }
        guard row.pdfState == .hasPDF, let rel = row.pdfPath, let url = MailAttachmentFiles.url(rel, root: paths.mailFiles) else {
            return MailDupOutcome(paperID: nil, message: MailDupText.failed(lang))
        }
        let summary = await intake.ingest([.file(url)], options: ImportOptions(origin: .mail, ai: .skip))
        guard let outcome = summary.items.first?.outcome else { return MailDupOutcome(paperID: nil, message: MailDupText.failed(lang)) }
        switch outcome {
        case .duplicate(let id):
            try await linkMailItem(itemID: row.id, paperID: id)
            return MailDupOutcome(paperID: id, message: MailDupText.sameAfterAll(e.title, lang))
        case .sameWork:
            let parked = (try await db.openDupReviews(batchID: summary.batchID)).first { $0.isParked }
            guard let review = parked else { throw DupResolutionError.failed("") }
            guard review.existingPaperPK == e.pk else {
                // The PDF names another paper than the one shown: nothing is replaced.
                _ = try? await resolveDuplicate(reviewID: review.id, .skip)
                throw DupResolutionError.choiceUnavailable(MailDupChoice.useThisVersion.rawValue)
            }
            let done = try await resolveDuplicate(reviewID: review.id, .keepNew(reread: false))
            try await linkMailItem(itemID: row.id, paperID: e.id)
            return MailDupOutcome(paperID: e.id, reviewID: review.id, undoToken: done.undoToken, message: done.message)
        case .added(let id):
            guard let n = try await db.paper(id: id) else { throw DupResolutionError.failed("") }
            let review = try await reviewForMail(new: n, existing: e)
            let done = try await resolveDuplicate(reviewID: review.id, .keepNew(reread: false))
            try await linkMailItem(itemID: row.id, paperID: e.id)
            return MailDupOutcome(paperID: e.id, reviewID: review.id, undoToken: done.undoToken, message: done.message)
        case .rejected, .failed:
            return MailDupOutcome(paperID: nil, message: MailDupText.failed(lang))
        }
    }

    /// The open review of `n` against `e` — the intake's, or one written now (the user picked the pair).
    private func reviewForMail(new n: Paper, existing e: Paper) async throws -> DupReview {
        if let r = try await db.openDupReview(newPaperPK: n.pk), r.existingPaperPK == e.pk { return r }
        if let other = try await db.openDupReview(newPaperPK: n.pk) {
            // The intake matched another paper: that question is replaced by the user's pick.
            var closed = other
            closed.state = .dismissed
            closed.resolvedAt = ctx.now()
            try await db.updateDupReview(closed)
            ctx.events.send(.dedupe(.reviewClosed(reviewID: other.id)))
        }
        let settings = await ctx.settings()
        let ns = await DedupeIndex.subject(for: n, ctx: ctx)
        let es = await DedupeIndex.subject(for: e, ctx: ctx)
        let c = DupDetector.compare(ns, es, sensitivity: settings.dedupe.sensitivity)
        let review = DupReview(newPaperID: n.id, existingPaperID: e.id, band: c?.band ?? .possible, score: c?.score ?? 0,
                               createdAt: ctx.now(), newPaperPK: n.pk, existingPaperPK: e.pk,
                               relation: c?.relation ?? .sameWork, evidence: c?.evidence ?? [],
                               newerSide: c?.newerSide, origin: .mail)
        try await db.insertDupReview(review)
        return review
    }

    /// An undo record for steps outside `resolveDuplicate` (the email answers).
    private func ledger(_ steps: [DupUndoStep]) async -> String {
        let token = UUID().uuidString.lowercased()
        let now = ctx.now()
        await dupUndoLedger.put(token, DupUndoLedger.Entry(owner: ObjectIdentifier(self),
                                                           expiresAt: now.addingTimeInterval(UndoToken.lifetime),
                                                           steps: steps), now: now)
        return token
    }
}

/// Whether two papers the user keeps apart are "related" rather than unrelated: a correction,
/// a comment or a supplement of the other (by title).
enum DupRelationGuess {
    static func related(_ n: Paper, _ e: Paper) -> Bool {
        let kinds: Set<DupKind> = [.notice, .comment, .supplement]
        return kinds.contains(DedupeText.kind(title: n.title, fileName: n.originalName))
            || kinds.contains(DedupeText.kind(title: e.title, fileName: e.originalName))
    }
}

/// Why [Ask AI] can't run for a review.
package enum DupJudgeBlock: String, Sendable, Equatable, CaseIterable {
    /// Settings ▸ Library ▸ Duplicates ▸ "Ask AI to judge" is off (the default).
    case switchedOff
    /// The duplicate check is off.
    case dedupeOff
    /// Explain & Ask is off (`assist.mode`): no interactive AI at all.
    case assistOff
    /// Answered, dismissed or expired (or gone).
    case reviewClosed
    /// An identifier or the same bytes matched: nothing to weigh.
    case certain
    /// What matched is a removed paper's tombstone.
    case removedPaper
    /// The new paper is confidential, never-AI, possibly unpublished or from a person's email without an id.
    case privateNew
    /// The library paper is.
    case privateExisting
    /// `dedupe.ai.dailyCap` judge turns today already.
    case dailyCap
    /// Another judge turn is running.
    case busy
}

/// [Ask AI]'s state for one review (the sheet shows the button, or why not, and "3 / 10 today").
package struct DupJudgeStatus: Sendable, Equatable {
    package var block: DupJudgeBlock?
    package var usedToday: Int
    package var dailyCap: Int

    package init(block: DupJudgeBlock?, usedToday: Int, dailyCap: Int) {
        self.block = block; self.usedToday = usedToday; self.dailyCap = dailyCap
    }

    package var available: Bool { block == nil }
}

package enum DupJudgeError: Error, Equatable, Sendable {
    case blocked(DupJudgeBlock)
    /// `AssistGate` refused the turn (consent, pause, burst, the assist caps, the budget).
    case refused(AssistGate.Verdict)
    case failed(AssistFailure)
    /// The answer held no usable judgement of the review's match.
    case unreadable
}

/// One judge turn at a time per engine (the cap check and the count belong together).
final class DupJudgeInFlight: @unchecked Sendable {
    static let shared = DupJudgeInFlight()
    private let lock = NSLock()
    private var running: Set<ObjectIdentifier> = []

    func begin(_ engine: ObjectIdentifier) -> Bool { lock.withLock { running.insert(engine).inserted } }
    func end(_ engine: ObjectIdentifier) { _ = lock.withLock { running.remove(engine) } }
}

// MARK: - Choices

/// Which choices a review offers and which is preselected (DQ §4.1, dive-dedupe §6.2). Pure.
/// The default never throws the library's version away: a newer new file → keep it; the same
/// version of a finished paper → re-read it; otherwise skip the new copy.
package enum DupChoiceRules {
    package static func choices(_ r: DupReview, newIDs: PaperIDs, existing e: Paper?,
                                history h: DupHistoryRow?) -> (choices: [DupChoiceKind], default: DupChoiceKind) {
        let parked = r.newPaperPK == nil
        if e == nil {
            // A removed paper's tombstone (or nothing left to compare with).
            return h != nil ? ([.addAgain, .skip], .addAgain) : ([.keepBoth, .skip], .keepBoth)
        }
        guard let e else { return ([.skip], .skip) }
        switch r.relation {
        case .supplement, .correction, .comment:
            // A supplement is filed with its paper; a correction or a comment is a paper of its own,
            // linked as related (it can still be filed with the paper).
            if parked && e.isLive && r.band == .certain {
                return r.relation == .supplement ? ([.attachSupplement, .keepBoth, .skip], .attachSupplement)
                    : ([.keepBoth, .attachSupplement, .skip], .keepBoth)
            }
            return r.relation == .supplement ? ([.skip, .keepBoth], .skip) : ([.keepBoth, .skip], .keepBoth)
        default:
            break
        }
        // "Re-read" only means something for a paper that was finished (or removed): one still
        // being read stays as it is under "skip".
        var list: [DupChoiceKind] = [.keepNew]
        if e.status == .done || e.isDeleted { list.append(.rereadEarlier) }
        // Two live papers can't hold one DOI / arXiv id: "keep both" needs different ids.
        let sameDOI = newIDs.doi.map { d in e.ids.doi?.lowercased() == d.lowercased() } ?? false
        let sameArxiv = newIDs.arxivID.map { a in e.ids.arxivID?.lowercased() == a.lowercased() } ?? false
        if !parked || e.isDeleted || !(sameDOI || sameArxiv) { list.append(.keepBoth) }
        list.append(.skip)
        let preferred: DupChoiceKind
        // The user asked the AI judge and it was sure these are two works: keep both is suggested
        // (still only preselected — nothing happens before [Apply]).
        if r.aiVerdict?.saysDistinct == true, list.contains(.keepBoth) { preferred = .keepBoth }
        else if r.newerSide == .new { preferred = .keepNew }
        else if e.isDeleted { preferred = .rereadEarlier }
        else if e.status == .done && r.relation.isSameWork { preferred = .rereadEarlier }
        else if r.band == .possible && !parked { preferred = .keepBoth }
        else { preferred = .skip }
        let ordered = [preferred] + list.filter { $0 != preferred }
        return (ordered.filter(list.contains), preferred)
    }
}

// MARK: - Toast / result text

enum DupText {
    static func keptNew(_ title: String, _ l: UILang) -> String {
        l == .zh ? "已换成新文件：\(short(title))" : "Kept the new file: \(short(title))"
    }
    static func addedAsNew(_ title: String, _ l: UILang) -> String {
        l == .zh ? "已作为新论文添加：\(short(title))" : "Added as a new paper: \(short(title))"
    }
    static func rereading(_ title: String, _ l: UILang) -> String {
        l == .zh ? "已移回待读：\(short(title))" : "Back to To Read: \(short(title))"
    }
    static func keptBoth(_ l: UILang) -> String { l == .zh ? "两篇都保留，以后不再提醒" : "Kept both — won't ask again" }
    static func skipped(_ l: UILang) -> String { l == .zh ? "已跳过新文件" : "Skipped the new file" }
    static func attached(_ title: String, _ l: UILang) -> String {
        l == .zh ? "已作为补充材料存入：\(short(title))" : "Saved as a supplement of: \(short(title))"
    }
    static func addedAgain(_ title: String, _ l: UILang) -> String {
        l == .zh ? "已重新加入：\(short(title))" : "Added again: \(short(title))"
    }
    static func mergedNotesHeader(_ title: String, lang l: UILang) -> String {
        l == .zh ? "— 合并自「\(short(title))」—" : "— merged from “\(short(title))” —"
    }
    private static func short(_ s: String) -> String { s.count > 60 ? String(s.prefix(59)) + "…" : s }
}

// MARK: - Snapshots and the undo ledger

/// A paper's state a resolution may change, for its undo (in memory for `UndoToken.lifetime`).
package struct DupPaperSnapshot: Sendable {
    package var paper: Paper
    package var checklist: [ChecklistItem]
    package var tags: [Tag]
    package var keys: [DupKey]
    package var cycles: [ReadingCycle]
    package var sources: [PaperProvenance]
    package var policy: PaperPolicy?

    static func take(_ pk: Int64, db: Database, ctx: EngineContext) async throws -> DupPaperSnapshot {
        try await db.transaction { db in
            guard let p = try db.paper(pk: pk) else { throw DatabaseError.notFound("paper \(pk)") }
            return DupPaperSnapshot(paper: p, checklist: try db.checklist(paperPK: pk), tags: try db.tags(paperPK: pk),
                                    keys: try db.dupKeys(paperPK: pk), cycles: try db.readingCycles(paperPK: pk),
                                    sources: try db.paperSources(paperPK: pk), policy: try db.paperPolicy(paperPK: pk))
        }
    }

    /// Writes the snapshot's content back onto the (live or deleted) row — not its folder,
    /// deletion state or pipeline stage, which their own steps restore.
    func restore(db: Database, ctx: EngineContext, now: Date, text: String?, thumbnail: Data?) async throws {
        let s = self
        try await db.transaction { db in
            guard try db.paper(pk: s.paper.pk) != nil else { return }
            try db.modifyPaper(pk: s.paper.pk, now: now) { p in
                let o = s.paper
                p.sha256 = o.sha256; p.fileSize = o.fileSize; p.ids = o.ids; p.title = o.title; p.titleRank = o.titleRank
                p.authors = o.authors; p.year = o.year; p.venue = o.venue; p.abstract = o.abstract
                p.metaSource = o.metaSource; p.pageCount = o.pageCount; p.charCount = o.charCount
                p.flags = o.flags.subtracting(.missing).union(p.flags.intersection(.missing))
                p.originalName = o.originalName; p.status = o.status; p.doneAt = o.doneAt; p.openedAt = o.openedAt
                p.deadline = o.deadline; p.scheduleMode = o.scheduleMode; p.deadlineOrigin = o.deadlineOrigin
                p.placementFloor = o.placementFloor; p.provisional = o.provisional; p.priority = o.priority; p.notes = o.notes
            }
            try db.replaceChecklist(paperPK: s.paper.pk, items: s.checklist)
            try db.setTags(paperPK: s.paper.pk, s.tags)
            for source in DupKey.Source.allCases where source != .local {
                try db.deleteDupKeys(paperPK: s.paper.pk, source: source)
            }
            try db.addDupKeys(paperPK: s.paper.pk, s.keys.filter { $0.source != .local })
            try db.refreshLocalDupKeys(paperPK: s.paper.pk)
            for c in try db.readingCycles(paperPK: s.paper.pk) where !s.cycles.contains(where: { $0.n == c.n }) {
                try db.deleteReadingCycle(paperPK: s.paper.pk, n: c.n)
            }
            for c in s.cycles { try db.insertReadingCycle(paperPK: s.paper.pk, c) }
            try db.replacePaperSources(paperPK: s.paper.pk, s.sources)
            if let text { try db.indexFullText(pk: s.paper.pk, text: text) }
            try db.deleteDupFingerprint(paperPK: s.paper.pk)
        }
        if text != nil || thumbnail != nil {
            let texts = ctx.texts, thumbs = ctx.thumbs, id = paper.id
            await BlockingIO.run {
                if let text { try? texts.save(text, id: id) }
                if let thumbnail { try? thumbs.save(cardJPEG: thumbnail, id: id) }
            }
        }
        await ctx.syncSidecar(pk: paper.pk)
    }

    /// Inserts the snapshot as a paper again (a merge undone): same id, a new pk. Returns the pk.
    func recreate(db: Database, ctx: EngineContext) async throws -> Int64 {
        let s = self
        let texts = ctx.texts, id = paper.id
        let text = await BlockingIO.run { (try? texts.load(id: id)) ?? nil }
        return try await db.transaction { db -> Int64 in
            let saved = try db.insertPaper(s.paper, checklist: s.checklist)
            try db.setTags(paperPK: saved.pk, s.tags)
            try db.addDupKeys(paperPK: saved.pk, s.keys)
            for c in s.cycles { try db.insertReadingCycle(paperPK: saved.pk, c) }
            for p in s.sources { try db.insertPaperSource(paperPK: saved.pk, p) }
            if let policy = s.policy { try db.setPaperPolicy(paperPK: saved.pk, policy) }
            if let text { try db.indexFullText(pk: saved.pk, text: text) }
            return saved.pk
        }
    }
}

/// One compensating action of a resolution's undo, applied in reverse order.
package enum DupUndoStep: Sendable {
    case reopenReview(DupReview)
    case restorePaper(DupPaperSnapshot, text: String?, thumbnail: Data?)
    /// `heldJob`: the paper had a waiting reading job (it is re-created held).
    case recreatePaper(DupPaperSnapshot, parkedFolder: URL?, mailItems: [String], keptPaperID: String, heldJob: Bool)
    /// The kept paper's PDF goes to `newFileTo` (the removed paper's parked folder), `backup` back in place.
    case swapBack(paperPK: Int64, backup: URL?, newFileTo: URL?)
    case softDeleteAgain(paperID: String)
    case unSoftDelete(paperID: String)
    case removePair(Int64, Int64)
    case removeCycle(paperPK: Int64, n: Int)
    case reholdAI(paperPK: Int64)
    /// A merge's privacy marks on the kept paper: its policy back to `policy` (when it is still
    /// `merged`), the copy's carried hold note back to `aiNote`, a reading it held released.
    case restorePrivacy(paperPK: Int64, policy: PaperPolicy?, merged: PaperPolicy?, aiNote: String?, noteCarried: Bool,
                        reheld: Bool)
    case intakeRestoreDiscarded(pendingID: String)
    case intakeUndoReplace(id: String)
    case intakeUndoAttach(paperID: String, relativePath: String)
}

/// Resolutions' undo records: in memory, per engine, `UndoToken.lifetime` (the `SkipUndoLedger` pattern).
actor DupUndoLedger {
    struct Entry: Sendable {
        var owner: ObjectIdentifier
        var expiresAt: Date
        var steps: [DupUndoStep]
    }

    private static let maxEntries = 32
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    func put(_ token: String, _ entry: Entry, now: Date) {
        prune(now: now)
        entries[token] = entry
        order.append(token)
        while order.count > Self.maxEntries { entries[order.removeFirst()] = nil }
    }

    func take(_ token: String, owner: ObjectIdentifier, now: Date) -> Entry? {
        prune(now: now)
        guard let entry = entries[token], entry.owner == owner else { return nil }
        entries[token] = nil
        order.removeAll { $0 == token }
        return entry
    }

    private func prune(now: Date) {
        let expired = entries.filter { $0.value.expiresAt < now }.map(\.key)
        guard !expired.isEmpty else { return }
        for key in expired { entries[key] = nil }
        order.removeAll { expired.contains($0) }
    }
}

private let dupUndoLedger = DupUndoLedger()

private extension Optional {
    func asyncMap<U>(_ f: (Wrapped) async throws -> U) async rethrows -> U? {
        guard let w = self else { return nil }
        return try await f(w)
    }
}
