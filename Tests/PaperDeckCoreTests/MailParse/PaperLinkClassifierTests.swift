import Foundation
import Testing
@testable import PaperDeckCore

@Suite("MailParse · PaperLinkClassifier") struct MailParsePaperLinkClassifierTests {

    private static func c(_ s: String, _ anchor: String? = nil) -> MailCandidate? {
        PaperLinkClassifier.classify(URL(string: s)!, anchorText: anchor)
    }

    @Test func arxiv() throws {
        let abs = try #require(Self.c("https://arxiv.org/abs/2609.12345v2"))
        #expect(abs.ids == PaperIDs(arxivID: "2609.12345", arxivVersion: 2))
        #expect(abs.origin == .link && abs.cand.isEmpty && abs.host == "arxiv.org" && abs.pdfState == .downloadable)
        #expect(PaperLinkClassifier.pdfURL(for: abs)?.absoluteString == "https://arxiv.org/pdf/2609.12345v2")
        #expect(Self.c("https://arxiv.org/pdf/2609.12345.pdf")?.ids.arxivID == "2609.12345")
        #expect(Self.c("https://export.arxiv.org/html/2609.12345v1")?.ids.arxivVersion == 1)
        #expect(Self.c("https://arxiv.org/abs/math.GT/0309136")?.ids.arxivID == "math.GT/0309136")
        #expect(Self.c("https://www.alphaxiv.org/abs/2609.12345")?.ids.arxivID == "2609.12345")
        #expect(Self.c("https://huggingface.co/papers/2609.12345")?.ids.arxivID == "2609.12345")
        #expect(Self.c("https://doi.org/10.48550/arXiv.2609.12345")?.ids.arxivID == "2609.12345")
        #expect(Self.c("https://arxiv.org/abs/1301.99999") == nil || Self.c("https://arxiv.org/abs/1301.99999")?.ids.arxivID == nil)
    }

    @Test func biorxivAndMedrxiv() throws {
        let b = try #require(Self.c("https://www.biorxiv.org/content/10.1101/2026.09.14.612345v2.full.pdf+html"))
        #expect(b.ids.doi == "10.1101/2026.09.14.612345")
        #expect(b.pdfState == .downloadable)
        #expect(PaperLinkClassifier.pdfURL(for: b)?.absoluteString == "https://www.biorxiv.org/content/10.1101/2026.09.14.612345v2.full.pdf")
        let n = try #require(Self.c("https://www.biorxiv.org/content/10.64898/2026.09.20.612399v1"))
        #expect(n.ids.doi == "10.64898/2026.09.20.612399")
        #expect(PaperLinkClassifier.pdfURL(for: n)?.absoluteString == "https://www.biorxiv.org/content/10.64898/2026.09.20.612399v1.full.pdf")
        let m = try #require(Self.c("https://www.medrxiv.org/content/10.1101/2026.09.24.26312345v3.abstract"))
        #expect(m.ids.doi == "10.1101/2026.09.24.26312345")
        #expect(PaperLinkClassifier.pdfURL(for: m)?.absoluteString == "https://www.medrxiv.org/content/10.1101/2026.09.24.26312345v3.full.pdf")
        #expect(Self.c("https://www.biorxiv.org/cgi/content/short/2026.09.20.612345v1?rss=1")?.ids.doi == "10.1101/2026.09.20.612345")
        #expect(Self.c("https://doi.org/10.1101/2026.09.20.612345")?.pdfState == .downloadable)
        #expect(Self.c("https://doi.org/10.1101/gr.278123.123")?.pdfState == .needsPDF)   // Genome Research, not a preprint
    }

