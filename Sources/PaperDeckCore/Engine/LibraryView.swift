import Foundation

// The UI read model (§8 主窗口): one consistent snapshot of the library for the sidebar,
// card grid, 今天 list, detail inspector and the sidebar footer.

/// One paper as the card grid / Today list / inspector show it.
package struct PaperRow: Sendable, Equatable, Identifiable {
    package var paper: Paper
    package var checklist: [ChecklistItem]         // ord order
    package var tags: [Tag]                        // visible (non-suppressed)
    package var category: PaperCategory?
    package var remainingMinutes: Int              // Σ unticked minutes (estimate when no checklist)
    package var doneCount: Int
    package var totalCount: Int
    // DDLChip inputs (the chip itself is `DeadlineLabel.chip(…)` in PaperDeckShared)
    package var atRisk: Bool
    package var finish: LocalDate?                 // simulated finish day (at-risk tooltip)
    package var minutesToday: Int?                 // today's share when the paper is in today's set
    package var thumbnailURL: URL?                 // caches/thumbs/<id>@2x.jpg when present
    package var pdfURL: URL

    package var id: String { paper.id }
}

/// A sidebar category line.
package struct CategoryRow: Sendable, Equatable, Identifiable {
    package var category: PaperCategory
    package var paperCount: Int                    // live papers
    package var isNew: Bool                        // NEW badge until acknowledged

    package var id: Int64 { category.pk }
}

package struct LibrarySnapshot: Sendable, Equatable {
    package struct Totals: Sendable, Equatable {
        package var count: Int                     // live papers
        package var logicalBytes: Int64            // Σ file_size of live papers (DB)
    }

    package let rows: [PaperRow]                   // live papers, queue order
    package let deleted: [PaperRow]                // 最近删除, most recent first
    package let categories: [CategoryRow]
    package let today: TodayPlan
    package let generatedAt: Date
    package let totals: Totals
    private let index: [String: Int]               // id → position (rows first, then deleted)

    package init(rows: [PaperRow], deleted: [PaperRow], categories: [CategoryRow], today: TodayPlan,
                 generatedAt: Date, totals: Totals) {
        self.rows = rows; self.deleted = deleted; self.categories = categories; self.today = today
        self.generatedAt = generatedAt; self.totals = totals
        var index: [String: Int] = [:]
        for (i, r) in (rows + deleted).enumerated() where index[r.id] == nil { index[r.id] = i }
        self.index = index
    }

    /// O(1) lookup of a live or deleted row.
    package func row(id: String) -> PaperRow? {
        guard let i = index[id.lowercased()] else { return nil }
        return i < rows.count ? rows[i] : deleted[i - rows.count]
    }

    /// Today's set in display order (overdue, due today, planned).
    package var todayRows: [PaperRow] { today.ids.compactMap { row(id: $0) } }

    /// 侧栏「需要处理」: AI failed / needs login, locked, scanned or missing files.
    package var needsAttention: [PaperRow] {
        let flags: PaperFlags = [.locked, .scanned, .missing]
        return rows.filter {
            $0.paper.aiState == .failed || $0.paper.aiState == .needsLogin || !$0.paper.flags.intersection(flags).isEmpty
        }
    }
}

extension Engine {
    /// Builds the whole read model from one DB read (a single Database call, so no write can
    /// interleave) plus one listing of the thumbnail cache. Batch queries keep it O(papers).
    package func librarySnapshot() async throws -> LibrarySnapshot {
        let read = try await db.transaction { db -> LibrarySnapshotRead in
            let live = try db.livePapers()
            let deleted = try db.deletedPapers()
            let pks = (live + deleted).map(\.pk)
            return LibrarySnapshotRead(live: live, deleted: deleted, checklists: try db.checklists(paperPKs: pks),
                               tags: try db.tags(paperPKs: pks), categories: try db.categories(),
                               counts: try db.categoryCounts(), skipDaysJSON: try db.kv(EngineContext.skipDaysKey))
        }
        var settings = ctx.loadSettings()
        settings.plan.skipDays = LibrarySnapshotRead.decodeSkipDays(read.skipDaysJSON)
        let now = ctx.now()
        let scheduler = Scheduler(settings: settings.plan, now: now, calendar: ctx.calendar)
        let items = read.live.map { Scheduler.item(for: $0, checklist: read.checklists[$0.pk] ?? []) }
        let today = TodaySet.compute(items, scheduler: scheduler)

        let thumbs = ctx.thumbs
        let thumbIDs = await BlockingIO.run { LibrarySnapshotRead.cardThumbnailIDs(in: thumbs.cardDirectory) }
        let categoriesByPK = Dictionary(read.categories.map { ($0.pk, $0) }, uniquingKeysWith: { a, _ in a })

        func row(_ p: Paper, live: Bool) -> PaperRow {
            let checklist = read.checklists[p.pk] ?? []
            return PaperRow(
                paper: p, checklist: checklist,
                tags: (read.tags[p.pk] ?? []).filter { $0.origin != .suppressed },
                category: p.categoryPK.flatMap { categoriesByPK[$0] },
                remainingMinutes: Scheduler.remainingMinutes(estMinutes: p.estMinutes, checklist: checklist),
                doneCount: checklist.count(where: \.isDone), totalCount: checklist.count,
                atRisk: live && today.atRisk.contains(p.id),
                finish: live ? today.finish[p.id] : nil,
                minutesToday: live ? today.minutesToday[p.id] : nil,
                thumbnailURL: thumbIDs.contains(p.id) ? thumbs.cardURL(for: p.id) : nil,
                pdfURL: ctx.pdfURL(p))
        }

        return LibrarySnapshot(
            rows: read.live.map { row($0, live: true) },
            deleted: read.deleted.map { row($0, live: false) },
            categories: read.categories.map {
                CategoryRow(category: $0, paperCount: read.counts[$0.pk] ?? 0, isNew: !$0.acknowledged)
            },
            today: today,
            generatedAt: now,
            totals: .init(count: read.live.count, logicalBytes: read.live.reduce(0) { $0 + max(0, $1.fileSize) }))
    }

    /// Search box (⌘F): live paper ids in rank order (metadata hits, then full-text hits).
    package func search(_ query: String) async throws -> [String] {
        let pks = try await db.search(query)
        return try await db.papers(pks: pks).map(\.id)
    }
}

/// Everything `librarySnapshot()` reads inside its one Database call.
struct LibrarySnapshotRead: Sendable {
    var live: [Paper]
    var deleted: [Paper]
    var checklists: [Int64: [ChecklistItem]]
    var tags: [Int64: [Tag]]
    var categories: [PaperCategory]
    var counts: [Int64: Int]
    var skipDaysJSON: String?

    /// Same encoding as `EngineContext.setSkipDays` (JSON array of `YYYY-MM-DD`).
    static func decodeSkipDays(_ json: String?) -> Set<LocalDate> {
        guard let json, let list = try? JSONDecoder().decode([LocalDate].self, from: Data(json.utf8)) else { return [] }
        return Set(list)
    }

    /// Ids that have `<id>@2x.jpg` in the card-thumbnail cache (one directory listing).
    static func cardThumbnailIDs(in dir: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.compactMap { $0.hasSuffix("@2x.jpg") ? String($0.dropLast("@2x.jpg".count)) : nil })
    }
}
