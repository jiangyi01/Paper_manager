import Foundation
import Synchronization

/// Finds canonical bibliographic metadata for one paper (DESIGN §6.1 [enriched]).
///
/// Order: arXiv id → arXiv; bioRxiv-family DOI → bioRxiv, then medRxiv (both DOI
/// prefixes); any DOI → Crossref, then OpenAlex when the abstract is missing (or
/// Crossref has nothing); PII → Crossref `alternative-id`; no usable id → Crossref
/// bibliographic search accepted only at TitleSimilarity ≥ 0.92. Every failure is
/// non-fatal: the result is nil (or the best partial record when the total
/// timeout hits mid-way) and the card offers "refresh metadata".
///
/// Responses are cached by URL without the mailto: 2xx forever (a preprint server's for
/// `preprintTTL`), 404 — and well-formed "nothing found" answers, stored as 404 — for 30
/// days. Throttled, 5xx and malformed responses are never cached.
package struct MetadataResolver: Sendable {
    package static let defaultTotalTimeout: TimeInterval = 20
    package static let defaultRequestTimeout: TimeInterval = 10
    package static let negativeTTL: TimeInterval = 30 * 86_400

    /// How long a preprint server's answer counts as fresh: it says whether the preprint was
    /// published only as of the day we asked (bioRxiv `published`, arXiv `doi`).
    package static let preprintTTL: TimeInterval = 30 * 86_400

    /// Whether a cached response may be used instead of fetching (the DB store can prune with this too).
    /// A 2xx from a preprint server (`key` under api.biorxiv.org/details or export.arxiv.org/api)
    /// expires after `preprintTTL`, so a preprint fetched before publication learns its journal
    /// DOI; every other 2xx is kept.
    package static func isFresh(status: Int, fetchedAt: Date, now: Date, key: String = "") -> Bool {
        if (200..<300).contains(status) {
            return !isPreprintServerKey(key) || now.timeIntervalSince(fetchedAt) < preprintTTL
        }
        if status == 404 { return now.timeIntervalSince(fetchedAt) < negativeTTL }
        return false
    }

    /// A cache key (request URL without mailto) of a preprint server's record.
    package static func isPreprintServerKey(_ key: String) -> Bool {
        let k = key.lowercased()
        return k.hasPrefix("https://api.biorxiv.org/details/") || k.hasPrefix("https://export.arxiv.org/api/query")
    }

    /// What a log line may name of a request: the host and path (a DOI, an arXiv / bioRxiv path),
    /// never the query — a title search carries the title, which for an email's attachment may
    /// be an unpublished manuscript's or a file name.
    package static func logKey(for url: URL) -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.host ?? "?" }
        let query = comps.percentEncodedQuery != nil
        comps.percentEncodedQuery = nil
        comps.fragment = nil
        comps.user = nil
        comps.password = nil
        return (comps.url?.absoluteString ?? (url.host ?? "?")) + (query ? "?…" : "")
    }

    /// An error as a log line may name it: its type (and a URL error's code) — never its
    /// description, which quotes the failing URL with its query.
    package static func logReason(_ error: any Error) -> String {
        if let e = error as? URLError { return "URLError(\(e.code.rawValue))" }
        return String(describing: type(of: error))
    }

    /// Cache key: the request URL minus `mailto`, so changing the contact address keeps the cache.
    package static func cacheKey(for url: URL) -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.percentEncodedQueryItems, items.contains(where: { $0.name == "mailto" }) else {
            return url.absoluteString
        }
        let kept = items.filter { $0.name != "mailto" }
        comps.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return comps.url?.absoluteString ?? url.absoluteString
    }

    private let fetcher: any HTTPFetching
    private let cache: any MetadataCacheStore
    private let gate: HostGate
    private let mailto: String?
    private let requestTimeout: TimeInterval
    private let now: @Sendable () -> Date
    /// Monotonic time behind the total timeout; tests inject a manual clock to decide when it runs out.
    private let clock: any HostGate.Clock

    package init(fetcher: any HTTPFetching, cache: any MetadataCacheStore, gate: HostGate, mailto: String? = nil,
                 requestTimeout: TimeInterval = MetadataResolver.defaultRequestTimeout,
                 now: @escaping @Sendable () -> Date = { Date() },
                 clock: any HostGate.Clock = HostGate.SystemClock()) {
        self.fetcher = fetcher
        self.cache = cache
        self.gate = gate
        self.mailto = MetadataClients.sanitizedMailto(mailto)
        self.requestTimeout = requestTimeout
        self.now = now
        self.clock = clock
    }

    /// `forceRefresh` skips cache reads (the card's "refresh metadata"); responses are still stored.
    package func resolve(ids: PaperIDs, titleGuess: String?, firstAuthorGuess: String?,
                         timeout: TimeInterval = MetadataResolver.defaultTotalTimeout,
                         forceRefresh: Bool = false) async -> BiblioMetadata? {
        let run = Run(clock: clock, deadline: clock.now() + max(0, timeout), forceRefresh: forceRefresh)
        let finished: BiblioMetadata?? = await withTaskGroup(of: BiblioMetadata??.self) { group in
            group.addTask {
                .some(await self.lookUp(ids: ids, titleGuess: titleGuess, firstAuthorGuess: firstAuthorGuess, run: run))
            }
            group.addTask {
                try? await run.clock.sleep(until: run.deadline)
                return .none
            }
            let first = await group.next() ?? .none
            group.cancelAll()
            return first
        }
        if let finished { return finished }
        Log.metadata.info("metadata lookup timed out after \(timeout, privacy: .public)s")
        return run.best
    }

    // MARK: - Routing

    private func lookUp(ids: PaperIDs, titleGuess: String?, firstAuthorGuess: String?, run: Run) async -> BiblioMetadata? {
        if let arxiv = ids.arxivID ?? ids.doi.flatMap(MetadataClients.arxivID(fromDOI:)),
           let url = MetadataClients.arxivURL(id: arxiv),
           case .found(let meta) = await fetch(url, run: run, parse: { try MetadataClients.parseArxiv($0) }) {
            run.best = meta
            return meta
        }

        if let doi = ids.doi.flatMap(MetadataClients.normalizeDOI) {
            if let preprint = MetadataClients.biorxivDOI(doi), let meta = await biorxiv(doi: preprint, run: run) {
                return meta
            }
            if let meta = await crossrefThenOpenAlex(doi: doi, run: run) { return meta }
        }

        if let pii = ids.pii, let url = MetadataClients.crossrefPIIURL(pii: pii, mailto: mailto),
           case .found(let work) = await fetch(url, run: run, parse: { try MetadataClients.parseCrossrefList($0).first }) {
            run.best = work.meta
            return await fillAbstract(work.meta, run: run)
        }

        // Also reached when ids exist but no source knows them (e.g. a mistyped DOI).
        if let title = titleGuess, Self.isSearchable(title) {
            let surname = firstAuthorGuess.flatMap(Self.surname)
            if let url = MetadataClients.crossrefSearchURL(title: title, author: surname, mailto: mailto),
               case .found(let work) = await fetch(url, run: run, parse: {
                   Self.bestMatch(in: try MetadataClients.parseCrossrefList($0), title: title, surname: surname)
               }) {
                run.best = work.meta
                return await fillAbstract(work.meta, run: run)
            }
        }
        return nil
    }

    private func biorxiv(doi: String, run: Run) async -> BiblioMetadata? {
        let dois = [doi] + (MetadataClients.alternateBiorxivDOI(doi).map { [$0] } ?? [])
        for server in MetadataClients.PreprintServer.allCases {
            for candidate in dois {
                guard !Task.isCancelled else { return nil }
                if let url = MetadataClients.biorxivURL(doi: candidate, server: server),
                   case .found(let meta) = await fetch(url, run: run, parse: { try MetadataClients.parseBiorxiv($0) }) {
                    run.best = meta
                    return meta
                }
            }
        }
        return nil
    }

    private func crossrefThenOpenAlex(doi: String, run: Run) async -> BiblioMetadata? {
        guard !Task.isCancelled else { return nil }
        if let url = MetadataClients.crossrefWorkURL(doi: doi, mailto: mailto),
           case .found(let work) = await fetch(url, run: run, parse: { try MetadataClients.parseCrossrefWork($0) }) {
            run.best = work.meta
            return await fillAbstract(work.meta, run: run)
        }
        guard !Task.isCancelled, let url = MetadataClients.openAlexWorkURL(doi: doi, mailto: mailto),
              case .found(let meta) = await fetch(url, run: run, parse: { try MetadataClients.parseOpenAlexWork($0) })
        else { return nil }
        run.best = meta
        return meta
    }

    /// Crossref rarely has abstracts for Elsevier/Springer; OpenAlex usually does.
    private func fillAbstract(_ record: BiblioMetadata, run: Run) async -> BiblioMetadata {
        guard record.abstract == nil, !Task.isCancelled, let doi = record.ids.doi,
              let url = MetadataClients.openAlexWorkURL(doi: doi, mailto: mailto),
              case .found(let extra) = await fetch(url, run: run, parse: { try MetadataClients.parseOpenAlexWork($0) })
        else { return record }
        var merged = record
        merged.abstract = extra.abstract
        merged.venue = record.venue ?? extra.venue
        merged.year = record.year ?? extra.year
        if merged.authors.isEmpty { merged.authors = extra.authors }
        merged.title = record.title ?? extra.title
        merged.ids = record.ids.merged(with: extra.ids)
        merged.openAlexID = record.openAlexID ?? extra.openAlexID
        for r in extra.relations where !merged.relations.contains(r) { merged.relations.append(r) }
        run.best = merged
        return merged
    }

    // MARK: - Search acceptance

    /// Titles shorter than this are too generic to search for.
    private static func isSearchable(_ title: String) -> Bool {
        let n = TitleSimilarity.normalize(title)
        return n.count >= 12 && n.split(separator: " ").count >= 3
    }

    /// "Wang, L." / "Li Wang" → "Wang".
    private static func surname(_ author: String) -> String? {
        let s = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let part = s.contains(",") ? String(s.prefix { $0 != "," }) : String(s.split(separator: " ").last ?? "")
        let cleaned = part.trimmingCharacters(in: CharacterSet.letters.inverted)
        return cleaned.count >= 2 ? cleaned : nil
    }

    /// Best hit at ≥ 0.92 similarity (≥ 0.97 when a known first-author surname is absent from its
    /// author list). A journal version beats a same-titled preprint, because a PDF without any
    /// detectable id is almost always the journal typeset.
    private static func bestMatch(in works: [MetadataClients.CrossrefWork], title: String,
                                  surname: String?) -> MetadataClients.CrossrefWork? {
        let wanted = surname.map(TitleSimilarity.normalize)
        var best: (work: MetadataClients.CrossrefWork, rank: Double)?
        for work in works {
            guard let candidate = work.meta.title else { continue }
            let similarity = TitleSimilarity.score(title, candidate)
            var authorOK = true
            if let wanted, !wanted.isEmpty, !work.meta.authors.isEmpty {
                authorOK = work.meta.authors.contains { TitleSimilarity.normalize($0).split(separator: " ").contains(Substring(wanted)) }
            }
            guard similarity >= (authorOK ? TitleSimilarity.acceptThreshold : 0.97) else { continue }
            let rank = similarity - (work.isPreprint ? 0.005 : 0)
            if best == nil || rank > best!.rank { best = (work, rank) }
        }
        return best?.work
    }

    // MARK: - Cached, gated fetch

    private enum Outcome<T: Sendable>: Sendable {
        case found(T)
        case notFound
        case failed
    }

    private func fetch<T: Sendable>(_ url: URL, run: Run, parse: @Sendable (Data) throws -> T?) async -> Outcome<T> {
        guard !Task.isCancelled else { return .failed }
        let key = Self.cacheKey(for: url)
        // A preprint server's record past `preprintTTL` is re-asked, but still answers when the
        // network can't (it was right as of its day).
        var stale: Data?
        if !run.forceRefresh, let hit = await cache.cached(key: key) {
            if Self.isFresh(status: hit.status, fetchedAt: hit.fetchedAt, now: now(), key: key) {
                if hit.status == 404 { return .notFound }
                do {
                    if let value = try parse(hit.body) { return .found(value) }
                    return .notFound
                } catch {
                    // An unparseable cached body (older format?) falls through to a fresh fetch.
                }
            } else if (200..<300).contains(hit.status) {
                stale = hit.body
            }
        }
        func fallback() -> Outcome<T> {
            if let stale, let value = try? parse(stale) { return .found(value) }
            return .failed
        }

        let remaining = run.remaining
        guard remaining > 0 else { return fallback() }
        let host = url.host ?? ""
        let headers = MetadataClients.requestHeaders(for: url, mailto: mailto)
        let perRequest = min(requestTimeout, remaining)
        let fetcher = self.fetcher
        let result: HTTPResult
        do {
            result = try await gate.perform(host: host,
                                            policy: HostGate.policy(forHost: host, politeCrossref: mailto != nil),
                                            budget: remaining) {
                try await fetcher.get(url, headers: headers, timeout: perRequest)
            }
        } catch {
            Log.metadata.info("metadata fetch failed \(Self.logKey(for: url), privacy: .public): \(Self.logReason(error), privacy: .public)")
            return fallback()
        }

        switch result.status {
        case 200..<300:
            do {
                if let value = try parse(result.body) {
                    await cache.store(key: key, status: result.status, body: result.body, at: now())
                    return .found(value)
                }
                await cache.store(key: key, status: 404, body: result.body, at: now())
                return .notFound
            } catch {
                Log.metadata.error("unexpected metadata response \(Self.logKey(for: url), privacy: .public): \(Self.logReason(error), privacy: .public)")
                return .failed
            }
        case 404, 410:
            await cache.store(key: key, status: 404, body: result.body, at: now())
            return .notFound
        default:
            Log.metadata.info("metadata HTTP \(result.status) for \(Self.logKey(for: url), privacy: .public)")
            return fallback()
        }
    }
}

extension MetadataResolver {
    /// Per-call state shared by the lookup task and the timeout: the deadline and the
    /// best record seen so far (returned if the deadline cuts the lookup short).
    fileprivate final class Run: Sendable {
        let clock: any HostGate.Clock
        let deadline: TimeInterval              // on `clock`
        let forceRefresh: Bool
        private let bestRecord = Mutex<BiblioMetadata?>(nil)

        init(clock: any HostGate.Clock, deadline: TimeInterval, forceRefresh: Bool) {
            self.clock = clock
            self.deadline = deadline
            self.forceRefresh = forceRefresh
        }

        var best: BiblioMetadata? {
            get { bestRecord.withLock { $0 } }
            set { bestRecord.withLock { $0 = newValue } }
        }

        /// Seconds left before the deadline (≤ 0 when past it).
        var remaining: TimeInterval { deadline - clock.now() }
    }
}