    @Test func doiAndPublisherPatterns() {
        #expect(Self.c("https://doi.org/10.1038/s41586-026-01234-5")?.ids.doi == "10.1038/s41586-026-01234-5")
        #expect(Self.c("http://dx.doi.org/10.1016/J.CELL.2026.09.012")?.ids.doi == "10.1016/j.cell.2026.09.012")
        #expect(Self.c("https://www.nature.com/articles/s41586-026-01234-5")?.ids.doi == "10.1038/s41586-026-01234-5")
        #expect(Self.c("https://www.nature.com/articles/nature12345")?.ids.doi == "10.1038/nature12345")
        #expect(Self.c("https://www.nature.com/articles/s41586-026-01234-5")?.pdfState == .needsPDF)
        #expect(Self.c("https://www.nature.com/articles/s41586-026-01234-5.pdf")?.pdfState == .downloadable)
        #expect(Self.c("https://www.science.org/doi/10.1126/science.adk1234")?.ids.doi == "10.1126/science.adk1234")
        #expect(Self.c("https://www.science.org/doi/full/10.1126/science.adk1234")?.ids.doi == "10.1126/science.adk1234")
        #expect(Self.c("https://www.pnas.org/doi/10.1073/pnas.2400001121")?.ids.doi == "10.1073/pnas.2400001121")
        #expect(Self.c("https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0301234")?.ids.doi == "10.1371/journal.pone.0301234")
        #expect(Self.c("https://elifesciences.org/articles/98765")?.ids.doi == "10.7554/elife.98765")
        #expect(Self.c("https://elifesciences.org/reviewed-preprints/101234")?.ids.doi == "10.7554/elife.101234")
        #expect(Self.c("https://onlinelibrary.wiley.com/doi/full/10.1002/advs.202401234")?.ids.doi == "10.1002/advs.202401234")
        #expect(Self.c("https://link.springer.com/article/10.1007/s00018-024-05123-4")?.ids.doi == "10.1007/s00018-024-05123-4")
        #expect(Self.c("https://www.frontiersin.org/articles/10.3389/fnins.2026.1234567/full")?.ids.doi == "10.3389/fnins.2026.1234567")
        #expect(Self.c("https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4567890")?.ids.doi == "10.2139/ssrn.4567890")
        #expect(Self.c("https://www.researchsquare.com/article/rs-4567890/v1")?.ids.doi == "10.21203/rs.3.rs-4567890/v1")
    }

    @Test func elsevierPII() {
        #expect(Self.c("https://www.cell.com/cell/fulltext/S0092-8674(26)00123-4")?.ids.pii == "S0092867426001234")
        #expect(Self.c("https://www.cell.com/action/showPdf?pii=S0092-8674(26)00230-X")?.ids.pii == "S009286742600230X")
        #expect(Self.c("https://www.sciencedirect.com/science/article/pii/S0092867426001234")?.ids.pii == "S0092867426001234")
        #expect(Self.c("https://www.sciencedirect.com/science/article/abs/pii/S0092867426001234")?.ids.pii == "S0092867426001234")
        #expect(Self.c("https://linkinghub.elsevier.com/retrieve/pii/S0092867426001234")?.ids.pii == "S0092867426001234")
    }

    @Test func pubmedPMCAndOpenReview() throws {
        let pm = try #require(Self.c("https://pubmed.ncbi.nlm.nih.gov/39876543/"))
        #expect(pm.ids.isEmpty && pm.pdfState == .needsPDF && pm.host == "pubmed.ncbi.nlm.nih.gov")
        #expect(PaperLinkClassifier.pubmedID(from: URL(string: "https://pubmed.ncbi.nlm.nih.gov/39876543/")!) == "39876543")
        #expect(PaperLinkClassifier.pubmedID(from: URL(string: "https://www.ncbi.nlm.nih.gov/pubmed/12345678")!) == "12345678")
        #expect(PaperLinkClassifier.pmcID(from: URL(string: "https://pmc.ncbi.nlm.nih.gov/articles/PMC11234567/")!) == "PMC11234567")
        #expect(PaperLinkClassifier.pmcID(from: URL(string: "https://www.ncbi.nlm.nih.gov/pmc/articles/pmc1234567")!) == "PMC1234567")
        #expect(Self.c("https://pmc.ncbi.nlm.nih.gov/articles/PMC11234567/") != nil)
        #expect(Self.c("https://openreview.net/forum?id=AbC123xyz")?.pdfState == .needsPDF)
        #expect(Self.c("https://openreview.net/pdf?id=AbC123xyz")?.pdfState == .downloadable)
    }

    @Test func directPDFs() throws {
        let p = try #require(Self.c("https://lab.example.edu/papers/s41586-026-01234-5.pdf"))
        #expect(p.pdfState == .downloadable)
        #expect(p.ids.doi == "10.1038/s41586-026-01234-5")              // from the file name
        let q = try #require(Self.c("https://files.example.org/preprint-final.PDF"))
        #expect(q.ids.isEmpty && q.pdfState == .downloadable)
    }

