import Foundation
import Testing
@testable import PaperDeckCore

@Suite("MailParse · MailExtractor") struct MailParseMailExtractorTests {

    private typealias F = MailParseFixture

    private static let pdfBytes = Data("%PDF-1.4\n%%EOF\n".utf8)

    @Test func advisorRequestWithAttachment() throws {
        let (_, e) = try F.extraction("advisor-request-pdf", kind: .advisor)
        #expect(e.candidates.map(\.cand) == ["c1", "c2"])
        try #require(e.candidates.count > 1)          // no index past a failed expectation (QA-15)
        let att = e.candidates[0]
        #expect(att.origin == .attachment && att.attachmentIndex == 0 && att.pdfState == .hasPDF)
        #expect(att.snippet == "Smith2026_neocortex.pdf")
        let link = e.candidates[1]
        #expect(link.origin == .link && link.ids.doi == "10.1101/2026.09.14.612345" && link.pdfState == .downloadable)
        #expect(link.url == "https://www.biorxiv.org/content/10.1101/2026.09.14.612345v2")

        let body = e.bodyText
        #expect(body.contains("before Thursday's lab meeting"))
        #expect(body.contains("The companion preprint is here: [c2 biorxiv.org]"))
        #expect(!body.contains("http"))
        #expect(!body.contains("utm_"))
        #expect(body.contains("call me at [phone]"))
        #expect(body.contains("lab manager at [email]"))
        #expect(!body.contains("Professor of Neuroscience"))             // signature cut
        #expect(!body.contains("wrote:") && !body.contains("s41586-099"))   // quoted history cut, and its link dropped
        #expect(!e.isForwarded)
        #expect(e.snippet.hasPrefix("Hi Yi, Please read the attached paper"))
        #expect(e.snippet.count <= 255 && !e.snippet.contains("[c"))
    }

    @Test func htmlOnlyBodyGivesTheSameCandidates() throws {
        var c = try F.content("advisor-request-pdf")
        c.plainText = nil
        let e = MailExtractor.extract(c, senderKind: .advisor, bodyCap: 12_000)
        #expect(e.candidates.map(\.origin) == [.attachment, .link])
        try #require(e.candidates.count > 1)          // no index past a failed expectation (QA-15)
        #expect(e.candidates[1].ids.doi == "10.1101/2026.09.14.612345")
        #expect(e.bodyText.contains("The companion preprint is here [c2 biorxiv.org]."))
        #expect(!e.bodyText.contains("s41586-099") && !e.bodyText.contains("is there a paper"))
        #expect(e.bodyText.contains("[email]") && !e.bodyText.contains("lab.manager@"))
    }

    @Test func chineseAdvisorMail() throws {
        let (_, e) = try F.extraction("advisor-zh-gb2312", kind: .advisor)
        #expect(e.candidates.count == 1)
        #expect(e.candidates[0].ids.doi == "10.64898/2026.09.20.612399")
        #expect(e.candidates[0].pdfState == .downloadable)
        #expect(e.bodyText.contains("请在周五前读一下这篇文章，下周组会我们讨论。"))
        #expect(e.bodyText.contains("[c1 biorxiv.org]"))
        #expect(e.bodyText.contains("打我电话 [phone]"))
    }

