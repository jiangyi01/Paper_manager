import Foundation

// Index rebuild from the files (§1 设计原则: the DB can be rebuilt from every paper's
// card.json plus `.paperdeck-library.json`), and the canonical dump that proves it.

package struct RebuildReport: Sendable, Equatable {
    package var papers = 0                    // live papers inserted
    package var deleted = 0                   // 最近删除 papers inserted
    package var categories = 0                // categories after the rebuild
    package var skipDays = 0
    package var fullTextIndexed = 0
    package var manifestFound = false
    package var skipped: [String] = []        // "<folder>: <reason>" (duplicates, constraint conflicts)
    package var unreadable: [String] = []     // card.json / manifest files that did not decode

    package init() {}
}

extension Engine {
    /// Rebuilds the index from `Papers/**/card.json`, `.recently-deleted/*/card.json` and the
    /// library manifest (categories with description/hue/origin/acknowledged, skip days,
    /// library id). Starter categories are matched by name case-insensitively. Folder
    /// location decides live vs deleted. FTS metadata is indexed on insert; full text comes
    /// from the text cache when present. Refuses (`.libraryNotEmpty`) when the index has
    /// papers unless `replacingExisting` (then only DB rows are dropped — files stay).
    /// Replacing keeps what hangs off the dropped rows but isn't in card.json — Q&A threads,
    /// Explain history, duplicate reviews — by linking it back to the re-inserted papers by id;
    /// it refuses (`.aiReadingInProgress`) while the agent queue is reading a paper, whose
    /// result would otherwise land on a deleted row and be read a second time.
    @discardableResult
    package func rebuildFromSidecars(replacingExisting: Bool = false) async throws -> RebuildReport {
        // A running reading's job row would cascade away under it: its card dropped, the paper
        // queued again from card.json. A started queue has reset every stale running row, so a
        // running job then is a live one (checked again inside the transaction below).
        if replacingExisting, await agents.runningPaperPK() != nil { throw PaperOperationError.aiReadingInProgress }
        let queueLive = await agents.mayBeReading()
        let library = paths.library, manifestURL = paths.libraryManifest
        let liveScan = await SidecarWriter.scanSidecars(papersRoot: paths.papers)
        let binScan = await SidecarWriter.scanSidecars(papersRoot: paths.recentlyDeleted)
        var report = RebuildReport()
        let manifest: LibraryManifest?
        do {
            manifest = try await BlockingIO.run { try SidecarWriter.readManifest(at: manifestURL) }
        } catch {
            manifest = nil
            report.unreadable.append("\(LibraryManifest.fileName): \(error)")
        }
        report.manifestFound = manifest != nil
        report.unreadable += (liveScan.unreadable + binScan.unreadable).map {
            "\(OpsFiles.relative($0.folder, library: library)): \($0.reason)"
        }
        let liveEntries = liveScan.entries, binEntries = binScan.entries
        let candidates = await BlockingIO.run {
            SidecarRestore.candidates(live: liveEntries, deleted: binEntries, library: library)
        }
        let now = ctx.now()

        let outcome = try await db.transaction { db -> SidecarRestore.Outcome in
            let existing = try db.allPapers()
            var links = PaperAssistLinks()
            if !existing.isEmpty {
                guard replacingExisting else { throw PaperOperationError.libraryNotEmpty }
                if queueLive, try !db.jobs(states: [.running]).isEmpty { throw PaperOperationError.aiReadingInProgress }
                // Q&A thread links, Explain records and duplicate reviews hang off the rows'
                // pks (cascade / set null): read them by paper id, link them back below.
                links = try db.paperAssistLinks()
                for p in existing { try db.hardDelete(pk: p.pk) }
            }
            var categories = try SidecarRestore.restoreCategories(db, manifest: manifest)
            var out = SidecarRestore.Outcome()
            var seenIDs = Set<String>(), seenSHA = Set<String>()
            for c in candidates {
                let id = c.sidecar.id.lowercased(), sha = c.sidecar.sha256.lowercased()
                guard !seenIDs.contains(id), !seenSHA.contains(sha) else {
                    out.skipped.append("\(c.relativeFolder): duplicate of another card.json")
                    continue
                }
                do {
                    let saved = try SidecarRestore.insert(c, db: db, categories: &categories, now: now)
                    seenIDs.insert(id); seenSHA.insert(sha)
                    out.inserted.append(.init(pk: saved.pk, id: saved.id))
                    if saved.isDeleted { out.deleted += 1 } else { out.live += 1 }
                } catch let e as SQLiteError where e.isConstraintViolation {
                    out.skipped.append("\(c.relativeFolder): \(e.message)")
                }
            }
            if !links.isEmpty {
                let relinked = try db.relinkPaperAssistLinks(links)
                if relinked.unmatched > 0 {
                    Log.storage.notice("rebuild: \(relinked.unmatched, privacy: .public) assist row(s) without their paper")
                }
            }
            if let manifest {
                if manifest.skipDays.isEmpty {
                    try db.removeKV(EngineContext.skipDaysKey)
                } else {
                    let json = try JSONEncoder().encode(manifest.skipDays.sorted())
                    try db.setKV(EngineContext.skipDaysKey, String(decoding: json, as: UTF8.self))
                }
                try db.setKV("library.id", manifest.libraryID)
            }
            out.categories = try db.categories().count
            out.skipDays = LibrarySnapshotRead.decodeSkipDays(try db.kv(EngineContext.skipDaysKey)).count
            return out
        }

        report.papers = outcome.live
        report.deleted = outcome.deleted
        report.categories = outcome.categories
        report.skipDays = outcome.skipDays
        report.skipped += outcome.skipped
        report.fullTextIndexed = await SidecarRestore.indexFullText(self, outcome.inserted)
        _ = await restoreQASidecars(paperIDs: outcome.inserted.map(\.id))   // qa.json → qa_* (single-paper threads)
        await ctx.writeManifest()
        Log.storage.notice("rebuild: \(report.papers) live, \(report.deleted) deleted, \(report.skipped.count) skipped")
        return report
    }

