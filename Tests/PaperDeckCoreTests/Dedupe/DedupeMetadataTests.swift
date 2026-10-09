import Foundation
import Testing
@testable import PaperDeckCore

/// The metadata side of the duplicate check (dive-dedupe §2): Crossref relations and notices,
/// the OpenAlex work id, and the preprint servers' 30-day cache TTL (with a stale answer kept
/// for when the network can't be reached). Offline: scripted transports only.
@Suite struct CrossrefRelationTests {
    @Test func hasPreprintVersionOfAndUpdateTo() throws {
        let body = DedupeKit.crossref(doi: "10.1016/j.cell.2024.05.001", title: "Lineage tracing at scale",
                                      relation: ["has-preprint": ["10.1101/2023.11.11.566789"],
                                                 "is-version-of": ["10.5281/ZENODO.1"],
                                                 "is-comment-on": ["10.1234/c"],
                                                 "has-review": ["10.1/review"],
                                                 "is-identical-to": ["10.1016/j.cell.2024.05.001"]],
                                      updateTo: [])
        let work = try #require(try MetadataClients.parseCrossrefWork(Data(body.utf8)))
        let rel = Set(work.meta.relations)
        #expect(rel.contains(WorkRelation(kind: .hasPreprint, doi: "10.1101/2023.11.11.566789")))
        #expect(rel.contains(WorkRelation(kind: .isVersionOf, doi: "10.5281/zenodo.1")))
        #expect(rel.contains(WorkRelation(kind: .isCommentOn, doi: "10.1234/c")))
        // Unknown relation names and links to the record itself are dropped.
        #expect(rel.count == 3)
        #expect(work.meta.workType == "journal-article")
        // Nothing here is adopted as an id.
        #expect(work.meta.ids.doi == "10.1016/j.cell.2024.05.001" && work.meta.ids.publishedDOI == nil)
        let keys = DupKeys.fromRecord(work.meta)
        #expect(keys.contains(DupKey(kind: .preprintDOI, value: "biorxiv:2023.11.11.566789", source: .crossref)))
    }

    @Test func noticesAndComponents() throws {
        let notice = DedupeKit.crossref(doi: "10.1038/s41586-025-09999-9", title: "Author Correction: Molecular dynamics",
                                        updateTo: ["10.1038/s41586-025-01234-5"])
        let n = try #require(try MetadataClients.parseCrossrefWork(Data(notice.utf8)))
        #expect(n.meta.relations == [WorkRelation(kind: .correctionOf, doi: "10.1038/s41586-025-01234-5")])
        #expect(DedupeText.kind(title: n.meta.title ?? "", relations: n.meta.relations) == .notice)
        let component = DedupeKit.crossref(doi: "10.1371/journal.pone.0270001.s001", title: "S1 Fig", type: "component")
        let c = try #require(try MetadataClients.parseCrossrefWork(Data(component.utf8)))
        #expect(c.meta.workType == "component")
        #expect(DedupeText.kind(title: "S1 Fig", workType: c.meta.workType) == .supplement)
    }

    @Test func preprintSubtypeIsKept() throws {
        let body = DedupeKit.crossref(doi: "10.1101/2023.11.11.566789", title: "Lineage tracing", type: "posted-content")
            .replacingOccurrences(of: "\"type\":\"posted-content\"", with: "\"type\":\"posted-content\",\"subtype\":\"preprint\"")
        let w = try #require(try MetadataClients.parseCrossrefWork(Data(body.utf8)))
        #expect(w.meta.workType == "posted-content/preprint")
        #expect(VersionRank.of(ids: w.meta.ids, venue: w.meta.venue, workType: w.meta.workType).tier == .preprint)
    }

    @Test func openAlexWorkID() throws {
        let data = try MetadataParsingTests.fixture("openalex-s41586-024-08351-7", "json")
        let meta = try #require(try MetadataClients.parseOpenAlexWork(data))
        #expect(meta.openAlexID == "W4406155815")
        #expect(MetadataClients.openAlexWorkID("w123456") == "W123456")
        #expect(MetadataClients.openAlexWorkID("https://openalex.org/A5100335897") == nil)
        #expect(MetadataClients.openAlexWorkID("W12") == nil)
    }

