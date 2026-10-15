import Foundation

/// Shared dependencies handed to every engine actor (import, enrich, agent queue,
/// operations). A Sendable bag of references — no state of its own.
package struct EngineContext: Sendable {
    package let paths: AppPaths
    package let db: Database
    package let sidecars: SidecarWriter
    package let texts: TextStore
    package let thumbs: ThumbnailStore
    package let events: EventHub<EngineEvent>
    /// Fresh settings snapshot (UserDefaults; skipDays are merged from the DB by `settings()`).
    package let loadSettings: @Sendable () -> EngineSettings
    package let now: @Sendable () -> Date
    /// `Calendar.autoupdatingCurrent` in the app, so a time-zone change (travel) moves "today".
    package let calendar: Calendar
    /// Removals that wait out an undo window (shared by the intake and the duplicate decisions).
    package let undoCleanups = UndoCleanups()

    package init(paths: AppPaths, db: Database, sidecars: SidecarWriter, texts: TextStore, thumbs: ThumbnailStore,
                 events: EventHub<EngineEvent>, loadSettings: @escaping @Sendable () -> EngineSettings,
                 now: @escaping @Sendable () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent) {
        self.paths = paths; self.db = db; self.sidecars = sidecars; self.texts = texts; self.thumbs = thumbs
        self.events = events; self.loadSettings = loadSettings; self.now = now; self.calendar = calendar
    }

    package var changes: ChangeHub { db.changes }

    // MARK: Settings

    static let skipDaysKey = "plan.skipDays"

    /// Settings with the persisted skip days filled into the plan.
    package func settings() async -> EngineSettings {
        var s = loadSettings()
        s.plan.skipDays = await skipDays()
        return s
    }

    package func skipDays() async -> Set<LocalDate> {
        guard let raw = try? await db.kv(Self.skipDaysKey) else { return [] }
        return Self.decodeSkipDays(raw)
    }

    /// Skip days read inside a transaction (serializable with every other write).
    package static func skipDays(in db: isolated Database) -> Set<LocalDate> {
        guard let raw = try? db.kv(skipDaysKey) else { return [] }
        return decodeSkipDays(raw)
    }

    private static func decodeSkipDays(_ raw: String) -> Set<LocalDate> {
        guard let list = try? JSONDecoder().decode([LocalDate].self, from: Data(raw.utf8)) else { return [] }
        return Set(list)
    }

    /// Persists skip days to the DB and mirrors them into .paperdeck-library.json.
    package func setSkipDays(_ days: Set<LocalDate>) async throws {
        let ctx = self
        try await db.transaction { db in try ctx.writeSkipDays(days, in: db) }
        await writeManifest()
    }

    /// The kv half of `setSkipDays`, for callers already inside a transaction (they mirror the
    /// manifest afterwards with `writeManifest()`).
    package func writeSkipDays(_ days: Set<LocalDate>, in db: isolated Database) throws {
        // Keep only the recent past + future; old skip days no longer affect planning.
        let floor = LocalDate.today(now: now(), calendar: calendar).adding(days: -60, calendar: calendar)
        let kept = days.filter { $0 >= floor }.sorted()
        let data = try JSONEncoder().encode(kept)
        try db.setKV(Self.skipDaysKey, String(decoding: data, as: UTF8.self))
    }

    // MARK: Planning inputs

    package struct PlanInputs: Sendable {
        package var papers: [Paper]                       // live papers
        package var checklists: [Int64: [ChecklistItem]]  // by paper pk
        package var items: [SchedItem]                    // one per live paper
        package var settings: EngineSettings
        package var scheduler: Scheduler

        package func item(id: String) -> SchedItem? { items.first { $0.id == id } }
        package func paper(id: String) -> Paper? { papers.first { $0.id == id } }
    }

    /// Everything the pure planners need, loaded consistently (read-only views: Today, snapshots).
    /// Operations that write a schedule use `schedule(_:)`, which reads the same inputs inside
    /// its write transaction.
    package func planInputs() async throws -> PlanInputs {
        let ctx = self
        return try await db.transaction { db in try ctx.planInputs(in: db) }
    }

    /// `planInputs()` inside a transaction.
    package func planInputs(in db: isolated Database) throws -> PlanInputs {
        let papers = try db.livePapers()
        let checklists = try db.checklists(paperPKs: papers.map(\.pk))
        let items = papers.map { Scheduler.item(for: $0, checklist: checklists[$0.pk] ?? []) }
        var s = loadSettings()
        s.plan.skipDays = Self.skipDays(in: db)
        return PlanInputs(papers: papers, checklists: checklists, items: items, settings: s,
                          scheduler: Scheduler(settings: s.plan, now: now(), calendar: calendar))
    }

    /// What one schedule operation wants persisted, computed from in-transaction inputs.
    package struct SchedulePlan<Result: Sendable>: Sendable {
        package var changed: [SchedItem]
        /// New skip-day set; nil = unchanged.
        package var skipDays: Set<LocalDate>?
        package var result: Result

        package init(changed: [SchedItem], skipDays: Set<LocalDate>? = nil, result: Result) {
            self.changed = changed; self.skipDays = skipDays; self.result = result
        }
    }

    /// Serializable read-modify-write for every DDL operation (§6.3 table): the plan inputs are
    /// read, the pure (synchronous, cheap) Scheduler step `compute` runs, and its result is
    /// written — all inside ONE transaction, so no concurrent edit (a pin, a priority change, a
    /// card clearing `provisional`) can land between the read and the write. Only the fields
    /// `compute` actually changed are written. Sidecars / manifest are refreshed afterwards.
    package func schedule<Result: Sendable>(
        _ compute: @Sendable (PlanInputs) throws -> SchedulePlan<Result>
    ) async throws -> Result {
        let ctx = self
        let now = self.now()
        let (result, pks, skipChanged) = try await db.transaction { db -> (Result, [Int64], Bool) in
            let inputs = try ctx.planInputs(in: db)
            let plan = try compute(inputs)
            var skipChanged = false
            if let days = plan.skipDays, days != inputs.settings.plan.skipDays {
                try ctx.writeSkipDays(days, in: db)
                skipChanged = true
            }
            let before = Dictionary(inputs.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let pks = try EngineContext.writeSchedule(plan.changed, expecting: before, db: db, now: now)
            return (plan.result, pks, skipChanged)
        }
        for pk in pks { await syncSidecar(pk: pk) }
        if skipChanged { await writeManifest() }
        return result
    }

    /// Writes scheduler results computed from an earlier (possibly stale) snapshot, compare-and-set:
    /// a paper whose scheduling fields no longer match its `snapshot` item was changed meanwhile
    /// and is left alone; otherwise only the fields that differ from the snapshot are written.
    /// Without a snapshot item only deadline / mode / origin / floor are written — never priority
    /// (no Scheduler step changes it) nor provisional (only CardApplier clears it, in its own
    /// transaction). Prefer `schedule(_:)`, which has no staleness at all.
    package func applySchedule(_ changed: [SchedItem], expecting snapshot: [SchedItem] = []) async throws {
        guard !changed.isEmpty else { return }
        let before = Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let now = self.now()
        let pks = try await db.transaction { db in
            try EngineContext.writeSchedule(changed, expecting: before, db: db, now: now)
        }
        for pk in pks { await syncSidecar(pk: pk) }
    }

    /// The write half of `schedule` / `applySchedule`. Returns the pks of rows that changed.
    static func writeSchedule(_ changed: [SchedItem], expecting before: [String: SchedItem],
                              db: isolated Database, now: Date) throws -> [Int64] {
        var latest: [String: SchedItem] = [:]
        var order: [String] = []
        for s in changed {
            if latest.updateValue(s, forKey: s.id) == nil { order.append(s.id) }
        }
        var pks: [Int64] = []
        for id in order {
            guard let s = latest[id], var p = try db.paper(id: id), p.isLive else { continue }
            let original = p
            if let old = before[id] {
                guard p.deadline == old.deadline, p.scheduleMode == old.scheduleMode,
                      p.deadlineOrigin == old.deadlineOrigin, p.placementFloor == old.placementFloor else {
                    continue                         // changed since the snapshot: that edit wins
                }
                if s.deadline != old.deadline { p.deadline = s.deadline }
                if s.scheduleMode != old.scheduleMode { p.scheduleMode = s.scheduleMode }
                if s.deadlineOrigin != old.deadlineOrigin { p.deadlineOrigin = s.deadlineOrigin }
                if s.placementFloor != old.placementFloor { p.placementFloor = s.placementFloor }
                if s.provisional != old.provisional { p.provisional = s.provisional }
                if s.priority != old.priority { p.priority = s.priority }
            } else {
                p.deadline = s.deadline
                p.scheduleMode = s.scheduleMode
                p.deadlineOrigin = s.deadlineOrigin
                p.placementFloor = s.placementFloor
            }
            guard p != original else { continue }
            _ = try db.updatePaper(p, now: now)
            pks.append(p.pk)
        }
        return pks
    }

    // MARK: Files

    package func folderURL(_ paper: Paper) -> URL {
        LibraryPaths.folderURL(forRelative: paper.folder, library: paths.library)
    }

    package func pdfURL(_ paper: Paper) -> URL {
        folderURL(paper).appendingPathComponent(paper.pdfName)
    }

    // MARK: Sidecars

    /// Rebuilds card.json + notes.md for one paper from the DB (coalesced by SidecarWriter).
    package func syncSidecar(pk: Int64) async {
        do {
            guard let p = try await db.paper(pk: pk) else { return }
            let checklist = try await db.checklist(paperPK: pk)
            let tags = try await db.tags(paperPK: pk)
            let categoryName = try await p.categoryPK.asyncFlatMap { try await db.category(pk: $0)?.name }
            let job = try await db.jobs(states: [.succeeded])
                .filter { $0.paperPK == pk }
                .max { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
            let provenance = try await db.paperSources(paperPK: pk)
            // The reading assist's optional keys (written only when non-empty).
            let policy = try await db.paperPolicy(paperPK: pk)
            let cycles = try await db.readingCycles(paperPK: pk)
            let distinct = try await db.dupPairPartnerIDs(paperPK: pk)
            let sidecar = CardSidecar(paper: p, checklist: checklist, categoryName: categoryName, tags: tags,
                                      aiProvider: p.card == nil ? nil : job?.provider,
                                      aiModel: p.card == nil ? nil : job?.model,
                                      aiGeneratedAt: p.card == nil ? nil : job?.finishedAt,
                                      provenance: provenance, policy: policy, readingCycles: cycles,
                                      distinctFrom: distinct)
            let folder = p.isDeleted
                ? paths.recentlyDeleted.appendingPathComponent((p.folder as NSString).lastPathComponent)
                : folderURL(p)
            await sidecars.schedule(sidecar, folderURL: folder)
        } catch {
            Log.storage.error("syncSidecar(\(pk)) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Mirrors categories + skip days into the library manifest.
    package func writeManifest() async {
        do {
            let categories = try await db.categories()
            let libraryID: String
            if let id = try await db.kv("library.id") { libraryID = id }
            else { libraryID = UUID().uuidString.lowercased(); try await db.setKV("library.id", libraryID) }
            let manifest = LibraryManifest(libraryID: libraryID, categories: categories,
                                           skipDays: await skipDays(), updatedAt: now())
            await sidecars.writeManifest(manifest)
        } catch {
            Log.storage.error("writeManifest failed: \(String(describing: error), privacy: .public)")
        }
    }
}

private extension Optional {
    func asyncFlatMap<U>(_ f: (Wrapped) async throws -> U?) async rethrows -> U? {
        guard let w = self else { return nil }
        return try await f(w)
    }
}

/// DB-backed metadata cache (`meta_cache` table).
package struct DBMetadataCache: MetadataCacheStore {
    package let db: Database
    package init(db: Database) { self.db = db }

    package func cached(key: String) async -> (status: Int, body: Data, fetchedAt: Date)? {
        guard let hit = try? await db.metaCache(key: key) else { return nil }
        return (hit.status, hit.body ?? Data(), hit.fetchedAt)
    }

    package func store(key: String, status: Int, body: Data, at: Date) async {
        try? await db.putMetaCache(key: key, status: status, body: body, at: at)
    }
}