    /// Deterministic, key-sorted JSON of the library's canonical state: papers (all columns
    /// except `pk` and `updated_at`; category by name) with their checklist, tags and email
    /// provenance (`paper_source`), categories (without pk) and skip days. Rebuild fidelity =
    /// byte-identical dumps.
    package func dumpCanonical() async throws -> Data {
        let read = try await db.transaction { db -> CanonicalRead in
            let papers = try db.allPapers()
            let pks = papers.map(\.pk)
            var sources: [Int64: [PaperProvenance]] = [:]
            for pk in pks {
                let rows = try db.paperSources(paperPK: pk)
                if !rows.isEmpty { sources[pk] = rows }
            }
            var cycles: [Int64: [ReadingCycle]] = [:]
            var distinct: [Int64: [String]] = [:]
            for pk in pks {
                let c = try db.readingCycles(paperPK: pk)
                if !c.isEmpty { cycles[pk] = c }
                let d = try db.dupPairPartnerIDs(paperPK: pk)
                if !d.isEmpty { distinct[pk] = d }
            }
            return CanonicalRead(papers: papers, checklists: try db.checklists(paperPKs: pks),
                                 tags: try db.tags(paperPKs: pks), sources: sources, categories: try db.categories(),
                                 skipDaysJSON: try db.kv(EngineContext.skipDaysKey),
                                 policies: try db.paperPolicies(paperPKs: pks), cycles: cycles, distinct: distinct)
        }
        let names = Dictionary(read.categories.map { ($0.pk, $0.name) }, uniquingKeysWith: { a, _ in a })
        let papers = try read.papers.sorted { $0.id < $1.id }.map { p in
            try CanonicalRead.paper(p, category: p.categoryPK.flatMap { names[$0] },
                                    checklist: read.checklists[p.pk] ?? [], tags: read.tags[p.pk] ?? [],
                                    provenance: read.sources[p.pk] ?? [], policy: read.policies[p.pk],
                                    cycles: read.cycles[p.pk] ?? [], distinctFrom: read.distinct[p.pk] ?? [])
        }
        let categories = read.categories
            .sorted { ($0.name.lowercased(), $0.name) < ($1.name.lowercased(), $1.name) }
            .map(CanonicalRead.category)
        let doc = JSONValue.object([
            "format": .string("paperdeck.canonical/1"),
            "papers": .array(papers),
            "categories": .array(categories),
            "skipDays": .array(LibrarySnapshotRead.decodeSkipDays(read.skipDaysJSON).sorted().map { .string($0.iso) }),
        ])
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var data = try enc.encode(doc)
        data.append(0x0A)
        return data
    }
}

// MARK: - Shared with Maintenance (adopting single folders)

enum SidecarRestore {
    /// A card.json found on disk, with what the folder actually holds.
    struct Candidate: Sendable {
        var relativeFolder: String
        var sidecar: CardSidecar
        var inRecentlyDeleted: Bool
        var pdfName: String?                  // PDF present in the folder (card's name preferred); nil = none
        var folderDate: Date?                 // stand-in for unreadable timestamps
    }

