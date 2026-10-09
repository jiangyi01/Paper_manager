import Foundation
import Testing
@testable import PaperDeckCore

@Suite("MailParse · AlertParsers") struct MailParseAlertParsersTests {

    private typealias F = MailParseFixture

    @Test func googleScholarAlert() throws {
        let html = try #require(try F.content("scholar-alert").html)
        let e = AlertParsers.googleScholar(html: html)
        #expect(e.count == 5)
        #expect(e.allSatisfy { $0.origin == .alertEntry && $0.cand.isEmpty })
        #expect(e.map(\.title) == [
            "Spatial transcriptomics atlas of the developing mouse neocortex",
            "Single-cell multiome profiling of human cortical organoids",
            "Foundation models for spatial transcriptomics: a benchmark",
            "Spatial mapping of immune niches in human lymph nodes",
            "SpotClean2: denoising sequencing-based spatial data",
        ])
        try #require(e.count > 4)          // no index past a failed expectation (QA-15)
        #expect(e[0].authors == ["A Chen", "B Kumar", "C Lopez", "D Singh"])
        #expect(e[0].ids.doi == "10.64898/2026.09.20.612345")
        #expect(e[0].pdfState == .downloadable)
        #expect(e[0].url == "https://www.biorxiv.org/content/10.64898/2026.09.20.612345v1.full.pdf")
        #expect(e[0].urlOriginal?.hasPrefix("https://scholar.google.com/scholar_url?url=") == true)
        #expect(e[0].snippet?.hasPrefix("We present a spatial transcriptomics atlas") == true)
        #expect(e[1].ids.doi == "10.1038/s41586-026-01234-5")
        #expect(e[2].ids.arxivID == "2609.12345")
        #expect(e[3].ids.pii == "S0092867426001234")
        #expect(e[4].ids.isEmpty && e[4].host == "academic.oup.com" && e[4].pdfState == .needsPDF)
        #expect(e[4].authors == ["J Doe", "K Roe"])
        #expect(AlertParsers.parse(html: html, plainText: nil, generic: false) == e)
    }

    @Test func scholarByline() {
        let b = AlertParsers.parseScholarByline("A Chen, B Kumar… - Nature Neuroscience, 2026 - nature.com")
        #expect(b.authors == ["A Chen", "B Kumar"])
        #expect(b.venue == "Nature Neuroscience")
        #expect(b.year == 2026)
        let arxiv = AlertParsers.parseScholarByline("F Zhang, G Li - arXiv preprint arXiv:2609.12345, 2026")
        #expect(arxiv.venue == "arXiv preprint arXiv:2609.12345" && arxiv.year == 2026)
        #expect(AlertParsers.arxivIDInText("F Zhang - arXiv preprint arXiv:2609.12345, 2026") == "2609.12345")
    }

    @Test func arxivListing() throws {
        let text = try #require(try F.content("arxiv-listing").plainText)
        let e = AlertParsers.arxivListing(text: text)
        #expect(e.count == 3)
        #expect(e.map(\.ids.arxivID) == ["2609.20001", "2609.20417", "2609.19876"])
        try #require(e.count > 2)          // no index past a failed expectation (QA-15)
        #expect(e[0].title == "Graph neural networks for cell-type deconvolution of spatial transcriptomics data")
        #expect(e[0].authors == ["Mei Lin", "Arjun Rao", "Sofia Duarte"])
        #expect(e[0].snippet?.hasPrefix("Spatial transcriptomics measures gene expression in situ") == true)
        #expect(e[0].url == "https://arxiv.org/abs/2609.20001" && e[0].host == "arxiv.org")
        #expect(e.allSatisfy { $0.pdfState == .downloadable && $0.origin == .alertEntry })
        #expect(e[1].authors == ["Tomasz Nowak", "Hana Sato"])
        #expect(e[2].title == "Protein language models predict enzyme thermostability")
        #expect(e[2].authors == ["J. Alvarez", "K. Osei", "L. Martin"])
    }

    @Test func biorxivAlert() throws {
        let html = try #require(try F.content("biorxiv-alert").html)
        let e = AlertParsers.biorxiv(html: html)
        #expect(e.count == 3)
        #expect(e.map(\.ids.doi) == ["10.1101/2026.09.25.614123", "10.64898/2026.09.26.614500", "10.1101/2026.09.24.26312345"])
        try #require(e.count > 2)          // no index past a failed expectation (QA-15)
        #expect(e[0].title == "Multiplexed imaging reveals layer-specific astrocyte states in human cortex")
        #expect(e[0].authors == ["Priya Natarajan", "Oliver Grant", "Mei Tanaka"])
        #expect(e[2].host == "medrxiv.org")
        #expect(e.allSatisfy { $0.snippet == nil })                           // no footer text as a snippet
        #expect(e[0].url == "https://www.biorxiv.org/content/10.1101/2026.09.25.614123v1")   // rss/utm stripped
    }

    @Test func genericTOCOnlyWhenAsked() throws {
        let html = try #require(try F.content("forwarded-toc").html)
        #expect(AlertParsers.parse(html: html, plainText: nil, generic: false).isEmpty)
        let e = AlertParsers.parse(html: html, plainText: nil, generic: true)
        #expect(e.count == 4)
        #expect(e.map(\.ids.pii) == ["S0092867426002001", "S0092867426002116", nil, "S009286742600230X"])
        try #require(e.count > 2)          // no index past a failed expectation (QA-15)
        #expect(e[2].ids.doi == "10.1016/j.cell.2026.09.012")
        #expect(e[2].authors == ["Fatima Haddad", "Greg Olsen", "Hiro Sato"])
        #expect(!e.contains { ($0.title ?? "").contains("View the full issue") })
    }

    @Test func newsletterChromeYieldsNothing() {
        let html = """
        <p><a href="https://www.nature.com/nature/current-issue">Read the current issue of Nature online today</a></p>
        <p><a href="https://www.nature.com/unsubscribe?x=1">Unsubscribe from these emails at any time</a></p>
        <p><a href="https://twitter.com/nature">Follow Nature on Twitter for the latest news</a></p>
        """
        #expect(AlertParsers.parse(html: html, plainText: nil, generic: true).isEmpty)
    }

    @Test func anchorTextKeepsSpacesBetweenTags() {
        let html = #"<p><a href="https://doi.org/10.1038/s41586-026-07777-7"><b>Deep learning</b> <i>maps</i> the mouse connectome</a><br>A One, B Two</p>"#
        let e = AlertParsers.parse(html: html, plainText: nil, generic: true)
        #expect(e.first?.title == "Deep learning maps the mouse connectome")
        #expect(e.first?.authors == ["A One", "B Two"])
    }

    @Test func duplicateEntriesCollapse() {
        let html = """
        <p><a href="https://doi.org/10.1038/s41586-026-07777-7">Deep learning maps the mouse connectome at scale</a><br>A One, B Two</p>
        <p><a href="https://www.nature.com/articles/s41586-026-07777-7">Deep learning maps the mouse connectome at scale</a><br>A One, B Two</p>
        """
        let e = AlertParsers.parse(html: html, plainText: nil, generic: true)
        #expect(e.count == 1)
        #expect(e.first?.ids.doi == "10.1038/s41586-026-07777-7")
    }
}
