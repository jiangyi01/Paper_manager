import Foundation
import Testing
@testable import PaperDeckCore

/// Routing, caching and failure handling, fully offline: a fake transport replays
/// the real responses in Fixtures/metadata and a virtual clock makes HostGate spacing free.
@Suite struct MetadataResolverTests {
    typealias Handler = @Sendable (URL) async throws -> HTTPResult

    final class FakeFetcher: HTTPFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        private var headerLog: [[String: String]] = []
        private let handler: Handler

        init(_ handler: @escaping Handler = MetadataResolverTests.fixtureRoute) { self.handler = handler }

        func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResult {
            lock.withLock { urls.append(url); headerLog.append(headers) }
            return try await handler(url)
        }

        var requested: [String] { lock.withLock { urls.map(\.absoluteString) } }
        var headers: [[String: String]] { lock.withLock { headerLog } }
    }

    private static func ok(_ name: String, _ ext: String) -> HTTPResult {
        HTTPResult(status: 200, body: (try? MetadataParsingTests.fixture(name, ext)) ?? Data())
    }

    private static let crossref404 = HTTPResult(status: 404, body: Data("Resource not found.".utf8))

    /// Serves the saved responses; unknown ids get each API's real "not found" shape.
    static let fixtureRoute: Handler = { url in
        let path = url.path
        let query = url.query ?? ""
        switch url.host {
        case "export.arxiv.org":
            if query.hasSuffix("2606.24530") { return ok("arxiv-2606-24530", "xml") }
            if query.hasSuffix("2604.09554") { return ok("arxiv-2604-09554", "xml") }
            return ok("arxiv-notfound", "xml")
        case "api.biorxiv.org":
            switch path {
            case "/details/biorxiv/10.1101/2025.09.01.673319": return ok("biorxiv-2025-09-01-673319", "json")
            case "/details/biorxiv/10.64898/2026.02.27.708412": return ok("biorxiv-64898-2026-02-27-708412", "json")
            case "/details/biorxiv/10.64898/2026.04.06.716850": return ok("biorxiv-64898-2026-04-06-716850", "json")
            case "/details/biorxiv/10.1101/2024.01.16.575956": return ok("biorxiv-2024-01-16-575956", "json")
            default: return ok("biorxiv-notfound", "json")
            }
        case "api.crossref.org":
            switch path {
            case "/works/10.1038/s41586-024-08351-7": return ok("crossref-s41586-024-08351-7", "json")
            case "/works/10.20944/preprints202608.0213.v1": return ok("crossref-preprints202608-0213-v1", "json")
            case "/works/10.64898/2026.02.27.708412": return ok("crossref-64898-2026-02-27-708412", "json")
            case "/works" where query.contains("filter=alternative-id:S0092867424013321"):
                return ok("crossref-pii-S0092867424013321", "json")
            case "/works" where query.contains("query.bibliographic=SpatialFormer"):
                return ok("crossref-query-spatialformer", "json")
            case "/works" where query.contains("query.bibliographic="):
                return ok("crossref-query-neocortex", "json")
            case "/works":
                return HTTPResult(status: 200, body: Data(#"{"status":"ok","message":{"items":[]}}"#.utf8))
            default: return crossref404
            }
        case "api.openalex.org":
            switch path {
            case "/works/doi:10.1038/s41586-024-08351-7": return ok("openalex-s41586-024-08351-7", "json")
            case "/works/doi:10.1016/j.cell.2024.11.015": return ok("openalex-cell-2024-11-015", "json")
            default: return HTTPResult(status: 404, body: (try? MetadataParsingTests.fixture("openalex-notfound", "html")) ?? Data())
            }
        default:
            throw URLError(.cannotFindHost)
        }
    }

    /// Time stands still until `advance`; a sleeper wakes once the clock reaches its deadline (or
    /// its task is cancelled), so a resolver's total timeout runs out exactly when the test says
    /// so — also when `advance` comes before the timeout task got to sleep.
    final class ManualClock: HostGate.Clock, @unchecked Sendable {
        private typealias Wake = CheckedContinuation<Void, any Error>
        private let lock = NSLock()
        private var t: TimeInterval = 1000
        private var sleepers: [UUID: (until: TimeInterval, wake: Wake)] = [:]
        private var cancelledEarly: Set<UUID> = []

        func now() -> TimeInterval { lock.withLock { t } }

        func sleep(seconds: TimeInterval) async throws { try await sleep(until: now() + seconds) }

        func sleep(until deadline: TimeInterval) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (wake: Wake) in
                    enum Next { case wait, due, cancel }
                    let next: Next = lock.withLock {
                        if cancelledEarly.remove(id) != nil { return .cancel }
                        if deadline <= t { return .due }
                        sleepers[id] = (deadline, wake)
                        return .wait
                    }
                    switch next {
                    case .wait: break
                    case .due: wake.resume()
                    case .cancel: wake.resume(throwing: CancellationError())
                    }
                }
            } onCancel: {
                let wake: Wake? = lock.withLock {
                    guard let s = sleepers.removeValue(forKey: id) else { cancelledEarly.insert(id); return nil }
                    return s.wake
                }
                wake?.resume(throwing: CancellationError())
            }
        }

        func advance(_ s: TimeInterval) {
            let due: [Wake] = lock.withLock {
                t += s
                let ids = sleepers.filter { $0.value.until <= t }.map(\.key)
                return ids.compactMap { sleepers.removeValue(forKey: $0)?.wake }
            }
            for wake in due { wake.resume() }
        }
    }

    private static func resolver(_ fetcher: FakeFetcher, cache: InMemoryMetadataCache = InMemoryMetadataCache(),
                                 mailto: String? = nil, now: @escaping @Sendable () -> Date = { Date() },
                                 clock: any HostGate.Clock = HostGate.SystemClock()) -> MetadataResolver {
        MetadataResolver(fetcher: fetcher, cache: cache, gate: HostGate(clock: HostGateTests.VirtualClock()),
                         mailto: mailto, now: now, clock: clock)
    }

    private static let natureDOI = "10.1038/s41586-024-08351-7"
    private static let arxivNature = "https://export.arxiv.org/api/query?id_list=2606.24530"
    private static let crossrefNature = "https://api.crossref.org/works/10.1038/s41586-024-08351-7"
    private static let openAlexSelect = "?select=id,doi,title,display_name,publication_year,type,authorships,primary_location,abstract_inverted_index"
    private static let openAlexNature = "https://api.openalex.org/works/doi:10.1038/s41586-024-08351-7" + openAlexSelect

    // MARK: Routing

    @Test func arxivIDGoesToArxivOnly() async throws {
        let fetcher = FakeFetcher()
        let meta = try #require(await Self.resolver(fetcher).resolve(
            ids: PaperIDs(arxivID: "2606.24530", arxivVersion: 2), titleGuess: "whatever title here", firstAuthorGuess: nil))
        #expect(fetcher.requested == [Self.arxivNature])
        #expect(meta.source == .arxiv)
        #expect(meta.title?.hasPrefix("NatureBench") == true)
        #expect(meta.ids.arxivID == "2606.24530")
        #expect(fetcher.headers.first?["User-Agent"] == "PaperDeck/0.1 (macOS)")
        #expect(fetcher.headers.first?["Accept"] == "application/atom+xml")
    }

    @Test func arxivMissFallsThroughToDOI() async throws {
        let fetcher = FakeFetcher()
        let meta = try #require(await Self.resolver(fetcher).resolve(
            ids: PaperIDs(doi: Self.natureDOI, arxivID: "2601.99999"), titleGuess: nil, firstAuthorGuess: nil))
        #expect(fetcher.requested == ["https://export.arxiv.org/api/query?id_list=2601.99999", Self.crossrefNature, Self.openAlexNature])
        #expect(meta.source == .crossref)
    }

    @Test func biorxivDOI() async throws {
        let fetcher = FakeFetcher()
        let meta = try #require(await Self.resolver(fetcher).resolve(
            ids: PaperIDs(doi: "10.1101/2025.09.01.673319"), titleGuess: nil, firstAuthorGuess: nil))
        #expect(fetcher.requested == ["https://api.biorxiv.org/details/biorxiv/10.1101/2025.09.01.673319"])
        #expect(meta.source == .biorxiv)
        #expect(meta.venue == "bioRxiv")
        #expect(meta.authors.first == "H. E. Miller")
        #expect(meta.year == 2025)
    }

    /// File names only carry the date-stamped suffix; 2026 bioRxiv papers live under 10.64898.
    @Test func biorxivFilenameDOIFindsNewPrefix() async throws {
        let fetcher = FakeFetcher()
        let meta = try #require(await Self.resolver(fetcher).resolve(
            ids: PaperIDs(doi: "10.1101/2026.02.27.708412"), titleGuess: nil, firstAuthorGuess: nil))
        #expect(fetcher.requested == [
            "https://api.biorxiv.org/details/biorxiv/10.1101/2026.02.27.708412",
            "https://api.biorxiv.org/details/biorxiv/10.64898/2026.02.27.708412",
        ])
        #expect(meta.ids.doi == "10.64898/2026.02.27.708412")
        #expect(meta.title == "Eubiota: Modular Agentic AI for Autonomous Discovery in the Gut Microbiome")
    }

    @Test func biorxivUnknownTriesMedrxivThenCrossref() async throws {
        let fetcher = FakeFetcher()
        let meta = await Self.resolver(fetcher).resolve(
            ids: PaperIDs(doi: "10.1101/2019.01.01.000001"), titleGuess: nil, firstAuthorGuess: nil)
        #expect(meta == nil)
        #expect(fetcher.requested == [
            "https://api.biorxiv.org/details/biorxiv/10.1101/2019.01.01.000001",
            "https://api.biorxiv.org/details/biorxiv/10.64898/2019.01.01.000001",
            "https://api.biorxiv.org/details/medrxiv/10.1101/2019.01.01.000001",
            "https://api.biorxiv.org/details/medrxiv/10.64898/2019.01.01.000001",
            "https://api.crossref.org/works/10.1101/2019.01.01.000001",
            "https://api.openalex.org/works/doi:10.1101/2019.01.01.000001" + Self.openAlexSelect,
        ])
    }

    @Test func coldSpringHarborJournalSkipsBiorxiv() async {
        let fetcher = FakeFetcher()
        _ = await Self.resolver(fetcher).resolve(ids: PaperIDs(doi: "10.1101/gr.278123.123"), titleGuess: nil, firstAuthorGuess: nil)
        #expect(fetcher.requested.first == "https://api.crossref.org/works/10.1101/gr.278123.123")
    }

    @Test func arxivDataCiteDOIUsesArxiv() async throws {
        let fetcher = FakeFetcher()
        let meta = try #require(await Self.resolver(fetcher).resolve(
            ids: PaperIDs(doi: "10.48550/arXiv.2604.09554"), titleGuess: nil, firstAuthorGuess: nil))
        #expect(fetcher.requested == ["https://export.arxiv.org/api/query?id_list=2604.09554"])
        #expect(meta.source == .arxiv)
    }

    @Test func journalDOIUsesCrossrefThenOpenAlexForAbstract() async throws {
        let fetcher = FakeFetcher()
        let meta = try #require(await Self.resolver(fetcher).resolve(
            ids: PaperIDs(doi: Self.natureDOI), titleGuess: nil, firstAuthorGuess: nil))
        #expect(fetcher.requested == [Self.crossrefNature, Self.openAlexNature])
        #expect(meta.source == .crossref)
        #expect(meta.title == "Molecular and cellular dynamics of the developing human neocortex")
        #expect(meta.venue == "Nature")
        #expect(meta.year == 2025)
        #expect(meta.authors.count == 20)
        #expect(meta.abstract?.hasPrefix("Here we collected paired single-nucleus") == true)
        #expect(meta.ids.doi == Self.natureDOI)
    }

    @Test func crossrefAbstractSkipsOpenAlex() async throws {
        let fetcher = FakeFetcher()
        let meta = try #require(await Self.resolver(fetcher).resolve(
            ids: PaperIDs(doi: "10.20944/preprints202608.0213.v1"), titleGuess: nil, firstAuthorGuess: nil))
        #expect(fetcher.requested == ["https://api.crossref.org/works/10.20944/preprints202608.0213.v1"])
        #expect(meta.venue == "Preprints.org")
        #expect(meta.abstract != nil)
    }

    @Test func unknownToCrossrefFallsBackToOpenAlex() async throws {
        let fetcher = FakeFetcher { url in
            if url.host == "api.openalex.org" { return MetadataResolverTests.ok("openalex-cell-2024-11-015", "json") }
            return MetadataResolverTests.crossref404
        }
        let meta = try #require(await Self.resolver(fetcher).resolve(
            ids: PaperIDs(doi: "10.1016/j.cell.2024.11.015"), titleGuess: nil, firstAuthorGuess: nil))
        #expect(meta.source == .openalex)
        #expect(meta.venue == "Cell")
        #expect(fetcher.requested.count == 2)
    }

    @Test func piiUsesCrossrefFilterThenOpenAlex() async throws {
        let fetcher = FakeFetcher()
        let meta = try #require(await Self.resolver(fetcher).resolve(
            ids: PaperIDs(pii: "S0092867424013321"), titleGuess: nil, firstAuthorGuess: nil))
        #expect(fetcher.requested == [
            "https://api.crossref.org/works?filter=alternative-id:S0092867424013321&rows=1",
            "https://api.openalex.org/works/doi:10.1016/j.cell.2024.11.015" + Self.openAlexSelect,
        ])
        #expect(meta.title == "How to build the virtual cell with artificial intelligence: Priorities and opportunities")
        #expect(meta.venue == "Cell")
        #expect(meta.year == 2024)
        #expect(meta.ids.doi == "10.1016/j.cell.2024.11.015")
        #expect(meta.ids.pii == "S0092867424013321")
        #expect(meta.abstract?.hasPrefix("Cells are essential") == true)
        #expect(meta.source == .crossref)
    }

    // MARK: Title search

    @Test func titleSearchPrefersJournalVersion() async throws {
        let fetcher = FakeFetcher()
        let title = "SpatialFormer: universal spatial representation learning from subcellular molecular to multicellular landscapes"
        let meta = try #require(await Self.resolver(fetcher).resolve(ids: PaperIDs(), titleGuess: title, firstAuthorGuess: "Jun Wang"))
        #expect(fetcher.requested.first == "https://api.crossref.org/works?query.bibliographic=SpatialFormer%3A%20universal%20spatial%20representation%20learning%20from%20subcellular%20molecular%20to%20multicellular%20landscapes&query.author=Wang&rows=3")
        #expect(fetcher.requested.count == 2)          // + OpenAlex abstract attempt (404 here)
        #expect(meta.ids.doi == "10.1038/s43588-026-01016-7")
        #expect(meta.venue == "Nature Computational Science")
        #expect(meta.source == .crossref)
    }

    @Test func titleSearchAcceptsExactJournalTitle() async throws {
        let fetcher = FakeFetcher()
        let meta = try #require(await Self.resolver(fetcher).resolve(
            ids: PaperIDs(), titleGuess: "Molecular and Cellular Dynamics of the Developing Human Neocortex",
            firstAuthorGuess: "Wang, L."))
        #expect(meta.ids.doi == Self.natureDOI)
        #expect(meta.abstract != nil)                   // filled from OpenAlex
    }

    @Test func titleSearchRejectsDissimilarHits() async throws {
        let fetcher = FakeFetcher()
        let cache = InMemoryMetadataCache()
        let resolver = Self.resolver(fetcher, cache: cache)
        let meta = await resolver.resolve(ids: PaperIDs(), titleGuess: "Single-cell atlas of the adult mouse hippocampus",
                                          firstAuthorGuess: nil)
        #expect(meta == nil)
        #expect(fetcher.requested.count == 1)
        // No acceptable hit is negative-cached (30 days) rather than kept forever.
        let key = try #require(await cache.keys.first)
        #expect(await cache.cached(key: key)?.status == 404)
        _ = await resolver.resolve(ids: PaperIDs(), titleGuess: "Single-cell atlas of the adult mouse hippocampus", firstAuthorGuess: nil)
        #expect(fetcher.requested.count == 1)
    }

    /// Between 0.92 and 0.97 the guessed first author must appear in the hit's author list.
    @Test func authorMismatchRaisesTheBar() async throws {
        let long = "A comprehensive single cell multiomic atlas of human fetal development across twelve major organs reveals shared regulatory programs that govern cell fate decisions and lineage commitment in early gestation"
        let near = long.replacingOccurrences(of: "twelve", with: "fifteen")
        let score = TitleSimilarity.score(long, near)
        #expect(score >= 0.92 && score < 0.97)
        let body = #"{"status":"ok","message":{"items":[{"DOI":"10.1000/atlas","type":"journal-article","title":["\#(long)"],"author":[{"given":"Mei","family":"Chen"}]}]}}"#
        let fetcher = FakeFetcher { _ in HTTPResult(status: 200, body: Data(body.utf8)) }
        let matched = await Self.resolver(fetcher).resolve(ids: PaperIDs(), titleGuess: near, firstAuthorGuess: "Mei Chen")
        #expect(matched?.ids.doi == "10.1000/atlas")
        let mismatched = await Self.resolver(fetcher).resolve(ids: PaperIDs(), titleGuess: near, firstAuthorGuess: "Olsen")
        #expect(mismatched == nil)
        let exact = await Self.resolver(fetcher).resolve(ids: PaperIDs(), titleGuess: long, firstAuthorGuess: "Olsen")
        #expect(exact?.ids.doi == "10.1000/atlas")
    }

    @Test func nothingToLookUp() async {
        let fetcher = FakeFetcher()
        let r = Self.resolver(fetcher)
        #expect(await r.resolve(ids: PaperIDs(), titleGuess: nil, firstAuthorGuess: nil) == nil)
        #expect(await r.resolve(ids: PaperIDs(), titleGuess: "Nature", firstAuthorGuess: "Wang") == nil)
        #expect(await r.resolve(ids: PaperIDs(doi: "not-a-doi"), titleGuess: "  ", firstAuthorGuess: nil) == nil)
        #expect(fetcher.requested.isEmpty)
    }

    // MARK: Cache

    @Test func cacheHitAvoidsFetch() async throws {
        let fetcher = FakeFetcher()
        let cache = InMemoryMetadataCache()
        let first = await Self.resolver(fetcher, cache: cache).resolve(ids: PaperIDs(doi: Self.natureDOI), titleGuess: nil, firstAuthorGuess: nil)
        #expect(fetcher.requested.count == 2)
        let second = await Self.resolver(fetcher, cache: cache).resolve(ids: PaperIDs(doi: Self.natureDOI), titleGuess: nil, firstAuthorGuess: nil)
        #expect(fetcher.requested.count == 2)
        #expect(first != nil && first == second)
        #expect(await cache.keys == [Self.openAlexNature, Self.crossrefNature].sorted())

        _ = await Self.resolver(fetcher, cache: cache).resolve(ids: PaperIDs(doi: Self.natureDOI), titleGuess: nil,
                                                                 firstAuthorGuess: nil, forceRefresh: true)
        #expect(fetcher.requested.count == 4)
    }

    @Test func notFoundIsCachedFor30Days() async throws {
        let fetcher = FakeFetcher()
        let cache = InMemoryMetadataCache()
        let ids = PaperIDs(doi: "10.5555/unknown-work")
        #expect(await Self.resolver(fetcher, cache: cache).resolve(ids: ids, titleGuess: nil, firstAuthorGuess: nil) == nil)
        #expect(fetcher.requested.count == 2)          // Crossref 404, OpenAlex 404
        for key in await cache.keys { #expect(await cache.cached(key: key)?.status == 404) }

        let in29Days: @Sendable () -> Date = { Date().addingTimeInterval(29 * 86_400) }
        #expect(await Self.resolver(fetcher, cache: cache, now: in29Days).resolve(ids: ids, titleGuess: nil, firstAuthorGuess: nil) == nil)
        #expect(fetcher.requested.count == 2)

        let in31Days: @Sendable () -> Date = { Date().addingTimeInterval(31 * 86_400) }
        _ = await Self.resolver(fetcher, cache: cache, now: in31Days).resolve(ids: ids, titleGuess: nil, firstAuthorGuess: nil)
        #expect(fetcher.requested.count == 4)
    }

    @Test func emptyAnswersAreNegativeCached() async throws {
        let fetcher = FakeFetcher()
        let cache = InMemoryMetadataCache()
        _ = await Self.resolver(fetcher, cache: cache).resolve(ids: PaperIDs(arxivID: "2601.99999"), titleGuess: nil, firstAuthorGuess: nil)
        #expect(await cache.cached(key: "https://export.arxiv.org/api/query?id_list=2601.99999")?.status == 404)
    }

    @Test func freshnessRule() {
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(MetadataResolver.isFresh(status: 200, fetchedAt: t0, now: t0.addingTimeInterval(1e9)))
        #expect(MetadataResolver.isFresh(status: 404, fetchedAt: t0, now: t0.addingTimeInterval(29 * 86_400)))
        #expect(!MetadataResolver.isFresh(status: 404, fetchedAt: t0, now: t0.addingTimeInterval(30 * 86_400)))
        #expect(!MetadataResolver.isFresh(status: 503, fetchedAt: t0, now: t0))
    }

    @Test func mailtoIsSentButNotPartOfTheCacheKey() async throws {
        let fetcher = FakeFetcher()
        let cache = InMemoryMetadataCache()
        _ = await Self.resolver(fetcher, cache: cache, mailto: "reader@lab.edu")
            .resolve(ids: PaperIDs(doi: Self.natureDOI), titleGuess: nil, firstAuthorGuess: nil)
        #expect(fetcher.requested == [Self.crossrefNature + "?mailto=reader%40lab.edu",
                                      Self.openAlexNature + "&mailto=reader%40lab.edu"])
        #expect(fetcher.headers.allSatisfy { $0["User-Agent"] == "PaperDeck/0.1 (macOS; mailto:reader@lab.edu)" })
        #expect(await cache.keys == [Self.openAlexNature, Self.crossrefNature].sorted())
        // Clearing the address later still hits the same cache entries.
        _ = await Self.resolver(fetcher, cache: cache).resolve(ids: PaperIDs(doi: Self.natureDOI), titleGuess: nil, firstAuthorGuess: nil)
        #expect(fetcher.requested.count == 2)
        #expect(MetadataResolver.cacheKey(for: URL(string: "https://x.org/a?mailto=m%40x.org")!) == "https://x.org/a")
    }

    // MARK: Failures

    @Test func serverErrorsAndGarbageAreNotCached() async throws {
        let fetcher = FakeFetcher { url in
            if url.host == "api.crossref.org" { return HTTPResult(status: 503) }
            return HTTPResult(status: 200, body: Data("<html>maintenance</html>".utf8))
        }
        let cache = InMemoryMetadataCache()
        // Load-tolerant (ENV-1): the gate's backoff runs on a virtual clock, but the total timeout is
        // wall time; under a loaded full run the default 20 s ran out before the third try.
        let meta = await Self.resolver(fetcher, cache: cache).resolve(ids: PaperIDs(doi: Self.natureDOI), titleGuess: nil,
                                                                      firstAuthorGuess: nil, timeout: 300)
        #expect(meta == nil)
        #expect(fetcher.requested.filter { $0.hasPrefix("https://api.crossref.org") }.count == 3)   // gate retried 503
        #expect(await cache.storeCount == 0)
    }

    @Test func transportErrorsAreNonFatal() async {
        let fetcher = FakeFetcher { _ in throw URLError(.notConnectedToInternet) }
        let cache = InMemoryMetadataCache()
        let meta = await Self.resolver(fetcher, cache: cache).resolve(
            ids: PaperIDs(doi: Self.natureDOI, arxivID: "2606.24530", pii: "S0092867424013321"),
            titleGuess: "Molecular and cellular dynamics of the developing human neocortex", firstAuthorGuess: nil)
        #expect(meta == nil)
        #expect(await cache.storeCount == 0)
        #expect(fetcher.requested.count == 5)          // arXiv, Crossref, OpenAlex, PII filter, search
    }

    @Test func totalTimeoutReturnsNil() async {
        let fetcher = FakeFetcher { _ in
            try await Task.sleep(for: .seconds(30))
            return HTTPResult(status: 200)
        }
        let started = ContinuousClock.now
        let meta = await Self.resolver(fetcher).resolve(ids: PaperIDs(doi: Self.natureDOI), titleGuess: nil,
                                                         firstAuthorGuess: nil, timeout: 0.3)
        #expect(meta == nil)
        #expect(ContinuousClock.now - started < .seconds(20))      // load-tolerant (ENV-1); the fetch hangs 30 s
    }

    /// Crossref answers, OpenAlex hangs, the total timeout runs out: the Crossref record comes back.
    /// The deadline is a manual clock that only runs out once OpenAlex has been asked, so the
    /// partial record is in hand however slowly a loaded machine gets there.
    @Test func timeoutKeepsPartialRecord() async throws {
        let clock = ManualClock()
        let timeout: TimeInterval = 5
        let abandoned = OpsTestKit.Box(false)
        let fetcher = FakeFetcher { url in
            if url.host == "api.openalex.org" {
                clock.advance(timeout)                              // the deadline passes while OpenAlex hangs
                do { try await Task.sleep(for: .seconds(30)) } catch { abandoned.value = true; throw error }
            }
            return try await MetadataResolverTests.fixtureRoute(url)
        }
        let meta = try #require(await Self.resolver(fetcher, clock: clock).resolve(
            ids: PaperIDs(doi: Self.natureDOI), titleGuess: nil, firstAuthorGuess: nil, timeout: timeout))
        #expect(meta.title == "Molecular and cellular dynamics of the developing human neocortex")
        #expect(meta.abstract == nil)
        #expect(fetcher.requested == [Self.crossrefNature, Self.openAlexNature])
        #expect(abandoned.value)                                    // the hung request was cancelled, not awaited
    }
}
