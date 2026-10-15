import Foundation

// Batch operations on a multi-selection (DQ §5.4; READING_ASSIST_PLAN §4, §6.4 C1). Owned by
// Slice C.
//
// - Every field operation runs in ONE transaction (one ChangeHub burst); the DDL operations in one
//   `ctx.schedule` pass (read, place one after another, write — serializable with every other
//   schedule write); Move to Recently Deleted moves the folders inside that one transaction and
//   moves them back if it fails.
// - One undo token (30 s) whose ledger keeps each changed paper's previous values; undo restores a
//   paper only while it still has the batch's values, so a change the user made since wins (the
//   rule of 今天跳过, OperationsSchedule.swift).
// - A committed batch is announced as `EngineEvent.batchApplied`; the App words its toast.

extension Engine {
    /// Applies `op` to the papers (`paperIDs` in the order the user sees them). Unknown and deleted
    /// papers are skipped (for `.restore`: live ones and restore conflicts), so are papers marked
    /// done for the DDL operations. Throws (nothing changed) for an invalid tag or an unknown category.
    package func applyBatch(_ op: BatchOperation, paperIDs: [String]) async throws -> BatchOutcome {
        let ids = BatchSupport.unique(paperIDs)
        let run: BatchRun
        switch op {
        case .moveToTrash: run = try await batchMoveToTrash(ids)
        case .restore: run = try await batchRestore(ids)
        case .pinDeadline, .postponeDay, .postponeWeek, .unschedule, .restoreAuto:
            run = try await batchSchedule(op, ids)
        case .setStatus, .setPriority, .setCategory, .addTags, .removeTags:
            run = try await batchFields(op, ids)
        }
        for pk in run.changes.map(\.pk) { await ctx.syncSidecar(pk: pk) }
        var token: String?
        if !run.changes.isEmpty, op != .restore {
            let id = UUID().uuidString.lowercased()
            let now = ctx.now()
            await batchUndoLedger.put(id, BatchUndoLedger.Entry(owner: ObjectIdentifier(self), operation: op,
                                                               expiresAt: now.addingTimeInterval(UndoToken.lifetime),
                                                               changes: run.changes), now: now)
            token = id
        }
        let outcome = BatchOutcome(applied: run.applied, skipped: run.skipped, undoToken: token)
        if !outcome.applied.isEmpty {
            ctx.events.send(.batchApplied(BatchNotice(operation: op.code, paperIDs: outcome.applied, undoToken: token)))
        }
        return outcome
    }

    /// Reverts a batch within its 30 s window: every paper that still has the batch's values gets
    /// its previous ones back, in one transaction. Papers moved to Recently Deleted are restored one
    /// by one (one that can't be — the same DOI is live again — stays there). False when the token
    /// is unknown, already used or expired. (The toast's [Undo] reaches this through
    /// `Engine.undo(token:)`.)
    @discardableResult
    package func undoBatch(token: String) async throws -> Bool {
        guard let entry = await batchUndoLedger.take(token, owner: ObjectIdentifier(self), now: ctx.now()) else { return false }
        if entry.operation == .moveToTrash {
            for change in entry.changes {
                guard let p = try await db.paper(pk: change.pk), p.isDeleted, p.deletedAt == change.after.deletedAt else { continue }
                do { _ = try await restore(paperID: p.id) } catch {
                    Log.storage.info("batch undo: \(p.id, privacy: .public) stays in Recently Deleted (\(String(describing: error), privacy: .public))")
                }
            }
            return true
        }
        let now = ctx.now()
        let changes = entry.changes
        let operation = entry.operation
        let restored = try await db.transaction { db -> [Int64] in
            var touched: [Int64] = []
            for change in changes {
                guard let p = try db.paper(pk: change.pk), p.isLive else { continue }
                switch operation {
                case .addTags, .removeTags:
                    let current = try db.tags(paperPK: change.pk)
                    guard BatchSupport.sameTags(current, change.after.tags) else { continue }
                    try db.setTags(paperPK: change.pk, change.before.tags ?? [])
                default:
                    guard BatchSupport.unchanged(p, since: change.after, for: operation) else { continue }
                    try db.modifyPaper(pk: change.pk, now: now) { row in
                        BatchSupport.restore(&row, from: change.before, for: operation)
                    }
                }
                touched.append(change.pk)
            }
            return touched
        }
        for pk in restored { await ctx.syncSidecar(pk: pk) }
        return true
    }

