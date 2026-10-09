import Foundation

/// One side of a comparison: a paper (live or Recently Deleted), a file being imported, or a
/// removed paper's tombstone. Everything the pure detector reads.
package struct DupSubject: Sendable, Equatable {
    package var paperPK: Int64?
    package var paperID: String?
    package var historyPK: Int64?
    package var sha256: String?
    /// Identity token → the kinds this side holds it as.
    package var keys: [String: Set<DupKey.Kind>]
    /// Its own (normalized) DOI: two different final DOIs are rarely one work.
    package var doi: String?
    package var title: String
    package var titleNorm: String
    package var surnames: [String]
    package var year: Int?
    package var pages: Int?
    package var venue: String?
    package var kind: DupKind
    package var rank: VersionRank
    /// Page-1 and abstract MinHash signatures.
    package var page: [UInt32]?
    package var abstract: [UInt32]?
    package var addedAt: Date?
    package var isDeleted: Bool
    package var fileName: String?

    package init(paperPK: Int64? = nil, paperID: String? = nil, historyPK: Int64? = nil, sha256: String? = nil,
                 keys: [DupKey] = [], doi: String? = nil, title: String, surnames: [String] = [], year: Int? = nil,
                 pages: Int? = nil, venue: String? = nil, kind: DupKind? = nil, rank: VersionRank = VersionRank(tier: .unknown),
                 page: [UInt32]? = nil, abstract: [UInt32]? = nil, addedAt: Date? = nil, isDeleted: Bool = false,
                 fileName: String? = nil) {
        self.paperPK = paperPK; self.paperID = paperID; self.historyPK = historyPK; self.sha256 = sha256?.lowercased()
        var map: [String: Set<DupKey.Kind>] = [:]
        for k in keys { map[k.value, default: []].insert(k.kind) }
        self.keys = map
        self.doi = MetadataClients.normalizeDOI(doi)
        self.title = title; self.titleNorm = DedupeText.titleNorm(title); self.surnames = surnames; self.year = year
        self.pages = pages; self.venue = venue
        self.kind = kind ?? DedupeText.kind(title: title, fileName: fileName)
        self.rank = rank; self.page = page; self.abstract = abstract; self.addedAt = addedAt
        self.isDeleted = isDeleted; self.fileName = fileName
    }

    /// A paper row plus its stored keys and fingerprint signatures.
    package static func paper(_ p: Paper, storedKeys: [DupKey] = [], page: [UInt32]? = nil,
                              abstract: [UInt32]? = nil, workType: String? = nil,
                              relations: [WorkRelation] = []) -> DupSubject {
        let keys = DupKeys.local(p.ids) + storedKeys.filter { $0.source != .local }
        return DupSubject(paperPK: p.pk, paperID: p.id, sha256: p.sha256, keys: keys, doi: p.ids.doi, title: p.title,
                          surnames: DedupeText.surnames(p.authors), year: p.year, pages: p.pageCount, venue: p.venue,
                          kind: DedupeText.kind(title: p.title, fileName: p.originalName, workType: workType,
                                                relations: relations),
                          rank: VersionRank.of(ids: p.ids, venue: p.venue, workType: workType, fileName: p.originalName),
                          page: page, abstract: abstract ?? MinHash.abstractSignature(p.abstract), addedAt: p.addedAt,
                          isDeleted: p.isDeleted, fileName: p.originalName)
    }
}

/// What the detector concluded about one pair.
package struct DupCandidate: Sendable, Equatable {
    package var band: DupBand
    package var relation: DupRelation
    /// 0…1, for ranking candidates only (never shown).
    package var score: Double
    package var evidence: [DupEvidence]
    package var newerSide: DupSide?

    package init(band: DupBand, relation: DupRelation, score: Double, evidence: [DupEvidence], newerSide: DupSide?) {
        self.band = band; self.relation = relation; self.score = score; self.evidence = evidence; self.newerSide = newerSide
    }

    /// Stronger band first, then the higher score.
    package func beats(_ other: DupCandidate) -> Bool {
        band != other.band ? band > other.band : score > other.score
    }
}

