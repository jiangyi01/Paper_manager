import Foundation
import Testing
@testable import PaperDeckCore

/// Parsers against real API responses saved in Fixtures/metadata (see SOURCES.txt there).
@Suite struct MetadataParsingTests {
    static func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/metadata"),
                               "missing fixture \(name).\(ext)")
        return try Data(contentsOf: url)
    }

    // MARK: arXiv

    @Test func arxivNatureBench() throws {
        let data = try Self.fixture("arxiv-2606-24530", "xml")
        let meta = try #require(try MetadataClients.parseArxiv(data))
        #expect(meta.title == "NatureBench: Can Coding Agents Match the Published SOTA of Nature-Family Papers?")
        #expect(meta.authors.count == 17)
        #expect(meta.authors.first == "Yuru Wang")
        #expect(meta.authors.last == "Kaiyan Zhang")
        #expect(meta.year == 2026)
        #expect(meta.venue == "arXiv")
        #expect(meta.source == .arxiv)
        #expect(meta.ids.arxivID == "2606.24530")
        #expect(meta.ids.arxivVersion == 2)
        #expect(meta.ids.doi == nil)
        #expect(meta.abstract?.hasPrefix("We introduce NatureBench, a cross-discipline benchmark") == true)
        #expect(meta.abstract?.contains("g>0.1") == true)   // entity decoded by the XML parser

        let entry = try #require(try MetadataClients.parseArxivEntry(data))
        #expect(entry.primaryCategory == "cs.CL")
        #expect(entry.published == "2026-06-23T12:58:23Z")
        #expect(entry.journalRef == nil)
    }

    @Test func arxivLABBench2() throws {
        let meta = try #require(try MetadataClients.parseArxiv(Self.fixture("arxiv-2604-09554", "xml")))
        #expect(meta.title == "LABBench2: An Improved Benchmark for AI Systems Performing Biology Research")
        #expect(meta.authors.count == 12)
        #expect(meta.authors.first == "Jon M Laurent")
        #expect(meta.authors.contains("Alexandros Sanchez Vassopoulos"))
        #expect(meta.year == 2026)
        #expect(meta.ids.arxivID == "2604.09554")
        let entry = try #require(try MetadataClients.parseArxivEntry(Self.fixture("arxiv-2604-09554", "xml")))
        #expect(entry.primaryCategory == "cs.AI")
    }

    @Test func arxivNotFoundIsNil() throws {
        #expect(try MetadataClients.parseArxiv(Self.fixture("arxiv-notfound", "xml")) == nil)
    }

    /// The legacy feed wraps titles, carries arxiv:doi/journal_ref and reports errors as an entry.
    @Test func arxivLegacyFeedFields() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:arxiv="http://arxiv.org/schemas/atom">
          <title type="html">ArXiv Query: id_list=math/0309136</title>
          <entry>
            <id>http://arxiv.org/abs/math/0309136v2</id>
            <published>2003-09-08T12:00:00Z</published>
            <title>Knots   and
              Links in  3-manifolds</title>
            <summary>  An abstract
              over two lines. </summary>
            <author><name>Ann  Author</name><arxiv:affiliation>Somewhere</arxiv:affiliation></author>
            <author><name>Bo Second</name></author>
            <arxiv:doi>10.1000/XYZ.123 10.1000/other</arxiv:doi>
            <arxiv:journal_ref>J. Topol. 1 (2004) 1-10</arxiv:journal_ref>
            <arxiv:primary_category term="math.GT" scheme="http://arxiv.org/schemas/atom"/>
          </entry>
        </feed>
        """
        let entry = try #require(try MetadataClients.parseArxivEntry(Data(xml.utf8)))
        #expect(entry.id == "math/0309136")
        #expect(entry.version == 2)
        #expect(entry.title == "Knots and Links in 3-manifolds")
        #expect(entry.summary == "An abstract over two lines.")
        #expect(entry.authors == ["Ann Author", "Bo Second"])
        #expect(entry.doi == "10.1000/xyz.123")
        #expect(entry.journalRef == "J. Topol. 1 (2004) 1-10")
        #expect(entry.primaryCategory == "math.GT")
        let meta = try #require(try MetadataClients.parseArxiv(Data(xml.utf8)))
        #expect(meta.ids.publishedDOI == "10.1000/xyz.123")
        #expect(meta.year == 2003)

        let error = """
        <feed xmlns="http://www.w3.org/2005/Atom"><entry><id>http://arxiv.org/api/errors#incorrect_id_format_for_x</id>
        <title>Error</title><summary>incorrect id format for x</summary></entry></feed>
        """
        #expect(try MetadataClients.parseArxiv(Data(error.utf8)) == nil)
    }

    @Test func arxivMalformedThrows() {
        #expect(throws: MetadataClients.ParseError.self) { try MetadataClients.parseArxiv(Data("<html><body>busy".utf8)) }
        #expect(throws: MetadataClients.ParseError.self) { try MetadataClients.parseArxiv(Data("%PDF-1.4 not xml".utf8)) }
        #expect(throws: MetadataClients.ParseError.self) { try MetadataClients.parseArxiv(Data()) }
    }

    // MARK: bioRxiv

    @Test func biorxivLatestVersionAndFirstPostingYear() throws {
        let meta = try #require(try MetadataClients.parseBiorxiv(Self.fixture("biorxiv-2025-09-01-673319", "json")))
        #expect(meta.title == "BioML-bench: Evaluation of AI Agents for End-to-End Biomedical ML")
        #expect(meta.authors == ["H. E. Miller", "M. Greenig", "B. Tenmann", "B. Wang"])
        #expect(meta.year == 2025)
        #expect(meta.venue == "bioRxiv")
        #expect(meta.source == .biorxiv)
        #expect(meta.ids.doi == "10.1101/2025.09.01.673319")
        #expect(meta.ids.publishedDOI == nil)     // "published": "NA"
        #expect(meta.abstract?.hasPrefix("Large language model (LLM) agents hold promise") == true)
    }

    @Test func biorxivNewPrefixRecords() throws {
        let eubiota = try #require(try MetadataClients.parseBiorxiv(Self.fixture("biorxiv-64898-2026-02-27-708412", "json")))
        #expect(eubiota.title == "Eubiota: Modular Agentic AI for Autonomous Discovery in the Gut Microbiome")
        #expect(eubiota.authors.count == 15)
        #expect(eubiota.authors.first == "P. Lu")
        #expect(eubiota.authors.last == "J. Zou")
        #expect(eubiota.year == 2026)
        #expect(eubiota.ids.doi == "10.64898/2026.02.27.708412")

        let compbio = try #require(try MetadataClients.parseBiorxiv(Self.fixture("biorxiv-64898-2026-04-06-716850", "json")))
        #expect(compbio.title == "Agentic systems are adept at solving well-scoped, verifiable problems in computational biology")
        #expect(compbio.authors.first == "S. Nair")
        #expect(compbio.authors.count == 11)
        #expect(compbio.year == 2026)
        #expect(compbio.abstract?.hasPrefix("We introduce CompBioBench") == true)
    }

    @Test func biorxivPublishedDOI() throws {
        let meta = try #require(try MetadataClients.parseBiorxiv(Self.fixture("biorxiv-2024-01-16-575956", "json")))
        #expect(meta.title == "Molecular and cellular dynamics of the developing human neocortex at single-cell resolution")
        #expect(meta.ids.publishedDOI == "10.1038/s41586-024-08351-7")
        #expect(meta.year == 2024)
        #expect(meta.authors.first == "L. Wang")
        #expect(meta.authors.count == 20)
    }

    @Test func biorxivNoPostsAndGarbage() throws {
        #expect(try MetadataClients.parseBiorxiv(Self.fixture("biorxiv-notfound", "json")) == nil)
        #expect(throws: MetadataClients.ParseError.self) { try MetadataClients.parseBiorxiv(Data("<html>".utf8)) }
        #expect(throws: MetadataClients.ParseError.self) { try MetadataClients.parseBiorxiv(Data(#"{"messages":[]}"#.utf8)) }
    }

    @Test func biorxivMedrxivAndOddAuthors() throws {
        let json = #"""
        {"collection":[{"title":"A  <i>test</i>","authors":"Doe, Jane; The ABC Consortium; ; Smith,","doi":"10.1101/2020.01.01.000001",
          "date":"2020-01-02","version":2,"published":"NA","server":"medRxiv","abstract":"p &lt; 0.05 <b>bold</b>"}]}
        """#
        let meta = try #require(try MetadataClients.parseBiorxiv(Data(json.utf8)))
        #expect(meta.title == "A test")
        #expect(meta.authors == ["Jane Doe", "The ABC Consortium", "Smith"])
        #expect(meta.venue == "medRxiv")
        #expect(meta.abstract == "p < 0.05 bold")
    }

    // MARK: Crossref

    @Test func crossrefNatureWork() throws {
        let work = try #require(try MetadataClients.parseCrossrefWork(Self.fixture("crossref-s41586-024-08351-7", "json")))
        let meta = work.meta
        #expect(meta.title == "Molecular and cellular dynamics of the developing human neocortex")
        #expect(meta.authors.count == 20)
        #expect(meta.authors.first == "Li Wang")
        #expect(meta.venue == "Nature")
        #expect(meta.year == 2025)
        #expect(meta.abstract == nil)
        #expect(meta.source == .crossref)
        #expect(meta.ids.doi == "10.1038/s41586-024-08351-7")
        #expect(meta.ids.pii == nil)
        #expect(work.type == "journal-article")
        #expect(!work.isPreprint)
    }

    @Test func crossrefPIIFilterList() throws {
        let works = try MetadataClients.parseCrossrefList(Self.fixture("crossref-pii-S0092867424013321", "json"))
        #expect(works.count == 1)
        let meta = try #require(works.first).meta
        #expect(meta.title == "How to build the virtual cell with artificial intelligence: Priorities and opportunities")
        #expect(meta.authors.first == "Charlotte Bunne")
        #expect(meta.authors.count == 42)
        #expect(meta.venue == "Cell")
        #expect(meta.year == 2024)
        #expect(meta.ids.doi == "10.1016/j.cell.2024.11.015")
        #expect(meta.ids.pii == "S0092867424013321")
    }

    @Test func crossrefPostedContentVenueAndAbstract() throws {
        let preprint = try #require(try MetadataClients.parseCrossrefWork(Self.fixture("crossref-preprints202608-0213-v1", "json")))
        #expect(preprint.meta.title == "Agentic Laboratories of the Future: Towards World Models for Scientific Discovery")
        #expect(preprint.meta.authors.first == "Kelsey Fu")
        #expect(preprint.meta.authors.last == "Mengdi Wang")
        #expect(preprint.meta.authors.count == 55)
        #expect(preprint.meta.venue == "Preprints.org")
        #expect(preprint.meta.year == 2026)
        #expect(preprint.isPreprint)
        let abstract = try #require(preprint.meta.abstract)
        #expect(abstract.hasPrefix("Scientific discovery is fundamentally a problem-solving process"))
        #expect(abstract.hasSuffix("into a unified discovery system."))
        #expect(!abstract.contains("<"))

        let eubiota = try #require(try MetadataClients.parseCrossrefWork(Self.fixture("crossref-64898-2026-02-27-708412", "json")))
        #expect(eubiota.meta.venue == "bioRxiv")          // from `institution`
        #expect(eubiota.meta.year == 2026)
        #expect(eubiota.meta.authors.first == "Pan Lu")
        #expect(eubiota.meta.abstract?.hasPrefix("The gut microbiome regulates") == true)
    }

    @Test func crossrefSearchResults() throws {
        let works = try MetadataClients.parseCrossrefList(Self.fixture("crossref-query-spatialformer", "json"))
        #expect(works.count == 3)
        #expect(works.map(\.meta.ids.doi) == ["10.1101/2025.01.18.633701", "10.1038/s43588-026-01016-7", "10.2139/ssrn.4791548"])
        try #require(works.count > 2)          // no index past a failed expectation (QA-15)
        #expect(works[0].isPreprint)
        #expect(works[0].meta.venue == "bioRxiv")
        #expect(works[0].meta.abstract?.hasPrefix("Abstract") == false)   // heading dropped
        #expect(works[1].meta.venue == "Nature Computational Science")
        #expect(works[1].meta.year == 2026)
        #expect(works[2].meta.venue == "SSRN")
        #expect((works[0].score ?? 0) > 0)
    }

    @Test func crossrefRelationsAndMarkup() throws {
        let json = #"""
        {"status":"ok","message":{"DOI":"10.1101/2020.02.02.000002","type":"posted-content",
          "title":["<i>In vivo</i> imaging of  &amp; stuff"],"subtitle":["a subtitle"],
          "author":[{"given":"Ann","family":"Lee"},{"name":"Big Consortium"},{"family":"Solo"}],
          "issued":{"date-parts":[[null]]},"created":{"date-parts":[[2020,2,3]]},
          "relation":{"is-preprint-of":[{"id-type":"doi","id":"10.1000/JOURNAL.1","asserted-by":"subject"}]},
          "abstract":"<jats:sec><jats:title>Background</jats:title><jats:p>One.</jats:p></jats:sec><jats:sec><jats:title>Results</jats:title><jats:p>Two <jats:sup>2</jats:sup>.</jats:p></jats:sec>"}}
        """#
        let work = try #require(try MetadataClients.parseCrossrefWork(Data(json.utf8)))
        #expect(work.meta.title == "In vivo imaging of & stuff: a subtitle")
        #expect(work.meta.authors == ["Ann Lee", "Big Consortium", "Solo"])
        #expect(work.meta.year == 2020)
        #expect(work.meta.venue == "bioRxiv")
        #expect(work.meta.ids.publishedDOI == "10.1000/journal.1")
        #expect(work.meta.abstract == "Background\n\nOne.\n\nResults\n\nTwo 2.")
    }

    @Test func crossrefGarbageThrows() throws {
        #expect(throws: MetadataClients.ParseError.self) { try MetadataClients.parseCrossrefWork(Self.fixture("crossref-notfound", "txt")) }
        #expect(throws: MetadataClients.ParseError.self) { try MetadataClients.parseCrossrefList(Data("[1,2]".utf8)) }
        #expect(try MetadataClients.parseCrossrefList(Data(#"{"message":{"items":[]}}"#.utf8)).isEmpty)
    }

    // MARK: OpenAlex

    @Test func openAlexNatureRebuildsAbstract() throws {
        let meta = try #require(try MetadataClients.parseOpenAlexWork(Self.fixture("openalex-s41586-024-08351-7", "json")))
        #expect(meta.title == "Molecular and cellular dynamics of the developing human neocortex")
        #expect(meta.authors.count == 20)
        #expect(meta.authors.first == "Li Wang")
        #expect(meta.venue == "Nature")
        #expect(meta.year == 2025)
        #expect(meta.source == .openalex)
        #expect(meta.ids.doi == "10.1038/s41586-024-08351-7")
        let abstract = try #require(meta.abstract)
        #expect(abstract.hasPrefix("Here we collected paired single-nucleus chromatin accessibility"))   // stray "." dropped
        #expect(abstract.split(separator: " ").count > 150)
    }

    @Test func openAlexCell() throws {
        let meta = try #require(try MetadataClients.parseOpenAlexWork(Self.fixture("openalex-cell-2024-11-015", "json")))
        #expect(meta.title == "How to build the virtual cell with artificial intelligence: Priorities and opportunities")
        #expect(meta.venue == "Cell")
        #expect(meta.year == 2024)
        #expect(meta.authors.count == 42)
        #expect(meta.abstract?.hasPrefix("Cells are essential to understanding health and disease") == true)
    }

    @Test func openAlexInvertedIndexIsBounded() {
        let index: JSONValue = .object([
            "world": .array([.number(1)]), "Hello": .array([.number(0)]),
            "ignored": .array([.number(-3), .number(9_999_999)]), "Abstract": .array([]),
        ])
        #expect(MetadataClients.invertedIndexToText(index) == "Hello world")
        #expect(MetadataClients.invertedIndexToText(.null) == nil)
        #expect(MetadataClients.invertedIndexToText(.object([:])) == nil)
    }

    @Test func openAlexGarbageThrows() throws {
        #expect(throws: MetadataClients.ParseError.self) { try MetadataClients.parseOpenAlexWork(Self.fixture("openalex-notfound", "html")) }
        #expect(throws: MetadataClients.ParseError.self) { try MetadataClients.parseOpenAlexWork(Data("[]".utf8)) }
    }

    // MARK: Text cleanup

    @Test func jatsAndMarkup() {
        let jats = "<jats:title>Abstract</jats:title>\n  <jats:p>First <jats:italic>in vivo</jats:italic> &amp; p &lt; 0.05 &#x3B2;.</jats:p><jats:p>Second\n line</jats:p>"
        #expect(MetadataClients.jatsToPlainText(jats) == "First in vivo & p < 0.05 β.\n\nSecond line")
        #expect(MetadataClients.stripMarkup("p < 0.05 and <i>E. coli</i>  x>y") == "p < 0.05 and E. coli x>y")
        #expect(MetadataClients.stripMarkup("Tom &amp; Jerry &bogus; &#169;") == "Tom & Jerry &bogus; ©")
        #expect(MetadataClients.jatsToPlainText("plain text") == "plain text")
    }

    // MARK: URLs and identity

    @Test func urlBuilders() {
        #expect(MetadataClients.arxivURL(id: "2606.24530v2")?.absoluteString == "https://export.arxiv.org/api/query?id_list=2606.24530")
        #expect(MetadataClients.arxivURL(id: "arXiv:2604.09554")?.absoluteString == "https://export.arxiv.org/api/query?id_list=2604.09554")
        #expect(MetadataClients.arxivURL(id: "math.GT/0309136")?.absoluteString == "https://export.arxiv.org/api/query?id_list=math/0309136")
        #expect(MetadataClients.arxivURL(id: "2606.24530&x=1") == nil)
        #expect(MetadataClients.biorxivURL(doi: "10.1101/2025.09.01.673319", server: .biorxiv)?.absoluteString
                == "https://api.biorxiv.org/details/biorxiv/10.1101/2025.09.01.673319")
        #expect(MetadataClients.biorxivURL(doi: "10.64898/2026.02.27.708412", server: .medrxiv)?.absoluteString
                == "https://api.biorxiv.org/details/medrxiv/10.64898/2026.02.27.708412")
        #expect(MetadataClients.crossrefWorkURL(doi: "10.1038/S41586-024-08351-7", mailto: nil)?.absoluteString
                == "https://api.crossref.org/works/10.1038/s41586-024-08351-7")
        #expect(MetadataClients.crossrefWorkURL(doi: "10.1002/(sici)1097<417>;2-g", mailto: "me@example.org")?.absoluteString
                == "https://api.crossref.org/works/10.1002/(sici)1097%3C417%3E%3B2-g?mailto=me%40example.org")
        #expect(MetadataClients.crossrefPIIURL(pii: "S0092867424013321", mailto: nil)?.absoluteString
                == "https://api.crossref.org/works?filter=alternative-id:S0092867424013321&rows=1")
        #expect(MetadataClients.crossrefSearchURL(title: "SpatialFormer: universal  spatial", author: "Wang", mailto: nil)?.absoluteString
                == "https://api.crossref.org/works?query.bibliographic=SpatialFormer%3A%20universal%20spatial&query.author=Wang&rows=3")
        #expect(MetadataClients.crossrefSearchURL(title: "  ", author: nil, mailto: nil) == nil)
        #expect(MetadataClients.openAlexWorkURL(doi: "https://doi.org/10.1016/j.cell.2024.11.015", mailto: nil)?.absoluteString
                == "https://api.openalex.org/works/doi:10.1016/j.cell.2024.11.015?select=id,doi,title,display_name,publication_year,type,authorships,primary_location,abstract_inverted_index")
        #expect(MetadataClients.crossrefWorkURL(doi: "not a doi", mailto: nil) == nil)
    }

    @Test func userAgentAndMailto() {
        #expect(MetadataClients.userAgent(mailto: nil) == "PaperDeck/0.1 (macOS)")
        #expect(MetadataClients.userAgent(mailto: " reader@lab.edu ") == "PaperDeck/0.1 (macOS; mailto:reader@lab.edu)")
        #expect(MetadataClients.userAgent(mailto: "x@y.org\r\nX-Evil: 1") == "PaperDeck/0.1 (macOS)")
        #expect(MetadataClients.userAgent(mailto: "no-at-sign") == "PaperDeck/0.1 (macOS)")
        #expect(MetadataClients.userAgent(mailto: "a@b") == "PaperDeck/0.1 (macOS)")
        let headers = MetadataClients.requestHeaders(for: URL(string: "https://export.arxiv.org/api/query?id_list=1")!, mailto: nil)
        #expect(headers["Accept"] == "application/atom+xml")
        #expect(headers["User-Agent"] == "PaperDeck/0.1 (macOS)")
    }

    @Test func doiHelpers() {
        #expect(MetadataClients.normalizeDOI("https://doi.org/10.1038/S41586-024-08351-7") == "10.1038/s41586-024-08351-7")
        #expect(MetadataClients.normalizeDOI("doi:10.1101/2025.09.01.673319") == "10.1101/2025.09.01.673319")
        #expect(MetadataClients.normalizeDOI("11.1234/x") == nil)
        #expect(MetadataClients.normalizeDOI("") == nil)
        #expect(MetadataClients.isBiorxivFamily(doi: "10.1101/2025.09.01.673319"))
        #expect(MetadataClients.isBiorxivFamily(doi: "10.64898/2026.02.27.708412"))
        #expect(!MetadataClients.isBiorxivFamily(doi: "10.1038/s41586-024-08351-7"))
        #expect(MetadataClients.alternateBiorxivDOI("10.1101/2026.02.27.708412") == "10.64898/2026.02.27.708412")
        #expect(MetadataClients.alternateBiorxivDOI("10.64898/2026.02.27.708412") == "10.1101/2026.02.27.708412")
        #expect(MetadataClients.alternateBiorxivDOI("10.1101/gr.123456.111") == nil)
        #expect(MetadataClients.alternateBiorxivDOI("10.1101/833400") == nil)
        #expect(MetadataClients.biorxivDOI("10.1101/2025.09.01.673319v2") == "10.1101/2025.09.01.673319")
        #expect(MetadataClients.biorxivDOI("10.1101/833400") == "10.1101/833400")
        #expect(MetadataClients.biorxivDOI("10.1101/gr.278123.123") == nil)      // Genome Research
        #expect(MetadataClients.biorxivDOI("10.1101/gad.350000.122") == nil)     // Genes & Development
        #expect(!MetadataClients.isBiorxivFamily(doi: "10.1101/cshperspect.a000001"))
        #expect(MetadataClients.arxivID(fromDOI: "10.48550/arXiv.2606.24530") == "2606.24530")
        #expect(MetadataClients.arxivID(fromDOI: "10.1038/s41586-024-08351-7") == nil)
    }
}
