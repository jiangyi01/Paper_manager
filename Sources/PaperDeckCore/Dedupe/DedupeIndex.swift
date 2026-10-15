import Foundation

/// What the library has that `DupDetector` matched.
package struct DupMatch: Sendable {
    package var candidate: DupCandidate
    /// The paper (live or in Recently Deleted); nil when a tombstone matched.
    package var existing: Paper?
    package var history: DupHistoryRow?

    /// The band a review gets: a removed paper that was never read only earns a chip (nothing
    /// to remember about it worth holding a new import for).
    package var reviewBand: DupBand {
        if existing == nil, let h = history, h.readCount == 0, h.doneAt == nil { return .possible }
        return candidate.band
    }
}

/// Candidate retrieval for the duplicate check (dive-dedupe §4.1): identity tokens through
/// `paper_key` and the id columns (live and Recently Deleted papers), FTS5 bm25 on the title
/// (and on the full text for a paper without a usable title), and the tombstones — never an N²
/// pass. Signatures come from `paper_fingerprint`, computed from the text cache when missing.
package enum DedupeIndex {
    /// Fuzzy candidates per query (title, then text).
    package static let titleCandidates = 20
    package static let textCandidates = 10

    /// The detector's view of a paper row: its stored keys, its fingerprint (computed and stored
    /// when missing or computed from another file — unless `computeMissing` is false: then it is
    /// compared without its page text), its abstract signature.
    package static func subject(for p: Paper, ctx: EngineContext, storedKeys: [DupKey]? = nil,
                                fingerprint: (page: [UInt32]?, abstract: [UInt32]?, sha256Prefix: String?)?? = nil,
                                computeMissing: Bool = true) async -> DupSubject {
        let db = ctx.db
        let keys: [DupKey]
        if let storedKeys { keys = storedKeys } else { keys = (try? await db.dupKeys(paperPK: p.pk)) ?? [] }
        let fp: (page: [UInt32]?, abstract: [UInt32]?, sha256Prefix: String?)?
        if let fingerprint { fp = fingerprint } else {
            fp = (try? await db.dupFingerprint(paperPK: p.pk)).flatMap { $0.map { ($0.page, $0.abstract, $0.sha256Prefix) } }
        }
        let stale = isStale(fp, sha256: p.sha256)
        var subject = DupSubject.paper(p, storedKeys: keys)
        if stale {
            guard computeMissing else {
                subject.page = nil
                return subject
            }
            let texts = ctx.texts, id = p.id
            let text = await BlockingIO.run { (try? texts.load(id: id)) ?? nil }
            subject.page = text.flatMap { MinHash.pageSignature(pages: $0.components(separatedBy: "\u{0C}")) }
            try? await db.upsertDupFingerprint(paperPK: p.pk, subject: subject, sha256: p.sha256,
                                               sourceUpdatedAt: p.updatedAt, now: ctx.now())
        } else {
            subject.page = fp?.page
        }
        return subject
    }

    /// The stored fingerprint is missing, or was computed from another file.
    static func isStale(_ fp: (page: [UInt32]?, abstract: [UInt32]?, sha256Prefix: String?)?, sha256: String) -> Bool {
        guard let fp else { return true }
        return fp.sha256Prefix != nil && fp.sha256Prefix != String(sha256.lowercased().prefix(16))
    }

    /// The subject of a file being imported (not committed): its local ids, the PDF's title when
    /// it is better than the file name, the Author attribute's surnames, the page-1 signature.
    package static func stagedSubject(sha256: String, ids: PaperIDs, title: String, titleRank: TitleRank,
                                      fileName: String, extracted: ExtractedPDF?) -> DupSubject {
        let usable = titleRank >= .pdfAttribute ? title : ""
        var s = DupSubject(sha256: sha256, keys: DupKeys.local(ids), doi: ids.doi, title: usable,
                           surnames: DedupeText.attributeSurnames(extracted?.attributeAuthor),
                           pages: extracted?.pageCount, kind: DedupeText.kind(title: usable, fileName: fileName),
                           rank: VersionRank.of(ids: ids, venue: nil, fileName: fileName),
                           page: extracted.flatMap { MinHash.pageSignature(pages: $0.pageTexts) }, fileName: fileName)
        if usable.isEmpty { s.kind = DedupeText.isSupplementFileName(fileName) ? .supplement : .article }
        return s
    }

    /// The DOIs to look up in the id columns for `ids` (both bioRxiv prefixes, the published DOI).
    package static func columnDOIs(_ ids: PaperIDs, extra: [String] = []) -> [String] {
        var out: [String] = []
        for d in [ids.doi, ids.publishedDOI] + extra.map(Optional.some) {
            for x in Database.sameWorkDOIs(d) where !out.contains(x) { out.append(x) }
        }
        return out
    }

    /// The best match for `n` in the library: identity first (live and deleted papers, then
    /// tombstones), then — with `fuzzy` — the bm25 candidates and the tombstones' titles.
    /// `excluding` is `n`'s own paper; pairs the user (or the judge) already decided about it
    /// are skipped. `ids` / `extraDOIs` feed the id-column lookup; `pages` (a file without a
    /// usable title) adds full-text candidates. `computeMissing`: how many candidates without a
    /// stored fingerprint may have it computed here (their text read and hashed); the others are
    /// compared without their page text. The import passes a few (it runs inside the commit lock,
    /// after `prepare` computed them outside it); the library check computes them all.
    /// `liveOnly` (Check for Duplicates, `--dedupe-report`): only live papers are candidates — a
    /// copy in Recently Deleted (or a tombstone) that would win the match must not hide a live
    /// twin. Intake and mail lookups leave it off, so they still find Recently Deleted copies.
    package static func match(_ n: DupSubject, ids: PaperIDs, extraDOIs: [String] = [], excluding pk: Int64?,
                              settings: DedupeSettings, ctx: EngineContext, fuzzy: Bool = true,
                              pages: [String]? = nil, computeMissing: Int = .max,
                              liveOnly: Bool = false) async -> DupMatch? {
        let db = ctx.db
        await backfillOnce(db)
        var decided: Set<[Int64]> = []
        if let pk { decided = (try? await db.decidedPairs(involving: [pk])) ?? [] }
        func isDecided(_ other: Int64) -> Bool {
            guard let pk else { return false }
            return decided.contains([min(pk, other), max(pk, other)])
        }

        var best: DupMatch?
        var budget = computeMissing
        func consider(_ e: DupSubject, paper: Paper?, history: DupHistoryRow?) {
            guard let c = DupDetector.compare(n, e, sensitivity: settings.sensitivity) else { return }
            if best == nil || c.beats(best!.candidate) { best = DupMatch(candidate: c, existing: paper, history: history) }
        }
        func considerPapers(_ pks: [Int64]) async {
            guard !pks.isEmpty else { return }
            let papers = (try? await db.papers(pks: pks)) ?? []
            let keys = (try? await db.dupKeys(paperPKs: pks)) ?? [:]
            let prints = (try? await db.dupFingerprints(paperPKs: pks)) ?? [:]
            // In candidate order (identity, then best bm25 first): the budget goes to the likeliest.
            let order = Dictionary(pks.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            for p in papers.sorted(by: { (order[$0.pk] ?? 0) < (order[$1.pk] ?? 0) })
            where !isDecided(p.pk) && (!liveOnly || p.isLive) {
                let fp: (page: [UInt32]?, abstract: [UInt32]?, sha256Prefix: String?)?? = .some(prints[p.pk])
                let compute = budget > 0 && isStale(prints[p.pk], sha256: p.sha256)
                if compute { budget -= 1 }
                consider(await subject(for: p, ctx: ctx, storedKeys: keys[p.pk] ?? [], fingerprint: fp, computeMissing: compute),
                         paper: p, history: nil)
            }
        }

        // 1. Identity: tokens and id columns (live + Recently Deleted).
        let tokens = Array(n.keys.keys).sorted()
        let dois = columnDOIs(ids, extra: extraDOIs)
        let identityPKs = (try? await db.paperPKs(holdingTokens: tokens, dois: dois, arxivID: ids.arxivID,
                                                 excluding: pk)) ?? []
        var seen = Set(identityPKs)
        if let pk { seen.insert(pk) }
        await considerPapers(identityPKs)
        if let b = best, b.candidate.band == .certain { return b }

        // 2. Tombstones with the bytes or an identity token.
        if settings.history, !liveOnly {
            let rows = (try? await db.historyMatching(sha256: n.sha256, tokens: tokens, dois: dois,
                                                      arxivID: ids.arxivID)) ?? []
            for h in rows { consider(h.subject, paper: nil, history: h) }
            if let b = best, b.candidate.band == .certain { return b }
        }
        guard fuzzy else { return best }

        // 3. Fuzzy: bm25 on the title; on the text when there is no usable title.
        let fuzzyPKs = await fuzzyCandidates(n, excluding: pk, pages: pages, db: db).filter { seen.insert($0).inserted }
        await considerPapers(fuzzyPKs)

        // 4. Tombstones by title (the table is small: metadata of removed papers only). Their
        // normalized titles are read alone and filtered by a cheap bound of the title score
        // (`TitleBound`, D6) and the detector's "contained" rule (D6-1); only the few that can
        // still match — at most `historyTitleHitLimit` — are loaded and compared.
        if settings.history, !liveOnly, !n.titleNorm.isEmpty {
            let titles = (try? await db.historyTitles(limit: historyTitleLimit)) ?? []
            let picked = tombstoneTitleHits(n.titleNorm, among: titles)
            for h in (try? await db.historyRows(pks: picked)) ?? [] { consider(h.subject, paper: nil, history: h) }
        }
        return best
    }

    /// The most recent tombstones the title scan reads.
    package static let historyTitleLimit = 500
    /// A tombstone's title is compared when the score could reach this.
    package static let historyTitleThreshold = 0.85
    /// At most this many tombstones are loaded and compared inside the commit lock (the best titles).
    package static let historyTitleHitLimit = 12

    /// The tombstones (pk, normalized title) whose title is `titleNorm` with a subtitle added or cut
    /// (`DedupeText.prefixContained`, the detector's own "contained" rule) or scores ≥
    /// `historyTitleThreshold` with it — the full score only for the few `TitleBound` lets through.
    /// In input order; when more than `historyTitleHitLimit` qualify, the best-scoring ones.
    ///
    /// D6-1: a 10-character prefix used to let every tombstone that merely *starts* like the new
    /// title through unscored ("single cell…", "the role of…": a fifth of a focused lab's removed
    /// papers), and each of those was loaded and compared inside the commit lock (~0.2 ms each).
    /// Now a shared opening only counts when the whole shorter title is the longer one's start —
    /// the only way such a title can still match (`DupDetector`'s `contained`).
    package static func tombstoneTitleHits(_ titleNorm: String, among titles: [(pk: Int64, titleNorm: String)]) -> [Int64] {
        guard !titleNorm.isEmpty else { return [] }
        let head = String(titleNorm.prefix(10))
        let query = TitleProfile(titleNorm)
        let cache = TitleProfileCache.shared
        var picked: [(pk: Int64, score: Double, order: Int)] = []
        for (i, (hpk, norm)) in titles.enumerated() where !norm.isEmpty {
            // Cheap first: a truncated / subtitled title shares the opening characters (either way round).
            if norm.hasPrefix(head) || head.hasPrefix(norm), DedupeText.prefixContained(titleNorm, norm) {
                picked.append((hpk, TitleSimilarity.score(titleNorm, norm), i))
            } else if TitleBound.mayReach(query, cache.profile(norm), historyTitleThreshold) {
                let score = TitleSimilarity.score(titleNorm, norm)
                if score >= historyTitleThreshold { picked.append((hpk, score, i)) }
            }
        }
        if picked.count > historyTitleHitLimit {
            picked = Array(picked.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
                .prefix(historyTitleHitLimit)).sorted { $0.order < $1.order }
        }
        return picked.map(\.pk)
    }

    /// The papers (live or Recently Deleted, never tombstones) that `n` matches, best first, at
    /// most `limit` — the AI judge's extra candidates. Pairs already decided are skipped.
    package static func paperMatches(_ n: DupSubject, ids: PaperIDs, excluding pk: Int64?, settings: DedupeSettings,
                                     ctx: EngineContext, limit: Int) async -> [DupMatch] {
        let db = ctx.db
        await backfillOnce(db)
        var decided: Set<[Int64]> = []
        if let pk { decided = (try? await db.decidedPairs(involving: [pk])) ?? [] }
        var pks = (try? await db.paperPKs(holdingTokens: Array(n.keys.keys).sorted(), dois: columnDOIs(ids),
                                          arxivID: ids.arxivID, excluding: pk)) ?? []
        for other in await fuzzyCandidates(n, excluding: pk, pages: nil, db: db) where !pks.contains(other) { pks.append(other) }
        pks.removeAll { other in pk.map { decided.contains([min($0, other), max($0, other)]) } ?? false }
        guard !pks.isEmpty, limit > 0 else { return [] }
        let papers = (try? await db.papers(pks: pks)) ?? []
        let keys = (try? await db.dupKeys(paperPKs: pks)) ?? [:]
        let prints = (try? await db.dupFingerprints(paperPKs: pks)) ?? [:]
        var found: [DupMatch] = []
        for p in papers {
            let fp: (page: [UInt32]?, abstract: [UInt32]?, sha256Prefix: String?)?? = .some(prints[p.pk])
            let e = await subject(for: p, ctx: ctx, storedKeys: keys[p.pk] ?? [], fingerprint: fp, computeMissing: false)
            if let c = DupDetector.compare(n, e, sensitivity: settings.sensitivity) {
                found.append(DupMatch(candidate: c, existing: p, history: nil))
            }
        }
        return Array(found.sorted { $0.candidate.beats($1.candidate) }.prefix(limit))
    }

    /// The fuzzy candidates of `n`: bm25 on its title; on its text when it has no usable title.
    static func fuzzyCandidates(_ n: DupSubject, excluding pk: Int64?, pages: [String]?, db: Database) async -> [Int64] {
        let titleTokens = n.title.isEmpty ? [] : DedupeText.queryTokens(n.title)
        var out = (try? await db.dedupeTitleCandidates(tokens: titleTokens, excluding: pk, limit: titleCandidates)) ?? []
        if titleTokens.count < 3, let pages {
            out += await textCandidates(pages: pages, excluding: pk, db: db)
        }
        return out
    }

    /// Before the commit lock (`IntakeActor`): the identity keys of older papers, and the
    /// fingerprints the import's `match` will want — of its identity and fuzzy candidates — computed
    /// and stored now, so the check inside the lock only reads them (a library imported by an
    /// older build has none). Returns how many fingerprints it computed.
    @discardableResult
    package static func prepare(_ n: DupSubject, ids: PaperIDs, ctx: EngineContext, pages: [String]? = nil) async -> Int {
        let db = ctx.db
        await backfillOnce(db)
        var pks = (try? await db.paperPKs(holdingTokens: Array(n.keys.keys).sorted(), dois: columnDOIs(ids),
                                          arxivID: ids.arxivID, excluding: nil)) ?? []
        for pk in await fuzzyCandidates(n, excluding: nil, pages: pages, db: db) where !pks.contains(pk) { pks.append(pk) }
        guard !pks.isEmpty else { return 0 }
        let prints = (try? await db.dupFingerprints(paperPKs: pks)) ?? [:]
        var computed = 0
        for p in (try? await db.papers(pks: pks)) ?? [] where isStale(prints[p.pk], sha256: p.sha256) {
            _ = await subject(for: p, ctx: ctx, fingerprint: .some(prints[p.pk]))
            computed += 1
        }
        return computed
    }

    /// Identity keys for papers imported before the check (or by an older build): once per
    /// database per launch, not on every import.
    package static func backfillOnce(_ db: Database) async {
        guard BackfilledDatabases.shared.claim(db) else { return }
        do { try await db.backfillLocalDupKeys() } catch {
            BackfilledDatabases.shared.release(db)
            Log.db.error("dedupe key backfill failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Text-only candidates for a file without a usable title: the rarest-looking words of its
    /// first page against the full-text index (best bm25 first).
    package static func textCandidates(pages: [String], excluding pk: Int64?, db: Database) async -> [Int64] {
        let words = MinHash.bodyWords(pages: pages).prefix(400)
        var picked: [String] = []
        for w in Set(words).sorted(by: { $0.count != $1.count ? $0.count > $1.count : $0 < $1 })
        where w.count >= 7 && !w.allSatisfy(\.isNumber) {
            picked.append(w)
            if picked.count == 16 { break }
        }
        return (try? await db.dedupeTextCandidates(tokens: picked, excluding: pk, limit: textCandidates)) ?? []
    }
}

/// The databases whose identity keys were backfilled in this process (held weakly).
private final class BackfilledDatabases: @unchecked Sendable {
    static let shared = BackfilledDatabases()

    private let lock = NSLock()
    private let done = NSHashTable<AnyObject>.weakObjects()

    /// True the first time for `db` (the caller backfills).
    func claim(_ db: Database) -> Bool {
        lock.withLock {
            if done.contains(db) { return false }
            done.add(db)
            return true
        }
    }

    func release(_ db: Database) { lock.withLock { done.remove(db) } }
}
