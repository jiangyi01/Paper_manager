import Foundation
import Testing
@testable import PaperDeckCore

/// The detector against `Fixtures/dedupe/pairs.json` (DQ §7): synthetic preprint ↔ journal,
/// version, alias, supplement, notice, comment, family-member and generic-title pairs.
/// Acceptance (READING_ASSIST_PLAN §9.1): zero false `certain`, at most one false `likely`,
/// recall ≥ 90 % on the true same-work pairs — and every pair's expected band and relation.
@Suite struct DupDetectorFixtureTests {
    struct Side: Decodable {
        var title: String?
        var authors: [String]?
        var year: Int?
        var doi: String?
        var arxiv: String?
        var arxivVersion: Int?
        var publishedDOI: String?
        var venue: String?
        var pages: Int?
        var fileName: String?
        var sha: String?
        var workType: String?
        var relations: [Rel]?
        var openalex: String?
        var abstract: String?
        var text: String?

        struct Rel: Decodable { var kind: String; var doi: String }

        var subject: DupSubject {
            let ids = PaperIDs(doi: doi, arxivID: arxiv, arxivVersion: arxivVersion, publishedDOI: publishedDOI)
            let rels = (relations ?? []).compactMap { r in WorkRelation.Kind(rawValue: r.kind).map { WorkRelation(kind: $0, doi: r.doi.lowercased()) } }
            let record = BiblioMetadata(ids: ids, source: .crossref, relations: rels, workType: workType, openAlexID: openalex)
            let t = title ?? ""
            return DupSubject(sha256: sha, keys: DupKeys.local(ids) + DupKeys.fromRecord(record), doi: doi, title: t,
                              surnames: DedupeText.surnames(authors ?? []), year: year, pages: pages, venue: venue,
                              kind: DedupeText.kind(title: t, fileName: fileName, workType: workType, relations: rels),
                              rank: VersionRank.of(ids: ids, venue: venue, workType: workType),
                              page: text.flatMap { MinHash.pageSignature(pages: [$0]) },
                              abstract: MinHash.abstractSignature(abstract), fileName: fileName)
        }
    }

    struct Pair: Decodable {
        struct Expect: Decodable { var band: String?; var relation: String? }
        var name: String
        var truth: String
        var expect: Expect
        var new: Side
        var existing: Side
    }

    struct Doc: Decodable { var schema: String; var pairs: [Pair] }

    static func load() throws -> Doc {
        let url = try #require(Bundle.module.url(forResource: "pairs", withExtension: "json", subdirectory: "Fixtures/dedupe"))
        return try JSONDecoder().decode(Doc.self, from: Data(contentsOf: url))
    }

    @Test func fixtureHasAboutFortyPairs() throws {
        let doc = try Self.load()
        #expect(doc.schema == "paperdeck.dedupe-pairs/1")
        #expect(doc.pairs.count >= 40)
        #expect(Set(doc.pairs.map(\.name)).count == doc.pairs.count)
    }

    static let names: [String] = (try? load().pairs.map(\.name)) ?? []

    @Test(arguments: names)
    func pairBandAndRelation(_ name: String) throws {
        let pair = try #require(try Self.load().pairs.first { $0.name == name })
        let c = DupDetector.compare(pair.new.subject, pair.existing.subject)
        #expect(c?.band.rawValue == pair.expect.band, "\(name): \(String(describing: c))")
        if let relation = pair.expect.relation {
            #expect(c?.relation.rawValue == relation, "\(name): \(String(describing: c))")
        }
        // Every verdict can be explained.
        if let c { #expect(!c.evidence.isEmpty, "\(name)") }
    }

    @Test func acceptance() throws {
        let doc = try Self.load()
        var falseCertain: [String] = [], falseLikely: [String] = [], missed: [String] = []
        var same = 0, found = 0
        for p in doc.pairs {
            let c = DupDetector.compare(p.new.subject, p.existing.subject)
            let sameWorkVerdict = c.map { $0.relation.isSameWork } ?? false
            if p.truth != "same", c?.band == .certain, sameWorkVerdict { falseCertain.append(p.name) }
            if p.truth != "same", c?.band == .likely, sameWorkVerdict { falseLikely.append(p.name) }
            if p.truth == "same" {
                same += 1
                if c != nil { found += 1 } else { missed.append(p.name) }
            }
        }
        #expect(falseCertain.isEmpty, "false certain: \(falseCertain)")
        #expect(falseLikely.count <= 1, "false likely: \(falseLikely)")
        #expect(same > 0 && Double(found) / Double(same) >= 0.9, "missed: \(missed)")
    }

    @Test func sensitivityShiftsOnlyTheFuzzyBands() throws {
        let doc = try Self.load()
        for p in doc.pairs {
            let strict = DupDetector.compare(p.new.subject, p.existing.subject, sensitivity: .strict)
            let balanced = DupDetector.compare(p.new.subject, p.existing.subject, sensitivity: .balanced)
            let loose = DupDetector.compare(p.new.subject, p.existing.subject, sensitivity: .loose)
            // Identity verdicts don't move; fuzzy ones only get weaker when stricter.
            if balanced?.band == .certain { #expect(strict?.band == .certain && loose?.band == .certain, "\(p.name)") }
            #expect((strict?.band.strength ?? 0) <= (balanced?.band.strength ?? 0), "\(p.name)")
            #expect((balanced?.band.strength ?? 0) <= (loose?.band.strength ?? 0), "\(p.name)")
        }
    }
}
