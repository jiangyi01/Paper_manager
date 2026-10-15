import Foundation

// User operations on papers (§6.3 operations, §6.4 状态流转, §8 详情页 / 右键菜单 / 分类管理).
// Every operation persists through the Database actor (one transaction or `modifyPaper`,
// never a stale `updatePaper` copy across an await), then refreshes card.json/notes.md
// via `ctx.syncSidecar(pk:)`. Papers are addressed by their UUID `id` in this API.
//
// Split across files: Operations.swift (checklist, status, estimate, metadata, taxonomy),
// OperationsSchedule.swift (DDL + 今天跳过 undo), OperationsFiles.swift (delete/restore/purge).

// MARK: - Errors

/// Why a user operation was refused. The UI shows `message(_:)` (zh/en).
package enum PaperOperationError: Error, Equatable, Sendable {
    case paperNotFound(String)
    case paperDeleted(String)                       // the paper is in 最近删除; restore it first
    case paperNotDeleted(String)                    // restore/purge of a live paper
    case checklistItemNotFound(String)
    case emptyText
    case emptyTitle
    case invalidTag(String)
    case invalidCategoryName(String)
    case categoryNotFound(Int64)
    case duplicateCategory(String)                  // existing name (case-insensitive match)
    case invalidIdentifier(String)                  // DOI / arXiv id the user typed
    case duplicateIdentifier(paperID: String, title: String)   // DOI/arXiv already on another live paper
    case restoreConflict(paperID: String, title: String)       // same DOI/arXiv is live again
    case fileOperation(String)
    case trashFailed(String)                        // folder name that could not be moved to the Trash
    case libraryNotEmpty                            // rebuild into a non-empty index
    case aiReadingInProgress                        // rebuild while the agent queue reads a paper

    package func message(_ lang: UILang) -> String { PaperOpsText.error(self, lang) }
}

// MARK: - Checklist, status, estimate, metadata, taxonomy

extension Engine {
    // MARK: Checklist

    /// Ticks or unticks one item. First tick → `reading` (+ `opened_at`); all ticked →
    /// `done` + `done_at` (when 全部勾选后自动标记已读 is on); unticking on a done paper →
    /// `reading`. DDLs never move. `becameDone` lets the UI show「已标记为已读 · 撤销」
    /// (undo = `setStatus(paperID:, .reading)`).
    @discardableResult
    package func toggleChecklistItem(paperID: String, itemID: String) async throws -> (paper: Paper, becameDone: Bool) {
        let pk = try await PaperOpsSupport.livePK(db, paperID)
        let autoDone = (await ctx.settings()).autoMarkDone
        let now = ctx.now()
        let outcome = try await db.transaction { db -> (Paper, Bool) in
            var p = try PaperOpsSupport.live(db, pk: pk, id: paperID)
            var items = try db.checklist(paperPK: pk)
            guard let i = items.firstIndex(where: { $0.id == itemID }) else {
                throw PaperOperationError.checklistItemNotFound(itemID)
            }
            let ticked = items[i].doneAt == nil
            items[i].doneAt = ticked ? now : nil
            try db.upsertChecklistItem(paperPK: pk, item: items[i])
            let before = p.status
            let after = ChecklistMerger.statusAfterToggle(current: before, items: items, autoDone: autoDone, ticked: ticked)
            if ticked, p.openedAt == nil { p.openedAt = now }
            p.status = after
            if after != .done { p.doneAt = nil } else if before != .done || p.doneAt == nil { p.doneAt = now }
            return (try db.updatePaper(p, now: now), before != .done && after == .done)
        }
        await ctx.syncSidecar(pk: pk)
        return (outcome.0, outcome.1)
    }

    /// Appends a user item (origin user). Returns the new item.
    @discardableResult
    package func addChecklistItem(paperID: String, text: String, section: String? = nil, minutes: Int = 10,
                                  page: Int? = nil) async throws -> ChecklistItem {
        let text = PaperOpsSupport.oneLine(text)
        guard !text.isEmpty else { throw PaperOperationError.emptyText }
        let section = PaperOpsSupport.optionalLine(section)
        let minutes = PaperOpsSupport.itemMinutes(minutes)
        let page = page.flatMap { $0 > 0 ? $0 : nil }
        let pk = try await PaperOpsSupport.livePK(db, paperID)
        let item = try await db.transaction { db -> ChecklistItem in
            _ = try PaperOpsSupport.live(db, pk: pk, id: paperID)
            let items = try db.checklist(paperPK: pk)
            let item = ChecklistItem(ord: (items.map(\.ord).max() ?? -1) + 1, text: text, section: section, page: page,
                                     minutes: minutes, kind: .other, origin: .user)
            try db.upsertChecklistItem(paperPK: pk, item: item)
            return item
        }
        await ctx.syncSidecar(pk: pk)
        return item
    }