    @Test func recordsEncodedBeforeTheFieldsStillDecode() throws {
        let old = #"{"title":"T","authors":["A B"],"ids":{"doi":"10.1/x"},"source":"crossref"}"#
        let m = try JSONDecoder().decode(BiblioMetadata.self, from: Data(old.utf8))
        #expect(m.relations.isEmpty && m.workType == nil && m.openAlexID == nil && m.ids.doi == "10.1/x")
        // And a record without relations encodes as before (no new keys).
        let json = String(decoding: try JSONEncoder().encode(BiblioMetadata(title: "T", source: .crossref)), as: UTF8.self)
        #expect(!json.contains("relations") && !json.contains("workType") && !json.contains("openAlexID"))
    }
}

@Suite struct ResolverTTLTests {
    final class Counting: HTTPFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var fail = false
        let body: Data
        init(_ body: Data) { self.body = body }
        func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResult {
            lock.withLock { n += 1 }
            if lock.withLock({ fail }) { throw URLError(.notConnectedToInternet) }
            return HTTPResult(status: 200, body: body)
        }
        var count: Int { lock.withLock { n } }
        func setFail(_ v: Bool) { lock.withLock { fail = v } }
    }

    final class Now: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_790_000_000)
        var value: Date { lock.withLock { t } }
        func advance(days: Double) { lock.withLock { t = t.addingTimeInterval(days * 86_400) } }
    }

    @Test func isFreshByKey() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let biorxiv = "https://api.biorxiv.org/details/biorxiv/10.1101/2024.01.01.000001"
        let arxiv = "https://export.arxiv.org/api/query?id_list=2401.01234"
        let crossref = "https://api.crossref.org/works/10.1038/x"
        #expect(MetadataResolver.isFresh(status: 200, fetchedAt: t0, now: t0.addingTimeInterval(29 * 86_400), key: biorxiv))
        #expect(!MetadataResolver.isFresh(status: 200, fetchedAt: t0, now: t0.addingTimeInterval(31 * 86_400), key: biorxiv))
        #expect(!MetadataResolver.isFresh(status: 200, fetchedAt: t0, now: t0.addingTimeInterval(31 * 86_400), key: arxiv))
        #expect(MetadataResolver.isFresh(status: 200, fetchedAt: t0, now: t0.addingTimeInterval(1e9), key: crossref))
        #expect(MetadataResolver.isFresh(status: 200, fetchedAt: t0, now: t0.addingTimeInterval(1e9)))
        #expect(!MetadataResolver.isFresh(status: 404, fetchedAt: t0, now: t0.addingTimeInterval(31 * 86_400), key: crossref))
    }

    /// A bioRxiv record fetched before publication learns its journal DOI after 30 days; while
    /// offline the stale record still answers.
    @Test func biorxivRecordIsRefetchedAfterThirtyDays() async throws {
        let body = Data(#"{"collection":[{"doi":"10.1101/2024.01.01.000001","title":"A preprint","authors":"Wang, L.","date":"2024-01-01","version":"1","server":"biorxiv","published":"NA"}]}"#.utf8)
        let fetcher = Counting(body)
        let cache = InMemoryMetadataCache()
        let now = Now()
        let resolver = MetadataResolver(fetcher: fetcher, cache: cache, gate: HostGate(clock: DedupeKit.InstantGateClock()),
                                        now: { now.value })
        let ids = PaperIDs(doi: "10.1101/2024.01.01.000001")
        _ = await resolver.resolve(ids: ids, titleGuess: nil, firstAuthorGuess: nil)
        #expect(fetcher.count == 1)
        now.advance(days: 10)
        _ = await resolver.resolve(ids: ids, titleGuess: nil, firstAuthorGuess: nil)
        #expect(fetcher.count == 1)                      // fresh: from the cache
        now.advance(days: 25)
        _ = await resolver.resolve(ids: ids, titleGuess: nil, firstAuthorGuess: nil)
        #expect(fetcher.count == 2)                      // 35 days: asked again
        now.advance(days: 40)
        fetcher.setFail(true)
        let offline = await resolver.resolve(ids: ids, titleGuess: nil, firstAuthorGuess: nil)
        #expect(offline?.title == "A preprint")          // the stale record answers
    }
}