    @Test func safeLinksNeverReachTheBody() throws {
        let (_, e) = try F.extraction("safelinks-nature", kind: .person)
        #expect(e.candidates.count == 1)
        let c = e.candidates[0]
        #expect(c.ids.doi == "10.1038/s41593-026-01999-8")
        #expect(c.title == "Cortical circuits for flexible behavior in mice")
        #expect(c.url == "https://www.nature.com/articles/s41593-026-01999-8")
        #expect(c.urlOriginal?.contains("safelinks.protection.outlook.com") == true)
        #expect(e.bodyText.contains("Cortical circuits for flexible behavior in mice [c1 nature.com]"))
        for leak in ["safelinks", "sdata", "data=", "yi.jiang", "%40", "<", ">"] { #expect(!e.bodyText.contains(leak), "\(leak)") }
    }

    @Test func proofpointLink() throws {
        let (_, e) = try F.extraction("proofpoint-v3", kind: .person)
        #expect(e.candidates.count == 1)
        #expect(e.candidates[0].ids.pii == "S0092867426001234")
        #expect(e.candidates[0].url == "https://www.cell.com/cell/fulltext/S0092-8674(26)00123-4?src=alert")
        #expect(e.bodyText.contains("before Friday? [c1 cell.com]"))
        #expect(!e.bodyText.contains("urldefense"))
    }

    @Test func scholarAlert() throws {
        let (_, e) = try F.extraction("scholar-alert", kind: .alert)
        #expect(e.candidates.count == 5)
        #expect(e.candidates.allSatisfy { $0.origin == .alertEntry })
        #expect(e.candidates.map(\.cand) == ["c1", "c2", "c3", "c4", "c5"])
        #expect(e.bodyText.contains("Spatial transcriptomics atlas of the developing mouse neocortex [c1 biorxiv.org]"))
        #expect(e.bodyText.contains("[c5 academic.oup.com]"))
        #expect(!e.bodyText.contains("scholar_url") && !e.bodyText.contains("scisig"))
        #expect(!e.bodyText.contains("- A Chen - new results"))              // hidden preheader
        #expect(!e.bodyText.contains("Twitter") && !e.bodyText.contains("LinkedIn"))   // share icons leave no text
    }

    @Test func arxivListing() throws {
        let (_, e) = try F.extraction("arxiv-listing", kind: .alert)
        #expect(e.candidates.map(\.ids.arxivID) == ["2609.20001", "2609.20417", "2609.19876"])
        #expect(e.candidates.allSatisfy { $0.origin == .alertEntry })
        #expect(e.bodyText.contains("\\\\ ( [c1 arxiv.org] , 2048kb)"))
        #expect(e.bodyText.contains("Archives at [link arxiv.org]"))
        #expect(e.bodyText.contains("e-mail To: [email]"))
    }

    @Test func biorxivAlert() throws {
        let (_, e) = try F.extraction("biorxiv-alert", kind: .alert)
        #expect(e.candidates.count == 3)
        #expect(e.bodyText.contains("in human cortex [c1 biorxiv.org]"))
        #expect(e.bodyText.contains("doi: [c1 biorxiv.org]"))               // the doi.org link maps to the same entry
        #expect(!e.bodyText.contains("New bioRxiv results for your alert"))  // hidden preheader
        #expect(e.bodyText.contains("Manage alerts | Unsubscribe"))          // chrome text stays, links do not
    }

    @Test func forwardedTableOfContents() throws {
        let (_, e) = try F.extraction("forwarded-toc", kind: .person)
        #expect(e.isForwarded)
        #expect(e.candidates.count == 4)
        #expect(e.candidates.allSatisfy { $0.origin == .alertEntry })
        try #require(e.candidates.count > 0)          // no index past a failed expectation (QA-15)
        #expect(e.candidates[0].ids.pii == "S0092867426002001")              // SES click-tracking unwrapped
        let parts = e.bodyText.components(separatedBy: "\n\n[forwarded]\n")
        #expect(parts.count == 2)
        #expect(parts[0] == "FYI, see #3 — relevant to our spatial project.")
        #expect(parts[1].hasPrefix("From: Cell Press <[email]>\nDate: Wed, Sep 30, 2026 at 6:00 AM\nSubject: Cell: Table of Contents"))
        #expect(!parts[1].contains("To:"))
        #expect(parts[1].contains("colorectal cancer [c3 doi.org]"))
        #expect(e.snippet == "FYI, see #3 — relevant to our spatial project.")
    }

    @Test func forwardedMessageAttachment() throws {
        let (_, e) = try F.extraction("rfc822-attachment", kind: .person)
        #expect(e.isForwarded)
        #expect(e.candidates.map(\.origin) == [.attachment])
        try #require(e.candidates.count > 0)          // no index past a failed expectation (QA-15)
        #expect(e.candidates[0].snippet == "preprint.pdf" && e.candidates[0].pdfState == .hasPDF)
        #expect(e.bodyText.hasPrefix("Forwarding this - see the attached message.\n\n[forwarded]\n"))
        #expect(e.bodyText.contains("Please read the attached preprint before our meeting next Tuesday."))
        #expect(e.bodyText.contains("From: \"Prof. Jane Smith\" <[email]>"))
    }

    @Test func inlineImagesAreNotCandidates() throws {
        let (_, e) = try F.extraction("alternative-inline-image", kind: .person)
        #expect(e.candidates.isEmpty)
        #expect(e.bodyText == "Weekly update: the new confocal is installed in room 4102. No papers this week.")
    }

    @Test func chineseFilenames() throws {
        let (_, e) = try F.extraction("rfc2231-filename", kind: .person)
        #expect(e.candidates.map(\.snippet) == ["单细胞空间组学.pdf", "神经元图谱.pdf", "综述：空间转录组.pdf"])
        #expect(e.candidates.map(\.attachmentIndex) == [0, 1, 2])
    }

    @Test func promptInjectionStaysInert() throws {
        let (_, e) = try F.extraction("injection-alert", kind: .alert)
        let body = e.bodyText
        #expect(!body.contains("ignore all previous instructions"))          // hidden preheader dropped
        #expect(!body.contains("[c1 evil.com]") && body.contains("(c1 evil.com]"))   // forged marker defused
        #expect(!body.contains("[forwarded]") && !e.isForwarded)             // forged section label defused
        #expect(body.contains("Visit [link evil.example.com] to claim."))
        #expect(!body.contains("token=") && !body.contains("abc123"))
        #expect(!body.contains("javascript") && !body.contains("data:"))
        #expect(e.candidates.count == 1)
        #expect(e.candidates[0].ids.doi == "10.1038/s41586-026-05555-1")
        #expect(body.contains("in adult mice [c1 nature.com]"))
    }

    @Test func candidateOrderAndDedupe() throws {
        let html = """
        <p>See arXiv:2609.11111 and <a href="https://www.nature.com/articles/s41586-026-00001-1?utm_source=x">this one</a>,
        also <a href="https://doi.org/10.1038/s41586-026-00001-1">the DOI link</a> and doi:10.1038/s41586-026-00001-1.</p>
        <h3><a class="gse_alrt_title" href="https://scholar.google.com/scholar_url?url=https://www.biorxiv.org/content/10.1101/2026.09.01.600001v1">An alert entry title about cortical development</a></h3>
        <div>A Author, B Author - bioRxiv, 2026</div>
        """
        let content = MailContent(header: F.header(), plainText: nil, html: html, attachments: [
            MailAttachment(filename: "notes.docx", contentType: "application/octet-stream", isInline: false, data: Data([1]), sizeBytes: 1),
            MailAttachment(filename: "paper.pdf", contentType: "application/pdf", isInline: false, data: Self.pdfBytes, sizeBytes: 15),
            MailAttachment(filename: "figure.pdf", contentType: "application/pdf", isInline: true, data: Self.pdfBytes, sizeBytes: 15),
        ])
        let e = MailExtractor.extract(content, senderKind: .person, bodyCap: 5_000)
        #expect(e.candidates.map(\.origin) == [.attachment, .link, .identifier, .alertEntry])
        #expect(e.candidates.map(\.cand) == ["c1", "c2", "c3", "c4"])
        try #require(e.candidates.count > 3)          // no index past a failed expectation (QA-15)
        #expect(e.candidates[0].attachmentIndex == 1)
        #expect(e.candidates[1].ids.doi == "10.1038/s41586-026-00001-1")
        #expect(e.candidates[2].ids.arxivID == "2609.11111" && e.candidates[2].url == "https://arxiv.org/abs/2609.11111")
        #expect(e.candidates[3].ids.doi == "10.1101/2026.09.01.600001")
        #expect(e.bodyText.contains("this one [c2 nature.com]") && e.bodyText.contains("the DOI link [c2 nature.com]"))
    }

    @Test func linkMatchingAnAttachmentMergesIntoIt() {
        let content = MailContent(
            header: F.header(),
            plainText: "Attached, also online: https://www.nature.com/articles/s41586-026-01234-5",
            html: nil,
            attachments: [MailAttachment(filename: "s41586-026-01234-5.pdf", contentType: "application/pdf", isInline: false,
                                         data: Self.pdfBytes, sizeBytes: 15)])
        let e = MailExtractor.extract(content, senderKind: .advisor, bodyCap: 1_000)
        #expect(e.candidates.count == 1)
        #expect(e.candidates[0].origin == .attachment && e.candidates[0].pdfState == .hasPDF)
        #expect(e.candidates[0].url == "https://www.nature.com/articles/s41586-026-01234-5")
        #expect(e.bodyText == "Attached, also online: [c1 nature.com]")
    }

    @Test func oversizedAttachmentNeedsThePDF() {
        let content = MailContent(header: F.header(), plainText: "see attachment please", html: nil, attachments: [
            MailAttachment(filename: "huge.pdf", contentType: "application/pdf", isInline: false, data: nil, sizeBytes: 90 << 20),
        ])
        let e = MailExtractor.extract(content, senderKind: .advisor, bodyCap: 1_000)
        #expect(e.candidates.first?.pdfState == .needsPDF)
    }

    @Test func bodyCapAndSnippetLimit() {
        let long = String(repeating: "Spatial omics is growing quickly. ", count: 200)
        let content = MailContent(header: F.header(), plainText: long + "\n\n---------- Forwarded message ---------\nFrom: X\n\nforwarded text",
                                  html: nil, attachments: [])
        let e = MailExtractor.extract(content, senderKind: .person, bodyCap: 300)
        #expect(e.bodyText.count <= 300)
        #expect(e.bodyText.hasSuffix("[…truncated]"))
        #expect(!e.bodyText.contains("[forwarded]"))                          // no budget left for it
        #expect(e.snippet.count == 255 && e.snippet.hasSuffix("…"))
        #expect(MailExtractor.extract(content, senderKind: .person, bodyCap: 0).bodyText.contains("[forwarded]"))
    }

    // MARK: History splitting

    @Test func outlookReplyHeaderBlockIsCut() {
        let text = """
        Sounds good, please read the second one.

        ________________________________
        From: Yi Jiang <yi.jiang@wustl.edu>
        Sent: Monday, September 28, 2026 9:00 AM
        To: Smith, Jane <jsmith@wustl.edu>
        Subject: papers

        Old content with https://www.nature.com/articles/s41586-026-99999-9
        """
        let s = MailExtractor.splitHistory(text, subject: "RE: papers")
        #expect(s.unique == "Sounds good, please read the second one.")
        #expect(s.forwarded == nil)
        let fw = MailExtractor.splitHistory(text, subject: "FW: papers")
        #expect(fw.forwarded?.hasPrefix("From: Yi Jiang <yi.jiang@wustl.edu>\nSent: Monday") == true)
        #expect(fw.forwarded?.contains("To:") == false)
        #expect(fw.forwarded?.contains("Old content") == true)
    }

    @Test func chineseReplyMarkers() {
        let zh = "好的，周五前看完。\n\n发件人: 王老师 <wang@wustl.edu>\n发送时间: 2026年9月28日 9:00\n收件人: 小易\n主题: 论文\n\n旧内容"
        #expect(MailExtractor.splitHistory(zh, subject: "回复: 论文").unique == "好的，周五前看完。")
        let gmailZh = "收到。\n\n王老师 <wang@wustl.edu> 于2026年9月28日周一 09:00写道：\n> 请读一下"
        #expect(MailExtractor.splitHistory(gmailZh, subject: "Re: 论文").unique == "收到。")
        let zai = "谢谢老师\n在 2026年9月28日，上午9:00，王老师 <wang@wustl.edu> 写道：\n旧内容"
        #expect(MailExtractor.splitHistory(zai, subject: "Re: 论文").unique == "谢谢老师")
        let fwd = "看看这个\n\n---------- 转发的邮件 ----------\n发件人：Nature\n主题：TOC\n\n条目"
        #expect(MailExtractor.splitHistory(fwd, subject: "转发：TOC").forwarded?.contains("条目") == true)
    }

    @Test func englishReplyMarkers() {
        let wrapped = "Yes.\n\nOn Mon, Sep 28, 2026 at 9:00 AM Yi Jiang <\nyi.jiang@wustl.edu> wrote:\n> old"
        #expect(MailExtractor.splitHistory(wrapped, subject: "Re: x").unique == "Yes.")
        let original = "Top reply\n-----Original Message-----\nFrom: a\nold"
        #expect(MailExtractor.splitHistory(original, subject: "RE: x").unique == "Top reply")
        #expect(MailExtractor.splitHistory(original, subject: "FW: x").forwarded == "From: a\n\nold")
        let apple = "FYI\n\nBegin forwarded message:\n\nFrom: Nature <n@nature.com>\nSubject: TOC\nDate: today\nTo: me\n\nEntries here"
        let s = MailExtractor.splitHistory(apple, subject: "Fwd: TOC")
        #expect(s.unique == "FYI")
        #expect(s.forwarded == "From: Nature <n@nature.com>\nSubject: TOC\nDate: today\n\nEntries here")
        let inline = "My answer\n> quoted line\nMore answer\nSent from my iPhone"
        #expect(MailExtractor.splitHistory(inline, subject: "").unique == "My answer\nMore answer")
    }

    // MARK: Redaction

    @Test func redaction() {
        let s = MailExtractor.redact("""
        Call +1 (314) 555-0199, 314-555-0123 or +86 138 1234 5678 / 13812345678. Room 4102, 2026-09-29, \
        arXiv 2609.12345, doi 10.1101/2026.09.14.612345, ID 12345. Mail jsmith@wustl.edu or other@wustl.edu.
        """, sender: "jsmith@wustl.edu")
        #expect(s == """
        Call [phone], [phone] or [phone] / [phone]. Room 4102, 2026-09-29, \
        arXiv 2609.12345, doi 10.1101/2026.09.14.612345, ID 12345. Mail jsmith@wustl.edu or [email].
        """)
    }
}