    /// Rewrites an item's text, section and minutes; marks it `userEdited` so re-reads keep it.
    @discardableResult
    package func editChecklistItem(paperID: String, itemID: String, text: String, section: String?,
                                   minutes: Int) async throws -> ChecklistItem {
        let text = PaperOpsSupport.oneLine(text)
        guard !text.isEmpty else { throw PaperOperationError.emptyText }
        let section = PaperOpsSupport.optionalLine(section)
        let minutes = PaperOpsSupport.itemMinutes(minutes)
        let pk = try await PaperOpsSupport.livePK(db, paperID)
        let item = try await db.transaction { db -> ChecklistItem in
            _ = try PaperOpsSupport.live(db, pk: pk, id: paperID)
            guard var item = try db.checklist(paperPK: pk).first(where: { $0.id == itemID }) else {
                throw PaperOperationError.checklistItemNotFound(itemID)
            }
            if item.section != section { item.page = nil }     // the old page belonged to the old locator
            item.text = text
            item.section = section
            item.minutes = minutes
            item.userEdited = true
            try db.upsertChecklistItem(paperPK: pk, item: item)
            return item
        }
        await ctx.syncSidecar(pk: pk)
        return item
    }

    package func deleteChecklistItem(paperID: String, itemID: String) async throws {
        let pk = try await PaperOpsSupport.livePK(db, paperID)
        try await db.transaction { db in
            _ = try PaperOpsSupport.live(db, pk: pk, id: paperID)
            guard try db.checklist(paperPK: pk).contains(where: { $0.id == itemID }) else {
                throw PaperOperationError.checklistItemNotFound(itemID)
            }
            try db.deleteChecklistItem(id: itemID)
        }
        await ctx.syncSidecar(pk: pk)
    }

    /// Drag-reorder: moves the item to `toIndex` (clamped), renumbers `ord` 0…n−1 and
    /// marks the moved item `userEdited`. Returns the checklist in its new order.
    @discardableResult
    package func moveChecklistItem(paperID: String, itemID: String, toIndex: Int) async throws -> [ChecklistItem] {
        let pk = try await PaperOpsSupport.livePK(db, paperID)
        let items = try await db.transaction { db -> [ChecklistItem] in
            _ = try PaperOpsSupport.live(db, pk: pk, id: paperID)
            var items = try db.checklist(paperPK: pk)
            guard let from = items.firstIndex(where: { $0.id == itemID }) else {
                throw PaperOperationError.checklistItemNotFound(itemID)
            }
            var moved = items.remove(at: from)
            moved.userEdited = true
            items.insert(moved, at: min(max(toIndex, 0), items.count))
            for i in items.indices { items[i].ord = Double(i) }
            try db.replaceChecklist(paperPK: pk, items: items)
            return items
        }
        await ctx.syncSidecar(pk: pk)
        return items
    }

    // MARK: Status / priority

    /// 状态 [待读|在读|已读]. Entering done stamps `done_at`; leaving done clears it. DDLs never move.
    @discardableResult
    package func setStatus(paperID: String, _ status: PaperStatus) async throws -> Paper {
        try await PaperOpsSupport.modifyLive(self, paperID) { p, now in
            guard p.status != status else { return }
            p.status = status
            p.doneAt = status == .done ? now : nil
        }
    }