    struct Inserted: Sendable, Equatable {
        var pk: Int64
        var id: String
    }

    struct Outcome: Sendable {
        var inserted: [Inserted] = []
        var live = 0
        var deleted = 0
        var categories = 0
        var skipDays = 0
        var skipped: [String] = []
    }

    /// Live folders first (a paper found in both places stays live), each group in folder order.
    static func candidates(live: [(folder: URL, sidecar: CardSidecar)], deleted: [(folder: URL, sidecar: CardSidecar)],
                           library: URL) -> [Candidate] {
        func make(_ e: (folder: URL, sidecar: CardSidecar), deleted: Bool) -> Candidate {
            Candidate(relativeFolder: OpsFiles.relative(e.folder, library: library), sidecar: e.sidecar,
                      inRecentlyDeleted: deleted,
                      pdfName: resolvePDF(in: e.folder, preferred: [e.sidecar.pdf,
                                                                    FileNamer.pdfName(forFolder: e.folder.lastPathComponent)]),
                      folderDate: (try? e.folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
        }
        return live.map { make($0, deleted: false) } + deleted.map { make($0, deleted: true) }
    }

    /// The first preferred name that exists, else the folder's only PDF, else nil. Blocking.
    static func resolvePDF(in folder: URL, preferred: [String]) -> String? {
        for name in preferred where !name.isEmpty && !name.contains("/") {
            if PaperOpsSupport.itemExists(folder.appendingPathComponent(name)) { return name }
        }
        let pdfs = pdfNames(in: folder)
        return pdfs.count == 1 ? pdfs[0] : nil
    }

    static func pdfNames(in folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && $0.lowercased().hasSuffix(".pdf") }.sorted()
    }

    static func categoryKey(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Makes the category table match the manifest (existing rows — the seeded starters —
    /// are updated in place when the name matches case-insensitively; rows the manifest
    /// doesn't list are dropped). Without a manifest the current rows stay. Returns key → pk.
    static func restoreCategories(_ db: isolated Database, manifest: LibraryManifest?) throws -> [String: Int64] {
        var byKey: [String: Int64] = [:]
        let existing = try db.categories()
        guard let manifest else {
            for c in existing { byKey[categoryKey(c.name)] = c.pk }
            return byKey
        }
        var kept = Set<Int64>()
        for entry in manifest.categoryModels() {
            let key = categoryKey(entry.name)
            guard byKey[key] == nil else { continue }
            if var c = existing.first(where: { categoryKey($0.name) == key }) {
                c.name = entry.name
                c.description = entry.description
                c.hue = entry.hue
                c.origin = entry.origin
                c.acknowledged = entry.acknowledged
                c.createdAt = entry.createdAt
                try db.updateCategory(c)
                byKey[key] = c.pk
                kept.insert(c.pk)
            } else {
                let saved = try db.insertCategory(entry)
                byKey[key] = saved.pk
                kept.insert(saved.pk)
            }
        }
        for c in existing where !kept.contains(c.pk) { try db.deleteCategory(pk: c.pk) }
        return byKey
    }

    /// Inserts one paper with its checklist, tags, category (created when unknown — origin
    /// agent, NEW badge), its email provenance (`paper_source` rows from card.json
    /// "provenance"), a succeeded job row carrying the AI provenance card.json keeps, and
    /// the active job a waiting ai_state implies (`AgentQueue.recreateLostJob`).
    static func insert(_ c: Candidate, db: isolated Database, categories: inout [String: Int64], now: Date) throws -> Paper {
        let m = c.sidecar.toModels(folder: c.relativeFolder, fallbackDate: c.folderDate ?? now)
        var p = m.paper
        if let pdf = c.pdfName {
            p.pdfName = pdf
            p.flags.remove(.missing)
        } else {
            p.flags.insert(.missing)
        }
        if c.inRecentlyDeleted {
            if p.deletedAt == nil { p.deletedAt = c.folderDate ?? now }
        } else {
            p.deletedAt = nil
        }
        if let name = PaperOpsSupport.optionalLine(m.categoryName) {
            let key = categoryKey(name)
            if let pk = categories[key] {
                p.categoryPK = pk
            } else {
                let created = try db.insertCategory(PaperCategory(name: name, hue: Taxonomy.nextHue(existing: try db.categories()),
                                                                  origin: .agent, acknowledged: false, createdAt: now))
                categories[key] = created.pk
                p.categoryPK = created.pk
            }
        }
        let saved = try db.insertPaper(p, checklist: m.checklist)
        for source in m.provenance {                               // never touches updated_at
            try db.insertPaperSource(paperPK: saved.pk, source)
        }
        // The reading assist's rows (none touches updated_at): the AI policy, the reading cycles,
        // and "not the same work" decisions with papers already restored (the partner's card
        // lists this paper too, so the pair comes back whichever card is read first).
        if let policy = m.policy { try db.setPaperPolicy(paperPK: saved.pk, policy) }
        for cycle in m.readingCycles { try db.insertReadingCycle(paperPK: saved.pk, cycle) }
        for other in Array(Set(m.distinctFrom + m.relatedTo.map(\.id))).sorted() {
            if let partner = try db.paper(id: other) {
                let related = m.relatedTo.first { $0.id == other }
                try db.setDupPair(saved.pk, partner.pk, decision: related == nil ? "distinct" : "related",
                                  relation: related?.relation, decidedBy: "user", at: now)
            }
        }
        if !m.tags.isEmpty {
            try db.setTags(paperPK: saved.pk, m.tags)
            _ = try db.updatePaper(saved, now: saved.updatedAt)        // setTags touched updated_at; keep the card's
        }
        if saved.card != nil, let provider = m.aiProvider {
            let at = m.aiGeneratedAt ?? saved.updatedAt
            _ = try db.insertJob(AgentJob(paperPK: saved.pk, provider: provider, state: .succeeded, model: m.aiModel,
                                          createdAt: at, startedAt: at, finishedAt: at))
        }
        // card.json only records the paper's ai_state; a waiting state (held / queued / …) needs
        // its active job back, or neither releaseHeld nor the queue would ever see the paper.
        if try AgentQueue.recreateLostJob(for: saved, db: db, providerID: "claude", now: now),
           saved.aiState == .running {
            return try db.paper(pk: saved.pk) ?? saved             // a crash mid-run: back to queued
        }
        return saved
    }

    /// Full-text FTS rows from `support/text/<id>.txt.lzfse` where cached. Returns how many.
    static func indexFullText(_ engine: Engine, _ inserted: [Inserted]) async -> Int {
        let texts = engine.ctx.texts
        var indexed = 0
        for entry in inserted {
            let id = entry.id
            guard let text = await BlockingIO.run({ (try? texts.load(id: id)) ?? nil }), !text.isEmpty else { continue }
            do {
                try await engine.db.indexFullText(pk: entry.pk, text: text)
                indexed += 1
            } catch {
                Log.storage.error("full-text index failed for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return indexed
    }
}

// MARK: - Canonical dump

private struct CanonicalRead: Sendable {
    var papers: [Paper]
    var checklists: [Int64: [ChecklistItem]]
    var tags: [Int64: [Tag]]
    var sources: [Int64: [PaperProvenance]]
    var categories: [PaperCategory]
    var skipDaysJSON: String?
    /// The reading assist's per-paper rows; each key is in the dump only when non-empty, so the
    /// dumps of libraries without them are unchanged.
    var policies: [Int64: PaperPolicy] = [:]
    var cycles: [Int64: [ReadingCycle]] = [:]
    var distinct: [Int64: [String]] = [:]

    private static func s(_ v: String?) -> JSONValue { v.map(JSONValue.string) ?? .null }
    private static func n(_ v: Int?) -> JSONValue { v.map { .number(Double($0)) } ?? .null }
    private static func d(_ v: Date?) -> JSONValue { v.map { .string(Database.timestamp($0)) } ?? .null }
    private static func day(_ v: LocalDate?) -> JSONValue { v.map { .string($0.iso) } ?? .null }

    static func paper(_ p: Paper, category: String?, checklist: [ChecklistItem], tags: [Tag],
                      provenance: [PaperProvenance], policy: PaperPolicy? = nil, cycles: [ReadingCycle] = [],
                      distinctFrom: [String] = []) throws -> JSONValue {
        let items = checklist.sorted { ($0.ord, $0.id) < ($1.ord, $1.id) }.map { i -> JSONValue in
            .object(["id": .string(i.id), "ord": .number(i.ord), "text": .string(i.text), "section": s(i.section),
                     "page": n(i.page), "minutes": n(i.minutes), "kind": .string(i.kind.rawValue),
                     "origin": .string(i.origin.rawValue), "userEdited": .bool(i.userEdited), "doneAt": d(i.doneAt)])
        }
        let tagValues = tags.sorted { ($0.name.lowercased(), $0.origin.rawValue) < ($1.name.lowercased(), $1.origin.rawValue) }
            .map { JSONValue.object(["name": .string($0.name), "origin": .string($0.origin.rawValue)]) }
        let sources = provenance.map { v -> JSONValue in
            .object(["kind": .string(v.kind), "mailMessageID": s(v.mailMessageID),
                     "internetMessageID": s(v.internetMessageID), "fromAddress": s(v.fromAddress),
                     "fromName": s(v.fromName), "subject": s(v.subject), "receivedAt": d(v.receivedAt),
                     "webLink": s(v.webLink), "requestKind": s(v.requestKind?.rawValue), "summary": s(v.summary),
                     "dueHint": day(v.dueHint), "addedAt": d(v.addedAt)])
        }
        var extra: [String: JSONValue] = [:]
        if let policy, !policy.isEmpty {
            extra["policy"] = .object(["confidential": .bool(policy.confidential), "neverAI": .bool(policy.neverAI),
                                       "setBy": .string(policy.setBy.rawValue), "setAt": d(policy.setAt)])
        }
        if !cycles.isEmpty {
            extra["readingCycles"] = .array(cycles.sorted { $0.n < $1.n }.map {
                .object(["n": n($0.n), "startedAt": d($0.startedAt), "doneAt": d($0.doneAt), "reason": s($0.reason)])
            })
        }
        // `Database.dupPairPartnerIDs`: the partners' ids, then the related pairs' entries.
        let related = distinctFrom.compactMap(CardSidecar.relatedPartner)
        let partners = distinctFrom.filter { CardSidecar.relatedPartner($0) == nil }
        if !partners.isEmpty { extra["distinctFrom"] = .array(partners.sorted().map(JSONValue.string)) }
        if !related.isEmpty {
            extra["relatedTo"] = .array(related.sorted { $0.id < $1.id }.map {
                .object(["id": .string($0.id), "relation": s($0.relation)])
            })
        }
        return .object(extra.merging([
            "id": .string(p.id), "sha256": .string(p.sha256), "fileSize": .number(Double(p.fileSize)),
            "doi": s(p.ids.doi), "publishedDoi": s(p.ids.publishedDOI), "arxivID": s(p.ids.arxivID),
            "arxivVersion": n(p.ids.arxivVersion), "pii": s(p.ids.pii),
            "title": .string(p.title), "titleRank": n(p.titleRank.rawValue), "authors": .array(p.authors.map(JSONValue.string)),
            "year": n(p.year), "venue": s(p.venue), "abstract": s(p.abstract), "metaSource": .string(p.metaSource.rawValue),
            "metaUserEdited": .bool(p.metaUserEdited), "pageCount": n(p.pageCount), "charCount": n(p.charCount),
            "flags": n(p.flags.rawValue), "folder": .string(p.folder), "pdfName": .string(p.pdfName),
            "originalName": .string(p.originalName), "nameFinal": .bool(p.nameFinal), "stage": .string(p.stage.rawValue),
            "status": .string(p.status.rawValue), "priority": n(p.priority.rawValue), "deadline": day(p.deadline),
            "scheduleMode": .string(p.scheduleMode.rawValue), "deadlineOrigin": .string(p.deadlineOrigin.rawValue),
            "queueRank": n(p.queueRank), "placementFloor": day(p.placementFloor), "provisional": .bool(p.provisional),
            "estMinutes": n(p.estMinutes), "estSource": .string(p.estSource.rawValue), "category": s(category),
            "categoryUserSet": .bool(p.categoryUserSet), "needsReview": .bool(p.needsReview), "tldr": s(p.tldr),
            "card": try p.card.map { try JSONValue.from($0) } ?? .null, "cardVersion": n(p.cardVersion),
            "textQuality": s(p.textQuality?.rawValue), "aiState": .string(p.aiState.rawValue), "aiNote": s(p.aiNote),
            "aiSeen": .bool(p.aiSeen), "notes": .string(p.notes), "addedAt": d(p.addedAt), "openedAt": d(p.openedAt),
            "doneAt": d(p.doneAt), "deletedAt": d(p.deletedAt),
            "checklist": .array(items), "tags": .array(tagValues), "provenance": .array(sources),
        ], uniquingKeysWith: { _, column in column }))
    }

    static func category(_ c: PaperCategory) -> JSONValue {
        .object(["name": .string(c.name), "description": s(c.description), "hue": n(c.hue),
                 "origin": .string(c.origin.rawValue), "acknowledged": .bool(c.acknowledged), "createdAt": d(c.createdAt)])
    }
}