    /// Re-read with AI for several papers (after the App's confirmation sheet): an ordinary card
    /// job for each live paper, at normal priority (behind single re-reads) and not held, so the
    /// queue runs them one by one on the chosen provider. Nothing is queued while `agent.mode` is
    /// off (every paper is reported skipped). No undo; the jobs can be cancelled per paper.
    ///
    /// A paper that waits for the user's own confirmation is never sent by a batch (`RereadHold`:
    /// marked "Never use AI" or "Unpublished / confidential", held as possibly unpublished, from a
    /// confidential email or a person's email without a DOI / arXiv id — whatever Explain and Ask
    /// would confirm first —, under an open duplicate review): it keeps its held job and note and
    /// is reported in `held` — the user opens it and confirms there.
    package func requestReread(paperIDs: [String]) async throws -> BatchOutcome {
        let ids = BatchSupport.unique(paperIDs)
        guard ctx.loadSettings().agentMode != .off else { return BatchOutcome(skipped: ids) }
        var applied: [String] = [], skipped: [String] = []
        var live: [Paper] = []
        for id in ids {
            guard let p = try await db.paper(id: id), p.isLive else { skipped.append(id); continue }
            live.append(p)
        }
        let holds = try await rereadHolds(live)
        var held: [RereadHeld] = []
        for p in live {
            if let reason = holds[p.pk] {
                held.append(RereadHeld(paperID: p.id, reason: reason))
                continue
            }
            await agents.enqueue(paperPK: p.pk, hold: false, priority: 0)
            applied.append(p.id)
        }
        if !applied.isEmpty {
            ctx.events.send(.batchApplied(BatchNotice(operation: BatchOperation.rereadCode, paperIDs: applied)))
        }
        return BatchOutcome(applied: applied, skipped: skipped, held: held)
    }

    /// The papers of `paperIDs` batch "Read with AI" would leave out, and why (the confirmation
    /// sheet lists them before anything is queued). Read-only; unknown and deleted papers are
    /// not listed.
    package func rereadHolds(paperIDs: [String]) async throws -> [RereadHeld] {
        var live: [Paper] = []
        for id in BatchSupport.unique(paperIDs) {
            if let p = try await db.paper(id: id), p.isLive { live.append(p) }
        }
        let holds = try await rereadHolds(live)
        return live.compactMap { p in holds[p.pk].map { RereadHeld(paperID: p.id, reason: $0) } }
    }

    /// "Read All Now (N)" in the AI queue: every held reading starts (those held while
    /// `agent.mode` was off too) — except the ones a batch must never send (`rereadHolds`:
    /// never-AI, possibly unpublished, confidential, from a confidential email or a person's email
    /// without a DOI / arXiv id, held by a duplicate review), which keep their
    /// held job and note for the user's own confirmation in the paper. When the holds can't be
    /// read, nothing is released. Returns how many started and which stayed held, and why.
    @discardableResult
    package func releaseHeldReadings() async -> HeldRelease {
        let held = (try? await db.jobs(states: [.held])) ?? []
        var papers: [Paper] = []
        for job in held {
            if let p = try? await db.paper(pk: job.paperPK), p.isLive, !papers.contains(where: { $0.pk == p.pk }) {
                papers.append(p)
            }
        }
        guard !papers.isEmpty else { return HeldRelease() }
        guard let holds = await batchHolds(papers) else { return HeldRelease() }
        let release = papers.filter { holds[$0.pk] == nil }.map(\.pk)
        if !release.isEmpty { await agents.releaseHeld(paperPKs: release) }
        return HeldRelease(released: release.count,
                           held: papers.compactMap { p in holds[p.pk].map { RereadHeld(paperID: p.id, reason: $0) } })
    }