    /// ⌘D. Leaving done goes back to `reading` when the paper was started, else `to_read`.
    @discardableResult
    package func toggleDone(paperID: String) async throws -> Paper {
        let pk = try await PaperOpsSupport.livePK(db, paperID)
        let now = ctx.now()
        let saved = try await db.transaction { db -> Paper in
            var p = try PaperOpsSupport.live(db, pk: pk, id: paperID)
            if p.status == .done {
                let anyTicked = try db.checklist(paperPK: pk).contains(where: \.isDone)
                let started = p.openedAt != nil || anyTicked
                p.status = started ? .reading : .toRead
                p.doneAt = nil
            } else {
                p.status = .done
                p.doneAt = now
            }
            return try db.updatePaper(p, now: now)
        }
        await ctx.syncSidecar(pk: pk)
        return saved
    }

    /// Priority only — the DDL is a commitment and stays (§6.3). The detail view then offers
    /// 「按新优先级重新排期此论文」 = `replan(paperID:)`.
    @discardableResult
    package func setPriority(paperID: String, _ priority: Priority) async throws -> Paper {
        try await PaperOpsSupport.modifyLive(self, paperID) { p, _ in p.priority = priority }
    }

    /// The PDF was opened through the app: stamps `opened_at` once and moves to_read → reading.
    @discardableResult
    package func markOpened(paperID: String) async throws -> Paper {
        try await PaperOpsSupport.modifyLive(self, paperID) { p, now in
            if p.openedAt == nil { p.openedAt = now }
            if p.status == .toRead { p.status = .reading }
        }
    }

    // MARK: Estimate

    /// 预计 N′ stepper: `est_source = user`; the DDL does not move. When the checklist is
    /// still the untouched heuristic one, its minutes are rescaled (largest remainder,
    /// 5-minute units when possible) so they add up to the new estimate.
    @discardableResult
    package func setEstimate(paperID: String, minutes: Int) async throws -> Paper {
        let est = min(max(minutes, 5), 24 * 60)
        let pk = try await PaperOpsSupport.livePK(db, paperID)
        let now = ctx.now()
        let saved = try await db.transaction { db -> Paper in
            var p = try PaperOpsSupport.live(db, pk: pk, id: paperID)
            p.estMinutes = est
            p.estSource = .user
            let items = try db.checklist(paperPK: pk)
            if PaperOpsSupport.isUntouchedHeuristic(items) {
                let scaled = PaperOpsSupport.rescale(items, to: est)
                if scaled != items { try db.replaceChecklist(paperPK: pk, items: scaled) }
            }
            return try db.updatePaper(p, now: now)
        }
        await ctx.syncSidecar(pk: pk)
        return saved
    }

    // MARK: Metadata, notes, AI

    /// 编辑元数据 (⌘E). Sets `meta_user_edited` (the resolver never overwrites it), title rank
    /// `user`, `meta_source = user` when nothing canonical was known, re-indexes the metadata
    /// FTS row (inside `updatePaper`), then asks the enrich pipeline to refile under the new name.
    @discardableResult
    package func editMetadata(paperID: String, title: String, authors: [String], year: Int?, venue: String?,
                              doi: String?, arxivID: String?) async throws -> Paper {
        let title = PaperOpsSupport.oneLine(title)
        guard !title.isEmpty else { throw PaperOperationError.emptyTitle }
        let authors = authors.map(PaperOpsSupport.oneLine).filter { !$0.isEmpty }
        let venue = PaperOpsSupport.optionalLine(venue)
        let year = year.flatMap { (1000...9999).contains($0) ? $0 : nil }
        let doi = try PaperOpsSupport.normalizedDOI(doi)
        let arxiv = try PaperOpsSupport.normalizedArxiv(arxivID)
        let pk = try await PaperOpsSupport.livePK(db, paperID)
        let now = ctx.now()
        let saved = try await db.transaction { db -> Paper in
            var p = try PaperOpsSupport.live(db, pk: pk, id: paperID)
            // Both bioRxiv prefixes (10.1101 / 10.64898) of one preprint count as the same DOI.
            if let doi, doi != p.ids.doi?.lowercased(),
               let other = try db.livePaper(holdingDOI: doi, excluding: pk) {
                throw PaperOperationError.duplicateIdentifier(paperID: other.id, title: other.title)
            }
            if let arxiv, arxiv.id.lowercased() != p.ids.arxivID?.lowercased(),
               let other = try db.paperMatchingWork(doi: nil, arxivID: arxiv.id, publishedDOI: nil, excluding: pk) {
                throw PaperOperationError.duplicateIdentifier(paperID: other.id, title: other.title)
            }
            let sameArxiv = arxiv?.id.lowercased() == p.ids.arxivID?.lowercased()
            let oldVersion = p.ids.arxivVersion
            p.title = title
            p.titleRank = .user
            p.authors = authors
            p.year = year
            p.venue = venue
            p.ids.doi = doi
            p.ids.arxivVersion = arxiv.flatMap { $0.version ?? (sameArxiv ? oldVersion : nil) }
            p.ids.arxivID = arxiv?.id
            p.metaUserEdited = true
            if p.metaSource == .none { p.metaSource = .user }
            do {
                return try db.updatePaper(p, now: now)
            } catch let e as SQLiteError where e.isUniqueViolation {
                throw PaperOperationError.duplicateIdentifier(paperID: "", title: doi ?? arxiv?.id ?? "")
            }
        }
        await ctx.syncSidecar(pk: pk)
        await enrich.refile(pk: pk)
        return try await db.paper(pk: pk) ?? saved
    }