    @Test func titleAnchoredPublisherLinks() throws {
        let oup = try #require(Self.c("https://academic.oup.com/bioinformatics/article/42/9/btag321/8123456",
                                      "SpotClean2: denoising sequencing-based spatial data"))
        #expect(oup.title == "SpotClean2: denoising sequencing-based spatial data")
        #expect(oup.ids.isEmpty && oup.pdfState == .needsPDF)
        #expect(Self.c("https://academic.oup.com/bioinformatics/article/42/9/btag321/8123456", "Read more") == nil)
        #expect(Self.c("https://academic.oup.com/bioinformatics/article/42/9/btag321/8123456") == nil)
        #expect(Self.c("https://www.nature.com/nature/volumes/612/issues/7939", "Volume 612 Issue 7939, December 2026") == nil)
        #expect(Self.c("https://www.example-blog.com/post/1", "An interesting post about many things") == nil)
        let doi = try #require(Self.c("https://doi.org/10.1038/s41586-026-01234-5", "here"))
        #expect(doi.title == nil && doi.snippet == "here")
    }

    @Test func fileShares() {
        #expect(Self.c("https://wustl.box.com/s/abc123", "Smith et al. 2026 (PDF)")?.pdfState == .needsPDF)
        #expect(Self.c("https://drive.google.com/file/d/1AbC/view?usp=sharing", "paper.pdf") != nil)
        #expect(Self.c("https://drive.google.com/file/d/1AbC/view?usp=sharing", "Lab photos") == nil)
        #expect(Self.c("https://wustl-my.sharepoint.com/:b:/g/personal/x/EAbc?e=1") != nil)
    }

    @Test(arguments: [
        ("https://www.nature.com/articles/s41586-026-01234-5", "Unsubscribe"),
        ("https://www.nature.com/articles/s41586-026-01234-5", "Manage alerts"),
        ("https://www.nature.com/articles/s41586-026-01234-5", "View in browser"),
        ("https://www.nature.com/articles/s41586-026-01234-5", "Privacy Policy"),
        ("https://www.cell.com/action/unsubscribe?x=1", nil),
        ("https://connect.biorxiv.org/alerts/manage?id=abc", "Manage your alerts"),
        ("https://www.biorxiv.org/email-preferences", nil),
        ("https://twitter.com/intent/tweet?url=https://doi.org/10.1038/x", "Tweet"),
        ("https://www.linkedin.com/shareArticle?url=https://doi.org/10.1038/x", nil),
        ("https://www.nature.com/logo/10.1038/nature-logo.png", nil),
        ("https://scholar.google.com/scholar_alerts?view_op=cancel_alert_options", "CANCEL"),
        ("https://scholar.google.com/citations?update_op=email_library_add&info=abc", "Save"),
        ("https://wustl.zoom.us/j/123456789", "Join the journal club on Zoom now"),
        ("https://bit.ly/3abcdef", "Spatial transcriptomics atlas of the mouse brain"),
    ] as [(String, String?)])
    func denied(url: String, anchor: String?) {
        #expect(Self.c(url, anchor) == nil)
    }

    @Test func nonHTTPSchemesAreRejected() {
        for s in ["javascript:alert(1)", "data:text/html;base64,PHNjcmlwdD4=", "mailto:prof@wustl.edu", "ftp://x.org/a.pdf",
                  "file:///etc/passwd.pdf"] {
            #expect(PaperLinkClassifier.classify(URL(string: s)!, anchorText: "A long enough paper title here") == nil)
        }
    }

    @Test func wrappedLinkKeepsTheOriginal() throws {
        let wrapped = "https://nam02.safelinks.protection.outlook.com/?url=https%3A%2F%2Fwww.nature.com%2Farticles%2Fs41593-026-01999-8%3Futm_source%3Detoc&data=05%7C02"
        let c = try #require(Self.c(wrapped, "Cortical circuits for flexible behavior in mice"))
        #expect(c.url == "https://www.nature.com/articles/s41593-026-01999-8")
        #expect(c.urlOriginal == wrapped)
        #expect(c.host == "nature.com")
        #expect(c.title == "Cortical circuits for flexible behavior in mice")
    }

    @Test func titleLike() {
        #expect(PaperLinkClassifier.isTitleLike("Single-cell multiome profiling of human cortical organoids"))
        #expect(PaperLinkClassifier.isTitleLike("单细胞空间转录组学图谱的构建"))
        #expect(!PaperLinkClassifier.isTitleLike("Read the full article"))
        #expect(!PaperLinkClassifier.isTitleLike("https://doi.org/10.1038/s41586"))
        #expect(!PaperLinkClassifier.isTitleLike("doi: 10.1038/s41586-026-01234-5"))
        #expect(!PaperLinkClassifier.isTitleLike("short"))
    }
}