    /// "Queue Existing Papers" (AI queue, Settings ▸ AI): `releaseHeldReadings`, then a reading for
    /// each of `paperPKs` (papers never read: live, no card, no job) under the same rule — a paper
    /// a batch must never send is left as it is and reported.
    @discardableResult
    package func queueExistingPapers(_ paperPKs: [Int64]) async -> HeldRelease {
        var out = await releaseHeldReadings()
        var papers: [Paper] = []
        for pk in BatchSupport.uniquePKs(paperPKs) {
            if let p = try? await db.paper(pk: pk), p.isLive, p.card == nil, p.aiState == .none { papers.append(p) }
        }
        guard !papers.isEmpty, let holds = await batchHolds(papers) else { return out }
        for p in papers {
            if let reason = holds[p.pk] {
                out.held.append(RereadHeld(paperID: p.id, reason: reason))
                continue
            }
            await agents.enqueue(paperPK: p.pk, hold: false)
            out.released += 1
        }
        return out
    }

    /// `rereadHolds`, or nil (and logged) when they can't be read: then nothing may be sent.
    private func batchHolds(_ papers: [Paper]) async -> [Int64: RereadHold]? {
        do { return try await rereadHolds(papers) } catch {
            Log.agent.error("batch reading holds unreadable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Why each of `papers` must not be read by a batch (missing: it may be). The strongest reason
    /// wins (`RereadHold`'s order).
    private func rereadHolds(_ papers: [Paper]) async throws -> [Int64: RereadHold] {
        guard !papers.isEmpty else { return [:] }
        let policies = try await db.paperPolicies(paperPKs: papers.map(\.pk))
        var out: [Int64: RereadHold] = [:]
        for p in papers {
            let policy = policies[p.pk]
            if policy?.neverAI == true {
                out[p.pk] = .neverAI
            } else if p.aiNote == ImportAnnotation.unpublishedHoldNote {
                out[p.pk] = .possiblyUnpublished
            } else if policy?.confidential == true {
                out[p.pk] = .confidential
            } else if let hold = try await provenanceHold(p) {
                out[p.pk] = hold
            } else if let review = try await db.openDupReview(newPaperPK: p.pk), review.hold != .none {
                // Only a review that actually holds the paper (intake); a library-check review holds nothing.
                out[p.pk] = .duplicateReview
            }
        }
        return out
    }

    /// What Explain and Ask would confirm first about where the paper came from (`AssistPrivacy`
    /// inside PaperDeck: a confidential email, a person's email without a DOI / arXiv id — with the
    /// hold note gone too), as a batch hold; nil when they would send without asking.
    private func provenanceHold(_ p: Paper) async throws -> RereadHold? {
        switch try await assistPrivacy(paperID: p.id, hostBundleID: nil) {
        case .ok: return nil
        case .blocked: return .neverAI
        case .confirm(let reasons):
            if reasons.contains(.mailConfidential) { return .confidentialEmail }
            if reasons.contains(.markedConfidential) { return .confidential }
            return .possiblyUnpublished                 // personSourcedNoID, mailUnpublished
        }
    }

    // MARK: Field operations (one transaction)

    private func batchFields(_ op: BatchOperation, _ ids: [String]) async throws -> BatchRun {
        let tags: [String]
        switch op {
        case .addTags(let names), .removeTags(let names):
            tags = try BatchSupport.normalizedTags(names, strict: { if case .addTags = op { return true }; return false }())
        default:
            tags = []
        }
        let now = ctx.now()
        return try await db.transaction { db -> BatchRun in
            if case .setCategory(let pk?) = op, try db.category(pk: pk) == nil {
                throw PaperOperationError.categoryNotFound(pk)
            }
            var run = BatchRun()
            for id in ids {
                guard let p = try db.paper(id: id), p.isLive else { run.skipped.append(id); continue }
                run.applied.append(p.id)
                switch op {
                case .addTags, .removeTags:
                    let current = try db.tags(paperPK: p.pk)
                    let next = BatchSupport.tags(current, applying: op, names: tags)
                    guard !BatchSupport.sameTags(current, next) else { continue }
                    try db.setTags(paperPK: p.pk, next)
                    let stored = try db.tags(paperPK: p.pk)
                    run.changes.append(BatchChange(pk: p.pk, before: BatchFields(p, tags: current),
                                                   after: BatchFields(p, tags: stored)))
                default:
                    var row = p
                    BatchSupport.apply(op, to: &row, now: now)
                    guard row != p else { continue }
                    let saved = try db.updatePaper(row, now: now)
                    run.changes.append(BatchChange(pk: p.pk, before: BatchFields(p), after: BatchFields(saved)))
                }
            }
            return run
        }
    }

    // MARK: DDL operations (one schedule pass)

    private func batchSchedule(_ op: BatchOperation, _ ids: [String]) async throws -> BatchRun {
        let planned = try await ctx.schedule { inputs -> EngineContext.SchedulePlan<BatchRun> in
            var items = inputs.items
            let index = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            let papers = Dictionary(inputs.papers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var run = BatchRun()
            var changed: [SchedItem] = []
            for id in ids {
                guard let i = index[id], let paper = papers[id] else { run.skipped.append(id); continue }
                let item = items[i]
                guard item.status != .done else { run.skipped.append(id); continue }
                run.applied.append(id)
                let s = inputs.scheduler
                let updated: SchedItem
                switch op {
                case .pinDeadline(let day): updated = s.pin(item, to: day)
                case .postponeDay: updated = s.postponeDay(item)
                case .postponeWeek: updated = s.postponeWeek(item)
                case .unschedule: updated = s.unschedule(item)
                case .restoreAuto: updated = s.restoreAuto(item, among: items)
                default: updated = item
                }
                guard updated != item else { continue }
                items[i] = updated
                changed.append(updated)
                var after = paper
                after.deadline = updated.deadline
                after.scheduleMode = updated.scheduleMode
                after.deadlineOrigin = updated.deadlineOrigin
                after.placementFloor = updated.placementFloor
                after.provisional = updated.provisional
                run.changes.append(BatchChange(pk: paper.pk, before: BatchFields(paper), after: BatchFields(after)))
            }
            return EngineContext.SchedulePlan(changed: changed, result: run)
        }
        return planned
    }

    // MARK: Move to Recently Deleted (one transaction, folders moved back on failure)

    private func batchMoveToTrash(_ ids: [String]) async throws -> BatchRun {
        var live: [Paper] = []
        var skipped: [String] = []
        for id in ids {
            if let p = try await db.paper(id: id), p.isLive { live.append(p) } else { skipped.append(id) }
        }
        // As `softDelete`: the reading each paper waited for comes back with Undo / Restore
        // (`TrashedJob`), and the "possibly unpublished" mark outlives the cancelled job.
        var waiting: [Int64: TrashedJob] = [:]
        var unpublished = Set<Int64>()
        for p in live {
            if let job = try await db.activeJob(paperPK: p.pk) { waiting[p.pk] = TrashedJob(job, note: p.aiNote) }
            if p.aiNote == ImportAnnotation.unpublishedHoldNote { unpublished.insert(p.pk) }
            await agents.cancel(paperPK: p.pk)
        }
        let library = paths.library, bin = paths.recentlyDeleted, papers = paths.papers, inbox = paths.inbox
        let now = ctx.now()
        let pks = live.map(\.pk)
        let waitingJobs = waiting, unpublishedPKs = unpublished
        var run = try await db.transaction { db -> BatchRun in
            var run = BatchRun()
            var moves: [(from: URL, to: URL)] = []
            do {
                try? FileOps.createFolder(bin)
                for pk in pks {
                    guard var p = try db.paper(pk: pk), p.isLive else {
                        continue                                  // deleted meanwhile
                    }
                    if unpublishedPKs.contains(pk) { p.aiNote = ImportAnnotation.unpublishedHoldNote }
                    try db.setTrashedJob(waitingJobs[pk], paperID: p.id)
                    let before = p
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
                    if moved { moves.append((src, dst)) }
                    p.folder = OpsFiles.relative(dst, library: library)
                    p.deletedAt = now
                    if moved && PaperOpsSupport.itemExists(dst.appendingPathComponent(p.pdfName)) {
                        p.flags.remove(.missing)
                    } else {
                        p.flags.insert(.missing)
                    }
                    let saved = try db.updatePaper(p, now: now)
                    run.applied.append(saved.id)
                    run.changes.append(BatchChange(pk: pk, before: BatchFields(before), after: BatchFields(saved)))
                }
            } catch {
                for move in moves.reversed() { try? FileOps.moveFolder(from: move.to, to: move.from) }
                throw error
            }
            return run
        }
        let reached = Set(run.applied)
        run.skipped = skipped + live.map(\.id).filter { !reached.contains($0) }
        return run
    }

    // MARK: Restore from Recently Deleted (each paper on its own)

    /// A paper that can't be restored (the same DOI is live again, a file error) stays deleted and
    /// is reported skipped; when none could be, the first error is thrown.
    private func batchRestore(_ ids: [String]) async throws -> BatchRun {
        var run = BatchRun()
        var firstError: Error?
        for id in ids {
            guard let p = try await db.paper(id: id), p.isDeleted else { run.skipped.append(id); continue }
            do {
                let saved = try await restore(paperID: p.id)
                run.applied.append(saved.id)
                run.changes.append(BatchChange(pk: saved.pk, before: BatchFields(p), after: BatchFields(saved)))
            } catch {
                run.skipped.append(p.id)
                if firstError == nil { firstError = error }
            }
        }
        if run.applied.isEmpty, let firstError { throw firstError }
        return run
    }
}

// MARK: - Support

/// What `Engine.releaseHeldReadings` did: readings started, and readings left held because they
/// wait for the user's own confirmation.
package struct HeldRelease: Sendable, Equatable {
    /// Readings started (held ones released, never-read papers queued).
    package var released = 0
    /// The papers left out, and why (`L.Select.rereadHeld` words them).
    package var held: [RereadHeld] = []

    package init(released: Int = 0, held: [RereadHeld] = []) { self.released = released; self.held = held }
}

/// What one batch did, before the undo token is made.
struct BatchRun: Sendable {
    var applied: [String] = []
    var skipped: [String] = []
    var changes: [BatchChange] = []
}

/// The fields a batch operation may change, as they were before / after it.
struct BatchFields: Sendable, Equatable {
    var status: PaperStatus
    var doneAt: Date?
    var priority: Priority
    var categoryPK: Int64?
    var categoryUserSet: Bool
    var needsReview: Bool
    var deadline: LocalDate?
    var scheduleMode: ScheduleMode
    var deadlineOrigin: DeadlineOrigin
    var placementFloor: LocalDate?
    var provisional: Bool
    var deletedAt: Date?
    /// Every tag row including suppressed ones (tag operations only).
    var tags: [Tag]?

    init(_ p: Paper, tags: [Tag]? = nil) {
        status = p.status; doneAt = p.doneAt; priority = p.priority
        categoryPK = p.categoryPK; categoryUserSet = p.categoryUserSet; needsReview = p.needsReview
        deadline = p.deadline; scheduleMode = p.scheduleMode; deadlineOrigin = p.deadlineOrigin
        placementFloor = p.placementFloor; provisional = p.provisional; deletedAt = p.deletedAt
        self.tags = tags
    }
}

struct BatchChange: Sendable {
    var pk: Int64
    var before: BatchFields
    var after: BatchFields
}

enum BatchSupport {
    /// Lowercased, first occurrence kept, order kept.
    static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.map { $0.lowercased() }.filter { seen.insert($0).inserted }
    }

    /// First occurrence kept, order kept.
    static func uniquePKs(_ pks: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        return pks.filter { seen.insert($0).inserted }
    }

    /// Tag names as `Engine.addTag` stores them. Adding: an invalid name throws before anything
    /// changes; removing: names are matched like `Engine.removeTag` (no validation needed).
    static func normalizedTags(_ names: [String], strict: Bool) throws -> [String] {
        var out: [String] = []
        for name in names {
            if strict {
                guard let tag = Taxonomy.normalizeTag(name) else { throw PaperOperationError.invalidTag(name) }
                if !out.contains(tag) { out.append(tag) }
            } else {
                let key = PaperOpsSupport.tagKey(name)
                if !key.isEmpty, !out.contains(key) { out.append(key) }
            }
        }
        return out
    }

    /// The tag rows after adding / removing `names` — the rules of `Engine.addTag` / `removeTag`:
    /// adding makes an agent or suppressed tag the user's; removing keeps an agent tag as suppressed
    /// (so a re-read doesn't bring it back) and deletes a user tag.
    static func tags(_ current: [Tag], applying op: BatchOperation, names: [String]) -> [Tag] {
        var tags = current
        for name in names {
            let i = tags.firstIndex { PaperOpsSupport.tagKey($0.name) == name }
            switch op {
            case .addTags:
                if let i { if tags[i].origin != .user { tags[i].origin = .user } } else { tags.append(Tag(name: name, origin: .user)) }
            case .removeTags:
                guard let i else { continue }
                switch tags[i].origin {
                case .agent: tags[i].origin = .suppressed
                case .user: tags.remove(at: i)
                case .suppressed: break
                }
            default:
                break
            }
        }
        return tags
    }

    /// Tag rows compared as a set (the stored order follows tag row ids).
    static func sameTags(_ a: [Tag]?, _ b: [Tag]?) -> Bool {
        Set((a ?? []).map { "\($0.name.lowercased())|\($0.origin.rawValue)" })
            == Set((b ?? []).map { "\($0.name.lowercased())|\($0.origin.rawValue)" })
    }

    /// The single-paper operations' rules (`Engine.setStatus` / `setPriority` / `setCategory`).
    static func apply(_ op: BatchOperation, to p: inout Paper, now: Date) {
        switch op {
        case .setStatus(let status):
            guard p.status != status else { return }
            p.status = status
            p.doneAt = status == .done ? now : nil
        case .setPriority(let priority):
            p.priority = priority
        case .setCategory(let pk):
            guard p.categoryPK != pk || !p.categoryUserSet || p.needsReview else { return }
            p.categoryPK = pk
            p.categoryUserSet = true
            p.needsReview = false
        default:
            break
        }
    }

    /// The paper still has what the batch wrote (else the user changed it since: undo leaves it).
    static func unchanged(_ p: Paper, since after: BatchFields, for op: BatchOperation) -> Bool {
        let now = BatchFields(p)
        switch op {
        case .setStatus: return now.status == after.status && now.doneAt == after.doneAt
        case .setPriority: return now.priority == after.priority
        case .setCategory:
            return now.categoryPK == after.categoryPK && now.categoryUserSet == after.categoryUserSet
                && now.needsReview == after.needsReview
        case .pinDeadline, .postponeDay, .postponeWeek, .unschedule, .restoreAuto:
            return now.deadline == after.deadline && now.scheduleMode == after.scheduleMode
                && now.deadlineOrigin == after.deadlineOrigin
        case .addTags, .removeTags, .moveToTrash, .restore:
            return true                  // tags are compared by the caller; trash by `deletedAt`
        }
    }

    /// Puts the fields `op` changed back.
    static func restore(_ p: inout Paper, from before: BatchFields, for op: BatchOperation) {
        switch op {
        case .setStatus:
            p.status = before.status
            p.doneAt = before.doneAt
        case .setPriority:
            p.priority = before.priority
        case .setCategory:
            p.categoryPK = before.categoryPK
            p.categoryUserSet = before.categoryUserSet
            p.needsReview = before.needsReview
        case .pinDeadline, .postponeDay, .postponeWeek, .unschedule, .restoreAuto:
            p.deadline = before.deadline
            p.scheduleMode = before.scheduleMode
            p.deadlineOrigin = before.deadlineOrigin
            p.placementFloor = before.placementFloor
            p.provisional = before.provisional
        case .addTags, .removeTags, .moveToTrash, .restore:
            break
        }
    }
}

// MARK: - Undo records (in memory, per engine, 30 s — the SkipUndoLedger pattern)

actor BatchUndoLedger {
    struct Entry: Sendable {
        var owner: ObjectIdentifier
        var operation: BatchOperation
        var expiresAt: Date
        var changes: [BatchChange]
    }

    private static let maxEntries = 32
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    func put(_ token: String, _ entry: Entry, now: Date) {
        prune(owner: entry.owner, now: now)
        entries[token] = entry
        order.append(token)
        while order.count > Self.maxEntries { entries[order.removeFirst()] = nil }
    }

    /// Removes and returns a live record of `owner`; nil when missing or expired.
    func take(_ token: String, owner: ObjectIdentifier, now: Date) -> Entry? {
        prune(owner: owner, now: now)
        guard let entry = entries[token], entry.owner == owner else { return nil }
        entries[token] = nil
        order.removeAll { $0 == token }
        return entry
    }

    private func prune(owner: ObjectIdentifier, now: Date) {
        let expired = entries.filter { $0.value.owner == owner && $0.value.expiresAt < now }.map(\.key)
        guard !expired.isEmpty else { return }
        for key in expired { entries[key] = nil }
        order.removeAll { expired.contains($0) }
    }
}

private let batchUndoLedger = BatchUndoLedger()