    /// 「从 DOI 重新获取」 / 「刷新元数据」 (bypasses the metadata cache). True when anything changed.
    /// A paper flagged `titleLookupHeld` is looked up by its identifiers only.
    @discardableResult
    package func refreshMetadata(paperID: String) async throws -> Bool {
        let pk = try await PaperOpsSupport.livePK(db, paperID)
        return await enrich.refreshMetadata(pk: pk)
    }

    /// "Look up metadata online" on a paper whose title lookups are held (`titleLookupHeld`: it
    /// came from a confidential email or a person's possibly unpublished PDF): the user's explicit
    /// OK — the flag is cleared and the metadata is refreshed, now with a title search. True when
    /// anything changed.
    @discardableResult
    package func lookUpMetadataOnline(paperID: String) async throws -> Bool {
        let pk = try await PaperOpsSupport.livePK(db, paperID)
        let p = try await db.paper(pk: pk)
        if p?.flags.contains(.titleLookupHeld) == true {
            _ = try await db.modifyPaper(pk: pk, now: ctx.now()) { $0.flags.remove(.titleLookupHeld) }
            await ctx.syncSidecar(pk: pk)
        }
        return await enrich.refreshMetadata(pk: pk)
    }

    /// 笔记 (the app debounces ~1 s). Re-indexes the notes column; notes.md follows.
    @discardableResult
    package func setNotes(paperID: String, _ notes: String) async throws -> Paper {
        try await PaperOpsSupport.modifyLive(self, paperID) { p, _ in p.notes = notes }
    }

    /// 用 Claude 重新解读 (⌥⌘R): a fresh job at raised priority, not held.
    package func requestReread(paperID: String) async throws {
        let pk = try await PaperOpsSupport.livePK(db, paperID)
        await agents.enqueue(paperPK: pk, hold: false, priority: 1)
    }

    /// Clears the blue NEW dot after the user looked at a fresh AI card.
    @discardableResult
    package func markAISeen(paperID: String) async throws -> Paper {
        let current = try await PaperOpsSupport.livePaper(db, paperID)
        guard !current.aiSeen else { return current }
        return try await PaperOpsSupport.modifyLive(self, paperID) { p, _ in p.aiSeen = true }
    }

    // MARK: Categories

    /// 分类 ▸ (nil = 未分类). Marks the choice as the user's so re-reads never recategorize it.
    @discardableResult
    package func setCategory(paperID: String, categoryPK: Int64?) async throws -> Paper {
        let pk = try await PaperOpsSupport.livePK(db, paperID)
        let now = ctx.now()
        let saved = try await db.transaction { db -> Paper in
            var p = try PaperOpsSupport.live(db, pk: pk, id: paperID)
            if let categoryPK, try db.category(pk: categoryPK) == nil {
                throw PaperOperationError.categoryNotFound(categoryPK)
            }
            p.categoryPK = categoryPK
            p.categoryUserSet = true
            p.needsReview = false
            return try db.updatePaper(p, now: now)
        }
        await ctx.syncSidecar(pk: pk)
        return saved
    }