/// The rules (DQ §3.3, dive-dedupe §3), pure and explainable: identity first (shared bytes or
/// an identity token → certain), then hard vetoes (numbers and series, notices, comments,
/// supplements, generic titles, two different final DOIs), then the fuzzy bands.
package enum DupDetector {
    /// Thresholds of one sensitivity (Balanced = DQ's initial values).
    package struct Thresholds: Sendable, Equatable {
        package var title: Double         // added to every title threshold
        package var text: Double          // added to every text threshold

        package static func of(_ s: DedupeSettings.Sensitivity) -> Thresholds {
            switch s {
            case .strict: return Thresholds(title: 0.02, text: 0.05)
            case .balanced: return Thresholds(title: 0, text: 0)
            case .loose: return Thresholds(title: -0.02, text: -0.05)
            }
        }
    }

    /// How `n` (the new item) relates to `e` (what the library has or had); nil: not a duplicate.
    package static func compare(_ n: DupSubject, _ e: DupSubject,
                                sensitivity: DedupeSettings.Sensitivity = .balanced) -> DupCandidate? {
        if let a = n.sha256, let b = e.sha256, !a.isEmpty, a == b {
            return DupCandidate(band: .certain, relation: .sameFile, score: 1, evidence: [DupEvidence(.sameFile)],
                                newerSide: nil)
        }
        if let identity = identity(n, e) { return identity }
        return fuzzy(n, e, t: Thresholds.of(sensitivity))
    }

    /// The best match of `n` among `candidates` (stronger band, then higher score).
    package static func best(_ n: DupSubject, among candidates: [DupSubject],
                             sensitivity: DedupeSettings.Sensitivity = .balanced) -> (subject: DupSubject, candidate: DupCandidate)? {
        var best: (DupSubject, DupCandidate)?
        for e in candidates {
            guard let c = compare(n, e, sensitivity: sensitivity) else { continue }
            if best == nil || c.beats(best!.1) { best = (e, c) }
        }
        return best
    }

    // MARK: Identity

    private static func identity(_ n: DupSubject, _ e: DupSubject) -> DupCandidate? {
        let shared = Set(n.keys.keys).intersection(e.keys.keys)
        guard !shared.isEmpty else { return nil }
        var evidence: [DupEvidence] = []
        func add(_ ev: DupEvidence) { if !evidence.contains(where: { $0.code == ev.code }) { evidence.append(ev) } }
        for token in shared.sorted() {
            let a = n.keys[token] ?? [], b = e.keys[token] ?? []
            if token.hasPrefix("arxiv:") {
                add(DupEvidence(.arxiv, value: String(token.dropFirst(6))))
            } else if token.hasPrefix("openalex:") {
                add(DupEvidence(.openAlex, value: String(token.dropFirst(9)).uppercased()))
            } else if a.contains(.doi) && b.contains(.doi) {
                if let x = n.doi, let y = e.doi, x != y { add(DupEvidence(.doiFamily, value: y)) }
                else { add(DupEvidence(.sharedDOI, value: n.doi ?? e.doi)) }
            } else if a.contains(.publishedDOI) || b.contains(.publishedDOI) {
                add(DupEvidence(.publishedDOI, value: a.contains(.doi) ? n.doi : (b.contains(.doi) ? e.doi : nil)))
            } else {
                add(DupEvidence(.preprintLink, value: a.contains(.doi) ? n.doi : (b.contains(.doi) ? e.doi : nil)))
            }
        }
        // OpenAlex merges works by itself (and sometimes wrongly): on its own it is only "likely".
        let onlyOpenAlex = shared.allSatisfy { $0.hasPrefix("openalex:") }
        let band: DupBand = onlyOpenAlex ? .likely : .certain
        var newer = VersionRank.newer(new: n.rank, existing: e.rank)

        // Two copies of one notice, comment or review file (the same kind on both sides) are two
        // copies, not a notice of each other.
        let kind = n.kind == e.kind && relatedKinds.contains(n.kind) ? .article : n.kind
        // A supplement, a review file or a short insert printing the paper's identifier (a News &
        // Views piece, a research briefing) is not the paper.
        if kind == .supplement || kind == .review || shortInsert(n, of: e, shortIsNewer: newer == .new) {
            if kind == .supplement || kind == .review { evidence.append(DupEvidence(.supplement)) }
            return DupCandidate(band: band, relation: .supplement, score: 0.99, evidence: evidence, newerSide: .existing)
        }
        if kind == .notice {
            evidence.append(DupEvidence(.notice))
            return DupCandidate(band: band, relation: .correction, score: 0.99, evidence: evidence, newerSide: .existing)
        }
        if kind == .comment {
            evidence.append(DupEvidence(.comment))
            return DupCandidate(band: band, relation: .comment, score: 0.99, evidence: evidence, newerSide: .existing)
        }
        // What the library has is a notice, a comment, a review file, a supplement or a short insert
        // printing this paper's identifier (imported first): the paper itself is the one to keep.
        let fullPaper = n.kind == .article || (n.kind == .generic && (n.pages ?? 0) >= 8)
        if fullPaper,
           relatedKinds.contains(e.kind) || e.kind == .supplement || shortInsert(e, of: n, shortIsNewer: newer == .existing) {
            newer = .new
        }
        let relation: DupRelation
        switch newer {
        case .new: relation = .newerVersion
        case .existing: relation = .olderVersion
        case nil: relation = sameVersion(n, e, pageX: MinHash.jaccard(n.page, e.page)) ? .sameVersion : .sameWork
        }
        return DupCandidate(band: band, relation: relation, score: onlyOpenAlex ? 0.9 : 0.99, evidence: evidence,
                            newerSide: newer)
    }

    /// Kinds that are about a paper rather than the paper.
    private static let relatedKinds: Set<DupKind> = [.notice, .comment, .review]

    /// `s` is a short insert of `l`: 1–3 pages printing the identifier of an 8+ page paper. Not when
    /// it is the paper's own short version — a newer version (an application note, a brief
    /// communication over its preprint) of 2+ pages under the same title.
    static func shortInsert(_ s: DupSubject, of l: DupSubject, shortIsNewer: Bool) -> Bool {
        guard let sp = s.pages, sp <= 3, (l.pages ?? 0) >= 8, s.kind == .article || s.kind == .generic else { return false }
        if shortIsNewer, sp >= 2, sameTitle(s, l) { return false }
        return true
    }

    /// Two real titles that name one work (the same words, or one is the other plus a subtitle).
    static func sameTitle(_ a: DupSubject, _ b: DupSubject) -> Bool {
        guard !a.titleNorm.isEmpty, !b.titleNorm.isEmpty, a.kind != .generic, b.kind != .generic else { return false }
        return a.titleNorm == b.titleNorm || DedupeText.prefixContained(a.titleNorm, b.titleNorm)
            || TitleSimilarity.score(a.titleNorm, b.titleNorm) >= 0.9
    }

    /// "The same version" is a fact only when both versions are known and equal, or the text is
    /// the same (≥ 0.9 page overlap); otherwise it is "the same work" (DQ §3.4).
    static func sameVersion(_ n: DupSubject, _ e: DupSubject, pageX: Double?) -> Bool {
        VersionRank.sameVersion(n.rank, e.rank) || (pageX ?? 0) >= 0.9
    }

    /// Fuzzy matches need both: known-equal versions AND near-identical page text. Two different
    /// works that happen to be v1 each must stay "same work", not "another copy".
    static func sameVersionFuzzy(_ n: DupSubject, _ e: DupSubject, pageX: Double?) -> Bool {
        VersionRank.sameVersion(n.rank, e.rank) && (pageX ?? 0) >= 0.9
    }

    // MARK: Fuzzy

    private static func fuzzy(_ n: DupSubject, _ e: DupSubject, t th: Thresholds) -> DupCandidate? {
        guard !n.titleNorm.isEmpty || n.page != nil else { return nil }

        // Two notices, comments or review files: their titles name the paper they are about (two
        // corrections of one paper share it), so only their text can say they are one document.
        let sameRelatedKind = n.kind == e.kind && relatedKinds.contains(n.kind)
        if !sameRelatedKind {
            // Notices and comments are never the same work: at most "related" to their target.
            if n.kind == .notice || n.kind == .comment {
                guard let target = DedupeText.noticeTarget(n.title), e.kind == .article else { return nil }
                let targetScore = TitleSimilarity.score(target, e.title)
                guard targetScore >= 0.92 + th.title else { return nil }
                let pct = Int((targetScore * 100).rounded())
                return DupCandidate(band: .possible, relation: n.kind == .notice ? .correction : .comment, score: 0.6,
                                    evidence: [DupEvidence(n.kind == .notice ? .notice : .comment), DupEvidence(.title, percent: pct)],
                                    newerSide: nil)
            }
            if relatedKinds.contains(e.kind) || n.kind == .review { return nil }
        }
        // A supplement with no shared identifier: not a duplicate of anything.
        if n.kind == .supplement || e.kind == .supplement { return nil }

        let pageX = MinHash.jaccard(n.page, e.page)
        let absX = MinHash.jaccard(n.abstract, e.abstract)
        // The cheap way out first (most candidates): no title word in common and no shared text
        // — no rule below can fire (every title rule needs T ≥ 0.70, every text rule X ≥ 0.35).
        if max(pageX ?? 0, absX ?? 0) < 0.35, !DedupeText.shareAWord(n.titleNorm, e.titleNorm) { return nil }
        // Normalized already: the score's own normalization is then cheap and changes nothing.
        let titleScore = n.titleNorm.isEmpty || e.titleNorm.isEmpty ? 0 : TitleSimilarity.score(n.titleNorm, e.titleNorm)

        let generic = n.kind == .generic || e.kind == .generic || sameRelatedKind
        let cjk = DedupeText.isCJK(n.title) || DedupeText.isCJK(e.title)
        // A thesis vs a paper from it.
        if let a = n.pages, let b = e.pages, max(a, b) >= 60, min(a, b) < 40 { return nil }
        // Numbers, series numerals, species… differ: two members of one family — no title rule
        // applies (the same page text still counts: a junk title doesn't make it another paper).
        let familyVeto = !generic && !DedupeText.sameDiscriminators(n.titleNorm, e.titleNorm)

        let firstAuthor = n.surnames.first.map { $0 == e.surnames.first } ?? false
        let overlap: Double? = {
            guard !n.surnames.isEmpty, !e.surnames.isEmpty else { return nil }
            let common = Set(n.surnames).intersection(e.surnames).count
            return Double(common) / Double(min(n.surnames.count, e.surnames.count))
        }()
        let dy: Int? = { guard let a = n.year, let b = e.year else { return nil }; return abs(a - b) }()
        let preprintSide = n.rank.tier == .preprint || e.rank.tier == .preprint
        let yearOK = dy.map { $0 <= (preprintSide ? 2 : 1) } ?? true
        let x: Double? = [pageX, absX].compactMap { $0 }.max()
        let o = overlap ?? 0, xv = x ?? 0
        // A title match counts only for real, comparable titles (CJK: stricter).
        let titleOK = !generic && !familyVeto && !n.titleNorm.isEmpty && !e.titleNorm.isEmpty
        let tq = titleOK ? titleScore - (cjk ? 0.03 : 0) : 0
        let contained = titleOK && DedupeText.prefixContained(n.titleNorm, e.titleNorm)

        var band: DupBand?
        if (tq >= 0.97 + th.title && firstAuthor && yearOK)
            || (tq >= 0.92 + th.title && o >= 0.6 && yearOK && xv >= 0.4 + th.text)
            || (xv >= 0.8 + th.text && o >= 0.5)
            // At intake the authors are rarely known: the same title over mostly the same text.
            || (xv >= 0.8 + th.text && tq >= 0.92 + th.title && yearOK) {
            band = .likely
        } else if ((tq >= 0.92 + th.title || contained) && (firstAuthor || o >= 0.5) && (dy ?? 0) <= 3)
                    || (tq >= 0.70 + th.title && o >= 0.6 && yearOK && xv >= 0.5 + th.text)
                    || (generic && (pageX ?? 0) >= 0.9 + th.text) {
            band = .possible
        }
        guard var found = band else { return nil }

        // Two different final DOIs with no link between them: rarely one work, so never more than possible.
        if let a = n.doi, let b = e.doi, a != b, n.rank.tier == .published, e.rank.tier == .published,
           DOIFamily.key(a) != DOIFamily.key(b), found == .likely {
            found = .possible
        }

        var evidence: [DupEvidence] = []
        if titleOK, titleScore >= 0.5 { evidence.append(DupEvidence(.title, percent: Int((titleScore * 100).rounded()))) }
        if firstAuthor, let s = n.surnames.first { evidence.append(DupEvidence(.firstAuthor, value: s)) }
        if overlap != nil, n.surnames.count > 1 || e.surnames.count > 1 {
            let common = Set(n.surnames).intersection(e.surnames).count
            if common > 0 { evidence.append(DupEvidence(.authors, count: common, total: max(n.surnames.count, e.surnames.count))) }
        }
        if let a = n.year, let b = e.year { evidence.append(DupEvidence(.year, count: b, total: a)) }
        if let pageX, pageX >= 0.3 { evidence.append(DupEvidence(.text, percent: Int((pageX * 100).rounded()))) }
        if let absX, absX >= 0.3 { evidence.append(DupEvidence(.abstract, percent: Int((absX * 100).rounded()))) }

        var weight = 0.45, sum = 0.45 * (titleOK ? titleScore : 0)
        if let overlap { weight += 0.2; sum += 0.2 * overlap }
        if let x { weight += 0.2; sum += 0.2 * x }
        if let dy { weight += 0.05; sum += dy <= 1 ? 0.05 : 0 }
        let score = min(0.97, sum / weight)

        let newer = VersionRank.newer(new: n.rank, existing: e.rank)
        let relation: DupRelation = newer == .new ? .newerVersion : newer == .existing ? .olderVersion
            : (sameVersionFuzzy(n, e, pageX: pageX) ? .sameVersion : .sameWork)
        return DupCandidate(band: found, relation: relation, score: score, evidence: evidence, newerSide: newer)
    }
}