    /// New user category (name normalized like the agent's, least-used palette hue).
    @discardableResult
    package func createCategory(name: String, description: String? = nil) async throws -> PaperCategory {
        guard let name = Taxonomy.normalizeCategoryName(name) else { throw PaperOperationError.invalidCategoryName(name) }
        let description = PaperOpsSupport.optionalLine(description)
        let now = ctx.now()
        let saved = try await db.transaction { db -> PaperCategory in
            if let existing = try db.category(named: name) { throw PaperOperationError.duplicateCategory(existing.name) }
            let hue = Taxonomy.nextHue(existing: try db.categories())
            return try db.insertCategory(PaperCategory(name: name, description: description, hue: hue, origin: .user,
                                                       acknowledged: true, createdAt: now))
        }
        await ctx.writeManifest()
        return saved
    }

    /// 重命名… — card.json of every paper in it is rewritten (it stores the category name).
    @discardableResult
    package func renameCategory(pk: Int64, name: String) async throws -> PaperCategory {
        guard let name = Taxonomy.normalizeCategoryName(name) else { throw PaperOperationError.invalidCategoryName(name) }
        let (saved, affected) = try await db.transaction { db -> (PaperCategory, [Int64]) in
            guard var c = try db.category(pk: pk) else { throw PaperOperationError.categoryNotFound(pk) }
            if let other = try db.category(named: name), other.pk != pk { throw PaperOperationError.duplicateCategory(other.name) }
            c.name = name
            try db.updateCategory(c)
            return (c, try db.allPapers().filter { $0.categoryPK == pk }.map(\.pk))
        }
        await ctx.writeManifest()
        for paperPK in affected { await ctx.syncSidecar(pk: paperPK) }
        return saved
    }

    /// 编辑描述… (one line; sent to Claude so it categorizes consistently). Empty → nil.
    @discardableResult
    package func setCategoryDescription(pk: Int64, _ description: String?) async throws -> PaperCategory {
        let description = PaperOpsSupport.optionalLine(description)
        let saved = try await db.transaction { db -> PaperCategory in
            guard var c = try db.category(pk: pk) else { throw PaperOperationError.categoryNotFound(pk) }
            c.description = description
            try db.updateCategory(c)
            return c
        }
        await ctx.writeManifest()
        return saved
    }

    /// 删除（论文移到未分类）.
    package func deleteCategory(pk: Int64) async throws {
        let affected = try await db.transaction { db -> [Int64] in
            guard try db.category(pk: pk) != nil else { throw PaperOperationError.categoryNotFound(pk) }
            let affected = try db.allPapers().filter { $0.categoryPK == pk }.map(\.pk)
            try db.deleteCategory(pk: pk)
            return affected
        }
        await ctx.writeManifest()
        for paperPK in affected { await ctx.syncSidecar(pk: paperPK) }
    }

    /// Opening a NEW category in the sidebar acknowledges it (badge off).
    package func acknowledgeCategory(pk: Int64) async throws {
        let changed = try await db.transaction { db -> Bool in
            guard var c = try db.category(pk: pk) else { throw PaperOperationError.categoryNotFound(pk) }
            guard !c.acknowledged else { return false }
            c.acknowledged = true
            try db.updateCategory(c)
            return true
        }
        if changed { await ctx.writeManifest() }
    }

    // MARK: Tags

    /// Adds a user tag (normalized kebab-case). An agent or suppressed row with the same
    /// name becomes the user's. Returns the visible (non-suppressed) tags.
    @discardableResult
    package func addTag(paperID: String, _ name: String) async throws -> [Tag] {
        guard let tag = Taxonomy.normalizeTag(name) else { throw PaperOperationError.invalidTag(name) }
        let pk = try await PaperOpsSupport.livePK(db, paperID)
        let tags = try await db.transaction { db -> [Tag] in
            _ = try PaperOpsSupport.live(db, pk: pk, id: paperID)
            var tags = try db.tags(paperPK: pk)
            if let i = tags.firstIndex(where: { PaperOpsSupport.tagKey($0.name) == tag }) {
                guard tags[i].origin != .user else { return tags.filter { $0.origin != .suppressed } }
                tags[i].origin = .user
            } else {
                tags.append(Tag(name: tag, origin: .user))
            }
            try db.setTags(paperPK: pk, tags)
            return tags.filter { $0.origin != .suppressed }
        }
        await ctx.syncSidecar(pk: pk)
        return tags
    }

    /// Removes a tag chip. An agent tag is kept as `suppressed` so a re-read does not bring
    /// it back; a user tag is deleted. Returns the visible tags.
    @discardableResult
    package func removeTag(paperID: String, _ name: String) async throws -> [Tag] {
        let key = PaperOpsSupport.tagKey(name)
        let pk = try await PaperOpsSupport.livePK(db, paperID)
        let tags = try await db.transaction { db -> [Tag] in
            _ = try PaperOpsSupport.live(db, pk: pk, id: paperID)
            var tags = try db.tags(paperPK: pk)
            guard let i = tags.firstIndex(where: { PaperOpsSupport.tagKey($0.name) == key }) else {
                return tags.filter { $0.origin != .suppressed }
            }
            switch tags[i].origin {
            case .agent: tags[i].origin = .suppressed
            case .user: tags.remove(at: i)
            case .suppressed: return tags.filter { $0.origin != .suppressed }
            }
            try db.setTags(paperPK: pk, tags)
            return tags.filter { $0.origin != .suppressed }
        }
        await ctx.syncSidecar(pk: pk)
        return tags
    }
}

// MARK: - Shared helpers (Operations*.swift)

enum PaperOpsSupport {
    /// pk of a live paper, or the typed error the UI shows.
    static func livePK(_ db: Database, _ id: String) async throws -> Int64 {
        try await livePaper(db, id).pk
    }

    static func livePaper(_ db: Database, _ id: String) async throws -> Paper {
        guard let p = try await db.paper(id: id) else { throw PaperOperationError.paperNotFound(id) }
        guard p.isLive else { throw PaperOperationError.paperDeleted(id) }
        return p
    }

    /// Re-reads the row inside a transaction (the only copy a write may be based on).
    static func live(_ db: isolated Database, pk: Int64, id: String) throws -> Paper {
        guard let p = try db.paper(pk: pk) else { throw PaperOperationError.paperNotFound(id) }
        guard p.isLive else { throw PaperOperationError.paperDeleted(id) }
        return p
    }

    /// Atomic read-modify-write of a live paper + sidecar sync.
    static func modifyLive(_ engine: Engine, _ id: String,
                           _ body: @escaping @Sendable (inout Paper, Date) throws -> Void) async throws -> Paper {
        let pk = try await livePK(engine.db, id)
        let now = engine.ctx.now()
        let saved = try await engine.db.modifyPaper(pk: pk, now: now) { p in
            guard p.isLive else { throw PaperOperationError.paperDeleted(id) }
            try body(&p, now)
        }
        await engine.ctx.syncSidecar(pk: pk)
        return saved
    }

    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    static func optionalLine(_ s: String?) -> String? {
        guard let s else { return nil }
        let line = oneLine(s)
        return line.isEmpty ? nil : line
    }

    static func itemMinutes(_ m: Int) -> Int { min(max(m, 1), 600) }

    static func tagKey(_ name: String) -> String {
        Taxonomy.normalizeTag(name) ?? name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Bare DOI, `doi:` or doi.org URL → lowercased DOI; empty → nil; anything else throws.
    static func normalizedDOI(_ raw: String?) throws -> String? {
        guard let raw = optionalLine(raw) else { return nil }
        guard let doi = FTSQuery.parseDOI(raw) else { throw PaperOperationError.invalidIdentifier(raw) }
        return doi
    }

    /// `2606.24530v2`, `arXiv:…`, arxiv.org URLs → (base id, version); empty → nil.
    static func normalizedArxiv(_ raw: String?) throws -> (id: String, version: Int?)? {
        guard let raw = optionalLine(raw) else { return nil }
        guard let id = FTSQuery.parseArxivID(raw) else { throw PaperOperationError.invalidIdentifier(raw) }
        var stem = raw
        if stem.lowercased().hasSuffix(".pdf") { stem = String(stem.dropLast(4)) }
        let version = stem.range(of: #"v(\d+)$"#, options: .regularExpression)
            .flatMap { Int(stem[$0].dropFirst()) }
        return (id, version)
    }

    /// The import-time checklist nobody has touched yet (safe to rescale).
    static func isUntouchedHeuristic(_ items: [ChecklistItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { $0.origin == .heuristic && !ChecklistMerger.isTouched($0) }
    }

    /// Largest-remainder rescale so Σ minutes == est exactly; 5-minute units when `est` is a
    /// multiple of 5 and every item can keep at least one unit, else whole minutes. Each item
    /// keeps ≥ 1 unit whenever there are enough units.
    static func rescale(_ items: [ChecklistItem], to est: Int) -> [ChecklistItem] {
        guard !items.isEmpty, est > 0 else { return items }
        let unit = est % 5 == 0 && est / 5 >= items.count ? 5 : 1
        let units = est / unit
        var alloc = ChecklistHeuristics.largestRemainder(units: units, weights: items.map { max(0, $0.minutes) })
        if units >= items.count {
            var deficit = 0
            for i in alloc.indices where alloc[i] < 1 { deficit += 1 - alloc[i]; alloc[i] = 1 }
            while deficit > 0, let j = alloc.indices.filter({ alloc[$0] > 1 }).max(by: { alloc[$0] < alloc[$1] }) {
                alloc[j] -= 1
                deficit -= 1
            }
        }
        return zip(items, alloc).map { item, a in
            var copy = item
            copy.minutes = a * unit
            return copy
        }
    }

    /// Unique child name inside `dir` (FileNamer's `_2`, `_3`… rule). Blocking.
    static func uniqueChildName(_ base: String, in dir: URL) -> String {
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return FileNamer.uniqueName(base, existing: Set(existing))
    }

    static func itemExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

// MARK: - zh/en strings produced by the operations

enum PaperOpsText {
    static func error(_ e: PaperOperationError, _ lang: UILang) -> String {
        let zh = lang == .zh
        switch e {
        case .paperNotFound: return zh ? "找不到这篇论文" : "Paper not found"
        case .paperDeleted: return zh ? "这篇论文在「最近删除」中，请先恢复" : "This paper is in Recently Deleted — restore it first"
        case .paperNotDeleted: return zh ? "这篇论文不在「最近删除」中" : "This paper is not in Recently Deleted"
        case .checklistItemNotFound: return zh ? "找不到该清单条目" : "Checklist item not found"
        case .emptyText: return zh ? "条目内容不能为空" : "The item text can't be empty"
        case .emptyTitle: return zh ? "标题不能为空" : "The title can't be empty"
        case .invalidTag(let t): return zh ? "无效的标签：\(t)" : "Invalid tag: \(t)"
        case .invalidCategoryName(let n): return zh ? "无效的分类名称：\(n)" : "Invalid category name: \(n)"
        case .categoryNotFound: return zh ? "找不到该分类" : "Category not found"
        case .duplicateCategory(let n): return zh ? "已有同名分类「\(n)」" : "A category named “\(n)” already exists"
        case .invalidIdentifier(let s): return zh ? "无法识别的 DOI 或 arXiv 编号：\(s)" : "Not a valid DOI or arXiv ID: \(s)"
        case .duplicateIdentifier(_, let title):
            return zh ? "该 DOI/arXiv 编号已属于库中另一篇论文：\(title)" : "That DOI/arXiv ID already belongs to another paper: \(title)"
        case .restoreConflict(_, let title):
            return zh ? "无法恢复：同一论文已在库中（\(title)）" : "Can't restore: the same paper is already in the library (\(title))"
        case .fileOperation(let why): return zh ? "文件操作失败：\(why)" : "File operation failed: \(why)"
        case .trashFailed(let name): return zh ? "无法将「\(name)」移到废纸篓" : "Couldn't move “\(name)” to the Trash"
        case .libraryNotEmpty: return zh ? "索引中已有论文，未执行重建" : "The index already contains papers; nothing was rebuilt"
        case .aiReadingInProgress:
            return zh ? "AI 正在解读一篇论文，未执行重建。请等它读完（或在 AI 队列中取消）后再试。"
                      : "AI is reading a paper right now; nothing was rebuilt. Try again once it finishes (or cancel it in the AI queue)."
        }
    }

    static func skippedToday(moved: Int, _ lang: UILang) -> String {
        if lang == .zh { return moved > 0 ? "今天已跳过 · \(moved) 篇顺延一天" : "今天已跳过" }
        if moved == 0 { return "Skipped today" }
        return "Skipped today · \(moved) paper\(moved == 1 ? "" : "s") moved to the next reading day"
    }

    static func undo(_ lang: UILang) -> String { lang == .zh ? "撤销" : "Undo" }
}
